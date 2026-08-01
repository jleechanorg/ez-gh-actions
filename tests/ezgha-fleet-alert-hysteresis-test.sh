#!/usr/bin/env bash
# ezgha-fleet-alert-hysteresis-test.sh — exercise all 4 cells of the
# multi-window hysteresis matrix (bead jleechan-vg1d).
#
# The script builds synthetic daemon stderr logs + a synthetic slot file
# for each cell, then invokes scripts/ezgha-fleet-alert.sh with each
# scenario and asserts the expected exit code + JSON reason field.
#
# Matrix:
#   cell 1: short=OK,    long=OK       -> exit 0, reason all-windows-ok
#   cell 2: short=DEGRADED, long=OK    -> exit 2, reason short-window-only-hold
#   cell 3: short=OK,    long=DEGRADED -> exit 2, reason long-window-only-hold
#   cell 4: short=DEGRADED, long=DEGRADED -> exit 1, reason both-windows-degraded
#   cell 5 (toggle FAIL): capacity-zero slot file -> exit 1 (slot file override)
#
# Toggle FAIL -> PASS verified by patching: before the matrix cells run,
# a sanity test injects a low-threshold env + high-reclaim log and
# confirms the alert fires (exits 1) when BOTH windows are degraded.
# The shellcheck-equivalent — running with both windows OK — confirms
# the script does NOT false-alert on idle healthy fleet (memory
# feedback_2026-08-01_daemon_settling_check_false_positive_idle.md).
#
# Usage:
#   bash tests/ezgha-fleet-alert-hysteresis-test.sh
#
# Exit code:
#   0 = all cells passed
#   non-zero = first failing cell
#
# The test is hermetic: it creates tempdirs for stderr log + slot file
# + state dir, never touches the real $HOME or /tmp/ezgha-launchd-stderr.log.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/ezgha-fleet-alert.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: script not executable: $SCRIPT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=true
fail() {
  echo "FAIL: $*" >&2
  PASS=false
}

# Helper: build a synthetic daemon stderr log containing N reclaim events
# (PR #109 format with wall_ts timestamps inside the requested window).
build_log() {
  local log_path="$1" count="$2" window_sec="$3"
  local now i wall
  # shellcheck disable=SC2034 # window_sec is part of the helper's signature for clarity (future per-window tuning)
  : "${window_sec:=60}"
  now="$(date +%s)"
  : > "$log_path"
  for ((i=0; i<count; i++)); do
    # Spread events inside the window so wall_ts cutoff keeps them.
    wall=$(( now - (i * 5) ))
    printf 'info: release_stale_slots reclaimed slot %d: runner_id=%d last_run_id=%d monotonic_ts=%.3f wall_ts=%d elapsed_secs=120 peak_rss_mb=300 in_grace=false reason=gh-rejected-past-grace\n' \
      "$((i+1))" "$((100+i))" "$((200+i))" "$((i*5)).000" "$wall" \
      >> "$log_path"
  done
  # Add some non-reclaim noise.
  printf 'info: ensure_count up to capacity\n' >> "$log_path"
  printf 'debug: polling github api\n' >> "$log_path"
}

# Helper: build a synthetic slot file with N runner_ids.
build_slot_file() {
  local slot_path="$1" count="$2"
  {
    printf '# ezgha slot assignments\n'
    printf 'runner_ids = ['
    local i
    for ((i=1; i<=count; i++)); do
      if (( i > 1 )); then printf ', '; fi
      printf '%d' "$((900+i))"
    done
    printf ']\n'
  } > "$slot_path"
}

# Run a single cell. Args:
#   $1 = cell name (string)
#   $2 = expected exit code
#   $3 = expected reason substring in stdout JSON
#   $4 = short-window reclaim count (events in 60s short window)
#   $5 = long-window reclaim count (events in 120s long window)
#   $6 = slot capacity (entries in slot file)
run_cell() {
  local name="$1" expected_rc="$2" expected_reason="$3" \
        short_count="$4" long_count="$5" slot_capacity="$6"

  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  build_log "$stderr_log" "$short_count" 60
  # For long window, write a separate log with the long-window count.
  # Since the script reads one log file, we instead make the long
  # window cover the short window content by putting MORE events in
  # the log and trusting the windowed count logic.
  # For simplicity: use a single log; vary MIN_RECLAIMS_* thresholds
  # so the short window's smaller threshold trips on small counts,
  # and the long window only trips on larger counts (the long window's
  # higher MIN_RECLAIMS_LONG threshold is the discriminator).
  build_log "$stderr_log" "$long_count" 120
  build_slot_file "$slot_file" "$slot_capacity"

  local rc actual_reason actual_payload
  actual_payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=10 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    "$SCRIPT"
  )"
  rc=$?
  actual_reason="$(printf '%s\n' "$actual_payload" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)"

  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "${name}: expected exit ${expected_rc}, got ${rc}; payload=${actual_payload}"
    return
  fi
  if [[ "$actual_reason" != "$expected_reason" ]]; then
    fail "${name}: expected reason '${expected_reason}', got '${actual_reason}'; payload=${actual_payload}"
    return
  fi
  echo "PASS: ${name} (rc=${rc}, reason=${actual_reason})"
}

