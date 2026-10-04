#!/usr/bin/env bash
# Verify the finite resource fence applied to the Colima QEMU service.
#
# ASSERT_LIVE_QEMU=1 enables a read-only cgroup-v2 probe.  The probe resolves
# one exact QEMU PID from QEMU_PROC_ROOT (default: /proc), requiring the
# lima-vm@colima.service cgroup when QEMU_PID is omitted, reads that PID's
# 0:: cgroup entry, and inspects only the resulting QEMU_CGROUP_ROOT path
# (default: /sys/fs/cgroup).  It never scans for, or falls back to, a sibling
# slice: a bounded unrelated QEMU/cgroup must not make this check pass.
#
# The ceiling is deployment-mode dependent:
# vm-backed (runners inside Colima) 34G/38G from systemd/, host-docker (Colima
# runs an 8 GiB guest) 9G/10G from systemd/host-docker/.
# Both tracked variants are always checked; QEMU_CEILING_MODE selects the live
# bound (default: host-docker when the Docker daemon shares this kernel).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
fail() { echo "FAIL: $*" >&2; exit 1; }

if [ -z "${QEMU_CEILING_MODE:-}" ]; then
  QEMU_CEILING_MODE="$("${REPO_ROOT}/scripts/host/docker-host-mode.sh")"
fi
case "$QEMU_CEILING_MODE" in
  vm-backed) QEMU_MAX_HIGH=$((34 * 1024 * 1024 * 1024)); QEMU_MAX_MAX=$((38 * 1024 * 1024 * 1024)) ;;
  host-docker) QEMU_MAX_HIGH=$((9 * 1024 * 1024 * 1024)); QEMU_MAX_MAX=$((10 * 1024 * 1024 * 1024)) ;;
  *) fail "unknown QEMU_CEILING_MODE=${QEMU_CEILING_MODE} (expected vm-backed or host-docker)" ;;
esac

assert_file() { [ -f "$1" ] || fail "missing $1"; }
assert_line() {
  local file="$1" line="$2"
  grep -Fqx "$line" "$file" || fail "$file missing exact line: $line"
}

for mode in vm-backed host-docker; do
  case "$mode" in
    vm-backed) dir="${REPO_ROOT}/systemd"; high=MemoryHigh=34G; max=MemoryMax=38G ;;
    host-docker) dir="${REPO_ROOT}/systemd/host-docker"; high=MemoryHigh=9G; max=MemoryMax=10G ;;
  esac
  DROPIN="${dir}/lima-vm@colima.service.d/99-memory-ceiling.conf"
  SLICE="${dir}/app-lima-vm.slice"
  RUNTIME_UNIT="${dir}/lima-vm-cpu-ceiling.service"
  assert_file "$DROPIN"
  assert_file "$SLICE"
  assert_file "$RUNTIME_UNIT"
  for file in "$DROPIN" "$SLICE"; do
    assert_line "$file" "$high"
    assert_line "$file" "$max"
    assert_line "$file" "MemorySwapMax=2G"
    assert_line "$file" "TasksMax=4096"
    assert_line "$file" "CPUQuota=1600%"
  done
  assert_line "$DROPIN" "CPUAccounting=yes"
  # install.sh must apply the same finite values to a transient service after a
  # Colima restart; these are static text checks and do not execute install.sh.
  for setting in "$high" "$max" MemorySwapMax=2G TasksMax=4096 CPUQuota=1600%; do
    grep -Fq "$setting" "${REPO_ROOT}/install.sh" \
      || fail "install.sh does not apply $mode $setting"
    grep -Fq "$setting" "$RUNTIME_UNIT" \
      || fail "$RUNTIME_UNIT missing $setting"
  done
done

if [ "${ASSERT_LIVE_QEMU:-0}" != "1" ]; then
  echo "PASS: tracked QEMU ceilings present (live cgroup not checked)"
  exit 0
fi

QEMU_PROC_ROOT="${QEMU_PROC_ROOT:-/proc}"
QEMU_CGROUP_ROOT="${QEMU_CGROUP_ROOT:-/sys/fs/cgroup}"
QEMU_PID="${QEMU_PID:-}"
export QEMU_PROC_ROOT QEMU_CGROUP_ROOT QEMU_PID QEMU_MAX_HIGH QEMU_MAX_MAX

python3 - <<'PY' || fail "live QEMU cgroup ceilings are missing, unbounded, or exceed limits"
import os
import re
import subprocess
import sys

proc_root = os.environ["QEMU_PROC_ROOT"].rstrip("/") or "/"
cgroup_root = os.environ["QEMU_CGROUP_ROOT"].rstrip("/") or "/"
requested_pid = os.environ.get("QEMU_PID", "").strip()
service_unit = "lima-vm@colima.service"


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def safe_cgroup_path(value, label):
    if not value or not value.startswith("/") or "\x00" in value:
        fail(f"{label} has no safe cgroup-v2 path: {value!r}")
    parts = value.split("/")[1:]
    if any(part in ("", ".", "..") for part in parts):
        fail(f"{label} has unsafe cgroup path: {value!r}")
    return value


