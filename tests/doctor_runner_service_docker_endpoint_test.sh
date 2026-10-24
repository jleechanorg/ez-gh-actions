#!/usr/bin/env bash
# Regression: remote Linux Docker probes must follow ezgha.service's endpoint,
# even when the systemd user manager environment is empty and the login shell
# has an unrelated interactive Docker context.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/remote-home"

cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
cmd="${*: -1}"
host="${*: -2:1}"
case "$host:$cmd" in
  linux-host:*)
    # Execute the actual remote command, including unit-environment parsing.
    HOME="$REMOTE_TEST_HOME" bash -c "$cmd"
    ;;
  mac-host:*"plutil -extract EnvironmentVariables.DOCKER_HOST"*)
    printf '%s\n' 'unix:///Users/test/.colima/default/docker.sock'
    ;;
  *) exit 255 ;;
esac
SH
chmod +x "$TMP/bin/ssh"

cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '--user show-environment') exit 0 ;;
  '--user show ezgha.service -p Environment --value')
    printf '%s\n' 'RUST_LOG=info DOCKER_HOST=unix:///var/run/docker.sock OTHER=value'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"
export REMOTE_TEST_HOME="$TMP/remote-home"

FUNCTIONS="$(sed -n '/^REMOTE_DOCKER_HOST_CACHE=/,/^probe_slot_state() {/p' "$ROOT/doctor-runner" | sed '$d')"
[ -n "$FUNCTIONS" ] || { echo 'FAIL: remote_docker_env function not found'; exit 1; }

run_function() (
  PATH="$TMP/bin:$PATH"
  REMOTE_DOCKER_HOST_CACHE=""
  REMOTE_DOCKER_HOST_CACHED_FOR=""
  eval "$FUNCTIONS"
  remote_docker_env "$1"
)

# Manager environment is deliberately empty while the unit has a native socket.
# The simulated login-shell context is Colima; unit selection must win.
linux_result="$(run_function linux-host)"
if [ "$linux_result" != "DOCKER_HOST='unix:///var/run/docker.sock' " ]; then
  echo "FAIL: Linux endpoint should come from ezgha.service, got: $linux_result" >&2
  exit 1
fi

# Preserve the established launchd plist path on macOS.
mac_result="$(run_function mac-host)"
if [ "$mac_result" != "DOCKER_HOST='unix:///Users/test/.colima/default/docker.sock' " ]; then
  echo "FAIL: macOS launchd endpoint changed: $mac_result" >&2
  exit 1
fi

echo 'PASS: remote Linux uses service endpoint; macOS keeps launchd endpoint'
