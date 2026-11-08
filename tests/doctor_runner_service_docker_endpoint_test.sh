#!/usr/bin/env bash
# Regression: remote probes must use the endpoint selected by ezgha.service,
# matching src/platform.rs; a failed endpoint lookup must never probe Docker.
# Bead: jleechan-wo2c.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/remote-home"

cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '--user show ezgha.service -p LoadState --value')
    [ "${SYSTEMCTL_FAIL:-0}" = 1 ] && exit 1
    printf '%s\n' "${UNIT_LOAD_STATE:-loaded}"
    ;;
  '--user show ezgha.service -p Environment --value')
    [ "${SYSTEMCTL_FAIL:-0}" = 1 ] && exit 1
    printf '%s\n' "${UNIT_ENV:-}"
    ;;
  *) exit 1 ;;
esac
SH

cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${DOCKER_HOST-<unset>}" "$*" >> "$DOCKER_CALLS"
case "$1" in
  inspect) printf '%s\n' "${DOCKER_INSPECT_RUNNING:-true}" ;;
  top) printf 'PID COMMAND\n1 Runner.Worker\n' ;;
  *) exit 2 ;;
esac
SH

cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
host="${*: -2:1}"
cmd="${*: -1}"
case "$host" in
  linux-host)
    HOME="$REMOTE_TEST_HOME" PATH="$TMP_BIN:$PATH" bash -c "$cmd"
    ;;
  mac-host)
    case "$cmd" in
      *"plutil -extract EnvironmentVariables.DOCKER_HOST"*) printf '%s\n' 'unix:///Users/test/.colima/default/docker.sock' ;;
      *) PATH="$TMP_BIN:$PATH" bash -c "$cmd" ;;
    esac
    ;;
  *) exit 255 ;;
esac
SH
chmod +x "$TMP/bin/"*
export TMP_BIN="$TMP/bin" REMOTE_TEST_HOME="$TMP/remote-home" DOCKER_CALLS="$TMP/docker-calls"

# Exercise the actual function and caller from doctor-runner. The SSH shim
# runs each remote command with mocked systemctl/docker on its PATH.
FUNCTIONS="$(sed -n '/^REMOTE_DOCKER_HOST_CACHE=/,/^# Local fleet —/p' "$ROOT/doctor-runner" | sed '$d')"
[ -n "$FUNCTIONS" ] || { echo 'FAIL: remote endpoint/probe functions not found'; exit 1; }

run_case() (
  local unit_env="$1" systemctl_fail="$2" host="$3" unit_load_state="${4:-loaded}"
  : > "$DOCKER_CALLS"
  PATH="$TMP/bin:$PATH"
  export UNIT_ENV="$unit_env" SYSTEMCTL_FAIL="$systemctl_fail" UNIT_LOAD_STATE="$unit_load_state"
  REMOTE_DOCKER_HOST_CACHE="" REMOTE_DOCKER_HOST_CACHED_FOR=""
  bad() { printf '  [BAD] %s\n' "$*"; }
  eval "$FUNCTIONS"
  probe_slot_state "$host" case-slot || [ "$?" -eq 2 ]
)

assert_endpoint() {
  local name="$1" unit_env="$2" expected="$3"
  local state
  state="$(run_case "$unit_env" 0 linux-host 2>"$TMP/$name.err")"
  [ "$state" = EXECUTING ] || { echo "FAIL: $name state was $state"; return 1; }
  grep -Fq "$expected|inspect -f {{.State.Running}} case-slot" "$DOCKER_CALLS" || {
    echo "FAIL: $name inspect did not use endpoint $expected"; cat "$DOCKER_CALLS"; return 1;
  }
  grep -Fq "$expected|top case-slot -eo pid,comm" "$DOCKER_CALLS" || {
    echo "FAIL: $name top did not use endpoint $expected"; cat "$DOCKER_CALLS"; return 1;
  }
  echo "PASS: $name selected $expected for executed docker probes"
}

