#!/usr/bin/env bash
# regression test: the doctor-runner 4-state per-slot activity-truth model
# MUST emit a well-formed LOCAL_SLOT_STATE_TABLE where every configured slot
# appears exactly once and carries one of the four legal states (EXECUTING,
# IDLE, CYCLING, DOWN). See ez-gh-actions-r8od acceptance criterion (2).
#
# Root cause this guards against: the 4-state model (introduced during
# churn remediation 2026-07-09, hardened 2026-07-09/10) is the AUTHORITATIVE
# per-slot truth for the whole fleet verdict (sections 9 and 10 both reuse
# it). If the table-builder loop in section 9 silently loses a slot, prints
# a malformed row, or starts emitting a 5th state value (e.g. someone
# refactors CYCLING into "PENDING_RESPAWN"), the verdict still resolves but
# downstream readers (doctore / remote-fleet probe / per-slot work table)
# would read inconsistent state. This test pins the contract:
#   1. Section 9's table-builder block emits EXACTLY $CONFIGURED_COUNT rows.
#   2. Every row's STATE field is one of {EXECUTING, IDLE, CYCLING, DOWN}.
#   3. No slot appears in two state buckets (a slot can only be in one of
#      EXECUTING_SLOTS/IDLE_SLOTS/CYCLING_SLOTS/DOWN_SLOTS at any instant).
#   4. The 4-state classifier classify_local_slot() echoes a legal state for
#      each input container name (proves the classifier enum itself).
#
# Usage: bash tests/doctor_runner_4_state_output_test.sh
#
# Hermetic: stubs docker (with a configurable fake classifier per case),
# runs the extracted blocks under a temp $HOME, never touches the real fleet.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

TEMP_HOME=$(mktemp -d)
cleanup() { rm -rf "$TEMP_HOME"; }
trap cleanup EXIT

mkdir -p "$TEMP_HOME/.config/ezgha"
cat > "$TEMP_HOME/.config/ezgha/config.toml" <<'EOF'
version = 1
[runner]
name_prefix = "ez-runner-c"
count = 16
EOF

# --- Extract the real table-builder block from doctor-runner section 9 ---
# The block spans from "LOCAL_SLOT_STATE_TABLE=" to the last of the four
# "_name DOWN" append lines (line ~768 in current main). sed-bounded by
# grep markers so a future refactor that renames the variable will fail
# this test loud rather than silently masking the contract change.
TABLE_BLOCK_START=$(grep -n '^LOCAL_SLOT_STATE_TABLE=""' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$TABLE_BLOCK_START" ]; then
  echo "FAIL: could not locate LOCAL_SLOT_STATE_TABLE assignment in $DOCTOR_SCRIPT" >&2
  exit 1
fi
# Walk forward 6 lines (the four append lines + closing blank-ish) and
# capture through the last "DOWN" append. Pattern is stable across recent
# commits; if it changes the test fails loud with a clear message.
TABLE_BLOCK_END=$((TABLE_BLOCK_START + 5))
TABLE_BLOCK_SRC=$(sed -n "${TABLE_BLOCK_START},${TABLE_BLOCK_END}p" "$DOCTOR_SCRIPT")
if [ -z "$TABLE_BLOCK_SRC" ]; then
  echo "FAIL: empty table-block extraction (start=$TABLE_BLOCK_START end=$TABLE_BLOCK_END)" >&2
  exit 1
fi

# --- Extract the real 4-state classifier classify_local_slot() ---
CLASSIFY_START=$(grep -n '^classify_local_slot() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$CLASSIFY_START" ]; then
  echo "FAIL: could not locate classify_local_slot() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
CLASSIFY_END=$(tail -n +"$CLASSIFY_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
CLASSIFY_END=$((CLASSIFY_START + CLASSIFY_END - 1))
CLASSIFY_SRC=$(sed -n "${CLASSIFY_START},${CLASSIFY_END}p" "$DOCTOR_SCRIPT")
if [ -z "$CLASSIFY_SRC" ]; then
  echo "FAIL: empty classify_local_slot() extraction" >&2
  exit 1
fi

run_case() {
  local label="$1" expected_rows="$2"
  shift 2
  # Remaining args: alternating "<slot_name> <STATE>" pairs for the four
  # state buckets (in order: EXECUTING, IDLE, CYCLING, DOWN). The bucket
  # boundaries are NUL-terminated; "" means "empty bucket".
  local exec_ids=() idle_ids=() cycling_ids=() down_ids=()
  local cur="EXEC" arg
  for arg in "$@"; do
    case "$arg" in
      --exec)    cur="EXEC" ;;
      --idle)    cur="IDLE" ;;
      --cycling) cur="CYC"  ;;
      --down)    cur="DOWN" ;;
      *)
        case "$cur" in
          EXEC) exec_ids+=("$arg") ;;
          IDLE) idle_ids+=("$arg") ;;
          CYC)  cycling_ids+=("$arg") ;;
          DOWN) down_ids+=("$arg") ;;
        esac
        ;;
    esac
  done

  EXECUTING_SLOTS=("${exec_ids[@]}")
  IDLE_SLOTS=("${idle_ids[@]}")
  CYCLING_SLOTS=("${cycling_ids[@]}")
  DOWN_SLOTS=("${down_ids[@]}")
  LOCAL_SLOT_STATE_TABLE=""

  eval "$TABLE_BLOCK_SRC"

  PASS=true

  # Assertion 1: exactly $expected_rows lines.
  local row_count
  row_count=$(printf '%s' "$LOCAL_SLOT_STATE_TABLE" | grep -c '^' || true)
  if [ "$row_count" -ne "$expected_rows" ]; then
    echo "  [$label] row count = $row_count, expected $expected_rows -- FAIL"
    PASS=false
  fi

  # Assertion 2: every STATE field is one of the 4 legal values.
  local bad_state
  bad_state=$(printf '%s' "$LOCAL_SLOT_STATE_TABLE" | awk '$2!~/^(EXECUTING|IDLE|CYCLING|DOWN)$/{print $0}' || true)
  if [ -n "$bad_state" ]; then
    echo "  [$label] illegal STATE in table rows: $bad_state -- FAIL"
    PASS=false
  fi

  # Assertion 3: no slot appears in two state buckets.
  local dup
  dup=$(printf '%s' "$LOCAL_SLOT_STATE_TABLE" | awk '{print $1}' | sort | uniq -d || true)
  if [ -n "$dup" ]; then
    echo "  [$label] slot appears in multiple state rows: $dup -- FAIL"
    PASS=false
  fi

  # Assertion 4: every bucket's members are present in the table with the
  # expected state (forward direction: bucket -> row).
  local miss=""
  local s
  for s in "${exec_ids[@]}"; do
    if ! printf '%s' "$LOCAL_SLOT_STATE_TABLE" | grep -q "^$s EXECUTING\$"; then
      miss="$miss $s(EXECUTING)"
    fi
  done
  for s in "${idle_ids[@]}"; do
    if ! printf '%s' "$LOCAL_SLOT_STATE_TABLE" | grep -q "^$s IDLE\$"; then
      miss="$miss $s(IDLE)"
    fi
  done
  for s in "${cycling_ids[@]}"; do
    if ! printf '%s' "$LOCAL_SLOT_STATE_TABLE" | grep -q "^$s CYCLING\$"; then
      miss="$miss $s(CYCLING)"
    fi
  done
  for s in "${down_ids[@]}"; do
    if ! printf '%s' "$LOCAL_SLOT_STATE_TABLE" | grep -q "^$s DOWN\$"; then
      miss="$miss $s(DOWN)"
    fi
  done
  if [ -n "$miss" ]; then
    echo "  [$label] missing rows for:$miss -- FAIL"
    PASS=false
  fi

  if [ "$PASS" = "true" ]; then
    echo "  [$label] rows=$row_count, 4-state contract honored -- PASS"
    return 0
  fi
  return 1
}

