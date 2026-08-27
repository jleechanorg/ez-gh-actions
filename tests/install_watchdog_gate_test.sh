#!/usr/bin/env bash
# regression test: install.sh arms the fleet watchdog by default.
# A default `./install.sh` run must:
#   (a) render/copy the ezgha-watchdog.timer/.service unit files
#       (repo is source, ~/.config/systemd/user is what systemctl reads),
#   (b) enable `systemctl --user enable --now` for the watchdog timer,
#   (c) render ezgha-watchdog.service with EZGHA_WATCHDOG_ALLOW_RESTART=1.
# `./install.sh --without-watchdog` must skip arming and heal drift: if the
# watchdog timer is already enabled (e.g. an out-of-band re-arm), disable it.
# `./install.sh --with-watchdog` remains supported (same as default).
#
# This drives install.sh's REAL Linux watchdog-gating code path end-to-end
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

INSTALLED_MAC_HOST_ARG="$(
  sed -n 's/.*ezgha-fleet-watchdog\.sh" "--host \([^" ]*\)".*/\1/p' \
    "$REPO_ROOT/install.sh"
)"
PARSER_HOSTS="$(
  sed -n 's/.*argument (\([^)]*\)).*/\1/p' \
    "$REPO_ROOT/scripts/ezgha-fleet-watchdog.sh" | head -1
)"
if printf '%s\n' "$PARSER_HOSTS" | tr '|' '\n' | grep -Fxq "$INSTALLED_MAC_HOST_ARG"; then
  echo "PASS: Mac watchdog install host '$INSTALLED_MAC_HOST_ARG' matches parser"
else
  fail "Mac watchdog install host '$INSTALLED_MAC_HOST_ARG' is outside parser contract '$PARSER_HOSTS'"
fi

# ── 1. Build a minimal, docs/-less copy of the tree install.sh needs ─────────
# (docs/-less so the live post-deploy verify-exit-criteria.sh gate is never
# reached -- see header comment.)
TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}/systemd" "${TEMP_REPO}/scripts/host"
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"
cp "${REPO_ROOT}"/systemd/ezgha-*.service "${REPO_ROOT}"/systemd/ezgha-*.timer "${TEMP_REPO}/systemd/"
cp "${REPO_ROOT}"/systemd/app-lima-vm.slice \
   "${REPO_ROOT}"/systemd/agents.slice \
   "${REPO_ROOT}"/systemd/automation.slice \
   "${REPO_ROOT}"/systemd/agent-scope-reaper.service \
   "${REPO_ROOT}"/systemd/agent-scope-reaper.timer \
   "${REPO_ROOT}"/systemd/psi-oom-watcher.service \
   "${REPO_ROOT}"/systemd/psi-oom-watcher.timer \
   "${TEMP_REPO}/systemd/"
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
cp "${REPO_ROOT}"/systemd/guest/actions.slice \
   "${TEMP_REPO}/systemd/guest/"
printf '[package]\nname = "ez-gh-actions"\nversion = "0.0.0"\n' > "${TEMP_REPO}/Cargo.toml"
for name in ezgha-fleet-watchdog.sh refresh_gh_app_token.sh cleanup-stuck-runs.sh; do
  printf '#!/usr/bin/env bash\ntrue\n' > "${TEMP_REPO}/scripts/${name}"
  chmod +x "${TEMP_REPO}/scripts/${name}"
done
for name in agent-scoped-launch.sh agent-scope-reaper.sh psi-oom-watcher.sh watchdog-load-repair.sh; do
  cp "${REPO_ROOT}/scripts/host/${name}" "${TEMP_REPO}/scripts/host/${name}"
done

