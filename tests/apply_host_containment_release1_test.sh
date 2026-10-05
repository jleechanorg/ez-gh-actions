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

set_slice_mem() { # root slice current file shmem
  printf '%s\n' "$3" > "$1/sys/fs/cgroup/$2/memory.current"
  printf 'anon %s\nfile %s\nshmem %s\n' "$(($3 - $4))" "$4" "$5" > "$1/sys/fs/cgroup/$2/memory.stat"
}

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

  # Current use under the 10G/4.5G/9G thresholds; non-reclaimable
  # (memory.current - (file - shmem)) <= new MemoryHigh - 1 GiB.
  set_slice_mem "$root" agents.slice 5368709120 2147483648 0
  set_slice_mem "$root" automation.slice 1073741824 0 0
  printf '1073741824\n' > "$root/sys/fs/cgroup/app-lima-vm.slice/memory.current"
  printf '1073741824\n' > "$root/sys/fs/cgroup/lima-vm@colima.service/memory.current"

  # Staged actions.slice cgroup values
  printf '27917287424\n' > "$root/sys/fs/cgroup/actions.slice/memory.high"
  printf '30064771072\n' > "$root/sys/fs/cgroup/actions.slice/memory.max"
  printf '0\n' > "$root/sys/fs/cgroup/actions.slice/memory.swap.max"
  printf '%s\n' "$pids_max" > "$root/sys/fs/cgroup/actions.slice/pids.max"
  printf '2000000 100000\n' > "$root/sys/fs/cgroup/actions.slice/cpu.max"
  printf 'default 25\n' > "$root/sys/fs/cgroup/actions.slice/io.weight"
  printf '5368709120\n' > "$root/sys/fs/cgroup/actions.slice/memory.current"
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
grep -Fq "MemoryHigh=10G" "$PASS_ROOT/etc/systemd/user/agents.slice" || fail "agents.slice staged without the tracked 10G policy"
grep -Fq "MemoryHigh=4608M" "$PASS_ROOT/etc/systemd/user/automation.slice" || fail "automation.slice staged without the tracked 4608M policy"
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

# 3. Pre-mutation gate: non-reclaimable use of each user slice must sit
#    at least 1 GiB below its new MemoryHigh (agents 10G, automation 4608M).
G=1073741824
M=1048576
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
# Every case stays below the raw MemoryHigh guard (agents 10G, automation
# 4608M) so only the non-reclaimable rule decides.
# 9.5G current minus 1G reclaimable cache stays under the 9G admission threshold.
preflight_case agents_cache agents.slice $((9728 * M)) $((1024 * M)) 0 pass
# 9.5G current minus 205M reclaimable cache exceeds the 9G admission threshold.
preflight_case agents_anon agents.slice $((9728 * M)) $((205 * M)) 0 refuse
grep -q "agents.slice non-reclaimable 9985589248 bytes > 9663676416" "$WORK/preflight_agents_anon.log" \
  || fail "agents refusal lacks the measured numbers: $(tail -2 "$WORK/preflight_agents_anon.log")"
# shmem is not reclaimable: 9.5G current, 1G file of which 700M shmem -> 9404M refuses.
preflight_case agents_shmem agents.slice $((9728 * M)) $((1024 * M)) $((700 * M)) refuse
# automation: 4G minus 0.5G cache meets the 3.5G admission threshold; 4500M minus 0.5G refuses.
preflight_case automation_cache automation.slice $((4096 * M)) $((512 * M)) 0 pass
preflight_case automation_anon automation.slice $((4500 * M)) $((512 * M)) 0 refuse
ok "apply-host-containment-release1.sh refuses to lower a user slice beneath its non-reclaimable use and changes nothing"