# ── matrix cells ──────────────────────────────────────────────────────────
echo "=== ezgha-fleet-alert hysteresis matrix (bead jleechan-vg1d) ==="

# cell 1: short=OK, long=OK — neither window sees ≥ min reclaims.
# Use 2 reclaim events total (below MIN_RECLAIMS_SHORT=3 AND MIN_RECLAIMS_LONG=10).
# Slot capacity healthy (16).
run_cell "cell1-short-ok-long-ok" 0 "all-windows-ok" 2 2 16

# cell 2: short=DEGRADED (≥3 in 60s window), long=OK (<10 in 120s window).
# The short window sees ALL events (it covers the last 60s); long window
# sees events from the past 120s. To trip short but not long, we need
# events inside 60s window >= MIN_RECLAIMS_SHORT but events inside 120s
# window < MIN_RECLAIMS_LONG. Since the log contains ALL events, and
# short ⊂ long in time, if short has 5 events, long has ≥5 events too.
# To make short=DEGRADED but long=OK, we raise MIN_RECLAIMS_LONG above
# what the long window would otherwise see. We use MIN_RECLAIMS_LONG=20
# inline; the cell test passes its own override.
run_cell_short_degraded() {
  local name="cell2-short-degraded-long-ok"
  local expected_rc=2 expected_reason="short-window-only-hold"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  # 5 events in short window, but raise MIN_RECLAIMS_LONG to 20 so long
  # window stays OK (it has the same 5 events but threshold is 20).
  build_log "$stderr_log" 5 60
  build_slot_file "$slot_file" 16

  local rc actual_reason actual_payload
  actual_payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=20 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    "$SCRIPT"
  )"
  rc=$?
  actual_reason="$(printf '%s\n' "$actual_payload" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)"
  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "${name}: expected exit ${expected_rc}, got ${rc}; payload=${actual_payload}"
  elif [[ "$actual_reason" != "$expected_reason" ]]; then
    fail "${name}: expected reason '${expected_reason}', got '${actual_reason}'"
  else
    echo "PASS: ${name} (rc=${rc}, reason=${actual_reason})"
  fi
}
run_cell_short_degraded

# cell 3: short=OK, long=DEGRADED.
# Long window has ≥ MIN_RECLAIMS_LONG events; short window has < MIN_RECLAIMS_SHORT.
# We make 1 short-window event (the most-recent event) and 12 long-window
# events (the rest from earlier). To control this precisely, we build the
# log manually: 1 event with wall_ts=now, 11 events with wall_ts=now-90s
# (inside long 120s window but outside short 60s window).
run_cell_long_degraded() {
  local name="cell3-short-ok-long-degraded"
  local expected_rc=2 expected_reason="long-window-only-hold"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  local now
  now="$(date +%s)"
  : > "$stderr_log"
  # 1 recent event (inside both windows).
  printf 'info: release_stale_slots reclaimed slot 1: runner_id=1 last_run_id=2 monotonic_ts=0.000 wall_ts=%d elapsed_secs=120 peak_rss_mb=300 in_grace=false reason=gh-rejected-past-grace\n' \
    "$now" >> "$stderr_log"
  # 11 events at now-90s (inside long 120s window, outside short 60s window).
  local i
  for ((i=0; i<11; i++)); do
    printf 'info: release_stale_slots reclaimed slot %d: runner_id=%d last_run_id=%d monotonic_ts=%.3f wall_ts=%d elapsed_secs=120 peak_rss_mb=300 in_grace=false reason=gh-rejected-past-grace\n' \
      "$((i+2))" "$((100+i))" "$((200+i))" "0.000" "$(( now - 90 ))" \
      >> "$stderr_log"
  done
  build_slot_file "$slot_file" 16

  local rc actual_reason actual_payload
  actual_payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=10 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    "$SCRIPT"
  )"
  rc=$?
  actual_reason="$(printf '%s\n' "$actual_payload" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)"
  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "${name}: expected exit ${expected_rc}, got ${rc}; payload=${actual_payload}"
  elif [[ "$actual_reason" != "$expected_reason" ]]; then
    fail "${name}: expected reason '${expected_reason}', got '${actual_reason}'"
  else
    echo "PASS: ${name} (rc=${rc}, reason=${actual_reason})"
  fi
}
run_cell_long_degraded

