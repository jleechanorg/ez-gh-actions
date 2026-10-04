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
  show)
    if [[ " $* " == *" -p ActiveState "* ]]; then echo inactive; fi
    exit 0 ;;
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
mkdir -p "$HOME_DIR/.config/ezgha" "$HOME_DIR/.config/systemd/user"
printf '[runner]\ncount = 14\n' > "$HOME_DIR/.config/ezgha/config.toml"
EVENT_LOG="$EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$HOME_DIR" CARGO_HOME="$HOME_DIR/.cargo" XDG_CONFIG_HOME="$HOME_DIR/.config" \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/install.log" 2>&1 || fail "host-Docker fixture install failed"

[ -f "$HOME_DIR/.local/libexec/ezgha/host-containment-policy/systemd/host/actions.slice" ] \
  || fail "installed containment policy subtree is incomplete"
for policy in app-lima-vm.slice lima-vm@colima.service.d/99-memory-ceiling.conf lima-vm-cpu-ceiling.service; do
  cmp "$REPO_ROOT/systemd/$policy" "$HOME_DIR/.local/libexec/ezgha/host-containment-policy/systemd/$policy" || fail "missing or stale installed $policy"
done
cmp "$REPO_ROOT/scripts/host/qemu-ceiling-guard.sh" "$HOME_DIR/.local/libexec/ezgha/qemu-ceiling-guard.sh" || fail "missing installed QEMU guard"
root_line="$(line_of "root-phase:--system-phase --runner-count 14")"; user_line="$(line_of "user-phase:--runner-count 14")"; install_line="$(line_of cargo-install)"; build_line="$(grep -n -m1 '^docker-build:' "$EVENT_LOG" | cut -d: -f1)"
[ -n "$root_line" ] && [ -n "$user_line" ] && [ -n "$install_line" ] && [ -n "$build_line" ] || fail "missing containment or install event"
[ "$root_line" -lt "$user_line" ] && [ "$user_line" -lt "$install_line" ] && [ "$install_line" -lt "$build_line" ] \
  || fail "root/user containment did not precede binary replacement and image build"

ROLLBACK_HOME="$WORK/rollback_home"
ROLLBACK_LOG="$WORK/rollback_events"
mkdir -p "$ROLLBACK_HOME/.config/ezgha"
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

# An explicitly selected VM daemon must be used consistently for reachability,
# kernel classification, and image build. Its guest kernel differs from the
# host, so host-Docker containment is intentionally not activated.
VM_EVENT_LOG="$WORK/vm_events"
VM_HOME="$WORK/vm_home"
mkdir -p "$VM_HOME/.config/ezgha"
printf '[runner]\ncount = 12\n' > "$VM_HOME/.config/ezgha/config.toml"
env EVENT_LOG="$VM_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$VM_HOME" CARGO_HOME="$VM_HOME/.cargo" XDG_CONFIG_HOME="$VM_HOME/.config" \
  DOCKER_HOST='unix:///fixture/vm.sock' \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/vm-install.log" 2>&1 \
  || fail "explicit VM endpoint fixture install failed"
grep -qx 'docker-info:unix:///fixture/vm.sock' "$VM_EVENT_LOG" \
  || fail "installer did not probe the explicitly selected VM endpoint"
grep -qx 'docker-build:unix:///fixture/vm.sock' "$VM_EVENT_LOG" \
  || fail "installer did not build on the explicitly selected VM endpoint"
if grep -qE '^(root|user)-phase:' "$VM_EVENT_LOG"; then
  fail "VM endpoint was misclassified as native HostDocker"
fi

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

# Docker documents DOCKER_CONTEXT as higher precedence than DOCKER_HOST. The
# active-service upgrade path must persist that resolved endpoint before its
# existing restart, rather than leaving an old unit pointed at native Docker.
CONTEXT_EVENT_LOG="$WORK/context_events"
CONTEXT_HOME="$WORK/context_home"
mkdir -p "$CONTEXT_HOME/.config/ezgha"
printf '[runner]\ncount = 14\n' > "$CONTEXT_HOME/.config/ezgha/config.toml"
env EVENT_LOG="$CONTEXT_EVENT_LOG" PATH="$STUB_BIN:$PATH" HOME="$CONTEXT_HOME" CARGO_HOME="$CONTEXT_HOME/.cargo" XDG_CONFIG_HOME="$CONTEXT_HOME/.config" \
  SYSTEMCTL_ACTIVE=1 DOCKER_CONTEXT='explicit-context' DOCKER_HOST='unix:///fixture/ignored.sock' \
  bash "$TEMP_REPO/install.sh" --dev > "$WORK/context-install.log" 2>&1 \
  || fail "named Docker context fixture install failed"
grep -qx 'docker-info:unix:///fixture/context.sock' "$CONTEXT_EVENT_LOG" \
  || fail "DOCKER_CONTEXT did not override DOCKER_HOST during endpoint discovery"
grep -qx 'docker-build:unix:///fixture/context.sock' "$CONTEXT_EVENT_LOG" \
  || fail "image build did not use the resolved named context endpoint"
if ! grep -qx 'install-service:unix:///fixture/context.sock' "$CONTEXT_EVENT_LOG"; then
  echo "context fixture install log:" >&2
  sed -n '1,120p' "$WORK/context-install.log" >&2 || true
  echo "context fixture events:" >&2
  cat "$CONTEXT_EVENT_LOG" >&2 || true
  fail "active systemd service refresh did not persist the selected endpoint"
fi
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
