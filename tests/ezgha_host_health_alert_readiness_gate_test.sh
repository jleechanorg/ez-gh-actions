#!/usr/bin/env bash
# Hermetic regression coverage for bead jleechan-obei.
#
# Measured failure (2026-11-21 04:46:28Z-04:56Z UTC on jeff-ubuntu): the
# host-health check promoted the readiness-layer `serve.runner_settling.ceiling`
# daemon CRITICAL into cause=fleet and dispatched "[CRITICAL] ezgha runner fleet
# down" / a FLEET DOWN ERROR entry while the same host reported
#   - 20/20 managed containers running (docker ps --filter label=ezgha=managed),
#   - 20 online + 20 busy ez-runner registrations (org roster, 0 offline),
#   - `runner startup settled: 20/20 ready locally` at 04:51:49Z,
#   - 14 worldarchitect.ai jobs in progress.
# The policy this feeds promises the fleet "cannot run jobs"; it was running them.
#
# The contract asserted here:
#   1. A readiness/settling CRITICAL with containers present never pages cause=fleet.
#   2. It is still recorded (WARNING, cause=operational, key named).
#   3. With 0 containers the same key still pages cause=fleet (fail closed).
#   4. With an unreachable docker daemon it still pages cause=fleet (fail closed).
#   5. A readiness note must not mask a coexisting genuine capacity CRITICAL.
#   6. An unknown CRITICAL key keeps the historical fail-closed page.
#
# Everything is driven by the script's HEALTH_ALERT_* audit hooks; no docker,
# ssh, systemctl or gcloud is contacted.
#
# Usage: bash tests/ezgha_host_health_alert_readiness_gate_test.sh
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${HEALTH_ALERT_SCRIPT_UNDER_TEST:-$ROOT/scripts/ezgha-host-health-alert.sh}"
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

# docker stub whose `info` fails: models the "daemon unreachable" probe.
cat > "$W/docker-dead" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "info" ] && exit 1
exit 1
STUB
chmod +x "$W/docker-dead"

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

crit_file() { # path key [age_seconds]
  printf '{"body":"x","event_key":"%s","severity":"CRITICAL","subject":"s","ts_unix":%s}\n' "$2" "$(( NOW - ${3:-60} ))" > "$1"
}

CEILING="serve.runner_settling.ceiling"

# ── 1. The measured false page: settling ceiling + 20 live containers ───────
crit_file "$W/alerts-ceil.jsonl" "$CEILING"
run ceil 122 20 HEALTH_ALERT_ALERTS_FILE="$W/alerts-ceil.jsonl"
[ "$(fleet_cause ceil)" = 0 ] \
  || { cat "$(log_of ceil)" >&2; fail "a settling-ceiling CRITICAL with 20 containers must never emit cause=fleet"; }
[ "$(errors ceil)" = 0 ] \
  || { cat "$(log_of ceil)" >&2; fail "a settling-ceiling CRITICAL with 20 containers must not page at ERROR"; }
pass "settling ceiling with 20 serving containers does not page as a fleet outage"

# ── 2. Still recorded, at WARNING, on its own cause, naming the key ────────
[ "$(warnings ceil)" = 1 ] || { cat "$(log_of ceil)" >&2; fail "the suppressed CRITICAL must still be recorded at WARNING"; }
grep -q '"cause":"operational"' "$(log_of ceil)" \
  || { cat "$(log_of ceil)" >&2; fail "the record must carry cause=operational, not fleet or disk"; }
grep -q "$CEILING" "$(log_of ceil)" || fail "the record must name the CRITICAL key so it is diagnosable"
grep -q '20 container(s) are serving' "$(log_of ceil)" \
  || { cat "$(log_of ceil)" >&2; fail "the note must state the observed serving capacity"; }
pass "the readiness CRITICAL is still recorded (WARNING, cause=operational, key + count named)"

