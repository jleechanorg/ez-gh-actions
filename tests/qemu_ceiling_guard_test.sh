#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/sys/fs/cgroup/lima-vm@colima.service"
export LOG="$WORK/events"
cat > "$WORK/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
case " $* " in
  *' set-property '*) exit "${SET_FAIL:-0}" ;;
  *' -p ActiveState '*) [ "${QUERY_FAIL:-0}" = 0 ] || exit 1; echo "${STATE:-active}" ;;
  *' -p MemoryHigh '*) echo "${HIGH:-9663676416}" ;;
  *' -p MemoryMax '*) echo 10737418240 ;;
  *' -p MemorySwapMax '*) echo 2147483648 ;;
  *' -p TasksMax '*) echo 4096 ;;
  *' -p CPUQuotaPerSecUSec '*) echo 16s ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$WORK/bin/systemctl"
printf '1073741824\n' > "$WORK/sys/fs/cgroup/lima-vm@colima.service/memory.current"
run() { CONTAINMENT_LIVE_SYSTEMD=1 "$REPO/scripts/host/qemu-ceiling-guard.sh" --root "$WORK" --apply; }
run || fail 'safe apply failed'
grep -q set-property "$LOG" || fail 'safe apply did not write'
: > "$LOG"
printf '9663676416\n' > "$WORK/sys/fs/cgroup/lima-vm@colima.service/memory.current"
if run; then fail 'high current accepted'; fi
if grep -q set-property "$LOG"; then fail 'high current wrote limits'; fi
mv "$WORK/sys/fs/cgroup/lima-vm@colima.service/memory.current" "$WORK/current.saved"
if run; then fail 'missing current accepted'; fi
mv "$WORK/current.saved" "$WORK/sys/fs/cgroup/lima-vm@colima.service/memory.current"
printf 'invalid\n'  > "$WORK/sys/fs/cgroup/lima-vm@colima.service/memory.current"
if run; then fail 'unreadable current accepted'; fi
printf '1073741824\n' > "$WORK/sys/fs/cgroup/lima-vm@colima.service/memory.current"
if SET_FAIL=1 run; then fail 'set-property failure accepted'; fi
if HIGH=1 run; then fail 'readback mismatch accepted'; fi
if QUERY_FAIL=1 run; then fail 'manager query failure accepted'; fi
: > "$LOG"
STATE=inactive run || fail 'confirmed inactive rejected'
if grep -q set-property "$LOG"; then fail 'inactive service wrote limits'; fi
: > "$LOG"
mkdir -p "$WORK/empty"
PATH="$WORK/bin:$PATH" "$REPO/scripts/host/qemu-ceiling-guard.sh" --root "$WORK/empty"
[ ! -s "$LOG" ] || fail 'empty fixture touched systemd'
if CONTAINMENT_LIVE_SYSTEMD=1 "$REPO/scripts/host/qemu-ceiling-guard.sh" --root "$WORK/empty"; then fail 'missing fixture manager accepted'; fi
echo 'QEMU_CEILING_GUARD_TEST: PASS'
