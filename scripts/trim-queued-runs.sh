#!/usr/bin/env bash
# trim-queued-runs.sh — periodically trim redundant or stale queued CI runs.
#
# Cancels queued runs in target repos matching any of:
#   1. PR not modified in >= MIN_PR_AGE_HOURS (default: 2 hours).
#   2. PR is in DRAFT state (drafts should not block ready PRs).
#   3. Superseded commit: remote branch HEAD has advanced past the run's commit.
#
# Safety invariants:
#   - In-progress runs are NEVER touched.
#   - Deploy workflows (deploy-production, auto-deploy-dev) are NEVER touched.
#   - Status is rechecked immediately before cancellation to prevent races.
#   - Dry-run by default; requires --apply to perform cancellations.
#
# Usage:
#   ./scripts/trim-queued-runs.sh                 # dry-run across default repos
#   ./scripts/trim-queued-runs.sh --apply         # cancel matching queued runs
#   ./scripts/trim-queued-runs.sh --min-pr-age-hours 3 --apply
#   ./scripts/trim-queued-runs.sh --no-trim-drafts --apply
#
# Env overrides:
#   QUEUE_REPOS="owner/repo1 owner/repo2"
#   MIN_PR_AGE_HOURS=2
#   TRIM_DRAFTS=1
#   TRIM_SUPERSEDED=1
#   CANCEL_VERIFY_WAIT_S=10
#   REPO_TIMEOUT_S=420   per-repo wall-clock cap (see "Bounded per-repo pass")
set -euo pipefail

PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"
export PATH
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER=""

if [[ -z "${GH_TOKEN:-}" && -f "${HOME}/.config/ezgha/gh_token" ]]; then
  ezgha_tok="$(<"${HOME}/.config/ezgha/gh_token")"
  if [[ -n "$ezgha_tok" ]]; then
    export GH_TOKEN="$ezgha_tok"
  fi
fi

DEFAULT_QUEUE_REPOS="jleechanorg/worldarchitect.ai jleechanorg/ez-gh-actions jleechanorg/worldai_frontend"
QUEUE_REPOS="${QUEUE_REPOS:-$DEFAULT_QUEUE_REPOS}"
MIN_PR_AGE_HOURS="${MIN_PR_AGE_HOURS:-2}"
TRIM_DRAFTS="${TRIM_DRAFTS:-1}"
TRIM_SUPERSEDED="${TRIM_SUPERSEDED:-1}"
CANCEL_VERIFY_WAIT_S="${CANCEL_VERIFY_WAIT_S:-10}"
DRY_RUN=1

usage() {
  sed -n '2,24p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      DRY_RUN=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --min-pr-age-hours)
      MIN_PR_AGE_HOURS="${2:?missing hours}"
      shift 2
      ;;
    --repos)
      QUEUE_REPOS="${2:?missing repos}"
      shift 2
      ;;
    --trim-drafts)
      TRIM_DRAFTS=1
      shift
      ;;
    --no-trim-drafts)
      TRIM_DRAFTS=0
      shift
      ;;
    --trim-superseded)
      TRIM_SUPERSEDED=1
      shift
      ;;
    --no-trim-superseded)
      TRIM_SUPERSEDED=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "requires gh and python3" >&2
  exit 2
fi

export MIN_PR_AGE_HOURS TRIM_DRAFTS TRIM_SUPERSEDED CANCEL_VERIFY_WAIT_S DRY_RUN

