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
  echo unix:///fixture/context.sock
  exit 0
fi
if [[ "$args" == *" info "* ]]; then
  echo "docker-info:${DOCKER_HOST:-}" >> "$EVENT_LOG"
  if [ "${DOCKER_HOST:-}" = "unix:///fixture/vm.sock" ] || [ "${DOCKER_HOST:-}" = "unix:///fixture/context.sock" ]; then
    echo fixture-vm-kernel
  else
    echo fixture-host-kernel
  fi
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
  is-active) [ "${SYSTEMCTL_ACTIVE:-0}" = 1 ] && exit 0 || exit 1 ;;
  daemon-reload|start|set-property) echo "systemctl-$1" >> "$EVENT_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
for agent in codex claude gemini cursor aider cody; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$agent"
done
chmod +x "$STUB_BIN"/*

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
mkdir -p "$HOME_DIR/.config/ezgha" "$HOME_DIR/.config/systemd/user"
printf '# fixture\n' > "$HOME_DIR/.config/ezgha/config.toml"
EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$HOME_DIR" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/install.log" 2>&1 || fail "host-Docker fixture install failed"

[ -f "$HOME_DIR/.local/libexec/ezgha/host-containment-policy/systemd/host/actions.slice" ] \
  || fail "installed containment policy subtree is incomplete"
root_line="$(line_of root-phase)"; user_line="$(line_of user-phase)"; install_line="$(line_of cargo-install)"; build_line="$(grep -n -m1 '^docker-build:' "$EVENT_LOG" | cut -d: -f1)"
[ -n "$root_line" ] && [ -n "$user_line" ] && [ -n "$install_line" ] && [ -n "$build_line" ] || fail "missing containment or install event"
[ "$root_line" -lt "$user_line" ] && [ "$user_line" -lt "$install_line" ] && [ "$install_line" -lt "$build_line" ] \
  || fail "root/user containment did not precede binary replacement and image build"

run_failed_phase() {
  local phase="$1"
  local home="$WORK/${phase}_home"
  local log="$WORK/${phase}_events"
  mkdir -p "$home/.config/ezgha"
  printf '# fixture\n' > "$home/.config/ezgha/config.toml"
  if env EVENT_LOG="$log" PATH="$STUB_BIN:$PATH" HOME="$home" "APPLY_FAIL_${phase^^}=1" \
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
env EVENT_LOG="$VM_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$VM_HOME" \
  DOCKER_HOST='unix:///fixture/vm.sock' \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/vm-install.log" 2>&1 \
  || fail "explicit VM endpoint fixture install failed"
grep -qx 'docker-info:unix:///fixture/vm.sock' "$VM_EVENT_LOG" \
  || fail "installer did not probe the explicitly selected VM endpoint"
grep -qx 'docker-build:unix:///fixture/vm.sock' "$VM_EVENT_LOG" \
  || fail "installer did not build on the explicitly selected VM endpoint"
if grep -q '^root-phase$\|^user-phase$' "$VM_EVENT_LOG"; then
  fail "VM endpoint was misclassified as native HostDocker"
fi

# Docker documents DOCKER_CONTEXT as higher precedence than DOCKER_HOST. The
# active-service upgrade path must persist that resolved endpoint before its
# existing restart, rather than leaving an old unit pointed at native Docker.
CONTEXT_EVENT_LOG="$WORK/context_events"
CONTEXT_HOME="$WORK/context_home"
mkdir -p "$CONTEXT_HOME/.config/ezgha"
printf '# fixture\n' > "$CONTEXT_HOME/.config/ezgha/config.toml"
env EVENT_LOG="$CONTEXT_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$CONTEXT_HOME" \
  SYSTEMCTL_ACTIVE=1 DOCKER_CONTEXT='explicit-context' DOCKER_HOST='unix:///fixture/ignored.sock' \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/context-install.log" 2>&1 \
  || fail "named Docker context fixture install failed"
grep -qx 'docker-info:unix:///fixture/context.sock' "$CONTEXT_EVENT_LOG" \
  || fail "DOCKER_CONTEXT did not override DOCKER_HOST during endpoint discovery"
grep -qx 'docker-build:unix:///fixture/context.sock' "$CONTEXT_EVENT_LOG" \
  || fail "image build did not use the resolved named context endpoint"
grep -qx 'install-service:unix:///fixture/context.sock' "$CONTEXT_EVENT_LOG" \
  || fail "active systemd service refresh did not persist the selected endpoint"
echo "INSTALL_HOST_CONTAINMENT_TEST: PASS"
