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
assert_line "$REPO_ROOT/systemd/app-lima-vm.slice" "MemoryHigh=34G"
assert_line "$REPO_ROOT/systemd/app-lima-vm.slice" "MemoryMax=38G"
assert_line "$REPO_ROOT/systemd/app-lima-vm.slice" "MemorySwapMax=2G"
assert_line "$REPO_ROOT/systemd/app-lima-vm.slice" "TasksMax=4096"
assert_line "$REPO_ROOT/systemd/app-lima-vm.slice" "CPUQuota=1600%"
QEMU_DROPIN="$REPO_ROOT/systemd/lima-vm@colima.service.d/99-memory-ceiling.conf"
assert_file "$QEMU_DROPIN"
assert_line "$QEMU_DROPIN" "MemoryHigh=34G"
assert_line "$QEMU_DROPIN" "MemoryMax=38G"
assert_line "$QEMU_DROPIN" "MemorySwapMax=2G"
assert_line "$QEMU_DROPIN" "TasksMax=4096"
assert_line "$QEMU_DROPIN" "CPUQuota=1600%"
assert_file "$REPO_ROOT/systemd/lima-vm-cpu-ceiling.service"
for setting in MemoryHigh=34G MemoryMax=38G MemorySwapMax=2G TasksMax=4096 CPUQuota=1600%; do
  grep -Fq "$setting" "$REPO_ROOT/systemd/lima-vm-cpu-ceiling.service" \
    || fail "lima-vm-cpu-ceiling.service missing $setting"
done
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
assert_line "$REPO_ROOT/systemd/automation.slice" "MemoryHigh=4G"
assert_line "$REPO_ROOT/systemd/automation.slice" "MemoryMax=6G"
assert_line "$REPO_ROOT/systemd/automation.slice" "MemorySwapMax=1G"
assert_line "$REPO_ROOT/systemd/automation.slice" "TasksMax=4096"
grep -q "measured margin" "$REPO_ROOT/systemd/agents.slice" || fail "agents.slice lacks measured margin documentation"
grep -q "measured margin" "$REPO_ROOT/systemd/app-lima-vm.slice" || fail "app-lima-vm.slice lacks measured margin documentation"
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
grep -Eq -- '--user --slice=agents.slice --scope --collect --unit=agent-claude-[0-9]+-[0-9]+ -- claude --version' "$STUB/capture" || fail "launcher invocation did not preserve command, discoverable unit, and scope flags"
LAUNCH_CAPTURE="$STUB/optout" PATH="$STUB:$PATH" AGENT_SLICE_OPT_OUT=1 \
  "$LAUNCH" codex codex exec test >/dev/null
grep -Fq 'exec test' "$STUB/optout" || fail "explicit opt-out did not execute command"
ok "generic scoped launcher and explicit opt-out"

REAPER="$REPO_ROOT/scripts/host/agent-scope-reaper.sh"
assert_file "$REAPER"; bash -n "$REAPER"
assert_file "$REPO_ROOT/systemd/agent-scope-reaper.service"
assert_file "$REPO_ROOT/systemd/agent-scope-reaper.timer"
grep -q 'grace' "$REAPER" || fail "reaper lacks grace period"
grep -q 'primary' "$REAPER" || fail "reaper lacks primary CLI check"
printf '%s\n' 'agent-old.scope|100' 'agent-young.scope|950' 'agent-live.scope|100' 'not-agent.scope|100' > "$STUB/scopes"
AGENT_SCOPE_UNIT_FIXTURE="$STUB/scopes" AGENT_SCOPE_NOW_EPOCH=1000 \
  AGENT_SCOPE_GRACE_SECONDS=100 AGENT_SCOPE_PRIMARY_MAP='agent-old.scope=0,agent-live.scope=1' AGENT_SCOPE_DRY_RUN=1 \
  AGENT_SCOPE_REAPER_LOG="$STUB/reaper.log" "$REAPER"
grep -q '"unit":"agent-old.scope".*"action":"would-stop"' "$STUB/reaper.log" || fail "reaper did not identify aged orphan"
grep -q '"unit":"agent-young.scope".*"action":"keep"' "$STUB/reaper.log" || fail "reaper did not honor grace period"
grep -q '"unit":"agent-live.scope".*"action":"defer"' "$STUB/reaper.log" || fail "reaper did not inspect each scope independently"
ok "orphan reaper artifacts"

for forbidden_file in \
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
  "$REPO_ROOT/scripts/ezgha-fleet-watchdog.sh"; do
  [ ! -e "$forbidden_file" ] || fail "forbidden watchdog/reboot artifact still exists: $forbidden_file"
done
ok "watchdog and reboot artifacts are strictly absent"

grep -q 'Gate 8 guest runner aggregate' "$REPO_ROOT/docs/verify-exit-criteria.sh" || fail "exit criteria do not verify the guest runner aggregate"
grep -q '/sys/fs/cgroup/actions.slice/memory.max' "$REPO_ROOT/docs/verify-exit-criteria.sh" || fail "exit criteria do not read the live guest actions.slice ceiling"

echo "HOST_CONTROL_ARTIFACTS_TEST: PASS"
