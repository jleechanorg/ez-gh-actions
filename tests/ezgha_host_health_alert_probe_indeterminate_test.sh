#!/usr/bin/env bash
# Hermetic coverage for bead jleechan-q0ms: a docker-CLI probe timeoout must not
# page CRITICAL cause=fleet while dockerd is alive and containers keep serving.
#
# Measured failure (2026-11-19 on jeff-ubuntu, alert 0.of74h15h854p):
#   12:48:27Z DOWN cause=fleet severity=CRITICAL container_count=0 free_gb=81,
#             sole failed_check "local: docker daemon unreachable or timed out",
#   12:50:04Z RECOVERED with 15 containers, and at 12:56Z `docker info` answered
#             in 0.12s with 20/20 ez-runner-c-* containers running.
# The host was memory-starved (swap 16,376/16,383MB, load 176 on 32 CPUs) and
# the single `timeout 10 docker info` was simply too slow to answer.
#
# The contract asserted here:
#   1. Probe timeout + dockerd ALIVE -> WARNING cause=probe, never cause=fleet,
#      and the container count is reported unknown (-1), never a live 0.
#   2. Daemon CONFIRMED down -> unchanged cause=fleet CRITICAL page.
#   3. No independent liveness signal (or non-Linux) -> unchanged fail-closed
#      cause=fleet page, so this change cannot hide a dead daemon.
#   4. Probe indeterminate for >= PROBE_PAGE_AFTER_MIN -> escalates to
#      cause=fleet CRITICAL so a genuinely wedged daemon still pages.
#   5. Healthy host -> no entries at all (regression guard).
#
# Every path runs the real script: docker/gcloud/timeout are stubs on PATH (and
# DOCKER_BIN/GCLOUD_BIN), while probe outcomes come from the script's existing
# env seams. The local `timeout` shim keeps behaviour identical on macOS, which
# has no coreutils `timeout`.
#
# Usage: bash tests/ezgha_host_health_alert_probe_indeterminate_test.sh
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

mkdir -p "$W/bin"
# `timeout <secs> cmd...`: ignore the budget, run the command. Test-only.
cat > "$W/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB
# docker stub: DOCKER_INFO_RC drives `docker info`, DOCKER_PS_RC/`DOCKER_PS_N`
# drive `docker ps` (failure vs managed-container count).
cat > "$W/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "${1:-}" >> "${DOCKER_LOG:-/dev/null}"
case "${1:-}" in
  info) exit "${DOCKER_INFO_RC:-0}" ;;
  ps)
    if [ "${DOCKER_PS_RC:-0}" -ne 0 ]; then exit "${DOCKER_PS_RC}"; fi
    i=0
    while [ "$i" -lt "${DOCKER_PS_N:-0}" ]; do echo "container-$i"; i=$((i + 1)); done
    ;;
esac
exit 0
STUB
# No systemd bus and no daemon process unless the test says otherwise: these
# stubs make the "no independent signal" path deterministic on every host
# (GitHub's ubuntu runner runs a real dockerd, this Mac has no /var/run/docker.pid).
cat > "$W/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$W/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "${1:-}" = logging ] && [ "${2:-}" = write ]; then printf '%s' "${4:-}" > "${STUB_PAYLOAD:-/dev/null}"; fi
exit 0
STUB
chmod +x "$W/bin/timeout" "$W/bin/docker" "$W/bin/systemctl" "$W/bin/pgrep" "$W/bin/gcloud"

NOW=$(date +%s)
log_of() { echo "$W/log-$1"; }
docker_of() { echo "$W/docker-$1"; }
payload_of() { echo "$W/payload-$1"; }
# probe_info_calls <case>: how many `docker info` probes the script actually ran
probe_info_calls() { if [ -f "$(docker_of "$1")" ]; then grep -c '^info$' "$(docker_of "$1")" || true; else echo 0; fi; }
errors() { local l; l="$(log_of "$1")"; if [ -f "$l" ]; then grep -c -- "--severity=ERROR" "$l" || true; else echo 0; fi; }
warnings() { local l; l="$(log_of "$1")"; if [ -f "$l" ]; then grep -c -- "--severity=WARNING" "$l" || true; else echo 0; fi; }
fleet_entries() { local l; l="$(log_of "$1")"; if [ -f "$l" ]; then grep -c '"cause":"fleet"' "$l" || true; else echo 0; fi; }
probe_entries() { local l; l="$(log_of "$1")"; if [ -f "$l" ]; then grep -c '"cause":"probe"' "$l" || true; else echo 0; fi; }