def actual_service_cgroup():
    try:
        result = subprocess.run(
            ["systemctl", "--user", "show", "-p", "ControlGroup", "--value", "--", service_unit],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        fail(f"cannot resolve {service_unit} ControlGroup: {exc}")
    return safe_cgroup_path(result.stdout.strip(), f"{service_unit} ControlGroup")


def qemu_comm(pid, *, required):
    try:
        comm = read(os.path.join(proc_root, pid, "comm"))
    except OSError as exc:
        if required:
            fail(f"cannot read {proc_root}/{pid}/comm: {exc}")
        return None
    return comm if comm.startswith("qemu-system-x86") else None


def cgroup_rel(pid, *, required):
    try:
        lines = read(os.path.join(proc_root, pid, "cgroup")).splitlines()
    except OSError as exc:
        if required:
            fail(f"cannot read {proc_root}/{pid}/cgroup: {exc}")
        return None
    rel = None
    for line in lines:
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0":
            rel = fields[2]
            break
    if rel is None:
        if required:
            fail(f"QEMU pid {pid} has no cgroup-v2 0:: path")
        return None
    if not rel.startswith("/") or "\x00" in rel:
        if required:
            fail(f"QEMU pid {pid} has unsafe cgroup path: {rel!r}")
        return None
    parts = rel.split("/")[1:]
    if any(part in ("", ".", "..") for part in parts):
        if required:
            fail(f"QEMU pid {pid} has unsafe cgroup path: {rel!r}")
        return None
    return rel


def under_service(rel, service_cgroup):
    return rel == service_cgroup or rel.startswith(service_cgroup.rstrip("/") + "/")


def cgroup_for(pid, service_cgroup, *, required):
    rel = cgroup_rel(pid, required=required)
    if rel is None:
        return None
    if not under_service(rel, service_cgroup):
        if required:
            fail(
                f"QEMU pid {pid} cgroup is outside {service_unit} ControlGroup "
                f"{service_cgroup}: {rel!r}"
            )
        return None
    path = os.path.join(cgroup_root, *rel.split("/")[1:])
    if not os.path.isdir(path):
        if required:
            fail(f"QEMU pid {pid} cgroup path does not exist: {path}")
        return None
    try:
        procs = read(os.path.join(path, "cgroup.procs")).split()
    except OSError as exc:
        if required:
            fail(f"cannot verify QEMU pid {pid} membership at {path}: {exc}")
        return None
    if pid not in procs:
        if required:
            fail(f"QEMU pid {pid} is not a member of its resolved cgroup {path}")
        return None
    return path


def candidate_pids(service_cgroup):
    if requested_pid:
        if not requested_pid.isdigit() or int(requested_pid) <= 0:
            fail(f"invalid QEMU_PID={requested_pid!r}")
        comm = qemu_comm(requested_pid, required=True)
        if comm is None:
            try:
                actual_comm = read(os.path.join(proc_root, requested_pid, "comm"))
            except OSError as exc:
                fail(f"cannot read {proc_root}/{requested_pid}/comm: {exc}")
            fail(
                f"QEMU_PID={requested_pid} is not qemu-system-x86 "
                f"(comm={actual_comm!r})"
            )
        cgroup_for(requested_pid, service_cgroup, required=True)
        return [requested_pid]
    try:
        pids = sorted((name for name in os.listdir(proc_root) if name.isdigit()), key=int)
    except OSError as exc:
        fail(f"cannot list {proc_root}: {exc}")
    matches = []
    for pid in pids:
        if qemu_comm(pid, required=False) is None:
            continue
        if cgroup_for(pid, service_cgroup, required=False) is not None:
            matches.append(pid)
    if len(matches) != 1:
        if not matches:
            fail(f"no qemu-system-x86 process belongs to {service_unit} ControlGroup {service_cgroup}")
        fail(
            f"expected exactly one qemu-system-x86 process under {service_unit} "
            f"ControlGroup {service_cgroup}, found {len(matches)} ({', '.join(matches)})"
        )
    return matches

service_cgroup = actual_service_cgroup()
pids = candidate_pids(service_cgroup)
pid = pids[0]
cg = cgroup_for(pid, service_cgroup, required=True)


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

high = finite_int("memory.high", int(os.environ["QEMU_MAX_HIGH"]))
maximum = finite_int("memory.max", int(os.environ["QEMU_MAX_MAX"]))
swap = finite_int("memory.swap.max", 2 * 1024**3)
pids_max = finite_int("pids.max", 4096)
if high > maximum:
    fail(f"{cg}/memory.high={high} exceeds memory.max={maximum}")
print(
    f"PASS: live QEMU pid={pid} cgroup={cg} "
    f"cpu.max={quota} {period} memory.high={high} memory.max={maximum} "
    f"memory.swap.max={swap} pids.max={pids_max} "
    f"service_cgroup={service_cgroup}"
)
PY
