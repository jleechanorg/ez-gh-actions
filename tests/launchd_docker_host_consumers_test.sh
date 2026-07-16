#!/usr/bin/env bash
# Regression: authoritative macOS fleet verifiers must use the Docker endpoint
# persisted for launchd before their first Docker probe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/launchd-service-docker-endpoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PLIST="$TMP/home/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
EXPECTED_HOST="unix://$TMP/home/.colima/default/docker.sock"
AMBIENT_HOST="unix:///ambient/docker.sock"
mkdir -p "$(dirname "$PLIST")" "$TMP/bin"

cat >"$TMP/bin/plutil" <<EOF
#!/usr/bin/env bash
if [ "\$*" != "-extract EnvironmentVariables.DOCKER_HOST raw -o - $PLIST" ]; then
  echo "unexpected plutil invocation: \$*" >&2
  exit 2
fi
if [ ! -f "$PLIST" ]; then
  echo "Could not modify plist, error: file does not exist"
  exit 1
fi
if [ "\${PLUTIL_MODE:-success}" = "missing-key" ]; then
  echo "Could not extract value, error: No value at that key path"
  exit 1
fi
printf '%s\n' '$EXPECTED_HOST'
EOF
chmod +x "$TMP/bin/plutil"

# shellcheck disable=SC1090,SC1091 # HELPER is resolved from the current worktree.
source "$HELPER"

reset_ambient() {
  export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
  export DOCKER_HOST="$AMBIENT_HOST" DOCKER_CONTEXT="interactive-context"
  unset PLUTIL_MODE
}

assert_ambient_preserved() {
  local label="$1"
  if [ "$DOCKER_HOST" != "$AMBIENT_HOST" ]; then
    echo "FAIL: $label replaced ambient DOCKER_HOST with '$DOCKER_HOST'" >&2
    return 1
  fi
  if [ "$DOCKER_CONTEXT" != "interactive-context" ]; then
    echo "FAIL: $label changed ambient DOCKER_CONTEXT" >&2
    return 1
  fi
  echo "PASS: $label preserves ambient Docker selection"
}

touch "$PLIST"
reset_ambient
use_launchd_service_docker_endpoint macos
if [ "$DOCKER_HOST" != "$EXPECTED_HOST" ]; then
  echo "FAIL: successful import exported DOCKER_HOST='$DOCKER_HOST'" >&2
  exit 1
fi
if [ "${DOCKER_CONTEXT+x}" = x ]; then
  echo "FAIL: successful import left DOCKER_CONTEXT set" >&2
  exit 1
fi
echo "PASS: successful import selects $DOCKER_HOST and clears DOCKER_CONTEXT"

rm -f "$PLIST"
reset_ambient
use_launchd_service_docker_endpoint macos
assert_ambient_preserved "missing plist"

touch "$PLIST"
reset_ambient
export PLUTIL_MODE=missing-key
use_launchd_service_docker_endpoint macos
assert_ambient_preserved "missing key"

check_consumer() {
  local script="$1" first_probe_pattern="$2"
  local source_line call_line first_probe

  source_line=$(grep -n 'launchd-service-docker-endpoint[.]sh' "$script" | head -1 | cut -d: -f1 || true)
  # shellcheck disable=SC2016 # Literal source pattern, not shell expansion.
  call_line=$(grep -n '^use_launchd_service_docker_endpoint "\$PLATFORM"$' "$script" | head -1 | cut -d: -f1 || true)
  first_probe=$(grep -nE "$first_probe_pattern" "$script" | head -1 | cut -d: -f1 || true)

  if [ -z "$source_line" ] || [ -z "$call_line" ]; then
    echo "FAIL: $script does not load and call the launchd endpoint helper" >&2
    return 1
  fi
  if [ -z "$first_probe" ] || [ "$source_line" -ge "$call_line" ] || [ "$call_line" -ge "$first_probe" ]; then
    echo "FAIL: $script does not select the launchd endpoint before its first Docker probe" >&2
    return 1
  fi
  echo "PASS: $script selects the launchd endpoint before its first Docker probe"
}

check_consumer "$ROOT/doctor-runner" '^if DOCKER_INFO=.*docker info'
check_consumer "$ROOT/docs/verify-exit-criteria.sh" '^docker info --format'
