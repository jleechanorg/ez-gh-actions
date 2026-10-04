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
grep -q -- '--runner-count' "$ASSERT_SCRIPT" || fail "assert script does not expose the bounded runner-count selector"
grep -q 'ACTIONS_PIDS_MAX=8000' "$ASSERT_SCRIPT" || fail "assert script does not retain the 14-runner TasksMax=8000 profile"

setup_passing_fixture() {
  local root="$1" runner_count="${2:-14}" pids_max
  case "$runner_count" in
    10) pids_max=6000 ;;
    14) pids_max=8000 ;;
    *) fail "test fixture does not support runner count $runner_count" ;;
  esac
  mkdir -p "$root/proc" "$root/sys/devices/system/cpu" "$root/sys/fs/cgroup/actions.slice" \
           "$root/etc/systemd/system/-.slice.d" \
           "$root/etc/systemd/system/user.slice.d" \
           "$root/etc/systemd/system/user-.slice.d" \
           "$root/etc/systemd/system/user@.service.d" \
           "$root/etc/systemd/user/app.slice.d" \
           "$root/etc/systemd/user/session.slice.d" \
           "$root/etc/systemd/user" \
           "$root/bin" "$root/state"

  printf 'MemTotal:       65512304 kB\nMemFree:        30000000 kB\n' > "$root/proc/meminfo"
  # Online CPUs (32 online CPUs)
  printf '0-31\n' > "$root/sys/devices/system/cpu/online"
  # cgroup v2 controllers
  printf 'cpuset cpu io memory pids\n' > "$root/sys/fs/cgroup/cgroup.controllers"

  # actions.slice cgroup limits
  printf '27917287424\n' > "$root/sys/fs/cgroup/actions.slice/memory.high"
  printf '30064771072\n' > "$root/sys/fs/cgroup/actions.slice/memory.max"
  printf '0\n' > "$root/sys/fs/cgroup/actions.slice/memory.swap.max"
  printf '%s\n' "$pids_max" > "$root/sys/fs/cgroup/actions.slice/pids.max"
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
  printf '[Slice]\nMemoryHigh=10G\nMemoryMax=12G\nMemorySwapMax=2G\nTasksMax=8192\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\n' \
    > "$root/etc/systemd/user/agents.slice"
  printf '[Slice]\nMemoryHigh=4608M\nMemoryMax=5G\nMemorySwapMax=1G\nTasksMax=4096\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\n' \
    > "$root/etc/systemd/user/automation.slice"

  # Mock docker command
  cat > "$root/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
runner_count=__FIXTURE_RUNNER_COUNT__
if [ "$1" = "--host" ]; then shift 2; fi
if [ "$1" = "info" ]; then
  printf '2 systemd\n'
elif [ "$1" = "ps" ]; then
  for i in $(seq 1 "$runner_count"); do
    printf "cid%02d ez-runner-c-%d\n" "$i" "$i"
  done
elif [ "$1" = "inspect" ]; then
  slot="${4#cid}"
  printf '%s\n' "$((10000 + 10#$slot))"
fi
DOCKER_EOF
  sed "s/__FIXTURE_RUNNER_COUNT__/$runner_count/" "$root/bin/docker" > "$root/bin/docker.tmp"
  mv "$root/bin/docker.tmp" "$root/bin/docker"
  chmod +x "$root/bin/docker"

  # Mock /proc/<pid>/cgroup for each container PID
  for i in $(seq 1 "$runner_count"); do
    local pid=$((10000 + i))
    mkdir -p "$root/proc/$pid"
    printf "0::/actions.slice/docker-cid%02d.scope\n" "$i" > "$root/proc/$pid/cgroup"
  done
}

# 1. Test clean passing fixture
FIXTURE_PASS="$WORK/pass"
setup_passing_fixture "$FIXTURE_PASS"
PATH="$FIXTURE_PASS/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet || fail "passing fixture failed assertion"
ok "assert-host-containment-release1.sh passes valid default-14 fixture"

FIXTURE_ROLLBACK="$WORK/rollback"
setup_passing_fixture "$FIXTURE_ROLLBACK" 10
PATH="$FIXTURE_ROLLBACK/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_ROLLBACK" --runner-count 10 --require-fleet || fail "assert script rejected explicit 10-runner rollback fixture"
ok "assert-host-containment-release1.sh accepts explicit 10-runner rollback fixture"

