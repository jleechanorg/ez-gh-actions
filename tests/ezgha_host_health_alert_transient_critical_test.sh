#!/usr/bin/env bash
# Hermetic regression coverage for bead jleechan-fals-fleet-down-memory-pressure.
#
# Measured failure (2026-11-07 21:14-21:18Z on jeff-ubuntu): the host-health
# check promoted a transient `runner_pool.memory_pressure` daemon CRITICAL into
# cause=fleet and dispatched three "FLEET DOWN" ERROR entries while 15-20 managed
# containers were actively carrying a Runner.Worker, and the daemon itself logged
# `runner startup settled: 20/20 ready locally`. The fleet was running jobs; the
# page claimed it could not.
#
# The contract asserted here:
#   1. A transient admission-deferral CRITICAL never produces cause=fleet.
#   2. It is still recorded (not silently dropped) — at WARNING, on its own cause.
#   3. A genuine capacity CRITICAL still pages cause=fleet (no over-suppression).
#   4. An unknown CRITICAL key keeps the historical fail-closed page.
#
# Everything is driven by the script's HEALTH_ALERT_* audit hooks; no docker,
# ssh, systemctl or gcloud is contacted.
#
# Usage: bash tests/ezgha_host_health_alert_transient_critical_test.sh
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/ezgha-host-health-alert.sh"
W="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${W:?}"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$W/gcloud"

NOW=$(date +%s)
state_dir() { mkdir -p "$W/state-$1"; }

# run <case> <free_gb> <container_count> [extra env...]
run() {
  local case="$1" free="$2" cnt="$3"; shift 3
  state_dir "$case"
  env \
    GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-$case" \
    HEALTH_ALERT_HOST="testhost" HEALTH_ALERT_PLATFORM="Linux" \
    HEALTH_ALERT_STATE_DIR="$W/state-$case" \
    HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
    HEALTH_ALERT_PEER_FREE_GB=100 HEALTH_ALERT_PEER_CONTAINERS=4 HEALTH_ALERT_PEER_SERVICE=active \
    HEALTH_ALERT_FREE_GB="$free" HEALTH_ALERT_CONTAINER_COUNT="$cnt" \
    "$@" "$S" >"$W/out-$case" 2>"$W/err-$case" || true
}
log_of() { echo "$W/log-$1"; }
errors() { local l; l="$(log_of "$1")"; [ -f "$l" ] && grep -c -- "--severity=ERROR" "$l" || true; }
warnings() { local l; l="$(log_of "$1")"; [ -f "$l" ] && grep -c -- "--severity=WARNING" "$l" || true; }
fleet_cause() { local l; l="$(log_of "$1")"; [ -f "$l" ] && grep -c '"cause":"fleet"' "$l" || true; }

crit_file() { # path key
  printf '{"body":"x","event_key":"%s","severity":"CRITICAL","subject":"s","ts_unix":%s}\n' "$2" "$(( NOW - 60 ))" > "$1"
}

# ── 1. The measured false page: memory_pressure + 20 live containers ────────
crit_file "$W/alerts-mem.jsonl" "runner_pool.memory_pressure"
run mem 100 20 HEALTH_ALERT_ALERTS_FILE="$W/alerts-mem.jsonl"
[ "$(fleet_cause mem)" = 0 ] \
  || { cat "$(log_of mem)" >&2; fail "a transient memory_pressure CRITICAL must never emit cause=fleet"; }
[ "$(errors mem)" = 0 ] \
  || fail "a transient memory_pressure CRITICAL must not page at ERROR"
pass "transient memory_pressure CRITICAL does not page as a fleet outage"

# ── 2. It is still recorded, at WARNING, on its own cause ──────────────────
[ "$(warnings mem)" = 1 ] || { cat "$(log_of mem)" >&2; fail "the suppressed CRITICAL must still be recorded at WARNING"; }
grep -q '"cause":"operational"' "$(log_of mem)" \
  || { cat "$(log_of mem)" >&2; fail "the record must carry cause=operational, not fleet or disk"; }
grep -q 'memory_pressure' "$(log_of mem)" \
  || fail "the record must name the CRITICAL key so it is diagnosable"
pass "the transient CRITICAL is still recorded (WARNING, cause=operational, key named)"

# ── 3. A genuine capacity CRITICAL still pages cause=fleet ────────────────
crit_file "$W/alerts-cap.jsonl" "runner_pool.disk_measurement_unavailable"
run cap 100 0 HEALTH_ALERT_ALERTS_FILE="$W/alerts-cap.jsonl"
[ "$(fleet_cause cap)" = 1 ] \
  || { cat "$(log_of cap)" >&2; fail "a capacity CRITICAL with 0 containers must still page cause=fleet"; }
[ "$(errors cap)" = 1 ] || fail "a capacity CRITICAL must page at ERROR"
pass "genuine capacity CRITICAL still pages cause=fleet (no over-suppression)"

# ── 4. An unknown key keeps the historical fail-closed page ───────────────
crit_file "$W/alerts-unk.jsonl" "runner_pool.some_future_capacity_key"
run unk 100 0 HEALTH_ALERT_ALERTS_FILE="$W/alerts-unk.jsonl"
[ "$(fleet_cause unk)" = 1 ] \
  || { cat "$(log_of unk)" >&2; fail "an unrecognized CRITICAL key must not be silently downgraded"; }
pass "unrecognized CRITICAL key keeps the fail-closed cause=fleet page"

# ── 5. Zero containers + transient key: the 0-container probe still pages ──
# The transient exemption must not mask a genuinely empty fleet.
run mem0 100 0 HEALTH_ALERT_ALERTS_FILE="$W/alerts-mem.jsonl"
[ "$(errors mem0)" = 1 ] \
  || { cat "$(log_of mem0)" >&2; fail "0 containers must page regardless of the transient key"; }
grep -q '0 ezgha runner containers running' "$(log_of mem0)" \
  || fail "the 0-container probe must be the reason cited"
pass "0-container truth still pages even with a transient CRITICAL present"

echo "ALL PASS: transient daemon CRITICALs no longer masquerade as fleet outages"
