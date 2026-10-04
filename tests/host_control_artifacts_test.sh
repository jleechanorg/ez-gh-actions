#!/usr/bin/env bash
# Regression coverage for the bounded host-control artifacts (issues #72/#75).
# This test is intentionally shell-only and never starts/stops a host unit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

assert_file() { [ -f "$1" ] || fail "missing $1"; }
assert_line() {
  local file="$1" line="$2"
  grep -Fqx "$line" "$file" || fail "$file missing exact line: $line"
}

for unit in agents.slice app-lima-vm.slice automation.slice; do
  assert_file "$REPO_ROOT/systemd/$unit"
done
assert_file "$REPO_ROOT/systemd/ao-daemon.service.d/20-automation-slice.conf"
assert_file "$REPO_ROOT/systemd/ao-orchestrator.service.d/20-automation-slice.conf"
assert_file "$REPO_ROOT/systemd/ai.dark-factory.daemon.service.d/20-automation-slice.conf"
grep -q '^Slice=automation.slice$' "$REPO_ROOT/systemd/ao-daemon.service.d/20-automation-slice.conf" || fail "AO drop-in does not select automation.slice"
grep -q '^Slice=automation.slice$' "$REPO_ROOT/systemd/ao-orchestrator.service.d/20-automation-slice.conf" || fail "AO orchestrator drop-in does not select automation.slice"
grep -q '^Slice=automation.slice$' "$REPO_ROOT/systemd/ai.dark-factory.daemon.service.d/20-automation-slice.conf" || fail "dark-factory daemon drop-in does not select automation.slice"
assert_line "$REPO_ROOT/systemd/agents.slice" "MemoryHigh=10G"
assert_line "$REPO_ROOT/systemd/agents.slice" "MemoryMax=12G"
assert_line "$REPO_ROOT/systemd/agents.slice" "MemorySwapMax=2G"
assert_line "$REPO_ROOT/systemd/agents.slice" "TasksMax=8192"
# The QEMU ceiling is deployment-mode dependent (bead ez-gh-actions-154k):
# VM-backed (runners inside Colima) keeps 9G/10G; host-docker (runners in
# host Docker, Colima only runs qdrant in an 8 GiB guest) caps it at 9G/10G.
# Each of the three tracked surfaces exists in both variants.
for mode in vm-backed host-docker; do
  case "$mode" in
    vm-backed) dir="$REPO_ROOT/systemd"; high=MemoryHigh=9G; max=MemoryMax=10G ;;
    host-docker) dir="$REPO_ROOT/systemd/host-docker"; high=MemoryHigh=9G; max=MemoryMax=10G ;;
  esac
  for file in "$dir/app-lima-vm.slice" "$dir/lima-vm@colima.service.d/99-memory-ceiling.conf"; do
    assert_file "$file"
    for line in "$high" "$max" MemorySwapMax=2G TasksMax=4096 CPUQuota=1600%; do
      assert_line "$file" "$line"
    done
  done
  assert_file "$dir/lima-vm-cpu-ceiling.service"
  for setting in "$high" "$max" MemorySwapMax=2G TasksMax=4096 CPUQuota=1600%; do
    grep -Fq "$setting" "$dir/lima-vm-cpu-ceiling.service" \
      || fail "$mode lima-vm-cpu-ceiling.service missing $setting"
    grep -Fq "$setting" "$REPO_ROOT/install.sh" || fail "install.sh does not apply $mode $setting"
  done
  grep -q "measured margin" "$dir/app-lima-vm.slice" || fail "$mode app-lima-vm.slice lacks measured margin documentation"
done
# Every memory value is an integer unit (systemd and the Gate 8 bash helpers
# both reject fractional sizes such as 4.5G).
! grep -rEn '^Memory(High|Max|SwapMax)=[0-9]*\.[0-9]' "$REPO_ROOT/systemd" \
  || fail "fractional memory value in tracked systemd policy"
grep -q 'memory: "8GiB"' "$REPO_ROOT/install.sh" || fail "install.sh does not set the host-docker Lima guest to 8GiB"
assert_file "$REPO_ROOT/scripts/host/assert-qemu-cpu-ceiling.sh"
bash -n "$REPO_ROOT/scripts/host/assert-qemu-cpu-ceiling.sh"
grep -q 'QEMU_PROC_ROOT' "$REPO_ROOT/scripts/host/assert-qemu-cpu-ceiling.sh" \
  || fail "QEMU assertion lacks injected proc-root fixture support"
grep -q 'QEMU_CGROUP_ROOT' "$REPO_ROOT/scripts/host/assert-qemu-cpu-ceiling.sh" \
  || fail "QEMU assertion lacks injected cgroup-root fixture support"
