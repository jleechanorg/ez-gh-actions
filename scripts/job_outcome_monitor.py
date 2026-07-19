#!/usr/bin/env python3
"""Report a bounded recent sample of objective ezgha runner job outcomes."""

import argparse
import json
import os
import subprocess
import sys
import time
import tomllib
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode


DEFAULT_WINDOW_HOURS = 6.0
DEFAULT_MINIMUM_JOBS = 6
DEFAULT_MINIMUM_SUCCESS_RATE = 0.8
DEFAULT_SAMPLE_TARGET = 32
DEFAULT_MAXIMUM_RUNS_PER_REPO = 20
DEFAULT_MAXIMUM_API_REQUESTS = 50
DEFAULT_MAXIMUM_WALL_SECONDS = 75.0
HARD_MAXIMUM_RUNS_PER_REPO = 99
HARD_MAXIMUM_API_REQUESTS = 100
HARD_MAXIMUM_WALL_SECONDS = 75.0
GH_TIMEOUT_SECONDS = 45
STALE_TOKEN_ENV = ("GH_TOKEN", "GH_TOKEN_AGENTF", "GITHUB_TOKEN")


class CoverageError(RuntimeError):
    """The requested outcome window could not be observed completely."""


class GithubApi:
    def __init__(self, maximum_requests, maximum_wall_seconds):
        self.maximum_requests = maximum_requests
        self.requests = 0
        self.deadline = time.monotonic() + maximum_wall_seconds
        self.probe_deadline_exhausted = False

    def block_reason(self):
        if self.requests >= self.maximum_requests:
            return "api_request_budget_exhausted"
        if time.monotonic() >= self.deadline:
            self.probe_deadline_exhausted = True
            return "probe_deadline_exhausted"
        return None

    def get(self, path):
        block_reason = self.block_reason()
        if block_reason:
            raise CoverageError(block_reason)
        self.requests += 1
        timeout = min(GH_TIMEOUT_SECONDS, max(0.001, self.deadline - time.monotonic()))
        env = os.environ.copy()
        for name in STALE_TOKEN_ENV:
            env.pop(name, None)
        try:
            result = subprocess.run(
                ["gh", "api", path],
                capture_output=True,
                text=True,
                env=env,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            if timeout < GH_TIMEOUT_SECONDS:
                self.probe_deadline_exhausted = True
                raise CoverageError("probe_deadline_exhausted") from exc
            raise CoverageError("github_api_unavailable:TimeoutExpired") from exc
        except OSError as exc:
            raise CoverageError(f"github_api_unavailable:{type(exc).__name__}") from exc
        if result.returncode != 0:
            raise CoverageError("github_api_nonzero")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise CoverageError("github_api_invalid_json") from exc
        if not isinstance(payload, dict):
            raise CoverageError("github_api_non_object")
        return payload


def parse_instant(raw):
    if not isinstance(raw, str):
        raise ValueError("timestamp must be a string")
    value = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if value.tzinfo is None:
        raise ValueError("timestamp must include a timezone")
    return value.astimezone(timezone.utc)


def format_instant(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def load_runner_prefix(path):
    try:
        payload = tomllib.loads(Path(path).read_text(encoding="utf-8"))
        prefix = payload["runner"]["name_prefix"]
    except (OSError, KeyError, TypeError, tomllib.TOMLDecodeError) as exc:
        raise CoverageError("configured_runner_prefix_unavailable") from exc
    if not isinstance(prefix, str) or not prefix.strip():
        raise CoverageError("configured_runner_prefix_invalid")
    return prefix.strip()


def runner_matches(name, prefix):
    return name == prefix or name.startswith(f"{prefix}-")


def collect_outcomes(
    api,
    repos,
    runner_prefix,
    start,
    end,
    sample_target,
    maximum_runs_per_repo,
):
    sampled_jobs = []
    seen_job_ids = set()
    candidate_runs = []
    reported_runs = 0
    runs_scanned = 0
    run_caps_reached = []
    api_request_cap_reached = False
    reasons = []

    for repo in repos:
        block_reason = api.block_reason()
        if block_reason:
            reasons.append(
                "api_request_budget_too_small_for_repo_lists"
                if block_reason == "api_request_budget_exhausted"
                else block_reason
            )
            break
        query = urlencode(
            {
                "status": "completed",
                "created": f">={format_instant(start)}",
                "per_page": maximum_runs_per_repo,
            }
        )
        try:
            payload = api.get(f"repos/{repo}/actions/runs?{query}")
            runs = payload.get("workflow_runs")
            total_count = payload.get("total_count")
            if not isinstance(runs, list) or type(total_count) is not int:
                raise CoverageError(f"run_list_invalid:{repo}")
            reported_runs += total_count
            capped = total_count > maximum_runs_per_repo
            expected_items = maximum_runs_per_repo if capped else total_count
            if len(runs) != expected_items:
                raise CoverageError(f"run_list_truncated:{repo}")
            if capped:
                run_caps_reached.append(repo)
            for run in runs:
                if not isinstance(run, dict) or type(run.get("id")) is not int:
                    raise CoverageError(f"run_invalid:{repo}")
                if run.get("status") != "completed":
                    raise CoverageError(f"run_not_completed:{repo}:{run['id']}")
                try:
                    created_at = parse_instant(run.get("created_at"))
                except (TypeError, ValueError) as exc:
                    raise CoverageError(f"run_timestamp_invalid:{repo}:{run['id']}") from exc
                if created_at < start or created_at > end:
                    raise CoverageError(f"run_outside_window:{repo}:{run['id']}")
                candidate_runs.append((created_at, repo, run["id"]))
        except CoverageError as exc:
            reasons.append(str(exc))

    candidate_runs.sort(reverse=True)
    for _, repo, run_id in candidate_runs:
        if len(sampled_jobs) >= sample_target:
            break
        block_reason = api.block_reason()
        if block_reason:
            if block_reason == "api_request_budget_exhausted":
                api_request_cap_reached = True
            else:
                reasons.append(block_reason)
            break
        try:
            jobs_payload = api.get(
                f"repos/{repo}/actions/runs/{run_id}/jobs?filter=all&per_page=100"
            )
            jobs = jobs_payload.get("jobs")
            jobs_total = jobs_payload.get("total_count")
            if not isinstance(jobs, list) or type(jobs_total) is not int:
                raise CoverageError(f"job_list_invalid:{repo}:{run_id}")
            if jobs_total != len(jobs):
                raise CoverageError(f"job_list_truncated:{repo}:{run_id}")
            runs_scanned += 1
            for job in jobs:
                if not isinstance(job, dict) or type(job.get("id")) is not int:
                    raise CoverageError(f"job_invalid:{repo}:{run_id}")
                runner_name = job.get("runner_name")
                if not isinstance(runner_name, str) or not runner_matches(
                    runner_name, runner_prefix
                ):
                    continue
                if job.get("status") != "completed":
                    raise CoverageError(f"job_not_completed:{repo}:{job['id']}")
                conclusion = job.get("conclusion")
                if not isinstance(conclusion, str) or not conclusion:
                    raise CoverageError(f"job_conclusion_invalid:{repo}:{job['id']}")
                try:
                    completed_at = parse_instant(job.get("completed_at"))
                except (TypeError, ValueError) as exc:
                    raise CoverageError(
                        f"job_timestamp_invalid:{repo}:{job['id']}"
                    ) from exc
                if completed_at < start or completed_at > end:
                    raise CoverageError(f"job_outside_window:{repo}:{job['id']}")
                if job["id"] in seen_job_ids:
                    raise CoverageError(f"duplicate_job:{job['id']}")
                seen_job_ids.add(job["id"])
                sampled_jobs.append(
                    {
                        "id": job["id"],
                        "conclusion": conclusion,
                        "completed_at": completed_at,
                    }
                )
        except CoverageError as exc:
            reasons.append(str(exc))
            break

    sampled_jobs.sort(key=lambda job: job["completed_at"], reverse=True)
    sampled_jobs = sampled_jobs[:sample_target]
    scanned_all_candidates = runs_scanned == len(candidate_runs)
    metadata = {
        "reported_runs": reported_runs,
        "candidate_runs": len(candidate_runs),
        "runs_scanned": runs_scanned,
        "run_caps_reached": sorted(run_caps_reached),
        "api_request_cap_reached": api_request_cap_reached,
        "eligible_run_population_complete": (
            not run_caps_reached
            and not api_request_cap_reached
            and scanned_all_candidates
            and not reasons
        ),
        "probe_deadline_exhausted": api.probe_deadline_exhausted,
    }
    return sampled_jobs, metadata, sorted(set(reasons))


def build_report(args):
    now = parse_instant(args.now) if args.now else datetime.now(timezone.utc)
    start = now - timedelta(hours=args.window_hours)
    api = GithubApi(args.maximum_api_requests, args.maximum_wall_seconds)
    reasons = []
    try:
        prefix = load_runner_prefix(args.config)
        sampled_jobs, metadata, collection_reasons = collect_outcomes(
            api,
            args.repo,
            prefix,
            start,
            now,
            args.sample_target,
            args.maximum_runs_per_repo,
        )
        reasons.extend(collection_reasons)
    except CoverageError as exc:
        prefix = None
        sampled_jobs = []
        metadata = {
            "reported_runs": 0,
            "candidate_runs": 0,
            "runs_scanned": 0,
            "run_caps_reached": [],
            "api_request_cap_reached": False,
            "eligible_run_population_complete": False,
            "probe_deadline_exhausted": api.probe_deadline_exhausted,
        }
        reasons.append(str(exc))

    conclusions = Counter(job["conclusion"] for job in sampled_jobs)
    completed_jobs = sum(conclusions.values())
    success = conclusions.get("success", 0)
    unsuccessful = completed_jobs - success
    success_rate = success / completed_jobs if completed_jobs else None
    sample_sufficient = completed_jobs >= args.minimum_jobs
    if not sample_sufficient:
        reasons.append("insufficient_sample")
    if reasons:
        verdict = "UNKNOWN"
    elif success_rate >= args.minimum_success_rate:
        verdict = "HEALTHY"
    else:
        verdict = "UNHEALTHY"

    return {
        "schema_version": 1,
        "observed_at": format_instant(now),
        "metric": "bounded_recent_job_success_rate",
        "signal": "completed_jobs_on_configured_runner_prefix",
        "causal_attribution": {
            "determined": False,
            "note": "Job conclusions alone do not distinguish fleet defects from repository or test failures.",
        },
        "runner_prefix": prefix,
        "repos": args.repo,
        "eligibility_window": {
            "hours": args.window_hours,
            "start": format_instant(start),
            "end": format_instant(now),
            "population": "jobs completed within window from completed runs created within same window",
        },
        "limits": {
            "sample_target": args.sample_target,
            "maximum_runs_per_repo": args.maximum_runs_per_repo,
            "maximum_api_requests": args.maximum_api_requests,
            "maximum_wall_seconds": args.maximum_wall_seconds,
        },
        "thresholds": {
            "minimum_jobs": args.minimum_jobs,
            "minimum_success_rate": args.minimum_success_rate,
        },
        "coverage": {
            "sample_sufficient": sample_sufficient,
            "sample_target_met": completed_jobs >= args.sample_target,
            "eligible_run_population_complete": metadata[
                "eligible_run_population_complete"
            ],
            "probe_deadline_exhausted": metadata["probe_deadline_exhausted"],
            "api_requests": api.requests,
            "reported_runs": metadata["reported_runs"],
            "candidate_runs": metadata["candidate_runs"],
            "runs_scanned": metadata["runs_scanned"],
            "run_caps_reached": metadata["run_caps_reached"],
            "api_request_cap_reached": metadata["api_request_cap_reached"],
            "reasons": sorted(set(reasons)),
        },
        "sample": {
            "target_jobs": args.sample_target,
            "selection": "exact-prefix jobs from newest-created completed runs scanned before hard caps",
            "newest_completed_at": (
                format_instant(sampled_jobs[0]["completed_at"]) if sampled_jobs else None
            ),
            "oldest_completed_at": (
                format_instant(sampled_jobs[-1]["completed_at"]) if sampled_jobs else None
            ),
        },
        "outcomes": {
            "completed_jobs": completed_jobs,
            "success": success,
            "unsuccessful": unsuccessful,
            "sample_success_rate": success_rate,
            "conclusions": dict(sorted(conclusions.items())),
        },
        "verdict": verdict,
    }


def positive_float(raw):
    value = float(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return value


def positive_int(raw):
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return value


def success_rate(raw):
    value = float(raw)
    if not 0 <= value <= 1:
        raise argparse.ArgumentTypeError("must be between zero and one")
    return value


def repo_name(raw):
    if raw.count("/") != 1 or any(char.isspace() for char in raw):
        raise argparse.ArgumentTypeError("must be owner/repo")
    owner, repo = raw.split("/", 1)
    if not owner or not repo:
        raise argparse.ArgumentTypeError("must be owner/repo")
    return raw


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config", default=str(Path.home() / ".config/ezgha/config.toml")
    )
    parser.add_argument("--repo", action="append", required=True, type=repo_name)
    parser.add_argument("--window-hours", type=positive_float, default=DEFAULT_WINDOW_HOURS)
    parser.add_argument("--minimum-jobs", type=positive_int, default=DEFAULT_MINIMUM_JOBS)
    parser.add_argument(
        "--minimum-success-rate", type=success_rate, default=DEFAULT_MINIMUM_SUCCESS_RATE
    )
    parser.add_argument("--sample-target", type=positive_int, default=DEFAULT_SAMPLE_TARGET)
    parser.add_argument(
        "--maximum-runs-per-repo",
        type=positive_int,
        default=DEFAULT_MAXIMUM_RUNS_PER_REPO,
    )
    parser.add_argument(
        "--maximum-api-requests",
        type=positive_int,
        default=DEFAULT_MAXIMUM_API_REQUESTS,
    )
    parser.add_argument(
        "--maximum-wall-seconds",
        type=positive_float,
        default=DEFAULT_MAXIMUM_WALL_SECONDS,
    )
    parser.add_argument("--now", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    args.repo = list(dict.fromkeys(args.repo))
    if args.maximum_runs_per_repo > HARD_MAXIMUM_RUNS_PER_REPO:
        parser.error(
            f"--maximum-runs-per-repo must be <= {HARD_MAXIMUM_RUNS_PER_REPO}"
        )
    if args.maximum_api_requests > HARD_MAXIMUM_API_REQUESTS:
        parser.error(f"--maximum-api-requests must be <= {HARD_MAXIMUM_API_REQUESTS}")
    if args.maximum_wall_seconds > HARD_MAXIMUM_WALL_SECONDS:
        parser.error(f"--maximum-wall-seconds must be <= {HARD_MAXIMUM_WALL_SECONDS:g}")
    if args.sample_target < args.minimum_jobs:
        parser.error("--sample-target must be >= --minimum-jobs")
    return args


def main(argv=None):
    try:
        report = build_report(parse_args(argv))
    except (TypeError, ValueError) as exc:
        print(json.dumps({"schema_version": 1, "verdict": "UNKNOWN", "error": str(exc)}))
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return {"HEALTHY": 0, "UNHEALTHY": 1, "UNKNOWN": 2}[report["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