# ── 2. Stub PATH ───────────────────────────────────────────────────────────
# git/cargo/rustc/docker/gh: always succeed, never touch anything real.
# systemctl: a stateful fake that remembers per-unit enable/disable state in
# $SYSTEMCTL_STATE_DIR so the test can assert on it afterward.
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
exit 0
EOF

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/limactl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LIMACTL_CAPTURE:?}"
case "$*" in
  *"tee /etc/systemd/system/actions.slice"*) cat > "${GUEST_ACTIONS_SLICE_CAPTURE:?}" ;;
esac
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
# Stateful stub: enable/disable/is-enabled tracked as touch-files under
# $SYSTEMCTL_STATE_DIR/<unit>.enabled -- SYSTEMCTL_STATE_DIR is exported by
# the test harness.
: "${SYSTEMCTL_STATE_DIR:?SYSTEMCTL_STATE_DIR must be exported}"
if [ "${1:-}" = "--user" ]; then shift; fi
printf '%s\n' "$*" >> "${SYSTEMCTL_CAPTURE:-/dev/null}"
sub="${1:-}"
shift || true
case "${sub}" in
  enable)
    [ "${1:-}" = "--now" ] && shift
    touch "${SYSTEMCTL_STATE_DIR}/${1}.enabled"
    exit 0
    ;;
  disable)
    [ "${1:-}" = "--now" ] && shift
    rm -f "${SYSTEMCTL_STATE_DIR}/${1}.enabled"
    exit 0
    ;;
  is-enabled)
    [ -f "${SYSTEMCTL_STATE_DIR}/${1}.enabled" ] && exit 0 || exit 1
    ;;
  is-active)
    exit 1
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
export GUEST_ACTIONS_SLICE_CAPTURE="${WORK}/guest-actions.slice"
export SYSTEMCTL_CAPTURE="${WORK}/systemctl.calls"
: > "${LIMACTL_CAPTURE}"
: > "${SYSTEMCTL_CAPTURE}"

run_install() {
  # $1 = temp HOME, $2 = systemctl state dir, remaining = install.sh args
  local temp_home="$1" state_dir="$2"
  shift 2
  mkdir -p "${state_dir}"
  HOME="${temp_home}" SYSTEMCTL_STATE_DIR="${state_dir}" \
    bash "${TEMP_REPO}/install.sh" --dev "$@" >"${temp_home}/install.log" 2>&1
}

# ── Case A: default run arms watchdog ────────────────────────────────────────
HOME_A="${WORK}/home_a"
STATE_A="${WORK}/state_a"
mkdir -p "${HOME_A}" "${STATE_A}"
touch "${STATE_A}/psi-oom-watcher.timer.enabled" # simulate prior installation
run_install "${HOME_A}" "${STATE_A}"

