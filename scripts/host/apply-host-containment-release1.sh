#!/usr/bin/env bash
# Apply finite Release 1 host containment without restarting the desktop,
# user manager, Docker daemon, or runner containers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="/"
SYSTEM_PHASE=0
RUNNER_COUNT=14
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --system-phase) SYSTEM_PHASE=1; shift ;;
    --runner-count)
      [ "$#" -ge 2 ] || fail "--runner-count requires 10 or 14"
      RUNNER_COUNT="$2"; shift 2 ;;
    *) echo "FAIL: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
case "$RUNNER_COUNT" in
  10)
    ACTIONS_PIDS_MAX=6000
    ACTIONS_PIDS_PROPERTY="TasksMax=6000"
    ;;
  14)
    ACTIONS_PIDS_MAX=8000
    ACTIONS_PIDS_PROPERTY="TasksMax=8000"
    ;;
  *) fail "runner count must be 10 or 14 (got $RUNNER_COUNT)" ;;
esac
ACTIONS_MEMORY_HIGH_BYTES=27917287424

if [ -d "${SCRIPT_DIR}/../../systemd/host" ]; then
  POLICY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
elif [ -d "${SCRIPT_DIR}/host-containment-policy/systemd/host" ]; then
  POLICY_ROOT="${SCRIPT_DIR}/host-containment-policy"
else
  fail "missing tracked host containment policy beside activation script"
fi

if [ "$ROOT" = "/" ]; then
  if [ "$SYSTEM_PHASE" -eq 1 ]; then
    [ "$(id -u)" -eq 0 ] || fail "system phase must run as root"
    DEPLOY_UID="${SUDO_UID:-${PKEXEC_UID:-}}"
    [[ "$DEPLOY_UID" =~ ^[1-9][0-9]*$ ]] || fail "system phase requires the invoking deploy user identity"
  else
    [ "$(id -u)" -ne 0 ] || fail "run user phase as the deploy user, not root"
    DEPLOY_UID="$(id -u)"
  fi
  USER_UNIT_DIR="${HOME}/.config/systemd/user"
else
  USER_UNIT_DIR="${ROOT}/etc/systemd/user"
fi
SYS_DIR="${ROOT}/etc/systemd/system"
CGROUP_ROOT="${ROOT}/sys/fs/cgroup"

read_value() { [ -f "$1" ] && cat "$1"; }
check_below() {
  local file="$1" limit="$2" label="$3" value
  [ -e "$file" ] || return 0
  value="$(read_value "$file")" || fail "could not read ${label} at ${file}"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "invalid ${label}: ${value}"
  [ "$value" -lt "$limit" ] || fail "${label} (${value} bytes) is at or above its safe activation threshold"
}
user_cgroup_dir() {
  local unit="$1" group
  if [ "$ROOT" != "/" ]; then
    if [ -d "$CGROUP_ROOT/$unit" ]; then printf '%s/%s' "$CGROUP_ROOT" "$unit"; fi
    return
  fi
  group="$(systemctl --user show "$unit" -p ControlGroup --value 2>/dev/null || true)"
  [ -n "$group" ] && printf '%s%s' "$CGROUP_ROOT" "$group"
}

# Every gate precedes writes or systemd state changes.
mem_total_kib="$(awk '/^MemTotal:/ {print $2}' "${ROOT}/proc/meminfo" 2>/dev/null || true)"
[[ "$mem_total_kib" =~ ^[0-9]+$ ]] || fail "could not determine MemTotal"
hard_limits_sum_kib=$(( (28 + 10 + 12 + 5) * 1024 * 1024 ))
reserve_kib=$(( mem_total_kib / 10 ))
[ "$reserve_kib" -ge 2097152 ] || reserve_kib=2097152
computed_floor_kib=$(( hard_limits_sum_kib + reserve_kib ))
[ "$mem_total_kib" -ge "$computed_floor_kib" ] || fail "MemTotal (${mem_total_kib} KiB) is below required computed floor (${computed_floor_kib} KiB)"
[ -f "${ROOT}/sys/devices/system/cpu/online" ] || fail "missing cpu/online"
cpu_count=0; IFS=',' read -r -a cpu_ranges < "${ROOT}/sys/devices/system/cpu/online"
for range in "${cpu_ranges[@]}"; do
  if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then cpu_count=$((cpu_count + BASH_REMATCH[2] - BASH_REMATCH[1] + 1));
  elif [[ "$range" =~ ^[0-9]+$ ]]; then cpu_count=$((cpu_count + 1)); fi
