#!/usr/bin/env bash
# Static structural regression test for Release 1 finite host containment policy artifacts.
# This test is shell-only and never modifies, starts, or stops host units or services.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

assert_file() { [ -f "$1" ] || fail "missing required artifact: $1"; }
assert_not_file() { [ ! -e "$1" ] || fail "forbidden artifact must not exist: $1"; }
assert_line() {
  local file="$1" line="$2"
  grep -Fqx "$line" "$file" || fail "$file missing exact line: $line"
}

# 1. System actions.slice finite policy
ACTIONS_SLICE="$REPO_ROOT/systemd/host/actions.slice"
assert_file "$ACTIONS_SLICE"
assert_line "$ACTIONS_SLICE" "[Slice]"
assert_line "$ACTIONS_SLICE" "MemoryHigh=26G"
assert_line "$ACTIONS_SLICE" "MemoryMax=28G"
assert_line "$ACTIONS_SLICE" "MemorySwapMax=0"
assert_line "$ACTIONS_SLICE" "TasksMax=6000"
assert_line "$ACTIONS_SLICE" "CPUQuota=2000%"
assert_line "$ACTIONS_SLICE" "IOWeight=25"
assert_line "$ACTIONS_SLICE" "ManagedOOMMemoryPressure=auto"
assert_line "$ACTIONS_SLICE" "ManagedOOMSwap=auto"
ok "systemd/host/actions.slice finite boundary and auto OOM policies"

# 2. User workload slices
AGENTS_SLICE="$REPO_ROOT/systemd/agents.slice"
assert_file "$AGENTS_SLICE"
assert_line "$AGENTS_SLICE" "MemoryHigh=18G"
assert_line "$AGENTS_SLICE" "MemoryMax=20G"
assert_line "$AGENTS_SLICE" "MemorySwapMax=2G"
assert_line "$AGENTS_SLICE" "TasksMax=8192"
assert_line "$AGENTS_SLICE" "ManagedOOMMemoryPressure=auto"
assert_line "$AGENTS_SLICE" "ManagedOOMSwap=auto"
grep -q "8.10" "$AGENTS_SLICE" || fail "agents.slice missing documented 8.10 GiB current justification"
grep -q "17.14" "$AGENTS_SLICE" || fail "agents.slice missing documented 17.14 GiB peak justification"
ok "systemd/agents.slice 18G/20G envelope and auto OOM policies"

AUTOMATION_SLICE="$REPO_ROOT/systemd/automation.slice"
assert_file "$AUTOMATION_SLICE"
assert_line "$AUTOMATION_SLICE" "MemoryHigh=4G"
assert_line "$AUTOMATION_SLICE" "MemoryMax=6G"
assert_line "$AUTOMATION_SLICE" "MemorySwapMax=1G"
assert_line "$AUTOMATION_SLICE" "TasksMax=4096"
assert_line "$AUTOMATION_SLICE" "ManagedOOMMemoryPressure=auto"
assert_line "$AUTOMATION_SLICE" "ManagedOOMSwap=auto"
ok "systemd/automation.slice 4G/6G envelope and auto OOM policies"

# 3. Boundary drop-ins (6 tracked drop-ins)
for dropin in \
  "$REPO_ROOT/systemd/host/-.slice.d/99-ezgha-containment.conf" \
  "$REPO_ROOT/systemd/host/user.slice.d/99-ezgha-containment.conf" \
  "$REPO_ROOT/systemd/host/user-.slice.d/99-ezgha-containment.conf" \
  "$REPO_ROOT/systemd/user/app.slice.d/99-ezgha-containment.conf" \
  "$REPO_ROOT/systemd/user/session.slice.d/99-ezgha-containment.conf"; do
  assert_file "$dropin"
  assert_line "$dropin" "ManagedOOMMemoryPressure=auto"
  assert_line "$dropin" "ManagedOOMSwap=auto"
done

USER_SVC_DROPIN="$REPO_ROOT/systemd/host/user@.service.d/99-ezgha-containment.conf"
assert_file "$USER_SVC_DROPIN"
assert_line "$USER_SVC_DROPIN" "ManagedOOMMemoryPressure=auto"
assert_line "$USER_SVC_DROPIN" "ManagedOOMSwap=auto"
assert_line "$USER_SVC_DROPIN" "ManagedOOMPreference=none"
assert_line "$USER_SVC_DROPIN" "OOMScoreAdjust=0"
ok "all six boundary drop-ins present and neutral"

# 4. Config alignment (2500 MiB per runner)
LINUX_EXAMPLE="$REPO_ROOT/config/config.toml.linux.example"
assert_file "$LINUX_EXAMPLE"
grep -q "memory_mb = 2500" "$LINUX_EXAMPLE" || fail "config.toml.linux.example missing 2500 MiB runner memory limit"
ok "config.toml.linux.example aligned to 2500 MiB per runner"

# 5. Absence of forbidden legacy artifacts and escape hatches
assert_not_file "$REPO_ROOT/systemd/ezgha.service.d/10-oomd-omit.conf"
assert_not_file "$REPO_ROOT/systemd/psi-oom-watcher.service"
assert_not_file "$REPO_ROOT/systemd/psi-oom-watcher.timer"
assert_not_file "$REPO_ROOT/scripts/host/psi-oom-watcher.sh"
assert_not_file "$REPO_ROOT/config/config.toml.linux-canary.example"

for launcher in "$REPO_ROOT/scripts/host/agent-scoped-launch.sh" "$REPO_ROOT/scripts/host/agent-cli-scoped.sh"; do
  if [ -f "$launcher" ]; then
    if grep -q "AGENT_SLICE_OPT_OUT" "$launcher"; then
      fail "forbidden AGENT_SLICE_OPT_OUT escape hatch found in $launcher"
    fi
  fi
done
ok "forbidden legacy escape hatches and watcher/exemption units strictly absent"

echo "HOST_CRASH_CONTAINMENT_RELEASE1_ARTIFACTS_TEST: PASS"
