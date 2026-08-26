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
APPLY_WD="$REPO_ROOT/scripts/host/apply-watchdog-no-reboot-vote.sh"
assert_file "$APPLY_WD"
bash -n "$APPLY_WD"
APPLY_WATCHDOG_DRY_RUN=1 bash "$APPLY_WD" | grep -q 'repair-maximum=0' \
  || fail "apply-watchdog-no-reboot-vote.sh dry-run missing repair-maximum=0"
assert_file "$REPO_ROOT/config/sysctl.d/99-ezgha-oops-reboot.conf"
assert_line "$REPO_ROOT/config/sysctl.d/99-ezgha-oops-reboot.conf" "kernel.panic = 10"
assert_file "$REPO_ROOT/config/grub.d/zz-ezgha-nohz-panic.cfg"
grep -q 'nohz=off' "$REPO_ROOT/config/grub.d/zz-ezgha-nohz-panic.cfg" \
  || fail "grub drop-in missing nohz=off"
APPLY_PANIC_STOP_DRY_RUN=1 bash "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" | grep -q 'nohz=off' \
  || fail "apply-cfs-nohz-panic-stop.sh dry-run missing nohz=off"
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

REPAIR="$REPO_ROOT/scripts/host/watchdog-load-repair.sh"
assert_file "$REPAIR"; bash -n "$REPAIR"
! grep -q 'log result reboot-eligible' "$REPAIR" || fail "repair still logs reboot-eligible (that exit 1 is a watchdog(8) reboot vote)"
! grep -q '^exit 1$' "$REPAIR" || fail "repair still exits 1 (watchdog(8) reboot vote)"
assert_line "$REPO_ROOT/config/watchdog.conf" "repair-maximum = 0"
# Use a temporary executable fixture for the configured repair-binary path;
# the tracked config deliberately names the installed /home path, which this
# test must not create or mutate.
WATCHDOG_FIXTURE_DIR="$(mktemp -d)"
WATCHDOG_FIXTURE_REPAIR="$WATCHDOG_FIXTURE_DIR/watchdog-load-repair.sh"
cp "$REPAIR" "$WATCHDOG_FIXTURE_REPAIR"
chmod +x "$WATCHDOG_FIXTURE_REPAIR"
sed "s#^[[:space:]]*repair-binary[[:space:]]*=.*#repair-binary = $WATCHDOG_FIXTURE_REPAIR#" \
  "$REPO_ROOT/config/watchdog.conf" > "$WATCHDOG_FIXTURE_DIR/watchdog.conf"
ASSERT_LIVE_WATCHDOG=1 WATCHDOG_CONF_PATH="$WATCHDOG_FIXTURE_DIR/watchdog.conf" \
  REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/scripts/host/assert-no-host-reboot-vote.sh" >/dev/null \
  || fail "watchdog reboot-vote assertion does not accept the safe fixture config"
grep -Fq 'WATCHDOG_CONF_PATH=/etc/watchdog.conf' "$REPO_ROOT/docs/verify-exit-criteria.sh" \
  || fail "exit criteria does not pin the live watchdog config path"
grep -Fq 'ASSERT_LIVE_WATCHDOG=1' "$REPO_ROOT/docs/verify-exit-criteria.sh" \
  || fail "exit criteria does not run the Linux watchdog assertion in live read-only mode"
grep -Fq 'scripts/host/assert-no-host-reboot-vote.sh' "$REPO_ROOT/docs/verify-exit-criteria.sh" \
  || fail "exit criteria does not invoke the watchdog assertion"
for stage in freeze close kill remove reclaim verify limactl; do
  grep -q "$stage" "$REPAIR" || fail "repair missing stage $stage"
done
grep -q 'DEADLINE' "$REPAIR" || fail "repair lacks total deadline"
grep -q 'DRY_RUN' "$REPAIR" || fail "repair lacks dry-run injection path"
printf 'MemAvailable: 1000 kB\n' > "$STUB/meminfo"
printf 'some avg10=10.0 avg60=10.0 avg300=10.0 total=1\n' > "$STUB/psi"
mkdir -p "$STUB/cgroup"; : > "$STUB/cgroup/memory.reclaim"
cat > "$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *' is-active '* ]]; then
  printf 'admission-poll\n' >> "${REPAIR_TRACE:?}"
  printf 'inactive\n'
else
  printf 'admission\n' >> "${REPAIR_TRACE:?}"
fi
printf '%s\n' "$*" > "${REPAIR_SYSTEMCTL_ARGS:?}"
EOF
cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = context ] && [ "${2:-}" = inspect ]; then
  printf 'unix:///tmp/active-lima/docker.sock\n'
elif [ "${1:-}" = ps ]; then
  printf 'runner-1\n'