assert_endpoint conflicting-host 'DOCKER_HOST=tcp://stale-colima:2375 DOCKER_HOST_OVERRIDE=unix:///run/ezgha/docker.sock DOCKER_CONTEXT=stale' 'unix:///run/ezgha/docker.sock'
assert_endpoint quoted-override "DOCKER_HOST_OVERRIDE=\"unix:///run/socket path/daemon.sock;\$(touch $TMP/injected)\" DOCKER_CONTEXT=stale" "unix:///run/socket path/daemon.sock;\$(touch $TMP/injected)"
assert_endpoint apostrophe-override "DOCKER_HOST_OVERRIDE=\"unix:///run/owner's socket.sock\"" "unix:///run/owner's socket.sock"
assert_endpoint quoted-assignment '"DOCKER_HOST_OVERRIDE=unix:///run/whole assignment/daemon.sock" DOCKER_CONTEXT=stale' 'unix:///run/whole assignment/daemon.sock'
[ ! -e "$TMP/injected" ] || { echo 'FAIL: endpoint command substitution executed'; exit 1; }
assert_endpoint stale-host-only 'DOCKER_HOST=tcp://stale-colima:2375 DOCKER_CONTEXT=stale' 'unix:///var/run/docker.sock'
assert_endpoint empty-unit-env '' 'unix:///var/run/docker.sock'

# A failed systemctl lookup is unresolved, counted DOWN, and must not result in
# any remote docker probe. Verify the diagnostic is explicit as well.
set +e
failed_state="$(run_case '' 1 linux-host 2>"$TMP/systemctl-failed.err")"
failed_rc=$?
set -e
[ "$failed_rc" -eq 0 ] || { echo "FAIL: failed endpoint lookup aborted probe (rc=$failed_rc)"; exit 1; }
[ "$failed_state" = DOWN ] || { echo "FAIL: failed endpoint lookup should count as DOWN, got $failed_state"; exit 1; }
[ ! -s "$DOCKER_CALLS" ] || { echo 'FAIL: Docker was probed after endpoint lookup failed'; cat "$DOCKER_CALLS"; exit 1; }
grep -qi 'endpoint.*unresolved\|unresolved.*endpoint' "$TMP/systemctl-failed.err" || {
  echo 'FAIL: missing explicit unresolved-endpoint diagnostic'; cat "$TMP/systemctl-failed.err"; exit 1;
}
echo 'PASS: failed systemctl lookup is unresolved/DOWN and issues no docker probe'

# systemctl show may succeed for a missing unit and return an empty
# Environment. That must not be mistaken for the loaded unit's native socket.
set +e
missing_unit_state="$(run_case '' 0 linux-host not-found 2>"$TMP/systemd-unit-missing.err")"
missing_unit_rc=$?
set -e
[ "$missing_unit_rc" -eq 0 ] || { echo "FAIL: missing unit lookup aborted probe (rc=$missing_unit_rc)"; exit 1; }
[ "$missing_unit_state" = DOWN ] || { echo "FAIL: missing systemd unit should count as DOWN, got $missing_unit_state"; exit 1; }
[ ! -s "$DOCKER_CALLS" ] || { echo 'FAIL: Docker was probed when systemd unit was not loaded'; cat "$DOCKER_CALLS"; exit 1; }
grep -qi 'endpoint.*unresolved\|unresolved.*endpoint' "$TMP/systemd-unit-missing.err" || {
  echo 'FAIL: missing unit lacked explicit unresolved-endpoint diagnostic'; cat "$TMP/systemd-unit-missing.err"; exit 1;
}
echo 'PASS: systemd LoadState=not-found is unresolved/DOWN and issues no docker probe'

: > "$DOCKER_CALLS"
malformed_state="$(run_case 'DOCKER_HOST_OVERRIDE="unterminated' 0 linux-host 2>"$TMP/malformed.err")"
[ "$malformed_state" = DOWN ] || { echo "FAIL: malformed unit Environment should be unresolved, got $malformed_state"; exit 1; }
[ ! -s "$DOCKER_CALLS" ] || { echo 'FAIL: malformed unit Environment issued Docker probe'; cat "$DOCKER_CALLS"; exit 1; }
grep -qi 'endpoint.*unresolved\|unresolved.*endpoint' "$TMP/malformed.err" || { echo 'FAIL: malformed unit Environment lacked unresolved diagnostic'; exit 1; }
echo 'PASS: malformed quoted Environment fails closed without Docker probe'

