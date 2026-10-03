#!/usr/bin/env bash
# Focused Gate-8 regression coverage. The verifier's test mode exercises the
# same config/cgroup helpers without running the live fleet gates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/docs/verify-exit-criteria.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/valid.toml" <<'EOF'
[limits]
cgroup_parent = "actions.slice"
EOF
VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
VERIFY_EXIT_CRITERIA_TEST_CASE=config \
VERIFY_EXIT_CRITERIA_CONFIG="$TMP/valid.toml" \
  bash "$VERIFY" >/dev/null || fail "actions.slice config should pass"

cat > "$TMP/missing.toml" <<'EOF'
[limits]
cgroup_parent = ""
EOF
if VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
   VERIFY_EXIT_CRITERIA_TEST_CASE=config \
   VERIFY_EXIT_CRITERIA_CONFIG="$TMP/missing.toml" \
   bash "$VERIFY" >/dev/null 2>&1; then
  fail "missing cgroup_parent should fail"
fi
VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
VERIFY_EXIT_CRITERIA_TEST_CASE=platform_config \
VERIFY_EXIT_CRITERIA_PLATFORM=Darwin \
VERIFY_EXIT_CRITERIA_CONFIG="$TMP/missing.toml" \
  bash "$VERIFY" >/dev/null || fail "macOS config must not require Linux actions.slice"
if VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
   VERIFY_EXIT_CRITERIA_TEST_CASE=platform_config \
   VERIFY_EXIT_CRITERIA_PLATFORM=Linux \
   VERIFY_EXIT_CRITERIA_CONFIG="$TMP/missing.toml" \
   bash "$VERIFY" >/dev/null 2>&1; then
  fail "Linux config without actions.slice should fail"
fi

# Fake a live managed container whose PID is in actions.slice.
mkdir -p "$TMP/proc/4242" "$TMP/cgroup/actions.slice/runner.scope"
printf '0::/actions.slice/runner.scope\n' > "$TMP/proc/4242/cgroup"
cat > "$TMP/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps) printf 'runner-1\n' ;;
  inspect) printf '4242\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/docker"
PATH="$TMP:$PATH" \
VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
VERIFY_EXIT_CRITERIA_TEST_CASE=containers \
VERIFY_EXIT_CRITERIA_PROC_ROOT="$TMP/proc" \
VERIFY_EXIT_CRITERIA_CGROUP_ROOT="$TMP/cgroup" \
  bash "$VERIFY" >/dev/null || fail "runner in actions.slice should pass"

# A managed runner outside actions.slice must fail even when the slice exists.
printf '0::/user.slice/runner.scope\n' > "$TMP/proc/4242/cgroup"
if PATH="$TMP:$PATH" \
   VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
   VERIFY_EXIT_CRITERIA_TEST_CASE=containers \
   VERIFY_EXIT_CRITERIA_PROC_ROOT="$TMP/proc" \
   VERIFY_EXIT_CRITERIA_CGROUP_ROOT="$TMP/cgroup" \
   bash "$VERIFY" >/dev/null 2>&1; then
  fail "runner outside actions.slice should fail"
fi

# A finite parent slice is the effective recursive ceiling even when a child
# scope retains its default memory.high=max.
mkdir -p "$TMP/effective-cgroup/agents.slice/agent.scope"
printf '10737418240\n' > "$TMP/effective-cgroup/agents.slice/memory.high"
printf '12884901888\n' > "$TMP/effective-cgroup/agents.slice/memory.max"
printf 'max\n' > "$TMP/effective-cgroup/agents.slice/agent.scope/memory.high"
printf 'max\n' > "$TMP/effective-cgroup/agents.slice/agent.scope/memory.max"
VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
VERIFY_EXIT_CRITERIA_TEST_CASE=cgroup_ceiling \
VERIFY_EXIT_CRITERIA_CGROUP_ROOT="$TMP/effective-cgroup" \
VERIFY_EXIT_CRITERIA_CGROUP_PATH=/agents.slice/agent.scope \
  bash "$VERIFY" >/dev/null || fail "finite ancestor ceiling should bound child scope"
