#!/usr/bin/env bash
# Repo-side contract: QEMU drop-in/slice must declare a finite CPUQuota.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
out="$(bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh")"
echo "$out" | grep -q 'PASS: tracked QEMU ceilings present' \
  || { echo "FAIL: expected tracked PASS, got: $out" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/systemd/lima-vm@colima.service.d"
cp "${REPO_ROOT}/systemd/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  "$tmp/systemd/lima-vm@colima.service.d/"
cp "${REPO_ROOT}/systemd/app-lima-vm.slice" "$tmp/systemd/"
cp "${REPO_ROOT}/systemd/lima-vm-cpu-ceiling.service" "$tmp/systemd/"
mkdir -p "$tmp"
# install.sh grep is required; copy a stub without CPUQuota to force FAIL.
printf '#!/bin/sh\n# no CPUQuota here\n' > "$tmp/install.sh"
neg_rc=0
neg_out="$(REPO_ROOT="$tmp" bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" || neg_rc=$?
[ "$neg_rc" -ne 0 ] || { echo "FAIL: stub install.sh without CPUQuota should fail" >&2; exit 1; }
echo "$neg_out" | grep -q 'install.sh does not apply' \
  || { echo "FAIL: expected install.sh FAIL line, got: $neg_out" >&2; exit 1; }

# Fully injected cgroup-v2 fixture.  The assertion must follow the exact
# cgroup path reported by /proc/<pid>/cgroup rather than selecting a bounded
# sibling by name.
PROC="$tmp/proc"; CG="$tmp/cgroup"
mkdir -p "$PROC/4242" "$CG/user.slice/app.slice/lima-vm@colima.service" \
  "$CG/user.slice/app.slice/unrelated.scope"
printf 'qemu-system-x86_64\n' > "$PROC/4242/comm"
printf '0::/user.slice/app.slice/lima-vm@colima.service\n' > "$PROC/4242/cgroup"
printf '4242\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/cgroup.procs"
printf '9999\n' > "$CG/user.slice/app.slice/unrelated.scope/cgroup.procs"
printf '1600000 100000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/cpu.max"
printf '30000000000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.high"
printf '38000000000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.max"
printf '2000000000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.swap.max"
printf '4096\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/pids.max"
for f in cpu.max memory.high memory.max memory.swap.max pids.max; do
  case "$f" in
    cpu.max) v='100000 100000' ;;
    memory.high) v='1000000000' ;;
    memory.max) v='1000000000' ;;
    memory.swap.max) v='1000000000' ;;
    pids.max) v='100' ;;
  esac
  printf '%s\n' "$v" > "$CG/user.slice/app.slice/unrelated.scope/$f"
done
live_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=4242 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" \
  || { echo "FAIL: bounded exact fixture rejected: $live_out" >&2; exit 1; }
echo "$live_out" | grep -q 'pid=4242.*lima-vm@colima.service' \
  || { echo "FAIL: live fixture did not report exact QEMU cgroup: $live_out" >&2; exit 1; }

# A bounded sibling must not satisfy the check when the PID's own cgroup is
# absent.  This catches regressions to basename/sibling discovery.
rm -rf "$CG/user.slice/app.slice/lima-vm@colima.service"
sibling_rc=0
sibling_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=4242 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" || sibling_rc=$?
[ "$sibling_rc" -ne 0 ] || { echo "FAIL: bounded sibling incorrectly passed" >&2; exit 1; }
echo "$sibling_out" | grep -q 'cgroup path does not exist' \
  || { echo "FAIL: missing exact cgroup was not rejected: $sibling_out" >&2; exit 1; }

# Negative bound: the exact cgroup exists but memory.max exceeds 38 GiB.
mkdir -p "$CG/user.slice/app.slice/lima-vm@colima.service"
printf '4242\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/cgroup.procs"
printf '1600000 100000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/cpu.max"
printf '30000000000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.high"
printf '42000000000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.max"
printf '2000000000\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.swap.max"
printf '4096\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/pids.max"
bound_rc=0
bound_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=4242 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" || bound_rc=$?
[ "$bound_rc" -ne 0 ] || { echo "FAIL: memory.max above 38 GiB incorrectly passed" >&2; exit 1; }
echo "$bound_out" | grep -q 'memory.max=.*exceeds' \
  || { echo "FAIL: negative memory.max bound was not reported: $bound_out" >&2; exit 1; }

echo "ASSERT_QEMU_CPU_CEILING_TEST: PASS"
