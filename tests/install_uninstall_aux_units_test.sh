#!/usr/bin/env bash
# regression test: install.sh --uninstall must disable and remove every
# auxiliary systemd unit before deleting ~/.local/libexec/ezgha, while
# preserving unrelated user drop-ins.
#
# This drives the real --uninstall path with every destructive executable
# resolved to an exact fixture stub before invocation. Do not run install.sh
# against a live system: this test is stubs only. The fixture clears inherited
# environment state and uses a fake user bus address.
#
# Platform selection is stubbed: uname reports Linux and launchctl is a
# tripwire, so the fixture cannot reach a live macOS service manager.
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

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF

cat > "${STUB_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
: "${FORBIDDEN_LAUNCHCTL_LOG:?FORBIDDEN_LAUNCHCTL_LOG must be exported}"
echo "launchctl $*" >> "${FORBIDDEN_LAUNCHCTL_LOG}"
exit 99
EOF

cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${SYSTEMCTL_LOG:?SYSTEMCTL_LOG must be exported}"
echo "systemctl $*" >> "${SYSTEMCTL_LOG}"
exit 0
EOF

cat > "${STUB_BIN}/limactl" <<'EOF'
#!/usr/bin/env bash
: "${LIMACTL_LOG:?LIMACTL_LOG must be exported}"
echo "limactl $*" >> "${LIMACTL_LOG}"
exit 1
EOF

cat > "${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
: "${FORBIDDEN_SUDO_LOG:?FORBIDDEN_SUDO_LOG must be exported}"
echo "sudo $*" >> "${FORBIDDEN_SUDO_LOG}"
exit 99
EOF

