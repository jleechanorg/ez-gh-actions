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

# Gate 8 obsolete-timer loop: agent-scope-reaper was deleted and the PSI
# watcher is disabled by policy (install.sh), so the verifier must NOT demand
# either timer be enabled+active, and must fail if psi-oom-watcher.timer is
# enabled (policy drift).
mkdir -p "$TMP/timerbin"
cat > "$TMP/timerbin/systemctl" <<'EOF2'
#!/usr/bin/env bash
# stub: is-enabled/is-active answer from $STUB_ENABLED_TIMERS (space list)
[ "${1:-}" = "--user" ] && shift
case "${1:-}" in
  is-enabled|is-active)
    if [ -n "${STUB_SYSTEMCTL_BROKEN:-}" ]; then
      echo "${STUB_BROKEN_MSG:-Failed to connect to bus: No medium found}" >&2; exit 1
    fi
    for t in ${STUB_ENABLED_TIMERS:-}; do [ "$t" = "${2:-}" ] && { echo enabled; exit 0; }; done
    if [ -n "${STUB_NOTFOUND:-}" ]; then echo not-found; exit 4; fi
    if [ -n "${STUB_ABSENT:-}" ]; then
      echo "Failed to get unit file state for ${2:-}: No such file or directory" >&2; exit 1
    fi
    echo disabled; exit 1 ;;
esac
exit 1
EOF2
chmod +x "$TMP/timerbin/systemctl"
timers_rc=0
timers_out=$(PATH="$TMP/timerbin:$PATH" STUB_ENABLED_TIMERS="" \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" 2>&1) || timers_rc=$?
[ "$timers_rc" -eq 0 ] \
  || fail "no reaper/psi timers enabled must pass Gate 8 timer check (rc=$timers_rc): $timers_out"
timers_rc=0
timers_out=$(PATH="$TMP/timerbin:$PATH" STUB_ENABLED_TIMERS="psi-oom-watcher.timer" \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" 2>&1) || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "enabled psi-oom-watcher.timer must fail Gate 8 (policy: disabled)"
grep -Fq 'psi-oom-watcher.timer' <<<"$timers_out" \
  || fail "psi timer failure omitted diagnostic: $timers_out"
# A broken user manager (query failure, not a known disabled/absent state)
# must fail closed rather than read as "timer disabled".
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_SYSTEMCTL_BROKEN=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "systemctl query failure must fail Gate 8 closed"
# No user session (ssh/cron): the bus error also says "No such file or
# directory" but is a query failure, not an absent unit.
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_SYSTEMCTL_BROKEN=1 \
  STUB_BROKEN_MSG="Failed to connect to bus: No such file or directory" \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "bus-connect failure ('No such file') must fail Gate 8 closed"
# An absent unit (No such file) is a known-disabled state and passes.
PATH="$TMP/timerbin:$PATH" STUB_ABSENT=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || fail "absent psi-oom-watcher.timer must pass"
# systemd 255 prints exactly "not-found" (exit 4) for an absent unit, the
# normal state once install.sh has deleted the watcher unit files.
PATH="$TMP/timerbin:$PATH" STUB_NOTFOUND=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || fail "systemd not-found (exit 4) for absent timer must pass"
[ "$(grep -c 'agent-scope-reaper' "$VERIFY")" -eq 0 ] \
  || fail "verifier still references deleted agent-scope-reaper"

echo "VERIFY_EXIT_GATE8_TEST: PASS"
