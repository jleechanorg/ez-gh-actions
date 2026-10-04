#!/usr/bin/env bash
# regression test: install.sh enforces watchdog removal and cleanup.
# A `./install.sh` run must:
#   (a) NOT install ezgha-watchdog.timer or ezgha-watchdog.service or watchdog-load-repair.sh,
#   (b) disable and remove any previously installed/drifted watchdog timer/service.
#
# This drives install.sh's REAL Linux code path end-to-end
# with `systemctl`/`docker`/`gh`/`cargo`/`git` stubbed out on PATH -- it
# never touches the live system, never builds the real binary, and (by
# copying install.sh into a docs/-less temp tree) never reaches the live
# ./docs/verify-exit-criteria.sh post-deploy gate. Per CLAUDE.md: "Do NOT
# run install.sh against the live system -- stubs only."
#
# Usage: bash tests/install_watchdog_gate_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${INSTALL_SCRIPT:-${REPO_ROOT}/install.sh}"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

# ── 1. Build a minimal, docs/-less copy of the tree install.sh needs ─────────
TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}/systemd" "${TEMP_REPO}/scripts/host"
cp "${INSTALL_SCRIPT}" "${TEMP_REPO}/install.sh"
cp "${REPO_ROOT}"/systemd/ezgha-*.service "${REPO_ROOT}"/systemd/ezgha-*.timer "${TEMP_REPO}/systemd/" 2>/dev/null || true
cp "${REPO_ROOT}"/systemd/app-lima-vm.slice \
   "${REPO_ROOT}"/systemd/agents.slice \
   "${REPO_ROOT}"/systemd/automation.slice \
   "${TEMP_REPO}/systemd/"
# The production tree deliberately removed these legacy artifacts.  Keep
# minimal fixture inputs so the parent installer reaches Case A's stale-copy
# assertions instead of failing while it tries to stage its then-required
# sources.
printf '[Unit]\nDescription=legacy reaper fixture\n' \
  > "${TEMP_REPO}/systemd/agent-scope-reaper.service"
printf '[Timer]\nUnit=agent-scope-reaper.service\n' \
  > "${TEMP_REPO}/systemd/agent-scope-reaper.timer"
