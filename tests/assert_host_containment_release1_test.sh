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
  printf '[Slice]\nMemoryHigh=8G\nMemoryMax=10G\nMemorySwapMax=1G\nTasksMax=4096\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\n' \
    > "$root/etc/systemd/user/automation.slice"

  # Mock docker command
  cat > "$root/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
if [ "$1" = "--host" ]; then shift 2; fi
if [ "$1" = "info" ]; then
  printf '2 systemd\n'
elif [ "$1" = "ps" ]; then
  for i in $(seq 1 10); do
    printf "cid%02d ez-runner-c-%d\n" "$i" "$i"
  done
elif [ "$1" = "inspect" ]; then
  slot="${4#cid}"
  printf '%s\n' "$((10000 + 10#$slot))"
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
PATH="$FIXTURE_PASS/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet || fail "passing fixture failed assertion"
ok "assert-host-containment-release1.sh passes valid fixture"

# 2a. Kernel-reserve tolerance: jeff-ubuntu's real 64 GiB MemTotal passes the floor
FIXTURE_MEM_TOL="$WORK/mem_tol"
setup_passing_fixture "$FIXTURE_MEM_TOL"
printf 'MemTotal:       64856928 kB\n' > "$FIXTURE_MEM_TOL/proc/meminfo"
PATH="$FIXTURE_MEM_TOL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_TOL" --require-fleet > "$WORK/mem_tol.log" 2>&1 \
  || { cat "$WORK/mem_tol.log" >&2; fail "assertion rejected MemTotal 64856928 KiB (64 GiB host) within kernel-reserve tolerance"; }
ok "assert-host-containment-release1.sh accepts 64 GiB host MemTotal (64856928 KiB)"

# 2b. Exact boundary: floor (64487424 KiB) passes, floor-1 fails
for kib in 64487424 64487423; do
  FX="$WORK/mem_b_$kib"; setup_passing_fixture "$FX"
  printf 'MemTotal:       %s kB\n' "$kib" > "$FX/proc/meminfo"
  if PATH="$FX/bin:$PATH" "$ASSERT_SCRIPT" --root "$FX" --require-fleet > "$WORK/mem_b_$kib.log" 2>&1; then rc=0; else rc=1; fi
  if [ "$kib" = 64487424 ]; then [ "$rc" = 0 ] || fail "MemTotal at exact floor $kib KiB rejected"
  else [ "$rc" = 1 ] && grep -q "FAIL: host MemTotal" "$WORK/mem_b_$kib.log" || fail "MemTotal floor-1 $kib KiB accepted"; fi
done
ok "assert-host-containment-release1.sh floor boundary is exact (64487424 pass, 64487423 fail)"

# 2. Test memory below floor (60 GiB = 62,914,560 KiB)
FIXTURE_MEM_FAIL="$WORK/mem_fail"
setup_passing_fixture "$FIXTURE_MEM_FAIL"
printf 'MemTotal:       62914560 kB\n' > "$FIXTURE_MEM_FAIL/proc/meminfo"
if PATH="$FIXTURE_MEM_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_FAIL" --require-fleet > "$WORK/mem_fail.log" 2>&1; then
  fail "assertion passed when MemTotal was below floor"
fi
grep -q "FAIL: host MemTotal" "$WORK/mem_fail.log" || fail "missing expected MemTotal failure message"
ok "assert-host-containment-release1.sh rejects memory below 62 GiB floor"

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
  for i in $(seq 1 9); do
    printf "cid%02d ez-runner-c-%d\n" "$i" "$i"
  done
fi
DOCKER_EOF
chmod +x "$FIXTURE_COUNT_FAIL/bin/docker"
if PATH="$FIXTURE_COUNT_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_COUNT_FAIL" --require-fleet > "$WORK/count_fail.log" 2>&1; then
  fail "assertion passed when runner container count was 9"
fi
grep -q "FAIL: runner container count" "$WORK/count_fail.log" || fail "missing runner count failure message"
ok "assert-host-containment-release1.sh rejects container count != 10"

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
agents.slice MemoryHigh 19327352832
agents.slice MemoryMax 21474836480
agents.slice MemorySwapMax 2147483648
automation.slice MemoryHigh ${auto_high}
automation.slice MemoryMax ${auto_max}
automation.slice MemorySwapMax 1073741824
user@${uid}.service ManagedOOMMemoryPressure auto
user@${uid}.service ManagedOOMSwap auto
user@${uid}.service ManagedOOMPreference none
user@${uid}.service OOMScoreAdjust 0
-.slice ManagedOOMMemoryPressure auto
user.slice ManagedOOMMemoryPressure auto
app.slice ManagedOOMMemoryPressure auto
session.slice ManagedOOMMemoryPressure auto
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
write_props 8589934592 10737418240 > "$WORK/props_ok.txt"
CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_ok.log" 2>&1 \
  || fail "live systemd checks rejected 8G/10G automation.slice: $(tail -3 "$WORK/live_ok.log")"
write_props 4294967296 6442450944 > "$WORK/props_old.txt"
if CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_old.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_old.log" 2>&1; then
  fail "live systemd checks accepted the old 4G/6G automation.slice"
fi
grep -q "automation.slice MemoryHigh ('4294967296') != '8589934592'" "$WORK/live_old.log" || fail "missing automation.slice MemoryHigh mismatch message: $(tail -2 "$WORK/live_old.log")"
ok "assert-host-containment-release1.sh live checks accept 8G/10G and reject 4G/6G automation.slice"

echo "ASSERT_HOST_CONTAINMENT_RELEASE1_TEST: PASS"