# 2. Test memory floor boundary (computed: 55 GiB hard limits + max(2GiB, 10% MemTotal))
# At boundary (64,079,644 KiB): 57,671,680 + 6,407,964 = 64,079,644 KiB (PASS)
# Above boundary (64,079,645 KiB): 57,671,680 + 6,407,964 = 64,079,644 <= 64,079,645 KiB (PASS)
# Below boundary (64,079,643 KiB): 57,671,680 + 6,407,964 = 64,079,644 > 64,079,643 KiB (FAIL)
FIXTURE_MEM_FAIL="$WORK/mem_fail"
setup_passing_fixture "$FIXTURE_MEM_FAIL"
printf 'MemTotal:       64079643 kB\n' > "$FIXTURE_MEM_FAIL/proc/meminfo"
if PATH="$FIXTURE_MEM_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_FAIL" --require-fleet > "$WORK/mem_fail.log" 2>&1; then
  fail "assertion passed when MemTotal was below computed floor"
fi
grep -q "FAIL: host MemTotal" "$WORK/mem_fail.log" || fail "missing expected MemTotal failure message"
ok "assert-host-containment-release1.sh rejects memory below computed floor (64079643 KiB)"

FIXTURE_MEM_BOUNDARY="$WORK/mem_boundary"
setup_passing_fixture "$FIXTURE_MEM_BOUNDARY"
printf 'MemTotal:       64079644 kB\n' > "$FIXTURE_MEM_BOUNDARY/proc/meminfo"
PATH="$FIXTURE_MEM_BOUNDARY/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_BOUNDARY" --require-fleet \
  || fail "assertion rejected memory at exact computed floor (64079644 KiB)"
ok "assert-host-containment-release1.sh accepts memory at exact computed floor (64079644 KiB)"

FIXTURE_MEM_ABOVE="$WORK/mem_above"
setup_passing_fixture "$FIXTURE_MEM_ABOVE"
printf 'MemTotal:       64079645 kB\n' > "$FIXTURE_MEM_ABOVE/proc/meminfo"
PATH="$FIXTURE_MEM_ABOVE/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_ABOVE" --require-fleet \
  || fail "assertion rejected memory above exact computed floor (64079645 KiB)"
ok "assert-host-containment-release1.sh accepts memory above exact computed floor (64079645 KiB)"

# 3. Test online CPUs below floor (31 online CPUs)
FIXTURE_CPU_FAIL="$WORK/cpu_fail"
setup_passing_fixture "$FIXTURE_CPU_FAIL"
printf '0-30\n' > "$FIXTURE_CPU_FAIL/sys/devices/system/cpu/online"
if PATH="$FIXTURE_CPU_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_CPU_FAIL" --require-fleet > "$WORK/cpu_fail.log" 2>&1; then
  fail "assertion passed when online CPUs was 31 (< 32)"
fi
grep -q "FAIL: host online logical CPUs" "$WORK/cpu_fail.log" || fail "missing expected CPU count failure message"
ok "assert-host-containment-release1.sh rejects fewer than 32 online CPUs"

# 4. Test missing controller (missing memory controller)
FIXTURE_CTRL_FAIL="$WORK/ctrl_fail"
setup_passing_fixture "$FIXTURE_CTRL_FAIL"
printf 'cpuset cpu io pids\n' > "$FIXTURE_CTRL_FAIL/sys/fs/cgroup/cgroup.controllers"
if PATH="$FIXTURE_CTRL_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_CTRL_FAIL" --require-fleet > "$WORK/ctrl_fail.log" 2>&1; then
  fail "assertion passed when memory controller was missing"
fi
grep -q "FAIL: cgroup.controllers missing required controller" "$WORK/ctrl_fail.log" || fail "missing controller failure message"
ok "assert-host-containment-release1.sh rejects missing cgroup controller"

# 5. Test invalid actions.slice memory limit (e.g. max or 32G)
FIXTURE_SLICE_FAIL="$WORK/slice_fail"
setup_passing_fixture "$FIXTURE_SLICE_FAIL"
printf 'max\n' > "$FIXTURE_SLICE_FAIL/sys/fs/cgroup/actions.slice/memory.max"
if PATH="$FIXTURE_SLICE_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_SLICE_FAIL" --require-fleet > "$WORK/slice_fail.log" 2>&1; then
  fail "assertion passed when actions.slice memory.max was infinite"
fi
grep -q "FAIL: actions.slice memory.max" "$WORK/slice_fail.log" || fail "missing actions.slice memory.max failure message"
ok "assert-host-containment-release1.sh rejects infinite actions.slice memory"

# 6. Test wrong runner container count (9 containers instead of 10)
FIXTURE_COUNT_FAIL="$WORK/count_fail"
setup_passing_fixture "$FIXTURE_COUNT_FAIL"
cat > "$FIXTURE_COUNT_FAIL/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
if [ "$1" = "--host" ]; then shift 2; fi
if [ "$1" = "info" ]; then
  printf '2 systemd\n'
