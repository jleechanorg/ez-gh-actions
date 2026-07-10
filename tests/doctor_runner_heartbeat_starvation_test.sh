#!/usr/bin/env bash
# regression test: serve-loop starvation must be measured via the
# "queue monitor:" journal-line HEARTBEAT (PID-scoped), never the old
# demand-driven "respawned ephemeral runner" gap heuristic — see
# ez-gh-actions-wxfl.
#
# Root cause this guards against: the prior signal measured the max gap
# between "respawned ephemeral runner" journal lines. That line only
# appears when ensure_count actually needed to respawn something, so an
# IDLE fleet (nothing queued, nothing to respawn) produced zero such lines
# and the max-gap arithmetic either false-positived or silently no-opped.
# The same signal also false-positived across ordinary daemon restarts,
# because a restart's dead time (old process exits, new process starts)
# looks identical to a stalled loop under a naive timestamp diff.
#
# This test extracts the ACTUAL compute_heartbeat_gap() function and the
# ACTUAL SERVE_TICK_SECONDS/STARVE_GAP_WARN_SECONDS threshold-derivation
# lines from doctor-runner (via sed, not a re-implementation), then
# exercises them against fixture journalctl `-o short-unix` lines,
# asserting:
#   (a) regular same-PID ticks 30s apart -> healthy (gap well under 5x
#       tick threshold).
#   (b) same fixture PLUS a 214s gap that spans a PID change (i.e. a
#       daemon restart) -> still healthy: the cross-PID gap is excluded
#       from the max-gap measurement entirely (restart-immune), even
#       though 214s alone would exceed the default 150s threshold.
#   (c) a real stall: two same-PID ticks with a gap > 5x the configured
#       tick -> starved (CRITICAL).
#
# Usage: bash tests/doctor_runner_heartbeat_starvation_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

TEMP_HOME=$(mktemp -d)
cleanup() { rm -rf "$TEMP_HOME"; }
trap cleanup EXIT

CONFIG_DIR="$TEMP_HOME/.config/ezgha"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.toml" <<'EOF'
version = 1
[runner]
serve_tick_seconds = 30
name_prefix = "ez-runner-c"
count = 16
EOF

# Extract the real compute_heartbeat_gap() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate — keeps the test honest against code drift.
FUNC_START=$(grep -n '^compute_heartbeat_gap() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate compute_heartbeat_gap() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
FUNC_END=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_START + FUNC_END - 1))
FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")

# Extract the real SERVE_TICK_SECONDS + STARVE_GAP_WARN_SECONDS threshold
# derivation lines (reads [runner] serve_tick_seconds from config.toml,
# defaults to 30, threshold = 5x tick).
TICK_START=$(grep -n '^SERVE_TICK_SECONDS=' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
TICK_END=$(grep -n '^STARVE_GAP_WARN_SECONDS=' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$TICK_START" ] || [ -z "$TICK_END" ]; then
  echo "FAIL: could not locate SERVE_TICK_SECONDS/STARVE_GAP_WARN_SECONDS derivation in $DOCTOR_SCRIPT" >&2
  exit 1
fi
TICK_SRC=$(sed -n "${TICK_START},${TICK_END}p" "$DOCTOR_SCRIPT")

bad() { printf '  [BAD]  %s\n' "$*"; }  # stub matching doctor-runner's helper

qm_line() {
  # $1=epoch seconds, $2=pid -> one fixture "queue monitor:" journal line in
  # journalctl `-o short-unix` format.
  printf '%s.000000 Jeff-Ubuntu ezgha[%s]: queue monitor: jleechanorg/worldarchitect.ai queued_jobs=0 fresh=0 stale=0 in_progress_jobs=1 max_job_age=0.1m threshold=20m\n' "$1" "$2"
}

run_case() {
  local label="$1" fixture="$2" expect_starved="$3" expect_restart_boundary="$4"

  HOME="$TEMP_HOME"
  eval "$FUNC_SRC"
  eval "$TICK_SRC"

  local out
  out=$(printf '%s\n' "$fixture" | compute_heartbeat_gap)
  local max_gap restart_boundary
  read -r max_gap restart_boundary <<< "$out"

  CRITICAL=0
  if [ "${max_gap:-0}" -gt "$STARVE_GAP_WARN_SECONDS" ]; then
    bad "serve-loop starvation: queue-monitor heartbeat gap ${max_gap}s exceeds ${STARVE_GAP_WARN_SECONDS}s (5x serve_tick_seconds=${SERVE_TICK_SECONDS})"
    CRITICAL=$((CRITICAL + 1))
  fi

  PASS=true
  if [ "$expect_starved" = "yes" ] && [ "$CRITICAL" -eq 0 ]; then
    echo "  [$label] expected starved (CRITICAL>0) but got CRITICAL=0 (max_gap=$max_gap threshold=$STARVE_GAP_WARN_SECONDS) -- FAIL"
    PASS=false
  fi
  if [ "$expect_starved" = "no" ] && [ "$CRITICAL" -ne 0 ]; then
    echo "  [$label] expected healthy (CRITICAL=0) but got CRITICAL=$CRITICAL (max_gap=$max_gap threshold=$STARVE_GAP_WARN_SECONDS) -- FAIL"
    PASS=false
  fi
  if [ "$restart_boundary" != "$expect_restart_boundary" ]; then
    echo "  [$label] restart_boundary mismatch: got=$restart_boundary want=$expect_restart_boundary -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    echo "  [$label] max_gap=${max_gap}s threshold=${STARVE_GAP_WARN_SECONDS}s restart_boundary=$restart_boundary CRITICAL=$CRITICAL -- PASS"
    return 0
  else
    return 1
  fi
}

echo "--- doctor-runner serve-loop-heartbeat starvation regression ---"
OVERALL_PASS=true

BASE=1783650000

# Case (a): regular same-PID ticks 30s apart -> healthy. Demand-independent
# by construction: no "respawned ephemeral runner" lines exist anywhere in
# this fixture, which would have made the OLD heuristic report a gap of 0s
# (misleadingly "healthy" for the wrong reason) or, on a truly idle window,
# skip evaluation entirely. The new heartbeat signal is healthy for the
# RIGHT reason: the loop is provably still ticking.
FIXTURE_A=$(
  qm_line "$BASE" 4192142
  qm_line "$((BASE + 30))" 4192142
  qm_line "$((BASE + 60))" 4192142
  qm_line "$((BASE + 90))" 4192142
)
run_case "regular-ticks-30s-healthy" "$FIXTURE_A" "no" "0" || OVERALL_PASS=false

# Case (b): a 214s gap that spans a PID change (daemon restart) -> healthy
# AND restart_boundary reported. 214s alone exceeds the 150s threshold used
# by the old heuristic's default, proving this is restart-immune: the
# cross-PID gap is excluded from the max-gap measurement, not merely
# tolerated.
FIXTURE_B=$(
  qm_line "$BASE" 4192142
  qm_line "$((BASE + 30))" 4192142
  qm_line "$((BASE + 244))" 5200099   # +214s gap, NEW pid (restart)
  qm_line "$((BASE + 274))" 5200099
)
run_case "restart-boundary-214s-gap-immune" "$FIXTURE_B" "no" "1" || OVERALL_PASS=false

# Case (c): a real stall -- two same-PID ticks 170s apart (> 5x the
# configured 30s tick = 150s threshold) -> starved. Proves the fix didn't
# just disable the check.
FIXTURE_C=$(
  qm_line "$BASE" 4192142
  qm_line "$((BASE + 170))" 4192142
)
run_case "same-pid-170s-gap-starved" "$FIXTURE_C" "yes" "0" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
