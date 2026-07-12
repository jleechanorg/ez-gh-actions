#!/usr/bin/env bash
# regression test: when the REMOTE half of the fleet is unreachable via SSH,
# the verdict must (a) keep `configured` at the FULL expected fleet size
# (not silently collapse to local-only), (b) count every unreachable slot
# in the `down` bucket (so the headline reads "16/22 healthy, 6 down"
# instead of "16/16 healthy"), and (c) flip the verdict from `ok` to
# `bad` (an unreachable half of the fleet cannot silently green).
#
# P1 #2 from PR #64 cold review: the prior code's unreachable branch
# left REMOTE_EXECUTING_SLOTS/IDLE_SLOTS/CYCLING_SLOTS/DOWN_SLOTS=()
# empty, so the call site's `configured = sum(local) + sum(remote)`
# collapsed to local-only. A Linux run with Mac unreachable reported
# `fleet healthy: 16/16 healthy: 16 executing ... 0 down` instead of
# `16/22 healthy: 16 executing ... 6 down`.
#
# This test extracts two real fragments from doctor-runner and exercises
# them against a fixture unreachable-host scenario:
#   (a) the unreachable-branch math (REMOTE_COUNT synthetic-DOWN entries
#       are added, so configured and down reflect the remote host).
#   (b) the grep-level assertion that the unreachable path emits a
#       [BAD] line and SLOT_PROOF_CRITICAL is incremented (so the
#       verdict flips from "fleet healthy: ..." to "fleet unhealthy: ..."
#       via exit 1).
#
# Usage: bash tests/doctor_runner_unreachable_remote_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

echo "--- doctor-runner unreachable-remote verdict regression ---"
OVERALL_PASS=true

# --- Assertion 1: the unreachable branch synthesizes REMOTE_DOWN_SLOTS ---
# Pre-fix the unreachable branch only printed `warn ... skipping remote
# per-slot proof` and left REMOTE_*_SLOTS empty, so the call site's
# `configured = sum(local) + sum(remote)` collapsed to local-only.
# Post-fix the unreachable branch populates REMOTE_DOWN_SLOTS with
# REMOTE_COUNT synthetic entries (so `configured` stays at the full
# fleet size and the headline `down` reflects the unproven remote slots).
if ! grep -q 'REMOTE_UNREACHABLE=1' "$DOCTOR_SCRIPT"; then
  echo "FAIL: doctor-runner unreachable branch does not set REMOTE_UNREACHABLE=1 -- regression of P1 #2" >&2
  OVERALL_PASS=false
fi
if ! grep -q 'REMOTE_DOWN_SLOTS+=("${REMOTE_PREFIX}-${_unreach_idx} (unreachable)")' "$DOCTOR_SCRIPT"; then
  echo "FAIL: doctor-runner unreachable branch does not synthesize REMOTE_DOWN_SLOTS entries -- P1 #2 fix missing" >&2
  OVERALL_PASS=false
fi
if ! grep -q 'SLOT_PROOF_CRITICAL=$((SLOT_PROOF_CRITICAL + REMOTE_COUNT))' "$DOCTOR_SCRIPT"; then
  echo "FAIL: doctor-runner unreachable branch does not bump SLOT_PROOF_CRITICAL -- verdict cannot flip to bad" >&2
  OVERALL_PASS=false
fi

# --- Assertion 2: the unreachable branch emits a [BAD] line ---
# Pre-fix the unreachable branch only emitted `warn ...`. Post-fix it
# emits `bad $REMOTE_LABEL not reachable via SSH ...`, which is what
# the per-slot execution-proof gate uses to push CRITICAL and force the
# verdict to `bad`.
if ! grep -q 'bad "$REMOTE_LABEL not reachable via SSH' "$DOCTOR_SCRIPT"; then
  echo "FAIL: doctor-runner unreachable branch does not emit a [BAD] line -- the [BAD]/info asymmetry would still mask the failure" >&2
  OVERALL_PASS=false
fi

# --- Assertion 3: end-to-end math via compute_verdict_summary ---
# Drive the actual function from doctor-runner with the inputs the
# unreachable branch produces: 16 local EXECUTING, 0 remote known (all
# 6 remote slots are unproven -> counted as DOWN).
FUNC_START=$(grep -n '^compute_verdict_summary() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate compute_verdict_summary() in $DOCTOR_SCRIPT" >&2
  OVERALL_PASS=false
else
  FUNC_END=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
  FUNC_END=$((FUNC_START + FUNC_END - 1))
  FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")

  eval "$FUNC_SRC"
  out=$(compute_verdict_summary 16 0 0 0  0 0 6 0 0)
  read -r total configured executing idle_ok idle_starved down cycling <<< "$out"

  echo "  [unreachable-remote-math] total=$total configured=$configured executing=$executing cycling=$cycling idle_ok=$idle_ok idle_starved=$idle_starved down=$down"

  # configured MUST be 22 (local 16 + remote unproven 6), NOT 16. If this
  # reads 16 the unreachable-remote fix has regressed.
  if [ "$configured" -ne 22 ]; then
    echo "FAIL: configured=$configured, expected 22 (P1 #2 regression -- configured collapsed to local-only)" >&2
    OVERALL_PASS=false
  fi
  # down MUST be 6 (the unreachable remote slots). Pre-fix this was 0.
  if [ "$down" -ne 6 ]; then
    echo "FAIL: down=$down, expected 6 (P1 #2 regression -- unreachable slots not counted as down)" >&2
    OVERALL_PASS=false
  fi
  # executing MUST be 16 (only the proven local slots).
  if [ "$executing" -ne 16 ]; then
    echo "FAIL: executing=$executing, expected 16 (unreachable slots must NOT inflate executing)" >&2
    OVERALL_PASS=false
  fi
  # total = configured when no idle/cycling/starved slots (16+6 = 22).
  if [ "$total" -ne 22 ]; then
    echo "FAIL: total=$total, expected 22" >&2
    OVERALL_PASS=false
  fi
fi

# --- Assertion 4: the verdict exit path with unreachable REMOTE ---
# Walk the script's verdict-flow with a mock REMOTE_HOST that fails
# ssh-reachability (we cannot fake ssh here without root; instead
# assert that the per-slot execution-proof gate consumes
# SLOT_PROOF_CRITICAL and exits 1).
if ! grep -q 'verdict: per-slot execution-proof gate FAILED' "$DOCTOR_SCRIPT"; then
  echo "FAIL: per-slot execution-proof gate [BAD] line missing -- SLOT_PROOF_CRITICAL would not flip verdict" >&2
  OVERALL_PASS=false
fi
if ! grep -q 'CRITICAL=$((CRITICAL + SLOT_PROOF_CRITICAL))' "$DOCTOR_SCRIPT"; then
  echo "FAIL: SLOT_PROOF_CRITICAL not added to CRITICAL -- the unreachable-path bump would not gate the verdict" >&2
  OVERALL_PASS=false
fi

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi