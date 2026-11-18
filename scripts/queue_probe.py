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


def in_progress_run_count(repo):
    payload = gh_json([
        "api",
        f"repos/{repo}/actions/runs?status=in_progress&per_page=1",
        "--jq",
        ".total_count",
    ])
    return payload if type(payload) is int and payload >= 0 else None


def list_queued_with_total(repo, *, max_pages=None):
    """Fetch queued runs up to max_pages (all pages when None), returning (runs, total_count)."""
    runs, page = [], 1
    reported_total = None
    while True:
        batch = gh_json([
            "api",
            f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}",
        ])
        if reported_total is None and isinstance((batch or {}).get("total_count"), int):
            reported_total = batch["total_count"]
        chunk = (batch or {}).get("workflow_runs") or []
        runs.extend(chunk)
        if len(chunk) < 100 or (max_pages is not None and page >= max_pages):
            return runs, (reported_total if reported_total is not None else len(runs))
        page += 1


def list_queued(repo):
    """Every queued run for a repo, following pagination."""
    runs, _total = list_queued_with_total(repo)
    return runs


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


def probe_repo(repo, *, max_job_checks=None):
    try:
        if max_job_checks is not None:
            queued, queued_total = list_queued_with_total(repo, max_pages=1)
        else:
            queued = list_queued(repo)
            queued_total = len(queued)
    except RuntimeError as exc:
        return {"repo": repo, "ok": False, "fresh": None, "ghosts": None,
                "oldest_fresh_wait_minutes": None, "in_progress_runs": None,
                "queued_total": None, "sample_capped": False,
                "sampled_fresh": None, "sampled_ghosts": None,
                "partial": False, "unverified_runs": 0,
                "error": str(exc)[:200]}

    try:
        ip_runs = in_progress_run_count(repo)
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

    sample_capped = max_job_checks is not None and (queued_total > max_job_checks or len(queued) > max_job_checks)
    to_check = queued[:max_job_checks] if (max_job_checks is not None and len(queued) > max_job_checks) else queued
    fresh = ghosts = unreadable_jobs = 0
    oldest = None
    for run in to_check:
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
                        "oldest_fresh_wait_minutes": None, "in_progress_runs": None,
                        "queued_total": queued_total, "sample_capped": False,
                        "sampled_fresh": None, "sampled_ghosts": None,
                        "partial": False, "unverified_runs": 0,
                        "error": f"rate limited while reading jobs: {str(exc)[:150]}"}
            count = None
            unreadable_jobs += 1

        if count == 0:
            ghosts += 1
            continue

        # count >= 1, or unreadable: both count as real waiting work.
        fresh += 1
        wait = minutes_since(run.get("created_at"))
        if wait is not None and (oldest is None or wait > oldest):
            oldest = wait

    return {"repo": repo, "ok": True,
            "fresh": None if sample_capped else fresh,
            "ghosts": None if sample_capped else ghosts,
            "oldest_fresh_wait_minutes": oldest, "in_progress_runs": ip_runs,
            "queued_total": queued_total, "sample_capped": sample_capped,
            "sampled_fresh": fresh, "sampled_ghosts": ghosts,
            "partial": unreadable_jobs > 0, "unverified_runs": unreadable_jobs,
            "error": None}


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
    ip_vals = [entry["in_progress_runs"] for entry in repos
               if entry["ok"] and type(entry.get("in_progress_runs")) is int]
    in_progress_total = (
        sum(ip_vals)
        if ok and len(ip_vals) == len(repos)
        else None
    )
    waits = [entry["oldest_fresh_wait_minutes"] for entry in repos
             if entry["ok"] and entry["oldest_fresh_wait_minutes"] is not None]

    payload = {
        "schema_version": 1,
        "ok": ok,
        "fresh": fresh,
        "ghosts": ghosts,
        "oldest_fresh_wait_minutes": max(waits) if waits else None,
        "in_progress_runs": in_progress_total,
        "partial": any(entry.get("partial") for entry in repos),
        "unverified_runs": sum(entry.get("unverified_runs") or 0 for entry in repos),
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