done
[ "$cpu_count" -ge 32 ] || fail "online CPU count (${cpu_count}) is below required 32 core floor"
for controller in cpu memory pids io; do
  grep -qw "$controller" "${CGROUP_ROOT}/cgroup.controllers" 2>/dev/null || fail "missing required cgroup v2 controller: ${controller}"
done
check_below "${CGROUP_ROOT}/actions.slice/memory.current" "$ACTIONS_MEMORY_HIGH_BYTES" "actions.slice memory.current"
check_below "${CGROUP_ROOT}/actions.slice/pids.current" "$ACTIONS_PIDS_MAX" "actions.slice pids.current"
agents_dir="$(user_cgroup_dir agents.slice || true)"
automation_dir="$(user_cgroup_dir automation.slice || true)"
qemu_slice_dir="$(user_cgroup_dir app-lima-vm.slice || true)"
qemu_svc_dir="$(user_cgroup_dir lima-vm@colima.service || true)"
[ -z "$agents_dir" ] || check_below "${agents_dir}/memory.current" 10737418240 "agents.slice memory.current"
[ -z "$automation_dir" ] || check_below "${automation_dir}/memory.current" 4294967296 "automation.slice memory.current"
[ -z "$qemu_slice_dir" ] || check_below "${qemu_slice_dir}/memory.current" 9663676416 "app-lima-vm.slice memory.current"
[ -z "$qemu_svc_dir" ] || check_below "${qemu_svc_dir}/memory.current" 9663676416 "lima-vm@colima.service memory.current"

install_file() {
  local source="$1" dest="$2"
  [ -f "$source" ] || fail "missing tracked policy source: ${source}"
  mkdir -p "$(dirname "$dest")"
  install -m 0644 "$source" "$dest"
}
install_system_file() {
  local source="$1" dest="$2"
  [ -f "$source" ] || fail "missing tracked policy source: ${source}"
  if [ "$ROOT" = "/" ]; then install -D -m 0644 "$source" "$dest"; else install_file "$source" "$dest"; fi
}

if [ "$SYSTEM_PHASE" -eq 1 ] || [ "$ROOT" != "/" ]; then
  install_system_file "${POLICY_ROOT}/systemd/host/actions.slice" "${SYS_DIR}/actions.slice"
  for path in -.slice.d user.slice.d user-.slice.d user@.service.d; do
    install_system_file "${POLICY_ROOT}/systemd/host/${path}/99-ezgha-containment.conf" "${SYS_DIR}/${path}/99-ezgha-containment.conf"
  done
  rm -f "${SYS_DIR}/ezgha.service.d/10-oomd-omit.conf" "${SYS_DIR}/psi-oom-watcher.service" "${SYS_DIR}/psi-oom-watcher.timer"
  if [ "$ROOT" = "/" ]; then
    systemctl daemon-reload
    systemctl set-property "user@${DEPLOY_UID}.service" \
      ManagedOOMMemoryPressure=auto ManagedOOMSwap=auto ManagedOOMPreference=none
    for property in ManagedOOMMemoryPressure=auto ManagedOOMSwap=auto ManagedOOMPreference=none OOMScoreAdjust=0; do
      key="${property%%=*}"; expected="${property#*=}"
      actual="$(systemctl show "user@${DEPLOY_UID}.service" -p "$key" --value)"
      [ "$actual" = "$expected" ] || fail "user@${DEPLOY_UID}.service ${key} ('$actual') != '$expected' after runtime policy apply"
    done
    user_manager_pid="$(systemctl show "user@${DEPLOY_UID}.service" -p MainPID --value)"
    [[ "$user_manager_pid" =~ ^[1-9][0-9]*$ ]] || fail "could not resolve user@${DEPLOY_UID}.service MainPID"
    grep -q "/user@${DEPLOY_UID}\.service" "/proc/${user_manager_pid}/cgroup" \
      || fail "user manager PID ${user_manager_pid} is not in user@${DEPLOY_UID}.service"
    printf '0\n' > "/proc/${user_manager_pid}/oom_score_adj"
    [ "$(cat "/proc/${user_manager_pid}/oom_score_adj")" = 0 ] \
      || fail "user manager OOM score adjustment did not become 0"
    systemctl enable actions.slice
    systemctl start actions.slice
    systemctl set-property actions.slice MemoryHigh=26G MemoryMax=28G MemorySwapMax=0 "$ACTIONS_PIDS_PROPERTY" CPUQuota=2000% IOWeight=25
  fi
