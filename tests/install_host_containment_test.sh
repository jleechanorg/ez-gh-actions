#!/usr/bin/env bash
# Hermetic Linux host-Docker containment ordering test for install.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TEMP_REPO="$WORK/repo"
STUB_BIN="$WORK/bin"
EVENT_LOG="$WORK/events"
mkdir -p "$TEMP_REPO" "$STUB_BIN"

cp "$REPO_ROOT/install.sh" "$REPO_ROOT/Cargo.toml" "$REPO_ROOT/Dockerfile.runner" "$TEMP_REPO/"
cp -a "$REPO_ROOT/systemd" "$REPO_ROOT/scripts" "$TEMP_REPO/"
rm -rf "$TEMP_REPO/docs"

fail() { echo "FAIL: $*" >&2; exit 1; }
line_of() { grep -n -m1 "^$1$" "$EVENT_LOG" | cut -d: -f1; }

if [ "${INSTALL_HOST_CONTAINMENT_LEGACY_TOML:-0}" = 1 ]; then
  if [ -z "${TOML_PACKAGE_ROOT:-}" ]; then
    echo "INSTALL_HOST_CONTAINMENT_LEGACY_TOML_TEST: SKIP (toml package unavailable)"
    exit 0
  fi
  LEGACY_PYTHON="$WORK/legacy-python"
  mkdir -p "$LEGACY_PYTHON"
  cat > "$LEGACY_PYTHON/tomllib.py" <<'EOF'
raise ModuleNotFoundError("fixture disables tomllib")
EOF
  export PYTHONPATH="$LEGACY_PYTHON:$TOML_PACKAGE_ROOT${PYTHONPATH:+:$PYTHONPATH}"
fi

cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -r) echo fixture-host-kernel ;; *) echo Linux ;; esac
EOF
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" context inspect "* ]]; then
  # Docker v29 resolves an explicit DOCKER_HOST before a named context.
  if [ -n "${DOCKER_HOST:-}" ]; then echo "$DOCKER_HOST";
  elif [ "${DOCKER_CONTEXT:-}" = remote-context ]; then echo ssh://fixture-remote;
  elif [ "${DOCKER_CONTEXT:-}" = explicit-context ]; then echo "unix://$HOME/.colima/default/docker.sock";
  else echo unix:///var/run/docker.sock; fi
  exit 0
fi
if [[ "$args" == *" info "* ]]; then
  echo "docker-info:${DOCKER_HOST:-}" >> "$EVENT_LOG"
  if [[ "${DOCKER_HOST:-}" == *"/.colima/default/docker.sock" ]]; then
    echo fixture-vm-kernel
  else
    echo "${FIXTURE_KERNEL:-fixture-host-kernel}"
  fi
  [ "${FIXTURE_PROBE_FAIL:-0}" != 1 ] || exit 1
fi
if [[ "$args" == *" build "* ]]; then echo "docker-build:${DOCKER_HOST:-}" >> "$EVENT_LOG"; fi
exit 0
EOF
cat > "$STUB_BIN/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo-$1" >> "$EVENT_LOG"
if [ "${1:-}" = install ]; then
  mkdir -p "$HOME/.cargo/bin"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = install-service ]; then echo "install-service:${DOCKER_HOST_OVERRIDE:-}" >> "$EVENT_LOG"; fi\nexit 0\n' > "$HOME/.cargo/bin/ezgha"
  chmod +x "$HOME/.cargo/bin/ezgha"
fi
exit 0
EOF
cat > "$STUB_BIN/rustc" <<'EOF'
#!/usr/bin/env bash
echo 'rustc 1.0.0'
EOF
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$STUB_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -n ] && [ "${2:-}" = true ]; then exit 0; fi
[ "${1:-}" = -n ] && shift
exec "$@"
EOF
cat > "$STUB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --user ]; then shift; fi
case "${1:-}" in
  enable)
    if [ "${SYSTEMCTL_REAPPLY_FAIL:-0}" = 1 ] && [[ " $* " == *" lima-vm-cpu-ceiling.service "* ]]; then
      echo reapply-enable-failed >> "$EVENT_LOG"
      exit 1
    fi
    exit 0 ;;
  show)
    if [[ " $* " == *" -p ActiveState "* ]]; then
      echo inactive
    elif [ -n "${SYSTEMCTL_CGROUP_PATH:-}" ] && [[ "$*" == *"lima-vm@colima.service"* ]]; then
      printf '%s\n' "$SYSTEMCTL_CGROUP_PATH"
    fi
    exit 0 ;;
  is-enabled)
    if [ "${2:-}" = agent-scope-reaper.timer ] \
       || [ "${2:-}" = psi-oom-watcher.timer ]; then
      echo disabled
      exit 1
    fi
    exit 0 ;;
  is-active)
    if [ "${2:-}" = agent-scope-reaper.timer ] \
       || [ "${2:-}" = agent-scope-reaper.service ] \
       || [ "${2:-}" = psi-oom-watcher.timer ] \
       || [ "${2:-}" = psi-oom-watcher.service ]; then
      echo inactive
      exit 3
    fi
    [ "${SYSTEMCTL_ACTIVE:-0}" = 1 ] && exit 0 || exit 1 ;;
  daemon-reload)
    echo "systemctl-$1:$*" >> "$EVENT_LOG"
    [ "${FAIL_RELOAD:-0}" != 1 ]; exit $? ;;
  start|set-property|enable)
    echo "systemctl-$1:$*" >> "$EVENT_LOG"
    if [ "${FAIL_SLICE_SET:-0}" = 1 ] && [ "$1" = set-property ] \
       && { [ "${2:-}" = agents.slice ] || [ "${2:-}" = automation.slice ]; }; then
      exit 1
    fi
    if [ "$1" = set-property ] && [ -n "${SYSTEMCTL_OVERRIDE_DIR:-}" ] \
       && { [ "${2:-}" = agents.slice ] || [ "${2:-}" = automation.slice ]; }; then
      mkdir -p "$SYSTEMCTL_OVERRIDE_DIR"
      printf '%s\n' "$*" > "$SYSTEMCTL_OVERRIDE_DIR/$2"
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
# limactl reports VM status (its .memory mirrors lima.yaml, not the running
# guest); the running size comes from the colima QEMU's -m in LIMA_PROC_ROOT.
cat > "$STUB_BIN/limactl" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "list --json colima" ]; then
  printf '{"name":"colima","status":"%s","memory":4294967296,"dir":"%s"}\n' "${LIMA_FIXTURE_STATUS:-Stopped}" "${LIMA_FIXTURE_DIR:-$HOME/.lima/colima}"
  exit 0
