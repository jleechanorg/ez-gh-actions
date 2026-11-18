#!/usr/bin/env python3
"""Compute sanitized CI latency telemetry (avg, p50, p90, p99) for ezgha dashboards.

Measures three clocks across recent completed non-skipped GitHub Actions runs/jobs:
  1. Queue Wait      (job started_at - created_at)
  2. Job Execution   (job completed_at - started_at)
  3. End-to-End Run  (run updated_at - created_at)

Output is strictly aggregate-only (durations, sample counts, repo slugs, and workflow
names -- never branch names, PR titles, actors, commit messages, or tokens) so it is
safe for the public GitHub Pages snapshot as well as the local operator dashboard.
"""

import argparse
import datetime
import json
import math
import sys
from pathlib import Path

SCRIPT_DIR = str(Path(__file__).resolve().parent)
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import queue_probe  # noqa: E402

RATE_LIMIT_MARKERS = queue_probe.RATE_LIMIT_MARKERS
DEFAULT_REPOS = ("jleechanorg/worldarchitect.ai", "jleechanorg/worldai_frontend")
SKIPPED_CONCLUSIONS = frozenset({"skipped", "neutral"})


def gh_json(args):
    """Indirection so tests can stub GitHub CLI calls cleanly."""
    return queue_probe.gh_json(args)


def _parse_iso(stamp):
    if not isinstance(stamp, str) or not stamp:
        return None
    try:
        return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None


def _seconds_between(start_stamp, end_stamp):
    start_dt = _parse_iso(start_stamp)
    end_dt = _parse_iso(end_stamp)
    if start_dt is None or end_dt is None:
        return None
    delta = (end_dt - start_dt).total_seconds()
    return delta if delta >= 0 else None