state_file() { echo "$W/state-$1/host-health-alert-testhost.json"; }
seed_state() { # case status probe_since
  mkdir -p "$W/state-$1"
  printf '{"status":"%s", "last_sent_fleet":0, "last_sent_disk":0, "disk_breach_since":0, "probe_indeterminate_since":%s, "updated_at":"x"}\n' \
    "$2" "$3" > "$(state_file "$1")"
}

# run <case> <free_gb> [extra env...] — CONTAINER_COUNT is left unset on purpose:
# the probe must run for real against the docker stub.
run() {
  local case="$1" free="$2"; shift 2
  mkdir -p "$W/state-$case"
  env \
    PATH="$W/bin:$PATH" \
    GCLOUD_BIN="$W/bin/gcloud" STUB_LOG="$(log_of "$case")" STUB_PAYLOAD="$(payload_of "$case")" \
    DOCKER_BIN="$W/bin/docker" DOCKER_LOG="$(docker_of "$case")" \
    HEALTH_ALERT_HOST=testhost HEALTH_ALERT_PLATFORM=Linux \
    HEALTH_ALERT_STATE_DIR="$W/state-$case" \
    HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
    HEALTH_ALERT_PEER_FREE_GB=100 HEALTH_ALERT_PEER_CONTAINERS=4 HEALTH_ALERT_PEER_SERVICE=active \
    HEALTH_ALERT_FREE_GB="$free" HEALTH_ALERT_ALERTS_FILE="$W/alerts-none.jsonl" \
    HEALTH_ALERT_PROBE_BACKOFF_SEC=0 HEALTH_ALERT_DOCKER_PIDFILE="$W/no-such-docker.pid" \
    "$@" "$S" >"$W/out-$case" 2>"$W/err-$case" || true
}

# ── 1. Probe timeout, dockerd alive: WARNING cause=probe, never a fleet page ─
run probe_alive 81 DOCKER_INFO_RC=1 HEALTH_ALERT_DOCKERD_ALIVE=1
[ "$(errors probe_alive)" = 0 ] \
  || { cat "$(log_of probe_alive)" "$W/err-probe_alive" 2>/dev/null >&2; fail "an alive-but-unanswerable dockerd must not page ERROR"; }
[ "$(fleet_entries probe_alive)" = 0 ] || fail "probe timeout with a live daemon must not emit cause=fleet"
[ "$(warnings probe_alive)" = 1 ] || fail "probe timeout with a live daemon must still be recorded at WARNING"
[ "$(probe_entries probe_alive)" = 1 ] || fail "the record must carry cause=probe"
grep -q -- "--severity=WARNING" "$(log_of probe_alive)" \
  || fail "the emitted entry must be written at WARNING severity"
jq -e '.status == "DEGRADED" and .cause == "probe"' "$(payload_of probe_alive)" > /dev/null \
  || { jq . "$(payload_of probe_alive)" >&2; fail "payload must be DEGRADED cause=probe"; }
# Spec item 4: an unknown count is never a live-looking 0.
jq -e '.container_count == -1 and .container_count_known == false' "$(payload_of probe_alive)" > /dev/null \
  || { jq . "$(payload_of probe_alive)" >&2; fail "an unknown container count must be reported as -1 with container_count_known=false"; }
jq -e '[.failed_checks[] | select(test("docker CLI probe timed out \\(daemon active\\)"))] | length == 1' \
  "$(payload_of probe_alive)" > /dev/null || { jq . "$(payload_of probe_alive)" >&2; fail "failed_checks must name the timed-out CLI probe and the live daemon"; }
# Not a text grep: the CLI severity + cause pair is exactly what the
# `severity>=ERROR AND jsonPayload.cause="fleet"` policy evaluates.
grep -q -- '--severity=ERROR' "$(log_of probe_alive)" && fail "must not dispatch ERROR"
pass "probe timeout + live dockerd -> WARNING cause=probe, count unknown (-1), no fleet page"

# ── 2. The probe was actually retried before the daemon was consulted ───────
[ "$(probe_info_calls probe_alive)" = 3 ] \
  || fail "expected 3 docker info attempts, saw $(probe_info_calls probe_alive)"
pass "the daemon probe is retried 3x before any verdict"

# ── 3. Transition-only: a second indeterminate poll writes no new entry ─────
cp "$(log_of probe_alive)" "$W/log-probe_alive.before"
run probe_alive 81 DOCKER_INFO_RC=1 HEALTH_ALERT_DOCKERD_ALIVE=1
[ "$(warnings probe_alive)" = 1 ] || fail "a repeated indeterminate poll must not re-log every interval"
[ "$(errors probe_alive)" = 0 ] || fail "a repeated indeterminate poll must not page"
grep -q '"status":"PROBE"' "$(state_file probe_alive)" || { cat "$(state_file probe_alive)" >&2; fail "state must record the PROBE verdict"; }
grep -q '"probe_indeterminate_since":[1-9]' "$(state_file probe_alive)" || { cat "$(state_file probe_alive)" >&2; fail "state must record when the probe became indeterminate"; }
pass "repeat polls stay silent and persist probe_indeterminate_since"

