#!/usr/bin/env bash
# regression test: EXPECTED_CONTAINERS must come from config.toml runner.count
# (or a section-scoped fallback), never a whole-file grep of
# slot_assignments.toml — see ez-gh-actions-nj2j.
#
# Root cause this guards against: slot_assignments.toml now carries BOTH
# [assignments] and [registered_at] sections, one line per slot each
# (registered_at was added during churn remediation). A whole-file
# `grep -c '='` therefore counts ~2x the real slot count (e.g. ~28 for a
# 16-slot fleet), and a 16-container fleet was falsely flagged as a
# container-count CRITICAL with no printed [BAD] line explaining why.
#
# This test extracts the ACTUAL derivation code from doctor-runner (via sed,
# not a re-implementation) so it can't silently drift from the real logic,
# then exercises it against a fixture slot_assignments.toml with both
# sections + a config.toml with runner.count=16, asserting:
#   1. EXPECTED_CONTAINERS resolves to 16 (from config.toml), not ~28.
#   2. A 16-container fleet does NOT trip the container-count CRITICAL.
#   3. The section-scoped fallback (no config.toml) also resolves to 16,
#      not the whole-file double-count.
#
# Usage: bash tests/doctor_runner_expected_containers_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

TEMP_HOME=$(mktemp -d)
cleanup() { rm -rf "$TEMP_HOME"; }
trap cleanup EXIT

CONFIG_DIR="$TEMP_HOME/.config/ezgha"
mkdir -p "$CONFIG_DIR"

# Fixture: slot_assignments.toml with BOTH [assignments] and [registered_at]
# sections, 16 entries each — the exact shape that broke the old grep -c '='.
SLOT_FILE="$CONFIG_DIR/slot_assignments.toml"
{
  echo "[assignments]"
  for i in $(seq 1 16); do echo "slot-$i = \"runner-$i\""; done
  echo ""
  echo "[registered_at]"
  for i in $(seq 1 16); do echo "slot-$i = \"2026-07-09T00:00:00Z\""; done
} > "$SLOT_FILE"

# Extract the real count_assignments_section() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate — keeps the test honest against code drift.
FUNC_START=$(grep -n '^count_assignments_section() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate count_assignments_section() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
FUNC_END=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_START + FUNC_END - 1))
FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")

# Extract the real EXPECTED_CONTAINERS derivation + container-count gate
# block from doctor-runner.
DERIVE_START=$(grep -n '^CONFIG_RUNNER_COUNT=' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
DERIVE_END=$(grep -n 'container-count gate FAILED' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
DERIVE_END=$((DERIVE_END + 2))  # include the CRITICAL increment + closing fi
if [ -z "$DERIVE_START" ] || [ -z "$DERIVE_END" ]; then
  echo "FAIL: could not locate EXPECTED_CONTAINERS derivation block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
DERIVE_SRC=$(sed -n "${DERIVE_START},${DERIVE_END}p" "$DOCTOR_SCRIPT")

bad() { printf '  [BAD]  %s\n' "$*"; }  # stub matching doctor-runner's helper

run_case() {
  local label="$1" config_present="$2" expected_value="$3" container_count="$4" expect_critical="$5"
  if [ "$config_present" = "yes" ]; then
    cat > "$CONFIG_DIR/config.toml" <<EOF
version = 1
[runner]
name_prefix = "ez-runner-c"
count = 16
EOF
  else
    rm -f "$CONFIG_DIR/config.toml"
  fi

  HOME="$TEMP_HOME"
  SLOT_FILE="$SLOT_FILE"
  CONTAINER_COUNT="$container_count"
  EXPECTED_CONTAINERS=""
  CRITICAL=0
  eval "$FUNC_SRC"
  eval "$DERIVE_SRC"

  PASS=true
  if [ "$EXPECTED_CONTAINERS" != "$expected_value" ]; then
    echo "  [$label] EXPECTED_CONTAINERS mismatch: got=$EXPECTED_CONTAINERS want=$expected_value -- FAIL"
    PASS=false
  fi
  if [ "$expect_critical" = "yes" ] && [ "$CRITICAL" -eq 0 ]; then
    echo "  [$label] expected CRITICAL>0 but got CRITICAL=$CRITICAL -- FAIL"
    PASS=false
  fi
  if [ "$expect_critical" = "no" ] && [ "$CRITICAL" -ne 0 ]; then
    echo "  [$label] expected CRITICAL=0 but got CRITICAL=$CRITICAL -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    echo "  [$label] EXPECTED_CONTAINERS=$EXPECTED_CONTAINERS CRITICAL=$CRITICAL -- PASS"
    return 0
  else
    return 1
  fi
}

echo "--- doctor-runner EXPECTED_CONTAINERS regression ---"
OVERALL_PASS=true

# Case 1: config.toml present (count=16), 16 containers reported -> must
# resolve EXPECTED_CONTAINERS=16 (not ~28 from the old double-count bug) and
# must NOT trip the container-count critical.
run_case "config-present-16-containers" "yes" "16" "16" "no" || OVERALL_PASS=false

# Case 2: config.toml MISSING, fall back to section-scoped [assignments]
# count (16 entries), 16 containers reported -> must resolve to 16 via the
# fallback (never the whole-file double-count of ~28) and must NOT trip.
run_case "config-missing-section-scoped-fallback" "no" "16" "16" "no" || OVERALL_PASS=false

# Case 3: config.toml present (count=16), only 10 containers reported -> the
# gate MUST still correctly detect a real shortfall (proves the fix didn't
# just disable the check).
run_case "config-present-real-shortfall" "yes" "16" "10" "yes" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
