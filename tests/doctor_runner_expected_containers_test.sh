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
# sections + a config.toml with runner.count=16 followed by an inline comment
# containing more digits, asserting:
#   1. EXPECTED_CONTAINERS resolves to 16 (from config.toml), not ~28.
#      It must also ignore digits in the inline comment; concatenating those
#      digits made section 9 execute an effectively infinite `seq` on Mac.
#   2. The section-scoped fallback (no config.toml) also resolves to 16,
#      not the whole-file double-count.
#
# NOTE (ez-gh-actions-n9py): this test previously ALSO exercised the verdict
# CRITICAL comparison that consumed EXPECTED_CONTAINERS (a single-sample
# `docker ps` CONTAINER_COUNT vs EXPECTED_CONTAINERS check). That comparison
# was deleted — it flapped [BAD] on a healthy fleet under normal ephemeral
# churn (container briefly missing from one `docker ps` sample, observed
# 16->15->16 within 15s) — and replaced with a gate derived from the
# section-9 per-slot inventory (EXECUTING_SLOTS/IDLE_SLOTS, 2-sample DOWN
# persistence). That replacement gate (compute_live_slot_critical) is
# covered by tests/doctor_runner_live_slot_gate_test.sh; this file now only
# covers the EXPECTED_CONTAINERS derivation itself, which is unchanged.
#
# Usage: bash tests/doctor_runner_expected_containers_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"
LEGACY_DOCTOR_SCRIPT="$REPO_ROOT/doctor.sh"

TEMP_HOME=$(mktemp -d)
cleanup() { rm -rf "$TEMP_HOME"; }
trap cleanup EXIT

CONFIG_DIR="$TEMP_HOME/.config/ezgha"
mkdir -p "$CONFIG_DIR"

