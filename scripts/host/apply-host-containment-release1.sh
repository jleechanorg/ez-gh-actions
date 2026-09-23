#!/usr/bin/env bash
# Apply finite Release 1 host containment without restarting the desktop,
# user manager, Docker daemon, or runner containers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="/"
SYSTEM_PHASE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --system-phase) SYSTEM_PHASE=1; shift ;;
    *) echo "FAIL: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

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
  if [ "$ROOT" != "/" ]; then printf '%s/%s' "$CGROUP_ROOT" "$unit"; return; fi
  group="$(systemctl --user show "$unit" -p ControlGroup --value 2>/dev/null || true)"
  [ -n "$group" ] && printf '%s%s' "$CGROUP_ROOT" "$group"
}

# Every gate precedes writes or systemd state changes.
mem_total_kib="$(awk '/^MemTotal:/ {print $2}' "${ROOT}/proc/meminfo" 2>/dev/null || true)"
[[ "$mem_total_kib" =~ ^[0-9]+$ ]] || fail "could not determine MemTotal"
[ "$mem_total_kib" -ge 65011712 ] || fail "MemTotal (${mem_total_kib} KiB) is below required 62 GiB floor"
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
check_below "${CGROUP_ROOT}/actions.slice/memory.current" 27917287424 "actions.slice memory.current"
check_below "${CGROUP_ROOT}/actions.slice/pids.current" 6000 "actions.slice pids.current"
agents_dir="$(user_cgroup_dir agents.slice || true)"
automation_dir="$(user_cgroup_dir automation.slice || true)"
[ -z "$agents_dir" ] || check_below "${agents_dir}/memory.current" 19327352832 "agents.slice memory.current"
[ -z "$automation_dir" ] || check_below "${automation_dir}/memory.current" 4294967296 "automation.slice memory.current"

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
    systemctl start actions.slice
    systemctl set-property actions.slice MemoryHigh=26G MemoryMax=28G MemorySwapMax=0 TasksMax=6000 CPUQuota=2000% IOWeight=25
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
  rm -f "${USER_UNIT_DIR}/psi-oom-watcher.service" "${USER_UNIT_DIR}/psi-oom-watcher.timer"
  if [ "$ROOT" = "/" ]; then
    systemctl --user daemon-reload
    systemctl --user start agents.slice automation.slice
    systemctl --user set-property agents.slice MemoryHigh=18G MemoryMax=20G MemorySwapMax=2G TasksMax=8192
    systemctl --user set-property automation.slice MemoryHigh=4G MemoryMax=6G MemorySwapMax=1G TasksMax=4096
  fi
fi

if [ "$SYSTEM_PHASE" -eq 0 ] || [ "$ROOT" != "/" ]; then
  ASSERT_SCRIPT="${SCRIPT_DIR}/assert-host-containment-release1.sh"
  [ -x "$ASSERT_SCRIPT" ] || fail "missing sibling assertion script: ${ASSERT_SCRIPT}"
  "$ASSERT_SCRIPT" --root "$ROOT"
fi
ok "Release 1 host containment ${SYSTEM_PHASE:+system }phase applied"
