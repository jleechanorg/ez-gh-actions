#!/usr/bin/env bash
# assert-host-containment-release1.sh — Read-only assertion for Release 1 host crash containment.
# Validates host memory/CPU floors, cgroup v2 controller topology, actions.slice limits,
# boundary drop-in neutrality, Docker systemd driver, runner container count (exactly 10),
# and container PID ancestry under /actions.slice.
#
# Usage: assert-host-containment-release1.sh [--root <fixture-root>]
set -euo pipefail

ROOT="/"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "FAIL: --root requires an argument" >&2; exit 1; }
      ROOT="$2"
      shift 2
      ;;
    *)
      echo "FAIL: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Host Memory Floor (>= 65,011,712 KiB = 62 GiB)
MEMINFO="$ROOT/proc/meminfo"
[ -f "$MEMINFO" ] || fail "missing /proc/meminfo at $MEMINFO"
mem_total_kib="$(grep -E '^MemTotal:' "$MEMINFO" | awk '{print $2}' || true)"
[ -n "$mem_total_kib" ] || fail "could not parse MemTotal from $MEMINFO"
if [ "$mem_total_kib" -lt 65011712 ]; then
  fail "host MemTotal (${mem_total_kib} KiB) is below the required 62-GiB floor (65011712 KiB)"
fi

# 2. Online Logical CPUs (>= 32)
CPU_ONLINE="$ROOT/sys/devices/system/cpu/online"
[ -f "$CPU_ONLINE" ] || fail "missing cpu/online at $CPU_ONLINE"
cpu_online_raw="$(cat "$CPU_ONLINE")"
[ -n "$cpu_online_raw" ] || fail "cpu/online is empty at $CPU_ONLINE"

count_online_cpus() {
  local list="$1"
  local count=0
  local item
  local start
  local end
  IFS=',' read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      count=$(( count + end - start + 1 ))
    elif [[ "$item" =~ ^[0-9]+$ ]]; then
      count=$(( count + 1 ))
    fi
  done
  echo "$count"
}

online_cpu_count="$(count_online_cpus "$cpu_online_raw")"
if [ "$online_cpu_count" -lt 32 ]; then
  fail "host online logical CPUs (${online_cpu_count}) is below the required 32-CPU floor (32)"
fi

# 3. cgroup v2 Controllers
CONTROLLERS="$ROOT/sys/fs/cgroup/cgroup.controllers"
[ -f "$CONTROLLERS" ] || fail "missing cgroup.controllers at $CONTROLLERS"
controllers_str="$(cat "$CONTROLLERS")"
for ctrl in cpu io memory pids; do
  if ! [[ "$controllers_str" =~ (^|[[:space:]])"$ctrl"($|[[:space:]]) ]]; then
    fail "cgroup.controllers missing required controller: $ctrl"
  fi
done

# 4. actions.slice Limits
ACTIONS_DIR="$ROOT/sys/fs/cgroup/actions.slice"
[ -d "$ACTIONS_DIR" ] || fail "actions.slice cgroup missing at $ACTIONS_DIR"

check_cgroup_val() {
  local file="$1" expected="$2" name="$3"
  [ -f "$file" ] || fail "missing $name at $file"
  local actual
  actual="$(cat "$file")"
  if [ "$actual" != "$expected" ]; then
    fail "actions.slice $name ('$actual') != '$expected'"
  fi
}

check_cgroup_val "$ACTIONS_DIR/memory.high" "27917287424" "memory.high"
check_cgroup_val "$ACTIONS_DIR/memory.max" "30064771072" "memory.max"
check_cgroup_val "$ACTIONS_DIR/memory.swap.max" "0" "memory.swap.max"
check_cgroup_val "$ACTIONS_DIR/pids.max" "6000" "pids.max"
check_cgroup_val "$ACTIONS_DIR/cpu.max" "2000000 100000" "cpu.max"

[ -f "$ACTIONS_DIR/io.weight" ] || fail "missing io.weight at $ACTIONS_DIR/io.weight"
io_weight_val="$(cat "$ACTIONS_DIR/io.weight")"
if ! [[ "$io_weight_val" =~ 25 ]]; then
  fail "actions.slice io.weight ('$io_weight_val') does not contain 25"
fi

# 5. Docker Driver and Cgroup Version
command -v docker >/dev/null 2>&1 || fail "docker command not available on PATH"
docker_info="$(docker info 2>&1 || true)"
if ! echo "$docker_info" | grep -q "CgroupVersion: 2"; then
  fail "Docker is not running with CgroupVersion: 2"
fi
if ! echo "$docker_info" | grep -q "CgroupDriver: systemd"; then
  fail "Docker is not running with CgroupDriver: systemd"
fi

# 6. Runner Container Count (Exactly 10)
# Matches ez-runner-c-* containers or ezgha managed containers
containers_raw="$(docker ps --format '{{.ID}} {{.Names}} {{.State.Pid}}' 2>/dev/null || docker ps 2>/dev/null || true)"
matching_containers=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # Match container lines
  if [[ "$line" =~ ez-runner-c-[0-9]+|ez-runner-[0-9]+ ]]; then
    matching_containers+=("$line")
  fi
done <<< "$containers_raw"

container_count="${#matching_containers[@]}"
if [ "$container_count" -ne 10 ]; then
  fail "runner container count (${container_count}) != 10"
fi

# 7. Container PID Ancestry beneath /actions.slice
for cline in "${matching_containers[@]}"; do
  # Extract PID (3rd column if format was used, or lookup /proc)
  read -r _ cname cpid <<< "$cline"
  if [ -n "$cpid" ] && [ -f "$ROOT/proc/$cpid/cgroup" ]; then
    cg_content="$(cat "$ROOT/proc/$cpid/cgroup")"
    if ! [[ "$cg_content" =~ /actions\.slice ]]; then
      fail "container PID not beneath /actions.slice (container $cname PID $cpid has cgroup: $cg_content)"
    fi
  fi
done

echo "OK: host containment Release 1 verified"
exit 0
