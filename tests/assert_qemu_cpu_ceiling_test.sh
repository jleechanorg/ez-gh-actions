#!/usr/bin/env bash
# Repo-side contract: QEMU drop-in/slice must declare a finite CPUQuota.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# Live bounds are mode-dependent (bead ez-gh-actions-154k): VM-backed keeps
# 34G/38G, host-docker caps the qemu-only Colima VM at 9G/10G.  Pin the mode
# so fixtures never depend on this host's docker daemon.
export QEMU_CEILING_MODE=vm-backed
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
[ -d "${REPO_ROOT}/systemd/host-docker" ] \
  || { echo "FAIL: missing tracked host-docker QEMU ceiling variants (systemd/host-docker)" >&2; exit 1; }
cp -R "${REPO_ROOT}/systemd/host-docker" "$tmp/systemd/"
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
cat > "$tmp/systemctl" <<EOF
#!/usr/bin/env bash
printf "%s\\n" "/user.slice/app.slice/lima-vm@colima.service"
EOF
chmod +x "$tmp/systemctl"
export PATH="$tmp:$PATH"
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

# A valid descendant of the systemd-reported service cgroup is admitted when
# its own cgroup.procs contains the explicit QEMU PID.
mkdir -p "$CG/user.slice/app.slice/lima-vm@colima.service/qemu.scope"
for f in cpu.max memory.high memory.max memory.swap.max pids.max; do
  cp "$CG/user.slice/app.slice/lima-vm@colima.service/$f" \
    "$CG/user.slice/app.slice/lima-vm@colima.service/qemu.scope/$f"
done
printf "%s\n" "4242" > "$CG/user.slice/app.slice/lima-vm@colima.service/qemu.scope/cgroup.procs"
printf "%s\n" "0::/user.slice/app.slice/lima-vm@colima.service/qemu.scope" > "$PROC/4242/cgroup"
desc_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=4242 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" \
  || { echo "FAIL: valid service descendant rejected: $desc_out" >&2; exit 1; }
echo "$desc_out" | grep -q "qemu.scope" \
  || { echo "FAIL: descendant cgroup was not reported: $desc_out" >&2; exit 1; }
printf "%s\n" "0::/user.slice/app.slice/lima-vm@colima.service" > "$PROC/4242/cgroup"

# Empty actual ControlGroup output is fail-closed even when a basename matches.
cat > "$tmp/systemctl" <<EOF
#!/usr/bin/env bash
printf "%s\\n" ""
EOF
empty_rc=0
empty_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=4242 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" || empty_rc=$?
[ "$empty_rc" -ne 0 ] || { echo "FAIL: empty actual ControlGroup passed: $empty_out" >&2; exit 1; }
echo "$empty_out" | grep -q "ControlGroup" \
  || { echo "FAIL: empty ControlGroup diagnostic missing: $empty_out" >&2; exit 1; }
cat > "$tmp/systemctl" <<EOF
#!/usr/bin/env bash
printf "%s\\n" "/user.slice/app.slice/lima-vm@colima.service"
EOF

# Exactly two QEMUs beneath the actual unit must fail closed.
mkdir -p "$PROC/6262" "$CG/user.slice/app.slice/lima-vm@colima.service/second.scope"
printf "%s\n" "qemu-system-x86_64" > "$PROC/6262/comm"
printf "%s\n" "0::/user.slice/app.slice/lima-vm@colima.service/second.scope" > "$PROC/6262/cgroup"
for f in cpu.max memory.high memory.max memory.swap.max pids.max; do
  cp "$CG/user.slice/app.slice/lima-vm@colima.service/$f" \
    "$CG/user.slice/app.slice/lima-vm@colima.service/second.scope/$f"
done
printf "%s\n" "6262" > "$CG/user.slice/app.slice/lima-vm@colima.service/second.scope/cgroup.procs"
two_rc=0
two_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" || two_rc=$?
[ "$two_rc" -ne 0 ] || { echo "FAIL: multiple service QEMUs passed: $two_out" >&2; exit 1; }
echo "$two_out" | grep -q "expected exactly one" \
  || { echo "FAIL: multiple-QEMU diagnostic missing: $two_out" >&2; exit 1; }
rm -rf "$PROC/6262" "$CG/user.slice/app.slice/lima-vm@colima.service/second.scope"

