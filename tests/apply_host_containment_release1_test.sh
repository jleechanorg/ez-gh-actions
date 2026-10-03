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

set_slice_mem() { # root slice current file shmem
  printf '%s\n' "$3" > "$1/sys/fs/cgroup/$2/memory.current"
  printf 'anon %s\nfile %s\nshmem %s\n' "$(($3 - $4))" "$4" "$5" > "$1/sys/fs/cgroup/$2/memory.stat"
}

setup_fixture() {
  local root="$1"
  mkdir -p "$root/proc" "$root/sys/devices/system/cpu" "$root/sys/fs/cgroup/actions.slice" \
           "$root/sys/fs/cgroup/agents.slice" "$root/sys/fs/cgroup/automation.slice" \
           "$root/etc/systemd/system" "$root/etc/systemd/user" \
           "$root/bin" "$root/var/lock"

  printf 'MemTotal:       65512304 kB\nMemFree:        30000000 kB\n' > "$root/proc/meminfo"
  printf '0-31\n' > "$root/sys/devices/system/cpu/online"
  printf 'cpuset cpu io memory pids\n' > "$root/sys/fs/cgroup/cgroup.controllers"

  # Current use under the host-docker thresholds: non-reclaimable
  # (memory.current - (file - shmem)) <= new MemoryHigh - 1 GiB.
  set_slice_mem "$root" agents.slice 8589934592 2147483648 0
  set_slice_mem "$root" automation.slice 1073741824 0 0

  # Staged actions.slice cgroup values
  printf '27917287424\n' > "$root/sys/fs/cgroup/actions.slice/memory.high"
  printf '30064771072\n' > "$root/sys/fs/cgroup/actions.slice/memory.max"
  printf '0\n' > "$root/sys/fs/cgroup/actions.slice/memory.swap.max"
  printf '6000\n' > "$root/sys/fs/cgroup/actions.slice/pids.max"
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

[ -f "$PASS_ROOT/etc/systemd/system/actions.slice" ] || fail "actions.slice was not staged to system units"
[ -f "$PASS_ROOT/etc/systemd/system/-.slice.d/99-ezgha-containment.conf" ] || fail "-.slice.d drop-in not staged"
[ -f "$PASS_ROOT/etc/systemd/system/user@.service.d/99-ezgha-containment.conf" ] || fail "user@.service.d drop-in not staged"
[ -f "$PASS_ROOT/etc/systemd/user/agents.slice" ] || fail "agents.slice not staged to user units"
[ -f "$PASS_ROOT/etc/systemd/user/automation.slice" ] || fail "automation.slice not staged to user units"
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

# 2. Pre-mutation gate: memory below floor
MEM_FAIL_ROOT="$WORK/mem_fail"
setup_fixture "$MEM_FAIL_ROOT"
printf 'MemTotal:       65011711 kB\n' > "$MEM_FAIL_ROOT/proc/meminfo"
if PATH="$MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$MEM_FAIL_ROOT" > "$WORK/mem_fail.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when MemTotal was below floor"
fi
[ ! -f "$MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before memory check passed"
ok "apply-host-containment-release1.sh aborts before mutation when memory is below floor"

# 3. Pre-mutation gate: non-reclaimable use of each user slice must sit
#    at least 1 GiB below its new MemoryHigh (agents 13G, automation 7G).
G=1073741824
preflight_case() { # name slice current file shmem expect(pass|refuse)
  local root="$WORK/preflight_$1"
  setup_fixture "$root"
  set_slice_mem "$root" "$2" "$3" "$4" "$5"
  if PATH="$root/bin:$PATH" "$APPLY_SCRIPT" --root "$root" > "$WORK/preflight_$1.log" 2>&1; then
    [ "$6" = pass ] || fail "preflight $1 passed but should refuse: $(tail -2 "$WORK/preflight_$1.log")"
  else
    [ "$6" = refuse ] || fail "preflight $1 refused but should pass: $(tail -2 "$WORK/preflight_$1.log")"
    [ ! -f "$root/etc/systemd/system/actions.slice" ] || fail "preflight $1 staged files before refusing"
    [ ! -f "$root/etc/systemd/user/agents.slice" ] || fail "preflight $1 staged user slices before refusing"
    grep -q "$2" "$WORK/preflight_$1.log" || fail "preflight $1 refusal does not name $2"
  fi
}
# 16G current but 6G of it is reclaimable page cache: 10G <= 12G passes.
preflight_case agents_cache agents.slice $((16 * G)) $((6 * G)) 0 pass
# 15G current, 1G file: 14G non-reclaimable > 12G refuses.
preflight_case agents_anon agents.slice $((15 * G)) $((1 * G)) 0 refuse
grep -q "agents.slice non-reclaimable 15032385536 bytes > 12884901888" "$WORK/preflight_agents_anon.log" \
  || fail "agents refusal lacks the measured numbers: $(tail -2 "$WORK/preflight_agents_anon.log")"
# shmem is not reclaimable: 16G current, 6G file of which 3G shmem -> 13G refuses.
preflight_case agents_shmem agents.slice $((16 * G)) $((6 * G)) $((3 * G)) refuse
# automation: 7G current with 2G cache -> 5G <= 6G passes; 7G with 0.5G cache refuses.
preflight_case automation_cache automation.slice $((7 * G)) $((2 * G)) 0 pass
preflight_case automation_anon automation.slice $((7 * G)) $((G / 2)) 0 refuse
ok "apply-host-containment-release1.sh refuses to lower a user slice beneath its non-reclaimable use and changes nothing"

# 3b. Lima guest memory gate: the host-docker QEMU ceiling (4608M/5G) is only
#     safe for a <= 4 GiB guest; a larger configured guest refuses before any write.
lima_case() { # name yaml-memory limactl-bytes expect(pass|refuse)
  local root="$WORK/lima_$1"
  setup_fixture "$root"
  mkdir -p "$root/lima/colima"
  printf 'cpus: 4\nmemory: "%s"\n' "$2" > "$root/lima/colima/lima.yaml"
  cat > "$root/bin/limactl" <<LIMA_EOF
#!/usr/bin/env bash
[ "\$1 \$2 \$3" = "list --json colima" ] || exit 1
printf '{"name":"colima","status":"Running","memory":%s}\n' "$3"
LIMA_EOF
  chmod +x "$root/bin/limactl"
  if PATH="$root/bin:$PATH" "$APPLY_SCRIPT" --root "$root" > "$WORK/lima_$1.log" 2>&1; then
    [ "$4" = pass ] || fail "lima $1 passed but should refuse: $(tail -2 "$WORK/lima_$1.log")"
  else
    [ "$4" = refuse ] || fail "lima $1 refused but should pass: $(tail -2 "$WORK/lima_$1.log")"
    [ ! -f "$root/etc/systemd/system/actions.slice" ] || fail "lima $1 staged files before refusing"
  fi
}
lima_case resized 4GiB 4294967296 pass
lima_case running_8g 4GiB 8589934592 refuse
grep -qx "FAIL lima guest memory 8589934592 > 4GiB: resize the guest and restart the VM once before lowering the QEMU ceiling" "$WORK/lima_running_8g.log" \
  || fail "lima refusal message mismatch: $(cat "$WORK/lima_running_8g.log")"
lima_case yaml_8g 8GiB 4294967296 refuse
grep -q "FAIL lima guest memory 8589934592 > 4GiB" "$WORK/lima_yaml_8g.log" || fail "lima.yaml 8GiB refusal message missing"
ok "apply-host-containment-release1.sh refuses the host-docker QEMU ceiling while the Lima guest is above 4 GiB"

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
agents.slice MemoryHigh 13958643712
agents.slice MemoryMax 15032385536
agents.slice MemorySwapMax 2147483648
automation.slice MemoryHigh 7516192768
automation.slice MemoryMax 8589934592
automation.slice MemorySwapMax 1073741824
user@${uid}.service ManagedOOMMemoryPressure auto
user@${uid}.service ManagedOOMSwap auto
user@${uid}.service ManagedOOMPreference none
user@${uid}.service OOMScoreAdjust 0
-.slice ManagedOOMMemoryPressure auto
user.slice ManagedOOMMemoryPressure auto
actions.slice ManagedOOMMemoryPressure kill
actions.slice ManagedOOMMemoryPressureLimit 3435973836
app.slice ManagedOOMMemoryPressure auto
session.slice ManagedOOMMemoryPressure auto
PROPS
cat > "$LIVE_ROOT/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "${SYSTEMCTL_LOG:-/dev/null}"
prop="" unit="" show=0
for a in "$@"; do [ "$a" = show ] && show=1; done
[ "$show" = 1 ] || exit 0
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prop="$2"; shift 2 ;;
    --) unit="$2"; shift 2 ;;
    *) shift ;;
  esac