# 3b. Lima guest memory gate: the host-docker QEMU ceiling (9G/10G) is only
#     safe for a <= 8 GiB guest. `limactl list` reports lima.yaml, not the
#     running VM, so the running size comes from the colima QEMU's `-m` (MiB);
#     any state the check cannot establish refuses before any write.
lima_case() { # name yaml-memory(or - for no lima.yaml) limactl-status (or __NUMBER__) qemu-m-MiB(or -) expect(pass|refuse) [limactl-.memory JSON, or - to omit]
  local root="$WORK/lima_$1" memory_json=',"memory":4294967296' status_json
  case "${6:-}" in '') ;; -) memory_json='' ;; *) memory_json=",\"memory\":$6" ;; esac
  case "$3" in __NUMBER__) status_json=7 ;; *) status_json="\"$3\"" ;; esac
  setup_fixture "$root"
  mkdir -p "$root/lima/colima"
  [ "$2" = - ] || printf 'cpus: 4\nmemory: %s\n' "$2" > "$root/lima/colima/lima.yaml"
  cat > "$root/bin/limactl" <<LIMA_EOF
#!/usr/bin/env bash
[ "\$1 \$2 \$3" = "list --json colima" ] || exit 1
[ "$3" = ERROR ] && { echo 'level=fatal msg="boom"' >&2; exit 1; }
printf '{"name":"colima","status":%s%s}\n' '$status_json' '$memory_json'
LIMA_EOF
  chmod +x "$root/bin/limactl"
  if [ "$4" != - ]; then
    mkdir -p "$root/proc/7777" "$root/sys/fs/cgroup/lima-vm@colima.service"
    printf 'qemu-system-x86\n' > "$root/proc/7777/comm"
    printf '%s\0' qemu-system-x86_64 -m "$4" -drive "file=$root/lima/colima/diffdisk,if=virtio" > "$root/proc/7777/cmdline"
    printf '0::/lima-vm@colima.service\n' > "$root/proc/7777/cgroup"
    printf '7777\n' > "$root/sys/fs/cgroup/lima-vm@colima.service/cgroup.procs"
    cat > "$root/bin/systemctl" <<'SYSTEMCTL_EOF'
#!/usr/bin/env bash
case "$*" in
  *show*'lima-vm@colima.service'*) printf '/lima-vm@colima.service\n' ;;
esac
exit 0
SYSTEMCTL_EOF
    chmod +x "$root/bin/systemctl"
  fi
  if QEMU_CGROUP_ROOT="$root/sys/fs/cgroup" PATH="$root/bin:$PATH" "$APPLY_SCRIPT" --root "$root" > "$WORK/lima_$1.log" 2>&1; then
    [ "$5" = pass ] || fail "lima $1 passed but should refuse: $(tail -2 "$WORK/lima_$1.log")"
  else
    [ "$5" = refuse ] || fail "lima $1 refused but should pass: $(tail -2 "$WORK/lima_$1.log")"
    [ ! -f "$root/etc/systemd/system/actions.slice" ] || fail "lima $1 staged files before refusing"
  fi
}
lima_case resized_running 8GiB Running 4096 pass
lima_case resized_stopped 8GiB Stopped - pass
# Only an exact stopped state is safe without a QEMU proof. Lima's other
# statuses describe incomplete or broken inspection, so they must fail closed.
for status_case in Broken Unknown 'Stopped ' __NUMBER__; do
  case "$status_case" in
    Broken) status_name=broken_status ;;
    Unknown) status_name=unknown_status ;;
    __NUMBER__) status_name=nonstring_status ;;
    *) status_name=whitespace_status ;;
  esac
  lima_case "$status_name" 8GiB "$status_case" - refuse
  grep -q 'FAIL lima guest memory unknown (limactl.*status' "$WORK/lima_${status_name}.log" \
    || fail "unsupported Lima status $status_case did not fail closed: $(cat "$WORK/lima_${status_name}.log")"