# A same-basename cgroup outside the actual systemd ControlGroup is not
# accepted merely because its leaf name matches.
mkdir -p "$PROC/3131" "$CG/user.slice/app.slice/unrelated/lima-vm@colima.service"
printf "%s\n" "qemu-system-x86_64" > "$PROC/3131/comm"
printf "%s\n" "0::/user.slice/app.slice/unrelated/lima-vm@colima.service" > "$PROC/3131/cgroup"
printf "%s\n" "3131" > "$CG/user.slice/app.slice/unrelated/lima-vm@colima.service/cgroup.procs"
for f in cpu.max memory.high memory.max memory.swap.max pids.max; do
  cp "$CG/user.slice/app.slice/lima-vm@colima.service/$f" \
    "$CG/user.slice/app.slice/unrelated/lima-vm@colima.service/$f"
done
same_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" \
  || { echo "FAIL: valid service plus same-basename fixture rejected: $same_out" >&2; exit 1; }
echo "$same_out" | grep -q "pid=4242" \
  || { echo "FAIL: same-basename fixture selected unrelated QEMU: $same_out" >&2; exit 1; }
rm -rf "$PROC/3131" "$CG/user.slice/app.slice/unrelated"

# An explicit PID still requires a QEMU process identity.  A non-QEMU process
# in the correctly bounded service cgroup must fail closed rather than pass
# solely because its cgroup has the expected limits.
mkdir -p "$PROC/5252"
printf 'systemd\n' > "$PROC/5252/comm"
printf '0::/user.slice/app.slice/lima-vm@colima.service\n' > "$PROC/5252/cgroup"
printf '4242\n5252\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/cgroup.procs"
nonqemu_rc=0
nonqemu_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=5252 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" \
  || nonqemu_rc=$?
[ "$nonqemu_rc" -ne 0 ] || {
  echo "FAIL: explicit non-QEMU PID incorrectly passed: $nonqemu_out" >&2
  exit 1
}
echo "$nonqemu_out" | grep -q 'QEMU_PID=5252 is not qemu-system-x86' \
  || { echo "FAIL: non-QEMU PID rejection was not reported: $nonqemu_out" >&2; exit 1; }

# Multi-QEMU fixture: an unrelated, bounded QEMU has the lower PID and must
# not satisfy the check when QEMU_PID is omitted.  Resolution must select the
# sole QEMU in lima-vm@colima.service, not the first bounded process.
mkdir -p "$PROC/1111"
printf 'qemu-system-x86_64\n' > "$PROC/1111/comm"
printf '0::/user.slice/app.slice/unrelated.scope\n' > "$PROC/1111/cgroup"
printf '1111\n' > "$CG/user.slice/app.slice/unrelated.scope/cgroup.procs"
auto_out="$(ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" \
  || { echo "FAIL: service-bound multi-QEMU fixture rejected: $auto_out" >&2; exit 1; }
echo "$auto_out" | grep -q 'pid=4242.*lima-vm@colima.service' \
  || { echo "FAIL: auto-resolution selected an unrelated QEMU: $auto_out" >&2; exit 1; }

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

# Host-docker mode: the same 38 GiB-class VM-backed values exceed the
# 9G/10G host-docker bound, and the exact host-docker values pass.
printf '36507222016\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.high"
printf '40802189312\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.max"
hd_rc=0
hd_out="$(QEMU_CEILING_MODE=host-docker ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=4242 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" || hd_rc=$?
[ "$hd_rc" -ne 0 ] || { echo "FAIL: VM-backed 34G/38G passed the host-docker bound" >&2; exit 1; }
echo "$hd_out" | grep -q 'memory.high=36507222016 exceeds 9663676416' \
  || { echo "FAIL: host-docker bound not reported: $hd_out" >&2; exit 1; }
printf '9663676416\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.high"
printf '10737418240\n' > "$CG/user.slice/app.slice/lima-vm@colima.service/memory.max"
hd_out="$(QEMU_CEILING_MODE=host-docker ASSERT_LIVE_QEMU=1 QEMU_PROC_ROOT="$PROC" QEMU_CGROUP_ROOT="$CG" \
  QEMU_PID=4242 bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" 2>&1)" \
  || { echo "FAIL: exact host-docker 9G/10G rejected: $hd_out" >&2; exit 1; }
bad_rc=0
QEMU_CEILING_MODE=bogus bash "${REPO_ROOT}/scripts/host/assert-qemu-cpu-ceiling.sh" >/dev/null 2>&1 || bad_rc=$?
[ "$bad_rc" -ne 0 ] || { echo "FAIL: unknown QEMU_CEILING_MODE accepted" >&2; exit 1; }

echo "ASSERT_QEMU_CPU_CEILING_TEST: PASS"