fi
exit 1
EOF
for agent in codex claude gemini cursor aider cody; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$agent"
done
chmod +x "$STUB_BIN"/*
# Exercise the staged guest guard with a minimal PATH before the installer
# replay. GUEST_GUARD_ONLY=1 exits after this proof without invoking the
# privilege or service-manager paths in the rest of the fixture.
GUARD_HOME="$WORK/guard-home"
GUARD_PROC="$WORK/guard-proc"
GUARD_PATH="$WORK/guard-path"
GUARD_RUNTIME="$WORK/guard-runtime"
mkdir -p "$GUARD_HOME/.config/systemd/user/lima-vm@colima.service.d" \
  "$GUARD_HOME/.config/systemd/user/lima-vm-cpu-ceiling.service.d" \
  "$GUARD_HOME/.lima/colima" "$WORK/guard-lima-bin" \
  "$GUARD_HOME/.local/libexec/ezgha" "$GUARD_PROC" "$GUARD_PATH" "$GUARD_RUNTIME"
printf 'memory: "8GiB"\n' > "$GUARD_HOME/.lima/colima/lima.yaml"
: > "$GUARD_RUNTIME/fake-bus"
cp "$STUB_BIN/systemctl" "$GUARD_PATH/systemctl"
# Lima outside ~/.local/bin (e.g. /usr/local/bin) must still be admitted.
GUARD_LIMACTL="$WORK/guard-lima-bin/limactl"
cp "$STUB_BIN/limactl" "$GUARD_LIMACTL"
chmod +x "$GUARD_PATH/systemctl" "$GUARD_LIMACTL"
GUARD_MIN_PATH="$GUARD_PATH:/usr/bin:/bin"
if PATH="$GUARD_MIN_PATH" command -v limactl >/dev/null 2>&1; then
  fail "guard-only PATH unexpectedly exposed limactl"
fi
GUEST_DROPIN="$REPO_ROOT/systemd/host-docker/lima-vm@colima.service.d/10-guest-memory-admission.conf"
grep -qx 'Environment=LIMACTL=@LIMACTL@' "$GUEST_DROPIN" \
  || fail "source unit does not leave the limactl path for the installer to bind: $GUEST_DROPIN"
install -m 0755 "$TEMP_REPO/scripts/host/lima-guest-memory-check.sh" \
  "$GUARD_HOME/.local/libexec/ezgha/lima-guest-memory-check.sh"
# Render exactly as install.sh does.
render_line="$(grep -F '@LIMACTL@' "$REPO_ROOT/install.sh" | grep -F 'sed -e')"
[ -n "$render_line" ] || fail "install.sh does not render the limactl placeholder"
for guard_dir in lima-vm@colima.service.d lima-vm-cpu-ceiling.service.d; do
  sed -e "s|@LIMACTL@|${GUARD_LIMACTL}|g" "$GUEST_DROPIN" \
    > "$GUARD_HOME/.config/systemd/user/$guard_dir/10-guest-memory-admission.conf"
done
for staged_unit in \
    "$GUARD_HOME/.config/systemd/user/lima-vm@colima.service.d/10-guest-memory-admission.conf" \
    "$GUARD_HOME/.config/systemd/user/lima-vm-cpu-ceiling.service.d/10-guest-memory-admission.conf"; do
  grep -qx "Environment=LIMACTL=$GUARD_LIMACTL" "$staged_unit" \
    || fail "staged unit does not bind the installer's absolute limactl path: $staged_unit"
  limactl_path="$(sed -n 's/^Environment=LIMACTL=//p' "$staged_unit")"
  unit_name="$(basename "$staged_unit")"
  env -i HOME="$GUARD_HOME" PATH="$GUARD_MIN_PATH" \
    XDG_RUNTIME_DIR="$GUARD_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$GUARD_RUNTIME/fake-bus" \
    EVENT_LOG="$WORK/guard-events" LIMACTL="$limactl_path" \
    LIMA_FIXTURE_STATUS=Stopped LIMA_FIXTURE_DIR="$GUARD_HOME/.lima/colima" \
    LIMA_PROC_ROOT="$GUARD_PROC" \
    bash "$GUARD_HOME/.local/libexec/ezgha/lima-guest-memory-check.sh" \
    > "$WORK/$unit_name-minimal-path.log" 2>&1 \
    || fail "$unit_name guard could not resolve its unit-derived limactl path with minimal PATH"
  grep -q 'OK: lima guest memory <= 8GiB' "$WORK/$unit_name-minimal-path.log" \
    || fail "$unit_name guard did not complete normal admission with the unit-derived limactl path"
done
if env -i HOME="$GUARD_HOME" PATH="$GUARD_MIN_PATH" \
    XDG_RUNTIME_DIR="$GUARD_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$GUARD_RUNTIME/fake-bus" \
    LIMA_FIXTURE_STATUS=Stopped LIMA_FIXTURE_DIR="$GUARD_HOME/.lima/colima" \
    LIMA_PROC_ROOT="$GUARD_PROC" \
    bash "$GUARD_HOME/.local/libexec/ezgha/lima-guest-memory-check.sh" \
    > "$WORK/no-limactl.log" 2>&1; then
  fail "guard accepted normal admission without LIMACTL under minimal PATH"
fi
grep -q 'limactl not found' "$WORK/no-limactl.log" \
  || fail "missing LIMACTL control did not fail at the expected PATH boundary"
echo "INSTALL_HOST_CONTAINMENT_GUEST_GUARD: PASS"
if [ "${GUEST_GUARD_ONLY:-0}" = 1 ]; then
  exit 0
fi

# A context-only remote endpoint must not fall back to the local socket.
if EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" DOCKER_CONTEXT=remote-context \
    "$REPO_ROOT/scripts/host/docker-host-mode.sh" >/dev/null 2>&1; then
  fail "remote context was ignored in favor of the local default socket"
fi
# The Linux verifier resolves the endpoint stored in ezgha.service instead
# of inheriting this shell's remote context. Test the extracted helper with a
# service override and then its native fallback.
(
  export EVENT_LOG PATH="$STUB_BIN:$PATH" DOCKER_CONTEXT=remote-context DOCKER_HOST=ssh://ambient
  systemctl() { printf '%s\n' "DOCKER_HOST_OVERRIDE=unix://$HOME/.colima/default/docker.sock"; }
  eval "$(sed -n '/^service_docker_endpoint() {/,/^}/p' "$REPO_ROOT/docs/verify-exit-criteria.sh")"
  [ "$(service_docker_endpoint)" = "unix://$HOME/.colima/default/docker.sock" ] \
    || fail "verifier did not use persisted service Docker endpoint"
  systemctl() { printf '%s\n' ''; }
  [ "$(service_docker_endpoint)" = unix:///var/run/docker.sock ]     || fail "verifier did not use native Linux fallback"
)
if EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" FIXTURE_PROBE_FAIL=1 \
    "$REPO_ROOT/scripts/host/docker-host-mode.sh" unix:///var/run/docker.sock >/dev/null 2>&1; then
  fail "failed kernel probe with matching stdout was accepted"
fi
if EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" FIXTURE_KERNEL=other-kernel \
    "$REPO_ROOT/scripts/host/docker-host-mode.sh" unix:///var/run/docker.sock >/dev/null 2>&1; then
  fail "canonical endpoint with mismatched kernel was accepted as owned"
fi

# The installer must invoke the staged scripts. These fixtures record the
# privilege phase and avoid all host systemd/file mutation.
cat > "$TEMP_REPO/scripts/host/apply-host-containment-release1.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --system-phase ]; then
  echo "root-phase:$*" >> "$EVENT_LOG"
  [ "${APPLY_FAIL_ROOT:-0}" = 1 ] && exit 1
else
  echo "user-phase:$*" >> "$EVENT_LOG"
  [ "${APPLY_FAIL_USER:-0}" = 1 ] && exit 1
fi
exit 0
EOF
cat > "$TEMP_REPO/scripts/host/assert-host-containment-release1.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEMP_REPO/scripts/host/"*containment-release1.sh

HOME_DIR="$WORK/home"
HOST_OVERRIDE_DIR="$WORK/host-overrides"
mkdir -p "$HOME_DIR/.config/ezgha" "$HOME_DIR/.config/systemd/user" "$HOME_DIR/.lima/colima" "$HOST_OVERRIDE_DIR"
printf '[runner]\ncount = 14\n' > "$HOME_DIR/.config/ezgha/config.toml"
printf 'cpus: 4\nmemory: "8GiB"\n' > "$HOME_DIR/.lima/colima/lima.yaml"
printf 'set-property agents.slice MemoryHigh=18G MemoryMax=20G MemorySwapMax=2G TasksMax=8192\n' > "$HOST_OVERRIDE_DIR/agents.slice"
printf 'set-property automation.slice MemoryHigh=8G MemoryMax=10G MemorySwapMax=1G TasksMax=4096\n' > "$HOST_OVERRIDE_DIR/automation.slice"
EVENT_LOG="$EVENT_LOG" SYSTEMCTL_OVERRIDE_DIR="$HOST_OVERRIDE_DIR" PATH="$STUB_BIN:$PATH" HOME="$HOME_DIR" CARGO_HOME="$HOME_DIR/.cargo" XDG_CONFIG_HOME="$HOME_DIR/.config" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/install.log" 2>&1 || fail "host-Docker fixture install failed"

[ -f "$HOME_DIR/.local/libexec/ezgha/host-containment-policy/systemd/host/actions.slice" ] \
  || fail "installed containment policy subtree is incomplete"
assert_host_policy_slice() {
  local unit="$1" high="$2" max="$3" file
  file="$HOME_DIR/.local/libexec/ezgha/host-containment-policy/systemd/$unit"
  grep -qx "MemoryHigh=$high" "$file" && grep -qx "MemoryMax=$max" "$file" \
    || fail "staged policy does not contain the tracked $high/$max budget for $unit"
}
assert_host_policy_slice agents.slice 10G 12G
assert_host_policy_slice automation.slice 4608M 5G
assert_installed_slice() {
  local home="$1" unit="$2" high="$3" max="$4" file
  file="$home/.config/systemd/user/$unit"
  grep -qx "MemoryHigh=$high" "$file" && grep -qx "MemoryMax=$max" "$file" \
    || fail "installed $unit does not contain the selected $high/$max policy"
}
assert_installed_slice "$HOME_DIR" agents.slice 10G 12G
assert_installed_slice "$HOME_DIR" automation.slice 4608M 5G
assert_persisted_slice() {
  local dir="$1" unit="$2" high="$3" max="$4" swap="$5" tasks="$6"
  grep -Fqx "set-property $unit MemoryHigh=$high MemoryMax=$max MemorySwapMax=$swap TasksMax=$tasks" \
    "$dir/$unit" || fail "persisted $unit override did not match the selected budget"
}
assert_persisted_slice "$HOST_OVERRIDE_DIR" agents.slice 10G 12G 2G 8192
assert_persisted_slice "$HOST_OVERRIDE_DIR" automation.slice 4608M 5G 1G 4096
for policy in app-lima-vm.slice lima-vm@colima.service.d/99-memory-ceiling.conf lima-vm-cpu-ceiling.service; do
  cmp "$REPO_ROOT/systemd/$policy" "$HOME_DIR/.local/libexec/ezgha/host-containment-policy/systemd/$policy" || fail "missing or stale installed $policy"
done
cmp "$REPO_ROOT/scripts/host/qemu-ceiling-guard.sh" "$HOME_DIR/.local/libexec/ezgha/qemu-ceiling-guard.sh" || fail "missing installed QEMU guard"
root_line="$(line_of "root-phase:--system-phase --runner-count 14")"; user_line="$(line_of "user-phase:--runner-count 14")"; install_line="$(line_of cargo-install)"; build_line="$(grep -n -m1 '^docker-build:' "$EVENT_LOG" | cut -d: -f1)"
[ -n "$root_line" ] && [ -n "$user_line" ] && [ -n "$install_line" ] && [ -n "$build_line" ] || fail "missing containment or install event"
[ "$root_line" -lt "$user_line" ] && [ "$user_line" -lt "$install_line" ] && [ "$install_line" -lt "$build_line" ] \
  || fail "root/user containment did not precede binary replacement and image build"
grep -qx "systemctl-set-property:set-property agents.slice MemoryHigh=10G MemoryMax=12G MemorySwapMax=2G TasksMax=8192" "$EVENT_LOG" \
  || fail "host-docker install did not reapply the selected agents.slice live budget"
grep -qx "systemctl-set-property:set-property automation.slice MemoryHigh=4608M MemoryMax=5G MemorySwapMax=1G TasksMax=4096" "$EVENT_LOG" \
  || fail "host-docker install did not reapply the selected automation.slice live budget"
final_reload_line="$(grep -n '^systemctl-daemon-reload:daemon-reload$' "$EVENT_LOG" | tail -1 | cut -d: -f1)"
final_agents_line="$(grep -n '^systemctl-set-property:set-property agents.slice ' "$EVENT_LOG" | tail -1 | cut -d: -f1)"
[ -n "$final_reload_line" ] && [ -n "$final_agents_line" ] && [ "$final_reload_line" -lt "$final_agents_line" ] \
  || fail "host-docker slice budgets were applied before the final user-unit reload"

# Host-docker mode (bead ez-gh-actions-154k): the colima guest (qdrant only)
# is resized to 8GiB in the lima.yaml lima-vm@colima starts from, and the
# QEMU ceiling surfaces preserve the deployed 9G/10G policy.
grep -qx 'memory: "8GiB"' "$HOME_DIR/.lima/colima/lima.yaml" \
  || fail "host-docker install did not set the Lima guest to 8GiB: $(cat "$HOME_DIR/.lima/colima/lima.yaml")"
HD_UNITS="$HOME_DIR/.config/systemd/user"
for f in app-lima-vm.slice lima-vm@colima.service.d/99-memory-ceiling.conf; do
  grep -qx 'MemoryHigh=9G' "$HD_UNITS/$f" && grep -qx 'MemoryMax=10G' "$HD_UNITS/$f" \
    || fail "host-docker install did not deploy the 9G/10G $f"
done
grep -qx "ExecStart=$HOME_DIR/.local/libexec/ezgha/qemu-ceiling-guard.sh --apply" "$HD_UNITS/lima-vm-cpu-ceiling.service" \
  || fail "host-docker install deployed a lima-vm-cpu-ceiling.service that does not use the shared QEMU guard"
for unit in lima-vm@colima lima-vm-cpu-ceiling; do
  grep -qx 'ExecStartPre=%h/.local/libexec/ezgha/lima-guest-memory-check.sh' \
    "$HD_UNITS/$unit.service.d/10-guest-memory-admission.conf" \
    || fail "host-docker install did not stage $unit guest admission before start"
  grep -qx "Environment=LIMACTL=$STUB_BIN/limactl" "$HD_UNITS/$unit.service.d/10-guest-memory-admission.conf" \
    || fail "host-docker install did not bind $unit guest admission to the limactl it resolved"
done

# A guest still running at 12 GiB keeps the existing QEMU ceiling (fail closed)
# even though this same install run rewrote lima.yaml to 8GiB.
BIG_HOME="$WORK/big_guest_home"
mkdir -p "$BIG_HOME/.config/ezgha" "$BIG_HOME/.config/systemd/user/lima-vm@colima.service.d" "$BIG_HOME/.lima/colima"
printf '[runner]\ncount = 14\n' > "$BIG_HOME/.config/ezgha/config.toml"
printf 'cpus: 4\nmemory: "12GiB"\n' > "$BIG_HOME/.lima/colima/lima.yaml"
BIG_PROC="$WORK/big_proc"
BIG_CGROUP="$WORK/big_cgroup"
mkdir -p "$BIG_PROC/7777" "$BIG_CGROUP/lima-vm@colima.service"
printf 'qemu-system-x86\n' > "$BIG_PROC/7777/comm"
printf '%s\0' qemu-system-x86_64 -m 12288 -drive "file=$BIG_HOME/.lima/colima/diffdisk,if=virtio" > "$BIG_PROC/7777/cmdline"
printf '0::/lima-vm@colima.service\n' > "$BIG_PROC/7777/cgroup"
printf '7777\n' > "$BIG_CGROUP/lima-vm@colima.service/cgroup.procs"
printf '[Service]\nMemoryHigh=9G\nMemoryMax=10G\n' > "$BIG_HOME/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf"
cp "$REPO_ROOT/systemd/lima-vm-cpu-ceiling.service" "$BIG_HOME/.config/systemd/user/lima-vm-cpu-ceiling.service"
cp "$BIG_HOME/.config/systemd/user/lima-vm-cpu-ceiling.service" "$WORK/reapply-before"
cp "$BIG_HOME/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" "$WORK/cap-before"
# Use the real apply helper with an isolated root: early admission must stop
# before either phase, without relying on a stubbed apply result.
cp "$TEMP_REPO/scripts/host/apply-host-containment-release1.sh" "$WORK/apply-fixture"
cp "$REPO_ROOT/scripts/host/apply-host-containment-release1.sh" "$TEMP_REPO/scripts/host/"
sed -i "s|^ROOT=\"/\"$|ROOT=\"$WORK/isolated-apply\"|" "$TEMP_REPO/scripts/host/apply-host-containment-release1.sh"
if env EVENT_LOG="$WORK/big_events" PATH="$STUB_BIN:$PATH" HOME="$BIG_HOME" CARGO_HOME="$BIG_HOME/.cargo" XDG_CONFIG_HOME="$BIG_HOME/.config" \
  LIMA_FIXTURE_STATUS=Running LIMA_PROC_ROOT="$BIG_PROC" QEMU_CGROUP_ROOT="$BIG_CGROUP" \
  SYSTEMCTL_CGROUP_PATH=/lima-vm@colima.service \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/big-install.log" 2>&1; then
  fail "big-guest install passed despite pre-activation guest refusal"
fi
grep -qx 'MemoryMax=10G' "$BIG_HOME/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  || fail "failed guest check replaced the existing host-docker QEMU ceiling"
grep -q 'FAIL lima guest memory 12884901888 > 8GiB' "$WORK/big-install.log" \
  || fail "big-guest install did not report the Lima guest refusal"
grep -qx 'memory: "8GiB"' "$BIG_HOME/.lima/colima/lima.yaml" || fail "big-guest install did not resize lima.yaml"
if grep -Eq '^systemctl-(set-property|enable):.*lima-vm@colima\.service|^systemctl-enable:.*lima-vm-cpu-ceiling\.service' "$WORK/big_events" 2>/dev/null; then
  fail "failed guest check applied or enabled the stale host-docker ceiling: $(cat "$WORK/big_events")"
fi

[ ! -e "$WORK/isolated-apply/etc/systemd/system/actions.slice" ] \
  || fail "unsafe guest reached the real root apply phase"
cp "$WORK/apply-fixture" "$TEMP_REPO/scripts/host/apply-host-containment-release1.sh"
cmp "$WORK/reapply-before" "$BIG_HOME/.config/systemd/user/lima-vm-cpu-ceiling.service" \
  || fail "unsafe guest changed the existing reapply unit"
cmp "$WORK/cap-before" "$BIG_HOME/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  || fail "unsafe guest changed existing cap bytes"
for unit in lima-vm@colima lima-vm-cpu-ceiling; do
  grep -qx 'ExecStartPre=%h/.local/libexec/ezgha/lima-guest-memory-check.sh' \
    "$BIG_HOME/.config/systemd/user/$unit.service.d/10-guest-memory-admission.conf" \
    || fail "unsafe guest left $unit without a next-start guard"
done
if grep -Eq '^root-phase$|^user-phase$|^cargo-install$' "$WORK/big_events"; then
  fail "unsafe guest reached a containment apply phase or installed the binary"
fi
RELOAD_HOME="$WORK/reload_home"
mkdir -p "$RELOAD_HOME/.config/ezgha" "$RELOAD_HOME/.lima/colima"
printf 'memory: "8GiB"\n' > "$RELOAD_HOME/.lima/colima/lima.yaml"
printf '[runner]\ncount = 14\n' > "$RELOAD_HOME/.config/ezgha/config.toml"
if env EVENT_LOG="$WORK/reload_events" PATH="$STUB_BIN:$PATH" HOME="$RELOAD_HOME" \
    CARGO_HOME="$RELOAD_HOME/.cargo" XDG_CONFIG_HOME="$RELOAD_HOME/.config" FAIL_RELOAD=1 \
    bash "$TEMP_REPO/install.sh" --dev > "$WORK/reload.log" 2>&1; then
  fail "failed guard reload allowed installation"
fi
grep -q 'could not load guest admission guards' "$WORK/reload.log" \
  || fail "guard reload failure was not reported"
if grep -Eq '^root-phase$|^user-phase$|^cargo-install$' "$WORK/reload_events"; then
  fail "failed guard reload reached a mutation phase"
fi

# A lima.yaml without a memory: line gets one (sed alone would change nothing).
NOMEM_HOME="$WORK/nomem_home"
mkdir -p "$NOMEM_HOME/.config/ezgha" "$NOMEM_HOME/.lima/colima"
printf '[runner]\ncount = 14\n' > "$NOMEM_HOME/.config/ezgha/config.toml"
printf 'cpus: 4\n' > "$NOMEM_HOME/.lima/colima/lima.yaml"
env EVENT_LOG="$WORK/nomem_events" PATH="$STUB_BIN:$PATH" HOME="$NOMEM_HOME" CARGO_HOME="$NOMEM_HOME/.cargo" XDG_CONFIG_HOME="$NOMEM_HOME/.config" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/nomem-install.log" 2>&1 || fail "no-memory-line fixture install failed"
grep -qx 'memory: "8GiB"' "$NOMEM_HOME/.lima/colima/lima.yaml" \
  || fail "lima.yaml without memory: was not set to 8GiB: $(cat "$NOMEM_HOME/.lima/colima/lima.yaml")"

ROLLBACK_HOME="$WORK/rollback_home"
ROLLBACK_LOG="$WORK/rollback_events"
mkdir -p "$ROLLBACK_HOME/.config/ezgha" "$ROLLBACK_HOME/.lima/colima"
printf 'memory: "8GiB"\n' > "$ROLLBACK_HOME/.lima/colima/lima.yaml"
printf '[runner]\ncount = 10\n' > "$ROLLBACK_HOME/.config/ezgha/config.toml"
env EVENT_LOG="$ROLLBACK_LOG" PATH="$STUB_BIN:$PATH" HOME="$ROLLBACK_HOME" CARGO_HOME="$ROLLBACK_HOME/.cargo" XDG_CONFIG_HOME="$ROLLBACK_HOME/.config" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/rollback-install.log" 2>&1 \
  || fail "10-runner rollback fixture install failed"
grep -qx 'root-phase:--system-phase --runner-count 10' "$ROLLBACK_LOG" \
  || fail "10-runner rollback root phase did not receive --runner-count 10"
grep -qx 'user-phase:--runner-count 10' "$ROLLBACK_LOG" \
  || fail "10-runner rollback user phase did not receive --runner-count 10"

INVALID_HOME="$WORK/invalid_count_home"
INVALID_LOG="$WORK/invalid_count_events"
mkdir -p "$INVALID_HOME/.config/ezgha"
printf '[runner]\ncount = 12\n' > "$INVALID_HOME/.config/ezgha/config.toml"
if env EVENT_LOG="$INVALID_LOG" PATH="$STUB_BIN:$PATH" HOME="$INVALID_HOME" CARGO_HOME="$INVALID_HOME/.cargo" XDG_CONFIG_HOME="$INVALID_HOME/.config" \
    bash "$TEMP_REPO/install.sh" --dev > "$WORK/invalid-count-install.log" 2>&1; then
  fail "installer accepted unsupported runner.count=12"
fi
if grep -qE '^(root|user)-phase:' "$INVALID_LOG" 2>/dev/null; then
  fail "invalid runner.count wrote containment phases"
fi

run_failed_phase() {
  local phase="$1"
  local home="$WORK/${phase}_home"
  local log="$WORK/${phase}_events"
  mkdir -p "$home/.config/ezgha"
  printf '[runner]\ncount = 14\n' > "$home/.config/ezgha/config.toml"
  if env EVENT_LOG="$log" PATH="$STUB_BIN:$PATH" HOME="$home" CARGO_HOME="$home/.cargo" XDG_CONFIG_HOME="$home/.config" "APPLY_FAIL_${phase^^}=1" \
      bash "$TEMP_REPO/install.sh" --dev > "$WORK/${phase}.log" 2>&1; then
    fail "${phase} phase failure still allowed installation"
  fi
  if grep -q '^cargo-install$' "$log" 2>/dev/null; then
    fail "${phase} phase failure replaced the binary"
  fi
}
run_failed_phase root
run_failed_phase user

SLICE_FAIL_HOME="$WORK/slice_fail_home"
mkdir -p "$SLICE_FAIL_HOME/.config/ezgha" "$SLICE_FAIL_HOME/.lima/colima"
printf '[runner]\ncount = 14\n' > "$SLICE_FAIL_HOME/.config/ezgha/config.toml"
printf 'memory: "8GiB"\n' > "$SLICE_FAIL_HOME/.lima/colima/lima.yaml"
if env EVENT_LOG="$WORK/slice_fail_events" PATH="$STUB_BIN:$PATH" \
    HOME="$SLICE_FAIL_HOME" CARGO_HOME="$SLICE_FAIL_HOME/.cargo" \
    XDG_CONFIG_HOME="$SLICE_FAIL_HOME/.config" FAIL_SLICE_SET=1 \
    bash "$TEMP_REPO/install.sh" --dev > "$WORK/slice-fail.log" 2>&1; then
  fail "slice set-property failure still allowed installation"
fi
grep -q 'could not apply selected agents.slice budget' "$WORK/slice-fail.log" \
  || fail "slice set-property failure was not reported"
# The binary install precedes user-unit rendering; the setter failure must
# still abort the installer instead of silently accepting stale live limits.

# An explicitly selected VM daemon must be used consistently for reachability,
# kernel classification, and image build. Its guest kernel differs from the
# host, so host-Docker containment is intentionally not activated.
VM_EVENT_LOG="$WORK/vm_events"
VM_HOME="$WORK/vm_home"
mkdir -p "$VM_HOME/.config/ezgha"
printf '[runner]\ncount = 12\n' > "$VM_HOME/.config/ezgha/config.toml"
env EVENT_LOG="$VM_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$VM_HOME" CARGO_HOME="$VM_HOME/.cargo" XDG_CONFIG_HOME="$VM_HOME/.config" \
  DOCKER_HOST="unix://$VM_HOME/.colima/default/docker.sock" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/vm-install.log" 2>&1 \
  || fail "explicit VM endpoint fixture install failed"
grep -qx "docker-info:unix://$VM_HOME/.colima/default/docker.sock" "$VM_EVENT_LOG" \
  || fail "installer did not probe the explicitly selected VM endpoint"
grep -qx "docker-build:unix://$VM_HOME/.colima/default/docker.sock" "$VM_EVENT_LOG" \
  || fail "installer did not build on the explicitly selected VM endpoint"
if grep -qE '^(root|user)-phase:' "$VM_EVENT_LOG"; then
  fail "VM endpoint was misclassified as native HostDocker"
fi
# VM-backed mode installs the same tracked 9G/10G QEMU ceiling.
grep -qx 'MemoryMax=10G' "$VM_HOME/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  || fail "VM-backed install did not deploy the tracked 9G/10G QEMU ceiling"

# A host-docker installation leaves next-start guards for its 8GiB guest.
# Returning to VM-backed Docker must remove only those guards before cargo
# installation, even if the legacy guest configuration remains larger.
MIGRATE_HOME="$WORK/migrate_home"
MIGRATE_EVENTS="$WORK/migrate_events"
MIGRATE_OVERRIDES="$WORK/migrate-overrides"
mkdir -p "$MIGRATE_HOME/.config/ezgha" "$MIGRATE_HOME/.lima/colima" "$MIGRATE_OVERRIDES"
printf '[runner]\ncount = 14\n' > "$MIGRATE_HOME/.config/ezgha/config.toml"
printf 'memory: "8GiB"\n' > "$MIGRATE_HOME/.lima/colima/lima.yaml"
printf 'set-property agents.slice MemoryHigh=18G MemoryMax=20G MemorySwapMax=2G TasksMax=8192\n' > "$MIGRATE_OVERRIDES/agents.slice"
printf 'set-property automation.slice MemoryHigh=8G MemoryMax=10G MemorySwapMax=1G TasksMax=4096\n' > "$MIGRATE_OVERRIDES/automation.slice"
env EVENT_LOG="$MIGRATE_EVENTS" SYSTEMCTL_OVERRIDE_DIR="$MIGRATE_OVERRIDES" PATH="$STUB_BIN:$PATH" HOME="$MIGRATE_HOME" CARGO_HOME="$MIGRATE_HOME/.cargo" XDG_CONFIG_HOME="$MIGRATE_HOME/.config" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/migrate-host-docker.log" 2>&1 \
  || fail "host-docker migration setup install failed"
grep -Fqx "set-property agents.slice MemoryHigh=10G MemoryMax=12G MemorySwapMax=2G TasksMax=8192" "$MIGRATE_OVERRIDES/agents.slice" \
  || fail "host-docker migration setup did not overwrite the stale agents.slice user.control override"
grep -Fqx "set-property automation.slice MemoryHigh=4608M MemoryMax=5G MemorySwapMax=1G TasksMax=4096" "$MIGRATE_OVERRIDES/automation.slice" \
  || fail "host-docker migration setup did not overwrite the stale automation.slice user.control override"
for unit in lima-vm@colima lima-vm-cpu-ceiling; do
  guard="$MIGRATE_HOME/.config/systemd/user/$unit.service.d/10-guest-memory-admission.conf"
  [ -f "$guard" ] || fail "host-docker setup omitted $unit admission guard"
  printf '# preserve this unrelated drop-in\n' > "$(dirname "$guard")/99-unrelated.conf"
done
# This legacy guest is intentionally too large for the host-docker admission
# rule. VM-backed mode must not retain that rule.
printf 'memory: "12GiB"\n' > "$MIGRATE_HOME/.lima/colima/lima.yaml"
: > "$MIGRATE_EVENTS"
# Reintroduce stale user.control overrides; the VM-backed install must replace them too.
printf 'set-property agents.slice MemoryHigh=18G MemoryMax=20G MemorySwapMax=2G TasksMax=8192\n' > "$MIGRATE_OVERRIDES/agents.slice"
printf 'set-property automation.slice MemoryHigh=8G MemoryMax=10G MemorySwapMax=1G TasksMax=4096\n' > "$MIGRATE_OVERRIDES/automation.slice"
env EVENT_LOG="$MIGRATE_EVENTS" SYSTEMCTL_OVERRIDE_DIR="$MIGRATE_OVERRIDES" PATH="$STUB_BIN:$PATH" HOME="$MIGRATE_HOME" CARGO_HOME="$MIGRATE_HOME/.cargo" XDG_CONFIG_HOME="$MIGRATE_HOME/.config" \
  DOCKER_HOST="unix://$MIGRATE_HOME/.colima/default/docker.sock" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/migrate-vm-backed.log" 2>&1 \
  || fail "VM-backed migration install failed with a legacy large guest"
for unit in lima-vm@colima lima-vm-cpu-ceiling; do
  guard="$MIGRATE_HOME/.config/systemd/user/$unit.service.d/10-guest-memory-admission.conf"
  [ ! -e "$guard" ] || fail "VM-backed migration retained $unit host-docker admission guard"
  [ -f "$(dirname "$guard")/99-unrelated.conf" ] \
    || fail "VM-backed migration removed an unrelated $unit drop-in"
done
grep -qx 'MemoryMax=10G' "$MIGRATE_HOME/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  || fail "VM-backed migration did not install the tracked 9G/10G QEMU policy"
grep -Fqx "set-property agents.slice MemoryHigh=10G MemoryMax=12G MemorySwapMax=2G TasksMax=8192" "$MIGRATE_OVERRIDES/agents.slice" \
  || fail "VM-backed migration did not overwrite the stale agents.slice user.control override"
grep -Fqx "set-property automation.slice MemoryHigh=4608M MemoryMax=5G MemorySwapMax=1G TasksMax=4096" "$MIGRATE_OVERRIDES/automation.slice" \
  || fail "VM-backed migration did not overwrite the stale automation.slice user.control override"
grep -qx "systemctl-set-property:set-property agents.slice MemoryHigh=10G MemoryMax=12G MemorySwapMax=2G TasksMax=8192" "$MIGRATE_EVENTS" \
  || fail "VM-backed migration did not reapply the tracked agents.slice live budget"
grep -qx "systemctl-set-property:set-property automation.slice MemoryHigh=4608M MemoryMax=5G MemorySwapMax=1G TasksMax=4096" "$MIGRATE_EVENTS" \
  || fail "VM-backed migration did not reapply the tracked automation.slice live budget"
migrate_final_reload_line="$(grep -n '^systemctl-daemon-reload:daemon-reload$' "$MIGRATE_EVENTS" | tail -1 | cut -d: -f1)"
migrate_final_agents_line="$(grep -n '^systemctl-set-property:set-property agents.slice ' "$MIGRATE_EVENTS" | tail -1 | cut -d: -f1)"
[ -n "$migrate_final_reload_line" ] && [ -n "$migrate_final_agents_line" ] && [ "$migrate_final_reload_line" -lt "$migrate_final_agents_line" ] \
  || fail "VM-backed migration slice budgets were applied before the final user-unit reload"
assert_installed_slice "$MIGRATE_HOME" agents.slice 10G 12G
assert_installed_slice "$MIGRATE_HOME" automation.slice 4608M 5G
migrate_reload_line="$(line_of 'systemctl-daemon-reload:daemon-reload')"
migrate_install_line="$(line_of cargo-install)"
[ -n "$migrate_reload_line" ] && [ -n "$migrate_install_line" ] && [ "$migrate_reload_line" -lt "$migrate_install_line" ] \
  || fail "VM-backed migration did not reload systemd after guard cleanup before installation"

run_invalid_config() {
  local name="$1" contents="$2"
  local home="$WORK/${name}_home" log="$WORK/${name}_events"
  mkdir -p "$home/.config/ezgha"
  printf '%s' "$contents" > "$home/.config/ezgha/config.toml"
  if env EVENT_LOG="$log" PATH="$STUB_BIN:$PATH" HOME="$home" CARGO_HOME="$home/.cargo" XDG_CONFIG_HOME="$home/.config" \
      bash "$TEMP_REPO/install.sh" --dev > "$WORK/${name}.log" 2>&1; then
    fail "installer accepted present invalid config ${name}"
  fi
  if grep -qE '^(root|user)-phase:' "$log" 2>/dev/null; then
    fail "present invalid config ${name} wrote containment phases"
  fi
}
run_invalid_config malformed $'runner = [\n'
run_invalid_config missing_count $'[runner]\n'

# Docker v29 resolves DOCKER_HOST before DOCKER_CONTEXT. The active-service
# upgrade must persist the CLI-selected host endpoint, not the named context.
CONTEXT_EVENT_LOG="$WORK/context_events"
CONTEXT_HOME="$WORK/context_home"
mkdir -p "$CONTEXT_HOME/.config/ezgha" "$CONTEXT_HOME/.lima/colima"
printf '[runner]\ncount = 14\n' > "$CONTEXT_HOME/.config/ezgha/config.toml"
printf 'memory: "8GiB"\n' > "$CONTEXT_HOME/.lima/colima/lima.yaml"
env EVENT_LOG="$CONTEXT_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$CONTEXT_HOME" CARGO_HOME="$CONTEXT_HOME/.cargo" XDG_CONFIG_HOME="$CONTEXT_HOME/.config" \
  SYSTEMCTL_ACTIVE=1 DOCKER_CONTEXT='explicit-context' DOCKER_HOST='unix:///run/docker.sock' \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/context-install.log" 2>&1 \
  || fail "named Docker context fixture install failed"
grep -qx "docker-info:unix:///run/docker.sock" "$CONTEXT_EVENT_LOG" \
  || fail "DOCKER_HOST did not override DOCKER_CONTEXT during endpoint discovery"
grep -qx "docker-build:unix:///run/docker.sock" "$CONTEXT_EVENT_LOG" \
  || fail "image build did not use the CLI-selected host endpoint"
if ! grep -qx "install-service:unix:///run/docker.sock" "$CONTEXT_EVENT_LOG"; then
  echo "context fixture install log:" >&2
  sed -n '1,120p' "$WORK/context-install.log" >&2 || true
  echo "context fixture events:" >&2
  cat "$CONTEXT_EVENT_LOG" >&2 || true
  fail "active systemd service refresh did not persist the selected endpoint"
fi
# A matching kernel is insufficient for a remote or arbitrary Unix endpoint.
if PATH="$STUB_BIN:$PATH" "$REPO_ROOT/scripts/host/docker-host-mode.sh" ssh://fixture-remote >/dev/null 2>&1; then
  fail "same-kernel remote endpoint was accepted"
fi
if PATH="$STUB_BIN:$PATH" "$REPO_ROOT/scripts/host/docker-host-mode.sh" unix:///fixture/relay.sock >/dev/null 2>&1; then
  fail "arbitrary Unix endpoint was accepted"
fi
[ "$(PATH="$STUB_BIN:$PATH" "$REPO_ROOT/scripts/host/docker-host-mode.sh" unix:///var/run/docker.sock)" = host-docker ] \
  || fail "canonical native endpoint was not classified as host Docker"
REAPPLY_HOME="$WORK/reapply_home"
REAPPLY_LOG="$WORK/reapply_events"
mkdir -p "$REAPPLY_HOME/.config/ezgha" "$REAPPLY_HOME/.lima/colima"
printf 'memory: "8GiB"\n' > "$REAPPLY_HOME/.lima/colima/lima.yaml"
printf '[runner]\ncount = 14\n' > "$REAPPLY_HOME/.config/ezgha/config.toml"
if env EVENT_LOG="$REAPPLY_LOG" PATH="$STUB_BIN:$PATH" HOME="$REAPPLY_HOME" CARGO_HOME="$REAPPLY_HOME/.cargo" XDG_CONFIG_HOME="$REAPPLY_HOME/.config" \
    SYSTEMCTL_REAPPLY_FAIL=1 bash "$TEMP_REPO/install.sh" --dev > "$WORK/reapply-install.log" 2>&1; then
  fail "failed required QEMU reapply service enable allowed successful installation"
fi
grep -qx reapply-enable-failed "$REAPPLY_LOG" || fail "fixture missed reapply enable failure"
grep -q 'lima-vm-cpu-ceiling.service not enabled' "$WORK/reapply-install.log" || fail "required reapply failure was not reported"

if [ "${INSTALL_HOST_CONTAINMENT_LEGACY_TOML:-0}" = 1 ]; then
  echo "INSTALL_HOST_CONTAINMENT_LEGACY_TOML_TEST: PASS"
else
  echo "INSTALL_HOST_CONTAINMENT_NORMAL_TOMLLIB_TEST: PASS"
  TOML_PACKAGE_ROOT="$(python3 -c 'import pathlib, toml; print(pathlib.Path(toml.__file__).resolve().parent.parent)' 2>/dev/null || true)"
  if [ -n "$TOML_PACKAGE_ROOT" ]; then
    if TOML_PACKAGE_ROOT="$TOML_PACKAGE_ROOT" INSTALL_HOST_CONTAINMENT_LEGACY_TOML=1 \
        bash "$REPO_ROOT/tests/install_host_containment_test.sh" > "$WORK/legacy-toml.log" 2>&1; then
      cat "$WORK/legacy-toml.log"
    else
      cat "$WORK/legacy-toml.log" >&2
      fail "legacy TOML fallback fixture failed"
    fi
  else
    echo "INSTALL_HOST_CONTAINMENT_LEGACY_TOML_TEST: SKIP (toml package unavailable)"
  fi
fi
