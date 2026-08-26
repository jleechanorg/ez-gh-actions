#!/usr/bin/env bash
# Verify the finite resource fence applied to the Colima QEMU service.
#
# ASSERT_LIVE_QEMU=1 enables a read-only cgroup-v2 probe.  The probe resolves
# one exact QEMU PID from QEMU_PROC_ROOT (default: /proc), reads that PID's
# 0:: cgroup entry, and inspects only the resulting QEMU_CGROUP_ROOT path
# (default: /sys/fs/cgroup).  It never scans for, or falls back to, a sibling
# slice: a bounded unrelated cgroup must not make this check pass.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DROPIN="${REPO_ROOT}/systemd/lima-vm@colima.service.d/99-memory-ceiling.conf"
SLICE="${REPO_ROOT}/systemd/app-lima-vm.slice"
RUNTIME_UNIT="${REPO_ROOT}/systemd/lima-vm-cpu-ceiling.service"
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_file() { [ -f "$1" ] || fail "missing $1"; }
assert_line() {
  local file="$1" line="$2"
  grep -Fqx "$line" "$file" || fail "$file missing exact line: $line"
}

assert_file "$DROPIN"
assert_file "$SLICE"
assert_file "$RUNTIME_UNIT"
for file in "$DROPIN" "$SLICE"; do
  assert_line "$file" "MemoryHigh=34G"
  assert_line "$file" "MemoryMax=38G"
  assert_line "$file" "MemorySwapMax=2G"
  assert_line "$file" "TasksMax=4096"
  assert_line "$file" "CPUQuota=1600%"
done
assert_line "$DROPIN" "CPUAccounting=yes"
# install.sh must apply the same finite values to a transient service after a
# Colima restart; these are static text checks and do not execute install.sh.
for setting in MemoryHigh=34G MemoryMax=38G MemorySwapMax=2G TasksMax=4096 CPUQuota=1600%; do
  grep -Fq "$setting" "${REPO_ROOT}/install.sh" \
    || fail "install.sh does not apply $setting"
done
for setting in MemoryHigh=34G MemoryMax=38G MemorySwapMax=2G TasksMax=4096 CPUQuota=1600%; do
  grep -Fq "$setting" "$RUNTIME_UNIT" \
    || fail "$RUNTIME_UNIT missing $setting"
done

if [ "${ASSERT_LIVE_QEMU:-0}" != "1" ]; then
  echo "PASS: tracked QEMU ceilings present (live cgroup not checked)"
  exit 0
fi

QEMU_PROC_ROOT="${QEMU_PROC_ROOT:-/proc}"
QEMU_CGROUP_ROOT="${QEMU_CGROUP_ROOT:-/sys/fs/cgroup}"
QEMU_PID="${QEMU_PID:-}"
export QEMU_PROC_ROOT QEMU_CGROUP_ROOT QEMU_PID

python3 - <<'PY' || fail "live QEMU cgroup ceilings are missing, unbounded, or exceed limits"
import os
import re
import sys

proc_root = os.environ["QEMU_PROC_ROOT"].rstrip("/") or "/"
cgroup_root = os.environ["QEMU_CGROUP_ROOT"].rstrip("/") or "/"
requested_pid = os.environ.get("QEMU_PID", "").strip()

def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()

def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)

def candidate_pids():
    if requested_pid:
        if not requested_pid.isdigit() or int(requested_pid) <= 0:
            fail(f"invalid QEMU_PID={requested_pid!r}")
        try:
            comm = read(os.path.join(proc_root, requested_pid, "comm"))
        except OSError as exc:
            fail(f"cannot read {proc_root}/{requested_pid}/comm: {exc}")
        if not comm.startswith("qemu-system-x86"):
            fail(f"QEMU_PID={requested_pid} is not qemu-system-x86 (comm={comm!r})")
        return [requested_pid]
    try:
        pids = sorted((name for name in os.listdir(proc_root) if name.isdigit()), key=int)
    except OSError as exc:
        fail(f"cannot list {proc_root}: {exc}")
    matches = []
    for pid in pids:
        try:
            comm = read(os.path.join(proc_root, pid, "comm"))
        except OSError:
            continue
        if comm.startswith("qemu-system-x86"):
            matches.append(pid)
    return matches

def cgroup_for(pid):
    try:
        lines = read(os.path.join(proc_root, pid, "cgroup")).splitlines()
    except OSError as exc:
        fail(f"cannot read {proc_root}/{pid}/cgroup: {exc}")
    rel = None
    for line in lines:
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0":
            rel = fields[2]
            break
    if not rel or not rel.startswith("/") or "\x00" in rel:
        fail(f"QEMU pid {pid} has no cgroup-v2 0:: path")
    # /proc cgroup paths are absolute within cgroupfs.  Reject traversal and
    # inspect exactly this path; no basename/sibling discovery is permitted.
    parts = rel.split("/")[1:]
    if any(part in ("", ".", "..") for part in parts):
        fail(f"unsafe cgroup path {rel!r}")
    path = os.path.join(cgroup_root, *parts)
    if not os.path.isdir(path):
        fail(f"QEMU pid {pid} cgroup path does not exist: {path}")
    try:
        procs = read(os.path.join(path, "cgroup.procs")).split()
    except OSError as exc:
        fail(f"cannot verify QEMU pid {pid} membership at {path}: {exc}")
    if pid not in procs:
        fail(f"QEMU pid {pid} is not a member of its resolved cgroup {path}")
    return path

pids = candidate_pids()
if not pids:
    fail("no qemu-system-x86 process")
if requested_pid and not os.path.exists(os.path.join(proc_root, requested_pid, "comm")):
    fail(f"QEMU_PID={requested_pid} does not exist under {proc_root}")

pid = pids[0]
cg = cgroup_for(pid)

def finite_int(name, maximum):
    try:
        value = read(os.path.join(cg, name))
    except OSError as exc:
        fail(f"missing {cg}/{name}: {exc}")
    if value in ("", "max") or not re.fullmatch(r"[0-9]+", value):
        fail(f"{cg}/{name} is unbounded or invalid: {value!r}")
    number = int(value)
    if number > maximum:
        fail(f"{cg}/{name}={number} exceeds {maximum}")
    return number

try:
    cpu = read(os.path.join(cg, "cpu.max")).split()
except OSError as exc:
    fail(f"missing {cg}/cpu.max: {exc}")
if len(cpu) != 2 or cpu[0] == "max" or not all(re.fullmatch(r"[0-9]+", item) for item in cpu):
    fail(f"{cg}/cpu.max is unbounded or invalid: {' '.join(cpu)!r}")
quota, period = map(int, cpu)
if period <= 0 or quota <= 0 or quota > 16 * period:
    fail(f"{cg}/cpu.max={' '.join(cpu)} exceeds CPUQuota=1600%")

high = finite_int("memory.high", 34 * 1024**3)
maximum = finite_int("memory.max", 38 * 1024**3)
swap = finite_int("memory.swap.max", 2 * 1024**3)
pids_max = finite_int("pids.max", 4096)
if high > maximum:
    fail(f"{cg}/memory.high={high} exceeds memory.max={maximum}")
print(
    f"PASS: live QEMU pid={pid} cgroup={cg} "
    f"cpu.max={quota} {period} memory.high={high} memory.max={maximum} "
    f"memory.swap.max={swap} pids.max={pids_max}"
)
PY
