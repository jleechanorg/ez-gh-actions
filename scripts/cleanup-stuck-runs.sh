#!/usr/bin/env bash
# cleanup-stuck-runs.sh — report or remove GitHub Actions queue artifacts,
# across multiple repos.
#
# Three classes of "stuck" runs per repo in QUEUE_REPOS:
#   1. Zombies (>STALE_HOURS old, status=queued) — GitHub rejects DELETE on a
#      queued run (HTTP 403); cancel first (-> completed/cancelled), then delete.
#   2. Superseded queued runs — same branch + workflow, keeping the newest queued run.
#   3. Fresh tail (>FRESH_TAIL_MIN old, still queued) — cancel via API (drops CI for that PR).
#
# Multi-repo coverage (ez-gh-actions-ssjg): QUEUE_REPOS is a space-separated
# list, scanned in a loop. A failing repo is logged and counted but does NOT
# abort the loop — every repo in the list gets its own attempt every tick.
# QUEUE_REPO (singular) remains supported for back-compat with other scripts
# (queue-health.sh, queue-backlog-drain.sh) that set a single override repo;
# if only QUEUE_REPO is set, it becomes a one-element QUEUE_REPOS list.
#
# Force-cancel fallback (jleechan-uud): plain POST .../cancel returns HTTP 202
# but silently no-ops on runs whose only job never started (runner_id:0).
# After any cancel (superseded or tail), this script verifies ~20s later
# (CANCEL_VERIFY_WAIT_S) that the run actually left "queued"; if not, it
# retries via POST .../force-cancel. This verify+force-cancel happens
# synchronously per-run at the moment of that specific cancel call — not via
# same-tick batch-list membership, which previously let a run wedged in one
# tick survive every later tick forever (the plain cancel keeps returning 202
# and no-oping on it).
#
# Usage:
#   ./scripts/cleanup-stuck-runs.sh                 # dry-run: zombies + superseded queued runs
#   ./scripts/cleanup-stuck-runs.sh --apply          # delete zombies + cancel superseded queued runs
#   ./scripts/cleanup-stuck-runs.sh --zombies        # dry-run: only >STALE_HOURS artifacts
#   ./scripts/cleanup-stuck-runs.sh --superseded     # dry-run: only older queued runs by branch+workflow
#   ./scripts/cleanup-stuck-runs.sh --tail --apply   # cancel fresh tail >45m; intentionally opt-in
#
# Env overrides:
#   QUEUE_REPOS="owner/repo1 owner/repo2 ..."  # space-separated; default: see DEFAULT_QUEUE_REPOS below
#   QUEUE_REPO="owner/repo"                    # single-repo back-compat override (ignored if QUEUE_REPOS set)
#   CANCEL_VERIFY_WAIT_S=20                    # seconds to wait before force-cancel verify (0 to skip wait, e.g. tests)
#   DO_UNSCHEDULABLE=1                         # report queued runs whose labels no online runner carries (default 1)
#   UNSCHED_MIN_AGE_MIN=15                     # only report unschedulable runs queued at least this long
set -euo pipefail

DEFAULT_QUEUE_REPOS="jleechanorg/worldarchitect.ai jleechanorg/ai_universe jleechanorg/worldai_claw jleechanorg/mctrl_test jleechanorg/jleechanclaw jleechanorg/ai_universe_living_blog jleechanorg/agent-orchestrator jleechanorg/dark-factory jleechanorg/ez-gh-actions jleechanorg/user_scope"
QUEUE_REPOS="${QUEUE_REPOS:-${QUEUE_REPO:-$DEFAULT_QUEUE_REPOS}}"
STALE_HOURS="${STALE_HOURS:-8}"
FRESH_TAIL_MIN="${FRESH_TAIL_MIN:-45}"
CANCEL_VERIFY_WAIT_S="${CANCEL_VERIFY_WAIT_S:-20}"
DRY_RUN=1
DO_ZOMBIES=1
DO_SUPERSEDED=1
DO_TAIL=0
EXPLICIT_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zombies)
      if [[ "$EXPLICIT_MODE" -eq 0 ]]; then DO_ZOMBIES=0; DO_SUPERSEDED=0; DO_TAIL=0; fi
      DO_ZOMBIES=1; EXPLICIT_MODE=1; shift ;;
    --superseded)
      if [[ "$EXPLICIT_MODE" -eq 0 ]]; then DO_ZOMBIES=0; DO_SUPERSEDED=0; DO_TAIL=0; fi
      DO_SUPERSEDED=1; EXPLICIT_MODE=1; shift ;;
    --tail)
      if [[ "$EXPLICIT_MODE" -eq 0 ]]; then DO_ZOMBIES=0; DO_SUPERSEDED=0; DO_TAIL=0; fi
      DO_TAIL=1; EXPLICIT_MODE=1; shift ;;
    --apply) DRY_RUN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,29p' "$0"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "requires gh and python3" >&2
  exit 2
fi

export STALE_HOURS FRESH_TAIL_MIN DRY_RUN DO_ZOMBIES DO_SUPERSEDED DO_TAIL CANCEL_VERIFY_WAIT_S

FAILED_REPOS=()
REPO_COUNT=0

# Python body as a TRACKED sibling (same fix as trim-queued-runs.sh, bead
# jleechan-queue-trimmer-heredoc-deadlock). The original shape was
# `python3 <<'PY' ... PY | sed`, a heredoc writer that deadlocks when the
# reader goes away. Exec'ing a real file removes heredoc_write() entirely.
PY_BODY="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/cleanup_stuck_runs.py"
if [[ ! -r "$PY_BODY" ]]; then
  echo "FATAL: missing python body: $PY_BODY" >&2
  echo "       (install must copy scripts/cleanup_stuck_runs.py beside this script)" >&2
  exit 2
fi

for repo in $QUEUE_REPOS; do
  [[ -z "$repo" ]] && continue
  REPO_COUNT=$((REPO_COUNT + 1))
  repo_rc=0

  QUEUE_REPO="$repo" python3 -u "$PY_BODY" 2>&1 | sed -u "s#^#[${repo}] #" || repo_rc=$?

  if [[ "$repo_rc" -ne 0 ]]; then
    echo "[$repo] cleanup pass FAILED (exit=$repo_rc) — continuing to next repo"
    FAILED_REPOS+=("$repo")
  fi
done

echo "=== overall: ${REPO_COUNT} repo(s) scanned, ${#FAILED_REPOS[@]} failed: ${FAILED_REPOS[*]:-none} ==="
if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  exit 1
fi