# ── 4. Probe heals: RECOVERED cause=probe, no page ─────────────────────────
run probe_alive 81 DOCKER_INFO_RC=0 DOCKER_PS_N=20
[ "$(errors probe_alive)" = 0 ] || fail "recovery must not page"
grep -q '"status":"RECOVERED"' "$(log_of probe_alive)" || { cat "$(log_of probe_alive)" >&2; fail "recovery must emit a RECOVERED entry"; }
grep -q '"status":"RECOVERED", "cause":"probe"' "$(log_of probe_alive)" \
  || { cat "$(log_of probe_alive)" >&2; fail "the recovery entry must name cause=probe"; }
grep -q '"status":"OK"' "$(state_file probe_alive)" || fail "recovery must reset state to OK"
pass "a healed probe emits RECOVERED cause=probe and resets state"

# ── 5. Daemon CONFIRMED down: unchanged immediate cause=fleet CRITICAL ─────
run daemon_down 81 DOCKER_INFO_RC=1 HEALTH_ALERT_DOCKERD_ALIVE=0
[ "$(errors daemon_down)" = 1 ] || { cat "$(log_of daemon_down)" >&2; fail "a dead daemon must page immediately"; }
[ "$(fleet_entries daemon_down)" = 1 ] || fail "a dead daemon must page cause=fleet"
[ "$(probe_entries daemon_down)" = 0 ] || fail "a dead daemon must not be downgraded to cause=probe"
grep -q 'docker daemon unreachable or timed out' "$(log_of daemon_down)" || fail "the page must keep the historical failed_check text"
jq -e '.status == "DOWN" and .container_count == 0 and .container_count_known == true' "$(payload_of daemon_down)" > /dev/null \
  || { jq . "$(payload_of daemon_down)" >&2; fail "a dead daemon reports a known 0-container fleet"; }
pass "daemon confirmed down still pages cause=fleet CRITICAL immediately"

# ── 6. No independent signal: fail closed, exactly as before ───────────────
run no_signal 81 DOCKER_INFO_RC=1
[ "$(errors no_signal)" = 1 ] || { cat "$(log_of no_signal)" >&2; fail "without a liveness signal the verdict must stay fail-closed"; }
[ "$(fleet_entries no_signal)" = 1 ] || fail "no liveness signal must still page cause=fleet"
[ "$(probe_entries no_signal)" = 0 ] || fail "no liveness signal must never produce cause=probe"
pass "no independent liveness signal keeps the fail-closed cause=fleet page"

# ── 7. Darwin/colima keeps today's behaviour (no out-of-band source) ───────
run darwin_timeout 81 HEALTH_ALERT_PLATFORM=Darwin DOCKER_INFO_RC=1
[ "$(errors darwin_timeout)" = 1 ] || { cat "$(log_of darwin_timeout)" >&2; fail "Darwin must keep the historical fleet page"; }
[ "$(probe_entries darwin_timeout)" = 0 ] || fail "Darwin has no independent signal, so cause=probe must not appear"
pass "Darwin/colima probe timeout is unchanged (cause=fleet)"

# ── 8. Inside the window: no new entry, and the verdict says it is a probe ──
# (The WARNING is emitted on transition only, so a poll inside the window must
# write nothing — but it must still be loud on stderr and never page.)
seed_state within_window PROBE $(( NOW - 600 ))
run within_window 81 DOCKER_INFO_RC=1 HEALTH_ALERT_DOCKERD_ALIVE=1
[ "$(errors within_window)" = 0 ] || { cat "$(log_of within_window)" >&2; fail "10m of an indeterminate probe must stay inside the 15m window"; }
[ "$(probe_entries within_window)" = 0 ] || fail "a poll inside the window must not re-log every interval"
grep -q 'PROBE INDETERMINATE 10m' "$W/err-within_window" || { cat "$W/err-within_window" >&2; fail "the verdict must report the elapsed indeterminate minutes"; }
grep -q 'not a fleet outage' "$W/err-within_window" || { cat "$W/err-within_window" >&2; fail "the verdict must say this is not a fleet outage"; }
pass "an indeterminate probe inside PROBE_PAGE_AFTER_MIN stays silent and non-paging"

