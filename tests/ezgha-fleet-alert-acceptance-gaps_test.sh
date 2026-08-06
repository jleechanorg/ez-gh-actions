#!/usr/bin/env bash
# ezgha-fleet-alert-acceptance-gaps_test.sh — GH#106 acceptance-criteria gaps
# (bead jleechan-vsd1). Six tests covering the five gaps:
#   1. doctor-runner verdict polling (EZGHA_DOCTOR_RUNNER=1)
#   2. count_critical_in_window with doctor/container co-gating
#   3. container_count_check vs EZGHA_EXPECTED_CAPACITY
#   4. JSON payload uses "evidence" (not "reason")
#   5. ALERT_LOG_FILE sink (JSONL append) + /var/log fallback
#
# Each test is hermetic — tempdirs for stderr log, slot file, state dir,
# doctor-runner stub, and ALERT_LOG_FILE. Never touches the real $HOME
# filesystem or /var/log.
#
# Usage:
#   bash tests/ezgha-fleet-alert-acceptance-gaps_test.sh
#
# Exit code:
#   0 = all 6 tests pass
#   non-zero = first failing test

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/ezgha-fleet-alert.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: script not executable: $SCRIPT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=true
FAIL_COUNT=0
fail() {
  echo "FAIL: $*" >&2
  PASS=false
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ── helpers ────────────────────────────────────────────────────────────────
build_log() {
  local log_path="$1" count="$2"
  local now i wall
  now="$(date +%s)"
  : > "$log_path"
  for ((i=0; i<count; i++)); do
    wall=$(( now - (i * 5) ))
    printf 'info: release_stale_slots reclaimed slot %d: runner_id=%d last_run_id=%d monotonic_ts=%.3f wall_ts=%d elapsed_secs=120 peak_rss_mb=300 in_grace=false reason=gh-rejected-past-grace\n' \
      "$((i+1))" "$((100+i))" "$((200+i))" "$((i*5)).000" "$wall" \
      >> "$log_path"
  done
  printf 'info: ensure_count up to capacity\n' >> "$log_path"
}

build_slot_file() {
  local slot_path="$1" count="$2"
  local i
  {
    printf '# ezgha slot assignments\n'
    printf 'runner_ids = ['
    for ((i=1; i<=count; i++)); do
      if (( i > 1 )); then printf ', '; fi
      printf '%d' "$((900+i))"
    done
    printf ']\n'
  } > "$slot_path"
}

# Run alert script with given env overrides; echo stdout JSON.
run_alert() {
  local env_prefix="$1"
  local out
  out="$(eval "$env_prefix" "\"$SCRIPT\"")"
  printf '%s\n' "$out"
}

# Extract a value from the JSON payload on stdout.
json_field() {
  local payload="$1" field="$2"
  printf '%s\n' "$payload" | sed -n "s/.*\"$field\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

# Fake doctor-runner stub: prints verdict + 4 counts in a parseable format.
# Args: $1 = stub path, $2 = verdict (ok|fail), $3..$6 = exec/idle_ok/idle_starved/down
make_doctor_stub() {
  local stub_path="$1" verdict="$2" \
        exec_count="$3" idle_ok="$4" idle_starved="$5" down_count="$6"
  cat > "$stub_path" <<STUB
#!/usr/bin/env bash
# fake doctor-runner stub for GH#106 acceptance-gap tests
echo "doctor: $verdict"
echo "executing=$exec_count"
echo "idle_ok=$idle_ok"
echo "idle_starved=$idle_starved"
echo "down=$down_count"
exit 0
STUB
  chmod +x "$stub_path"
}

# ── test 1: doctor-runner degraded overrides hysteresis OK ────────────────
# EZGHA_DOCTOR_RUNNER=1, doctor reports DOWN slots, but low reclaim counts.
# Expect: alert fires (exit 1) because doctor feedback elevates the signal.
test1_doctor_runner_degraded_overrides() {
  local name="test1-doctor-runner-degraded-overrides"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"
  local doctor_stub="${cell_dir}/doctor-runner"

  build_log "$stderr_log" 0  # zero reclaim events
  build_slot_file "$slot_file" 16
  # 2 EXECUTING, 0 IDLE-OK, 0 IDLE-STARVED, 5 DOWN → fail verdict
  make_doctor_stub "$doctor_stub" "fail" 2 0 0 5

  local rc payload
  payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=10 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    EZGHA_DOCTOR_RUNNER=1 \
    DOCTOR_RUNNER_PATH="$doctor_stub" \
    "$SCRIPT"
  )"
  rc=$?

  local verdict down_count
  verdict="$(json_field "$payload" doctor_verdict)"
  down_count="$(json_field "$payload" doctor_down)"

  if [[ "$verdict" != "fail" ]]; then
    fail "${name}: expected doctor_verdict=fail, got '${verdict}'"
  elif [[ "$down_count" != "5" ]]; then
    fail "${name}: expected doctor_down=5, got '${down_count}'"
  elif [[ "$rc" -ne 1 ]]; then
    fail "${name}: expected exit 1 (alert fired), got ${rc} (doctor-down should elevate degraded)"
  else
    echo "PASS: ${name} (rc=${rc}, doctor_verdict=${verdict}, doctor_down=${down_count})"
  fi
}