done
awk -v u="$unit" -v p="$prop" '$1==u && $2==p {print $3; found=1} END {exit !found}' "$SYSTEMD_PROPS"
SHIM
chmod +x "$LIVE_ROOT/bin/systemctl"
CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$WORK/live_props.txt" SYSTEMCTL_LOG="$WORK/live_sys.log" PATH="$LIVE_ROOT/bin:$PATH" \
  "$APPLY_SCRIPT" --root "$LIVE_ROOT" > "$WORK/live.log" 2>&1 || fail "live-systemd apply failed: $(tail -3 "$WORK/live.log")"
grep -qx "systemctl --user set-property automation.slice MemoryHigh=7G MemoryMax=8G MemorySwapMax=1G TasksMax=4096" "$WORK/live_sys.log" \
  || fail "live apply did not set automation.slice to 7G/8G: $(grep automation "$WORK/live_sys.log" || echo none)"
grep -qx "systemctl --user set-property agents.slice MemoryHigh=13G MemoryMax=14G MemorySwapMax=2G TasksMax=8192" "$WORK/live_sys.log" \
  || fail "live apply did not set agents.slice to 13G/14G: $(grep agents "$WORK/live_sys.log" || echo none)"
ok "apply-host-containment-release1.sh live branch persists agents.slice 13G/14G and automation.slice 7G/8G via set-property"

# The root phase enrolls actions.slice with systemd-oomd (kill at 80% pressure);
# agents.slice and automation.slice are never enrolled with kill.
grep -Fqx '    systemctl set-property actions.slice ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit=80%' "$APPLY_SCRIPT" \
  || fail "root phase does not enroll actions.slice with ManagedOOMMemoryPressure=kill at 80%"
! grep -E 'set-property (agents|automation)\.slice.*ManagedOOMMemoryPressure=kill' "$APPLY_SCRIPT" \
  || fail "agents/automation.slice must not be enrolled with oomd kill"
ok "apply-host-containment-release1.sh enrolls only actions.slice with oomd kill"

echo "APPLY_HOST_CONTAINMENT_RELEASE1_TEST: PASS"