done
# lima.yaml already rewritten to 8GiB but the VM still runs with -m 8192:
# limactl would report 4294967296 here, the running QEMU is what counts.
lima_case yaml_rewritten_vm_8g 8GiB Running 8192 pass
lima_case yaml_8g_stopped 8GiB Stopped - pass
lima_case yaml_12g_stopped 12GiB Stopped - refuse
grep -q "FAIL lima guest memory 12884901888 > 8GiB" "$WORK/lima_yaml_12g_stopped.log" || fail "lima.yaml 12GiB refusal message missing"
# Unknowable state fails closed: a failed limactl query, or a Running VM
# whose QEMU process cannot be found.
lima_case limactl_error 8GiB ERROR - refuse
grep -q "FAIL lima guest memory unknown" "$WORK/lima_limactl_error.log" || fail "failed limactl query did not fail closed: $(cat "$WORK/lima_limactl_error.log")"
lima_case running_no_qemu 8GiB Running - refuse
grep -q "FAIL lima guest memory unknown" "$WORK/lima_running_no_qemu.log" || fail "Running VM without a QEMU process did not fail closed"
# limactl's configured .memory (bytes) is validated too: absent, malformed
# or > 8 GiB refuses even when lima.yaml and QEMU say 8 GiB.
lima_case limactl_mem_missing 8GiB Stopped - refuse -
grep -q "FAIL lima guest memory unknown (limactl" "$WORK/lima_limactl_mem_missing.log" || fail "absent limactl .memory did not fail closed: $(cat "$WORK/lima_limactl_mem_missing.log")"
lima_case limactl_mem_malformed 8GiB Stopped - refuse '"8GiB"'
grep -q "FAIL lima guest memory unknown (limactl" "$WORK/lima_limactl_mem_malformed.log" || fail "malformed limactl .memory did not fail closed: $(cat "$WORK/lima_limactl_mem_malformed.log")"
lima_case limactl_mem_5g 8GiB Running 4096 pass 5368709120
# Unparseable sizes and a missing lima.yaml refuse with a diagnostic, not silently.
lima_case yaml_unparseable 8G Stopped - refuse
grep -q "FAIL lima guest memory unknown (unparseable memory: 8G" "$WORK/lima_yaml_unparseable.log" || fail "unparseable lima.yaml memory exited without a diagnostic: $(cat "$WORK/lima_yaml_unparseable.log")"
lima_case qemu_m_unparseable 8GiB Running 8x refuse
grep -q "FAIL lima guest memory unknown (colima QEMU" "$WORK/lima_qemu_m_unparseable.log" || fail "unparseable QEMU -m exited without a diagnostic: $(cat "$WORK/lima_qemu_m_unparseable.log")"
lima_case yaml_missing_stopped - Stopped - refuse
grep -q "FAIL lima guest memory unknown (.*lima.yaml" "$WORK/lima_yaml_missing_stopped.log" || fail "instance without lima.yaml passed with nothing proven: $(cat "$WORK/lima_yaml_missing_stopped.log")"
ok "apply-host-containment-release1.sh refuses the host-docker QEMU ceiling while the Lima guest is above 8 GiB"

# An empty Lima listing cannot hide an owned running Colima process.
EMPTY_LIMA="$WORK/empty_lima"
mkdir -p "$EMPTY_LIMA/bin" "$EMPTY_LIMA/proc/7777"
printf '#!/bin/sh\nexit 0\n' > "$EMPTY_LIMA/bin/limactl"
printf '#!/bin/sh\nexit 0\n' > "$EMPTY_LIMA/bin/systemctl"
chmod +x "$EMPTY_LIMA/bin/limactl" "$EMPTY_LIMA/bin/systemctl"
printf 'qemu-system-x86\n' > "$EMPTY_LIMA/proc/7777/comm"
printf '%s\0' qemu-system-x86_64 -m 12288 -drive \
  "file=$EMPTY_LIMA/colima/diffdisk" > "$EMPTY_LIMA/proc/7777/cmdline"
