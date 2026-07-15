#!/usr/bin/env bash
# Regression: every macOS fleet verifier must use the Docker endpoint persisted
# for the launchd service before it runs its first Docker probe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PLIST="$TMP/home/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
EXPECTED_HOST="unix://$TMP/home/.colima/default/docker.sock"
mkdir -p "$(dirname "$PLIST")" "$TMP/bin"
touch "$PLIST"

cat >"$TMP/bin/plutil" <<EOF
#!/usr/bin/env bash
if [ "\$*" != "-extract EnvironmentVariables.DOCKER_HOST raw -o - $PLIST" ]; then
  echo "unexpected plutil invocation: \$*" >&2
  exit 2
fi
printf '%s\n' '$EXPECTED_HOST'
EOF
chmod +x "$TMP/bin/plutil"

check_consumer() {
  local script="$1" first_probe_pattern="$2"
  local block_start block_end first_probe block

  block_start=$(grep -n '^# BEGIN launchd service Docker endpoint$' "$script" | cut -d: -f1 || true)
  block_end=$(grep -n '^# END launchd service Docker endpoint$' "$script" | cut -d: -f1 || true)
  first_probe=$(grep -nE "$first_probe_pattern" "$script" | head -1 | cut -d: -f1 || true)

  if [ -z "$block_start" ] || [ -z "$block_end" ]; then
    echo "FAIL: $script does not import the launchd Docker endpoint" >&2
    return 1
  fi
  if [ -z "$first_probe" ] || [ "$block_end" -ge "$first_probe" ]; then
    echo "FAIL: $script imports the launchd Docker endpoint after its first Docker probe" >&2
    return 1
  fi

  block=$(sed -n "${block_start},${block_end}p" "$script")
  unset DOCKER_HOST
  export PLATFORM=macos HOME="$TMP/home" PATH="$TMP/bin:$PATH"
  eval "$block"
  if [ "${DOCKER_HOST:-}" != "$EXPECTED_HOST" ]; then
    echo "FAIL: $script exported DOCKER_HOST='${DOCKER_HOST:-<unset>}'" >&2
    return 1
  fi
  echo "PASS: $script uses $DOCKER_HOST before its first Docker probe"
}

check_consumer "$ROOT/doctor.sh" '^if DOCKER_INFO=.*docker info'
check_consumer "$ROOT/docs/verify-exit-criteria.sh" '^docker info --format'