chmod +x "${STUB_BIN}"/*

preflight_stub_path() {
  local bin_dir="$1" tool actual
  for tool in systemctl cargo limactl uname launchctl sudo; do
    actual="$(PATH="${bin_dir}:/usr/bin:/bin" command -v "${tool}" || true)"
    [ "${actual}" = "${bin_dir}/${tool}" ] || {
      echo "FAIL: ${tool} resolved to ${actual:-<missing>}, expected ${bin_dir}/${tool}" >&2
      return 1
    }
  done
}

if ! preflight_stub_path "${STUB_BIN}"; then
  echo "FAIL: fixture executable preflight rejected the intended stub set" >&2
  exit 1
fi
BAD_STUB_BIN="${WORK}/misnamed-bin"
mkdir -p "${BAD_STUB_BIN}"
ln -s "${STUB_BIN}/systemctl" "${BAD_STUB_BIN}/systemctl-misnamed"
if preflight_stub_path "${BAD_STUB_BIN}"; then
  echo "FAIL: misnamed fixture stub was accepted before installer invocation" >&2
  exit 1
else
  echo "PASS: misnamed fixture stub rejected before installer invocation"
fi

# ── Seed a fully "installed" state ────────────────────────────────────────
HOME_T="${WORK}/home"
mkdir -p "${HOME_T}/.config/systemd/user" "${HOME_T}/.local/libexec/ezgha"

for unit in ezgha.service \
            lima-vm-cpu-ceiling.service \
            ezgha-token-refresh.service ezgha-token-refresh.timer \
            ezgha-queue-reaper.service ezgha-queue-reaper.timer \
            ezgha-queue-trimmer.service ezgha-queue-trimmer.timer \
            ezgha-watchdog.service ezgha-watchdog.timer \
            ezgha-runner-dashboard.service ezgha-runner-dashboard.timer \
            ezgha-colima-trim.service ezgha-colima-trim.timer \
            ezgha-mission-output-cleanup.service ezgha-mission-output-cleanup.timer; do
  printf '[Unit]\nDescription=stub\n' > "${HOME_T}/.config/systemd/user/${unit}"
done
printf '#!/usr/bin/env bash\ntrue\n' > "${HOME_T}/.local/libexec/ezgha/cleanup-stuck-runs.sh"
for guard_dir in \
    "${HOME_T}/.config/systemd/user/lima-vm@colima.service.d" \
    "${HOME_T}/.config/systemd/user/lima-vm-cpu-ceiling.service.d"; do
  mkdir -p "${guard_dir}"
  printf 'owned guard\n' > "${guard_dir}/10-guest-memory-admission.conf"
  printf 'unrelated drop-in\n' > "${guard_dir}/99-unrelated.conf"
done

SYSTEMCTL_LOG="${WORK}/systemctl.log"
: > "${SYSTEMCTL_LOG}"
FORBIDDEN_LAUNCHCTL_LOG="${WORK}/launchctl.log"
: > "${FORBIDDEN_LAUNCHCTL_LOG}"

RUNTIME_DIR="${WORK}/runtime"
mkdir -p "${RUNTIME_DIR}"
: > "${RUNTIME_DIR}/fake-bus"
LIMACTL_LOG="${WORK}/limactl.log"
FORBIDDEN_SUDO_LOG="${WORK}/sudo.log"
: > "${LIMACTL_LOG}" "${FORBIDDEN_SUDO_LOG}"
env -i \
  "HOME=${HOME_T}" \
  "CARGO_HOME=${HOME_T}/.cargo" \
  "XDG_CONFIG_HOME=${HOME_T}/.config" \
  "XDG_RUNTIME_DIR=${RUNTIME_DIR}" \
  "DBUS_SESSION_BUS_ADDRESS=unix:path=${RUNTIME_DIR}/fake-bus" \
  "PATH=${STUB_BIN}:/usr/bin:/bin" \
  "SYSTEMCTL_LOG=${SYSTEMCTL_LOG}" \
  "LIMACTL_LOG=${LIMACTL_LOG}" \
  "FORBIDDEN_LAUNCHCTL_LOG=${FORBIDDEN_LAUNCHCTL_LOG}" \
  "FORBIDDEN_SUDO_LOG=${FORBIDDEN_SUDO_LOG}" \
  /bin/bash "${TEMP_REPO}/install.sh" --uninstall > "${WORK}/uninstall.log" 2>&1

# ── Assertions ─────────────────────────────────────────────────────────────

for aux in token-refresh queue-reaper queue-trimmer watchdog runner-dashboard colima-trim mission-output-cleanup; do
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

if grep -q "disable --now lima-vm-cpu-ceiling.service" "${SYSTEMCTL_LOG}"; then
  echo "PASS: uninstall disabled lima-vm-cpu-ceiling.service"
else
  fail "uninstall did NOT disable lima-vm-cpu-ceiling.service"
fi

if [ -f "${HOME_T}/.config/systemd/user/lima-vm-cpu-ceiling.service" ]; then
  fail "lima-vm-cpu-ceiling.service survived uninstall"
else
  echo "PASS: lima-vm-cpu-ceiling.service removed"
fi

for guard_dir in \
    "${HOME_T}/.config/systemd/user/lima-vm@colima.service.d" \
    "${HOME_T}/.config/systemd/user/lima-vm-cpu-ceiling.service.d"; do
  if [ -e "${guard_dir}/10-guest-memory-admission.conf" ]; then
    fail "owned guest admission drop-in survived uninstall: ${guard_dir}"
  else
    echo "PASS: owned guest admission drop-in removed: ${guard_dir}"
  fi
  if [ ! -f "${guard_dir}/99-unrelated.conf" ]; then
    fail "unrelated drop-in was removed: ${guard_dir}"
  else
    echo "PASS: unrelated drop-in preserved: ${guard_dir}"
  fi
done

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

if [ -s "${FORBIDDEN_LAUNCHCTL_LOG}" ]; then
  fail "uninstall invoked forbidden live-platform launchctl path"
else
  echo "PASS: Linux platform stub prevented launchctl invocation"
fi

if [ -s "${FORBIDDEN_SUDO_LOG}" ]; then
  fail "uninstall invoked forbidden sudo path"
else
  echo "PASS: uninstall did not invoke forbidden sudo path"
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
