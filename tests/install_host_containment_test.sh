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

cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -r) echo fixture-host-kernel ;; *) echo Linux ;; esac
EOF
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" context inspect explicit-context "* ]]; then
  echo "unix://$HOME/.colima/default/docker.sock"
  exit 0
fi
if [[ "$args" == *" context inspect remote-context "* ]]; then
  echo ssh://fixture-remote
  exit 0
fi
if [[ "$args" == *" context inspect "* ]]; then
  echo unix:///var/run/docker.sock
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
  start|set-property|enable) echo "systemctl-$1:$*" >> "$EVENT_LOG"; exit 0 ;;
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
# Named contexts take precedence over a reachable local Docker socket.
if EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" DOCKER_CONTEXT=remote-context \
    "$REPO_ROOT/scripts/host/docker-host-mode.sh" >/dev/null 2>&1; then
  fail "remote context was ignored in favor of the local default socket"
fi
if env -u QEMU_CEILING_MODE EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" \
    DOCKER_CONTEXT=remote-context bash "$REPO_ROOT/scripts/host/assert-qemu-cpu-ceiling.sh" >/dev/null 2>&1; then
  fail "QEMU assertion ignored the selected remote context"
fi
(
  export EVENT_LOG PATH="$STUB_BIN:$PATH" DOCKER_CONTEXT=remote-context
  fail() { echo "$*" >&2; exit 1; }
  eval "$(sed -n '/^DOCKER_HOST=.*--print-endpoint/,/^$/p' "$REPO_ROOT/docs/verify-exit-criteria.sh")"
) > "$WORK/remote-verifier.log" 2>&1 && fail "verifier selected the local socket for a remote context"
grep -q 'Docker endpoint ownership is unknown' "$WORK/remote-verifier.log" \
  || fail "verifier did not reject the actual selected remote endpoint"
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
  echo root-phase >> "$EVENT_LOG"
  [ "${APPLY_FAIL_ROOT:-0}" = 1 ] && exit 1
else
  echo user-phase >> "$EVENT_LOG"
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
mkdir -p "$HOME_DIR/.config/ezgha" "$HOME_DIR/.config/systemd/user" "$HOME_DIR/.lima/colima"
printf '# fixture\n' > "$HOME_DIR/.config/ezgha/config.toml"
printf 'cpus: 4\nmemory: "8GiB"\n' > "$HOME_DIR/.lima/colima/lima.yaml"
EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$HOME_DIR" CARGO_HOME="$HOME_DIR/.cargo" XDG_CONFIG_HOME="$HOME_DIR/.config" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/install.log" 2>&1 || fail "host-Docker fixture install failed"

[ -f "$HOME_DIR/.local/libexec/ezgha/host-containment-policy/systemd/host/actions.slice" ] \
  || fail "installed containment policy subtree is incomplete"
root_line="$(line_of root-phase)"; user_line="$(line_of user-phase)"; install_line="$(line_of cargo-install)"; build_line="$(grep -n -m1 '^docker-build:' "$EVENT_LOG" | cut -d: -f1)"
[ -n "$root_line" ] && [ -n "$user_line" ] && [ -n "$install_line" ] && [ -n "$build_line" ] || fail "missing containment or install event"
[ "$root_line" -lt "$user_line" ] && [ "$user_line" -lt "$install_line" ] && [ "$install_line" -lt "$build_line" ] \
  || fail "root/user containment did not precede binary replacement and image build"

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
grep -q 'MemoryHigh=9G MemoryMax=10G' "$HD_UNITS/lima-vm-cpu-ceiling.service" \
  || fail "host-docker install deployed a lima-vm-cpu-ceiling.service that re-applies the wrong 9G/10G ceiling"
grep -qx 'ExecStartPre=%h/.local/libexec/ezgha/lima-guest-memory-check.sh' \
  "$HD_UNITS/lima-vm@colima.service.d/10-guest-memory-admission.conf" \
  || fail "host-docker install did not stage the guard-only next-start admission"
grep -qx 'ExecStart=%h/.local/libexec/ezgha/lima-guest-memory-check.sh' \
  "$HD_UNITS/lima-vm-cpu-ceiling.service" \
  || fail "host-docker reapply unit does not run guest admission first"