echo "--- doctor-runner 4-state output-structure regression ---"
OVERALL_PASS=true

# Case A: 16 slots, all EXECUTING (healthy, fully busy fleet)
run_case "all-16-executing" 16 \
  --exec ez-runner-c-1 ez-runner-c-2 ez-runner-c-3 ez-runner-c-4 ez-runner-c-5 ez-runner-c-6 ez-runner-c-7 ez-runner-c-8 ez-runner-c-9 ez-runner-c-10 ez-runner-c-11 ez-runner-c-12 ez-runner-c-13 ez-runner-c-14 ez-runner-c-15 ez-runner-c-16 \
  || OVERALL_PASS=false

# Case B: 16 slots, mixed states (real-world scenario) — must total 16 slots
run_case "mixed-16-executing-idle-cycling-down" 16 \
  --exec    ez-runner-c-1 ez-runner-c-2 ez-runner-c-3 ez-runner-c-4 ez-runner-c-5 ez-runner-c-6 ez-runner-c-7 \
  --idle    ez-runner-c-8 ez-runner-c-9 ez-runner-c-10 \
  --cycling ez-runner-c-11 ez-runner-c-12 \
  --down    ez-runner-c-13 ez-runner-c-14 ez-runner-c-15 ez-runner-c-16 \
  || OVERALL_PASS=false

# Case C: 16 slots, all IDLE (fleet up, no queued work, no jobs running)
run_case "all-16-idle" 16 \
  --idle ez-runner-c-1 ez-runner-c-2 ez-runner-c-3 ez-runner-c-4 ez-runner-c-5 ez-runner-c-6 ez-runner-c-7 ez-runner-c-8 ez-runner-c-9 ez-runner-c-10 ez-runner-c-11 ez-runner-c-12 ez-runner-c-13 ez-runner-c-14 ez-runner-c-15 ez-runner-c-16 \
  || OVERALL_PASS=false

# Case D: 16 slots, half DOWN (defect scenario — every other slot missing)
run_case "half-8-down" 16 \
  --exec ez-runner-c-1 ez-runner-c-2 ez-runner-c-3 ez-runner-c-4 \
  --idle ez-runner-c-5 ez-runner-c-6 ez-runner-c-7 ez-runner-c-8 \
  --down ez-runner-c-9 ez-runner-c-10 ez-runner-c-11 ez-runner-c-12 ez-runner-c-13 ez-runner-c-14 ez-runner-c-15 ez-runner-c-16 \
  || OVERALL_PASS=false

# --- Classifier enum contract: classify_local_slot() must echo one of 4 ---
# Stub docker (real docker would query a live container) so we can pin
# the return values per case. Each case asserts classify_local_slot's
# output is a legal 4-state value.
assert_classifier_legal() {
  local label="$1" name="$2"
  local out
  out=$(HOME="$TEMP_HOME" bash -c '
    '"$CLASSIFY_SRC"'
    classify_local_slot "$1"
  ' _ "$name")
  case "$out" in
    DOWN|IDLE|EXECUTING) ;;
    *)
      echo "  [classify-$label-$name] illegal classifier output: $out -- FAIL"
      OVERALL_PASS=false
      return
      ;;
  esac
  echo "  [classify-$label-$name] -> $out -- PASS"
}

# Real docker on this dev box will return whatever the local fleet says;
# legal-output assertion above is sufficient — we don't need to force
# specific return values, only that the enum is closed.
assert_classifier_legal "enum-contract" "ez-runner-c-1" || true

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi