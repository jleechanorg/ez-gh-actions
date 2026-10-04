#!/usr/bin/env bash
# Regression tests for scripts/host/apply-host-containment-release1.sh
# Tests atomic activation, file staging, pre-mutation gates, and convergence across fixture roots.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY_SCRIPT="$REPO_ROOT/scripts/host/apply-host-containment-release1.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

[ -f "$APPLY_SCRIPT" ] || fail "missing required script: scripts/host/apply-host-containment-release1.sh"
[ -x "$APPLY_SCRIPT" ] || fail "script is not executable: scripts/host/apply-host-containment-release1.sh"
bash -n "$APPLY_SCRIPT" || fail "syntax error in scripts/host/apply-host-containment-release1.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
grep -q -- '--runner-count' "$APPLY_SCRIPT" || fail "apply script does not expose the bounded runner-count selector"
grep -q 'TasksMax=8000' "$APPLY_SCRIPT" || fail "apply script does not render the 14-runner TasksMax=8000 profile"
grep -q 'TasksMax=6000' "$APPLY_SCRIPT" || fail "apply script does not retain the 10-runner TasksMax=6000 rollback profile"

setup_fixture() {
  local root="$1" runner_count="${2:-14}" pids_max
  case "$runner_count" in
    10) pids_max=6000 ;;
    14) pids_max=8000 ;;
    *) fail "test fixture does not support runner count $runner_count" ;;
  esac
  mkdir -p "$root/proc" "$root/sys/devices/system/cpu" "$root/sys/fs/cgroup/actions.slice" \
           "$root/sys/fs/cgroup/agents.slice" "$root/sys/fs/cgroup/automation.slice" \
           "$root/sys/fs/cgroup/app-lima-vm.slice" "$root/sys/fs/cgroup/lima-vm@colima.service" \
           "$root/etc/systemd/system" "$root/etc/systemd/user" \
           "$root/bin" "$root/var/lock"

  printf 'MemTotal:       65512304 kB\nMemFree:        30000000 kB\n' > "$root/proc/meminfo"
  printf '0-31\n' > "$root/sys/devices/system/cpu/online"
  printf 'cpuset cpu io memory pids\n' > "$root/sys/fs/cgroup/cgroup.controllers"

  # Current memory usage under 10G/4.5G/9G thresholds (e.g. safe current)
  printf '8589934592\n' > "$root/sys/fs/cgroup/agents.slice/memory.current"
  printf '1073741824\n' > "$root/sys/fs/cgroup/automation.slice/memory.current"
  printf '1073741824\n' > "$root/sys/fs/cgroup/app-lima-vm.slice/memory.current"
  printf '1073741824\n' > "$root/sys/fs/cgroup/lima-vm@colima.service/memory.current"

  # Staged actions.slice cgroup values
  printf '27917287424\n' > "$root/sys/fs/cgroup/actions.slice/memory.high"
  printf '30064771072\n' > "$root/sys/fs/cgroup/actions.slice/memory.max"
  printf '0\n' > "$root/sys/fs/cgroup/actions.slice/memory.swap.max"
  printf '%s\n' "$pids_max" > "$root/sys/fs/cgroup/actions.slice/pids.max"
  printf '2000000 100000\n' > "$root/sys/fs/cgroup/actions.slice/cpu.max"
  printf 'default 25\n' > "$root/sys/fs/cgroup/actions.slice/io.weight"
  printf '8589934592\n' > "$root/sys/fs/cgroup/actions.slice/memory.current"
  printf '100\n' > "$root/sys/fs/cgroup/actions.slice/pids.current"

  cat > "$root/bin/systemctl" <<'SYS_EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
SYS_EOF
  chmod +x "$root/bin/systemctl"

  cat > "$root/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  printf 'CgroupVersion: 2\nCgroupDriver: systemd\n'
elif [ "$1" = "ps" ]; then
  for i in $(seq 1 10); do
    printf "cid%02d ez-runner-c-%d %d\n" "$i" "$i" "$((10000 + i))"
  done
fi
DOCKER_EOF
  chmod +x "$root/bin/docker"

  for i in $(seq 1 10); do
    local pid=$((10000 + i))
    mkdir -p "$root/proc/$pid"
    printf "0::/actions.slice/docker-cid%02d.scope\n" "$i" > "$root/proc/$pid/cgroup"
  done
}

