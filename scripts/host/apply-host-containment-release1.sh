#!/usr/bin/env bash
# Apply Release 1 finite host containment envelope and boundary policies.
# Stages systemd host containment units and drop-ins, validates host resources,
# reloads systemd manager, and runs the sibling read-only assertion.
#
# Usage:
#   scripts/host/apply-host-containment-release1.sh [--root <fixture-root>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ROOT="/"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "OK: $*"
}

# 1. Single-writer lock
LOCK_DIR="${ROOT}/var/lock"
if [ ! -d "${LOCK_DIR}" ]; then
  LOCK_DIR="${ROOT}/tmp"
fi
mkdir -p "${LOCK_DIR}"
LOCK_FILE="${LOCK_DIR}/apply-host-containment.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  fail "another apply-host-containment process is running (${LOCK_FILE})"
fi

# 2. Pre-mutation resource gates
MEMINFO="${ROOT}/proc/meminfo"
[ -f "${MEMINFO}" ] || fail "missing ${MEMINFO}"
MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' "${MEMINFO}")
[ -n "${MEM_TOTAL_KB}" ] || fail "could not determine MemTotal from ${MEMINFO}"
if [ "${MEM_TOTAL_KB}" -lt 65011712 ]; then
  fail "MemTotal (${MEM_TOTAL_KB} kB) is below required 62 GiB floor (65011712 kB)"
fi

CPU_ONLINE="${ROOT}/sys/devices/system/cpu/online"
[ -f "${CPU_ONLINE}" ] || fail "missing ${CPU_ONLINE}"
CPU_COUNT=0
IFS=',' read -ra RANGES < "${CPU_ONLINE}"
for range in "${RANGES[@]}"; do
  if [[ "${range}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
    CPU_COUNT=$((CPU_COUNT + end - start + 1))
  elif [[ "${range}" =~ ^[0-9]+$ ]]; then
    CPU_COUNT=$((CPU_COUNT + 1))
  fi
done
if [ "${CPU_COUNT}" -lt 32 ]; then
  fail "online CPU count (${CPU_COUNT}) is below required 32 core floor"
fi

CONTROLLERS="${ROOT}/sys/fs/cgroup/cgroup.controllers"
[ -f "${CONTROLLERS}" ] || fail "missing cgroup controllers file: ${CONTROLLERS}"
for ctrl in cpu memory pids io; do
  if ! grep -qw "${ctrl}" "${CONTROLLERS}"; then
    fail "missing required cgroup v2 controller: ${ctrl}"
  fi
done

# Check current slice usage thresholds
AGENTS_MEM_CURRENT="${ROOT}/sys/fs/cgroup/agents.slice/memory.current"
if [ -f "${AGENTS_MEM_CURRENT}" ]; then
  CURRENT_BYTES=$(cat "${AGENTS_MEM_CURRENT}")
  # 18 GiB = 19327352832 bytes
  if [ "${CURRENT_BYTES}" -ge 19327352832 ]; then
    fail "agents.slice memory.current (${CURRENT_BYTES} bytes) exceeds 18 GiB threshold"
  fi
fi

AUTOMATION_MEM_CURRENT="${ROOT}/sys/fs/cgroup/automation.slice/memory.current"
if [ -f "${AUTOMATION_MEM_CURRENT}" ]; then
  AUTO_CURRENT_BYTES=$(cat "${AUTOMATION_MEM_CURRENT}")
  # 4 GiB = 4294967296 bytes
  if [ "${AUTO_CURRENT_BYTES}" -ge 4294967296 ]; then
    fail "automation.slice memory.current (${AUTO_CURRENT_BYTES} bytes) exceeds 4 GiB threshold"
  fi
fi

# 3. Stage finite containment policy and boundary drop-ins
SYS_DIR="${ROOT}/etc/systemd/system"
USER_DIR="${ROOT}/etc/systemd/user"
mkdir -p "${SYS_DIR}/-.slice.d" \
         "${SYS_DIR}/user.slice.d" \
         "${SYS_DIR}/user-.slice.d" \
         "${SYS_DIR}/user@.service.d" \
         "${USER_DIR}/app.slice.d" \
         "${USER_DIR}/session.slice.d"

cp "${REPO_ROOT}/systemd/host/actions.slice" "${SYS_DIR}/actions.slice"
cp "${REPO_ROOT}/systemd/host/-.slice.d/99-ezgha-containment.conf" "${SYS_DIR}/-.slice.d/99-ezgha-containment.conf"
cp "${REPO_ROOT}/systemd/host/user.slice.d/99-ezgha-containment.conf" "${SYS_DIR}/user.slice.d/99-ezgha-containment.conf"
cp "${REPO_ROOT}/systemd/host/user-.slice.d/99-ezgha-containment.conf" "${SYS_DIR}/user-.slice.d/99-ezgha-containment.conf"
cp "${REPO_ROOT}/systemd/host/user@.service.d/99-ezgha-containment.conf" "${SYS_DIR}/user@.service.d/99-ezgha-containment.conf"

cp "${REPO_ROOT}/systemd/user/app.slice.d/99-ezgha-containment.conf" "${USER_DIR}/app.slice.d/99-ezgha-containment.conf"
cp "${REPO_ROOT}/systemd/user/session.slice.d/99-ezgha-containment.conf" "${USER_DIR}/session.slice.d/99-ezgha-containment.conf"
cp "${REPO_ROOT}/systemd/agents.slice" "${USER_DIR}/agents.slice"
cp "${REPO_ROOT}/systemd/automation.slice" "${USER_DIR}/automation.slice"

# Remove legacy watcher and exemption drop-ins
rm -f "${SYS_DIR}/ezgha.service.d/10-oomd-omit.conf" \
      "${SYS_DIR}/psi-oom-watcher.service" \
      "${SYS_DIR}/psi-oom-watcher.timer" \
      "${USER_DIR}/psi-oom-watcher.service" \
      "${USER_DIR}/psi-oom-watcher.timer"

# 4. Reload systemd daemon
if command -v systemctl >/dev/null 2>&1; then
  if [ "${ROOT}" = "/" ]; then
    systemctl daemon-reload || true
    systemctl --user daemon-reload || true
  fi
fi

# 5. Invoke sibling assertion
ASSERT_SCRIPT="${SCRIPT_DIR}/assert-host-containment-release1.sh"
[ -f "${ASSERT_SCRIPT}" ] || fail "missing sibling assertion script: ${ASSERT_SCRIPT}"

if ! "${ASSERT_SCRIPT}" --root "${ROOT}"; then
  fail "Release 1 containment assertion failed; leaving ezgha.service inactive"
fi

ok "Release 1 host containment applied and verified"
