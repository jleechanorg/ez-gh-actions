#!/usr/bin/env bash
# Guard against lowering QEMU resource ceilings beneath live usage.
# Reusable mechanism for install.sh, apply-host-containment-release1.sh,
# and lima-vm-cpu-ceiling.service.
set -euo pipefail

UNIT="lima-vm@colima.service"
THRESHOLD_BYTES=9663676416 # 9 GiB
ROOT="/"
ACTION="guard" # guard, apply, or assert-effective

fail() { echo "FAIL: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --unit) UNIT="$2"; shift 2 ;;
    --threshold) THRESHOLD_BYTES="$2"; shift 2 ;;
    --apply) ACTION="apply"; shift ;;
    --assert-effective) ACTION="assert-effective"; shift ;;
    *) fail "unknown argument '$1'" ;;
  esac
done

# Fixture roots never invoke the host systemd manager.
SYSTEMCTL=systemctl
if [ "$ROOT" != / ]; then SYSTEMCTL="$ROOT/bin/systemctl"; fi
ACTIVE=0
if [ "$ROOT" = / ] || [ "${CONTAINMENT_LIVE_SYSTEMD:-0}" = 1 ]; then
  state="$("$SYSTEMCTL" --user show "$UNIT" -p ActiveState --value)" || fail "cannot query $UNIT ActiveState"
  case "$state" in
    active|activating|reloading|deactivating) ACTIVE=1 ;;
    inactive|failed) ;;
    *) fail "unrecognized $UNIT ActiveState: $state" ;;
  esac
elif [[ " ${CONTAINMENT_ACTIVE_UNITS:-} " == *" ${UNIT} "* ]]; then
  ACTIVE=1
else
  for candidate in "$ROOT/sys/fs/cgroup/$UNIT" "$ROOT/sys/fs/cgroup/app-lima-vm.slice/$UNIT" "$ROOT/sys/fs/cgroup/app.slice/$UNIT"; do
    [ ! -d "$candidate" ] || ACTIVE=1
  done
fi
is_active() { [ "$ACTIVE" -eq 1 ]; }

resolve_cgroup_dir() {
  if [ "$ROOT" != "/" ]; then
    for candidate in "$ROOT/sys/fs/cgroup/$UNIT" "$ROOT/sys/fs/cgroup/app-lima-vm.slice/$UNIT" "$ROOT/sys/fs/cgroup/app.slice/$UNIT"; do
      if [ -d "$candidate" ]; then echo "$candidate"; return 0; fi
    done
    return 1
  fi
  local group
  group="$("$SYSTEMCTL" --user show "$UNIT" -p ControlGroup --value 2>/dev/null || true)"
  [ -n "$group" ] || return 1
  echo "/sys/fs/cgroup${group}"
}

guard_live_usage() {
  if ! is_active; then
    return 0
  fi
  local cg_dir
  cg_dir="$(resolve_cgroup_dir || true)"
  [ -n "$cg_dir" ] || fail "active service $UNIT has no resolved cgroup directory"
  local mem_file="$cg_dir/memory.current"
  [ -f "$mem_file" ] || fail "active service $UNIT missing memory.current at $mem_file"
  local current_usage
  current_usage="$(cat "$mem_file" 2>/dev/null || true)"
  [[ "$current_usage" =~ ^[0-9]+$ ]] || fail "active service $UNIT could not read numeric memory.current from $mem_file"
  if [ "$current_usage" -ge "$THRESHOLD_BYTES" ]; then
    fail "refusing to lower $UNIT: current memory usage ($current_usage bytes) >= threshold ($THRESHOLD_BYTES bytes)"
  fi
}

assert_effective_values() {
  if ! is_active; then
    return 0
  fi
  local high max swap tasks quota
  high="$("$SYSTEMCTL" --user show -p MemoryHigh --value "$UNIT" 2>/dev/null || true)"
  max="$("$SYSTEMCTL" --user show -p MemoryMax --value "$UNIT" 2>/dev/null || true)"
  swap="$("$SYSTEMCTL" --user show -p MemorySwapMax --value "$UNIT" 2>/dev/null || true)"
  tasks="$("$SYSTEMCTL" --user show -p TasksMax --value "$UNIT" 2>/dev/null || true)"
  quota="$("$SYSTEMCTL" --user show -p CPUQuotaPerSecUSec --value "$UNIT" 2>/dev/null || true)"
  [ -n "$quota" ] || quota="$("$SYSTEMCTL" --user show -p CPUQuota --value "$UNIT" 2>/dev/null || true)"

  [ "$high" = "9663676416" ] || fail "$UNIT effective MemoryHigh ('$high') != '9663676416'"
  [ "$max" = "10737418240" ] || fail "$UNIT effective MemoryMax ('$max') != '10737418240'"
  [ "$swap" = "2147483648" ] || fail "$UNIT effective MemorySwapMax ('$swap') != '2147483648'"
  [ "$tasks" = "4096" ] || fail "$UNIT effective TasksMax ('$tasks') != '4096'"
  case "$quota" in
    16s|1600%) ;;
    *) fail "$UNIT effective CPUQuota ('$quota') != '16s' / '1600%'" ;;
  esac
}

case "$ACTION" in
  guard)
    guard_live_usage
    ;;
  assert-effective)
    assert_effective_values
    ;;
  apply)
    guard_live_usage
    if is_active; then
      "$SYSTEMCTL" --user set-property --runtime "$UNIT" MemoryHigh=9G MemoryMax=10G MemorySwapMax=2G TasksMax=4096 CPUQuota=1600%
      assert_effective_values
    fi
    ;;
esac