else
  printf 'containers\n' >> "${REPAIR_TRACE:?}"
fi
printf '%s\n' "${DOCKER_HOST:-}" > "${REPAIR_DOCKER_HOST_CAPTURE:?}"
printf '%s\n' "${DOCKER_CONTEXT:-}" > "${REPAIR_DOCKER_CONTEXT_CAPTURE:?}"
printf '%s\n' "${DOCKER_CONFIG:-}" > "${REPAIR_DOCKER_CONFIG_CAPTURE:?}"
EOF
cat > "$STUB/limactl" <<'EOF'
#!/usr/bin/env bash
printf 'limactl\n' >> "${REPAIR_TRACE:?}"
printf '%s\n' "$HOME" > "${REPAIR_LIMACTL_HOME_CAPTURE:?}"
if [ -n "${REPAIR_LIMACTL_ARGS_CAPTURE:-}" ]; then
  printf '%s\n' "$*" > "${REPAIR_LIMACTL_ARGS_CAPTURE}"
fi
EOF
chmod +x "$STUB/systemctl" "$STUB/docker" "$STUB/limactl"
REPAIR_TRACE="$STUB/trace" REPAIR_SYSTEMCTL_ARGS="$STUB/systemctl.args" \
  REPAIR_DOCKER_HOST_CAPTURE="$STUB/docker-host" REPAIR_LIMACTL_HOME_CAPTURE="$STUB/limactl-home" \
  REPAIR_DOCKER_CONTEXT_CAPTURE="$STUB/docker-context" REPAIR_DOCKER_CONFIG_CAPTURE="$STUB/docker-config" \
  REPAIR_LIMACTL_ARGS_CAPTURE="$STUB/limactl-args" \
  REPAIR_LIMACTL_BIN="$STUB/limactl" REPAIR_USER="$USER" REPAIR_USER_HOME="$HOME" REPAIR_ALLOW_NONROOT=1 REPAIR_DEADLINE_SECONDS=10 \
  REPAIR_LOG_FILE="$STUB/repair.log" REPAIR_MEMINFO_FILE="$STUB/meminfo" REPAIR_PSI_FILE="$STUB/psi" \
  REPAIR_QEMU_CGROUP="$STUB/cgroup" REPAIR_VERIFY_WINDOW_SECONDS=0 REPAIR_VERIFY_WAIT_SECONDS=0 REPAIR_LIMA_STOP_TIMEOUT_SECONDS=1 \
  DOCKER_CONTEXT=poisoned-context DOCKER_CONFIG=/tmp/poisoned-docker-config \
  PATH="$STUB:$PATH" "$REPAIR" >/dev/null || repair_rc=$?
repair_rc="${repair_rc:-0}"
[ "$repair_rc" -eq 0 ] || fail "unrecovered pressure must still exit 0; non-zero is a watchdog(8) reboot vote"
grep -q '"stage":"result","status":"shed-complete"' "$STUB/repair.log" || fail "unrecovered pressure did not log shed-complete"
! grep -q 'reboot-eligible' "$STUB/repair.log" || fail "repair logged reboot-eligible"
[ "$(grep -c '"stage":"verify"' "$STUB/repair.log")" -ge 2 ] || fail "VM stop path did not perform bounded post-stop verification"
grep -nFx 'admission' "$STUB/trace" >/dev/null || fail "repair did not close admission"
grep -nFx 'containers' "$STUB/trace" >/dev/null || fail "repair did not shed containers"
grep -nFx 'limactl' "$STUB/trace" >/dev/null || fail "repair did not reach bounded VM stage"
admission_line=$(grep -nFx 'admission' "$STUB/trace" | head -1 | cut -d: -f1)
admission_poll_line=$(grep -nFx 'admission-poll' "$STUB/trace" | head -1 | cut -d: -f1)
containers_line=$(grep -nFx 'containers' "$STUB/trace" | head -1 | cut -d: -f1)
limactl_line=$(grep -nFx 'limactl' "$STUB/trace" | head -1 | cut -d: -f1)
[ "$admission_line" -lt "$admission_poll_line" ] && [ "$admission_poll_line" -lt "$containers_line" ] && [ "$containers_line" -lt "$limactl_line" ] || fail "repair stages are out of order or admission raced snapshot"
grep -Fq -- '--user --machine=' "$STUB/systemctl.args" || fail "repair did not target the owning user manager"
grep -Fxq 'unix:///tmp/active-lima/docker.sock' "$STUB/docker-host" || fail "repair did not discover and pass the active user Docker context socket"
[ -z "$(cat "$STUB/docker-context")" ] || fail "repair leaked inherited DOCKER_CONTEXT into managed-container operations"
[ -z "$(cat "$STUB/docker-config")" ] || fail "repair leaked inherited DOCKER_CONFIG into managed-container operations"
[ "$(cat "$STUB/limactl-home")" = "$HOME" ] || fail "repair did not run limactl with owning user HOME"
grep -Fq -- '--tty=false stop colima' "$STUB/limactl-args" || fail "repair did not invoke limactl stop noninteractively"
! grep -Fq -- '--timeout' "$STUB/limactl-args" || fail "repair passed unsupported --timeout flag to limactl stop"
grep -q '/proc/.*cgroup' "$REPAIR" || fail "repair does not dynamically derive QEMU cgroup from PID"
grep -q 'REPAIR_RECLAIM_BYTES' "$REPAIR" || fail "repair lacks configurable reclaim bytes"
grep -q 'REPAIR_MIN_AVAILABLE_KB' "$REPAIR" || fail "repair lacks MemAvailable reserve floor"
grep -q 'REPAIR_MAX_PSI_AVG10' "$REPAIR" || fail "repair lacks PSI threshold"
grep -q 'REPAIR_MAX_PSI_TOTAL_DELTA' "$REPAIR" || fail "repair lacks PSI total-delta bound"
grep -q 'REPAIR_VERIFY_WINDOW_SECONDS' "$REPAIR" || fail "repair lacks bounded PSI verification window"
grep -q 'REPAIR_ADMISSION_POLL_COMMAND_TIMEOUT_SECONDS' "$REPAIR" || fail "admission poll is not individually bounded"
grep -q '"stage":"result"' "$STUB/repair.log" || fail "repair missing structured result log"
grep -q 'Gate 8 guest runner aggregate' "$REPO_ROOT/docs/verify-exit-criteria.sh" || fail "exit criteria do not verify the guest runner aggregate"
grep -q '/sys/fs/cgroup/actions.slice/memory.max' "$REPO_ROOT/docs/verify-exit-criteria.sh" || fail "exit criteria do not read the live guest actions.slice ceiling"

