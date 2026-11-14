#!/usr/bin/env python3
"""Measure real CI queue depth for any repo, separating ghost runs from live ones.

Why this exists
---------------
`actions/runs?status=queued` is NOT a backlog metric. It returns a large population of
*ghost* runs: run records whose check suite never expanded, so `jobs.total_count == 0`.
A ghost has nothing to schedule, so it never gets a runner no matter how much idle
capacity exists. Counting ghosts as queued work produces confident wrong conclusions
("runners are starving the queue", "a label has no eligible runner").

Ghosts are distinguishable without a per-run jobs call:

    ghost <=> run.updated_at == run.created_at AND age > 15 min

A run created seconds ago also matches updated_at == created_at simply because nothing
has happened yet, so those fresh runs are resolved against `jobs.total_count` instead of
being guessed. The heuristic is confirmed against the jobs endpoint on a bounded sample
each run, so a change in GitHub's behaviour surfaces as a WARN rather than a silent
wrong number.

Usage
-----
    python3 .claude/skills/ezgha-queued-status/scripts/queued_status.py
    python3 .claude/skills/ezgha-queued-status/scripts/queued_status.py --repo owner/name
    python3 .claude/skills/ezgha-queued-status/scripts/queued_status.py --json

Exit codes: 0 measured, 2 measurement failed (API error / rate limit). A failed
measurement is never a zero.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import random
import subprocess
import sys

DEFAULT_REPO = "jleechanorg/worldarchitect.ai"
DEFAULT_ORG = "jleechanorg"
GHOST_AGE_FLOOR_MIN = 15
VERIFY_SAMPLE = 6


class MeasureError(RuntimeError):
    pass


def _raise_for_body(body, path):
    """A rate-limited/errored call is a JSON object with `message` and no data key."""
    if "message" in body and not ({"total_count", "runners", "workflow_runs"} & set(body)):
        raise MeasureError(f"gh api {path}: {str(body['message'])[:200]}")


def gh_json(path):
    proc = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if proc.returncode != 0:
        raise MeasureError(
            f"gh api {path} failed: {(proc.stderr or proc.stdout).strip()[:300]}"
        )
    try:
        body = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise MeasureError(f"gh api {path} returned non-JSON: {exc}") from exc
    _raise_for_body(body, path)
    return body


def gh_paged(path):
    """Fetch every page, tolerating gh's concatenated-object pagination output."""
    proc = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True)
    if proc.returncode != 0:
        raise MeasureError(
            f"gh api --paginate {path} failed: {(proc.stderr or proc.stdout).strip()[:300]}"
        )
    decoder = json.JSONDecoder()
    text, idx, rows = proc.stdout, 0, []
    while idx < len(text):
        while idx < len(text) and text[idx] in " \n\t\r":
            idx += 1
        if idx >= len(text):
            break
        if not text[idx:].lstrip().startswith("{"):
            raise MeasureError(f"gh api --paginate {path}: unexpected output")
        obj, idx = decoder.raw_decode(text, idx)
        _raise_for_body(obj, path)
        rows.extend(obj.get("workflow_runs", []))
    return rows


