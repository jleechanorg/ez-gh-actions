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
import os
import subprocess
import sys

RATE_LIMIT_MARKERS = ("rate limit", "403", "429")
DEFAULT_MAX_REQUESTS = 100


class RequestBudgetExhausted(RuntimeError):
    """Raised when queue_probe hits its per-run GitHub API request cap."""


def _resolve_max_requests(cli_value=None):
    if cli_value is not None:
        return max(1, int(cli_value))
    raw = os.environ.get("EZGHA_QUEUE_PROBE_MAX_REQUESTS", "").strip()
    if not raw:
        return DEFAULT_MAX_REQUESTS
    try:
        parsed = int(raw)
    except ValueError:
        return DEFAULT_MAX_REQUESTS
    return max(1, parsed)


def _call_gh(args, *, budget=None, reserve=0):
    if budget is not None:
        limit = budget.get("limit")
        used = budget.get("used", 0)
        if limit is not None and used + reserve >= limit:
            raise RequestBudgetExhausted(f"request budget exhausted ({limit} requests)")
        budget["used"] = used + 1
    return gh_json(args)


def gh_env():
    """Environment for gh subprocesses.

    gh picks up GH_TOKEN, but a launchd job inherits almost no environment, so the
    probe must locate a token itself or every scheduled publish reports the queue as
    unavailable. Prefer an explicit GH_TOKEN, then the App token file the rest of this
    repo already uses. Only the PATH is passed through otherwise -- the token is read
    here, never logged.
    """
    # launchd's PATH omits ~/.local/bin, which is where this host's gh wrapper lives,
    # so include the usual user bin directories and the Homebrew prefixes ahead of the
    # system defaults. Nothing here grants access; it only makes `gh` findable.
    default_path = ":".join(
        [
            os.path.expanduser("~/.local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    )
    env = {"PATH": os.environ.get("PATH") or default_path}
    if "/.local/bin" not in env["PATH"]:
        env["PATH"] = f"{os.path.expanduser('~/.local/bin')}:{default_path}"
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        candidate = os.path.expanduser("~/.config/ezgha/gh_token")
        try:
            with open(candidate, encoding="utf-8") as handle:
                token = handle.read().strip()
        except OSError:
            token = ""
    if token:
        env["GH_TOKEN"] = token
    env.update({
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_PAGER": "",
    })
    return env


def gh_json(args, timeout=20):
    try:
        result = subprocess.run(
            ["gh", *args], capture_output=True, env=gh_env(), timeout=timeout
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"gh timed out after {timeout}s") from exc
    if result.returncode != 0:
        raise RuntimeError((result.stderr or b"").decode()[:300])
    return json.loads(result.stdout.decode() or "null")


def in_progress_run_count(repo, *, budget=None, reserve=0):
    payload = _call_gh([
        "api",
        f"repos/{repo}/actions/runs?status=in_progress&per_page=1",
        "--jq",
        ".total_count",
    ], budget=budget, reserve=reserve)
    return payload if type(payload) is int and payload >= 0 else None


def _list_queued_budget(repo, *, max_pages=None, budget=None, reserve=0):
    runs, page = [], 1
    reported_total = None
    budget_error = None
    while True:
        page_reserve = 0 if page == 1 else reserve
        try:
            batch = _call_gh([
                "api",
                f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}",
            ], budget=budget, reserve=page_reserve)
        except RequestBudgetExhausted as exc:
            if page == 1:
                raise
            budget_error = str(exc)
            break
        if reported_total is None and isinstance((batch or {}).get("total_count"), int):
            reported_total = batch["total_count"]
        chunk = (batch or {}).get("workflow_runs") or []
        runs.extend(chunk)
        if len(chunk) < 100 or (max_pages is not None and page >= max_pages):
            break
        page += 1
    total = reported_total if reported_total is not None else len(runs)
    return runs, total, budget_error


def list_queued_with_total(repo, *, max_pages=None):
    """Fetch queued runs up to max_pages (all pages when None), returning (runs, total_count)."""
    runs, total, _budget_error = _list_queued_budget(repo, max_pages=max_pages)
    return runs, total


def list_queued(repo):
    """Every queued run for a repo, following pagination."""
    runs, _total = list_queued_with_total(repo)
    return runs


def job_count(repo, run_id, *, budget=None, reserve=0):
    payload = _call_gh(
        ["api", f"repos/{repo}/actions/runs/{run_id}/jobs", "--jq", ".total_count"],
        budget=budget,
        reserve=reserve,
    )
    return payload if type(payload) is int else None


def inspect_run_jobs(repo, run_id, *, budget=None, reserve=0):
    """Fetch a run's jobs page once and return (total_count, queued_jobs, has_job_details)."""
    payload = _call_gh(
        ["api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100"],
        budget=budget,
        reserve=reserve,
    )
    if type(payload) is int:
        return payload, [], False
    if not isinstance(payload, dict):
        return None, [], False
    total = payload.get("total_count")
    count = total if type(total) is int else None
    raw_jobs = payload.get("jobs")
    if isinstance(raw_jobs, list):
        queued_jobs = []
        for job in raw_jobs:
            if not isinstance(job, dict) or job.get("status") != "queued":
                continue
            labels = [
                lb.strip().lower()
                for lb in (job.get("labels") or [])
                if isinstance(lb, str) and lb.strip()
            ]
            queued_jobs.append({
                "repo": repo,
                "created_at": job.get("created_at"),
                "labels": labels,
            })
        return count, queued_jobs, True
    return count, [], False


def minutes_since(stamp):
    if not isinstance(stamp, str):
        return None
    try:
        created = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    delta = datetime.datetime.now(datetime.timezone.utc) - created
    return max(0, int(delta.total_seconds() // 60))


def probe_repo(repo, *, max_job_checks=None, max_requests=None, _budget=None, _reserve=0):
    budget = _budget
    if budget is None and max_requests is not None:
        budget = {"limit": max(1, int(max_requests)), "used": 0}
    try:
        queued, queued_total, budget_error = _list_queued_budget(
            repo,
            max_pages=1 if max_job_checks is not None else None,
            budget=budget,
            reserve=_reserve,
        )
    except RequestBudgetExhausted as exc:
        return {"repo": repo, "ok": False, "fresh": None, "ghosts": None,
                "oldest_fresh_wait_minutes": None, "in_progress_runs": None,
                "queued_total": None, "sample_capped": False,
                "sampled_fresh": None, "sampled_ghosts": None,
                "partial": True, "unverified_runs": 0,
                "error": str(exc)[:200]}
    except RuntimeError as exc:
        return {"repo": repo, "ok": False, "fresh": None, "ghosts": None,
                "oldest_fresh_wait_minutes": None, "in_progress_runs": None,
                "queued_total": None, "sample_capped": False,
                "sampled_fresh": None, "sampled_ghosts": None,
                "partial": False, "unverified_runs": 0,
                "error": str(exc)[:200]}

    try:
        ip_runs = in_progress_run_count(repo, budget=budget, reserve=0)
    except RequestBudgetExhausted as exc:
        budget_error = budget_error or str(exc)
        ip_runs = None
    except RuntimeError as exc:
        message = str(exc).lower()
        if any(marker in message for marker in RATE_LIMIT_MARKERS):
            return {"repo": repo, "ok": False, "fresh": None, "ghosts": None,
                    "oldest_fresh_wait_minutes": None, "in_progress_runs": None,
                    "queued_total": queued_total, "sample_capped": False,
                    "sampled_fresh": None, "sampled_ghosts": None,
                    "partial": False, "unverified_runs": 0,
                    "error": f"rate limited while reading in_progress runs: {str(exc)[:150]}"}
        ip_runs = None

    short_listing = queued_total > len(queued) and (max_job_checks is None or len(queued) < 100)
    sample_capped = max_job_checks is not None and (queued_total > max_job_checks or len(queued) > max_job_checks)
    to_check = queued[:max_job_checks] if (max_job_checks is not None and len(queued) > max_job_checks) else queued
    fresh = ghosts = unreadable_jobs = checked_runs = 0
    oldest = None
    budget_capped_jobs = False
    queued_jobs_out = []
    job_details_complete = True
    for run in to_check:
        run_id = run.get("id")
        if run_id is None:
            count = None
            run_queued_jobs = []
            has_job_details = False
            job_details_complete = False
        else:
            try:
                count, run_queued_jobs, has_job_details = inspect_run_jobs(
                    repo, run_id, budget=budget, reserve=_reserve
                )
            except RequestBudgetExhausted as exc:
                budget_error = budget_error or str(exc)
                budget_capped_jobs = True
                job_details_complete = False
                break
            except RuntimeError as exc:
                message = str(exc).lower()
                if any(marker in message for marker in RATE_LIMIT_MARKERS):
                    # Do not report a rate-limited pass as a clean queue.
                    return {"repo": repo, "ok": False, "fresh": None, "ghosts": None,
                            "oldest_fresh_wait_minutes": None, "in_progress_runs": None,
                            "queued_total": queued_total, "sample_capped": False,
                            "sampled_fresh": None, "sampled_ghosts": None,
                            "partial": False, "unverified_runs": 0,
                            "queued_jobs": [], "job_details_complete": False,
                            "error": f"rate limited while reading jobs: {str(exc)[:150]}"}
                count = None
                run_queued_jobs = []
                has_job_details = False
                job_details_complete = False

        checked_runs += 1
        if count is None:
            unreadable_jobs += 1
            job_details_complete = False

        if count == 0:
            ghosts += 1
            continue

        # count >= 1, or unreadable: both count as real waiting work.
        fresh += 1
        if has_job_details:
            queued_jobs_out.extend(run_queued_jobs)
            for qj in run_queued_jobs:
                wait = minutes_since(qj.get("created_at"))
                if wait is not None and (oldest is None or wait > oldest):
                    oldest = wait
        else:
            job_details_complete = False
            wait = minutes_since(run.get("created_at"))
            if wait is not None and (oldest is None or wait > oldest):
                oldest = wait

    budget_exhausted = budget_error is not None or budget_capped_jobs
    remaining_unchecked = max(0, max(queued_total, len(queued)) - checked_runs)
    unverified_runs = unreadable_jobs + remaining_unchecked
    incomplete = bool(sample_capped or short_listing or budget_exhausted)
    return {"repo": repo, "ok": True,
            "fresh": None if incomplete else fresh,
            "ghosts": None if incomplete else ghosts,
            "oldest_fresh_wait_minutes": oldest, "in_progress_runs": ip_runs,
            "queued_total": queued_total, "sample_capped": bool(sample_capped or budget_exhausted),
            "sampled_fresh": fresh, "sampled_ghosts": ghosts,
            "partial": bool(unverified_runs > 0 or incomplete), "unverified_runs": unverified_runs,
            "queued_jobs": queued_jobs_out,
            "job_details_complete": bool(job_details_complete and not incomplete and unreadable_jobs == 0),
            "error": budget_error[:200] if budget_error else None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", action="append", required=True,
                        help="org/repo to probe; repeatable")
    parser.add_argument("--max-requests", type=int, default=None,
                        help=f"hard cap on total GitHub API requests (default: {DEFAULT_MAX_REQUESTS})")
    parser.add_argument("--max-job-checks", type=int, default=None,
                        help="optional cap on per-run /jobs lookups per repo")
    parser.add_argument("--output", default=None)
    args = parser.parse_args()

    max_requests = _resolve_max_requests(args.max_requests)
    budget = {"limit": max_requests, "used": 0}
    total_repos = len(args.repo)
    repos = []
    for idx, repo in enumerate(args.repo):
        reserve_for_later = 2 * (total_repos - 1 - idx)
        repos.append(
            probe_repo(
                repo,
                max_job_checks=args.max_job_checks,
                _budget=budget,
                _reserve=reserve_for_later,
            )
        )
    ok = all(entry["ok"] for entry in repos)
    complete_counts = ok and all(type(entry.get("fresh")) is int and type(entry.get("ghosts")) is int for entry in repos)
    fresh = sum(entry["fresh"] for entry in repos) if complete_counts else None
    ghosts = sum(entry["ghosts"] for entry in repos) if complete_counts else None
    ip_vals = [entry["in_progress_runs"] for entry in repos
               if entry["ok"] and type(entry.get("in_progress_runs")) is int]
    in_progress_total = (
        sum(ip_vals)
        if ok and len(ip_vals) == len(repos)
        else None
    )
    waits = [entry["oldest_fresh_wait_minutes"] for entry in repos
             if entry["ok"] and entry["oldest_fresh_wait_minutes"] is not None]
    errors = [entry["error"] for entry in repos if entry.get("error")]

    payload = {
        "schema_version": 1,
        "ok": ok,
        "fresh": fresh,
        "ghosts": ghosts,
        "oldest_fresh_wait_minutes": max(waits) if waits else None,
        "in_progress_runs": in_progress_total,
        "partial": any(entry.get("partial") or entry.get("sample_capped") for entry in repos),
        "unverified_runs": sum(entry.get("unverified_runs") or 0 for entry in repos),
        "errors": errors,
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