fi

if [ "$SYSTEM_PHASE" -eq 0 ] || [ "$ROOT" != "/" ]; then
  # Only the documented, exact legacy override is migrated. Other local
  # overrides remain a hard error rather than being silently superseded.
  for unit in agents.slice automation.slice; do
    dropin_dir="${USER_UNIT_DIR}/${unit}.d"
    [ -d "$dropin_dir" ] || continue
    while IFS= read -r dropin; do
      case "$dropin" in *99-ezgha-containment.conf) continue ;; esac
      if grep -Eq '^[[:space:]]*(MemoryHigh|MemoryMax|MemorySwapMax)[[:space:]]*=[[:space:]]*(infinity|max)[[:space:]]*$' "$dropin"; then
        known_legacy="${USER_UNIT_DIR}/agents.slice.d/99-local-unlimited.conf"
        if [ "$unit" = agents.slice ] && [ "$dropin" = "$known_legacy" ]; then
          backup="${known_legacy}.ezgha-pre-containment.bak"
          cp -a "$known_legacy" "$backup"
          rm -f "$known_legacy"
        else
          fail "conflicting unlimited ${unit} override: ${dropin}; remove or replace that exact override before activation"
        fi
      fi
    done < <(find "$dropin_dir" -maxdepth 1 -type f -name '*.conf' -print | sort)
  done
  install_file "${POLICY_ROOT}/systemd/user/app.slice.d/99-ezgha-containment.conf" "${USER_UNIT_DIR}/app.slice.d/99-ezgha-containment.conf"
  install_file "${POLICY_ROOT}/systemd/user/session.slice.d/99-ezgha-containment.conf" "${USER_UNIT_DIR}/session.slice.d/99-ezgha-containment.conf"
  install_file "${POLICY_ROOT}/systemd/agents.slice" "${USER_UNIT_DIR}/agents.slice"
  install_file "${POLICY_ROOT}/systemd/automation.slice" "${USER_UNIT_DIR}/automation.slice"
  install_file "${POLICY_ROOT}/systemd/app-lima-vm.slice" "${USER_UNIT_DIR}/app-lima-vm.slice"
  install_file "${POLICY_ROOT}/systemd/lima-vm@colima.service.d/99-memory-ceiling.conf" "${USER_UNIT_DIR}/lima-vm@colima.service.d/99-memory-ceiling.conf"
  rm -f "${USER_UNIT_DIR}/psi-oom-watcher.service" "${USER_UNIT_DIR}/psi-oom-watcher.timer"
  # CONTAINMENT_LIVE_SYSTEMD=1 lets tests run the live user-systemd branch
  # against a --root fixture with a fake systemctl on PATH.
  if [ "$ROOT" = "/" ] || [ "${CONTAINMENT_LIVE_SYSTEMD:-0}" = 1 ]; then
    systemctl --user daemon-reload
    systemctl --user start agents.slice automation.slice
    systemctl --user set-property agents.slice MemoryHigh=10G MemoryMax=12G MemorySwapMax=2G TasksMax=8192
    systemctl --user set-property automation.slice MemoryHigh=4G MemoryMax=5G MemorySwapMax=1G TasksMax=4096
    if systemctl --user is-active lima-vm@colima.service >/dev/null 2>&1 || [ "$ROOT" != "/" ]; then
      systemctl --user set-property --runtime lima-vm@colima.service MemoryHigh=9G MemoryMax=10G MemorySwapMax=2G TasksMax=4096 CPUQuota=1600% 2>/dev/null || true
    fi
  fi
fi

if [ "$SYSTEM_PHASE" -eq 0 ] || [ "$ROOT" != "/" ]; then
  ASSERT_SCRIPT="${SCRIPT_DIR}/assert-host-containment-release1.sh"
  [ -x "$ASSERT_SCRIPT" ] || fail "missing sibling assertion script: ${ASSERT_SCRIPT}"
  "$ASSERT_SCRIPT" --root "$ROOT" --runner-count "$RUNNER_COUNT"
fi
ok "Release 1 host containment ${SYSTEM_PHASE:+system }phase applied"
