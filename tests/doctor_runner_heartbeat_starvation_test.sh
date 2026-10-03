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
#   (a) regular same-PID ticks 30s apart -> healthy (gap well under 8x
#       tick threshold).
#   (b) same fixture PLUS a 214s gap that spans a PID change (i.e. a
#       daemon restart) -> still healthy: the cross-PID gap is excluded
#       from the max-gap measurement entirely (restart-immune).
#   (c) a real stall: two same-PID ticks with a gap > 8x the configured
#       tick -> starved (CRITICAL).
#
# Threshold is 8x serve_tick_seconds (was 5x until ez-gh-actions-5n0h: bead
# evidence measured a real busy-tick gap of 99s against the old 100s 5x
# threshold on a healthy fleet -- flap-prone under busy-tick stretch).
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
[queue_monitor]
enabled = true
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

# Extract the REAL heartbeat gate block (STARVE_WINDOW .. through the
# platform if/elif/else, including the QUEUE_MONITOR_ENABLED skip) from
# doctor-runner; it is executed below with stubbed journalctl/recent_logs.
GATE_START=$(grep -n '^STARVE_WINDOW=' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
GATE_END=$(grep -n '^# --- G\. verdict' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$GATE_START" ] || [ -z "$GATE_END" ]; then
  echo "FAIL: could not locate heartbeat gate block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
GATE_SRC=$(sed -n "${GATE_START},$((GATE_END - 1))p" "$DOCTOR_SCRIPT")

bad() { printf '  [BAD]  %s\n' "$*"; }  # stub matching doctor-runner's helper

qm_line() {
  # $1=epoch seconds, $2=pid -> one fixture "queue monitor:" journal line in
  # journalctl `-o short-unix` format.
  printf '%s.000000 Jeff-Ubuntu ezgha[%s]: queue monitor: jleechanorg/worldarchitect.ai queued_jobs=0 fresh=0 stale=0 in_progress_jobs=1 max_job_age=0.1m threshold=20m\n' "$1" "$2"
}

run_case() {
  local label="$1" fixture="$2" expect_starved="$3" expect_restart_boundary="$4" service_state="${5:-active}"

  # Run the real gate block in a subshell with stubs. Any setup error (e.g.
  # an unbound variable) is surfaced and fails the case instead of being
  # masked.
  local gate_out gate_rc=0
  gate_out=$(
    set -u
    HOME="$TEMP_HOME"
    PLATFORM=linux
    SERVICE_STATE="$service_state"
    SLOT_PROOF_CRITICAL=0
    LOCAL_CONFIG_FILE="$CONFIG_DIR/config.toml"
    FIXTURE_LINES="$fixture"
    eval "$FUNC_SRC"
    journalctl() { printf '%s\n' "$FIXTURE_LINES"; }
    recent_logs() { :; }
    info() { :; }; warn() { :; }
    bad() { printf '  [BAD]  %s\n' "$*"; }
    eval "$GATE_SRC"
    echo "GATE_RESULT critical=$SLOT_PROOF_CRITICAL max_gap=${MAX_HEARTBEAT_GAP:-0} boundary=${RESTART_BOUNDARY_SEEN:-0} samples=${HEARTBEAT_SAMPLE_COUNT:-0} threshold=$STARVE_GAP_WARN_SECONDS"
  ) 2>&1 || gate_rc=$?
  if [ "$gate_rc" -ne 0 ] || ! grep -q '^GATE_RESULT' <<<"$gate_out" || grep -q 'unbound variable' <<<"$gate_out"; then
    echo "  [$label] TEST SETUP ERROR (rc=$gate_rc): $gate_out"
    return 1
  fi
  local result CRITICAL max_gap restart_boundary sample_count STARVE_GAP_WARN_SECONDS
  result=$(grep '^GATE_RESULT' <<<"$gate_out")
  CRITICAL=$(sed -E 's/.*critical=([0-9]+).*/\1/' <<<"$result")
  max_gap=$(sed -E 's/.*max_gap=([0-9]+).*/\1/' <<<"$result")
  restart_boundary=$(sed -E 's/.*boundary=([0-9]+).*/\1/' <<<"$result")
  sample_count=$(sed -E 's/.*samples=([0-9]+).*/\1/' <<<"$result")
  STARVE_GAP_WARN_SECONDS=$(sed -E 's/.*threshold=([0-9]+).*/\1/' <<<"$result")

  PASS=true
  if [ "$expect_starved" = "yes" ] && [ "$CRITICAL" -eq 0 ]; then
    echo "  [$label] expected starved (CRITICAL>0) but got CRITICAL=0 (max_gap=$max_gap samples=$sample_count threshold=$STARVE_GAP_WARN_SECONDS) -- FAIL"
    PASS=false
  fi
  if [ "$expect_starved" = "no" ] && [ "$CRITICAL" -ne 0 ]; then
    echo "  [$label] expected healthy (CRITICAL=0) but got CRITICAL=$CRITICAL (max_gap=$max_gap samples=$sample_count threshold=$STARVE_GAP_WARN_SECONDS) -- FAIL"
    PASS=false
  fi
  if [ "$restart_boundary" != "$expect_restart_boundary" ]; then
    echo "  [$label] restart_boundary mismatch: got=$restart_boundary want=$expect_restart_boundary -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    echo "  [$label] max_gap=${max_gap}s samples=${sample_count} threshold=${STARVE_GAP_WARN_SECONDS}s restart_boundary=$restart_boundary service_state=$service_state CRITICAL=$CRITICAL -- PASS"
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

# Case (c): a real stall -- two same-PID ticks 250s apart (> 8x the
# configured 30s tick = 240s threshold) -> starved. Proves the fix didn't
# just disable the check. (Threshold raised 5x->8x in ez-gh-actions-5n0h:
# bead evidence measured a real busy-tick gap of 99s against the old 100s
# 5x threshold on a healthy fleet -- one more-loaded tick from a false
# alarm -- so the fixture gap here was widened from 170s/150s-threshold to
# 250s/240s-threshold to stay a genuine stall under the new headroom.)
FIXTURE_C=$(
  qm_line "$BASE" 4192142
  qm_line "$((BASE + 250))" 4192142
)
run_case "same-pid-250s-gap-starved" "$FIXTURE_C" "yes" "0" || OVERALL_PASS=false

# Case (d): the exact real-incident values from the ez-gh-actions-5n0h bead
# report -- serve_tick_seconds=20 (jeff-ubuntu's configured tick, lowered
# from 30 during 2026-07-09 duty-cycle tuning) and a 99s gap, which was
# measured live against the OLD 5x threshold (100s) -- one more-loaded tick
# away from a false starvation alarm on a healthy fleet. Under the new 8x
# threshold (160s) this must read healthy with real headroom, not just
# barely under.
cat > "$CONFIG_DIR/config.toml" <<'EOF'
version = 1
[runner]
serve_tick_seconds = 20
name_prefix = "ez-runner-c"
count = 16
[queue_monitor]
enabled = true
EOF
FIXTURE_D=$(
  qm_line "$BASE" 4192142
  qm_line "$((BASE + 99))" 4192142
)
run_case "20s-tick-99s-gap-healthy-under-8x" "$FIXTURE_D" "no" "0" || OVERALL_PASS=false

cat > "$CONFIG_DIR/config.toml" <<'EOF'
version = 1
[runner]
serve_tick_seconds = 30
name_prefix = "ez-runner-c"
count = 16
[queue_monitor]
enabled = true  # the heartbeat line only exists when the monitor runs
EOF

# Case (e): codex adversarial review 2026-07-10 (finding 1, P1) -- ZERO
# "queue monitor:" lines in the window while the service is active. Before
# the fix, compute_heartbeat_gap's awk max_gap defaults to 0 (uninitialized
# variable) on empty input, which the plain gap>threshold gate read as a
# perfectly healthy 0s gap -- a completely silent serve loop (wedged before
# its first tick, or logging broken) false-greened. Must now trip CRITICAL
# via the sample-count check, independent of the gap value.
FIXTURE_E=""
run_case "zero-samples-active-service-critical" "$FIXTURE_E" "yes" "0" "active" || OVERALL_PASS=false

# Case (f): same empty fixture, but the service is NOT active. Out of scope
# per the finding -- the SERVICE_STATE gate elsewhere in doctor-runner
# already catches inactive/failed/not-loaded, so the heartbeat check itself
# must not ALSO fire (no double-counting / no misleading heartbeat-specific
# message when the real defect is "service down").
run_case "zero-samples-inactive-service-not-double-counted" "$FIXTURE_E" "no" "0" "inactive" || OVERALL_PASS=false

# Case (g): exactly 1 sample in-window is legitimate (a window shorter than
# one serve tick can catch only a single line) -- must NOT trip the
# zero-samples alarm.
FIXTURE_G=$(qm_line "$BASE" 4192142)
run_case "one-sample-active-service-healthy" "$FIXTURE_G" "no" "0" "active" || OVERALL_PASS=false

# Case (h): [queue_monitor] enabled = false means the daemon never emits
# "queue monitor:" lines, so zero samples while active is expected and must
# NOT trip the silent-loop alarm (2026-10-02 false positive on jeff-ubuntu).
cat > "$CONFIG_DIR/config.toml" <<'EOF2'
version = 1
[runner]
serve_tick_seconds = 30
name_prefix = "ez-runner-c"
count = 16
[queue_monitor]
enabled = false
EOF2
run_case "zero-samples-queue-monitor-disabled-not-critical" "$FIXTURE_E" "no" "0" "active" || OVERALL_PASS=false

# Cases (i)-(l): the daemon defaults queue_monitor.enabled to false when the
# table or key is missing, and TOML allows inline comments. Each of these
# means no heartbeat lines, so zero samples must NOT be critical.
for qm_case in "no-table|" "no-key|[queue_monitor]
repo = \"jleechanorg/worldarchitect.ai\"" "inline-comment-false|[queue_monitor]
enabled = false # disabled on purpose" "spaced-header|[ queue_monitor ]
enabled=false"; do
  qm_label="${qm_case%%|*}"; qm_body="${qm_case#*|}"
  printf 'version = 1\n[runner]\nserve_tick_seconds = 30\nname_prefix = "ez-runner-c"\ncount = 16\n%s\n' "$qm_body" > "$CONFIG_DIR/config.toml"
  run_case "zero-samples-queue-monitor-${qm_label}-not-critical" "$FIXTURE_E" "no" "0" "active" || OVERALL_PASS=false
done
# Case (m): enabled = true with an inline comment still runs the check.
printf 'version = 1\n[runner]\nserve_tick_seconds = 30\nname_prefix = "ez-runner-c"\ncount = 16\n[queue_monitor]\nenabled = true # on\n' > "$CONFIG_DIR/config.toml"
run_case "zero-samples-queue-monitor-enabled-inline-comment-critical" "$FIXTURE_E" "yes" "0" "active" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