printf 'max\n' > "$TMP/effective-cgroup/agents.slice/memory.high"
printf 'max\n' > "$TMP/effective-cgroup/agents.slice/memory.max"
if VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
   VERIFY_EXIT_CRITERIA_TEST_CASE=cgroup_ceiling \
   VERIFY_EXIT_CRITERIA_CGROUP_ROOT="$TMP/effective-cgroup" \
   VERIFY_EXIT_CRITERIA_CGROUP_PATH=/agents.slice/agent.scope \
   bash "$VERIFY" >/dev/null 2>&1; then
  fail "fully unbounded cgroup ancestry should fail"
fi

# Modern unit files must not bypass the live QEMU/AO/MCP probes.
modern_line=$(grep -n 'modern finite host envelope detected' "$VERIFY" | cut -d: -f1)
live_line=$(grep -n 'QEMU cgroup probe' "$VERIFY" | head -1 | cut -d: -f1)
[ -n "$modern_line" ] && [ -n "$live_line" ] && [ "$modern_line" -lt "$live_line" ] \
  || fail "live Gate-8 probe section is not retained after modern checks"
! sed -n "$modern_line,${live_line}p" "$VERIFY" | grep -q '^else$' \
  || fail "modern files still bypass live Gate-8 probes"
qemu_max_line=$(grep -n 'QEMU_CEILING_BYTES.*=' "$VERIFY" | head -1 | cut -d: -f1)
[ -n "$qemu_max_line" ] && [ "$live_line" -lt "$qemu_max_line" ] \
  || fail "live QEMU ceiling probe is missing after modern checks"
grep -Fq 'if [ "$QEMU_CEILING_BYTES" = "max" ]' "$VERIFY" \
  || fail "live max QEMU ceiling is not fail-closed"

# Host-docker envelope (bead ez-gh-actions-154k): live memory.max of
# actions/agents/automation/lima-vm@colima.service must equal the tracked
# host-docker policy, be finite, and with the 10% reserve fit MemTotal.
# Fixture host = jeff-ubuntu's MemTotal (63336 MB, reserve 6333 MB).
ENV_DIR="$TMP/envelope"
mkdir -p "$ENV_DIR/bin" "$ENV_DIR/cg/actions.slice" "$ENV_DIR/cg/user/agents.slice" \
  "$ENV_DIR/cg/user/automation.slice" "$ENV_DIR/cg/user/lima-vm@colima.service"
printf 'MemTotal:       64856928 kB\n' > "$ENV_DIR/meminfo"
cat > "$ENV_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# `systemctl --user show -p ControlGroup --value -- <unit>` -> /user/<unit>
for unit in "$@"; do :; done
printf '/user/%s\n' "$unit"
EOF
chmod +x "$ENV_DIR/bin/systemctl"
set_live() { # unit-dir high max
  printf '%s\n' "$2" > "$ENV_DIR/cg/$1/memory.high"
  printf '%s\n' "$3" > "$ENV_DIR/cg/$1/memory.max"
}
G=1073741824
set_live_policy() { # agents_high agents_max automation_high automation_max (GiB)
  set_live actions.slice $((26 * G)) $((28 * G))
  set_live user/agents.slice $(($1 * G)) $(($2 * G))
  set_live user/automation.slice $(($3 * G)) $(($4 * G))
  set_live user/lima-vm@colima.service $((4608 * 1048576)) $((5 * G))
}
run_envelope() { # policy-root
  PATH="$ENV_DIR/bin:$PATH" \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
  VERIFY_EXIT_CRITERIA_TEST_CASE=host_docker_envelope \
  VERIFY_EXIT_CRITERIA_POLICY_ROOT="$1" \
  VERIFY_EXIT_CRITERIA_CGROUP_ROOT="$ENV_DIR/cg" \
  VERIFY_EXIT_CRITERIA_MEMINFO="$ENV_DIR/meminfo" \
    bash "$VERIFY" 2>&1
}

