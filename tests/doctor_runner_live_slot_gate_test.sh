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
# fully managed fleet -- so the gate flapped [BAD] while section 9/10's
# 2-sample-verified per-slot proof showed 0 down in the SAME run.
#
# This test extracts the ACTUAL compute_live_slot_critical() function from
# doctor-runner (via sed, not a re-implementation) so it can't silently
# drift from the real logic, then exercises it against fixture per-slot
# counts, asserting:
#   (a) 1 executing + 15 IDLE-OK with no queue -> NOT critical.
#   (b) all 10 Linux + 6 Mac configured slots executing -> NOT critical.
#   (c) one slot cycling under daemon management -> NOT critical.
#   (d) one persisted-DOWN slot -> critical.
#
# Usage: bash tests/doctor_runner_live_slot_gate_test.sh

# Literal fixed-string assertions intentionally contain shell syntax.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

# Extract the real compute_live_slot_critical() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate -- keeps the test honest against code drift.
FUNC_START=$(grep -n '^compute_live_slot_critical() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
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

# The production call must derive the aggregate expected count from both host
# contracts. Passing local CONFIGURED_COUNT (10 on Linux) would let all six Mac
# slots be non-executing while 10 >= 10 still greens.
if ! grep -Fq 'FLEET_CONFIGURED_COUNT=$((LOCAL_COUNT + REMOTE_COUNT))' "$DOCTOR_SCRIPT"; then
  echo "FAIL: production gate does not derive aggregate local+remote configured count" >&2
  exit 1
fi
if ! grep -Fq '"${#EXECUTING_SLOTS[@]}" "${#IDLE_SLOTS[@]}" "${#CYCLING_SLOTS[@]}"' "$DOCTOR_SCRIPT"; then
  echo "FAIL: production live-slot gate does not consume local four-state inventory" >&2
  exit 1
fi
if ! grep -Fq '"${#REMOTE_EXECUTING_SLOTS[@]}" "${#REMOTE_IDLE_SLOTS[@]}" "${#REMOTE_CYCLING_SLOTS[@]}"' "$DOCTOR_SCRIPT"; then
  echo "FAIL: production live-slot gate does not consume remote four-state inventory" >&2
  exit 1
fi

bad() { printf '  [BAD]  %s\n' "$*"; }  # stub matching doctor-runner's helper

run_case() {
  local label="$1" local_exec_n="$2" local_idle_n="$3" local_cycling_n="$4"
  local remote_exec_n="$5" remote_idle_n="$6" remote_cycling_n="$7"
  local expected="$8" expect_critical="$9"

  eval "$FUNC_SRC"

  local out live critical
  out=$(compute_live_slot_critical \
    "$local_exec_n" "$local_idle_n" "$local_cycling_n" \
    "$remote_exec_n" "$remote_idle_n" "$remote_cycling_n" \
    "$expected")
  read -r live critical <<< "$out"

  CRITICAL=0
  if [ "$critical" -eq 1 ]; then
    bad "verdict: live-slot gate FAILED (managed live slots = ${live}, expected ${expected})"
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

# A drained queue with 1 executing and 15 IDLE-OK slots is healthy.
run_case "1exec-15idle-ok-16expected" 1 9 0 0 6 0 16 "no" || OVERALL_PASS=false

# Full configured capacity executing remains healthy.
run_case "10linux-6mac-exec-16expected" 10 0 0 6 0 0 16 "no" || OVERALL_PASS=false

# A journal-confirmed cycling slot remains under daemon management.
run_case "9linux-exec-1cycling-6mac-idle-16expected" 9 0 1 0 6 0 16 "no" || OVERALL_PASS=false

# Persisted remote DOWN slots remain critical.
run_case "9linux-exec-6mac-idle-1down-16expected" 9 0 0 0 6 0 16 "yes" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