# A rehearsal must not poll the still-active real service after simulating its
# stop request; dry-run should expose the plan immediately.
mkdir -p "$STUB/active-bin"
mkdir -p "$STUB/cgroup\\x2d"
: > "$STUB/cgroup\\x2d/memory.reclaim"
: > "$STUB/cgroup\\x2d/cgroup.procs"
cat > "$STUB/active-bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in *is-active*) printf 'active\n' ;; esac
EOF
chmod +x "$STUB/active-bin/systemctl"
dry_started=$(date +%s)
REPAIR_DRY_RUN=1 \
  REPAIR_LOG_FILE="$STUB/repair-dry-fast.log" REPAIR_MEMINFO_FILE="$STUB/meminfo" REPAIR_PSI_FILE="$STUB/psi" \
  REPAIR_QEMU_CGROUP="$STUB/cgroup\\x2d" REPAIR_QEMU_CGROUP_VERIFIED=1 REPAIR_ALLOW_NONROOT=1 \
  REPAIR_ADMISSION_POLL_SECONDS=3 REPAIR_LIMACTL_BIN="$STUB/limactl\\x2d" PATH="$STUB/active-bin:$STUB:$PATH" "$REPAIR" >/dev/null
[ $(( $(date +%s) - dry_started )) -lt 2 ] || fail "repair dry-run waited for live admission state"
jq -e . "$STUB/repair-dry-fast.log" >/dev/null || fail "repair structured log is invalid JSON for escaped cgroup paths"

# Empty/untrusted QEMU discovery must never construct or write /memory.reclaim.
REPAIR_TRACE="$STUB/trace-empty" REPAIR_SYSTEMCTL_ARGS="$STUB/systemctl-empty.args" REPAIR_DOCKER_HOST_CAPTURE="$STUB/docker-empty-host" REPAIR_LIMACTL_HOME_CAPTURE="$STUB/limactl-empty-home" \
  REPAIR_DRY_RUN=0 REPAIR_QEMU_PID=999999 REPAIR_QEMU_CGROUP= \
  REPAIR_LOG_FILE="$STUB/repair-empty-qemu.log" REPAIR_MEMINFO_FILE="$STUB/meminfo" REPAIR_PSI_FILE="$STUB/psi" \
  REPAIR_LIMACTL_BIN="$STUB/limactl" REPAIR_USER="$USER" REPAIR_USER_HOME="$HOME" \
  REPAIR_ALLOW_NONROOT=1 REPAIR_VERIFY_WAIT_SECONDS=0 PATH="$STUB:$PATH" "$REPAIR" >/dev/null || true
grep -q 'no verified live QEMU cgroup' "$STUB/repair-empty-qemu.log" || fail "empty QEMU discovery was not fail-closed"
! grep -q '/memory.reclaim' "$STUB/repair-empty-qemu.log" || fail "empty QEMU discovery attempted root memory.reclaim"