mkdir -p "${TEMP_REPO}/systemd/host"
cp -r "${REPO_ROOT}/systemd/host"/* "${TEMP_REPO}/systemd/host/" 2>/dev/null || true
mkdir -p "${TEMP_REPO}/systemd/ao-daemon.service.d" \
         "${TEMP_REPO}/systemd/ao-orchestrator.service.d" \
         "${TEMP_REPO}/systemd/ai.dark-factory.daemon.service.d" \
         "${TEMP_REPO}/systemd/lima-vm@colima.service.d" \
         "${TEMP_REPO}/systemd/guest"
cp "${REPO_ROOT}"/systemd/ao-daemon.service.d/20-automation-slice.conf \
   "${TEMP_REPO}/systemd/ao-daemon.service.d/"
cp "${REPO_ROOT}"/systemd/ao-orchestrator.service.d/20-automation-slice.conf \
   "${TEMP_REPO}/systemd/ao-orchestrator.service.d/"
cp "${REPO_ROOT}"/systemd/ai.dark-factory.daemon.service.d/20-automation-slice.conf \
   "${TEMP_REPO}/systemd/ai.dark-factory.daemon.service.d/"
cp "${REPO_ROOT}"/systemd/lima-vm@colima.service.d/99-memory-ceiling.conf \
   "${TEMP_REPO}/systemd/lima-vm@colima.service.d/"
cp "${REPO_ROOT}"/systemd/lima-vm-cpu-ceiling.service \
   "${TEMP_REPO}/systemd/"
cp "${REPO_ROOT}"/systemd/guest/actions.slice \
   "${TEMP_REPO}/systemd/guest/"
printf '[package]\nname = "ez-gh-actions"\nversion = "0.0.0"\n' > "${TEMP_REPO}/Cargo.toml"
for name in refresh_gh_app_token.sh cleanup-stuck-runs.sh; do
  printf '#!/usr/bin/env bash\ntrue\n' > "${TEMP_REPO}/scripts/${name}"
  chmod +x "${TEMP_REPO}/scripts/${name}"
done
printf '#!/usr/bin/env bash\ntrue\n' > "${TEMP_REPO}/scripts/host/agent-scope-reaper.sh"
chmod +x "${TEMP_REPO}/scripts/host/agent-scope-reaper.sh"
for name in agent-scoped-launch.sh assert-host-containment-release1.sh apply-host-containment-release1.sh; do
  if [ -f "${REPO_ROOT}/scripts/host/${name}" ]; then
    cp "${REPO_ROOT}/scripts/host/${name}" "${TEMP_REPO}/scripts/host/${name}"
  fi
done

# Record the QEMU guard calls without inspecting or changing live cgroups.
cat > "${TEMP_REPO}/scripts/host/qemu-ceiling-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'qemu-ceiling-guard:%s\n' "$*" >> "${SYSTEMCTL_CAPTURE:?}"
EOF
chmod +x "${TEMP_REPO}/scripts/host/qemu-ceiling-guard.sh"

# ── 2. Stub PATH ───────────────────────────────────────────────────────────
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"

cat > "${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  branch) echo "main" ;;
  status) exit 0 ;;
  fetch) exit 0 ;;
  rev-parse) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
  *) exit 0 ;;
esac
EOF

cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/rustc" <<'EOF'
#!/usr/bin/env bash
echo "rustc 1.0.0 (stub)"
EOF

cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" info "* ]]; then
  # A different kernel models the existing VM-backed path; this watchdog test
  # deliberately does not exercise the host-Docker activation branch.
  echo "fixture-vm-kernel"
fi
exit 0
EOF

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/limactl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

for agent in codex claude gemini; do
  cat > "${STUB_BIN}/${agent}" <<EOF
#!/usr/bin/env bash
echo ${agent}-stub
EOF
done

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF

cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${SYSTEMCTL_STATE_DIR:?SYSTEMCTL_STATE_DIR must be exported}"
if [ "${1:-}" = "--user" ]; then shift; fi
printf '%s\n' "$*" >> "${SYSTEMCTL_CAPTURE:-/dev/null}"
sub="${1:-}"
shift || true
in_list() {
  local needle="$1" item
  for item in ${2:-}; do [ "$item" = "$needle" ] && return 0; done
  return 1
}
case "${sub}" in
  enable)
    [ "${1:-}" = "--now" ] && shift
    touch "${SYSTEMCTL_STATE_DIR}/${1}.enabled"
    exit 0
    ;;
  disable)
    [ "${1:-}" = "--now" ] && shift
    if in_list "${1:-}" "${STUB_DISABLE_FAIL_UNITS:-}"; then exit 1; fi
    rm -f "${SYSTEMCTL_STATE_DIR}/${1}.enabled"
    exit 0
    ;;
  is-enabled)
    if in_list "${1:-}" "${STUB_ENABLED_QUERY_FAIL_UNITS:-}"; then
      echo 'Failed to connect to bus: No medium found' >&2
      exit 1
    fi
    if in_list "${1:-}" "${STUB_IS_ENABLED_NOT_FOUND_UNITS:-}"; then
      echo "Failed to get unit file state for ${1}: No such file or directory" >&2
      exit 1
    fi
    if [ -f "${SYSTEMCTL_STATE_DIR}/${1}.enabled" ]; then
      echo enabled
      exit 0
    fi
    echo disabled
    exit 1
    ;;
  is-active)
    if in_list "${1:-}" "${STUB_QUERY_FAIL_UNITS:-}"; then
      echo 'Failed to connect to bus: No medium found' >&2
      exit 1
    fi
    if in_list "${1:-}" "${STUB_ACTIVE_UNITS:-}"; then
      echo active
      exit 0
    fi
    echo inactive
    exit 3
    ;;
  stop)
    if in_list "${1:-}" "${STUB_STOP_FAIL_UNITS:-}"; then
      exit 1
    fi
    exit 0
    ;;
  daemon-reload)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:${PATH}"
export LIMACTL_CAPTURE="${WORK}/limactl.calls"
export SYSTEMCTL_CAPTURE="${WORK}/systemctl.calls"
: > "${LIMACTL_CAPTURE}"
: > "${SYSTEMCTL_CAPTURE}"

run_install() {
  local temp_home="$1" state_dir="$2"
  shift 2
  mkdir -p "${state_dir}"
  HOME="${temp_home}" SYSTEMCTL_STATE_DIR="${state_dir}" \
    bash "${TEMP_REPO}/install.sh" --dev "$@" >"${temp_home}/install.log" 2>&1
}

# ── Case A: default run cleans up and does not install watchdog ────────────────
HOME_A="${WORK}/home_a"
STATE_A="${WORK}/state_a"
mkdir -p "${HOME_A}/.config/systemd/user" "${STATE_A}"
touch "${STATE_A}/ezgha-watchdog.timer.enabled" # simulate prior installation
touch "${HOME_A}/.config/systemd/user/ezgha-watchdog.timer"
touch "${HOME_A}/.config/systemd/user/ezgha-watchdog.service"
# Previously installed copies of the deleted agent-scope-reaper must be removed.
touch "${HOME_A}/.config/systemd/user/agent-scope-reaper.service" \
      "${HOME_A}/.config/systemd/user/agent-scope-reaper.timer"
mkdir -p "${HOME_A}/.local/libexec/ezgha"
touch "${HOME_A}/.local/libexec/ezgha/agent-scope-reaper.sh"
run_install "${HOME_A}" "${STATE_A}"

for args in "" "--apply"; do
  if ! grep -Fqx "qemu-ceiling-guard:${args}" "${SYSTEMCTL_CAPTURE}"; then
    fail "Case A: installer skipped QEMU guard invocation: ${args:-check}"
  fi
done

if [ -f "${STATE_A}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case A: default run failed to disable ezgha-watchdog.timer"
else
  echo "PASS: Case A: default run disabled ezgha-watchdog.timer"
fi
if [ -f "${HOME_A}/.config/systemd/user/ezgha-watchdog.timer" ] || [ -f "${HOME_A}/.config/systemd/user/ezgha-watchdog.service" ]; then
  fail "Case A: watchdog unit files survived installation"
else
  echo "PASS: Case A: watchdog unit files removed from systemd user config"
fi
if ! grep -Fqx 'stop ezgha-watchdog.service' "${SYSTEMCTL_CAPTURE}"; then
  fail "Case A: default install did not stop an in-flight ezgha-watchdog.service"
else
  echo "PASS: Case A: default install stopped ezgha-watchdog.service"
fi
if [ -f "${HOME_A}/.local/libexec/ezgha/watchdog-load-repair.sh" ] || [ -f "${HOME_A}/.local/bin/watchdog-load-repair.sh" ]; then
  fail "Case A: watchdog-load-repair.sh was installed"
else
  echo "PASS: Case A: watchdog-load-repair.sh was not installed"
fi

# Host crash controls are source-controlled and rendered into stable paths.
for unit in app-lima-vm.slice agents.slice automation.slice; do
  if [ ! -f "${HOME_A}/.config/systemd/user/${unit}" ]; then
    fail "Case A: host control unit was not installed: ${unit}"
  fi
done

# A failed disable is safe only when a later query proves the timer is not
# enabled.  Inactive runtime state alone must not authorize artifact removal.
HOME_G="${WORK}/home_g"
STATE_G="${WORK}/state_g"
mkdir -p "${HOME_G}/.config/systemd/user" "${HOME_G}/.local/libexec/ezgha" "${STATE_G}"
touch "${HOME_G}/.config/systemd/user/agent-scope-reaper.service" \
      "${HOME_G}/.config/systemd/user/agent-scope-reaper.timer" \
      "${HOME_G}/.local/libexec/ezgha/agent-scope-reaper.sh" \
      "${STATE_G}/agent-scope-reaper.timer.enabled"
install_rc=0
STUB_DISABLE_FAIL_UNITS=agent-scope-reaper.timer \
  run_install "${HOME_G}" "${STATE_G}" || install_rc=$?
[ "$install_rc" -ne 0 ] \
  || fail "Case G: installer must fail when inactive reaper timer remains enabled"
for stale in \
  "${HOME_G}/.config/systemd/user/agent-scope-reaper.service" \
  "${HOME_G}/.config/systemd/user/agent-scope-reaper.timer" \
  "${HOME_G}/.local/libexec/ezgha/agent-scope-reaper.sh"; do
  [ -e "$stale" ] || fail "Case G: enabled reaper artifact was deleted: $stale"
done

# Failed enabled-state queries are not proof of retirement, even while both
# units are inactive.
HOME_H="${WORK}/home_h"
STATE_H="${WORK}/state_h"
mkdir -p "${HOME_H}/.config/systemd/user" "${HOME_H}/.local/libexec/ezgha" "${STATE_H}"
touch "${HOME_H}/.config/systemd/user/agent-scope-reaper.service" \
      "${HOME_H}/.config/systemd/user/agent-scope-reaper.timer" \
      "${HOME_H}/.local/libexec/ezgha/agent-scope-reaper.sh"
install_rc=0
STUB_ENABLED_QUERY_FAIL_UNITS=agent-scope-reaper.timer \
  run_install "${HOME_H}" "${STATE_H}" || install_rc=$?
[ "$install_rc" -ne 0 ] \
  || fail "Case H: installer must fail closed when reaper enabled state cannot be queried"
for stale in \
  "${HOME_H}/.config/systemd/user/agent-scope-reaper.service" \
  "${HOME_H}/.config/systemd/user/agent-scope-reaper.timer" \
  "${HOME_H}/.local/libexec/ezgha/agent-scope-reaper.sh"; do
  [ -e "$stale" ] || fail "Case H: reaper artifact was deleted after enabled-state query failure: $stale"
done

# A deleted unit file is a valid enabled-state result only when runtime is
# inactive, which this fixture supplies.
HOME_I="${WORK}/home_i"
STATE_I="${WORK}/state_i"
mkdir -p "${HOME_I}/.config/systemd/user" "${HOME_I}/.local/libexec/ezgha" "${STATE_I}"
touch "${HOME_I}/.config/systemd/user/agent-scope-reaper.service" \
      "${HOME_I}/.config/systemd/user/agent-scope-reaper.timer" \
      "${HOME_I}/.local/libexec/ezgha/agent-scope-reaper.sh"
STUB_IS_ENABLED_NOT_FOUND_UNITS=agent-scope-reaper.timer \
  run_install "${HOME_I}" "${STATE_I}"
for removed in \
  "${HOME_I}/.config/systemd/user/agent-scope-reaper.service" \
  "${HOME_I}/.config/systemd/user/agent-scope-reaper.timer" \
  "${HOME_I}/.local/libexec/ezgha/agent-scope-reaper.sh"; do
  [ ! -e "$removed" ] || fail "Case I: inactive absent reaper artifact survived: $removed"
done

for unit in psi-oom-watcher.service psi-oom-watcher.timer \
            agent-scope-reaper.service agent-scope-reaper.timer; do
  if [ -f "${HOME_A}/.config/systemd/user/${unit}" ]; then
    fail "Case A: deprecated host control unit was not removed: ${unit}"
  fi
done

if [ -e "${HOME_A}/.local/libexec/ezgha/agent-scope-reaper.sh" ]; then
  fail "Case A: stale agent-scope-reaper.sh was not removed"
fi
for script in agent-scoped-launch.sh assert-host-containment-release1.sh apply-host-containment-release1.sh; do
  if [ ! -x "${HOME_A}/.local/libexec/ezgha/${script}" ]; then
    fail "Case A: stable host script was not installed: ${script}"
  fi
done

# ── Case D: never delete reaper files while its service remains active ───────
HOME_D="${WORK}/home_d"
STATE_D="${WORK}/state_d"
mkdir -p "${HOME_D}/.config/systemd/user" "${HOME_D}/.local/libexec/ezgha" "${STATE_D}"
touch "${HOME_D}/.config/systemd/user/agent-scope-reaper.service" \
      "${HOME_D}/.config/systemd/user/agent-scope-reaper.timer" \
      "${HOME_D}/.local/libexec/ezgha/agent-scope-reaper.sh"
install_rc=0
STUB_STOP_FAIL_UNITS=agent-scope-reaper.service STUB_ACTIVE_UNITS=agent-scope-reaper.service \
  run_install "${HOME_D}" "${STATE_D}" || install_rc=$?
[ "$install_rc" -ne 0 ] \
  || fail "Case D: installer must fail when agent-scope-reaper remains active"
for stale in \
  "${HOME_D}/.config/systemd/user/agent-scope-reaper.service" \
  "${HOME_D}/.config/systemd/user/agent-scope-reaper.timer" \
  "${HOME_D}/.local/libexec/ezgha/agent-scope-reaper.sh"; do
  [ -e "$stale" ] || fail "Case D: active reaper artifact was deleted: $stale"
done
grep -Fq 'refusing to remove agent-scope-reaper files' "${HOME_D}/install.log" \
  || fail "Case D: installer omitted active-reaper refusal"

# A reaper timer that remains active is not safe even if its service stopped.
HOME_E="${WORK}/home_e"
STATE_E="${WORK}/state_e"
mkdir -p "${HOME_E}/.config/systemd/user" "${HOME_E}/.local/libexec/ezgha" "${STATE_E}"
touch "${HOME_E}/.config/systemd/user/agent-scope-reaper.service" \
      "${HOME_E}/.config/systemd/user/agent-scope-reaper.timer" \
      "${HOME_E}/.local/libexec/ezgha/agent-scope-reaper.sh"
install_rc=0
STUB_DISABLE_FAIL_UNITS=agent-scope-reaper.timer STUB_ACTIVE_UNITS=agent-scope-reaper.timer \
  run_install "${HOME_E}" "${STATE_E}" || install_rc=$?
[ "$install_rc" -ne 0 ] \
  || fail "Case E: installer must fail when agent-scope-reaper timer remains active"
for stale in \
  "${HOME_E}/.config/systemd/user/agent-scope-reaper.service" \
  "${HOME_E}/.config/systemd/user/agent-scope-reaper.timer" \
  "${HOME_E}/.local/libexec/ezgha/agent-scope-reaper.sh"; do
  [ -e "$stale" ] || fail "Case E: reaper artifact was deleted while timer remained active: $stale"
done

# An unavailable user-manager bus is not evidence that the reaper timer stopped.
HOME_F="${WORK}/home_f"
STATE_F="${WORK}/state_f"
mkdir -p "${HOME_F}/.config/systemd/user" "${HOME_F}/.local/libexec/ezgha" "${STATE_F}"
touch "${HOME_F}/.config/systemd/user/agent-scope-reaper.service" \
      "${HOME_F}/.config/systemd/user/agent-scope-reaper.timer" \
      "${HOME_F}/.local/libexec/ezgha/agent-scope-reaper.sh"
install_rc=0
STUB_QUERY_FAIL_UNITS=agent-scope-reaper.timer run_install "${HOME_F}" "${STATE_F}" || install_rc=$?
[ "$install_rc" -ne 0 ] \
  || fail "Case F: installer must fail closed when reaper timer state cannot be queried"
for stale in \
  "${HOME_F}/.config/systemd/user/agent-scope-reaper.service" \
  "${HOME_F}/.config/systemd/user/agent-scope-reaper.timer" \
  "${HOME_F}/.local/libexec/ezgha/agent-scope-reaper.sh"; do
  [ -e "$stale" ] || fail "Case F: reaper artifact was deleted after timer query failure: $stale"
done

# The PSI watcher must be stopped and verified before its retired files vanish.
for psi_case in active query; do
  psi_home="${WORK}/home_psi_${psi_case}"
  psi_state="${WORK}/state_psi_${psi_case}"
  mkdir -p "${psi_home}/.config/systemd/user"
  touch "${psi_home}/.config/systemd/user/psi-oom-watcher.service" \
        "${psi_home}/.config/systemd/user/psi-oom-watcher.timer"
  install_rc=0
  if [ "$psi_case" = active ]; then
    STUB_DISABLE_FAIL_UNITS=psi-oom-watcher.timer STUB_ACTIVE_UNITS=psi-oom-watcher.service \
      run_install "${psi_home}" "${psi_state}" || install_rc=$?
  else
    STUB_QUERY_FAIL_UNITS=psi-oom-watcher.service \
      run_install "${psi_home}" "${psi_state}" || install_rc=$?
  fi
  [ "$install_rc" -ne 0 ] \
    || fail "Case PSI-${psi_case}: installer must fail before removing unsafe watcher units"
  for stale in \
    "${psi_home}/.config/systemd/user/psi-oom-watcher.service" \
    "${psi_home}/.config/systemd/user/psi-oom-watcher.timer"; do
    [ -e "$stale" ] || fail "Case PSI-${psi_case}: watcher artifact was deleted unsafely: $stale"
  done
done

# ── Case C: macOS path removes the leftover fleet watchdog LaunchAgent ───────
# (static: the macOS branch needs launchctl/colima and is not drivable here)
for needle in \
  'launchctl bootout "gui/$(id -u)/org.jleechanorg.ezgha-watchdog"' \
  'rm -f "${watchdog_plist}"' \
  'ezgha-fleet-watchdog.sh'; do
  grep -qF -- "${needle}" "${REPO_ROOT}/install.sh" \
    || fail "Case C: install.sh macOS path lacks watchdog removal: ${needle}"
done

# ── Case B: uninstall removes host controls and restored CLI symlinks ─────────
HOME_B="${WORK}/home_b"
STATE_B="${WORK}/state_b"
mkdir -p "${HOME_B}/.local/bin" "${STATE_B}"
ln -s "${STUB_BIN}/codex" "${HOME_B}/.local/bin/codex"
run_install "${HOME_B}" "${STATE_B}"
HOME="${HOME_B}" SYSTEMCTL_STATE_DIR="${STATE_B}" \
  bash "${TEMP_REPO}/install.sh" --uninstall >"${HOME_B}/uninstall.log" 2>&1
if [ ! -L "${HOME_B}/.local/bin/codex" ] || [ "$(readlink "${HOME_B}/.local/bin/codex")" != "${STUB_BIN}/codex" ]; then
  fail "Case B: uninstall did not restore the pre-existing codex symlink"
fi
if [ -e "${HOME_B}/.config/systemd/user/agents.slice" ] || \
   [ -e "${HOME_B}/.config/systemd/user/automation.slice" ]; then
  fail "Case B: uninstall left host-control units behind"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
