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
# This test extracts the ACTUAL compute_execution_slot_critical() function from
# doctor-runner (via sed, not a re-implementation) so it can't silently
# drift from the real logic, then exercises it against fixture per-slot
# counts, asserting:
#   (a) all 10 Linux + 6 Mac configured slots executing -> NOT critical.
#   (b) Linux full, 4 Mac executing + 2 idle -> critical.
#   (c) Linux full, 5 Mac executing + 1 cycling -> critical.
#   (d) Linux full, 4 Mac executing + 2 DOWN -> critical.
#
# Usage: bash tests/doctor_runner_live_slot_gate_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

# Extract the real compute_execution_slot_critical() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate -- keeps the test honest against code drift.
FUNC_START=$(grep -n '^compute_execution_slot_critical() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate compute_execution_slot_critical() in $DOCTOR_SCRIPT" >&2
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
  local label="$1" local_exec_n="$2" remote_exec_n="$3" expected="$4" expect_critical="$5"

  eval "$FUNC_SRC"

  local out executing critical
  out=$(compute_execution_slot_critical "$local_exec_n" "$remote_exec_n" "$expected")
  read -r executing critical <<< "$out"

  CRITICAL=0
  if [ "$critical" -eq 1 ]; then
    bad "verdict: execution-slot gate FAILED (executing slots with Runner.Worker proof = ${executing}, expected >= ${expected} from config.toml runner.count=${expected})"
    CRITICAL=$((CRITICAL + 1))
  fi

  PASS=true
  if [ "$expect_critical" = "yes" ] && [ "$CRITICAL" -eq 0 ]; then
    echo "  [$label] expected CRITICAL>0 but got CRITICAL=0 (executing=$executing expected=$expected) -- FAIL"
    PASS=false
  fi
  if [ "$expect_critical" = "no" ] && [ "$CRITICAL" -ne 0 ]; then
    echo "  [$label] expected CRITICAL=0 but got CRITICAL=$CRITICAL (executing=$executing expected=$expected) -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    echo "  [$label] executing=$executing expected=$expected CRITICAL=$CRITICAL -- PASS"
    return 0
  else
    return 1
  fi
}

echo "--- doctor-runner execution-slot gate regression ---"
OVERALL_PASS=true

# Full configured capacity is healthy only when every Linux and Mac slot has
# Runner.Worker proof.
run_case "10linux-6mac-exec-16expected" 10 6 16 "no" || OVERALL_PASS=false

# Two remote idle listeners are available but not executing real jobs.
run_case "10linux-4mac-exec-2mac-idle-16expected" 10 4 16 "yes" || OVERALL_PASS=false

# One remote mid-respawn slot is cycling and cannot green the fleet.
run_case "10linux-5mac-exec-1mac-cycling-16expected" 10 5 16 "yes" || OVERALL_PASS=false

# Persisted remote DOWN slots remain critical.
run_case "10linux-4mac-exec-2mac-down-16expected" 10 4 16 "yes" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