for mode in check path; do
  args=()
  [ "$mode" != path ] || args=(--print-yaml)
  if env -u LIMA_YAML PATH="$EMPTY_LIMA/bin:$PATH" LIMACTL="$EMPTY_LIMA/bin/limactl" LIMA_PROC_ROOT="$EMPTY_LIMA/proc" \
      "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" "${args[@]}" > "$WORK/empty-$mode.log" 2>&1; then
    fail "empty Lima listing hid a running guest ($mode)"
  fi
  grep -q 'FAIL lima guest memory unknown.*owned colima QEMU' "$WORK/empty-$mode.log" \
    || fail "missing owned-QEMU diagnostic ($mode)"
done
mkdir -p "$EMPTY_LIMA/no_proc"
env -u LIMA_YAML PATH="$EMPTY_LIMA/bin:$PATH" LIMACTL="$EMPTY_LIMA/bin/limactl" LIMA_PROC_ROOT="$EMPTY_LIMA/no_proc" \
  "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" >/dev/null \
  || fail "proven absence of a Colima instance was rejected"

# The unit being capped must belong to the same Lima instance as the caller.
DUAL_LIMA="$WORK/dual_lima"
mkdir -p "$DUAL_LIMA/bin" "$DUAL_LIMA/lima/colima" "$DUAL_LIMA/proc/8888" \
  "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service"
printf 'memory: "8GiB"\n' > "$DUAL_LIMA/lima/colima/lima.yaml"
printf 'qemu-system-x86\n' > "$DUAL_LIMA/proc/8888/comm"
printf '%s\0' qemu-system-x86_64 -m 12288 -drive \
  "file=$DUAL_LIMA/other/colima/diffdisk" > "$DUAL_LIMA/proc/8888/cmdline"
printf '8888\n' > "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/cgroup.procs"
cat > "$DUAL_LIMA/bin/systemctl" <<'SHIM'
#!/bin/sh
[ "${LIMA_EMPTY_CGROUP:-0}" = 1 ] && exit 0
printf '/fixture/lima-vm@colima.service\n'
SHIM
cat > "$DUAL_LIMA/bin/limactl" <<'SHIM'
#!/bin/sh
printf '{"status":"%s","memory":8589934592}\n' "${LIMA_FIXTURE_STATUS:-Stopped}"
SHIM
chmod +x "$DUAL_LIMA/bin/"*
if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" > "$WORK/dual_lima.log" 2>&1; then
  fail "caller-selected stopped instance hid a different running guest in the capped unit"
fi
grep -q 'FAIL lima guest memory unknown.*capped unit' "$WORK/dual_lima.log" \
  || fail "dual-Lima refusal did not identify the capped unit mismatch"

if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" --print-yaml > "$WORK/dual_path.log" 2>&1; then
  fail "wrong-instance configuration path was offered to the installer"
fi
mkdir -p "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/child"
mv "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/cgroup.procs" \
  "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/child/cgroup.procs"
: > "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/cgroup.procs"
if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" > "$WORK/dual_nested.log" 2>&1; then
  fail "nested capped cgroup hid a different running guest"
fi
printf '%s\0' qemu-system-x86_64 -m 8192 -drive \
  "file=$DUAL_LIMA/lima/colima/diffdisk" > "$DUAL_LIMA/proc/8888/cmdline"
printf '0::/fixture/lima-vm@colima.service/child\n' > "$DUAL_LIMA/proc/8888/cgroup"
PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
  LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
  LIMA_FIXTURE_STATUS=Running \
  "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" >/dev/null \
  || fail "matching bounded guest in capped unit was rejected"

# A Running VM with a QEMU matching the selected instance but outside the
# capped service must fail even when the service cgroup itself is empty.
: > "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/child/cgroup.procs"
mkdir -p "$DUAL_LIMA/cgroup/fixture/unrelated.scope"
printf '8888\n' > "$DUAL_LIMA/cgroup/fixture/unrelated.scope/cgroup.procs"
printf '0::/fixture/unrelated.scope\n' > "$DUAL_LIMA/proc/8888/cgroup"
if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    LIMA_FIXTURE_STATUS=Running \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" > "$WORK/dual_outside_empty.log" 2>&1; then
  fail "Running QEMU outside an empty capped service cgroup was accepted"