# Both explicit recovery thresholds must be met; a high MemAvailable and
# PSI exactly at the limit is a successful verification.
printf 'MemAvailable: 8388608 kB\n' > "$STUB/meminfo-good"
printf 'some avg10=20 avg60=20 avg300=20 total=1\n' > "$STUB/psi-good"
REPAIR_TRACE="$STUB/trace-good" REPAIR_SYSTEMCTL_ARGS="$STUB/systemctl-good.args" REPAIR_DOCKER_HOST_CAPTURE="$STUB/docker-good-host" REPAIR_LIMACTL_HOME_CAPTURE="$STUB/limactl-good-home" \
  REPAIR_DRY_RUN=0 REPAIR_QEMU_PID=999999 REPAIR_QEMU_CGROUP= \
  REPAIR_LOG_FILE="$STUB/repair-good.log" REPAIR_MEMINFO_FILE="$STUB/meminfo-good" REPAIR_PSI_FILE="$STUB/psi-good" \
  REPAIR_LIMACTL_BIN="$STUB/limactl" REPAIR_USER="$USER" REPAIR_USER_HOME="$HOME" \
  REPAIR_ALLOW_NONROOT=1 REPAIR_VERIFY_WAIT_SECONDS=0 PATH="$STUB:$PATH" "$REPAIR" >/dev/null
grep -q '"stage":"verify","status":"improved"' "$STUB/repair-good.log" || fail "repair did not require and recognize both recovery thresholds"

# An earlier admission timeout is degraded but must not override a later
# verified recovery result.
REPAIR_TRACE="$STUB/trace-degraded" REPAIR_SYSTEMCTL_ARGS="$STUB/systemctl-degraded.args" \
  REPAIR_DOCKER_HOST_CAPTURE="$STUB/docker-degraded-host" REPAIR_LIMACTL_HOME_CAPTURE="$STUB/limactl-degraded-home" \
  REPAIR_ADMISSION_FORCE_DEGRADED=1 REPAIR_DRY_RUN=0 REPAIR_QEMU_PID=999999 REPAIR_QEMU_CGROUP= \
  REPAIR_LOG_FILE="$STUB/repair-degraded.log" REPAIR_MEMINFO_FILE="$STUB/meminfo-good" REPAIR_PSI_FILE="$STUB/psi-good" \
  REPAIR_LIMACTL_BIN="$STUB/limactl" REPAIR_USER="$USER" REPAIR_USER_HOME="$HOME" REPAIR_ALLOW_NONROOT=1 \
  REPAIR_VERIFY_WINDOW_SECONDS=0 REPAIR_VERIFY_INTERVAL_SECONDS=0 PATH="$STUB:$PATH" "$REPAIR" >/dev/null
grep -q '"stage":"result","status":"recovered"' "$STUB/repair-degraded.log" || fail "degraded admission incorrectly overrode verified recovery"

# PSI avg10 may still be high immediately after shedding. A short injected
# sequence proves the verifier waits for a later low-PSI sample instead of
# deciding VM shutdown from the first one-second read.
printf '40 100\n40 100\n20 100\n' > "$STUB/psi-sequence"
REPAIR_TRACE="$STUB/trace-sequence" REPAIR_SYSTEMCTL_ARGS="$STUB/systemctl-sequence.args" \
  REPAIR_DOCKER_HOST_CAPTURE="$STUB/docker-sequence-host" REPAIR_LIMACTL_HOME_CAPTURE="$STUB/limactl-sequence-home" \
  REPAIR_DRY_RUN=0 REPAIR_QEMU_PID=999999 REPAIR_QEMU_CGROUP= REPAIR_PSI_SEQUENCE_FILE="$STUB/psi-sequence" \
  REPAIR_LOG_FILE="$STUB/repair-sequence.log" REPAIR_MEMINFO_FILE="$STUB/meminfo-good" REPAIR_PSI_FILE="$STUB/psi-good" \
  REPAIR_LIMACTL_BIN="$STUB/limactl" REPAIR_USER="$USER" REPAIR_USER_HOME="$HOME" REPAIR_ALLOW_NONROOT=1 \
  REPAIR_VERIFY_WINDOW_SECONDS=3 REPAIR_VERIFY_INTERVAL_SECONDS=0 PATH="$STUB:$PATH" "$REPAIR" >/dev/null
grep -q '"stage":"verify","status":"improved"' "$STUB/repair-sequence.log" || fail "repair did not wait for initially high PSI to recover"
ok "watchdog repair ordering and bounded controls"

echo "HOST_CONTROL_ARTIFACTS_TEST: PASS"
