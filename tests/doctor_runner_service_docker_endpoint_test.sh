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
  inspect) printf 'true\n' ;;
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

# Exercise the actual function and probe payload from doctor-runner. The SSH
# shim runs each remote command with mocked systemctl/docker on its PATH.
FUNCTIONS="$(sed -n '/^REMOTE_DOCKER_HOST_CACHE=/,/^list_slot_work() {/p' "$ROOT/doctor-runner" | sed '$d')"
[ -n "$FUNCTIONS" ] || { echo 'FAIL: remote endpoint/probe functions not found'; exit 1; }

run_case() (
  local unit_env="$1" systemctl_fail="$2" host="$3"
  : > "$DOCKER_CALLS"
  PATH="$TMP/bin:$PATH"
  export UNIT_ENV="$unit_env" SYSTEMCTL_FAIL="$systemctl_fail"
  REMOTE_DOCKER_HOST_CACHE="" REMOTE_DOCKER_HOST_CACHED_FOR=""
  bad() { printf '  [BAD] %s\n' "$*"; }
  eval "$FUNCTIONS"
  probe_slot_state "$host" case-slot
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

# Keep the established macOS launchd endpoint behavior.
mac_result="$(run_case '' 0 mac-host 2>"$TMP/mac.err")"
[ "$mac_result" = EXECUTING ] || { echo "FAIL: macOS probe state was $mac_result"; exit 1; }
grep -Fq 'unix:///Users/test/.colima/default/docker.sock|inspect -f {{.State.Running}} case-slot' "$DOCKER_CALLS" || {
  echo 'FAIL: macOS launchd endpoint changed'; cat "$DOCKER_CALLS"; exit 1;
}
echo 'PASS: macOS launchd endpoint preserved'
