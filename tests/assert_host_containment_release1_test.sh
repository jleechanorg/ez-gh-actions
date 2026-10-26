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
  local root="$1" runner_count="${2:-20}" pids_max
  case "$runner_count" in
    10) pids_max=6000 ;;
    14) pids_max=8000 ;;
    20) pids_max=8000 ;;
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
  printf '[Slice]\nMemoryHigh=10G\nMemoryMax=11776M\nMemorySwapMax=2G\nTasksMax=8192\nManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\n' \
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
ok "assert-host-containment-release1.sh passes valid default-20 fixture"

FIXTURE_ROLLBACK_14="$WORK/rollback_14"
setup_passing_fixture "$FIXTURE_ROLLBACK_14" 14
PATH="$FIXTURE_ROLLBACK_14/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_ROLLBACK_14" --runner-count 14 --require-fleet || fail "assert script rejected explicit 14-runner rollback fixture"
ok "assert-host-containment-release1.sh accepts explicit 14-runner rollback fixture"

FIXTURE_ROLLBACK="$WORK/rollback"
setup_passing_fixture "$FIXTURE_ROLLBACK" 10
PATH="$FIXTURE_ROLLBACK/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_ROLLBACK" --runner-count 10 --require-fleet || fail "assert script rejected explicit 10-runner rollback fixture"
ok "assert-host-containment-release1.sh accepts explicit 10-runner rollback fixture"

# 2. Test memory floor boundary (computed: 54.5 GiB hard limits + max(2GiB, 10% MemTotal))
# R1 cap-fit amendment 2026-10-21 (agents.slice 12G -> 11776M, bead
# jleechan-r1-cap-fit-amendment-byee): caps sum 57,147,392 KiB.
# At boundary (63,497,102 KiB): 57,147,392 + 6,349,710 = 63,497,102 KiB (PASS)
# Above boundary (63,497,103 KiB): floor 63,497,102 <= 63,497,103 KiB (PASS)
# Below boundary (63,497,101 KiB): floor 63,497,102 > 63,497,101 KiB (FAIL)
FIXTURE_MEM_FAIL="$WORK/mem_fail"
setup_passing_fixture "$FIXTURE_MEM_FAIL"
printf 'MemTotal:       63497101 kB\n' > "$FIXTURE_MEM_FAIL/proc/meminfo"
if PATH="$FIXTURE_MEM_FAIL/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_FAIL" --require-fleet > "$WORK/mem_fail.log" 2>&1; then
  fail "assertion passed when MemTotal was below computed floor"
fi
grep -q "FAIL: host MemTotal" "$WORK/mem_fail.log" || fail "missing expected MemTotal failure message"
ok "assert-host-containment-release1.sh rejects memory below computed floor (63497101 KiB)"

FIXTURE_MEM_BOUNDARY="$WORK/mem_boundary"
setup_passing_fixture "$FIXTURE_MEM_BOUNDARY"
printf 'MemTotal:       63497102 kB\n' > "$FIXTURE_MEM_BOUNDARY/proc/meminfo"
PATH="$FIXTURE_MEM_BOUNDARY/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_BOUNDARY" --require-fleet \
  || fail "assertion rejected memory at exact computed floor (63497102 KiB)"
ok "assert-host-containment-release1.sh accepts memory at exact computed floor (63497102 KiB)"

FIXTURE_MEM_ABOVE="$WORK/mem_above"
setup_passing_fixture "$FIXTURE_MEM_ABOVE"
printf 'MemTotal:       63497103 kB\n' > "$FIXTURE_MEM_ABOVE/proc/meminfo"
PATH="$FIXTURE_MEM_ABOVE/bin:$PATH" "$ASSERT_SCRIPT" --root "$FIXTURE_MEM_ABOVE" --require-fleet \
  || fail "assertion rejected memory above exact computed floor (63497103 KiB)"
