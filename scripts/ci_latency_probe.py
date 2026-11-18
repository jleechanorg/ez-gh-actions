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
import re
import shlex
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = str(Path(__file__).resolve().parent)
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import queue_probe  # noqa: E402

RATE_LIMIT_MARKERS = queue_probe.RATE_LIMIT_MARKERS
DEFAULT_REPOS = ("jleechanorg/worldarchitect.ai", "jleechanorg/worldai_frontend")
SKIPPED_CONCLUSIONS = frozenset({"skipped", "neutral"})
COHORT_NAMES = ("success", "failure", "cancelled", "all_non_skipped")

PHASE_RULES = (
    ("playwright install", r"playwright\s+install"),
    ("playwright", r"playwright"),
    ("jest", r"\bjest\b"),
    ("pytest", r"\bpytest\b"),
    ("git index-pack", r"git\s+index-pack|index-pack"),
    ("git fetch", r"git\b.*\bfetch\b|git-remote-http"),
    ("gh api tarball", r"gh\s+api.*tarball"),
    ("npm ci", r"\bnpm\s+ci\b"),
    ("pip", r"\bpip3?\s+install\b"),
    ("cargo", r"\bcargo\b"),
    ("gcloud", r"\bgcloud\b"),
    ("mypy", r"\bmypy\b"),
    ("shellcheck", r"\bshellcheck\b"),
    ("setup-python", r"setup-python"),
)


def _command_head_string(command_text):
    """Extract executable/subcommand tokens, ignoring flags, paths, and shell wrappers."""
    cleaned = re.sub(r"^\S+\s+\(\d+s\):\s*", "", command_text.strip())
    try:
        tokens = shlex.split(cleaned)
    except ValueError:
        tokens = cleaned.split()
    while tokens:
        head = Path(tokens[0]).name.lower()
        if "=" in tokens[0] and not tokens[0].startswith("-"):
            tokens = tokens[1:]
        elif head == "env":
            tokens = tokens[1:]
        elif head == "timeout" and len(tokens) >= 3:
            tokens = tokens[2:]
        elif head in {"bash", "sh", "zsh"} and len(tokens) >= 3 and tokens[1] in {"-c", "-lc"}:
            inner = tokens[2]
            try:
                tokens = shlex.split(inner)
            except ValueError:
                tokens = inner.split()
        else:
            break
    head_tokens = []
    skip_next = False
    value_flags = {
        "-c", "-C", "-k", "-o", "-f", "-t", "-r", "-e",
        "--config", "--cwd", "--grep", "--output", "--filter",
        "--loader", "--import", "--require", "--eval",
    }
    non_phase_commands = {
        "cat", "less", "more", "head", "tail", "vim", "vi", "nano",
        "grep", "rg", "ls", "stat", "wc", "rm", "cp", "mv", "echo",
        "printf", "touch", "mkdir",
    }
    interpreters = {"node", "nodejs", "npx", "python", "python3", "python2", "uv"}
    ignored_exts = (".log", ".txt", ".json", ".xml", ".zip", ".md", ".ini", ".cfg", ".yml", ".yaml")
    for tok in tokens:
        if skip_next:
            skip_next = False
            continue
        if tok in value_flags:
            skip_next = True
            continue
        if tok.startswith("-"):
            continue
        low = tok.lower()
        base = Path(low).name if "/" in low else low
        if not head_tokens and base in non_phase_commands:
            return ""
        if "tarball" in low and head_tokens[:2] == ["gh", "api"]:
            head_tokens.append("tarball")
            break
        if base.endswith(ignored_exts) or base.endswith(".config.js"):
            continue
        if "/" in low and head_tokens:
            if "/_actions/" in low and "setup-python" in low:
                head_tokens.append("setup-python")
                continue
            if head_tokens[0] in interpreters:
                if "@playwright/" in low:
                    head_tokens.append("playwright")
                else:
                    head_tokens.append(base)
                if len(head_tokens) >= 3:
                    break
            continue
        if "setup-python" in low and not head_tokens:
            head_tokens.append("setup-python")
            continue
        head_tokens.append(base)
        if len(head_tokens) >= 3:
            break
    return " ".join(head_tokens)


def classify_phase(command_text):
    """Return canonical execution phase tag from OS process command line, or None."""
    if not isinstance(command_text, str) or not command_text.strip():
        return None
    head = _command_head_string(command_text)
    if not head:
        return None
    for label, pattern in PHASE_RULES:
        if re.search(pattern, head, re.IGNORECASE):
            return label
    return None


DEFAULT_GH_TIMEOUT_S = 20

_AUDIT_REPO_ALIASES = {
    "worldarchitect_ai": "jleechanorg/worldarchitect.ai",
    "worldai_frontend": "jleechanorg/worldai_frontend",
}