fi
grep -q 'outside capped unit' "$WORK/dual_outside_empty.log" \
  || fail "outside-QEMU refusal did not identify the capped service"
if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" --print-yaml > "$WORK/dual_outside_path.log" 2>&1; then
  fail "--print-yaml accepted a QEMU outside the capped service"
fi
grep -q 'outside capped unit' "$WORK/dual_outside_path.log" \
  || fail "--print-yaml outside-QEMU refusal did not identify the capped service"

# With exactly one matching QEMU in the capped service, Running is accepted.
printf '8888\n' > "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/child/cgroup.procs"
printf '0::/fixture/lima-vm@colima.service/child\n' > "$DUAL_LIMA/proc/8888/cgroup"
PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
  LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
  LIMA_FIXTURE_STATUS=Running \
  "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" >/dev/null \
  || fail "exactly one QEMU in the capped service was rejected"

# Two matching QEMUs inside the capped service make Running ownership
# ambiguous and must fail closed.
mkdir -p "$DUAL_LIMA/proc/9999"
printf 'qemu-system-x86\n' > "$DUAL_LIMA/proc/9999/comm"
printf '%s\0' qemu-system-x86_64 -m 8192 -drive \
  "file=$DUAL_LIMA/lima/colima/diffdisk" > "$DUAL_LIMA/proc/9999/cmdline"
printf '0::/fixture/lima-vm@colima.service/child\n' > "$DUAL_LIMA/proc/9999/cgroup"
printf '8888\n9999\n' > "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/child/cgroup.procs"
if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    LIMA_FIXTURE_STATUS=Running \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" > "$WORK/dual_two_inside.log" 2>&1; then
  fail "two matching QEMUs inside the capped service were accepted"
fi
grep -q 'multiple QEMU processes' "$WORK/dual_two_inside.log" \
  || fail "two-inside refusal did not identify ambiguous ownership"

# A second QEMU outside the capped service must not be ignored just because
# the service-owned QEMU is valid.
mkdir -p "$DUAL_LIMA/proc/9999"
printf 'qemu-system-x86\n' > "$DUAL_LIMA/proc/9999/comm"
printf '%s\0' qemu-system-x86_64 -m 8192 -drive \
  "file=$DUAL_LIMA/lima/colima/diffdisk" > "$DUAL_LIMA/proc/9999/cmdline"
printf '0::/fixture/unrelated.scope\n' > "$DUAL_LIMA/proc/9999/cgroup"
printf '8888\n' > "$DUAL_LIMA/cgroup/fixture/lima-vm@colima.service/child/cgroup.procs"
printf '9999\n' > "$DUAL_LIMA/cgroup/fixture/unrelated.scope/cgroup.procs"
if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    LIMA_FIXTURE_STATUS=Running \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" > "$WORK/dual_second_outside.log" 2>&1; then
  fail "second QEMU outside the capped service was accepted"
fi
grep -q 'outside capped unit' "$WORK/dual_second_outside.log" \
  || fail "second outside-QEMU refusal did not identify the capped service"

# An empty ControlGroup cannot prove a Running QEMU is covered by the cap.
if PATH="$DUAL_LIMA/bin:$PATH" LIMA_YAML="$DUAL_LIMA/lima/colima/lima.yaml" \
    LIMA_PROC_ROOT="$DUAL_LIMA/proc" QEMU_CGROUP_ROOT="$DUAL_LIMA/cgroup" \
    LIMA_FIXTURE_STATUS=Running LIMA_EMPTY_CGROUP=1 \
    "$REPO_ROOT/scripts/host/lima-guest-memory-check.sh" > "$WORK/dual_empty_control_group.log" 2>&1; then
  fail "Running QEMU was accepted with an empty capped ControlGroup"