ok "assert-host-containment-release1.sh accepts memory above exact computed floor (63497103 KiB)"

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
ok "assert-host-containment-release1.sh rejects container count != 20"

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
write_props() { # [agents_high agents_max] auto_high auto_max
  local agents_high=10737418240 agents_max=12348030976 auto_high auto_max uid; uid="$(id -u)"
  if [ "$#" -eq 4 ]; then agents_high="$1" agents_max="$2"; shift 2; fi
  auto_high="$1" auto_max="$2"
  cat <<PROPS
actions.slice ManagedOOMMemoryPressure kill
actions.slice ManagedOOMMemoryPressureLimit 3435973836
actions.slice ManagedOOMSwap auto
agents.slice MemoryHigh ${agents_high}
agents.slice MemoryMax ${agents_max}
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
case "$prop" in
  LoadState) [ "${QEMU_QUERY_FAIL:-0}" = 1 ] && exit 1; echo "${QEMU_LOAD_STATE:-loaded}"; exit 0 ;;
  ActiveState) [ "${QEMU_QUERY_FAIL:-0}" = 1 ] && exit 1; echo "${QEMU_ACTIVE_STATE:-active}"; exit 0 ;;
  ControlGroup) [ "${QEMU_QUERY_FAIL:-0}" = 1 ] && exit 1; printf '%s\n' "${QEMU_CONTROL_GROUP-/lima-vm@colima.service}"; exit 0 ;;
esac
awk -v u="$unit" -v p="$prop" '$1==u && $2==p {print $3; found=1} END {exit !found}' "$SYSTEMD_PROPS"
SHIM
chmod +x "$PROPS_BIN/systemctl"
# Live fixture calls must remain isolated from the host systemctl binary.
cat > "$FIXTURE_PASS/bin/systemctl" <<EOF_FIXTURE_SYSTEMCTL
#!/usr/bin/env bash
exec "$PROPS_BIN/systemctl" "\$@"
EOF_FIXTURE_SYSTEMCTL
chmod +x "$FIXTURE_PASS/bin/systemctl"
# Host-docker policy: agents 10G/11776M (11.5 GiB, R1 cap-fit amendment), automation 4608M/5G.
write_props 10737418240 12348030976 4831838208 5368709120 > "$WORK/props_ok.txt"
CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_ok.log" 2>&1 \
  || fail "live systemd checks rejected 10G/11776M agents + 4608M/5G automation: $(tail -3 "$WORK/live_ok.log")"
# The pre-154k 18G/20G + 8G/10G maxima over-commit the host-docker envelope.
write_props 19327352832 21474836480 5368709120 10737418240 > "$WORK/props_old.txt"
if CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_old.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_old.log" 2>&1; then
  fail "live systemd checks accepted the old 18G/20G agents.slice"
fi
grep -q "agents.slice MemoryHigh ('19327352832') != '10737418240'" "$WORK/live_old.log" || fail "missing agents.slice MemoryHigh mismatch message: $(tail -2 "$WORK/live_old.log")"
write_props 10737418240 12348030976 5368709120 10737418240 > "$WORK/props_old_auto.txt"
if CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_old_auto.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_old_auto.log" 2>&1; then
  fail "live systemd checks accepted the old 8G/10G automation.slice"
fi
grep -q "automation.slice MemoryHigh ('5368709120') != '4831838208'" "$WORK/live_old_auto.log" || fail "missing automation.slice MemoryHigh mismatch message: $(tail -2 "$WORK/live_old_auto.log")"
# actions.slice must be enrolled with oomd kill at 80% pressure.
sed 's/^actions.slice ManagedOOMMemoryPressure kill$/actions.slice ManagedOOMMemoryPressure auto/' "$WORK/props_ok.txt" > "$WORK/props_oom_auto.txt"
if CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_oom_auto.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
  "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_oom_auto.log" 2>&1; then
  fail "live systemd checks accepted actions.slice ManagedOOMMemoryPressure=auto"
fi
grep -q "actions.slice ManagedOOMMemoryPressure ('auto') != 'kill'" "$WORK/live_oom_auto.log" || fail "missing actions.slice oomd mismatch message: $(tail -2 "$WORK/live_oom_auto.log")"
ok "assert-host-containment-release1.sh live checks accept the host-docker policy and reject the pre-154k maxima"

# Swap-pressure kill remains forbidden on the runner aggregate.
sed 's/^actions.slice ManagedOOMSwap auto$/actions.slice ManagedOOMSwap kill/' "$WORK/props_ok.txt" > "$WORK/props_swap_kill.txt"
if CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_swap_kill.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
    "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" > "$WORK/live_swap_kill.log" 2>&1; then
  fail "live systemd checks accepted actions.slice ManagedOOMSwap=kill"
