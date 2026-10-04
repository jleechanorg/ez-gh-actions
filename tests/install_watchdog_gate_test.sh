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
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"
cp "${REPO_ROOT}"/systemd/ezgha-*.service "${REPO_ROOT}"/systemd/ezgha-*.timer "${TEMP_REPO}/systemd/" 2>/dev/null || true
cp "${REPO_ROOT}"/systemd/app-lima-vm.slice \
   "${REPO_ROOT}"/systemd/agents.slice \
   "${REPO_ROOT}"/systemd/automation.slice \
   "${REPO_ROOT}"/systemd/agent-scope-reaper.service \
   "${REPO_ROOT}"/systemd/agent-scope-reaper.timer \
   "${TEMP_REPO}/systemd/"
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
cp -r "${REPO_ROOT}/systemd/host-docker" "${TEMP_REPO}/systemd/"
printf '[package]\nname = "ez-gh-actions"\nversion = "0.0.0"\n' > "${TEMP_REPO}/Cargo.toml"
for name in refresh_gh_app_token.sh cleanup-stuck-runs.sh; do
  printf '#!/usr/bin/env bash\ntrue\n' > "${TEMP_REPO}/scripts/${name}"
  chmod +x "${TEMP_REPO}/scripts/${name}"
done
for name in agent-scoped-launch.sh agent-scope-reaper.sh assert-host-containment-release1.sh apply-host-containment-release1.sh lima-guest-memory-check.sh; do
  if [ -f "${REPO_ROOT}/scripts/host/${name}" ]; then
    cp "${REPO_ROOT}/scripts/host/${name}" "${TEMP_REPO}/scripts/host/${name}"
  fi
done

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
    if [ -f "${SYSTEMCTL_STATE_DIR}/${1}.enabled" ]; then echo enabled; exit 0; fi
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
run_install "${HOME_A}" "${STATE_A}"

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
for unit in agent-scope-reaper psi-oom-watcher; do
  grep -Fqx "disable --now ${unit}.timer" "${SYSTEMCTL_CAPTURE}" \
    || fail "Case A: default install did not disable ${unit}.timer"
  grep -Fqx "stop ${unit}.service" "${SYSTEMCTL_CAPTURE}" \
    || fail "Case A: default install did not stop ${unit}.service"
done
if [ -f "${HOME_A}/.local/libexec/ezgha/watchdog-load-repair.sh" ] || [ -f "${HOME_A}/.local/bin/watchdog-load-repair.sh" ]; then
  fail "Case A: watchdog-load-repair.sh was installed"
else
  echo "PASS: Case A: watchdog-load-repair.sh was not installed"
fi

# Host crash controls are source-controlled and rendered into stable paths.
for unit in app-lima-vm.slice agents.slice automation.slice \
            agent-scope-reaper.service agent-scope-reaper.timer; do
  if [ ! -f "${HOME_A}/.config/systemd/user/${unit}" ]; then
    fail "Case A: host control unit was not installed: ${unit}"
  fi
done

for unit in psi-oom-watcher.service psi-oom-watcher.timer; do
  if [ -f "${HOME_A}/.config/systemd/user/${unit}" ]; then
    fail "Case A: deprecated host control unit was not removed: ${unit}"
  fi
done

for script in agent-scoped-launch.sh agent-scope-reaper.sh assert-host-containment-release1.sh apply-host-containment-release1.sh; do
  if [ ! -x "${HOME_A}/.local/libexec/ezgha/${script}" ]; then
    fail "Case A: stable host script was not installed: ${script}"
  fi
done

# Both retired paths stop their timer and service independently and retain
# artifacts if either runtime state is active or cannot be queried.
for retired in agent-scope-reaper psi-oom-watcher; do
  for state in active query; do
    home="${WORK}/home_${retired}_${state}"
    state_dir="${WORK}/state_${retired}_${state}"
    mkdir -p "${home}/.config/systemd/user" "${home}/.local/libexec/ezgha" "${state_dir}"
    touch "${home}/.config/systemd/user/${retired}.service" \
          "${home}/.config/systemd/user/${retired}.timer"
    if [ "${retired}" = agent-scope-reaper ]; then
      touch "${home}/.local/libexec/ezgha/agent-scope-reaper.sh"
    fi
    install_rc=0
    if [ "${state}" = active ]; then
      STUB_DISABLE_FAIL_UNITS="${retired}.timer" STUB_ACTIVE_UNITS="${retired}.service" \
        run_install "${home}" "${state_dir}" || install_rc=$?
    else
      STUB_QUERY_FAIL_UNITS="${retired}.timer" \
        run_install "${home}" "${state_dir}" || install_rc=$?
    fi
    [ "${install_rc}" -ne 0 ] \
      || fail "${retired} ${state}: installer must refuse unsafe retired-unit cleanup"
    for stale in "${home}/.config/systemd/user/${retired}.service" "${home}/.config/systemd/user/${retired}.timer"; do
      [ -e "${stale}" ] || fail "${retired} ${state}: installer removed unsafe artifact ${stale}"
    done
  done
done

# A failed disable command is not proof of retirement: even an inactive timer
# must retain its artifacts if is-enabled still reports enabled.
for retired in agent-scope-reaper psi-oom-watcher; do
  home="${WORK}/home_${retired}_enabled"
  state_dir="${WORK}/state_${retired}_enabled"
  mkdir -p "${home}/.config/systemd/user" "${home}/.local/libexec/ezgha" "${state_dir}"
  touch "${home}/.config/systemd/user/${retired}.service" \
        "${home}/.config/systemd/user/${retired}.timer" \
        "${state_dir}/${retired}.timer.enabled"
  if [ "${retired}" = agent-scope-reaper ]; then
    touch "${home}/.local/libexec/ezgha/agent-scope-reaper.sh"
  fi
  install_rc=0
  STUB_DISABLE_FAIL_UNITS="${retired}.timer" \
    run_install "${home}" "${state_dir}" || install_rc=$?
  [ "${install_rc}" -ne 0 ] \
    || fail "${retired} enabled: installer must reject an enabled timer after failed disable"
  for stale in "${home}/.config/systemd/user/${retired}.service" "${home}/.config/systemd/user/${retired}.timer"; do
    [ -e "${stale}" ] || fail "${retired} enabled: installer removed enabled-unit artifact ${stale}"
  done
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
   [ -e "${HOME_B}/.config/systemd/user/agent-scope-reaper.timer" ]; then
  fail "Case B: uninstall left host-control units behind"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