fi
grep -q 'capped unit' "$WORK/dual_empty_control_group.log" \
  || fail "empty ControlGroup refusal did not identify missing ownership"

MEM_BOUNDARY_ROOT="$WORK/mem_boundary"
setup_fixture "$MEM_BOUNDARY_ROOT"
printf 'MemTotal:       64079644 kB\n' > "$MEM_BOUNDARY_ROOT/proc/meminfo"
PATH="$MEM_BOUNDARY_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$MEM_BOUNDARY_ROOT" > "$WORK/mem_boundary.log" 2>&1   || fail "apply-host-containment-release1.sh failed when MemTotal was at exact computed floor"
ok "apply-host-containment-release1.sh succeeds when memory is at exact computed floor"

# 3c. Pre-mutation gate: current agent memory usage >= 10G
AGENT_MEM_FAIL_ROOT="$WORK/agent_mem_fail"
setup_fixture "$AGENT_MEM_FAIL_ROOT"
# 10 GiB current usage
printf '10737418240\n' > "$AGENT_MEM_FAIL_ROOT/sys/fs/cgroup/agents.slice/memory.current"
if PATH="$AGENT_MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$AGENT_MEM_FAIL_ROOT" > "$WORK/agent_mem.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when current agent memory usage was at high limit"
fi
[ ! -f "$AGENT_MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before agent memory check"
ok "apply-host-containment-release1.sh aborts before mutation when current agent use >= 10G"

# 3d. Pre-mutation gate: current automation memory usage >= 4.5G
AUTO_MEM_FAIL_ROOT="$WORK/auto_mem_fail"
setup_fixture "$AUTO_MEM_FAIL_ROOT"
# 4.5 GiB current usage (4608M = 4831838208 bytes)
printf '4831838208\n' > "$AUTO_MEM_FAIL_ROOT/sys/fs/cgroup/automation.slice/memory.current"
if PATH="$AUTO_MEM_FAIL_ROOT/bin:$PATH" "$APPLY_SCRIPT" --root "$AUTO_MEM_FAIL_ROOT" > "$WORK/auto_mem.log" 2>&1; then
  fail "apply-host-containment-release1.sh passed when current automation memory usage was at high limit"
fi
[ ! -f "$AUTO_MEM_FAIL_ROOT/etc/systemd/system/actions.slice" ] || fail "staged files before automation memory check"
ok "apply-host-containment-release1.sh aborts before mutation when current automation use >= 4.5G"

# 3e. Pre-mutation gate: current QEMU memory usage >= 9G (proof of highusage no writes)
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

# 3f. Pre-mutation gate: missing/unreadable current usage refusal for active service
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
lima-vm@colima.service ControlGroup
agents.slice ActiveState active
automation.slice ActiveState active
app-lima-vm.slice ActiveState active
actions.slice ManagedOOMMemoryPressure kill
actions.slice ManagedOOMMemoryPressureLimit 3435973836
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
  || fail "live apply did not set agents.slice to 10G/12G: $(grep agents "$WORK/live_sys.log" || echo none)"
ok "apply-host-containment-release1.sh live branch persists agents.slice 10G/12G and automation.slice 4608M/5G via set-property"

# The root phase enrolls actions.slice with systemd-oomd (kill at 80% pressure);
# agents.slice and automation.slice are never enrolled with kill.
grep -Fqx '    systemctl set-property actions.slice ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit=80%' "$APPLY_SCRIPT" \
  || fail "root phase does not enroll actions.slice with ManagedOOMMemoryPressure=kill at 80%"
! grep -E 'set-property (agents|automation)\.slice.*ManagedOOMMemoryPressure=kill' "$APPLY_SCRIPT" \
  || fail "agents/automation.slice must not be enrolled with oomd kill"
ok "apply-host-containment-release1.sh enrolls only actions.slice with oomd kill"

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