def gh_json(args, timeout=DEFAULT_GH_TIMEOUT_S):
    """Bounded GitHub CLI JSON call delegating to queue_probe.gh_json."""
    return queue_probe.gh_json(args, timeout=timeout)


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
    timed_out_runs = 0
    failed_job_fetches = 0

    def empty_wf_bucket():
        return {
            "n_runs": 0,
            "cohorts": {
                c: {"queue_wait": [], "execution": [], "e2e": []}
                for c in COHORT_NAMES
            },
        }

    for repo in repos:
        try:
            runs = _fetch_completed_runs(repo, limit)
        except RuntimeError as exc:
            return {
                "schema_version": 1,
                "ok": False,
                "partial": True,
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
            wf_entry = wf_buckets.setdefault((repo, wf_name), empty_wf_bucket())
            wf_entry["n_runs"] += 1
            if e2e_s is not None:
                wf_entry["cohorts"]["all_non_skipped"]["e2e"].append(e2e_s)
                if conclusion in wf_entry["cohorts"]:
                    wf_entry["cohorts"][conclusion]["e2e"].append(e2e_s)

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
                        "partial": True,
                        "generated_at": generated_at,
                        "error": f"rate limited while reading jobs: {str(exc)[:150]}",
                        "overall": {},
                        "cancellation": {},
                        "workflows": [],
                        "repos": [],
                    }
                if "timed out" in str(exc).lower():
                    timed_out_runs += 1
                else:
                    failed_job_fetches += 1
                continue

            wf_name = str(run.get("name") or "unknown")
            wf_entry = wf_buckets.setdefault((repo, wf_name), empty_wf_bucket())
            for job in jobs:
                j_conc = (job.get("conclusion") or "").lower()
                if j_conc in SKIPPED_CONCLUSIONS:
                    continue
                q_s = _seconds_between(job.get("created_at"), job.get("started_at"))
                e_s = _seconds_between(job.get("started_at"), job.get("completed_at"))
                if q_s is not None:
                    job_queue_by_cohort["all_non_skipped"].append(q_s)
                    wf_entry["cohorts"]["all_non_skipped"]["queue_wait"].append(q_s)
                    if j_conc in job_queue_by_cohort:
                        job_queue_by_cohort[j_conc].append(q_s)
                    if j_conc in wf_entry["cohorts"]:
                        wf_entry["cohorts"][j_conc]["queue_wait"].append(q_s)
                if e_s is not None:
                    job_exec_by_cohort["all_non_skipped"].append(e_s)
                    wf_entry["cohorts"]["all_non_skipped"]["execution"].append(e_s)
                    if j_conc in job_exec_by_cohort:
                        job_exec_by_cohort[j_conc].append(e_s)
                    if j_conc in wf_entry["cohorts"]:
                        wf_entry["cohorts"][j_conc]["execution"].append(e_s)
                r_cls = _classify_runner_class(job.get("runner_name"))
                cls_bucket = runner_class_buckets.setdefault(
                    r_cls,
                    {c: {"queue_wait": [], "execution": []} for c in COHORT_NAMES},
                )
                if q_s is not None:
                    cls_bucket["all_non_skipped"]["queue_wait"].append(q_s)
                    if j_conc in cls_bucket:
                        cls_bucket[j_conc]["queue_wait"].append(q_s)
                if e_s is not None:
                    cls_bucket["all_non_skipped"]["execution"].append(e_s)
                    if j_conc in cls_bucket:
                        cls_bucket[j_conc]["execution"].append(e_s)

        repo_summaries.append({
            "repo": repo,
            "non_skipped_runs": repo_non_skipped,
            "cancelled_runs": repo_cancelled,
            "e2e_success": compute_stats(repo_e2e_success),
        })

    # Choose a single consistent cohort for headline clocks rather than mixing cohorts.
    has_success_cohort = bool(
        job_queue_by_cohort["success"] and job_exec_by_cohort["success"] and run_e2e_by_cohort["success"]
    )
    headline_cohort = "success" if has_success_cohort else "all_non_skipped"

    workflows = []
    for (repo, wf_name), bucket in wf_buckets.items():
        wf_cohorts = {
            c: {
                "queue_wait": compute_stats(bucket["cohorts"][c]["queue_wait"]),
                "execution": compute_stats(bucket["cohorts"][c]["execution"]),
                "e2e": compute_stats(bucket["cohorts"][c]["e2e"]),
            }
            for c in COHORT_NAMES
        }
        primary = wf_cohorts["success"] if wf_cohorts["success"]["execution"]["n"] > 0 else wf_cohorts["all_non_skipped"]
        if primary["queue_wait"]["n"] == 0 and primary["execution"]["n"] == 0 and primary["e2e"]["n"] == 0:
            continue
        workflows.append({
            "repo": repo,
            "workflow": wf_name,
            "n_runs": bucket["n_runs"],
            "cohort": "success" if wf_cohorts["success"]["execution"]["n"] > 0 else "all_non_skipped",
            "queue_wait": primary["queue_wait"],
            "execution": primary["execution"],
            "e2e": primary["e2e"],
            "cohorts": wf_cohorts,
        })
    workflows.sort(
        key=lambda item: (item["execution"]["p90_s"] or item["e2e"]["p90_s"] or 0.0, item["n_runs"]),
        reverse=True,
    )

    cancelled_pct = (
        round((cancelled_runs / total_non_skipped_runs) * 100.0, 1)
        if total_non_skipped_runs > 0
        else None
    )

    runner_classes = {}
    for cls, vals in sorted(runner_class_buckets.items()):
        cohorts_blk = {
            c: {
                "queue_wait": compute_stats(vals[c]["queue_wait"]),
                "execution": compute_stats(vals[c]["execution"]),
            }
            for c in COHORT_NAMES
        }
        pref = cohorts_blk[headline_cohort] if cohorts_blk[headline_cohort]["execution"]["n"] > 0 else cohorts_blk["all_non_skipped"]
        runner_classes[cls] = {
            "queue_wait": pref["queue_wait"],
            "execution": pref["execution"],
            "cohorts": cohorts_blk,
        }

    return {
        "schema_version": 1,
        "ok": True,
        "partial": bool(timed_out_runs or failed_job_fetches),
        "timed_out_runs": timed_out_runs,
        "failed_job_fetches": failed_job_fetches,
        "cohort": headline_cohort,
        "generated_at": generated_at,
        "overall": {
            "cohort": headline_cohort,
            "queue_wait": compute_stats(job_queue_by_cohort[headline_cohort]),
            "execution": compute_stats(job_exec_by_cohort[headline_cohort]),
            "e2e": compute_stats(run_e2e_by_cohort[headline_cohort]),
        },
        "cohorts": {
            cohort: {
                "queue_wait": compute_stats(job_queue_by_cohort[cohort]),
                "execution": compute_stats(job_exec_by_cohort[cohort]),
                "e2e": compute_stats(run_e2e_by_cohort[cohort]),
            }
            for cohort in COHORT_NAMES
        },
        "cancellation": {
            "cancelled_runs": cancelled_runs,
            "skipped_runs": skipped_runs,
            "total_non_skipped_runs": total_non_skipped_runs,
            "cancelled_rate_pct": cancelled_pct,
        },
        "runner_classes": runner_classes,
        "by_runner_class": runner_classes,
        "workflows": workflows,
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


def iter_audit_repo_blocks(raw):
    """Yield (repo_slug, block_dict) entries from a pre-collected audit JSON."""
    if not isinstance(raw, dict):
        return
    for key, val in raw.items():
        if not isinstance(val, dict):
            continue
        if any(k in val for k in ("recent_contiguous_runs", "recent_runs", "job_level_audit")):
            slug = val.get("repo") or _AUDIT_REPO_ALIASES.get(key) or key
            yield slug, val


def from_audit_data(raw):
    """Normalize a pre-collected ci_latency_percentiles dict into canonical probe shape."""
    if not isinstance(raw, dict):
        return {"schema_version": 1, "ok": False, "overall": {}, "cohorts": {}, "cancellation": {}, "workflows": []}
    repo_blocks = list(iter_audit_repo_blocks(raw))
    primary_slug, primary = repo_blocks[0] if repo_blocks else (None, {})
    recent = primary.get("recent_contiguous_runs") or primary.get("recent_runs") or {}
    cohorts = recent.get("cohorts") or {}
    job_audit = primary.get("job_level_audit") or {}
    job_cohorts = job_audit.get("job_cohorts") or {}

    cohorts_out = {}
    for c in COHORT_NAMES:
        jc = job_cohorts.get(c) or {}
        rc = cohorts.get(c) or {}
        cohorts_out[c] = {
            "queue_wait": _pick_stat_block(jc.get("queue_wait")),
            "execution": _pick_stat_block(jc.get("execution")),
            "job_total": _pick_stat_block(jc.get("total")),
            "e2e": _pick_stat_block(rc),
        }

    headline_cohort = "success" if cohorts_out["success"]["execution"]["n"] > 0 else "all_non_skipped"

    # Aggregate cancellation across all audited repo blocks rather than dropping repos after [0]
    cancelled_n = 0
    skipped_n = 0
    total_non_skipped = 0
    for _slug, block in repo_blocks:
        r_rec = block.get("recent_contiguous_runs") or block.get("recent_runs") or {}
        r_coh = r_rec.get("cohorts") or {}
        cancelled_n += (r_coh.get("cancelled") or {}).get("n") or 0
        skipped_n += r_rec.get("skipped_or_neutral_runs") or 0
        total_non_skipped += (r_coh.get("all_non_skipped") or {}).get("n") or 0
    cancelled_pct = (
        round((cancelled_n / total_non_skipped) * 100.0, 1)
        if total_non_skipped > 0
        else None
    )

    workflows = []
    for repo_slug, repo_block in repo_blocks:
        r_recent = repo_block.get("recent_contiguous_runs") or repo_block.get("recent_runs") or {}
        r_wf_map = {
            wf["workflow"]: wf
            for wf in (r_recent.get("by_workflow") or [])
            if isinstance(wf, dict) and isinstance(wf.get("workflow"), str)
        }
        r_jobs = repo_block.get("job_level_audit") or {}
        for wf in r_jobs.get("by_workflow") or []:
            if not isinstance(wf, dict) or not isinstance(wf.get("workflow"), str):
                continue
            r_match = r_wf_map.get(wf["workflow"]) or {}
            wf_cohorts = {}
            for c in COHORT_NAMES:
                c_data = wf.get(c) or {}
                wf_cohorts[c] = {
                    "queue_wait": _pick_stat_block(c_data.get("queue_wait")),
                    "execution": _pick_stat_block(c_data.get("execution")),
                    "job_total": _pick_stat_block(c_data.get("total")),
                    # Never substitute job wall time for run-level E2E wall time
                    "e2e": _pick_stat_block(r_match.get(c)),
                }
            pref = wf_cohorts["success"] if wf_cohorts["success"]["execution"]["n"] > 0 else wf_cohorts["all_non_skipped"]
            if pref["queue_wait"]["n"] == 0 and pref["execution"]["n"] == 0 and pref["e2e"]["n"] == 0:
                continue
            workflows.append({
                "repo": repo_slug,
                "workflow": wf["workflow"],
                "cohort": "success" if wf_cohorts["success"]["execution"]["n"] > 0 else "all_non_skipped",
                "queue_wait": pref["queue_wait"],
                "execution": pref["execution"],
                "e2e": pref["e2e"],
                "cohorts": wf_cohorts,
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
        cohorts_blk = {}
        for c in COHORT_NAMES:
            c_raw = cls_data.get(c) or {}
            cohorts_blk[c] = {
                "queue_wait": _pick_stat_block(c_raw.get("queue_wait")),
                "execution": _pick_stat_block(c_raw.get("execution")),
            }
        pref = (
            cohorts_blk[headline_cohort]
            if cohorts_blk[headline_cohort]["execution"]["n"] > 0
            else cohorts_blk["all_non_skipped"]
        )
        runner_classes[cls] = {
            "queue_wait": pref["queue_wait"],
            "execution": pref["execution"],
            "cohorts": cohorts_blk,
        }

    return {
        "schema_version": 1,
        "ok": bool(cohorts_out["success"]["execution"]["n"] or cohorts_out["success"]["e2e"]["n"] or workflows),
        "partial": False,
        "cohort": headline_cohort,
        "overall_scope": primary_slug,
        "generated_at": raw.get("generated_at_utc"),
        "overall": {
            "cohort": headline_cohort,
            "scope_repo": primary_slug,
            "queue_wait": cohorts_out[headline_cohort]["queue_wait"],
            "execution": cohorts_out[headline_cohort]["execution"],
            "e2e": cohorts_out[headline_cohort]["e2e"],
        },
        "cohorts": cohorts_out,
        "pr_critical_path": recent.get("pr_critical_path_turnaround") or {},
        "cancellation": {
            "cancelled_runs": cancelled_n,
            "skipped_runs": skipped_n,
            "total_non_skipped_runs": total_non_skipped,
            "cancelled_rate_pct": cancelled_pct,
        },
        "runner_classes": runner_classes,
        "by_runner_class": runner_classes,
        "step_categories": step_cats,
        "workflows": workflows,
    }


def from_audit_json(path):
    """Normalize a pre-collected ci_latency_percentiles.json into canonical probe shape."""
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    return from_audit_data(raw)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", action="append", default=None, help="org/repo to probe")
    parser.add_argument("--from-audit-json", default=None, help="Normalize pre-collected audit JSON")
    parser.add_argument("--classify-phase", default=None, help="Classify process command string and print phase tag")
    parser.add_argument("--limit", type=int, default=40)
    parser.add_argument("--job-run-limit", type=int, default=20)
    parser.add_argument("--output", default=None)
    args = parser.parse_args()

    if args.classify_phase is not None:
        tag = classify_phase(args.classify_phase)
        if tag:
            sys.stdout.write(tag + "\n")
        return 0

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
