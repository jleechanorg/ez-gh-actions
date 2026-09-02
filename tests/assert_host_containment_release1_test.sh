#!/usr/bin/env bash
# Regression tests for the read-only host containment assertion script.
# Validates assert-host-containment-release1.sh behavior across hermetic fixture roots.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSERT_SCRIPT="$REPO_ROOT/scripts/host/assert-host-containment-release1.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

[ -f "$ASSERT_SCRIPT" ] || fail "missing required script: scripts/host/assert-host-containment-release1.sh"
[ -x "$ASSERT_SCRIPT" ] || fail "script is not executable: scripts/host/assert-host-containment-release1.sh"
bash -n "$ASSERT_SCRIPT" || fail "syntax error in scripts/host/assert-host-containment-release1.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

setup_passing_fixture() {
  local root="$1"
  mkdir -p "$root/proc" "$root/sys/devices/system/cpu" "$root/sys/fs/cgroup/actions.slice" \
           "$root/etc/systemd/system/-.slice.d" \
           "$root/etc/systemd/system/user.slice.d" \
           "$root/etc/systemd/system/user-.slice.d" \
           "$root/etc/systemd/system/user@.service.d" \
           "$root/etc/systemd/user/app.slice.d" \
           "$root/etc/systemd/user/session.slice.d" \
           "$root/etc/systemd/user" \
           "$root/bin" "$root/state"

  # Host memory floor (65,011,712 KiB = 62 GiB floor)
  printf 'MemTotal:       65512304 kB\nMemFree:        30000000 kB\n' > "$root/proc/meminfo"
  # Online CPUs (32 online CPUs)
  printf '0-31\n' > "$root/sys/devices/system/cpu/online"
  # cgroup v2 controllers
  printf 'cpuset cpu io memory pids\n' > "$root/sys/fs/cgroup/cgroup.controllers"

  # actions.slice cgroup limits
  printf '27917287424\n' > "$root/sys/fs/cgroup/actions.slice/memory.high"
  printf '30064771072\n' > "$root/sys/fs/cgroup/actions.slice/memory.max"
  printf '0\n' > "$root/sys/fs/cgroup/actions.slice/memory.swap.max"
  printf '6000\n' > "$root/sys/fs/cgroup/actions.slice/pids.max"
  printf '2000000 100000\n' > "$root/sys/fs/cgroup/actions.slice/cpu.max"
  printf 'default 25\n' > "$root/sys/fs/cgroup/actions.slice/io.weight"

  # Boundary drop-ins
  for d in "$root/etc/systemd/system/-.slice.d" \
           "$root/etc/systemd/system/user.slice.d" \
           "$root/etc/systemd/system/user-.slice.d" \
           "$root/etc/systemd/user/app.slice.d" \
           "$root/etc/systemd/user/session.slice.d"; do
    printf '[Slice]\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\n' > "$d/99-ezgha-containment.conf"
  done
  printf '[Service]\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\nManagedOOMPreference=none\nOOMScoreAdjust=0\n' \
    > "$root/etc/systemd/system/user@.service.d/99-ezgha-containment.conf"

  # agents.slice and automation.slice in user units
  printf '[Slice]\nMemoryHigh=18G\nMemoryMax=20G\nMemorySwapMax=2G\nTasksMax=8192\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\n' \
    > "$root/etc/systemd/user/agents.slice"
  printf '[Slice]\nMemoryHigh=4G\nMemoryMax=6G\nMemorySwapMax=1G\nTasksMax=4096\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\n' \
    > "$root/etc/systemd/user/automation.slice"

  # Mock docker command
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

  # Mock /proc/<pid>/cgroup for each container PID
  for i in $(seq 1 10); do
    local pid=$((10000 + i))
    mkdir -p "$root/proc/$pid"
    printf "0::/actions.slice/docker-cid%02d.scope\n" "$i" > "$root/proc/$pid/cgroup"
  done
}

# 1. Test clean passing fixture
FIXTURE_PASS="$WORK/pass"
setup_passing_fixture "$FIXTURE_PASS"
PATH="$FIXTURE_PASS/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" || fail "passing fixture failed assertion"
ok "assert-host-containment-release1.sh passes valid fixture"

# 2. Test memory below floor (65,011,711 KiB)
FIXTURE_MEM_FAIL="$WORK/mem_fail"
setup_passing_fixture "$FIXTURE_MEM_FAIL"
printf 'MemTotal:       65011711 kB\n' > "$FIXTURE_MEM_FAIL/proc/meminfo"
if PATH="$FIXTURE_MEM_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_FAIL" > "$WORK/mem_fail.log" 2>&1; then
  fail "assertion passed when MemTotal was below floor"
