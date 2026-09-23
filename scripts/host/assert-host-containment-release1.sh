#!/usr/bin/env bash
# Read-only Release 1 host-containment assertion.
set -euo pipefail

ROOT="/"
REQUIRE_FLEET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --require-fleet) REQUIRE_FLEET=1; shift ;;
    *) echo "FAIL: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
fail() { echo "FAIL: $*" >&2; exit 1; }

mem_total_kib="$(awk '/^MemTotal:/ {print $2}' "$ROOT/proc/meminfo" 2>/dev/null || true)"
[[ "$mem_total_kib" =~ ^[0-9]+$ ]] || fail "could not parse MemTotal from $ROOT/proc/meminfo"
[ "$mem_total_kib" -ge 65011712 ] || fail "host MemTotal (${mem_total_kib} KiB) is below the required 62-GiB floor (65011712 KiB)"

[ -f "$ROOT/sys/devices/system/cpu/online" ] || fail "missing cpu/online"
cpu_count=0; IFS=',' read -r -a cpu_ranges < "$ROOT/sys/devices/system/cpu/online"
for range in "${cpu_ranges[@]}"; do
  if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then cpu_count=$((cpu_count + BASH_REMATCH[2] - BASH_REMATCH[1] + 1));
  elif [[ "$range" =~ ^[0-9]+$ ]]; then cpu_count=$((cpu_count + 1)); fi
done
[ "$cpu_count" -ge 32 ] || fail "host online logical CPUs (${cpu_count}) is below the required 32-CPU floor (32)"
for controller in cpu io memory pids; do
  grep -qw "$controller" "$ROOT/sys/fs/cgroup/cgroup.controllers" 2>/dev/null || fail "cgroup.controllers missing required controller: $controller"
done

ACTIONS_DIR="$ROOT/sys/fs/cgroup/actions.slice"
[ -d "$ACTIONS_DIR" ] || fail "actions.slice cgroup missing at $ACTIONS_DIR"
check_cgroup_val() {
  local file="$1" expected="$2" name="$3" actual
  [ -f "$file" ] || fail "missing $name at $file"
  actual="$(cat "$file")"
  [ "$actual" = "$expected" ] || fail "actions.slice $name ('$actual') != '$expected'"
}
check_cgroup_val "$ACTIONS_DIR/memory.high" 27917287424 memory.high
check_cgroup_val "$ACTIONS_DIR/memory.max" 30064771072 memory.max
check_cgroup_val "$ACTIONS_DIR/memory.swap.max" 0 memory.swap.max
check_cgroup_val "$ACTIONS_DIR/pids.max" 6000 pids.max
check_cgroup_val "$ACTIONS_DIR/cpu.max" "2000000 100000" cpu.max
io_weight="$(cat "$ACTIONS_DIR/io.weight" 2>/dev/null || true)"
[[ "$io_weight" =~ (^|[[:space:]])25($|[[:space:]]) ]] || fail "actions.slice io.weight ('$io_weight') does not contain 25"

if [ "$ROOT" = "/" ]; then
  check_user_property() {
    local unit="$1" property="$2" expected="$3" actual
    actual="$(systemctl --user show -p "$property" --value -- "$unit")"
    [ "$actual" = "$expected" ] || fail "${unit} ${property} ('$actual') != '$expected'"
  }
  check_user_property agents.slice MemoryHigh 19327352832
  check_user_property agents.slice MemoryMax 21474836480
  check_user_property agents.slice MemorySwapMax 2147483648
  check_user_property automation.slice MemoryHigh 4294967296
  check_user_property automation.slice MemoryMax 6442450944
  check_user_property automation.slice MemorySwapMax 1073741824
  check_system_property() {
    local unit="$1" property="$2" expected="$3" actual
    actual="$(systemctl show -p "$property" --value -- "$unit")"
    [ "$actual" = "$expected" ] || fail "${unit} ${property} ('$actual') != '$expected'"
  }
  deploy_uid="$(id -u)"
  check_system_property "user@${deploy_uid}.service" ManagedOOMMemoryPressure auto
  check_system_property "user@${deploy_uid}.service" ManagedOOMSwap auto
  check_system_property "user@${deploy_uid}.service" ManagedOOMPreference none
  check_system_property "user@${deploy_uid}.service" OOMScoreAdjust 0
  check_system_property -.slice ManagedOOMMemoryPressure auto
  check_system_property user.slice ManagedOOMMemoryPressure auto
  check_user_property app.slice ManagedOOMMemoryPressure auto
  check_user_property session.slice ManagedOOMMemoryPressure auto
fi

if [ "$REQUIRE_FLEET" -eq 1 ]; then
  command -v docker >/dev/null 2>&1 || fail "docker command not available on PATH"
  docker_cmd() { env -u DOCKER_HOST -u DOCKER_CONTEXT docker --host unix:///var/run/docker.sock "$@"; }
  docker_cgroup="$(docker_cmd info --format '{{.CgroupVersion}} {{.CgroupDriver}}' 2>/dev/null || true)"
  [ "$docker_cgroup" = "2 systemd" ] || fail "Docker cgroup mode ('$docker_cgroup') != '2 systemd'"
  mapfile -t containers < <(docker_cmd ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk '$2 ~ /^ez-runner-c-[0-9]+$/ {print $1 " " $2}')
  [ "${#containers[@]}" -eq 10 ] || fail "runner container count (${#containers[@]}) != 10"
  for container in "${containers[@]}"; do
    read -r cid cname <<< "$container"
    cpid="$(docker_cmd inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null || true)"
    [[ "$cpid" =~ ^[1-9][0-9]*$ ]] || fail "could not resolve live PID for runner container ${cname} (${cid})"
    cgroup_file="$ROOT/proc/$cpid/cgroup"
    [ -f "$cgroup_file" ] || fail "missing cgroup record for runner container ${cname} PID ${cpid}"
    cg_content="$(cat "$cgroup_file")"
    [[ "$cg_content" =~ ^0::/actions\.slice/ ]] || fail "container PID not beneath /actions.slice (container $cname PID $cpid has cgroup: $cg_content)"
  done
fi

echo "OK: host containment Release 1 verified"