def _linear_percentile(sorted_vals, q):
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return round(float(sorted_vals[0]), 2)
    pos = (len(sorted_vals) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return round(float(sorted_vals[lo]), 2)
    frac = pos - lo
    return round(float(sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * frac), 2)


def compute_stats(values):
    """Return {n, avg_s, p50_s, p90_s, p99_s, max_s} using linear interpolation."""
    clean = sorted(float(v) for v in values if isinstance(v, (int, float)) and v >= 0)
    if not clean:
        return {
            "n": 0,
            "avg_s": None,
            "p50_s": None,
            "p90_s": None,
            "p99_s": None,
            "max_s": None,
        }
    return {
        "n": len(clean),
        "avg_s": round(sum(clean) / len(clean), 2),
        "p50_s": _linear_percentile(clean, 0.50),
        "p90_s": _linear_percentile(clean, 0.90),
        "p99_s": _linear_percentile(clean, 0.99),
        "max_s": round(clean[-1], 2),
    }


def _classify_runner_class(runner_name):
    name = (runner_name or "").lower()
    if name.startswith("cmux-"):
        return "cmux-cloud"
    if name.startswith("ez-runner-c-"):
        return "jeff-ubuntu"
    if name.startswith("ez-mac-runner-"):
        return "mac-docker"
    if "native-mac" in name or "mac-native" in name:
        return "mac-native"
    return "other"


def _fetch_completed_runs(repo, limit):
    runs = []
    page = 1
    per_page = min(100, max(1, limit))
    while len(runs) < limit:
        batch = gh_json([
            "api",
            f"repos/{repo}/actions/runs?status=completed&per_page={per_page}&page={page}",
        ])
        chunk = (batch or {}).get("workflow_runs") or []
        runs.extend(chunk)
        if len(chunk) < per_page:
            break
        page += 1
    return runs[:limit]


def _fetch_run_jobs(repo, run_id):
    payload = gh_json(["api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100"])
    return (payload or {}).get("jobs") or []


def _is_rate_limit_error(message):
    lower = message.lower()
    return any(marker in lower for marker in RATE_LIMIT_MARKERS)


def probe_latency(repos, limit=40, job_run_limit=20):
    """Query GitHub Actions runs/jobs and compute sanitized latency percentiles."""
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    run_e2e_by_cohort = {"success": [], "failure": [], "cancelled": [], "all_non_skipped": []}
    job_queue_by_cohort = {"success": [], "failure": [], "cancelled": [], "all_non_skipped": []}
    job_exec_by_cohort = {"success": [], "failure": [], "cancelled": [], "all_non_skipped": []}
    wf_buckets = {}
    runner_class_buckets = {}
    repo_summaries = []
    skipped_runs = 0
    total_non_skipped_runs = 0
    cancelled_runs = 0

    for repo in repos:
        try:
            runs = _fetch_completed_runs(repo, limit)
        except RuntimeError as exc:
            return {
                "schema_version": 1,
                "ok": False,
                "generated_at": generated_at,
                "error": str(exc)[:200],
                "overall": {},
                "cancellation": {},
                "workflows": [],
                "repos": [],
            }

        repo_non_skipped = 0
        repo_cancelled = 0
        repo_e2e_success = []
        non_skipped_runs = []

        for run in runs:
            conclusion = (run.get("conclusion") or "").lower()
            if conclusion in SKIPPED_CONCLUSIONS:
                skipped_runs += 1
                continue
            total_non_skipped_runs += 1
            repo_non_skipped += 1
            if conclusion == "cancelled":
                cancelled_runs += 1
                repo_cancelled += 1

            e2e_s = _seconds_between(run.get("created_at"), run.get("updated_at"))
            if e2e_s is not None:
                run_e2e_by_cohort["all_non_skipped"].append(e2e_s)
                if conclusion in run_e2e_by_cohort:
                    run_e2e_by_cohort[conclusion].append(e2e_s)
                if conclusion == "success":
                    repo_e2e_success.append(e2e_s)

            wf_name = str(run.get("name") or "unknown")
            wf_entry = wf_buckets.setdefault(
                wf_name, {"queue_wait": [], "execution": [], "e2e": [], "n_runs": 0}
            )
            wf_entry["n_runs"] += 1
            if e2e_s is not None and conclusion == "success":
                wf_entry["e2e"].append(e2e_s)

            non_skipped_runs.append(run)

        for run in non_skipped_runs[:job_run_limit]:
            run_id = run.get("id")
            if run_id is None:
                continue
            try:
                jobs = _fetch_run_jobs(repo, run_id)
            except RuntimeError as exc:
                if _is_rate_limit_error(str(exc)):
                    return {
                        "schema_version": 1,
                        "ok": False,
                        "generated_at": generated_at,
                        "error": f"rate limited while reading jobs: {str(exc)[:150]}",
                        "overall": {},
                        "cancellation": {},
                        "workflows": [],
                        "repos": [],
                    }
                continue

            wf_name = str(run.get("name") or "unknown")
            wf_entry = wf_buckets.setdefault(
                wf_name, {"queue_wait": [], "execution": [], "e2e": [], "n_runs": 0}
            )
            for job in jobs:
                j_conc = (job.get("conclusion") or "").lower()
                if j_conc in SKIPPED_CONCLUSIONS:
                    continue
                q_s = _seconds_between(job.get("created_at"), job.get("started_at"))
                e_s = _seconds_between(job.get("started_at"), job.get("completed_at"))
                if q_s is not None:
                    job_queue_by_cohort["all_non_skipped"].append(q_s)
                    if j_conc in job_queue_by_cohort:
                        job_queue_by_cohort[j_conc].append(q_s)
                    if j_conc == "success":
                        wf_entry["queue_wait"].append(q_s)
                if e_s is not None:
                    job_exec_by_cohort["all_non_skipped"].append(e_s)
                    if j_conc in job_exec_by_cohort:
                        job_exec_by_cohort[j_conc].append(e_s)
                    if j_conc == "success":
                        wf_entry["execution"].append(e_s)
                if j_conc == "success":
                    r_cls = _classify_runner_class(job.get("runner_name"))
                    cls_bucket = runner_class_buckets.setdefault(
                        r_cls, {"queue_wait": [], "execution": []}
                    )
                    if q_s is not None:
                        cls_bucket["queue_wait"].append(q_s)
                    if e_s is not None:
                        cls_bucket["execution"].append(e_s)

        repo_summaries.append({
            "repo": repo,
            "non_skipped_runs": repo_non_skipped,
            "cancelled_runs": repo_cancelled,
            "e2e_success": compute_stats(repo_e2e_success),
        })

    # Prefer success cohort for headline queue/exec/e2e; fall back to all_non_skipped if empty.
    headline_q = job_queue_by_cohort["success"] or job_queue_by_cohort["all_non_skipped"]
    headline_e = job_exec_by_cohort["success"] or job_exec_by_cohort["all_non_skipped"]
    headline_e2e = run_e2e_by_cohort["success"] or run_e2e_by_cohort["all_non_skipped"]

    workflows = []
    for wf_name, bucket in wf_buckets.items():
        q_stats = compute_stats(bucket["queue_wait"])
        e_stats = compute_stats(bucket["execution"])
        e2e_stats = compute_stats(bucket["e2e"])
        if q_stats["n"] == 0 and e_stats["n"] == 0 and e2e_stats["n"] == 0:
            continue
        workflows.append({
            "workflow": wf_name,
            "n_runs": bucket["n_runs"],
            "queue_wait": q_stats,
            "execution": e_stats,
            "e2e": e2e_stats,
        })
    workflows.sort(
        key=lambda item: (item["execution"]["p90_s"] or item["e2e"]["p90_s"] or 0.0, item["n_runs"]),
        reverse=True,
    )

    cancelled_pct = (
        round((cancelled_runs / total_non_skipped_runs) * 100.0, 1)
        if total_non_skipped_runs > 0
        else 0.0
    )

    return {
        "schema_version": 1,
        "ok": True,
        "generated_at": generated_at,
        "overall": {
            "queue_wait": compute_stats(headline_q),
            "execution": compute_stats(headline_e),
            "e2e": compute_stats(headline_e2e),
        },
        "cohorts": {
            cohort: {
                "queue_wait": compute_stats(job_queue_by_cohort[cohort]),
                "execution": compute_stats(job_exec_by_cohort[cohort]),
                "e2e": compute_stats(run_e2e_by_cohort[cohort]),
            }
            for cohort in ("success", "failure", "cancelled", "all_non_skipped")
        },
        "cancellation": {
            "cancelled_runs": cancelled_runs,
            "skipped_runs": skipped_runs,
            "total_non_skipped_runs": total_non_skipped_runs,
            "cancelled_rate_pct": cancelled_pct,
        },
        "by_runner_class": {
            cls: {
                "queue_wait": compute_stats(vals["queue_wait"]),
                "execution": compute_stats(vals["execution"]),
            }
            for cls, vals in sorted(runner_class_buckets.items())
        },
        "workflows": workflows[:15],
        "repos": repo_summaries,
    }


def _pick_stat_block(block):
    if not isinstance(block, dict):
        return compute_stats([])
    return {
        "n": block.get("n", 0) if isinstance(block.get("n"), int) else 0,
        "avg_s": block.get("avg_s"),
        "p50_s": block.get("p50_s"),
        "p90_s": block.get("p90_s"),
        "p99_s": block.get("p99_s"),
        "max_s": block.get("max_s"),
    }


def from_audit_json(path):
    """Normalize a pre-collected ci_latency_percentiles.json into public probe shape."""
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    primary = raw.get("worldarchitect_ai") or raw.get("worldai_frontend") or {}
    recent = primary.get("recent_contiguous_runs") or primary.get("recent_runs") or {}
    cohorts = recent.get("cohorts") or {}
    job_audit = primary.get("job_level_audit") or {}
    job_cohorts = job_audit.get("job_cohorts") or {}

    success_jobs = job_cohorts.get("success") or job_cohorts.get("all_non_skipped") or {}
    success_runs = cohorts.get("success") or cohorts.get("all_non_skipped") or {}

    cancelled_n = (cohorts.get("cancelled") or {}).get("n") or 0
    total_non_skipped = (cohorts.get("all_non_skipped") or {}).get("n") or 0
    cancelled_pct = (
        round((cancelled_n / total_non_skipped) * 100.0, 1)
        if total_non_skipped > 0
        else 0.0
    )

    run_wf_map = {}
    for wf in recent.get("by_workflow") or []:
        if isinstance(wf, dict) and isinstance(wf.get("workflow"), str):
            run_wf_map[wf["workflow"]] = wf.get("success") or wf.get("all_non_skipped") or {}

    workflows = []
    for repo_key, repo_slug in (
        ("worldarchitect_ai", "jleechanorg/worldarchitect.ai"),
        ("worldai_frontend", "jleechanorg/worldai_frontend"),
    ):
        repo_block = raw.get(repo_key) or {}
        r_recent = repo_block.get("recent_contiguous_runs") or repo_block.get("recent_runs") or {}
        r_wf_map = {
            wf["workflow"]: wf.get("success") or wf.get("all_non_skipped") or {}
            for wf in (r_recent.get("by_workflow") or [])
            if isinstance(wf, dict) and isinstance(wf.get("workflow"), str)
        }
        r_jobs = repo_block.get("job_level_audit") or {}
        for wf in r_jobs.get("by_workflow") or []:
            if not isinstance(wf, dict) or not isinstance(wf.get("workflow"), str):
                continue
            cohort_data = wf.get("success") or wf.get("all_non_skipped") or {}
            qw = _pick_stat_block(cohort_data.get("queue_wait"))
            ex = _pick_stat_block(cohort_data.get("execution"))
            e2 = _pick_stat_block(r_wf_map.get(wf["workflow"]) or cohort_data.get("total"))
            if qw["n"] == 0 and ex["n"] == 0 and e2["n"] == 0:
                continue
            workflows.append({
                "repo": repo_slug,
                "workflow": wf["workflow"],
                "queue_wait": qw,
                "execution": ex,
                "e2e": e2,
            })
    workflows.sort(
        key=lambda item: (item["execution"]["p90_s"] or item["e2e"]["p90_s"] or 0.0),
        reverse=True,
    )

    step_cats = {}
    raw_steps = (
        (job_audit.get("p90_slow_success_job_step_breakdown") or {}).get("category_summaries_s")
        or {}
    )
    for cat, stats in raw_steps.items():
        if isinstance(cat, str) and isinstance(stats, dict):
            step_cats[cat] = _pick_stat_block(stats)

    runner_classes = {}
    for cls, cls_data in (job_audit.get("by_runner_class") or {}).items():
        if not isinstance(cls, str) or not isinstance(cls_data, dict):
            continue
        c_succ = cls_data.get("success") or cls_data.get("all_non_skipped") or {}
        runner_classes[cls] = {
            "queue_wait": _pick_stat_block(c_succ.get("queue_wait")),
            "execution": _pick_stat_block(c_succ.get("execution")),
        }

    return {
        "schema_version": 1,
        "ok": bool(success_jobs or success_runs),
        "generated_at": raw.get("generated_at_utc"),
        "overall": {
            "queue_wait": _pick_stat_block(success_jobs.get("queue_wait")),
            "execution": _pick_stat_block(success_jobs.get("execution")),
            "e2e": _pick_stat_block(success_runs),
        },
        "cancellation": {
            "cancelled_runs": cancelled_n,
            "skipped_runs": recent.get("skipped_or_neutral_runs") or 0,
            "total_non_skipped_runs": total_non_skipped,
            "cancelled_rate_pct": cancelled_pct,
        },
        "by_runner_class": runner_classes,
        "step_categories": step_cats,
        "workflows": workflows[:15],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", action="append", default=None, help="org/repo to probe")
    parser.add_argument("--from-audit-json", default=None, help="Normalize pre-collected audit JSON")
    parser.add_argument("--limit", type=int, default=40)
    parser.add_argument("--job-run-limit", type=int, default=20)
    parser.add_argument("--output", default=None)
    args = parser.parse_args()

    if args.from_audit_json:
        payload = from_audit_json(args.from_audit_json)
    else:
        repos = args.repo or list(DEFAULT_REPOS)
        payload = probe_latency(repos, limit=args.limit, job_run_limit=args.job_run_limit)

    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(encoded)
    else:
        sys.stdout.write(encoded)
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