elif [ "$1" = "ps" ]; then
  for i in $(seq 1 13); do
    printf "cid%02d ez-runner-c-%d\n" "$i" "$i"
  done
fi
DOCKER_EOF
chmod +x "$FIXTURE_COUNT_FAIL/bin/docker"
if PATH="$FIXTURE_COUNT_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_COUNT_FAIL" --require-fleet > "$WORK/count_fail.log" 2>&1; then
  fail "assertion passed when runner container count was 13"
fi
grep -q "FAIL: runner container count" "$WORK/count_fail.log" || fail "missing runner count failure message"
ok "assert-host-containment-release1.sh rejects container count != 14"

INVALID_ASSERT_ROOT="$WORK/invalid"
setup_passing_fixture "$INVALID_ASSERT_ROOT"
if PATH="$INVALID_ASSERT_ROOT/bin:$PATH" "$ASSERT_SCRIPT" --root "$INVALID_ASSERT_ROOT" --runner-count 12 > "$WORK/invalid_assert.log" 2>&1; then
  fail "assert-host-containment-release1.sh accepted unsupported runner count 12"
fi
ok "assert-host-containment-release1.sh rejects unsupported runner count"

# 7. Test PID not in actions.slice ancestry
FIXTURE_ANCESTRY_FAIL="$WORK/ancestry_fail"
setup_passing_fixture "$FIXTURE_ANCESTRY_FAIL"
printf "0::/user.slice/user-1000.slice/docker-cid01.scope\n" > "$FIXTURE_ANCESTRY_FAIL/proc/10001/cgroup"
if PATH="$FIXTURE_ANCESTRY_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_ANCESTRY_FAIL" --require-fleet > "$WORK/ancestry_fail.log" 2>&1; then
  fail "assertion passed when container PID was not in /actions.slice"
fi
grep -q "FAIL: container PID not beneath /actions.slice" "$WORK/ancestry_fail.log" || fail "missing ancestry failure message"
ok "assert-host-containment-release1.sh rejects runner container outside actions.slice"

# Live systemd property checks (normally only when --root is /): answer
# `systemctl show -p P --value -- U` from a table and run them against the
# passing fixture with CONTAINMENT_LIVE_SYSTEMD=1.
write_props() {
  local auto_high="$1" auto_max="$2" uid; uid="$(id -u)"
  cat <<PROPS
actions.slice ManagedOOMMemoryPressure auto
actions.slice ManagedOOMSwap auto
agents.slice MemoryHigh 10737418240
agents.slice MemoryMax 12884901888
agents.slice MemorySwapMax 2147483648
agents.slice TasksMax 8192
agents.slice ManagedOOMMemoryPressure auto
agents.slice ManagedOOMSwap auto
automation.slice MemoryHigh ${auto_high}
automation.slice MemoryMax ${auto_max}
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
}
PROPS_BIN="$WORK/props-bin"
mkdir -p "$PROPS_BIN"
cat > "$PROPS_BIN/systemctl" <<'SHIM'
#!/usr/bin/env bash
prop="" unit=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prop="$2"; shift 2 ;;
    --) unit="$2"; shift 2 ;;
    *) shift ;;
  esac
done
awk -v u="$unit" -v p="$prop" '$1==u && $2==p {print $3; found=1} END {exit !found}' "$SYSTEMD_PROPS"
SHIM
chmod +x "$PROPS_BIN/systemctl"
write_props 4831838208 5368709120 > "$WORK/props_ok.txt"
CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_ok.log" 2>&1\
  || fail "live systemd checks rejected 4608M/5G automation.slice: $(cat "$WORK/live_ok.log")"
write_props 8589934592 10737418240 > "$WORK/props_old.txt"
if CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_old.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_old.log" 2>&1; then
  fail "live systemd checks accepted the old 8G/10G automation.slice"
fi
grep -q "automation.slice MemoryHigh ('8589934592') != '4831838208'" "$WORK/live_old.log" || fail "missing automation.slice MemoryHigh mismatch message: $(tail -2 "$WORK/live_old.log")"
ok "assert-host-containment-release1.sh live checks accept 4608M/5G and reject 8G/10G automation.slice"

for property in ManagedOOMMemoryPressure ManagedOOMSwap; do
  sed "s/actions.slice $property auto/actions.slice $property kill/" "$WORK/props_ok.txt" > "$WORK/props_kill.txt"
  if CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_kill.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
      "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" > "$WORK/live_kill.log" 2>&1; then
    fail "live systemd checks accepted actions.slice $property=kill"
  fi
  grep -q "actions.slice $property" "$WORK/live_kill.log" || fail "wrong failure for actions.slice kill policy"
done
ok "actions.slice kill policies are rejected"

echo "ASSERT_HOST_CONTAINMENT_RELEASE1_TEST: PASS"