if [ ! -f "${STATE_A}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case A: default run did NOT enable ezgha-watchdog.timer (watchdog armed by default)"
else
  echo "PASS: Case A: default run enabled ezgha-watchdog.timer"
fi

if [ ! -f "${STATE_A}/ezgha-token-refresh.timer.enabled" ] || [ ! -f "${STATE_A}/ezgha-queue-reaper.timer.enabled" ]; then
  fail "Case A: default run failed to enable token-refresh/queue-reaper timers"
else
  echo "PASS: Case A: default run still enabled token-refresh + queue-reaper timers"
fi

rendered_timer="${HOME_A}/.config/systemd/user/ezgha-watchdog.timer"
if [ ! -f "${rendered_timer}" ]; then
  fail "Case A: default run did not render ezgha-watchdog.timer unit file"
else
  echo "PASS: Case A: default run rendered ezgha-watchdog.timer unit file"
fi

rendered_service="${HOME_A}/.config/systemd/user/ezgha-watchdog.service"
if [ ! -f "${rendered_service}" ]; then
  fail "Case A: default run did not render ezgha-watchdog.service unit file"
else
  echo "PASS: Case A: default run rendered ezgha-watchdog.service unit file"
fi

if ! grep -q 'Environment=EZGHA_WATCHDOG_ALLOW_RESTART=1' "${rendered_service}"; then
  fail "Case A: rendered ezgha-watchdog.service missing EZGHA_WATCHDOG_ALLOW_RESTART=1"
else
  echo "PASS: Case A: rendered ezgha-watchdog.service includes EZGHA_WATCHDOG_ALLOW_RESTART=1"
fi

# Host crash controls are source-controlled and rendered into stable paths.
for unit in app-lima-vm.slice agents.slice automation.slice \
            agent-scope-reaper.service agent-scope-reaper.timer \
            psi-oom-watcher.service psi-oom-watcher.timer; do
  if [ ! -f "${HOME_A}/.config/systemd/user/${unit}" ]; then
    fail "Case A: host control unit was not installed: ${unit}"
  fi
done
if [ ! -f "${STATE_A}/agent-scope-reaper.timer.enabled" ]; then
  fail "Case A: agent-scope-reaper.timer was not enabled"
fi
if [ -f "${STATE_A}/psi-oom-watcher.timer.enabled" ]; then
  fail "Case A: default install re-enabled retired psi-oom-watcher.timer"
else
  echo "PASS: Case A: default install kept psi-oom-watcher.timer disabled"
fi
if ! grep -Fqx 'disable --now psi-oom-watcher.timer' "${SYSTEMCTL_CAPTURE}"; then
  fail "Case A: default install did not explicitly heal a previously enabled psi-oom-watcher.timer"
else
  echo "PASS: Case A: default install disabled a drifted psi-oom-watcher.timer"
fi
if ! grep -Fqx 'stop psi-oom-watcher.service' "${SYSTEMCTL_CAPTURE}"; then
  fail "Case A: default install did not stop an in-flight psi-oom-watcher.service"
else
  echo "PASS: Case A: default install stopped psi-oom-watcher.service"
fi
for script in agent-scoped-launch.sh agent-scope-reaper.sh psi-oom-watcher.sh watchdog-load-repair.sh; do
  if [ ! -x "${HOME_A}/.local/libexec/ezgha/${script}" ]; then
    fail "Case A: stable host script was not installed: ${script}"
  fi
done
for dropin in \
  ao-daemon.service.d/20-automation-slice.conf \
  ao-orchestrator.service.d/20-automation-slice.conf \
  ai.dark-factory.daemon.service.d/20-automation-slice.conf; do
  if [ ! -f "${HOME_A}/.config/systemd/user/${dropin}" ]; then
    fail "Case A: service drop-in was not installed: ${dropin}"
  fi
done
if [ ! -f "${HOME_A}/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" ]; then
  fail "Case A: direct QEMU service memory ceiling was not installed"
fi
if ! grep -Fqx 'set-property --runtime lima-vm@colima.service MemoryHigh=34G MemoryMax=38G MemorySwapMax=2G TasksMax=4096' "${SYSTEMCTL_CAPTURE}"; then
  fail "Case A: direct QEMU service memory ceiling was not applied live"
fi
if ! cmp -s "${REPO_ROOT}/systemd/guest/actions.slice" "${GUEST_ACTIONS_SLICE_CAPTURE}"; then
  fail "Case A: tracked guest actions.slice was not installed through limactl"
fi
if ! grep -Fqx 'shell colima -- sudo -n systemctl set-property --runtime actions.slice MemoryHigh=28G MemoryMax=32G MemorySwapMax=0 TasksMax=6000' "${LIMACTL_CAPTURE}"; then
  fail "Case A: guest actions.slice live limits were not applied"
fi
for agent in codex claude gemini; do
  wrapper="${HOME_A}/.local/bin/${agent}"
  if [ ! -x "${wrapper}" ] || ! grep -q 'ezgha-agent-wrapper' "${wrapper}"; then
    fail "Case A: scoped agent wrapper was not installed: ${agent}"
  fi
done

# ── Case B: --without-watchdog heals drift (pre-enabled timer disabled) ──────
HOME_B="${WORK}/home_b"
STATE_B="${WORK}/state_b"
mkdir -p "${HOME_B}" "${STATE_B}"
touch "${STATE_B}/ezgha-watchdog.timer.enabled"   # simulate out-of-band re-arm
run_install "${HOME_B}" "${STATE_B}" --without-watchdog

if [ -f "${STATE_B}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case B: --without-watchdog did NOT disable a pre-enabled ezgha-watchdog.timer"
else
  echo "PASS: Case B: --without-watchdog disabled a drifted-enabled ezgha-watchdog.timer"
fi

if ! grep -q "watchdog arming skipped" "${HOME_B}/install.log"; then
  fail "Case B: install.sh did not print the watchdog opt-out skip message"
else
  echo "PASS: Case B: install.sh printed the watchdog opt-out skip message"
fi

# ── Case C: --with-watchdog still arms it (backward compat) ──────────────────
HOME_C="${WORK}/home_c"
STATE_C="${WORK}/state_c"
mkdir -p "${HOME_C}"
run_install "${HOME_C}" "${STATE_C}" --with-watchdog

if [ ! -f "${STATE_C}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case C: --with-watchdog did not enable ezgha-watchdog.timer"
else
  echo "PASS: Case C: --with-watchdog enabled ezgha-watchdog.timer"
fi

if [ ! -f "${STATE_C}/ezgha-token-refresh.timer.enabled" ] || [ ! -f "${STATE_C}/ezgha-queue-reaper.timer.enabled" ]; then
  fail "Case C: --with-watchdog run failed to also enable token-refresh/queue-reaper timers"
else
  echo "PASS: Case C: --with-watchdog run still enabled token-refresh + queue-reaper timers"
fi

# ── Case E: uninstall restores a pre-existing CLI symlink and removes host controls.
HOME_E="${WORK}/home_e"
STATE_E="${WORK}/state_e"
mkdir -p "${HOME_E}/.local/bin" "${STATE_E}"
ln -s "${STUB_BIN}/codex" "${HOME_E}/.local/bin/codex"
run_install "${HOME_E}" "${STATE_E}"
HOME="${HOME_E}" SYSTEMCTL_STATE_DIR="${STATE_E}" \
  bash "${TEMP_REPO}/install.sh" --uninstall >"${HOME_E}/uninstall.log" 2>&1
if [ ! -L "${HOME_E}/.local/bin/codex" ] || [ "$(readlink "${HOME_E}/.local/bin/codex")" != "${STUB_BIN}/codex" ]; then
  fail "Case E: uninstall did not restore the pre-existing codex symlink"
fi
if [ -e "${HOME_E}/.config/systemd/user/agents.slice" ] || \
   [ -e "${HOME_E}/.config/systemd/user/agent-scope-reaper.timer" ]; then
  fail "Case E: uninstall left host-control units behind"
fi
if ! grep -Fqx 'shell colima -- sudo -n rm -f /etc/systemd/system/actions.slice' "${LIMACTL_CAPTURE}"; then
  fail "Case E: uninstall did not remove the persistent guest actions.slice"
fi

# ── Case D: flag composes with --dev (already exercised via run_install,
#            which always passes --dev) -- verify --with-watchdog placed
#            BEFORE --dev also works (order independence) ──────────────────
HOME_D="${WORK}/home_d"
STATE_D="${WORK}/state_d"
mkdir -p "${HOME_D}" "${STATE_D}"
HOME="${HOME_D}" SYSTEMCTL_STATE_DIR="${STATE_D}" \
  bash "${TEMP_REPO}/install.sh" --with-watchdog --dev >"${HOME_D}/install.log" 2>&1
if [ ! -f "${STATE_D}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case D: '--with-watchdog --dev' (flag order swapped) did not enable ezgha-watchdog.timer"
else
  echo "PASS: Case D: flags compose regardless of order"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