# ── 9. Past the window: escalate to the existing cause=fleet page ──────────
seed_state sustained PROBE $(( NOW - 16 * 60 ))
run sustained 81 DOCKER_INFO_RC=1 HEALTH_ALERT_DOCKERD_ALIVE=1
[ "$(errors sustained)" = 1 ] || { cat "$(log_of sustained)" "$W/err-sustained" >&2; fail "a probe indeterminate past the window must page"; }
[ "$(fleet_entries sustained)" = 1 ] || fail "the escalation must use cause=fleet so the existing policy matches"
jq -e '.status == "DOWN" and .container_count == -1 and .container_count_known == false' "$(payload_of sustained)" > /dev/null \
  || { jq . "$(payload_of sustained)" >&2; fail "the escalation must stay honest about the unknown count"; }
grep -q 'stayed indeterminate for 16m' "$(log_of sustained)" || { cat "$(log_of sustained)" >&2; fail "the page must say how long the probe has been indeterminate"; }
grep -q 'FLEET DOWN on testhost (unknown containers' "$W/err-sustained" || { cat "$W/err-sustained" >&2; fail "the verdict line must not print -1 as a container count"; }
[ "$(probe_entries sustained)" = 0 ] || fail "an escalated probe must not also emit a cause=probe WARNING"
pass "sustained indeterminate probe escalates to cause=fleet CRITICAL"

# ── 10. The escalation obeys the fleet cooldown (no page every interval) ───
run sustained 81 DOCKER_INFO_RC=1 HEALTH_ALERT_DOCKERD_ALIVE=1
[ "$(errors sustained)" = 1 ] || { cat "$(log_of sustained)" >&2; fail "a repeat escalation inside COOLDOWN_SEC must be throttled"; }
pass "repeat escalations are throttled by the persisted fleet cooldown"

# ── 11. The window is env-overridable ─────────────────────────────────────
seed_state window_override PROBE $(( NOW - 3 * 60 ))
run window_override 81 DOCKER_INFO_RC=1 HEALTH_ALERT_DOCKERD_ALIVE=1 HEALTH_ALERT_PROBE_PAGE_AFTER_MIN=2
[ "$(errors window_override)" = 1 ] || { cat "$(log_of window_override)" >&2; fail "HEALTH_ALERT_PROBE_PAGE_AFTER_MIN must shorten the window"; }
pass "PROBE_PAGE_AFTER_MIN is env-overridable"

# ── 12. Healthy host: no entries at all (regression guard) ────────────────
run healthy 100 DOCKER_INFO_RC=0 DOCKER_PS_N=20
[ ! -f "$(log_of healthy)" ] || { cat "$(log_of healthy)" >&2; fail "a healthy host must not write any Cloud Logging entry"; }
[ "$(probe_entries healthy)" = 0 ] || fail "a healthy host must never emit cause=probe"
grep -q '"status":"OK"' "$(state_file healthy)" || fail "a healthy host must persist an OK state"
grep -q 'MUTUAL HEALTH CHECK OK' "$W/out-healthy" || fail "the healthy verdict line must be unchanged"
pass "healthy host is silent and reports the unchanged OK verdict"

# ── 13. Known-count payloads stay source-compatible with the policies ─────
# A zero-container fleet (real signal, not a probe timeout) still pages and
# still reports a known 0, so the fleet policy text stays accurate.
run zero_fleet 100 HEALTH_ALERT_CONTAINER_COUNT=0
[ "$(errors zero_fleet)" = 1 ] || fail "0 runner containers must still page"
jq -e '.container_count == 0 and .container_count_known == true' "$(payload_of zero_fleet)" > /dev/null \
  || { jq . "$(payload_of zero_fleet)" >&2; fail "an audited 0-container fleet reports a known 0"; }
pass "known container counts are unchanged (0 is still a real page)"

# ── 14. `docker info` answers but the count probe fails: count is unknown ───
# Same class of false page: an empty `docker ps` output must not be read as a
# live 0-container fleet.
run ps_timeout 100 DOCKER_INFO_RC=0 DOCKER_PS_RC=1
[ "$(errors ps_timeout)" = 0 ] || { cat "$(log_of ps_timeout)" >&2; fail "an unanswerable count probe must not page"; }
[ "$(fleet_entries ps_timeout)" = 0 ] || fail "an unanswerable count probe must not emit the 0-container fleet page"
jq -e '.cause == "probe" and .container_count == -1 and .container_count_known == false' "$(payload_of ps_timeout)" > /dev/null \
  || { jq . "$(payload_of ps_timeout)" >&2; fail "an unanswerable count probe must report cause=probe with an unknown count"; }
jq -e '[.failed_checks[] | select(test("container count timed out"))] | length == 1' "$(payload_of ps_timeout)" > /dev/null \
  || { jq . "$(payload_of ps_timeout)" >&2; fail "failed_checks must name the container-count probe"; }
pass "a failing container-count probe reports cause=probe, never a live 0"

echo "ALL PASS: a docker probe timeout with a live daemon no longer pages as fleet down"
