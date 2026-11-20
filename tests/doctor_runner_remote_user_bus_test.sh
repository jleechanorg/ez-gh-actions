#!/usr/bin/env bash
# Regression: a NON-INTERACTIVE ssh `systemctl --user` probe must establish the
# systemd user bus before asking for the daemon endpoint.
#
# Bead: jleechan-6ej6
#
# The defect this pins (measured 2026-11-18, not inferred):
#
#   ssh jeff-ubuntu 'systemctl --user show ezgha.service -p LoadState --value'
#     -> Failed to connect to bus: No medium found        (rc=1)
#
#   same command with XDG_RUNTIME_DIR=/run/user/$(id -u) and
#   DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
#     -> loaded                                           (rc=0)
#
# A non-interactive ssh command inherits no login session, so neither variable
# is set. `remote_docker_env()` treated the rc=1 as "endpoint unresolved" and
# every Linux slot was then counted DOWN WITHOUT a Docker probe — 20/20 falsely
# DOWN while 15 containers were actively executing Runner.Worker. That is the
# most expensive false signal available: it invites remediation against a
# healthy host.
#
# The shim below reproduces that transport condition faithfully: `systemctl`
# refuses exactly as systemd's user manager does when the bus is absent, and
# succeeds once both variables are exported. Any future change that drops the
# export therefore turns this test RED rather than silently reintroducing a
# false fleet-outage verdict.
#
# Usage: bash tests/doctor_runner_remote_user_bus_test.sh
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="${DOCTOR_RUNNER_UNDER_TEST:-$ROOT/doctor-runner}"
[ -x "$D" ] || { echo "FAIL: doctor-runner not executable at $D" >&2; exit 1; }
bash -n "$D" || { echo 'FAIL: doctor-runner has a syntax error' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/bin"

# systemctl shim: fail like the real user manager when the bus is absent.
cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
# A non-interactive ssh command has no user bus. Reproduce that refusal.
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  echo 'Failed to connect to bus: No medium found' >&2
  exit 1
fi
# The bus exists, but prove it points at THIS user's runtime dir rather than a
# hardcoded guess (bead asks for the verified uid).
[ "${XDG_RUNTIME_DIR}" = "/run/user/$(id -u)" ] || {
  echo "wrong XDG_RUNTIME_DIR: '${XDG_RUNTIME_DIR}'" >&2
  exit 1
}
[ "${DBUS_SESSION_BUS_ADDRESS}" = "unix:path=/run/user/$(id -u)/bus" ] || {
  echo "wrong DBUS_SESSION_BUS_ADDRESS: '${DBUS_SESSION_BUS_ADDRESS}'" >&2
  exit 1
}
case "$*" in
  '--user show ezgha.service -p LoadState --value') printf '%s\n' 'loaded' ;;
  '--user show ezgha.service -p Environment --value')
    printf '%s\n' 'DOCKER_HOST_OVERRIDE=unix:///run/ezgha/docker.sock' ;;
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

# ssh shim: run the remote command with mocked systemctl/docker on PATH, and
# with NO user-bus variables, exactly like a non-interactive ssh invocation.
# HOME is redirected to an empty dir: on a macOS dev box the real
# ~/Library/LaunchAgents/org.jleechanorg.ezgha.plist exists, which would select
# the launchd branch and dodge the systemd path this test is about.
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
cmd="${*: -1}"
env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS HOME="$REMOTE_TEST_HOME" \
  PATH="$TMP_BIN:$PATH" bash -c "$cmd"
SH
chmod +x "$TMP/bin/"*
export TMP_BIN="$TMP/bin" DOCKER_CALLS="$TMP/docker-calls"
export REMOTE_TEST_HOME="$TMP/remote-home"
mkdir -p "$REMOTE_TEST_HOME"

FUNCTIONS="$(sed -n '/^REMOTE_DOCKER_HOST_CACHE=/,/^# Local fleet —/p' "$D" | sed '$d')"
[ -n "$FUNCTIONS" ] || { echo 'FAIL: remote endpoint functions not found' >&2; exit 1; }

: > "$DOCKER_CALLS"
state=$(
  PATH="$TMP/bin:$PATH"
  export PATH
  REMOTE_DOCKER_HOST_CACHE="" REMOTE_DOCKER_HOST_CACHED_FOR=""
  bad() { printf '  [BAD] %s\n' "$*" >&2; }
  eval "$FUNCTIONS"
  probe_slot_state linux-host case-slot || [ "$?" -eq 2 ]
)

# 1. The slot must be probed and found EXECUTING, not counted DOWN unprobed.
if [ "$state" != EXECUTING ]; then
  echo "FAIL: healthy remote slot reported $state instead of EXECUTING" >&2
  echo '      (a non-interactive ssh probe lost the systemd user bus -> false DOWN)' >&2
  exit 1
fi
echo 'PASS: non-interactive ssh probe resolves the unit and reports EXECUTING'

# 2. The endpoint must come from the unit's own DOCKER_HOST_OVERRIDE, which can
#    only be read if systemctl succeeded — proof the bus was actually used.
grep -Fq 'unix:///run/ezgha/docker.sock|inspect -f {{.State.Running}} case-slot' "$DOCKER_CALLS" || {
  echo 'FAIL: docker probe did not use the endpoint read over the user bus' >&2
  cat "$DOCKER_CALLS" >&2
  exit 1
}
echo 'PASS: endpoint read over the user bus drives the docker probe'

# 3. A Docker probe must actually have happened — DOWN-by-skipping is the defect.
[ -s "$DOCKER_CALLS" ] || { echo 'FAIL: no docker probe issued at all (false DOWN)' >&2; exit 1; }
echo 'PASS: the slot was probed, not assumed dead'

# 4. Fail-closed is preserved: with a genuinely missing unit the probe must still
#    end DOWN and issue no Docker call. The bus export must not paper over it.
cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  echo 'Failed to connect to bus: No medium found' >&2
  exit 1
fi
case "$*" in
  '--user show ezgha.service -p LoadState --value') printf '%s\n' 'not-found' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"
: > "$DOCKER_CALLS"
missing_state=$(
  PATH="$TMP/bin:$PATH"
  export PATH
  REMOTE_DOCKER_HOST_CACHE="" REMOTE_DOCKER_HOST_CACHED_FOR=""
  bad() { :; }
  eval "$FUNCTIONS"
  probe_slot_state linux-host case-slot || [ "$?" -eq 2 ]
)
[ "$missing_state" = DOWN ] || {
  echo "FAIL: a genuinely missing unit must stay DOWN, got $missing_state" >&2
  exit 1
}
[ ! -s "$DOCKER_CALLS" ] || {
  echo 'FAIL: Docker was probed for an absent unit (bus export became fail-open)' >&2
  cat "$DOCKER_CALLS" >&2
  exit 1
}
echo 'PASS: fail-closed preserved — a really-absent unit stays DOWN with no docker probe'

echo 'ALL PASS: non-interactive ssh establishes the systemd user bus without weakening fail-closed'