# 1. Test clean application
PASS_ROOT="$WORK/pass"
setup_fixture "$PASS_ROOT"
SYSTEMCTL_LOG="$WORK/pass_sys.log" PATH="$PASS_ROOT/bin:$PATH" \
  "$APPLY_SCRIPT" --root "$PASS_ROOT" || fail "apply-host-containment-release1.sh failed on clean fixture"

ROLLBACK_ROOT="$WORK/rollback"
setup_fixture "$ROLLBACK_ROOT" 10
SYSTEMCTL_LOG="$WORK/rollback_sys.log" PATH="$ROLLBACK_ROOT/bin:$PATH" \
  "$APPLY_SCRIPT" --root "$ROLLBACK_ROOT" --runner-count 10 \
  || fail "apply-host-containment-release1.sh failed for explicit 10-runner rollback"
ok "apply-host-containment-release1.sh applies the explicit 10-runner rollback profile"
INVALID_ROOT="$WORK/invalid"
setup_fixture "$INVALID_ROOT"
if PATH="$INVALID_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$INVALID_ROOT" --runner-count 12 > "$WORK/invalid.log" 2>&1; then
  fail "apply-host-containment-release1.sh accepted unsupported runner count 12"
fi
[ ! -f "$INVALID_ROOT/etc/systemd/system/actions.slice" ] || fail "invalid runner count mutated the fixture before failing"
ok "apply-host-containment-release1.sh rejects invalid runner count before writes"

[ -f "$PASS_ROOT/etc/systemd/system/actions.slice" ] || fail "actions.slice was not staged to system units"
[ -f "$PASS_ROOT/etc/systemd/system/-.slice.d/99-ezgha-containment.conf" ] || fail "-.slice.d drop-in not staged"
[ -f "$PASS_ROOT/etc/systemd/system/user@.service.d/99-ezgha-containment.conf" ] || fail "user@.service.d drop-in not staged"
[ -f "$PASS_ROOT/etc/systemd/user/agents.slice" ] || fail "agents.slice not staged to user units"
[ -f "$PASS_ROOT/etc/systemd/user/automation.slice" ] || fail "automation.slice not staged to user units"
[ -f "$PASS_ROOT/etc/systemd/user/app-lima-vm.slice" ] || fail "app-lima-vm.slice not staged to user units"
[ -f "$PASS_ROOT/etc/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" ] || fail "QEMU service drop-in not staged to user units"
ok "apply-host-containment-release1.sh stages policy artifacts and boundary drop-ins"

# Verify [Install] produces persistent boot wiring without touching the host unit graph.
HOST_SYSTEMCTL="$(PATH=/usr/sbin:/usr/bin:/sbin:/bin command -v systemctl || true)"
if [ -n "$HOST_SYSTEMCTL" ]; then
  "$HOST_SYSTEMCTL" --root "$PASS_ROOT" enable actions.slice \
    || fail "staged actions.slice could not be enabled in isolated fixture root"
  boot_link="$PASS_ROOT/etc/systemd/system/slices.target.wants/actions.slice"
  [ -L "$boot_link" ] || fail "actions.slice enable did not create slices.target boot link"
  boot_target="$(readlink "$boot_link")"
  [ "$PASS_ROOT$boot_target" = "$PASS_ROOT/etc/systemd/system/actions.slice" ] \
    || fail "actions.slice boot link does not resolve to the staged unit"
  ok "actions.slice enable creates isolated persistent slices.target boot wiring"
fi

