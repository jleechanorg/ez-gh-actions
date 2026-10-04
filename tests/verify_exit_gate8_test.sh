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

# Policy helpers must account for native host-Docker actions.slice, preserve
# VM nesting, use the selected 10/14 TasksMax contract, and honor the
# installer-retired timer policy.
MODERN="$TMP/modern"
mkdir -p "$MODERN"
cat > "$MODERN/app-lima-vm.slice" <<UNIT
[Slice]
MemoryHigh=34G
MemoryMax=38G
MemorySwapMax=2G
TasksMax=4096
UNIT
cat > "$MODERN/agents.slice" <<UNIT
[Slice]
MemoryHigh=18G
MemoryMax=20G
MemorySwapMax=2G
TasksMax=8192
UNIT
cat > "$MODERN/automation.slice" <<UNIT
[Slice]
MemoryHigh=8G
MemoryMax=10G
MemorySwapMax=1G
TasksMax=4096
UNIT
cat > "$TMP/actions.slice" <<UNIT
[Slice]
MemoryHigh=26G
MemoryMax=28G
MemorySwapMax=0
TasksMax=8000
UNIT
cat > "$TMP/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
case "${1:-}" in
  --user) shift ;;
esac
if [ "${1:-}" = show ]; then
  unit="${2:-}"
  case "${TIMER_MODE:-disabled}:$unit:${4:-}" in
    disabled:*:LoadState) echo loaded ;;
    disabled:*:ActiveState) echo inactive ;;
    enabled:*:LoadState) echo loaded ;;
    enabled:*:ActiveState) echo active ;;
    absent:*:LoadState) echo not-found ;;
    absent:*:ActiveState) echo inactive ;;
    unreadable:*) exit 1 ;;
    service-absent:ao-orchestrator.service:LoadState) echo not-found ;;
    service-absent:*:LoadState) echo loaded ;;
    service-absent:*:ActiveState) echo inactive ;;
    service-loaded:*:LoadState) echo loaded ;;
    service-loaded:*:ActiveState) echo inactive ;;
    *) exit 1 ;;
  esac
  exit 0
elif [ "${1:-}" = is-enabled ]; then
  case "${TIMER_MODE:-disabled}" in disabled) echo disabled; exit 1 ;; enabled) echo enabled ;; *) exit 1 ;; esac
fi
exit 1
EOF_SYSTEMCTL
chmod +x "$TMP/systemctl"

policy_env=(PATH="$TMP:$PATH" VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_policy VERIFY_EXIT_CRITERIA_MODERN_UNIT_DIR="$MODERN" VERIFY_EXIT_CRITERIA_ACTIONS_UNIT="$TMP/actions.slice" VERIFY_EXIT_CRITERIA_MODERN_BASE_MB=69632 VERIFY_EXIT_CRITERIA_HOST_MB=80000)
if ! env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 bash "$VERIFY" >/dev/null; then
  fail "VM-backed actions must remain nested and disabled retired timers must pass"
fi
if env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=1 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 bash "$VERIFY" >/dev/null 2>&1; then
  fail "native actions.slice max must be included in hard-envelope arithmetic"
fi
if env "${policy_env[@]}" TIMER_MODE=enabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 bash "$VERIFY" >/dev/null 2>&1; then
  fail "enabled retired timer must fail policy verification"
fi
if env "${policy_env[@]}" TIMER_MODE=unreadable VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 bash "$VERIFY" >/dev/null 2>&1; then
  fail "unreadable retired timer state must fail closed"
fi
if ! env "${policy_env[@]}" TIMER_MODE=absent VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 bash "$VERIFY" >/dev/null; then
  fail "absent retired timer must be accepted as retired"
fi
out=$(env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 bash "$VERIFY")
grep -q "selected_tasks=6000" <<<"$out" || fail "10-runner rollback must derive TasksMax=6000"
out=$(env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=14 bash "$VERIFY")
grep -q "selected_tasks=8000" <<<"$out" || fail "14-runner profile must derive TasksMax=8000"

DROPINS="$TMP/dropins"
mkdir -p "$DROPINS/ao-daemon.service.d" "$DROPINS/ai.dark-factory.daemon.service.d"
printf "[Service]\\nSlice=automation.slice\\n" > "$DROPINS/ao-daemon.service.d/20-automation-slice.conf"
printf "[Service]\\nSlice=automation.slice\\n" > "$DROPINS/ai.dark-factory.daemon.service.d/20-automation-slice.conf"
if ! PATH="$TMP:$PATH" VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=automation_dropins VERIFY_EXIT_CRITERIA_DROPIN_DIR="$DROPINS" TIMER_MODE=service-absent bash "$VERIFY" >/dev/null; then
  fail "not-found ao-orchestrator service must not require its drop-in"
fi
if PATH="$TMP:$PATH" VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=automation_dropins VERIFY_EXIT_CRITERIA_DROPIN_DIR="$DROPINS" TIMER_MODE=service-loaded bash "$VERIFY" >/dev/null 2>&1; then
  fail "loaded ao-orchestrator service must require its automation drop-in"
fi

echo "VERIFY_EXIT_GATE8_POLICY_TEST: PASS"
echo "VERIFY_EXIT_GATE8_TEST: PASS"
