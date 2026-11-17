#!/usr/bin/env python3
"""Emit an aggregate queue-health payload for the runner dashboard snapshot.

Splits queued workflow runs into two classes so a human never again has to guess
whether the backlog number is real:

  fresh   -- a queued run that owns at least one job. This is work actually waiting
             for a runner, and the only number that should read as "backlog".
  ghosts  -- a queued run that owns ZERO jobs. GitHub will not transition these at
             all: cancel and force-cancel return 409 "Cannot cancel a workflow run
             that has not been queued yet" and DELETE returns 403. They can never
             start, and they cannot be cleaned up from our side. Counting them as
             queue depth is what made a 99-run queue look like a 99-run emergency
             when 25 were real.

Job count is the ONLY reliable discriminator. Verified 2026-11-16 against live runs:
`created_at == updated_at` is also true for a legitimate run created and still queued
in the same second, and `pull_requests == []` fails because some ghosts do carry a PR.
A run whose job count cannot be read is classified `fresh` -- unknown must never hide
real work.

Output is aggregate-only: counts and repo slugs, never run ids, branch names, or
actors. This payload feeds a public GitHub Pages snapshot.

Usage:
  scripts/queue_probe.py --repo jleechanorg/worldarchitect.ai --repo jleechanorg/worldai_frontend
"""

import argparse
import datetime
import json
import subprocess
import sys

RATE_LIMIT_MARKERS = ("rate limit", "403", "429")


def gh_json(args):
    result = subprocess.run(["gh", *args], capture_output=True)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or b"").decode()[:300])
    return json.loads(result.stdout.decode() or "null")


def list_queued(repo):
    """Every queued run for a repo, following pagination."""
    runs, page = [], 1
    while True:
        batch = gh_json([
            "api",
            f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}",
        ])
        chunk = (batch or {}).get("workflow_runs") or []
        runs.extend(chunk)
        if len(chunk) < 100:
            return runs
        page += 1


def job_count(repo, run_id):
    payload = gh_json(["api", f"repos/{repo}/actions/runs/{run_id}/jobs", "--jq", ".total_count"])
    return payload if type(payload) is int else None


def minutes_since(stamp):
    if not isinstance(stamp, str):
        return None
    try:
        created = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    delta = datetime.datetime.now(datetime.timezone.utc) - created
    return max(0, int(delta.total_seconds() // 60))


def probe_repo(repo):
    try:
        queued = list_queued(repo)
    except RuntimeError as exc:
        return {"repo": repo, "ok": False, "fresh": None, "ghosts": None,
                "oldest_fresh_wait_minutes": None, "error": str(exc)[:200]}

    fresh = ghosts = 0
    oldest = None
    for run in queued:
        run_id = run.get("id")
        if run_id is None:
            continue
        try:
            count = job_count(repo, run_id)
        except RuntimeError as exc:
            message = str(exc).lower()
            if any(marker in message for marker in RATE_LIMIT_MARKERS):
                # Do not report a rate-limited pass as a clean queue.
                return {"repo": repo, "ok": False, "fresh": None, "ghosts": None,
                        "oldest_fresh_wait_minutes": None,
                        "error": f"rate limited while reading jobs: {str(exc)[:150]}"}
            count = None

        if count == 0:
            ghosts += 1
            continue

        # count >= 1, or unreadable: both count as real waiting work.
        fresh += 1
        wait = minutes_since(run.get("created_at"))
        if wait is not None and (oldest is None or wait > oldest):
            oldest = wait

    return {"repo": repo, "ok": True, "fresh": fresh, "ghosts": ghosts,
            "oldest_fresh_wait_minutes": oldest, "error": None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", action="append", required=True,
                        help="org/repo to probe; repeatable")
    parser.add_argument("--output", default=None)
    args = parser.parse_args()

    repos = [probe_repo(repo) for repo in args.repo]
    ok = all(entry["ok"] for entry in repos)
    fresh = sum(entry["fresh"] for entry in repos if entry["ok"]) if ok else None
    ghosts = sum(entry["ghosts"] for entry in repos if entry["ok"]) if ok else None
    waits = [entry["oldest_fresh_wait_minutes"] for entry in repos
             if entry["ok"] and entry["oldest_fresh_wait_minutes"] is not None]

    payload = {
        "schema_version": 1,
        "ok": ok,
        "fresh": fresh,
        "ghosts": ghosts,
        "oldest_fresh_wait_minutes": max(waits) if waits else None,
        "repos": repos,
    }

    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(encoded)
    else:
        sys.stdout.write(encoded)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