def minutes_since(stamp, now):
    if not stamp:
        return None
    return (now - dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds() / 60


def measure(repo, org=DEFAULT_ORG, verify=VERIFY_SAMPLE):
    now = dt.datetime.now(dt.timezone.utc)
    out = {"repo": repo, "sampled_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}

    fleet = gh_json(f"/orgs/{org}/actions/runners?per_page=100")
    runners = fleet.get("runners", [])
    online = [r for r in runners if r.get("status") == "online"]
    busy = [r for r in online if r.get("busy")]
    out["fleet"] = {
        "total": len(runners),
        "online": len(online),
        "busy": len(busy),
        "idle": len(online) - len(busy),
        "offline": len(runners) - len(online),
        "utilization_pct": round(100 * len(busy) / len(online), 1) if online else 0.0,
        "offline_names": sorted(r["name"] for r in runners if r.get("status") != "online"),
    }

    out["run_status_totals"] = {
        status: gh_json(f"/repos/{repo}/actions/runs?status={status}&per_page=1").get(
            "total_count", 0
        )
        for status in ("queued", "in_progress")
    }

    queued = gh_paged(f"/repos/{repo}/actions/runs?status=queued&per_page=100")
    ghosts, live, fresh = [], [], []
    for run in queued:
        age = minutes_since(run.get("created_at"), now)
        row = {
            "id": run["id"],
            "name": run.get("name") or "",
            "branch": run.get("head_branch") or "",
            "path": run.get("path") or "",
            "created_at": run.get("created_at"),
            "age_min": round(age, 1) if age is not None else None,
        }
        if run.get("updated_at") != run.get("created_at"):
            live.append(row)
        elif (age or 0) > GHOST_AGE_FLOOR_MIN:
            ghosts.append(row)
        else:
            fresh.append(row)

    # Fresh runs cannot be classified by timestamp alone; resolve only this bounded set.
    for row in fresh:
        body = gh_json(f"/repos/{repo}/actions/runs/{row['id']}/jobs?per_page=100")
        (live if body.get("total_count", 0) > 0 else ghosts).append(row)

    out["queued_runs"] = {
        "raw_total": len(queued),
        "ghost": len(ghosts),
        "live": len(live),
        "fresh_resolved_via_jobs": len(fresh),
        "ghost_ids": [r["id"] for r in ghosts],
    }

    live_detail, waits = [], []
    for row in live:
        body = gh_json(f"/repos/{repo}/actions/runs/{row['id']}/jobs?per_page=100")
        jobs = body.get("jobs", [])
        queued_jobs = [j for j in jobs if j.get("status") == "queued"]
        for job in jobs:
            if job.get("status") in ("completed", "in_progress") and job.get("created_at") and job.get("started_at"):
                delta = (
                    dt.datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
                    - dt.datetime.fromisoformat(job["created_at"].replace("Z", "+00:00"))
                ).total_seconds() / 60
                # A zero delta means started_at was not a real pickup stamp.
                if delta > 0:
                    waits.append(delta)
        live_detail.append(
            {
                **row,
                "total_jobs": len(jobs),
                "queued_jobs": len(queued_jobs),
                "running_jobs": sum(1 for j in jobs if j.get("status") == "in_progress"),
                "oldest_queued_min": round(
                    max((minutes_since(j.get("created_at"), now) or 0) for j in queued_jobs), 1
                )
                if queued_jobs
                else None,
            }
        )
    out["live_runs"] = live_detail

    waits.sort()
    out["job_queue"] = {
        "queued_jobs": sum(r["queued_jobs"] for r in live_detail),
        "running_jobs": sum(r["running_jobs"] for r in live_detail),
        "pickup_wait_median_min": round(waits[len(waits) // 2], 1) if waits else None,
        "pickup_wait_p90_min": round(waits[int(len(waits) * 0.9)], 1) if waits else None,
        "pickup_wait_max_min": round(waits[-1], 1) if waits else None,
        "oldest_queued_job_min": max(
            (r["oldest_queued_min"] for r in live_detail if r["oldest_queued_min"] is not None),
            default=None,
        ),
    }

    checks = {"ghost_sampled": 0, "ghost_zero_jobs": 0, "live_sampled": 0, "live_has_jobs": 0}
    for row in random.sample(ghosts, min(verify, len(ghosts))):
        body = gh_json(f"/repos/{repo}/actions/runs/{row['id']}/jobs?per_page=100")
        checks["ghost_sampled"] += 1
        checks["ghost_zero_jobs"] += int(body.get("total_count", 0) == 0)
    for row in random.sample(live, min(verify, len(live))):
        body = gh_json(f"/repos/{repo}/actions/runs/{row['id']}/jobs?per_page=100")
        checks["live_sampled"] += 1
        checks["live_has_jobs"] += int(body.get("total_count", 0) > 0)
    out["heuristic_check"] = checks
    out["heuristic_ok"] = (
        checks["ghost_zero_jobs"] == checks["ghost_sampled"]
        and checks["live_has_jobs"] == checks["live_sampled"]
    )
    return out


def render(r):
    f, q, jq = r["fleet"], r["queued_runs"], r["job_queue"]
    lines = [
        f"## Queued status — {r['repo']} @ {r['sampled_at']}",
        "",
        "### Runner fleet (org level)",
        f"- online **{f['online']}** / total {f['total']} — busy {f['busy']}, "
        f"idle **{f['idle']}**, offline {f['offline']} ({f['utilization_pct']}% utilized)",
    ]
    if f["offline_names"]:
        lines.append(f"- offline: {', '.join(f['offline_names'])}")
    lines += [
        "",
        "### Queued workflow runs",
        f"- raw `status=queued`: **{q['raw_total']}** (ghosts {q['ghost']}, live {q['live']}; "
        f"{q['fresh_resolved_via_jobs']} too fresh for the timestamp test were resolved via jobs)",
    ]
    if q["ghost"]:
        lines.append(
            f"- **backlog is the {q['live']} live runs, not the raw {q['raw_total']}** — "
            f"{q['ghost']} are ghosts with zero jobs that will never be scheduled"
        )
    lines += [
        "",
        "### Live queue depth and pickup wait",
        f"- queued jobs: **{jq['queued_jobs']}** across {len(r['live_runs'])} live runs; "
        f"running {jq['running_jobs']}",
    ]
    if f["idle"] > 0 and jq["queued_jobs"] == 0:
        lines.append("- healthy: idle runners exist and nothing is waiting")
    elif f["idle"] == 0 and jq["queued_jobs"] > 0:
        lines.append("- saturated: zero idle runners while jobs wait — genuine capacity pressure")
    if jq["pickup_wait_median_min"] is not None:
        lines.append(
            f"- pickup wait (started_at − created_at): median **{jq['pickup_wait_median_min']}m**, "
            f"p90 {jq['pickup_wait_p90_min']}m, max {jq['pickup_wait_max_min']}m"
        )
    if jq["oldest_queued_job_min"] is not None:
        lines.append(f"- oldest still-queued job: **{jq['oldest_queued_job_min']}m**")
    if r["live_runs"]:
        lines += ["", "| run | branch | age | jobs | queued | running |", "|---|---|---|---|---|---|"]
        for row in sorted(r["live_runs"], key=lambda x: -(x["age_min"] or 0)):
            lines.append(
                f"| {row['name'][:34]} | {row['branch'][:26]} | {row['age_min']}m | "
                f"{row['total_jobs']} | {row['queued_jobs']} | {row['running_jobs']} |"
            )
    c = r["heuristic_check"]
    lines += [
        "",
        f"### Heuristic self-check — **{'OK' if r['heuristic_ok'] else 'WARN'}**",
        f"- ghost sample zero jobs: {c['ghost_zero_jobs']}/{c['ghost_sampled']}",
        f"- live sample has jobs: {c['live_has_jobs']}/{c['live_sampled']}",
    ]
    if not r["heuristic_ok"]:
        lines.append(
            "- WARN: the heuristic no longer separates ghosts. Use per-run `jobs.total_count` "
            "for every queued run before reporting a backlog number."
        )
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Measure real queued-task backlog.")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--org", default=DEFAULT_ORG)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--verify-sample", type=int, default=VERIFY_SAMPLE)
    args = ap.parse_args(argv)
    try:
        result = measure(args.repo, args.org, args.verify_sample)
    except MeasureError as exc:
        print(f"MEASUREMENT FAILED: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2) if args.json else render(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