# ── test 2: CRITICAL stderr scan gated by doctor/container ───────────────
# count_critical_in_window sees >= threshold but doctor=OK AND container_count=OK.
# Expect: alert does NOT fire (false-positive guard). Exit 0.
test2_critical_scan_gated_by_doctor() {
  local name="test2-critical-scan-gated-by-doctor"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"
  local doctor_stub="${cell_dir}/doctor-runner"

  # 5 CRITICAL lines + 0 reclaim events.
  local now i
  now="$(date +%s)"
  : > "$stderr_log"
  for ((i=0; i<5; i++)); do
    printf '%s CRITICAL runner startup settling ceiling reached: 0/6 executing locally\n' \
      "$now" >> "$stderr_log"
  done
  build_slot_file "$slot_file" 16
  # doctor OK + 16 containers → CRITICAL alone must NOT fire.
  make_doctor_stub "$doctor_stub" "ok" 16 0 0 0

  local rc payload
  payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=10 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    EZGHA_DOCTOR_RUNNER=1 \
    DOCTOR_RUNNER_PATH="$doctor_stub" \
    CRITICAL_DEGRADED_THRESHOLD=2 \
    EZGHA_EXPECTED_CAPACITY=16 \
    "$SCRIPT"
  )"
  rc=$?

  local crit_count
  crit_count="$(json_field "$payload" critical_in_window)"

  if [[ "$crit_count" != "5" ]]; then
    fail "${name}: expected critical_in_window=5, got '${crit_count}'"
  elif [[ "$rc" -ne 0 ]]; then
    fail "${name}: expected exit 0 (CRITICAL gated by doctor=OK), got ${rc} (false-positive)"
  else
    echo "PASS: ${name} (rc=${rc}, critical_in_window=${crit_count}, gated correctly)"
  fi
}

# ── test 3: container_count degraded contributes to degraded ─────────────
# EZGHA_EXPECTED_CAPACITY=16, but slot file shows only 4 (or no containers).
# Expect: alert fires (exit 1) due to container_count degradation.
test3_container_count_degraded() {
  local name="test3-container-count-degraded"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"
  local doctor_stub="${cell_dir}/doctor-runner"

  build_log "$stderr_log" 0
  build_slot_file "$slot_file" 4  # only 4 slots filled
  make_doctor_stub "$doctor_stub" "ok" 4 0 0 0

  local rc payload
  payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=10 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    EZGHA_DOCTOR_RUNNER=1 \
    DOCTOR_RUNNER_PATH="$doctor_stub" \
    EZGHA_EXPECTED_CAPACITY=16 \
    "$SCRIPT"
  )"
  rc=$?

  local count expected
  count="$(json_field "$payload" container_count)"
  expected="$(json_field "$payload" expected_capacity)"

  if [[ "$count" != "4" ]]; then
    fail "${name}: expected container_count=4, got '${count}'"
  elif [[ "$expected" != "16" ]]; then
    fail "${name}: expected expected_capacity=16, got '${expected}'"
  elif [[ "$rc" -ne 1 ]]; then
    fail "${name}: expected exit 1 (container_count < expected), got ${rc}"
  else
    echo "PASS: ${name} (rc=${rc}, container_count=${count}, expected=${expected})"
  fi
}