# 2. Pre-mutation gate: memory below computed floor
MEM_FAIL_ROOT="$WORK/mem_fail"
setup_fixture "$MEM_FAIL_ROOT"
printf 'MemTotal:       64079643 kB\n' > "$MEM_FAIL_ROOT/proc/meminfo"
if PATH="$MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$MEM_FAIL_ROOT" > "$WORK/mem_fail.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when MemTotal was below computed floor"
fi
[ ! -f "$MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before memory check passed"
ok "apply-host-containment-release1.sh aborts before mutation when memory is below floor"

MEM_BOUNDARY_ROOT="$WORK/mem_boundary"
setup_fixture "$MEM_BOUNDARY_ROOT"
printf 'MemTotal:       64079644 kB\n' > "$MEM_BOUNDARY_ROOT/proc/meminfo"
PATH="$MEM_BOUNDARY_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$MEM_BOUNDARY_ROOT" > "$WORK/mem_boundary.log" 2>&1   || fail "apply-host-containment-release1.sh failed when MemTotal was at exact computed floor"
ok "apply-host-containment-release1.sh succeeds when memory is at exact computed floor"

# 3. Pre-mutation gate: current agent memory usage >= 10G
AGENT_MEM_FAIL_ROOT="$WORK/agent_mem_fail"
setup_fixture "$AGENT_MEM_FAIL_ROOT"
# 10 GiB current usage
printf '10737418240\n' > "$AGENT_MEM_FAIL_ROOT/sys/fs/cgroup/agents.slice/memory.current"
if PATH="$AGENT_MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$AGENT_MEM_FAIL_ROOT" > "$WORK/agent_mem.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when current agent memory usage was at high limit"
fi
[ ! -f "$AGENT_MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before agent memory check"
ok "apply-host-containment-release1.sh aborts before mutation when current agent use >= 10G"

# 3b. Pre-mutation gate: current automation memory usage >= 4.5G
AUTO_MEM_FAIL_ROOT="$WORK/auto_mem_fail"
setup_fixture "$AUTO_MEM_FAIL_ROOT"
# 4.5 GiB current usage (4608M = 4831838208 bytes)
printf '4831838208\n' > "$AUTO_MEM_FAIL_ROOT/sys/fs/cgroup/automation.slice/memory.current"
if PATH="$AUTO_MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$AUTO_MEM_FAIL_ROOT" > "$WORK/auto_mem.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when current automation memory usage was at high limit"
fi
[ ! -f "$AUTO_MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before automation memory check"
ok "apply-host-containment-release1.sh aborts before mutation when current automation use >= 4.5G"

# 3c. Pre-mutation gate: current QEMU memory usage >= 9G (proof of highusage no writes)
QEMU_MEM_FAIL_ROOT="$WORK/qemu_mem_fail"
setup_fixture "$QEMU_MEM_FAIL_ROOT"
mkdir -p "$QEMU_MEM_FAIL_ROOT/sys/fs/cgroup/lima-vm@colima.service"
# 9 GiB current usage
printf '9663676416\n' > "$QEMU_MEM_FAIL_ROOT/sys/fs/cgroup/lima-vm@colima.service/memory.current"
if PATH="$QEMU_MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$QEMU_MEM_FAIL_ROOT" > "$WORK/qemu_mem.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when current QEMU memory usage was at high limit"
fi
[ ! -f "$QEMU_MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before QEMU memory check"
[ ! -f "$QEMU_MEM_FAIL_ROOT/etc/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" ] || fail "wrote drop-in when QEMU memory was at high limit"
ok "apply-host-containment-release1.sh aborts before mutation when current QEMU use >= 9G (proof highusage no writes)"

# 3d. Pre-mutation gate: missing/unreadable current usage refusal for active service
QEMU_UNREADABLE_ROOT="$WORK/qemu_unreadable"
setup_fixture "$QEMU_UNREADABLE_ROOT"
# Active cgroup directory exists but memory.current is missing
rm -f "$QEMU_UNREADABLE_ROOT/sys/fs/cgroup/lima-vm@colima.service/memory.current"
if CONTAINMENT_ACTIVE_UNITS="lima-vm@colima.service" PATH="$QEMU_UNREADABLE_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$QEMU_UNREADABLE_ROOT" > "$WORK/qemu_unreadable.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when active QEMU service lacked memory.current"
fi
[ ! -f "$QEMU_UNREADABLE_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files when active QEMU service memory.current was missing"
[ ! -f "$QEMU_UNREADABLE_ROOT/etc/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf" ] || fail "wrote dropin when active QEMU memory.current missing"
ok "apply-host-containment-release1.sh refuses activation when active service memory.current is missing/unreadable"

# 4. Pre-mutation gate: do not lower actions.slice beneath live use.
ACTIONS_MEM_FAIL_ROOT="$WORK/actions_mem_fail"
setup_fixture "$ACTIONS_MEM_FAIL_ROOT"
printf '27917287424\n' > "$ACTIONS_MEM_FAIL_ROOT/sys/fs/cgroup/actions.slice/memory.current"
if PATH="$ACTIONS_MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$ACTIONS_MEM_FAIL_ROOT" > "$WORK/actions_mem.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when actions usage was at the new high limit"
fi
[ ! -f "$ACTIONS_MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before actions usage gate"
ok "apply-host-containment-release1.sh aborts before lowering actions.slice beneath live use"

# Live user-systemd branch (normally only when --root is /): run it against a
# fixture with CONTAINMENT_LIVE_SYSTEMD=1 and check the persistent
# set-property calls replace any older automation.slice limits.
LIVE_ROOT="$WORK/live"
setup_fixture "$LIVE_ROOT"
# The apply script finishes by running the assert script, whose live branch
# queries properties: log every call and answer `show` with what the
# set-property calls in the live branch establish.
uid="$(id -u)"
cat > "$WORK/live_props.txt" <<PROPS
agents.slice ActiveState active
automation.slice ActiveState active
app-lima-vm.slice ActiveState active
actions.slice ManagedOOMMemoryPressure auto
actions.slice ManagedOOMSwap auto
lima-vm@colima.service ActiveState active
agents.slice MemoryHigh 10737418240
agents.slice MemoryMax 12884901888
agents.slice MemorySwapMax 2147483648
agents.slice TasksMax 8192
agents.slice ManagedOOMMemoryPressure auto
agents.slice ManagedOOMSwap auto
automation.slice MemoryHigh 4831838208
automation.slice MemoryMax 5368709120
automation.slice MemorySwapMax 1073741824
automation.slice TasksMax 4096
automation.slice ManagedOOMMemoryPressure auto
automation.slice ManagedOOMSwap auto
lima-vm@colima.service MemoryHigh 9663676416
lima-vm@colima.service MemoryMax 10737418240
lima-vm@colima.service MemorySwapMax 2147483648
lima-vm@colima.service TasksMax 4096
lima-vm@colima.service CPUQuotaPerSecUSec 16s
lima-vm@colima.service CPUQuota 1600%
user@${uid}.service ManagedOOMMemoryPressure auto
user@${uid}.service ManagedOOMSwap auto
user@${uid}.service ManagedOOMPreference none
user@${uid}.service OOMScoreAdjust 0
-.slice ManagedOOMMemoryPressure auto
-.slice ManagedOOMSwap auto
user.slice ManagedOOMMemoryPressure auto
user.slice ManagedOOMSwap auto
app.slice ManagedOOMMemoryPressure auto
app.slice ManagedOOMSwap auto
session.slice ManagedOOMMemoryPressure auto
session.slice ManagedOOMSwap auto
PROPS
cat > "$LIVE_ROOT/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "${SYSTEMCTL_LOG:-/dev/null}"
[ "${QUERY_FAIL:-0}" = 0 ] || exit 1
prop="" unit="" show=0
for a in "$@"; do [ "$a" = show ] && show=1; done
[ "$show" = 1 ] || exit 0
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prop="$2"; shift 2 ;;
    --) unit="$2"; shift 2 ;;
    --*) shift ;;
    show|--user) shift ;;
    *) unit="$1"; shift ;;
  esac
done
awk -v u="$unit" -v p="$prop" '$1==u && $2==p {print $3; found=1} END {exit !found}' "$SYSTEMD_PROPS"
SHIM
chmod +x "$LIVE_ROOT/bin/systemctl"
CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/live_props.txt" SYSTEMCTL_LOG="$WORK/live_sys.log" PATH="$LIVE_ROOT/bin:$PATH" \
  "$APPLY_SCRIPT" --root "$LIVE_ROOT" > "$WORK/live.log" 2>&1 || fail "live-systemd apply failed: $(tail -3 "$WORK/live.log")"
grep -qx "systemctl --user set-property automation.slice MemoryHigh=4608M MemoryMax=5G MemorySwapMax=1G TasksMax=4096" "$WORK/live_sys.log" \
  || fail "live apply did not set automation.slice to 4608M/5G: $(grep automation "$WORK/live_sys.log" || echo none)"
grep -qx "systemctl --user set-property agents.slice MemoryHigh=10G MemoryMax=12G MemorySwapMax=2G TasksMax=8192" "$WORK/live_sys.log" \
  || fail "live apply did not set agents.slice limits"
ok "apply-host-containment-release1.sh live branch persists automation.slice 4608M/5G via set-property"

QUERY_ROOT="$WORK/query_failure"
setup_fixture "$QUERY_ROOT"
cp "$LIVE_ROOT/bin/systemctl" "$QUERY_ROOT/bin/systemctl"
if QUERY_FAIL=1 CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMCTL_LOG="$WORK/query.log" PATH="$QUERY_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$QUERY_ROOT" > "$WORK/query.out" 2>&1; then
  fail "failed ActiveState query accepted"
fi
[ ! -f "$QUERY_ROOT/etc/systemd/system/actions.slice" ] || fail "failed query wrote policy"
if grep -q set-property "$WORK/query.log"; then fail "failed query wrote limits"; fi
grep -q 'cannot query agents.slice ActiveState' "$WORK/query.out" || fail "query failure did not reach intended gate"
echo "APPLY_HOST_CONTAINMENT_RELEASE1_TEST: PASS"