# ── 3. A single container short is still serving: 18 containers no page ────
run ceil18 122 18 HEALTH_ALERT_ALERTS_FILE="$W/alerts-ceil.jsonl"
[ "$(fleet_cause ceil18)" = 0 ] \
  || { cat "$(log_of ceil18)" >&2; fail "18 serving containers must not page cause=fleet"; }
[ "$(errors ceil18)" = 0 ] || fail "18 serving containers must not page at ERROR"
pass "a partial-but-serving fleet (18 containers) does not page as a fleet outage"

# ── 4. Zero containers: the same key still pages (fail closed) ─────────────
run ceil0 122 0 HEALTH_ALERT_ALERTS_FILE="$W/alerts-ceil.jsonl"
[ "$(errors ceil0)" = 1 ] \
  || { cat "$(log_of ceil0)" >&2; fail "0 containers must page regardless of the readiness key"; }
grep -q '0 ezgha runner containers running' "$(log_of ceil0)" \
  || fail "the 0-container probe must be the reason cited"
pass "0-container truth still pages even with a readiness CRITICAL present"

# ── 5. Unreachable docker daemon: still pages (fail closed) ────────────────
state_dir ceildocker
env \
  GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-ceildocker" \
  DOCKER_BIN="$W/docker-dead" \
  HEALTH_ALERT_HOST="testhost" HEALTH_ALERT_PLATFORM="Linux" \
  HEALTH_ALERT_STATE_DIR="$W/state-ceildocker" \
  HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
  HEALTH_ALERT_PEER_FREE_GB=100 HEALTH_ALERT_PEER_CONTAINERS=4 HEALTH_ALERT_PEER_SERVICE=active \
  HEALTH_ALERT_FREE_GB=122 \
  HEALTH_ALERT_ALERTS_FILE="$W/alerts-ceil.jsonl" \
  "$S" >"$W/out-ceildocker" 2>"$W/err-ceildocker" || true
[ "$(errors ceildocker)" = 1 ] \
  || { cat "$W/log-ceildocker" "$W/err-ceildocker" >&2; fail "an unreachable docker daemon must still page"; }
grep -q '"cause":"fleet"' "$W/log-ceildocker" \
  || { cat "$W/log-ceildocker" >&2; fail "an unreachable docker daemon must page as cause=fleet"; }
pass "an unreachable docker daemon still pages cause=fleet (unknown is never read as healthy)"

# ── 6. The readiness note must not mask a coexisting capacity CRITICAL ─────
MIXED="$W/alerts-mixed.jsonl"
crit_file "$MIXED" "runner_pool.disk_measurement_unavailable" 120
printf '{"body":"x","event_key":"%s","severity":"CRITICAL","subject":"ceil","ts_unix":%s}\n' "$CEILING" "$(( NOW - 60 ))" >> "$MIXED"
run mixed 122 20 HEALTH_ALERT_ALERTS_FILE="$MIXED"
grep -q '"cause":"fleet"' "$(log_of mixed)" \
  || { cat "$(log_of mixed)" >&2; fail "a capacity CRITICAL must still page beside a readiness note"; }
grep -q 'disk_measurement_unavailable' "$(log_of mixed)" \
  || fail "the page must name the capacity key that triggered it"
pass "a readiness note does not mask a coexisting genuine capacity CRITICAL"

# ── 7. An unknown key keeps the historical fail-closed page ───────────────
crit_file "$W/alerts-unk.jsonl" "runner_pool.some_future_readiness_key"
run unk 122 20 HEALTH_ALERT_ALERTS_FILE="$W/alerts-unk.jsonl"
[ "$(fleet_cause unk)" = 1 ] \
  || { cat "$(log_of unk)" >&2; fail "an unrecognized CRITICAL key must not be silently downgraded"; }
pass "unrecognized CRITICAL key keeps the fail-closed cause=fleet page"

echo "ALL PASS: a readiness ceiling with capacity serving no longer masquerades as a fleet outage"
