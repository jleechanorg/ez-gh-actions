#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOME_T="$WORK/home"
BIN="$WORK/bin"
mkdir -p "$HOME_T/Library/LaunchAgents" "$BIN"

sed -n '1,$p' > "$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
if [[ -n "${LAUNCHCTL_LOG:-}" ]]; then printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"; fi
if [[ "${LAUNCHCTL_FAIL_DASHBOARD_LOAD:-0}" == "1" &&
      "${1:-}" == "load" && "${2:-}" == *runner-dashboard.plist ]]; then
  exit 42
fi
if [[ "${LAUNCHCTL_FAIL_DASHBOARD_LOAD:-0}" == "once" &&
      "${1:-}" == "load" && "${2:-}" == *runner-dashboard.plist &&
      ! -e "${LAUNCHCTL_FAIL_ONCE_STATE:?}" ]]; then
  : > "$LAUNCHCTL_FAIL_ONCE_STATE"
  exit 42
fi
exit 0
SH
chmod +x "$BIN/launchctl"

HOME="$HOME_T" PATH="$BIN:$PATH" bash "$ROOT/launchd/install-launchagents.sh" install

for asset in index.html style.css dashboard.js; do
  test -f "$HOME_T/.local/libexec/ezgha/dashboard/$asset"
done
for script in publish_runner_dashboard.sh runner_dashboard_host_probe.sh build_runner_dashboard_snapshot.py; do
  test -x "$HOME_T/.local/libexec/ezgha/$script"
done

PLIST="$HOME_T/Library/LaunchAgents/org.jleechanorg.ezgha-runner-dashboard.plist"
test -f "$PLIST"
PLIST="$PLIST" HOME_T="$HOME_T" python3 - <<'PY'
import os
import plistlib
from pathlib import Path

payload = plistlib.loads(Path(os.environ["PLIST"]).read_bytes())
home = os.environ["HOME_T"]
assert payload["ProgramArguments"] == [
    "/bin/bash",
    f"{home}/.local/libexec/ezgha/publish_runner_dashboard.sh",
    "--publish",
]
assert payload["StartInterval"] == 600
assert payload["EnvironmentVariables"]["HOME"] == home
serialized = str(payload)
assert "worktree" not in serialized.lower()
assert "@HOME@" not in serialized
assert "@SCRIPTS_DIR@" not in serialized
for forbidden in ("TOKEN", "PASSWORD", "SECRET", "API_KEY"):
    assert forbidden not in serialized
PY

HOME="$HOME_T" PATH="$BIN:$PATH" bash "$ROOT/launchd/install-launchagents.sh" remove
test ! -e "$HOME_T/.local/libexec/ezgha"
test ! -e "$PLIST"

INSTALL_WIRING="$(
  sed -n '/launchd\/install-launchagents.sh" install/,+1p' "$ROOT/install.sh"
)"
[[ "$INSTALL_WIRING" == *'"org.jleechanorg.ezgha-runner-dashboard"'* ]]
if grep -q 'dashboard_template=' "$ROOT/install.sh"; then exit 1; fi
if grep -q 'SCRIPT_DIR}/dashboard/' "$ROOT/install.sh"; then exit 1; fi

FAIL_HOME="$WORK/fail-home"
mkdir -p "$FAIL_HOME/Library/LaunchAgents"
set +e
FAIL_OUTPUT="$(
  HOME="$FAIL_HOME" PATH="$BIN:$PATH" LAUNCHCTL_FAIL_DASHBOARD_LOAD=1 \
    bash "$ROOT/launchd/install-launchagents.sh" install \
      org.jleechanorg.ezgha-runner-dashboard 2>&1
)"
FAIL_STATUS=$?
set -e
test "$FAIL_STATUS" -eq 42
[[ "$FAIL_OUTPUT" != *"loaded: org.jleechanorg.ezgha-runner-dashboard"* ]]
test ! -e \
  "$FAIL_HOME/Library/LaunchAgents/org.jleechanorg.ezgha-runner-dashboard.plist"
test ! -e \
  "$FAIL_HOME/Library/LaunchAgents/org.jleechanorg.ezgha-token-refresh.plist"

UPGRADE_HOME="$WORK/upgrade-home"
UPGRADE_PLIST="$UPGRADE_HOME/Library/LaunchAgents/org.jleechanorg.ezgha-runner-dashboard.plist"
UPGRADE_LOG="$WORK/upgrade-launchctl.log"
mkdir -p "$(dirname "$UPGRADE_PLIST")"
printf '%s\n' 'prior-known-good-plist' > "$UPGRADE_PLIST"
set +e
HOME="$UPGRADE_HOME" PATH="$BIN:$PATH" \
  LAUNCHCTL_LOG="$UPGRADE_LOG" LAUNCHCTL_FAIL_DASHBOARD_LOAD=once \
  LAUNCHCTL_FAIL_ONCE_STATE="$WORK/upgrade-failed-once" \
  bash "$ROOT/launchd/install-launchagents.sh" install \
    org.jleechanorg.ezgha-runner-dashboard >/dev/null 2>&1
UPGRADE_STATUS=$?
set -e
test "$UPGRADE_STATUS" -eq 42
test "$(cat "$UPGRADE_PLIST")" = 'prior-known-good-plist'
test "$(grep -c '^load .*runner-dashboard.plist$' "$UPGRADE_LOG")" -eq 2
if compgen -G "$UPGRADE_PLIST.*" >/dev/null; then exit 1; fi

echo "runner dashboard launchd install tests passed"