# ── test 4: JSON payload uses 'evidence' not 'reason' ─────────────────────
# Verify the renamed field is present and 'reason' is absent.
test4_evidence_field_renamed() {
  local name="test4-evidence-field-renamed"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  build_log "$stderr_log" 8
  build_slot_file "$slot_file" 16

  local rc payload
  payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=8 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    "$SCRIPT"
  )"
  rc=$?

  local evidence has_reason
  evidence="$(json_field "$payload" evidence)"
  has_reason="$(printf '%s\n' "$payload" | grep -c '"reason":' || true)"

  if [[ "$evidence" != "both-windows-degraded" ]]; then
    fail "${name}: expected evidence='both-windows-degraded', got '${evidence}'"
  elif (( has_reason > 0 )); then
    fail "${name}: payload still contains 'reason' field (count=${has_reason}); expected only 'evidence'"
  else
    echo "PASS: ${name} (rc=${rc}, evidence=${evidence}, no 'reason' field)"
  fi
}

# ── test 5: ALERT_LOG_FILE sink — JSONL appended to file ──────────────────
# When ALERT_LOG_FILE is set and writable, append JSONL on alert fire.
test5_alert_log_file_sink() {
  local name="test5-alert-log-file-sink"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"
  local alert_log="${cell_dir}/alerts.log"

  build_log "$stderr_log" 8
  build_slot_file "$slot_file" 16

  local rc payload
  payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=8 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    ALERT_LOG_FILE="$alert_log" \
    "$SCRIPT"
  )"
  rc=$?

  if [[ ! -f "$alert_log" ]]; then
    fail "${name}: ALERT_LOG_FILE '${alert_log}' not created"
  elif [[ ! -s "$alert_log" ]]; then
    fail "${name}: ALERT_LOG_FILE '${alert_log}' exists but is empty"
  else
    # Verify the JSONL line is parseable JSON (starts with { ends with }).
    local line
    line="$(head -1 "$alert_log")"
    if [[ "$line" != "{"*"}" ]]; then
      fail "${name}: ALERT_LOG_FILE content not JSON: '${line}'"
    elif [[ "$rc" -ne 1 ]]; then
      fail "${name}: expected exit 1 (alert fired), got ${rc}"
    else
      echo "PASS: ${name} (rc=${rc}, log_lines=$(wc -l < "$alert_log" | tr -d ' '))"
    fi
  fi
}

# ── test 6: /var/log fallback when not writable ───────────────────────────
# When ALERT_LOG_FILE points to an unwritable path, fall back to STATE_DIR/alerts.log.
test6_alert_log_fallback() {
  local name="test6-alert-log-fallback"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  build_log "$stderr_log" 8
  build_slot_file "$slot_file" 16

  # Use a path that cannot be written (parent dir doesn't exist and is unwritable).
  local unwritable="/var/log/ezgha-alerts-test-$$.log"
  local fallback_log="${state_dir}/alerts.log"

  local rc payload
  payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=8 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    ALERT_LOG_FILE="$unwritable" \
    "$SCRIPT"
  )"
  rc=$?

  # Expect: alert logged to $STATE_DIR/alerts.log (fallback).
  if [[ -f "$fallback_log" ]] && [[ -s "$fallback_log" ]]; then
    echo "PASS: ${name} (rc=${rc}, fallback log at ${fallback_log})"
  elif [[ "$rc" -ne 1 ]]; then
    fail "${name}: expected exit 1 (alert fired), got ${rc}"
  else
    fail "${name}: fallback log not written to ${fallback_log} (rc=${rc})"
  fi
}

# ── run all ────────────────────────────────────────────────────────────────
echo "=== ezgha-fleet-alert GH#106 acceptance gaps (bead jleechan-vsd1) ==="
test1_doctor_runner_degraded_overrides
test2_critical_scan_gated_by_doctor
test3_container_count_degraded
test4_evidence_field_renamed
test5_alert_log_file_sink
test6_alert_log_fallback

if $PASS; then
  echo "=== ALL 6 ACCEPTANCE-GAP TESTS PASS ==="
  exit 0
else
  echo "=== ACCEPTANCE-GAP TESTS FAILED: ${FAIL_COUNT} failures ===" >&2
  exit 1
fi
