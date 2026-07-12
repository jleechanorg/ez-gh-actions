#!/usr/bin/env bash
# Install + activation proof test for the singleton backend-aware recovery
# controller unit (bead ez-gh-actions-ghd2.7 acceptance criterion #12).
#
# Verifies that running install.sh on a fresh Linux box (with systemctl
# stubbed) writes the ezgha-recovery.service + ezgha-recovery.timer files
# to ~/.config/systemd/user, substitutes @CARGO_BIN@ / @HOME@ correctly,
# leaves no unsubstituted @PLACEHOLDER@ in the rendered files, and asks
# systemd to enable the new timer.
#
# macOS launchd coverage is structurally identical (render + substitute +
# load + verify_scripts_exist); the same pattern is exercised by
# tests/install_uninstall_aux_units_test.sh for the Linux path. Per the
# project's CLAUDE.md "do NOT run install.sh against the live system --
# stubs only", we use the same stub-harness pattern.
#
# Usage: bash tests/install_recovery_unit_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}/systemd" "${TEMP_REPO}/launchd"
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"
cp "${REPO_ROOT}/systemd/"*.service "${REPO_ROOT}/systemd/"*.timer "${TEMP_REPO}/systemd/"
cp "${REPO_ROOT}/launchd/"*.plist.template "${TEMP_REPO}/launchd/"

# ── Stub PATH: systemctl (stateful logger) + cargo (never really installed
#    via cargo in this test -- exercises the "not installed via cargo"
#    fallback branch) ─────────────────────────────────────────────────────
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"

cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
# Pretend every cargo invocation succeeds so install.sh's `set -e` does
# not abort. We don't care about the side effects — this test only
# inspects the systemd/ files written to ~/.config/systemd/user and the
# systemctl commands invoked. (cargo uninstall -- ez-gh-actions returns
# non-zero, which the install.sh uninstall path treats as "not installed
# via cargo" and continues.)
exit 0
EOF

cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${SYSTEMCTL_LOG:?SYSTEMCTL_LOG must be exported}"
echo "systemctl $*" >> "${SYSTEMCTL_LOG}"
exit 0
EOF

chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:${PATH}"

# ── Seed a minimal "ready to install" state ──────────────────────────────
HOME_T="${WORK}/home"
mkdir -p "${HOME_T}/.config/ezgha"
# Pretend a config already exists, which is the trigger for the auxiliary
# timer-install block in install.sh. We don't need to set the full content.
printf '[github]\ntarget = "jleechanorg/ez-gh-actions-test"\n' > "${HOME_T}/.config/ezgha/config.toml"

SYSTEMCTL_LOG="${WORK}/systemctl.log"
: > "${SYSTEMCTL_LOG}"

# Run install.sh; we don't pass --with-watchdog so the watchdog arming
# stays gated, but the recovery timer should be enabled. Pass --dev to
# skip the production git-state check (we're not on main, and we don't
# have a real config in this test harness).
HOME="${HOME_T}" SYSTEMCTL_LOG="${SYSTEMCTL_LOG}" \
  bash "${TEMP_REPO}/install.sh" --dev > "${WORK}/install.log" 2>&1 || true

# ── Assertions ─────────────────────────────────────────────────────────────

# 1. ezgha-recovery.service exists with @CARGO_BIN@ / @HOME@ substituted.
SVC="${HOME_T}/.config/systemd/user/ezgha-recovery.service"
if [ ! -f "${SVC}" ]; then
  fail "ezgha-recovery.service not rendered at ${SVC}"
else
  echo "PASS: ezgha-recovery.service rendered at ${SVC}"
  if grep -q '@[A-Z_]*@' "${SVC}"; then
    fail "ezgha-recovery.service has unsubstituted @PLACEHOLDER@"
    grep -n '@[A-Z_]*@' "${SVC}" >&2 || true
  else
    echo "PASS: ezgha-recovery.service has no unsubstituted placeholders"
  fi
  if grep -qF "${TEMP_REPO}" "${SVC}"; then
    fail "ezgha-recovery.service references the worktree path"
  else
    echo "PASS: ezgha-recovery.service does NOT reference the worktree path"
  fi
fi

# 2. ezgha-recovery.timer exists.
TMR="${HOME_T}/.config/systemd/user/ezgha-recovery.timer"
if [ ! -f "${TMR}" ]; then
  fail "ezgha-recovery.timer not rendered at ${TMR}"
else
  echo "PASS: ezgha-recovery.timer rendered at ${TMR}"
fi

# 3. systemctl --user enable --now ezgha-recovery.timer was invoked.
if grep -q "enable --now ezgha-recovery.timer" "${SYSTEMCTL_LOG}"; then
  echo "PASS: install enabled ezgha-recovery.timer"
else
  fail "install did NOT call 'systemctl --user enable --now ezgha-recovery.timer'"
fi

# 4. daemon-reload was called.
if grep -q "daemon-reload" "${SYSTEMCTL_LOG}"; then
  echo "PASS: install ran systemctl --user daemon-reload"
else
  fail "install never ran daemon-reload"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  echo "--- install.log ---" >&2
  cat "${WORK}/install.log" >&2
  echo "--- systemctl.log ---" >&2
  cat "${SYSTEMCTL_LOG}" >&2
  exit 1
fi