GUEST_ACTIONS_SLICE="$REPO_ROOT/systemd/guest/actions.slice"
assert_file "$GUEST_ACTIONS_SLICE"
assert_line "$GUEST_ACTIONS_SLICE" "MemoryHigh=28G"
assert_line "$GUEST_ACTIONS_SLICE" "MemoryMax=32G"
assert_line "$GUEST_ACTIONS_SLICE" "MemorySwapMax=0"
assert_line "$GUEST_ACTIONS_SLICE" "TasksMax=6000"
assert_line "$REPO_ROOT/systemd/automation.slice" "MemoryHigh=4608M"
assert_line "$REPO_ROOT/systemd/automation.slice" "MemoryMax=5G"
assert_line "$REPO_ROOT/systemd/automation.slice" "MemorySwapMax=1G"
assert_line "$REPO_ROOT/systemd/automation.slice" "TasksMax=4096"
grep -q "measured margin" "$REPO_ROOT/systemd/agents.slice" || fail "agents.slice lacks measured margin documentation"
grep -q "measured margin" "$REPO_ROOT/systemd/automation.slice" || fail "automation.slice lacks measured margin documentation"
ok "slice budgets and measured-margin documentation"

LAUNCH="$REPO_ROOT/scripts/host/agent-scoped-launch.sh"
assert_file "$LAUNCH"
bash -n "$LAUNCH"
grep -q -- '--collect' "$LAUNCH" || fail "launcher does not collect transient scopes"
for cli in codex claude gemini cursor aider cody; do
  grep -q "$cli" "$LAUNCH" || fail "launcher does not list $cli"
done
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"; [ -z "${WATCHDOG_FIXTURE_DIR:-}" ] || rm -rf "$WATCHDOG_FIXTURE_DIR"' EXIT
cat > "$STUB/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${LAUNCH_CAPTURE:?}"
EOF
chmod +x "$STUB/systemd-run"
cat > "$STUB/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${LAUNCH_CAPTURE:?}"
EOF
chmod +x "$STUB/codex"
LAUNCH_CAPTURE="$STUB/capture" PATH="$STUB:$PATH" AGENT_SLICE_UNIT_FILE="$REPO_ROOT/systemd/agents.slice" \
  "$LAUNCH" claude claude --version >/dev/null
if grep -q 'AGENT_SLICE_OPT_OUT' "$LAUNCH"; then
  fail "launcher still contains forbidden AGENT_SLICE_OPT_OUT escape hatch"
fi
ok "generic scoped launcher enforces slice confinement with no opt-out"

for gone in scripts/host/agent-scope-reaper.sh systemd/agent-scope-reaper.service systemd/agent-scope-reaper.timer; do
  [ ! -e "$REPO_ROOT/$gone" ] || fail "deleted agent-scope-reaper artifact still present: $gone"
done
ok "orphan reaper artifacts removed"

for forbidden_file in \
  "$REPO_ROOT/systemd/ezgha.service.d/10-oomd-omit.conf" \
  "$REPO_ROOT/systemd/psi-oom-watcher.service" \
  "$REPO_ROOT/systemd/psi-oom-watcher.timer" \
  "$REPO_ROOT/scripts/host/psi-oom-watcher.sh" \
  "$REPO_ROOT/config/config.toml.linux-canary.example" \
  "$REPO_ROOT/scripts/host/watchdog-load-repair.sh" \
  "$REPO_ROOT/scripts/host/apply-watchdog-no-reboot-vote.sh" \
  "$REPO_ROOT/scripts/host/assert-no-host-reboot-vote.sh" \
  "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" \
  "$REPO_ROOT/scripts/host/configure-grub-kdump.sh" \
  "$REPO_ROOT/scripts/host/crash-capture-verify.sh" \
  "$REPO_ROOT/scripts/host/kdump-remediation.sh" \
  "$REPO_ROOT/config/watchdog.conf" \
  "$REPO_ROOT/config/sysctl.d/99-ezgha-oops-reboot.conf" \
  "$REPO_ROOT/config/grub.d/zz-ezgha-nohz-panic.cfg" \
  "$REPO_ROOT/systemd/ezgha-watchdog.service" \
  "$REPO_ROOT/systemd/ezgha-watchdog.timer" \
  "$REPO_ROOT/scripts/host/host-pressure-proof.sh" \
  "$REPO_ROOT/scripts/ezgha-fleet-watchdog.sh"; do
  [ ! -e "$forbidden_file" ] || fail "forbidden watchdog/reboot/exemption artifact still exists: $forbidden_file"
done
ok "watchdog, reboot, and exemption artifacts are strictly absent"

grep -q 'Gate 8 guest runner aggregate' "$REPO_ROOT/docs/verify-exit-criteria.sh" || fail "exit criteria do not verify the guest runner aggregate"
grep -q '/sys/fs/cgroup/actions.slice/memory.max' "$REPO_ROOT/docs/verify-exit-criteria.sh" || fail "exit criteria do not read the live guest actions.slice ceiling"

echo "HOST_CONTROL_ARTIFACTS_TEST: PASS"
