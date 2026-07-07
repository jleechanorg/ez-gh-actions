#!/usr/bin/env bash
# queue-reaper-stopgap.sh — STOPGAP ONLY, remove when the Rust-native reaper
# (bead ez-gh-actions-qbl) + periodic-reaper design (bead ez-gh-actions-7ap,
# owned by the jeff-ubuntu mission) lands and is deployed on both machines.
#
# Calls cleanup-stuck-runs.sh --tail --apply with FRESH_TAIL_MIN=20 on a
# schedule (see launchd/org.jleechanorg.ezgha-queue-reaper-stopgap.plist.template)
# so the worldarchitect.ai self-hosted queue tail doesn't silently regrow past
# the 20-minute health threshold between manual/agent-driven cleanup passes.
#
# 20-minute threshold + repeated --apply cancellation of fresh-tail queued
# runs on active PRs is pre-authorized per the 2026-07-07
# runner-queue-healthy-mac mission (user directive: "cancel actions over 20
# min"). Do not widen scope (e.g. add --zombies/--superseded here) without
# separate authorization — this script intentionally does ONLY the pre-authorized
# --tail lever.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${HOME}/Library/Logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ezgha-queue-reaper-stopgap.log"

{
  echo "=== $(date -u +%FT%TZ) queue-reaper-stopgap tick ==="
  cd "$REPO_DIR"
  # cleanup-stuck-runs.sh exits 1 whenever ANY individual cancel fails, which
  # includes the expected/benign race where a queued run completes or gets
  # cancelled naturally between the scan and the cancel call (see
  # tail_failed count in its own summary line) — that is normal steady-state
  # for a periodic reaper, not a wrapper failure, so don't let `set -e` above
  # swallow the completion marker over a partial-failure exit code.
  rc=0
  FRESH_TAIL_MIN=20 ./scripts/cleanup-stuck-runs.sh --tail --apply || rc=$?
  echo "=== $(date -u +%FT%TZ) tick complete (cleanup-stuck-runs.sh exit=$rc) ==="
} >> "$LOG_FILE" 2>&1