# ── Bounded per-repo pass (bead jleechan-queue-trimmer-heredoc-deadlock) ─────
# The original shape was `python3 -u <<'PY' ... PY 2>&1 | sed ...`. A heredoc
# writing into a pipeline deadlocks when the reader on the other end goes away:
# measured 2026-11-07, this job sat 15h48m in heredoc_write() with 900/900
# samples in `write()`, its python3 child already gone, while `sed` still held
# the pipe's read end. `launchctl` reported `state = running, last exit 0` the
# whole time, so nothing noticed.
#
# Two independent changes remove that failure mode:
#   1. Write the python body to a file and exec it. There is no heredoc writer,
#      so there is no heredoc_write() to block in. The pipe then belongs to
#      python3 -> sed, which cannot deadlock on itself.
#   2. Cap each repo's wall clock. A wedged repo is a FAILED repo (the loop
#      already tolerates per-repo failure), never an unbounded hang.
# Both are asserted by tests/trim_queued_runs_bounded_pass_test.sh.
REPO_TIMEOUT_S="${REPO_TIMEOUT_S:-420}"
# mktemp template: the X's MUST be last. BSD/macOS mktemp does not substitute a
# template whose X's are followed by a suffix — it returns the literal path,
# which made every concurrent tick share one file (caught by
# tests/trim_queued_runs_test.sh). python does not need a .py suffix.
PY_BODY="$(mktemp "${TMPDIR:-/tmp}/trim-queued-runs.XXXXXX")"
trap 'rm -f "${PY_BODY:?}"' EXIT
cat > "$PY_BODY" <<'PY'
import datetime
import json
import os
import subprocess
import sys
import time

repo = os.environ["QUEUE_REPO"]
min_pr_age_hours = float(os.environ["MIN_PR_AGE_HOURS"])
trim_drafts = os.environ.get("TRIM_DRAFTS", "1") == "1"
trim_superseded = os.environ.get("TRIM_SUPERSEDED", "1") == "1"
dry = os.environ.get("DRY_RUN") == "1"
verify_wait_s = float(os.environ.get("CANCEL_VERIFY_WAIT_S", "10"))

NEVER_CANCEL_PATHS = {
    ".github/workflows/deploy-production.yml",
    ".github/workflows/auto-deploy-dev.yml",
}

def gh_cmd(args):
    cmd = ["gh"] + args
    return subprocess.check_output(cmd, stderr=subprocess.STDOUT)

def gh_json(args):
    raw = gh_cmd(args)
    return json.loads(raw) if raw.strip() else None

def is_rate_limited(err):
    out = (err.output or b"").lower()
    return b"rate limit" in out or b"secondary rate limit" in out or b"403" in out

def list_queued_runs():
    runs = []
    page = 1
    while page <= 3:
        try:
            data = gh_json([
                "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
            ])
        except subprocess.CalledProcessError as e:
            if is_rate_limited(e):
                print("rate-limited listing /actions/runs; backing off 60s and retrying once")
                time.sleep(60)
                try:
                    data = gh_json([
                        "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
                    ])
                except subprocess.CalledProcessError as e2:
                    if is_rate_limited(e2):
                        print("SKIP: /actions/runs rate-limited after backoff — skipping repo tick")
                        return []
                    raise
            else:
                raise
        batch = data.get("workflow_runs", []) if data else []
        if not batch:
            break
        runs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return runs

def get_remote_head(branch):
    try:
        out = subprocess.check_output([
            "git", "ls-remote", f"https://github.com/{repo}.git", f"refs/heads/{branch}"
        ], stderr=subprocess.DEVNULL, text=True).strip()
        if out:
            return out.split()[0]
    except Exception:
        pass
    return None

def get_commit_date(sha):
    try:
        out = gh_cmd(["api", f"repos/{repo}/commits/{sha}", "--jq", ".commit.committer.date"]).decode().strip()
        if out:
            return datetime.datetime.fromisoformat(out.replace("Z", "+00:00"))
    except Exception:
        pass
    return None

def run_status(rid):
    out = gh_cmd(["api", f"repos/{repo}/actions/runs/{rid}", "--jq", ".status"]).decode().strip()
    return out

def cancel_run(rid):
    gh_cmd(["api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/cancel"])

def force_cancel_run(rid):
    gh_cmd(["api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/force-cancel"])

def verify_and_force_cancel(rid):
    if verify_wait_s > 0:
        time.sleep(verify_wait_s)
    try:
        status = run_status(rid)
    except subprocess.CalledProcessError:
        return False
    if status == "queued":
        force_cancel_run(rid)
        return True
    return False

now = datetime.datetime.now(datetime.timezone.utc)
all_queued = list_queued_runs()
eligible_runs = [r for r in all_queued if r.get("path") not in NEVER_CANCEL_PATHS]

print(f"scan: repo={repo} queued_total={len(all_queued)} eligible={len(eligible_runs)} mode={'dry-run' if dry else 'apply'}")

if not eligible_runs:
    sys.exit(0)