# (a) tracked policy 28+14+8+5 = 56320 MB + 6333 MB reserve <= 63336 MB.
set_live_policy 13 14 7 8
env_out=$(run_envelope "$ROOT") || fail "host-docker 28+14+8+5 envelope should pass: $env_out"
grep -Fq '56320MB' <<<"$env_out" || fail "envelope did not sum live maxima to 56320MB: $env_out"

# (b) an unbounded live maximum is rejected, never summed as zero.
printf 'max\n' > "$ENV_DIR/cg/user/agents.slice/memory.max"
if env_out=$(run_envelope "$ROOT"); then
  fail "unbounded agents.slice memory.max should fail: $env_out"
fi
grep -Fq 'agents.slice' <<<"$env_out" || fail "unbounded rejection did not name agents.slice: $env_out"

# (c) the pre-154k maxima 28+20+10+5 = 64512 MB over-commit the host even
#     when live state matches its (old) policy.
OLD_POLICY="$TMP/old-policy"
mkdir -p "$OLD_POLICY/systemd/host" "$OLD_POLICY/systemd/host-docker/lima-vm@colima.service.d"
cp "$ROOT/systemd/host/actions.slice" "$OLD_POLICY/systemd/host/actions.slice"
cp "$ROOT/systemd/host-docker/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  "$OLD_POLICY/systemd/host-docker/lima-vm@colima.service.d/99-memory-ceiling.conf" 2>/dev/null \
  || printf '[Service]\nMemoryHigh=4608M\nMemoryMax=5G\n' \
       > "$OLD_POLICY/systemd/host-docker/lima-vm@colima.service.d/99-memory-ceiling.conf"
printf '[Slice]\nMemoryHigh=18G\nMemoryMax=20G\n' > "$OLD_POLICY/systemd/agents.slice"
printf '[Slice]\nMemoryHigh=8G\nMemoryMax=10G\n' > "$OLD_POLICY/systemd/automation.slice"
set_live_policy 18 20 8 10
if env_out=$(run_envelope "$OLD_POLICY"); then
  fail "host-docker 28+20+10+5 envelope should fail: $env_out"
fi
grep -Fq 'exceed host' <<<"$env_out" || fail "old maxima did not fail on the envelope sum: $env_out"

# (d) live state that drifted from the tracked policy fails even if it fits.
set_live_policy 13 14 6 7
if env_out=$(run_envelope "$ROOT"); then
  fail "live automation.slice 6G/7G must not match the tracked 7G/8G policy: $env_out"
fi

# Gate 8 (3): oomd must monitor /actions.slice (real `oomctl` layout).
cat > "$TMP/oomctl-enrolled.txt" <<'EOF'
Dry Run: no
Swap Used Limit: 90.00%
Default Memory Pressure Limit: 60.00%
Default Memory Pressure Duration: 20s
System Context:
	Memory: Used: 0B Total: 0B
	Swap: Used: 0B Total: 0B
Swap Monitored CGroups:
Memory Pressure Monitored CGroups:
	Path: /actions.slice
		Memory Pressure Limit: 80.00%
		Pressure: Avg10: 0.00 Avg60: 0.00 Avg300: 0.00 Total: 0
		Current Memory Usage: 7.5G
		Memory Min: 0B
		Memory Low: 0B
		Pgscan: 0
		Last Pgscan: 0
EOF
cat > "$TMP/oomctl-empty.txt" <<'EOF'
Dry Run: no
Swap Used Limit: 90.00%
Default Memory Pressure Limit: 60.00%
Default Memory Pressure Duration: 20s
System Context:
	Memory: Used: 0B Total: 0B
	Swap: Used: 0B Total: 0B
Swap Monitored CGroups:
	Path: /actions.slice
Memory Pressure Monitored CGroups:
	Path: /user.slice