# Full caller regression: unresolved endpoint must stay DOWN even when a
# recent journal line would ordinarily mean a resolved, containerless slot is
# cycling. Exercise both systemctl failure and successful LoadState=not-found.
for caller_case in failed not-found; do
  : > "$DOCKER_CALLS"
  caller_out=$( (
    PATH="$TMP/bin:$PATH"; export PATH
    eval "$FUNCTIONS"
    eval "$(sed -n '/^journal_has_respawn_evidence() {/ ,/^}/p' "$ROOT/doctor-runner")"
    bad() { :; }; info() { :; }; sleep() { :; }
    fetch_respawn_log_window() { printf '%s\n' 'respawned ephemeral runner case-1'; }
    RESPAWN_EVIDENCE_WINDOW_MIN=5 SECTION10_DOWN_RESAMPLE_SECONDS=0
    RUNNER_JOB_INDEX_FILE=/dev/null STARVED_PRESENT=0 STARVE_QUEUED_COUNT=0
    if [ "$caller_case" = failed ]; then SYSTEMCTL_FAIL=1 UNIT_LOAD_STATE=loaded; else SYSTEMCTL_FAIL=0 UNIT_LOAD_STATE=not-found; fi
    export SYSTEMCTL_FAIL UNIT_LOAD_STATE
    list_slot_work case 1 linux-host linux > "$TMP/caller.out"
    declare -p LAST_DOWN_SLOTS
    cat "$TMP/caller.out"
  ) 2>"$TMP/caller-$caller_case.err")
  grep -Fq 'LAST_DOWN_SLOTS=([0]="case-1")' <<<"$caller_out" || { echo "FAIL: caller $caller_case did not preserve DOWN"; echo "$caller_out"; exit 1; }
  [ ! -s "$DOCKER_CALLS" ] || { echo "FAIL: caller $caller_case issued Docker probe"; cat "$DOCKER_CALLS"; exit 1; }
  echo "PASS: full caller preserves $caller_case unresolved slot as DOWN despite journal evidence"
done

# A loaded unit with a known endpoint and no container can still be cycling
# when the daemon has recent evidence for this exact slot.
: > "$DOCKER_CALLS"
resolved_out=$( (
  PATH="$TMP/bin:$PATH"; export PATH
  eval "$FUNCTIONS"
  eval "$(sed -n '/^journal_has_respawn_evidence() {/ ,/^}/p' "$ROOT/doctor-runner")"
  bad() { :; }; info() { :; }; sleep() { :; }
  fetch_respawn_log_window() { printf '%s\n' 'respawned ephemeral runner case-1'; }
  RESPAWN_EVIDENCE_WINDOW_MIN=5 SECTION10_DOWN_RESAMPLE_SECONDS=0
  RUNNER_JOB_INDEX_FILE=/dev/null STARVED_PRESENT=0 STARVE_QUEUED_COUNT=0
  export SYSTEMCTL_FAIL=0 UNIT_LOAD_STATE=loaded UNIT_ENV='' DOCKER_INSPECT_RUNNING=false
  list_slot_work case 1 linux-host linux
  declare -p LAST_CYCLING_SLOTS
))
grep -Fq 'LAST_CYCLING_SLOTS=([0]="case-1")' <<<"$resolved_out" || { echo 'FAIL: resolved containerless slot lost CYCLING evidence'; echo "$resolved_out"; exit 1; }
[ -s "$DOCKER_CALLS" ] || { echo 'FAIL: resolved containerless slot was not probed'; exit 1; }
echo 'PASS: resolved containerless slot remains CYCLING with recent journal evidence'

# Keep the established macOS launchd endpoint behavior.
mac_result="$(run_case '' 0 mac-host 2>"$TMP/mac.err")"
[ "$mac_result" = EXECUTING ] || { echo "FAIL: macOS probe state was $mac_result"; exit 1; }
grep -Fq 'unix:///Users/test/.colima/default/docker.sock|inspect -f {{.State.Running}} case-slot' "$DOCKER_CALLS" || {
  echo 'FAIL: macOS launchd endpoint changed'; cat "$DOCKER_CALLS"; exit 1;
}
echo 'PASS: macOS launchd endpoint preserved'