# A guest still running at 12 GiB keeps the existing QEMU ceiling (fail closed)
# even though this same install run rewrote lima.yaml to 8GiB.
BIG_HOME="$WORK/big_guest_home"
mkdir -p "$BIG_HOME/.config/ezgha" "$BIG_HOME/.config/systemd/user/lima-vm@colima.service.d" "$BIG_HOME/.lima/colima"
printf '# fixture\n' > "$BIG_HOME/.config/ezgha/config.toml"
printf 'cpus: 4\nmemory: "12GiB"\n' > "$BIG_HOME/.lima/colima/lima.yaml"
BIG_PROC="$WORK/big_proc"
mkdir -p "$BIG_PROC/7777"
printf 'qemu-system-x86\n' > "$BIG_PROC/7777/comm"
printf '%s\0' qemu-system-x86_64 -m 12288 -drive "file=$BIG_HOME/.lima/colima/diffdisk,if=virtio" > "$BIG_PROC/7777/cmdline"
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
  LIMA_FIXTURE_STATUS=Running LIMA_PROC_ROOT="$BIG_PROC" \
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
printf '# fixture\n' > "$RELOAD_HOME/.config/ezgha/config.toml"
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
printf '# fixture\n' > "$NOMEM_HOME/.config/ezgha/config.toml"
printf 'cpus: 4\n' > "$NOMEM_HOME/.lima/colima/lima.yaml"
env EVENT_LOG="$WORK/nomem_events" PATH="$STUB_BIN:$PATH" HOME="$NOMEM_HOME" CARGO_HOME="$NOMEM_HOME/.cargo" XDG_CONFIG_HOME="$NOMEM_HOME/.config" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/nomem-install.log" 2>&1 || fail "no-memory-line fixture install failed"
grep -qx 'memory: "8GiB"' "$NOMEM_HOME/.lima/colima/lima.yaml" \
  || fail "lima.yaml without memory: was not set to 8GiB: $(cat "$NOMEM_HOME/.lima/colima/lima.yaml")"

run_failed_phase() {
  local phase="$1"
  local home="$WORK/${phase}_home"
  local log="$WORK/${phase}_events"
  mkdir -p "$home/.config/ezgha"
  printf '# fixture\n' > "$home/.config/ezgha/config.toml"
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

# An explicitly selected VM daemon must be used consistently for reachability,
# kernel classification, and image build. Its guest kernel differs from the
# host, so host-Docker containment is intentionally not activated.
VM_EVENT_LOG="$WORK/vm_events"
VM_HOME="$WORK/vm_home"
mkdir -p "$VM_HOME"
env EVENT_LOG="$VM_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$VM_HOME" CARGO_HOME="$VM_HOME/.cargo" XDG_CONFIG_HOME="$VM_HOME/.config" \
  DOCKER_HOST="unix://$VM_HOME/.colima/default/docker.sock" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/vm-install.log" 2>&1 \
  || fail "explicit VM endpoint fixture install failed"
grep -qx "docker-info:unix://$VM_HOME/.colima/default/docker.sock" "$VM_EVENT_LOG" \
  || fail "installer did not probe the explicitly selected VM endpoint"
grep -qx "docker-build:unix://$VM_HOME/.colima/default/docker.sock" "$VM_EVENT_LOG" \
  || fail "installer did not build on the explicitly selected VM endpoint"
if grep -q '^root-phase$\|^user-phase$' "$VM_EVENT_LOG"; then
  fail "VM endpoint was misclassified as native HostDocker"
fi
# VM-backed mode keeps the 34G/38G QEMU ceiling (runners live in the guest).
grep -qx 'MemoryMax=38G' "$VM_HOME/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  || fail "VM-backed install did not deploy the 34G/38G QEMU ceiling"

# Docker documents DOCKER_CONTEXT as higher precedence than DOCKER_HOST. The
# active-service upgrade path must persist that resolved endpoint before its
# existing restart, rather than leaving an old unit pointed at native Docker.
CONTEXT_EVENT_LOG="$WORK/context_events"
CONTEXT_HOME="$WORK/context_home"
mkdir -p "$CONTEXT_HOME/.config/ezgha"
printf '# fixture\n' > "$CONTEXT_HOME/.config/ezgha/config.toml"
env EVENT_LOG="$CONTEXT_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$CONTEXT_HOME" CARGO_HOME="$CONTEXT_HOME/.cargo" XDG_CONFIG_HOME="$CONTEXT_HOME/.config" \
  SYSTEMCTL_ACTIVE=1 DOCKER_CONTEXT='explicit-context' DOCKER_HOST='unix:///fixture/ignored.sock' \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/context-install.log" 2>&1 \
  || fail "named Docker context fixture install failed"
grep -qx "docker-info:unix://$CONTEXT_HOME/.colima/default/docker.sock" "$CONTEXT_EVENT_LOG" \
  || fail "DOCKER_CONTEXT did not override DOCKER_HOST during endpoint discovery"
grep -qx "docker-build:unix://$CONTEXT_HOME/.colima/default/docker.sock" "$CONTEXT_EVENT_LOG" \
  || fail "image build did not use the resolved named context endpoint"
if ! grep -qx "install-service:unix://$CONTEXT_HOME/.colima/default/docker.sock" "$CONTEXT_EVENT_LOG"; then
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
echo "INSTALL_HOST_CONTAINMENT_TEST: PASS"