fi
grep -q "FAIL: host MemTotal" "$WORK/mem_fail.log" || fail "missing expected MemTotal failure message"
ok "assert-host-containment-release1.sh rejects memory below 62 GiB floor"

# 3. Test online CPUs below floor (31 online CPUs)
FIXTURE_CPU_FAIL="$WORK/cpu_fail"
setup_passing_fixture "$FIXTURE_CPU_FAIL"
printf '0-30\n' > "$FIXTURE_CPU_FAIL/sys/devices/system/cpu/online"
if PATH="$FIXTURE_CPU_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_CPU_FAIL" > "$WORK/cpu_fail.log" 2>&1; then
  fail "assertion passed when online CPUs was 31 (< 32)"
fi
grep -q "FAIL: host online logical CPUs" "$WORK/cpu_fail.log" || fail "missing expected CPU count failure message"
ok "assert-host-containment-release1.sh rejects fewer than 32 online CPUs"

# 4. Test missing controller (missing memory controller)
FIXTURE_CTRL_FAIL="$WORK/ctrl_fail"
setup_passing_fixture "$FIXTURE_CTRL_FAIL"
printf 'cpuset cpu io pids\n' > "$FIXTURE_CTRL_FAIL/sys/fs/cgroup/cgroup.controllers"
if PATH="$FIXTURE_CTRL_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_CTRL_FAIL" > "$WORK/ctrl_fail.log" 2>&1; then
  fail "assertion passed when memory controller was missing"
fi
grep -q "FAIL: cgroup.controllers missing required controller" "$WORK/ctrl_fail.log" || fail "missing controller failure message"
ok "assert-host-containment-release1.sh rejects missing cgroup controller"

# 5. Test invalid actions.slice memory limit (e.g. max or 32G)
FIXTURE_SLICE_FAIL="$WORK/slice_fail"
setup_passing_fixture "$FIXTURE_SLICE_FAIL"
printf 'max\n' > "$FIXTURE_SLICE_FAIL/sys/fs/cgroup/actions.slice/memory.max"
if PATH="$FIXTURE_SLICE_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_SLICE_FAIL" > "$WORK/slice_fail.log" 2>&1; then
  fail "assertion passed when actions.slice memory.max was infinite"
fi
grep -q "FAIL: actions.slice memory.max" "$WORK/slice_fail.log" || fail "missing actions.slice memory.max failure message"
ok "assert-host-containment-release1.sh rejects infinite actions.slice memory"

# 6. Test wrong runner container count (9 containers instead of 10)
FIXTURE_COUNT_FAIL="$WORK/count_fail"
setup_passing_fixture "$FIXTURE_COUNT_FAIL"
cat > "$FIXTURE_COUNT_FAIL/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  printf 'CgroupVersion: 2\nCgroupDriver: systemd\n'
elif [ "$1" = "ps" ]; then
  for i in $(seq 1 9); do
    printf "cid%02d ez-runner-c-%d %d\n" "$i" "$i" "$((10000 + i))"
  done
fi
DOCKER_EOF
chmod +x "$FIXTURE_COUNT_FAIL/bin/docker"
if PATH="$FIXTURE_COUNT_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_COUNT_FAIL" > "$WORK/count_fail.log" 2>&1; then
  fail "assertion passed when runner container count was 9"
fi
grep -q "FAIL: runner container count" "$WORK/count_fail.log" || fail "missing runner count failure message"
ok "assert-host-containment-release1.sh rejects container count != 10"

# 7. Test PID not in actions.slice ancestry
FIXTURE_ANCESTRY_FAIL="$WORK/ancestry_fail"
setup_passing_fixture "$FIXTURE_ANCESTRY_FAIL"
printf "0::/user.slice/user-1000.slice/docker-cid01.scope\n" > "$FIXTURE_ANCESTRY_FAIL/proc/10001/cgroup"
if PATH="$FIXTURE_ANCESTRY_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_ANCESTRY_FAIL" > "$WORK/ancestry_fail.log" 2>&1; then
  fail "assertion passed when container PID was not in /actions.slice"
fi
grep -q "FAIL: container PID not beneath /actions.slice" "$WORK/ancestry_fail.log" || fail "missing ancestry failure message"
ok "assert-host-containment-release1.sh rejects runner container outside actions.slice"

echo "ASSERT_HOST_CONTAINMENT_RELEASE1_TEST: PASS"