# Pre-fetch PR and remote HEAD info per branch to minimize API calls
branches = sorted(list(set(r.get("head_branch") for r in eligible_runs if r.get("head_branch"))))
branch_info = {}
commit_dates = {}

for b in branches:
    remote_head = get_remote_head(b)
    pr_data = None
    if b not in ("main", "master"):
        try:
            prs = gh_json(["pr", "list", "--repo", repo, "--head", b, "--state", "open", "--json", "number,title,isDraft,updatedAt,headRefOid"])
            if prs:
                pr_data = prs[0]
        except Exception:
            pass
    branch_info[b] = {
        "remote_head": remote_head,
        "pr": pr_data,
    }

# Find newest queued ios-testflight run on main/master to avoid cancelling the current candidate
newest_testflight_main_id = {}
for r in eligible_runs:
    if (r.get("path") == ".github/workflows/ios-testflight.yml" and
            r.get("head_branch") in ("main", "master") and
            r.get("event", "push") == "push"):
        hb = r.get("head_branch")
        cur_max = newest_testflight_main_id.get(hb, -1)
        if r.get("id", 0) > cur_max:
            newest_testflight_main_id[hb] = r.get("id", 0)

candidates = []

for r in eligible_runs:
    b = r.get("head_branch")
    if not b:
        continue
    info = branch_info.get(b)
    if not info:
        continue

    run_sha = r.get("head_sha")
    remote_head = info["remote_head"]
    pr = info["pr"]

    # Special case: iOS TestFlight runs on main/master
    if r.get("path") == ".github/workflows/ios-testflight.yml" and b in ("main", "master"):
        if trim_superseded and r.get("event", "push") == "push":
            max_id = newest_testflight_main_id.get(b)
            is_superseded_sha = bool(remote_head and run_sha and run_sha != remote_head)
            is_superseded_queue = bool(max_id and r.get("id", 0) < max_id)
            if is_superseded_sha or is_superseded_queue:
                reasons = []
                if is_superseded_sha:
                    reasons.append(f"run_sha={run_sha[:8]} != remote_head={remote_head[:8]}")
                if is_superseded_queue:
                    reasons.append(f"newer_queued_id={max_id}")
                candidates.append((r, f"superseded_main_build ({', '.join(reasons)})"))
        continue

    if b in ("main", "master"):
        continue

    # Reason 1: Superseded commit on branch
    if trim_superseded and remote_head and run_sha and run_sha != remote_head:
        candidates.append((r, f"superseded_commit (run_sha={run_sha[:8]} != branch_head={remote_head[:8]})"))
        continue

    if not pr:
        continue

    # Reason 2: Draft PR
    if trim_drafts and pr.get("isDraft"):
        candidates.append((r, f"draft_pr (PR #{pr['number']} is draft)"))
        continue

    # Reason 3: PR not modified in last MIN_PR_AGE_HOURS
    pr_updated_str = pr.get("updatedAt", "")
    pr_updated_dt = datetime.datetime.fromisoformat(pr_updated_str.replace("Z", "+00:00")) if pr_updated_str else None
    
    # Check commit committer date
    if run_sha not in commit_dates:
        commit_dates[run_sha] = get_commit_date(run_sha)
    commit_dt = commit_dates.get(run_sha)

    # Consider unmodified if commit date is >= min_pr_age_hours old
    ref_dt = commit_dt or pr_updated_dt
    if ref_dt:
        age_hours = (now - ref_dt).total_seconds() / 3600.0
        if age_hours >= min_pr_age_hours:
            candidates.append((r, f"unmodified_pr (PR #{pr['number']} last code/update was {age_hours:.1f}h ago >= {min_pr_age_hours:g}h)"))
            continue

print(f"candidates_identified: {len(candidates)}")

cancelled = 0
failed = 0
skipped_non_queued = 0