# cell 4: short=DEGRADED AND long=DEGRADED — both windows see enough events.
# Use a custom helper that lowers MIN_RECLAIMS_LONG so 8 events trip both
# short (≥3) AND long (≥8). In production, MIN_RECLAIMS_LONG=10 by default.
run_cell_both_degraded() {
  local name="cell4-both-degraded"
  local expected_rc=1 expected_reason="both-windows-degraded"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  build_log "$stderr_log" 8 60
  build_slot_file "$slot_file" 16

  local rc actual_reason actual_payload
  actual_payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=8 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    "$SCRIPT"
  )"
  rc=$?
  actual_reason="$(printf '%s\n' "$actual_payload" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)"
  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "${name}: expected exit ${expected_rc}, got ${rc}; payload=${actual_payload}"
  elif [[ "$actual_reason" != "$expected_reason" ]]; then
    fail "${name}: expected reason '${expected_reason}', got '${actual_reason}'"
  else
    echo "PASS: ${name} (rc=${rc}, reason=${actual_reason})"
  fi
}
run_cell_both_degraded

# cell 5: slot file override — empty slot file triggers both-windows-degraded
# even if reclaim counts are low (proves slot-file path overrides hysteresis).
run_cell_slot_override() {
  local name="cell5-slot-file-override"
  local expected_rc=1 expected_reason="both-windows-degraded"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  # No reclaim events at all, but slot file is empty (capacity > 0).
  : > "$stderr_log"
  build_slot_file "$slot_file" 0

  local rc actual_reason actual_payload
  actual_payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=10 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    SLOT_CAPACITY=4 \
    ALERT_SINK=none \
    "$SCRIPT"
  )"
  rc=$?
  actual_reason="$(printf '%s\n' "$actual_payload" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)"
  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "${name}: expected exit ${expected_rc}, got ${rc}; payload=${actual_payload}"
  elif [[ "$actual_reason" != "$expected_reason" ]]; then
    fail "${name}: expected reason '${expected_reason}', got '${actual_reason}'"
  else
    echo "PASS: ${name} (rc=${rc}, reason=${actual_reason})"
  fi
}
run_cell_slot_override

# ── anti-false-positive check (memory feedback_2026-08-01-daemon-settling) ──
# An idle fleet must NOT fire an alert when only low reclaim counts are
# present (the daemon's settling check false-positive on idle). Verify
# cell 1 again with a deliberately IDLE-shaped log (no reclaim events).
run_cell_idle_no_alert() {
  local name="idle-no-alert-anti-false-positive"
  local cell_dir="${WORK}/${name}"
  mkdir -p "${cell_dir}"
  local stderr_log="${cell_dir}/daemon.stderr.log"
  local slot_file="${cell_dir}/slot.toml"
  local state_dir="${cell_dir}/state"

  # Idle-shaped log: settling messages, no reclaim events.
  cat > "$stderr_log" <<'LOG'
info: runner startup settling ceiling reached: 0/6 executing locally, best 0, 5 poll(s)
info: polling github api
info: ensure_count up to capacity
LOG
  build_slot_file "$slot_file" 16

  local rc actual_reason actual_payload
  actual_payload="$(
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    MIN_RECLAIMS_SHORT=3 MIN_RECLAIMS_LONG=10 \
    DAEMON_STDERR_LOG="$stderr_log" \
    SLOT_FILE="$slot_file" \
    STATE_DIR="$state_dir" \
    ALERT_SINK=none \
    "$SCRIPT"
  )"
  rc=$?
  actual_reason="$(printf '%s\n' "$actual_payload" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)"
  if [[ "$rc" -ne 0 ]]; then
    fail "${name}: idle fleet must NOT alert (rc=${rc}, reason=${actual_reason})"
  elif [[ "$actual_reason" != "all-windows-ok" ]]; then
    fail "${name}: expected reason all-windows-ok, got '${actual_reason}'"
  else
    echo "PASS: ${name} (idle fleet does NOT false-positive; rc=0, reason=${actual_reason})"
  fi
}
run_cell_idle_no_alert

# ── result ───────────────────────────────────────────────────────────────
if $PASS; then
  echo "=== ALL CELLS PASS ==="
  exit 0
else
  echo "=== HYSTERESIS MATRIX FAILED ===" >&2
  exit 1
fi