# Extract the real TOML-aware runner-count parser. Both section 9 and the
# verdict derivation must call this helper so inline-comment handling cannot
# drift between the two consumers.
COUNT_FUNC_START=$(grep -n '^read_config_runner_count() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$COUNT_FUNC_START" ]; then
  echo "FAIL: could not locate read_config_runner_count() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
COUNT_FUNC_END=$(tail -n +"$COUNT_FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
COUNT_FUNC_END=$((COUNT_FUNC_START + COUNT_FUNC_END - 1))
COUNT_FUNC_SRC=$(sed -n "${COUNT_FUNC_START},${COUNT_FUNC_END}p" "$DOCTOR_SCRIPT")

grep -Fq 'CONFIGURED_COUNT=$(read_config_runner_count ' "$DOCTOR_SCRIPT" || {
  echo "FAIL: section 9 does not use read_config_runner_count()" >&2
  exit 1
}
grep -Fq 'CONFIG_RUNNER_COUNT=$(read_config_runner_count ' "$DOCTOR_SCRIPT" || {
  echo "FAIL: verdict derivation does not use read_config_runner_count()" >&2
  exit 1
}
grep -Fq 'DEFAULT_LINUX_RUNNER_COUNT=10' "$DOCTOR_SCRIPT" || {
  echo "FAIL: Linux fallback count is not the current 10-runner contract" >&2
  exit 1
}
grep -Fq 'DEFAULT_MAC_RUNNER_COUNT=6' "$DOCTOR_SCRIPT" || {
  echo "FAIL: macOS fallback count is not the current 6-runner contract" >&2
  exit 1
}
grep -Fq 'REMOTE_COUNT="${REMOTE_LINUX_COUNT:-$DEFAULT_LINUX_RUNNER_COUNT}"' "$DOCTOR_SCRIPT" || {
  echo "FAIL: remote Linux fallback count is not the current 10-runner contract" >&2
  exit 1
}
grep -Fq 'CONFIGURED_COUNT="${CONFIGURED_COUNT:-10}"' "$LEGACY_DOCTOR_SCRIPT" || {
  echo "FAIL: legacy doctor fallback count is not the current 10-runner contract" >&2
  exit 1
}

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

# Extract the real EXPECTED_CONTAINERS derivation block from doctor-runner
# (bounded by CONFIG_RUNNER_COUNT= ... the closing `fi` of the if/elif/else
# — NOT through the now-removed container-count CRITICAL comparison, which
# was deleted; see ez-gh-actions-n9py).
DERIVE_START=$(grep -n '^CONFIG_RUNNER_COUNT=' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$DERIVE_START" ]; then
  echo "FAIL: could not locate EXPECTED_CONTAINERS derivation block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
DERIVE_END_OFFSET=$(tail -n +"$DERIVE_START" "$DOCTOR_SCRIPT" | grep -n '^fi$' | head -1 | cut -d: -f1)
if [ -z "$DERIVE_END_OFFSET" ]; then
  echo "FAIL: could not locate closing 'fi' of EXPECTED_CONTAINERS derivation block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
DERIVE_END=$((DERIVE_START + DERIVE_END_OFFSET - 1))
DERIVE_SRC=$(sed -n "${DERIVE_START},${DERIVE_END}p" "$DOCTOR_SCRIPT")

run_case() {
  local label="$1" config_present="$2" expected_value="$3"
  if [ "$config_present" = "yes" ]; then
    cat > "$CONFIG_DIR/config.toml" <<EOF
version = 1
[runner]
name_prefix = "ez-runner-c"
count = 16 # synthetic fixture; trailing digits must not alter the parsed count 24
EOF
  else
    rm -f "$CONFIG_DIR/config.toml"
  fi

  HOME="$TEMP_HOME"
  SLOT_FILE="$SLOT_FILE"
  EXPECTED_CONTAINERS=""
  eval "$COUNT_FUNC_SRC"
  eval "$FUNC_SRC"
  eval "$DERIVE_SRC"

  PASS=true
  if [ "$EXPECTED_CONTAINERS" != "$expected_value" ]; then
    echo "  [$label] EXPECTED_CONTAINERS mismatch: got=$EXPECTED_CONTAINERS want=$expected_value -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    echo "  [$label] EXPECTED_CONTAINERS=$EXPECTED_CONTAINERS -- PASS"
    return 0
  else
    return 1
  fi
}

run_platform_default_case() {
  local label="$1" platform_default="$2"

  HOME="$TEMP_HOME"
  SLOT_FILE="$CONFIG_DIR/missing-slot-assignments.toml"
  EXPECTED_CONTAINERS=""
  DEFAULT_CONFIGURED_COUNT="$platform_default"
  eval "$COUNT_FUNC_SRC"
  eval "$FUNC_SRC"
  eval "$DERIVE_SRC"

  if [ "$EXPECTED_CONTAINERS" != "$platform_default" ]; then
    echo "  [$label] EXPECTED_CONTAINERS mismatch: got=$EXPECTED_CONTAINERS want=$platform_default -- FAIL"
    return 1
  fi
  echo "  [$label] EXPECTED_CONTAINERS=$EXPECTED_CONTAINERS -- PASS"
}

echo "--- doctor-runner EXPECTED_CONTAINERS regression ---"
OVERALL_PASS=true

# Case 1: synthetic config.toml (count=16) -> must resolve EXPECTED_CONTAINERS=16
# (not ~28 from the old double-count bug).
run_case "config-present-16-containers" "yes" "16" || OVERALL_PASS=false

# Case 2: config.toml MISSING, fall back to section-scoped [assignments]
# count (16 entries) -> must resolve to 16 via the fallback (never the
# whole-file double-count of ~28).
run_case "config-missing-section-scoped-fallback" "no" "16" || OVERALL_PASS=false

# Cases 3-4: with neither config nor slot assignments available, use the
# platform-selected default instead of silently treating every host as macOS.
run_platform_default_case "linux-platform-default" "10" || OVERALL_PASS=false
run_platform_default_case "macos-platform-default" "6" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