EOF
cat > "$TMP/oomctl-none.txt" <<'EOF'
Dry Run: no
Memory Pressure Monitored CGroups:
EOF
run_oomctl() {
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
  VERIFY_EXIT_CRITERIA_TEST_CASE=oomctl_actions \
  VERIFY_EXIT_CRITERIA_OOMCTL_FIXTURE="$1" \
    bash "$VERIFY" >/dev/null 2>&1
}
run_oomctl "$TMP/oomctl-enrolled.txt" || fail "oomctl listing /actions.slice under pressure should pass"
if run_oomctl "$TMP/oomctl-empty.txt"; then
  fail "/actions.slice only under Swap (pressure lists /user.slice) must not pass"
fi

# Exercise the actual inline Gate 8 (3) branch. The timer is deliberately
# enabled, active, and points to a script with a real `kill` shed path.
# Host-docker still must fail without /actions.slice; VM-backed retains the
# timer fallback when oomd has no enrolled cgroups.
PSI_BIN="$TMP/psi-bin"
mkdir -p "$PSI_BIN"
cat > "$PSI_BIN/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = info ] || exit 1
if [ "${PSI_MODE:?}" = host ]; then uname -r; else printf 'guest-kernel\n'; fi
EOF
cat > "$PSI_BIN/oomctl" <<'EOF'
#!/usr/bin/env bash
cat "${PSI_OOMCTL_FIXTURE:?}"
EOF
cat > "$TMP/psi-shed.sh" <<'EOF'
#!/usr/bin/env bash
kill -0 "$$"
EOF
cat > "$PSI_BIN/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  'is-active systemd-oomd') printf 'active\\n' ;;
  *'--user is-enabled psi-oom-watcher.timer'*) printf 'enabled\\n' ;;
  *'--user is-active psi-oom-watcher.timer'*) printf 'active\\n' ;;
  *'--user cat psi-oom-watcher.timer'*) printf 'ExecStart=%s\\n' '$TMP/psi-shed.sh' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$PSI_BIN/docker" "$PSI_BIN/oomctl" "$PSI_BIN/systemctl" "$TMP/psi-shed.sh"
PSI_BLOCK="$TMP/gate8-psi-block.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  printf '%s\n' 'fail() { echo "FAIL: $*" >&2; exit 1; }'
  sed -n '/^daemon_in_vm() {/,/^}/p' "$VERIFY"
  sed -n '/^oomctl_lists_actions_slice() {/,/^}/p' "$VERIFY"
  sed -n '/^host_docker_requires_actions_oomctl() {/,/^}/p' "$VERIFY"
  sed -n '/^# (3) PSI admission check/,/^# (4) Physical-host RAM envelope/{/^# (4) Physical-host RAM envelope/d;p}' "$VERIFY"
} > "$PSI_BLOCK"
chmod +x "$PSI_BLOCK"
run_gate8_psi() { # mode oomctl-fixture
  PATH="$PSI_BIN:$PATH" PSI_MODE="$1" PSI_OOMCTL_FIXTURE="$2" \
    bash "$PSI_BLOCK" 2>&1
}
host_pass=$(run_gate8_psi host "$TMP/oomctl-enrolled.txt") \
  || fail "host-docker /actions.slice pressure enrollment should pass: $host_pass"
grep -Fq 'oomctl: /actions.slice under Memory Pressure Monitored CGroups' <<<"$host_pass" \
  || fail "host-docker pass did not use the /actions.slice oomctl branch: $host_pass"
if host_fail=$(run_gate8_psi host "$TMP/oomctl-empty.txt"); then
  fail "host-docker Gate 8 (3) accepted an active psi timer without /actions.slice"
fi
grep -Fq 'psi-oom-watcher.timer is not an acceptable fallback' <<<"$host_fail" \
  || fail "host-docker rejection did not name the rejected timer fallback: $host_fail"
vm_pass=$(run_gate8_psi vm "$TMP/oomctl-none.txt") \
  || fail "VM-backed Gate 8 (3) should retain the active psi timer fallback: $vm_pass"
grep -Fq 'psi-oom-watcher.timer (user-scope' <<<"$vm_pass" \
  || fail "VM-backed pass did not use the timer fallback: $vm_pass"