for r, reason in candidates:
    rid = r["id"]
    name = r.get("name") or f"id={rid}"
    b = r.get("head_branch")
    url = r.get("html_url") or f"https://github.com/{repo}/actions/runs/{rid}"

    if dry:
        print(f"[dry-run] would cancel {rid} ({name}) on branch '{b}': {reason} — {url}")
        continue

    # Recheck status to guard against race with worker pickup
    try:
        cur_status = run_status(rid)
        if cur_status != "queued":
            skipped_non_queued += 1
            print(f"skipped {rid}: no longer queued (now {cur_status})")
            continue
    except subprocess.CalledProcessError:
        pass

    try:
        cancel_run(rid)
        cancelled += 1
        print(f"cancelled {rid} ({name}) on branch '{b}': {reason} — {url}")
        try:
            if verify_and_force_cancel(rid):
                print(f"force-cancelled {rid}: survived plain cancel")
        except Exception as e:
            print(f"verify/force-cancel notice for {rid}: {e}")
    except subprocess.CalledProcessError as e:
        failed += 1
        print(f"FAIL cancel {rid}: {(e.output or b'').decode()[:120]}")
    time.sleep(0.35)

print(f"summary: candidates={len(candidates)} cancelled={cancelled} failed={failed} skipped_non_queued={skipped_non_queued} dry_run={dry}")
if failed:
    sys.exit(1)
PY

FAILED_REPOS=()
TIMED_OUT_REPOS=()
REPO_COUNT=0

for repo in $QUEUE_REPOS; do
  [[ -z "$repo" ]] && continue
  REPO_COUNT=$((REPO_COUNT + 1))
  repo_rc=0

  # `timeout` is GNU coreutils on Linux and gtimeout (brew coreutils) on macOS,
  # where plain `timeout` may be absent. Fall back to an unbounded run only if
  # neither exists, rather than silently disabling the cap.
  #
  # macOS ships bash 3.2, where expanding an EMPTY array as "${A[@]}" under
  # `set -u` is an unbound-variable ERROR (fixed only in bash 4.4+). Using
  # "${TIMEOUT_CMD[@]}" unconditionally therefore aborted EVERY repo pass on a
  # host without `timeout`, while the loop still printed "N repo(s) scanned,
  # 0 failed" and exited 0 -- a silent no-op reported as success. Measured on
  # /bin/bash 3.2 with two repos: zero python executions, exit 0. The
  # "${A[@]+"${A[@]}"}" form expands to nothing when unset/empty and to the
  # elements otherwise, on bash 3.2 and 5.x alike, so the fallback actually runs
  # unbounded instead of doing nothing. Asserted by
  # tests/trim_queued_runs_bounded_pass_test.sh (no-timeout-binary arm).
  TIMEOUT_CMD=()
  TIMEOUT_BIN=""
  for candidate in timeout gtimeout; do
    # `command -v` alone is not enough: it reports a non-executable file on PATH
    # as a command, so a mode-644 placeholder on PATH would be "found" and then
    # fail at exec time. Require an actual executable resolved path.
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
      TIMEOUT_CMD=("$resolved" --kill-after=30s "$REPO_TIMEOUT_S")
      TIMEOUT_BIN="$candidate"
      break
    fi
  done
  if [[ ${#TIMEOUT_CMD[@]} -eq 0 ]]; then
    echo "[$repo] WARN: neither timeout nor gtimeout found; repo pass is unbounded" >&2
  fi

  QUEUE_REPO="$repo" ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} python3 -u "$PY_BODY" 2>&1 | sed "s#^#[${repo}] #" || repo_rc=$?

  if [[ "$repo_rc" -ne 0 ]]; then
    # 124/137 = timeout expired / killed after --kill-after. Name it explicitly:
    # a bounded stall is a distinct defect from a failing pass, and the previous
    # unbounded shape made it indistinguishable from "still working".
    if [[ "$repo_rc" -eq 124 || "$repo_rc" -eq 137 ]]; then
      echo "[$repo] trim pass TIMED OUT after ${REPO_TIMEOUT_S}s (exit=$repo_rc) — continuing to next repo"
      TIMED_OUT_REPOS+=("$repo")
    else
      echo "[$repo] trim pass FAILED (exit=$repo_rc) — continuing to next repo"
    fi
    FAILED_REPOS+=("$repo")
  fi
done

echo "=== overall: ${REPO_COUNT} repo(s) scanned, ${#FAILED_REPOS[@]} failed: ${FAILED_REPOS[*]:-none} (timed out: ${TIMED_OUT_REPOS[*]:-none}) ==="
if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  exit 1
fi
