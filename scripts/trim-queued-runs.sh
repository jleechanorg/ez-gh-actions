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
# ── Python body as a TRACKED sibling file (bead jleechan-queue-trimmer-heredoc-deadlock) ──
# History: the original shape was `python3 -u <<'PY' ... PY 2>&1 | sed ...`. Commit 250f26b tried
# to fix a 15h48m deadlock by writing the body with `cat > "$PY_BODY" <<'PY'` — but that is STILL a
# heredoc writer, so it wedged again (observed live 2026-11-13: bash blocked in heredoc_write for
# 30+ min, $PY_BODY 0 bytes, python never exec'd). REPO_TIMEOUT_S could not bound it because the
# wedge happens before the bounded python call.
#
# Fix: the body is a tracked file, exec'd directly. There is no heredoc writer at all, so there is
# nothing to block in. REPO_TIMEOUT_S still bounds the real work.
PY_BODY="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/trim_queued_runs.py"
if [[ ! -r "$PY_BODY" ]]; then
  echo "FATAL: missing python body: $PY_BODY" >&2
  echo "       (install must copy scripts/trim_queued_runs.py beside this script)" >&2
  exit 2
fi

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

  QUEUE_REPO="$repo" ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} python3 -u "$PY_BODY" 2>&1 | sed -u "s#^#[${repo}] #" || repo_rc=$?

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