fi
grep -q "actions.slice ManagedOOMSwap ('kill') != 'auto'" "$WORK/live_swap_kill.log" || fail "wrong failure for actions.slice swap kill policy: $(tail -2 "$WORK/live_swap_kill.log")"
ok "actions.slice swap kill policy is rejected"

# Native Docker with an explicitly inactive/not-found VM must skip only the
# QEMU live-property checks; the finite tracked drop-in remains source-checked.
if ! QEMU_LOAD_STATE=not-found QEMU_ACTIVE_STATE=inactive QEMU_CONTROL_GROUP= \
    CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
    "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_qemu_inactive.log" 2>&1; then
  fail "inactive native VM incorrectly failed containment assertion: $(tail -3 "$WORK/live_qemu_inactive.log")"
fi
ok "assert-host-containment-release1.sh skips live QEMU properties only for confirmed inactive VM"

if QEMU_LOAD_STATE=not-found QEMU_ACTIVE_STATE=inactive QEMU_CONTROL_GROUP= QEMU_QUERY_FAIL=1 \
    CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
    "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_qemu_query_fail.log" 2>&1; then
  fail "QEMU service query failure was accepted"
fi
ok "assert-host-containment-release1.sh fails closed on QEMU service query failure"

STRAY_BIN="$WORK/stray-ps-bin"
mkdir -p "$STRAY_BIN"
cat > "$STRAY_BIN/ps" <<'EOF_PS'
#!/usr/bin/env bash
case "$*" in
  *'comm='*) printf 'bash\nqemu-system-aarc\n'; exit 0 ;;
  *) exit 2 ;;
esac
EOF_PS
chmod +x "$STRAY_BIN/ps"
if QEMU_LOAD_STATE=not-found QEMU_ACTIVE_STATE=inactive QEMU_CONTROL_GROUP= \
    CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$STRAY_BIN:$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
    "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_qemu_stray.log" 2>&1; then
  fail "stray QEMU process was accepted with inactive VM service"
fi
grep -q 'stray QEMU process' "$WORK/live_qemu_stray.log" || fail "stray QEMU failure lacked a precise diagnostic"
ok "assert-host-containment-release1.sh rejects stray QEMU with inactive VM service"

QUERY_BIN="$WORK/query-fail-ps-bin"
mkdir -p "$QUERY_BIN"
cat > "$QUERY_BIN/ps" <<'EOF_PS_FAIL'
#!/usr/bin/env bash
exit 2
EOF_PS_FAIL
chmod +x "$QUERY_BIN/ps"
if QEMU_LOAD_STATE=not-found QEMU_ACTIVE_STATE=inactive QEMU_CONTROL_GROUP= \
    CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$QUERY_BIN:$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
    "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_qemu_ps_fail.log" 2>&1; then
  fail "process-name query failure was accepted"
fi
grep -q 'cannot query process names' "$WORK/live_qemu_ps_fail.log" || fail "process-name query failure lacked a precise diagnostic"
ok "assert-host-containment-release1.sh fails closed on process-name query failure"

mv "$FIXTURE_PASS/bin/systemctl" "$WORK/fixture-systemctl.saved"
if QEMU_LOAD_STATE=not-found QEMU_ACTIVE_STATE=inactive QEMU_CONTROL_GROUP= \
    CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/props_ok.txt" PATH="$PROPS_BIN:$FIXTURE_PASS/bin:$PATH" \
    "$ASSERT_SCRIPT" --root "$FIXTURE_PASS" --require-fleet > "$WORK/live_qemu_missing_systemctl.log" 2>&1; then
  fail "missing fixture systemctl binary reached the host systemctl"
fi
grep -q 'cannot query lima-vm@colima.service ActiveState' "$WORK/live_qemu_missing_systemctl.log" \
  || fail "missing fixture systemctl failure lacked a precise diagnostic"
mv "$WORK/fixture-systemctl.saved" "$FIXTURE_PASS/bin/systemctl"
ok "assert-host-containment-release1.sh keeps missing fixture systemctl isolated"

echo "ASSERT_HOST_CONTAINMENT_RELEASE1_TEST: PASS"