# Kdump/pstore verification is diagnostic-only. It must be quiet on a healthy
# fixture, fail closed on an unhealthy fixture, and never invoke a remediation
# hook (including the retired compatibility environment variable).
mkdir -p "$TMP/pstore" "$TMP/crash"
chmod 0555 "$TMP/crash"
printf '1\n' > "$TMP/kexec_crash_loaded"
cat > "$TMP/forbidden-remediation" <<EOF
#!/usr/bin/env bash
touch "$TMP/remediation-was-called"
EOF
chmod +x "$TMP/forbidden-remediation"
healthy_out=$(VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
  VERIFY_EXIT_CRITERIA_TEST_CASE=kdump \
  VERIFY_EXIT_CRITERIA_PSTORE_ROOT="$TMP/pstore" \
  VERIFY_EXIT_CRITERIA_KEXEC_CRASH_LOADED_PATH="$TMP/kexec_crash_loaded" \
  VERIFY_EXIT_CRITERIA_KDUMP_DIR="$TMP/crash" \
  VERIFY_EXIT_CRITERIA_KDUMP_MOUNT_OPTIONS=rw,relatime \
  VERIFY_EXIT_CRITERIA_KDUMP_REMEDIATION="$TMP/forbidden-remediation" \
  bash "$VERIFY" 2>&1) \
  || fail "healthy kdump fixture should pass: $healthy_out"
! grep -Fq '[FAIL]' <<<"$healthy_out" \
  || fail "healthy kdump fixture emitted a false [FAIL]: $healthy_out"
[ ! -e "$TMP/remediation-was-called" ] \
  || fail "healthy kdump fixture invoked forbidden remediation"

rm -rf "$TMP/pstore"
failed_out=''
failed_rc=0
failed_out=$(VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
  VERIFY_EXIT_CRITERIA_TEST_CASE=kdump \
  VERIFY_EXIT_CRITERIA_PSTORE_ROOT="$TMP/pstore" \
  VERIFY_EXIT_CRITERIA_KEXEC_CRASH_LOADED_PATH="$TMP/kexec_crash_loaded" \
  VERIFY_EXIT_CRITERIA_KDUMP_DIR="$TMP/crash" \
  VERIFY_EXIT_CRITERIA_KDUMP_REMEDIATION="$TMP/forbidden-remediation" \
  bash "$VERIFY" 2>&1) || failed_rc=$?
[ "$failed_rc" -ne 0 ] || fail "missing pstore fixture should fail closed"
grep -Fq 'Crash capture FAIL-CLOSED' <<<"$failed_out" \
  || fail "kdump failure omitted diagnostic: $failed_out"
[ ! -e "$TMP/remediation-was-called" ] \
  || fail "kdump failure invoked forbidden remediation"

mkdir -p "$TMP/pstore"
readonly_out=''
readonly_rc=0
readonly_out=$(VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
  VERIFY_EXIT_CRITERIA_TEST_CASE=kdump \
  VERIFY_EXIT_CRITERIA_PSTORE_ROOT="$TMP/pstore" \
  VERIFY_EXIT_CRITERIA_KEXEC_CRASH_LOADED_PATH="$TMP/kexec_crash_loaded" \
  VERIFY_EXIT_CRITERIA_KDUMP_DIR="$TMP/crash" \
  VERIFY_EXIT_CRITERIA_KDUMP_MOUNT_OPTIONS=ro,relatime \
  VERIFY_EXIT_CRITERIA_KDUMP_REMEDIATION="$TMP/forbidden-remediation" \
  bash "$VERIFY" 2>&1) || readonly_rc=$?
[ "$readonly_rc" -ne 0 ] || fail "read-only kdump target mount should fail closed"
grep -Fq 'not on a verifiably writable mount' <<<"$readonly_out" \
  || fail "read-only kdump target omitted diagnostic: $readonly_out"
[ ! -e "$TMP/remediation-was-called" ] \
  || fail "read-only kdump target invoked forbidden remediation"

echo "VERIFY_EXIT_GATE8_TEST: PASS"
