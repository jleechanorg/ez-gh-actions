#!/usr/bin/env bash
# regression test: install.sh --uninstall must tear down the auxiliary
# systemd timers/services (token-refresh, queue-reaper, watchdog, dashboard) BEFORE
# removing ~/.local/libexec/ezgha -- leaving them scheduled against a
# now-deleted script recreates the exact dead-path-scheduled-job incident
# class from 2026-07-09 (codex adversarial review 2026-07-10, finding 4).
# Previously uninstall() disabled only the main ezgha.service + main
# launchd plist, then `rm -rf`'d libexec, leaving the three aux
# timers/services still enabled and pointing at deleted scripts.
#
# This drives install.sh's REAL --uninstall code path end-to-end with
# `systemctl`/`cargo` stubbed out on PATH -- it never touches the live
# system. Per CLAUDE.md: "Do NOT run install.sh against the live system --
# stubs only."
#
# macOS launchd coverage: this test only exercises the Linux systemd path
# (this dev box's real platform, and the same stub-harness constraint that
# tests/install_watchdog_gate_test.sh already operates under -- faking
# `uname -s` = Darwin on a box with a REAL live systemd would require
# fully replacing PATH rather than prepending it, which risks accidentally
# shadowing a core utility and is not worth the risk for this fix). The
# macOS launchd removal code added alongside this fix (unload + rm -f each
# org.jleechanorg.ezgha-<name>.plist, plus the legacy
# -queue-reaper-stopgap plist) is structurally identical to the Linux
# branch verified below. Manual macOS verification steps:
#   1. On the Mac host: touch fake plists at
#      ~/Library/LaunchAgents/org.jleechanorg.ezgha-{token-refresh,queue-reaper,watchdog,queue-reaper-stopgap}.plist
#   2. Run ./install.sh --uninstall
#   3. Confirm: `launchctl list | grep ezgha` shows nothing, and none of the
#      four plist files above still exist on disk.
#
# Usage: bash tests/install_uninstall_aux_units_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
# shellcheck disable=SC2329  # Invoked indirectly by EXIT trap.
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}"
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"

# ── Stub PATH: systemctl (stateful logger) + cargo (never really installed
#    via cargo in this test -- exercises the "not installed via cargo"
#    fallback branch) ─────────────────────────────────────────────────────
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"

cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${SYSTEMCTL_LOG:?SYSTEMCTL_LOG must be exported}"
echo "systemctl $*" >> "${SYSTEMCTL_LOG}"
exit 0
EOF

chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:${PATH}"

# ── Seed a fully "installed" state ────────────────────────────────────────
HOME_T="${WORK}/home"
mkdir -p "${HOME_T}/.config/systemd/user" "${HOME_T}/.local/libexec/ezgha"

for unit in ezgha.service \
            ezgha-token-refresh.service ezgha-token-refresh.timer \
            ezgha-queue-reaper.service ezgha-queue-reaper.timer \
            ezgha-watchdog.service ezgha-watchdog.timer \
            ezgha-runner-dashboard.service ezgha-runner-dashboard.timer; do
  printf '[Unit]\nDescription=stub\n' > "${HOME_T}/.config/systemd/user/${unit}"
done
printf '#!/usr/bin/env bash\ntrue\n' > "${HOME_T}/.local/libexec/ezgha/cleanup-stuck-runs.sh"

SYSTEMCTL_LOG="${WORK}/systemctl.log"
: > "${SYSTEMCTL_LOG}"

HOME="${HOME_T}" SYSTEMCTL_LOG="${SYSTEMCTL_LOG}" \
  bash "${TEMP_REPO}/install.sh" --uninstall > "${WORK}/uninstall.log" 2>&1 || true

# ── Assertions ─────────────────────────────────────────────────────────────

for aux in token-refresh queue-reaper watchdog runner-dashboard; do
  if grep -q "disable --now ezgha-${aux}.timer" "${SYSTEMCTL_LOG}"; then
    echo "PASS: uninstall disabled ezgha-${aux}.timer"
  else
    fail "uninstall did NOT call 'systemctl --user disable --now ezgha-${aux}.timer'"
  fi
  for suffix in service timer; do
    f="${HOME_T}/.config/systemd/user/ezgha-${aux}.${suffix}"
    if [ -f "${f}" ]; then
      fail "aux unit file survived uninstall: ${f}"
    else
      echo "PASS: aux unit file removed: ezgha-${aux}.${suffix}"
    fi
  done
done

if grep -q "disable --now ezgha.service" "${SYSTEMCTL_LOG}"; then
  echo "PASS: uninstall disabled the main ezgha.service"
else
  fail "uninstall did NOT call 'systemctl --user disable --now ezgha.service'"
fi

if [ -f "${HOME_T}/.config/systemd/user/ezgha.service" ]; then
  fail "main ezgha.service unit file survived uninstall"
else
  echo "PASS: main ezgha.service unit file removed"
fi

if [ -d "${HOME_T}/.local/libexec/ezgha" ]; then
  fail "libexec script dir survived uninstall (should be rm -rf'd)"
else
  echo "PASS: libexec script dir removed"
fi

if grep -q "daemon-reload" "${SYSTEMCTL_LOG}"; then
  echo "PASS: uninstall ran systemctl --user daemon-reload after removing aux units"
else
  fail "uninstall never ran daemon-reload after removing aux unit files"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  echo "--- uninstall.log ---" >&2
  cat "${WORK}/uninstall.log" >&2
  echo "--- systemctl.log ---" >&2
  cat "${SYSTEMCTL_LOG}" >&2
  exit 1
fi
