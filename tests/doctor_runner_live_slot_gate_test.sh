#!/usr/bin/env bash
# regression test: the verdict block's "container count" critical gate must
# derive its live-container signal from the section-9 per-slot inventory
# (EXECUTING_SLOTS/IDLE_SLOTS, already computed with 2-sample DOWN
# persistence — bead ez-gh-actions-b895), never a single raw `docker ps`
# sample — see ez-gh-actions-n9py.
#
# Root cause this guards against: the prior gate compared ONE `docker ps
# --filter label=ezgha=managed` snapshot (CONTAINER_COUNT, taken in section
# 6 at whatever instant the script ran it) directly against config.toml
# runner.count. Under normal ephemeral churn (a runner finishes a job, its
# container is destroyed, and the next serve tick respawns it) that single
# sample legitimately oscillates -- observed 16->15->16 within 15s on a
# fully healthy fleet -- so the gate flapped [BAD] while section 9/10's
# 2-sample-verified per-slot proof showed 0 down in the SAME run.
#
# This test extracts the ACTUAL compute_live_slot_critical() function from
# doctor-runner (via sed, not a re-implementation) so it can't silently
# drift from the real logic, then exercises it against fixture per-slot
# counts, asserting:
#   (a) 16 configured, 14 executing + 1 idle + 1 recovered-cycling (folded
#       into idle by section 9's resample) = 16 live -> NOT critical, even
#       though a raw docker-ps sample momentarily read 15 (the old gate's
#       false-positive scenario -- this test proves the NEW gate no longer
#       consults that raw sample at all).
#   (b) 16 configured, only 14 live (2 slots persisted DOWN across both
#       section-9 samples) -> critical fires, proving the fix didn't just
#       disable the check.
#
# Usage: bash tests/doctor_runner_live_slot_gate_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

# Extract the real compute_live_slot_critical() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate -- keeps the test honest against code drift.
FUNC_START=$(grep -n '^compute_live_slot_critical() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate compute_live_slot_critical() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
FUNC_END=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_START + FUNC_END - 1))
FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")

# Assert the old single-sample gate is actually gone from the verdict path
# (not just superseded) -- the defect this fix targets was a live gate that
# consulted a raw docker-ps sample; if that comparison is still present
# anywhere, the flapping defect is still reachable regardless of what else
# we added.
if grep -q 'CONTAINER_COUNT:-0}" -lt' "$DOCTOR_SCRIPT"; then
  echo "FAIL: single-sample CONTAINER_COUNT critical comparison still present in $DOCTOR_SCRIPT (should be deleted, not just supplemented)" >&2
  exit 1
fi

bad() { printf '  [BAD]  %s\n' "$*"; }  # stub matching doctor-runner's helper

run_case() {
  local label="$1" exec_n="$2" idle_n="$3" expected="$4" expect_critical="$5"

  eval "$FUNC_SRC"

  local out live critical
  out=$(compute_live_slot_critical "$exec_n" "$idle_n" "$expected")
  read -r live critical <<< "$out"

  CRITICAL=0
  if [ "$critical" -eq 1 ]; then
    bad "verdict: live-slot gate FAILED (live slots (executing+idle+cycling from per-slot proof) = ${live}, expected >= ${expected} from config.toml runner.count=${expected})"
    CRITICAL=$((CRITICAL + 1))
  fi

  PASS=true
  if [ "$expect_critical" = "yes" ] && [ "$CRITICAL" -eq 0 ]; then
    echo "  [$label] expected CRITICAL>0 but got CRITICAL=0 (live=$live expected=$expected) -- FAIL"
    PASS=false
  fi
  if [ "$expect_critical" = "no" ] && [ "$CRITICAL" -ne 0 ]; then
    echo "  [$label] expected CRITICAL=0 but got CRITICAL=$CRITICAL (live=$live expected=$expected) -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    echo "  [$label] live=$live expected=$expected CRITICAL=$CRITICAL -- PASS"
    return 0
  else
    return 1
  fi
}

echo "--- doctor-runner live-slot gate regression ---"
OVERALL_PASS=true

# Case (a): 16 configured, 14 executing + 1 idle + 1 recovered-cycling
# (already folded into idle_n=2 by section 9's 2-sample resample) = 16 live
# -> NOT critical. This is the exact scenario a raw docker-ps sample would
# have misread as 15/16 (a container mid-respawn momentarily missing from
# `docker ps`) and flapped [BAD] on a healthy fleet.
run_case "14exec-2idle-cycling-folded-in-16expected" 14 2 16 "no" || OVERALL_PASS=false

# Case (b): 16 configured, totals show only 14 live (exec+idle) because 2
# slots persisted DOWN across both section-9 samples -> critical fires with
# the named message. Proves the fix didn't just disable the check.
run_case "14exec-0idle-2persisted-down-16expected" 14 0 16 "yes" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
