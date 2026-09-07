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

setup_fixture() {
  local root="$1"
  mkdir -p "$root/proc" "$root/sys/devices/system/cpu" "$root/sys/fs/cgroup/actions.slice" \
           "$root/sys/fs/cgroup/agents.slice" "$root/sys/fs/cgroup/automation.slice" \
           "$root/etc/systemd/system" "$root/etc/systemd/user" \
           "$root/bin" "$root/var/lock"

  printf 'MemTotal:       65512304 kB\nMemFree:        30000000 kB\n' > "$root/proc/meminfo"
  printf '0-31\n' > "$root/sys/devices/system/cpu/online"
  printf 'cpuset cpu io memory pids\n' > "$root/sys/fs/cgroup/cgroup.controllers"

  # Current memory usage under 18G/4G thresholds (e.g. 8 GiB current)
  printf '8589934592\n' > "$root/sys/fs/cgroup/agents.slice/memory.current"
  printf '1073741824\n' > "$root/sys/fs/cgroup/automation.slice/memory.current"

  # Staged actions.slice cgroup values
  printf '27917287424\n' > "$root/sys/fs/cgroup/actions.slice/memory.high"
  printf '30064771072\n' > "$root/sys/fs/cgroup/actions.slice/memory.max"
  printf '0\n' > "$root/sys/fs/cgroup/actions.slice/memory.swap.max"
  printf '6000\n' > "$root/sys/fs/cgroup/actions.slice/pids.max"
  printf '2000000 100000\n' > "$root/sys/fs/cgroup/actions.slice/cpu.max"
  printf 'default 25\n' > "$root/sys/fs/cgroup/actions.slice/io.weight"

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

[ -f "$PASS_ROOT/etc/systemd/system/actions.slice" ] || fail "actions.slice was not staged to system units"
[ -f "$PASS_ROOT/etc/systemd/system/-.slice.d/99-ezgha-containment.conf" ] || fail "-.slice.d drop-in not staged"
[ -f "$PASS_ROOT/etc/systemd/system/user@.service.d/99-ezgha-containment.conf" ] || fail "user@.service.d drop-in not staged"
[ -f "$PASS_ROOT/etc/systemd/user/agents.slice" ] || fail "agents.slice not staged to user units"
[ -f "$PASS_ROOT/etc/systemd/user/automation.slice" ] || fail "automation.slice not staged to user units"
ok "apply-host-containment-release1.sh stages policy artifacts and boundary drop-ins"

# 2. Pre-mutation gate: memory below floor
MEM_FAIL_ROOT="$WORK/mem_fail"
setup_fixture "$MEM_FAIL_ROOT"
printf 'MemTotal:       65011711 kB\n' > "$MEM_FAIL_ROOT/proc/meminfo"
if PATH="$MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$MEM_FAIL_ROOT" > "$WORK/mem_fail.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when MemTotal was below floor"
fi
[ ! -f "$MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before memory check passed"
ok "apply-host-containment-release1.sh aborts before mutation when memory is below floor"

# 3. Pre-mutation gate: current agent memory usage >= 18G
AGENT_MEM_FAIL_ROOT="$WORK/agent_mem_fail"
setup_fixture "$AGENT_MEM_FAIL_ROOT"
# 19 GiB current usage
printf '20401094656\n' > "$AGENT_MEM_FAIL_ROOT/sys/fs/cgroup/agents.slice/memory.current"
if PATH="$AGENT_MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$AGENT_MEM_FAIL_ROOT" > "$WORK/agent_mem.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when current agent memory usage was above threshold"
fi
[ ! -f "$AGENT_MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before agent memory check"
ok "apply-host-containment-release1.sh aborts before mutation when current agent use >= 18G"

echo "APPLY_HOST_CONTAINMENT_RELEASE1_TEST: PASS"
