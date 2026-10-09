#!/usr/bin/env bash
# Focused Gate-8 regression coverage. The verifier's test mode exercises the
# same config/cgroup helpers without running the live fleet gates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="${VERIFY:-$ROOT/docs/verify-exit-criteria.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Unknown daemon ownership must never select the native-host policy.
(
  eval "$(sed -n '/^containment_in_vm() {/,/^}/p' "$VERIFY")"
  eval "$(sed -n '/^host_docker_requires_actions_oomctl() {/,/^}/p' "$VERIFY")"
  export DOCKER_HOST=ssh://unowned-fixture
  unset DOCKER_CONTAINMENT_MODE
  if host_docker_requires_actions_oomctl; then
    fail "unknown Docker endpoint selected host policy"
  fi
) || fail "Docker ownership dispatch is unsafe"

DOCKER_CONTAINMENT_MODE=host-docker

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
  inspect)
    case "${3:-}" in
      '{{.State.Pid}}') printf '4242\n' ;;
      '{{.State.Running}} {{.State.Status}} {{.State.Pid}}') printf 'true running 4242\n' ;;
      *) exit 1 ;;
    esac
    ;;
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

# Gate-8 turnover fixtures use one atomic inspect response for running/status/PID.
mkdir -p "$TMP/race-proc/4242" "$TMP/race-cgroup/actions.slice/live.scope"
printf '0::/actions.slice/live.scope\n' > "$TMP/race-proc/4242/cgroup"
mkdir -p "$TMP/race-proc/4343" "$TMP/race-cgroup/actions.slice"
printf '0::/user.slice/runner.scope\n' > "$TMP/race-proc/4343/cgroup"
mkdir -p "$TMP/race-proc/4345"
printf '0::/actions.slice/missing.scope\n' > "$TMP/race-proc/4345/cgroup"
cat > "$TMP/docker-race" <<'EOF_RACE'
#!/usr/bin/env bash
set -e
case "${1:-}" in
  ps)
    case "${DOCKER_SCENARIO:-mixed}" in
      mixed) printf '%s\n' runner-stopped runner-live ;;
      all-exited) printf '%s\n' runner-stopped-a runner-stopped-b ;;
      empty) : ;;
      running-pid0|running-PID0) printf '%s\n' runner-pid0 ;;
      malformed-state) printf '%s\n' runner-malformed ;;
      outside) printf '%s\n' runner-outside ;;
      missing-proc) printf '%s\n' runner-missing-proc ;;
      missing-cgroup) printf '%s\n' runner-missing-cgroup ;;
      inspect-failure|inspect-error) printf '%s\n' runner-inspect-failure ;;
      docker-failure) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  inspect)
    id="${4:-}"
    case "$id" in
      runner-stopped|runner-stopped-a|runner-stopped-b) state='false exited 0' ;;
      runner-live) state='true running 4242' ;;
      runner-pid0) state='true running 0' ;;
      runner-malformed) state='corrupt' ;;
      runner-outside) state='true running 4343' ;;
      runner-missing-proc) state='true running 4344' ;;
      runner-missing-cgroup) state='true running 4345' ;;
      runner-inspect-failure) exit 1 ;;
      *) exit 1 ;;
    esac
    case "${3:-}" in
      '{{.State.Pid}}') printf '%s\n' "${state##* }" ;;
      '{{.State.Running}} {{.State.Status}} {{.State.Pid}}') printf '%s\n' "$state" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF_RACE
chmod +x "$TMP/docker-race"

run_container_case() {
  local scenario="$1" expected="$2" output rc
  output=''
  rc=0
  output=$(PATH="$TMP:$PATH" DOCKER_SCENARIO="$scenario" \
    VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
    VERIFY_EXIT_CRITERIA_TEST_CASE=containers \
    VERIFY_EXIT_CRITERIA_PROC_ROOT="$TMP/race-proc" \
    VERIFY_EXIT_CRITERIA_CGROUP_ROOT="$TMP/race-cgroup" \
    bash "$VERIFY" 2>&1) || rc=$?
  if [ "$expected" = pass ]; then
    [ "$rc" -eq 0 ] || fail "$scenario should pass: $output"
  else
    [ "$rc" -ne 0 ] || fail "$scenario should fail closed"
  fi
}

# The stopped PID-0 container may be observed during turnover, but a live
# peer must still be positively inspected and contained.
PATH="$TMP:$PATH" ln -sf "$TMP/docker-race" "$TMP/docker"
run_container_case mixed pass
run_container_case all-exited fail
run_container_case empty fail
run_container_case running-pid0 fail
run_container_case running-PID0 fail
run_container_case malformed-state fail
run_container_case outside fail
run_container_case missing-proc fail
run_container_case missing-cgroup fail
run_container_case inspect-failure fail
run_container_case inspect-error fail
run_container_case docker-failure fail

# Hermetic fake limactl transport for guest cgroup & container probes.
cat > "$TMP/limactl" <<'EOF_LIMA'
#!/usr/bin/env bash
set -e
if [ "${1:-}" != "shell" ] || [ "${2:-}" != "colima" ]; then
  echo "fake limactl: unexpected arguments: $*" >&2
  exit 1
fi
shift 2
if [ "${1:-}" = "--" ]; then shift; fi
if [ "${1:-}" != "sh" ] || [ "${2:-}" != "-lc" ]; then
  echo "fake limactl: expected 'sh -lc <cmd>', got: $*" >&2
  exit 1
fi
cmd="$3"

if [ -n "${GUEST_CGROUP_ROOT:-}" ]; then
  cmd="${cmd//\/sys\/fs\/cgroup/$GUEST_CGROUP_ROOT}"
fi
if [ -n "${GUEST_PROC_ROOT:-}" ]; then
  cmd="${cmd//\/proc/$GUEST_PROC_ROOT}"
fi
if [ -n "${GUEST_SYSTEMD_ROOT:-}" ]; then
  cmd="${cmd//\/etc\/systemd\/system/$GUEST_SYSTEMD_ROOT}"
fi

if [ -n "${GUEST_TRANSPORT_ERR_LOG:-}" ]; then
  exec 2> >(tee "$GUEST_TRANSPORT_ERR_LOG" >&2)
fi
exec sh -c "$cmd"
EOF_LIMA
chmod +x "$TMP/limactl"

mkdir -p "$TMP/guest-systemd"
touch "$TMP/guest-systemd/actions.slice"
printf '30064771072\n' > "$TMP/race-cgroup/actions.slice/memory.high"
printf '34359738368\n' > "$TMP/race-cgroup/actions.slice/memory.max"
printf '0\n' > "$TMP/race-cgroup/actions.slice/memory.swap.max"
printf '6000\n' > "$TMP/race-cgroup/actions.slice/pids.max"

eval "$(sed -n "/^GUEST_RUNNERS_ACTIONS_SLICE_SCRIPT=/,/^'/p" "$VERIFY")"
eval "$(sed -n '/^verify_guest_managed_runners_in_actions_slice() {/,/^}/p' "$VERIFY")"
GUEST_AGG_SRC=$(sed -n '/GUEST_ACTIONS_VALUES=""/,/Gate 8 guest runner aggregate: high=28G/p' "$VERIFY")

run_guest_container_case() {
  local scenario="$1" expected="$2" expected_diag="${3:-}" output rc transport_err
  output=''
  rc=0
  transport_err="$TMP/guest_transport_err.log"
  rm -f "$transport_err"
  output=$(PATH="$TMP:$PATH" \
    DOCKER_SCENARIO="$scenario" \
    GUEST_CGROUP_ROOT="$TMP/race-cgroup" \
    GUEST_PROC_ROOT="$TMP/race-proc" \
    GUEST_TRANSPORT_ERR_LOG="$transport_err" \
    GUEST_RUNNERS_ACTIONS_SLICE_SCRIPT="${GUEST_RUNNERS_ACTIONS_SLICE_SCRIPT:-}" \
    verify_guest_managed_runners_in_actions_slice 2>&1) || rc=$?
  local err_msg
  err_msg=$(cat "$transport_err" 2>/dev/null || true)
  if [ "$expected" = pass ]; then
    [ "$rc" -eq 0 ] || fail "guest container $scenario should pass (rc=$rc, output='$output', guest_err='$err_msg')"
  else
    [ "$rc" -ne 0 ] || fail "guest container $scenario should fail closed"
    if [ -n "$expected_diag" ]; then
      local combined="$output $err_msg"
      grep -Fq "$expected_diag" <<<"$combined" || fail "guest container $scenario expected diagnostic '$expected_diag', got: '$combined'"
    fi
  fi
}

run_guest_aggregate_case() {
  local scenario="$1" expected="$2" output rc
  output=''
  rc=0
  output=$(
    export PATH="$TMP:$PATH"
    export DOCKER_SCENARIO="$scenario"
    export GUEST_CGROUP_ROOT="$TMP/race-cgroup"
    export GUEST_PROC_ROOT="$TMP/race-proc"
    export GUEST_SYSTEMD_ROOT="$TMP/guest-systemd"
    export GUEST_RUNNERS_ACTIONS_SLICE_SCRIPT="${GUEST_RUNNERS_ACTIONS_SLICE_SCRIPT:-}"
    fail() { echo "FAIL: $*" >&2; exit 1; }
    eval "$GUEST_AGG_SRC" 2>&1
  ) || rc=$?
  if [ "$expected" = pass ]; then
    [ "$rc" -eq 0 ] || fail "guest aggregate $scenario should pass: $output"
  else
    [ "$rc" -ne 0 ] || fail "guest aggregate $scenario should fail closed"
  fi
}

# (a) Guest managed runner helper cases
run_guest_container_case mixed pass
run_guest_container_case all-exited fail "no positively inspected live managed runner containers found"
run_guest_container_case empty fail "no managed runner containers found"
run_guest_container_case inspect-error fail "could not be inspected"
run_guest_container_case running-PID0 fail "invalid live PID: 0"
run_guest_container_case malformed-state fail "returned malformed state"
run_guest_container_case outside fail "is outside actions.slice"
run_guest_container_case missing-proc fail "outside actions.slice: unavailable"
run_guest_container_case missing-cgroup fail "is not materialized under"

# (b) Guest aggregate runner traversal cases
run_guest_aggregate_case mixed pass
run_guest_aggregate_case all-exited fail
run_guest_aggregate_case empty fail
run_guest_aggregate_case inspect-error fail
run_guest_aggregate_case running-PID0 fail
run_guest_aggregate_case malformed-state fail
run_guest_aggregate_case outside fail
run_guest_aggregate_case missing-proc fail
run_guest_aggregate_case missing-cgroup fail

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
! grep -Fq "pgrep -f 'qemu-system-x86_64'" "$VERIFY" \
  || fail "Gate 8 still selects an arbitrary host QEMU"
grep -Fq 'assert-qemu-cpu-ceiling.sh' "$VERIFY" \
  || fail "Gate 8 does not reuse the service-bound QEMU assertion"

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
set_live_policy() { # agents_high agents_max automation_high automation_max (bytes)
  set_live actions.slice $((26 * G)) $((28 * G))
  set_live user/agents.slice "$1" "$2"
  set_live user/automation.slice "$3" "$4"
  set_live user/lima-vm@colima.service $((9 * G)) $((10 * G))
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

# (a) tracked policy 28+12+5+10 = 56320 MB + 6333 MB reserve <= 63336 MB.
set_live_policy $((10 * G)) $((12 * G)) $((4608 * 1048576)) $((5 * G))
env_out=$(run_envelope "$ROOT") || fail "host-docker 28+12+5+10 envelope should pass: $env_out"
grep -Fq '56320MB' <<<"$env_out" || fail "envelope did not sum live maxima to 56320MB: $env_out"

# (b) an unbounded live maximum is rejected, never summed as zero.
printf 'max\n' > "$ENV_DIR/cg/user/agents.slice/memory.max"
if env_out=$(run_envelope "$ROOT"); then
  fail "unbounded agents.slice memory.max should fail: $env_out"
fi
grep -Fq 'agents.slice' <<<"$env_out" || fail "unbounded rejection did not name agents.slice: $env_out"

# (c) maxima of 28+20+10+10 = 69632 MB over-commit the host even
#     when live state matches its (old) policy.
OLD_POLICY="$TMP/old-policy"
mkdir -p "$OLD_POLICY/systemd/host" "$OLD_POLICY/systemd/lima-vm@colima.service.d"
cp "$ROOT/systemd/host/actions.slice" "$OLD_POLICY/systemd/host/actions.slice"
cp "$ROOT/systemd/lima-vm@colima.service.d/99-memory-ceiling.conf" \
  "$OLD_POLICY/systemd/lima-vm@colima.service.d/99-memory-ceiling.conf"
printf '[Slice]\nMemoryHigh=18G\nMemoryMax=20G\n' > "$OLD_POLICY/systemd/agents.slice"
printf '[Slice]\nMemoryHigh=8G\nMemoryMax=10G\n' > "$OLD_POLICY/systemd/automation.slice"
set_live_policy $((18 * G)) $((20 * G)) $((8 * G)) $((10 * G))
if env_out=$(run_envelope "$OLD_POLICY"); then
  fail "host-docker 28+20+10+10 envelope should fail: $env_out"
fi
grep -Fq 'exceed host' <<<"$env_out" || fail "old maxima did not fail on the envelope sum: $env_out"

# (d) live state that drifted from the tracked policy fails even if it fits.
set_live_policy $((10 * G)) $((12 * G)) $((4 * G)) $((5 * G))
if env_out=$(run_envelope "$ROOT"); then
  fail "live automation.slice 4G/5G must not match the tracked 4608M/5G policy: $env_out"
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

# Gate 8 timer policy is executed before optional envelope detection. Both
# auxiliary mutation timers must be disabled and inactive because install.sh
# retires them.
TIMER_BIN="$TMP/timer-bin"
mkdir -p "$TIMER_BIN"
cat > "$TIMER_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--user" ] && shift
case "${1:-}" in
  is-enabled)
    if [ -n "${STUB_ENABLED_BROKEN:-}" ] && { [ -z "${STUB_BROKEN_TIMER:-}" ] || [ "${2:-}" = "${STUB_BROKEN_TIMER}" ]; }; then
      echo "${STUB_BROKEN_MSG:-Failed to connect to bus: No medium found}" >&2; exit 1
    fi
    for timer in ${STUB_ENABLED_TIMERS:-}; do [ "$timer" = "${2:-}" ] && { echo enabled; exit 0; }; done
    if [ -n "${STUB_ABSENT:-}" ]; then echo "Failed to get unit file state for ${2:-}: No such file or directory" >&2; exit 1; fi
    if [ -n "${STUB_NOTFOUND:-}" ]; then echo not-found; exit 4; fi
    echo disabled; exit 1 ;;
  is-active)
    if [ "${2:-}" = systemd-oomd ]; then echo inactive; exit 3; fi
    if [ -n "${STUB_ACTIVE_BROKEN:-}" ] && { [ -z "${STUB_BROKEN_TIMER:-}" ] || [ "${2:-}" = "${STUB_BROKEN_TIMER}" ]; }; then
      echo "${STUB_BROKEN_MSG:-Failed to connect to bus: No medium found}" >&2; exit 1
    fi
    for timer in ${STUB_ACTIVE_TIMERS:-}; do [ "$timer" = "${2:-}" ] && { echo active; exit 0; }; done
    echo inactive; exit 3 ;;
esac
exit 1
EOF
chmod +x "$TIMER_BIN/systemctl"

# Run the real Linux pre-envelope Gate 8 dispatch, not only the helper.
run_gate8_pre_envelope() {
  local gate_header modern_start gate_start retired_start helper_start helper_end saved_fail
  export STUB_ENABLED_TIMERS STUB_ACTIVE_TIMERS STUB_ABSENT STUB_NOTFOUND \
    STUB_ENABLED_BROKEN STUB_ACTIVE_BROKEN STUB_BROKEN_TIMER STUB_BROKEN_MSG
  gate_header=$(grep -n '^echo "--- Checking Gate 8: VM/AO/MCP containment ---"$' "$VERIFY" | cut -d: -f1)
  modern_start=$(grep -n '^IS_MODERN_ENVELOPE=0$' "$VERIFY" | cut -d: -f1)
  gate_start=$(awk -v min="$gate_header" -v max="$modern_start" 'NR >= min && NR < max && /^if \[ "\$\(uname -s\)" = "Linux" \]; then$/ { print NR; exit }' "$VERIFY")
  retired_start=$(grep -n '^verify_retired_timer() {' "$VERIFY" | cut -d: -f1)
  helper_start=$(grep -n '^verify_modern_timers() {' "$VERIFY" | cut -d: -f1)
  helper_end=$(awk -v start="$helper_start" 'NR > start && /^}$/ { print NR; exit }' "$VERIFY")
  [ -n "$gate_start" ] && [ -n "$retired_start" ] && [ -n "$helper_start" ] && [ -n "$helper_end" ] || fail "could not extract Gate 8 timer dispatch"
  saved_fail=$(declare -f fail)
  GATE8_POLICY_FAILURE=""
  CONFIG_FILE="$TMP/valid.toml"
  fail() { GATE8_POLICY_FAILURE="$*"; }
  uname() { echo Linux; }
  verify_platform_actions_slice() { return 0; }
  containment_in_vm() { return 1; }
  verify_managed_runners_in_actions_slice() { return 0; }
  eval "$(sed -n "${retired_start},${helper_end}p" "$VERIFY")"
  eval "$(sed -n "${gate_start},$((modern_start - 1))p" "$VERIFY")" || true
  GATE8_POLICY_RESULT="$GATE8_POLICY_FAILURE"
  eval "$saved_fail"
}

PATH="$TIMER_BIN:$PATH"
unset STUB_ENABLED_TIMERS STUB_ACTIVE_TIMERS STUB_ABSENT STUB_NOTFOUND STUB_ENABLED_BROKEN STUB_ACTIVE_BROKEN STUB_BROKEN_TIMER
run_gate8_pre_envelope
[ -z "$GATE8_POLICY_RESULT" ] || fail "both disabled timers must pass pre-envelope dispatch: $GATE8_POLICY_RESULT"
for retired_timer in agent-scope-reaper.timer psi-oom-watcher.timer; do
  STUB_ENABLED_TIMERS="$retired_timer"
  run_gate8_pre_envelope
  [ -n "$GATE8_POLICY_RESULT" ] || fail "enabled ${retired_timer} must fail before optional envelope detection"
  grep -Fq "$retired_timer" <<<"$GATE8_POLICY_RESULT" || fail "enabled timer failure omitted ${retired_timer}: $GATE8_POLICY_RESULT"
  unset STUB_ENABLED_TIMERS
  STUB_ABSENT=1 STUB_ACTIVE_TIMERS="$retired_timer"
  run_gate8_pre_envelope
  [ -n "$GATE8_POLICY_RESULT" ] || fail "absent ${retired_timer} unit but active runtime must fail"
  unset STUB_ABSENT STUB_ACTIVE_TIMERS
done
STUB_ENABLED_BROKEN=1
STUB_BROKEN_TIMER=psi-oom-watcher.timer
run_gate8_pre_envelope
[ -n "$GATE8_POLICY_RESULT" ] || fail "enabled-state bus failure must fail closed"
STUB_BROKEN_MSG="Failed to connect to bus: No such file or directory"
run_gate8_pre_envelope
[ -n "$GATE8_POLICY_RESULT" ] || fail "bus failure with 'No such file' must fail closed"
unset STUB_ENABLED_BROKEN
unset STUB_BROKEN_MSG
STUB_ACTIVE_BROKEN=1
STUB_BROKEN_TIMER=agent-scope-reaper.timer
run_gate8_pre_envelope
[ -n "$GATE8_POLICY_RESULT" ] || fail "active-state bus failure must fail closed"
unset STUB_ACTIVE_BROKEN STUB_BROKEN_TIMER

# Execute the real later PSI admission branch. With oomd inactive it must not
# revive the retired timer as a fallback or remediation.
run_gate8_psi_admission() {
  local psi_start psi_end saved_fail
  psi_start=$(grep -n '^# (3) PSI admission check' "$VERIFY" | cut -d: -f1)
  psi_end=$(grep -n '^# (4) Physical-host RAM envelope' "$VERIFY" | cut -d: -f1)
  [ -n "$psi_start" ] && [ -n "$psi_end" ] || fail "could not extract Gate 8 PSI admission"
  saved_fail=$(declare -f fail)
  GATE8_PSI_FAILURE=""
  fail() { GATE8_PSI_FAILURE="$*"; }
  uname() { echo Linux; }
  containment_in_vm() { return 1; }
  host_docker_requires_actions_oomctl() { return 1; }
  IS_MODERN_ENVELOPE=0
  eval "$(sed -n "${psi_start},$((psi_end - 1))p" "$VERIFY")"
  GATE8_PSI_RESULT="$GATE8_PSI_FAILURE"
  eval "$saved_fail"
}
run_gate8_psi_admission
[ -n "$GATE8_PSI_RESULT" ] || fail "unenrolled oomd must fail the later PSI-admission branch"
grep -Fq 'ManagedOOMMemoryPressure=kill' <<<"$GATE8_PSI_RESULT" || fail "PSI failure omitted enrolled-oomd remediation: $GATE8_PSI_RESULT"
! grep -Fq 'psi-oom-watcher' <<<"$GATE8_PSI_RESULT" || fail "later PSI branch still offers retired timer: $GATE8_PSI_RESULT"

# Test mode covers the shared disabled/inactive policy independently.
timer_out=$(PATH="$TIMER_BIN:$PATH" VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers bash "$VERIFY" 2>&1) || fail "both disabled timers failed test mode: $timer_out"
if timer_out=$(PATH="$TIMER_BIN:$PATH" STUB_ACTIVE_TIMERS=agent-scope-reaper.timer VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers bash "$VERIFY" 2>&1); then
  fail "disabled but active reaper timer must fail: $timer_out"
fi
if timer_out=$(PATH="$TIMER_BIN:$PATH" STUB_ACTIVE_TIMERS=psi-oom-watcher.timer VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers bash "$VERIFY" 2>&1); then
  fail "disabled but active PSI timer must fail: $timer_out"
fi
if timer_out=$(PATH="$TIMER_BIN:$PATH" STUB_NOTFOUND=1 VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers bash "$VERIFY" 2>&1); then
  : # systemd's not-found is a valid disabled PSI state
else
  fail "not-found PSI timer must pass: $timer_out"
fi

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
# Exercise the remaining Linux fixtures on every test host.
mkdir -p "$TMP/linux-bin"
cat > "$TMP/linux-bin/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -s ]; then
  printf 'Linux\n'
else
  exec "$(command -v uname)" "\$@"
fi
EOF
chmod +x "$TMP/linux-bin/uname"
export PATH="$TMP/linux-bin:$PATH"
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
mkdir -p "$MODERN" "$MODERN/lima-vm@colima.service.d"
cat > "$MODERN/app-lima-vm.slice" <<UNIT
[Slice]
MemoryHigh=9G
MemoryMax=10G
MemorySwapMax=2G
TasksMax=4096
UNIT
cat > "$MODERN/lima-vm@colima.service.d/99-memory-ceiling.conf" <<UNIT
[Service]
MemoryHigh=9G
MemoryMax=10G
MemorySwapMax=2G
TasksMax=4096
UNIT
cat > "$MODERN/agents.slice" <<UNIT
[Slice]
MemoryHigh=10G
MemoryMax=12G
MemorySwapMax=2G
TasksMax=8192
UNIT
cat > "$MODERN/automation.slice" <<UNIT
[Slice]
MemoryHigh=4608M
MemoryMax=5G
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
  case "${TIMER_MODE:-disabled}" in disabled) echo disabled; exit 1 ;; enabled) echo enabled ;; absent) echo not-found; exit 4 ;; *) exit 1 ;; esac
elif [ "${1:-}" = is-active ]; then
  case "${TIMER_MODE:-disabled}" in disabled|absent) echo inactive; exit 3 ;; enabled) echo active ;; *) exit 1 ;; esac
fi
exit 1
EOF_SYSTEMCTL
chmod +x "$TMP/systemctl"

# Base MB for 9/10G QEMU (10240), 10/12G agents (12288), 4608M/5G automation (5120) = 27648 MB.
# With native actions (28G = 28672 MB), total hard maxima = 56320 MB (55 GiB).
# In an 80000 MB host, 56320 + 8000 reserve = 64320 <= 80000 -> fits.
# In a 60000 MB host, 56320 + 6000 reserve = 62320 > 60000 -> exceeds.
policy_env=(PATH="$TMP:$PATH" VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_policy VERIFY_EXIT_CRITERIA_MODERN_UNIT_DIR="$MODERN" VERIFY_EXIT_CRITERIA_ACTIONS_UNIT="$TMP/actions.slice" VERIFY_EXIT_CRITERIA_HOST_MB=60000)
if ! env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 VERIFY_EXIT_CRITERIA_HOST_MB=80000 bash "$VERIFY" >/dev/null; then
  fail "VM-backed actions must remain nested and disabled retired timers must pass"
fi
if env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=1 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 bash "$VERIFY" >/dev/null 2>&1; then
  fail "native actions.slice max must be included in hard-envelope arithmetic and fail when exceeding host"
fi
if ! env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=1 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=10 VERIFY_EXIT_CRITERIA_HOST_MB=65000 bash "$VERIFY" >/dev/null; then
  fail "approved 55 GiB budget must fit 65000 MB host (56320 MB + 6500 MB reserve = 62820 MB <= 65000 MB)"
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
out=$(env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=0 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=20 bash "$VERIFY")
grep -q "selected_tasks=8000" <<<"$out" || fail "20-runner profile must derive TasksMax=8000"

cp "$MODERN/automation.slice" "$TMP/automation.good"
sed -i.bak 's/^MemoryMax=.*/MemoryMax=broken/' "$MODERN/automation.slice"
if env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=1 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=14 VERIFY_EXIT_CRITERIA_HOST_MB=65000 bash "$VERIFY" >"$TMP/parser-bad.log" 2>&1; then
  fail "production unit parser must reject malformed automation cap"
fi
cp "$TMP/automation.good" "$MODERN/automation.slice"
mv "$MODERN/agents.slice" "$TMP/agents.good"
if env "${policy_env[@]}" TIMER_MODE=disabled VERIFY_EXIT_CRITERIA_NATIVE_ACTIONS=1 VERIFY_EXIT_CRITERIA_RUNNER_COUNT=14 VERIFY_EXIT_CRITERIA_HOST_MB=65000 bash "$VERIFY" >"$TMP/parser-missing.log" 2>&1; then
  fail "production unit parser must reject unreadable agents unit"
fi
mv "$TMP/agents.good" "$MODERN/agents.slice"

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


# Exercise the mandatory canonical assertion with its existing real-root fixtures.
eval "$(sed -n '/^setup_passing_fixture() {/,/^# 1\. Test clean passing fixture/p' "$ROOT/tests/assert_host_containment_release1_test.sh" | sed '$d')"
eval "$(sed -n '/^write_props() {/,/^PROPS_BIN=/p' "$ROOT/tests/assert_host_containment_release1_test.sh" | sed '$d')"
FIXTURE="$TMP/assert-root"
setup_passing_fixture "$FIXTURE"
write_props 4831838208 5368709120 > "$TMP/props"
mkdir -p "$TMP/policy-bin"
cat > "$TMP/policy-bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = --user ] && [ "${2:-}" = show ] && [[ "${3:-}" = *.timer ]]; then
  case "${5:-}" in
    LoadState) echo loaded ;;
    ActiveState) echo "${FIXTURE_TIMER_ACTIVE:-inactive}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [ "${1:-}" = --user ] && [ "${2:-}" = is-enabled ]; then
  echo "${FIXTURE_TIMER_ENABLED:-disabled}"
  exit 1
fi
if [ "${1:-}" = --user ] && [ "${2:-}" = is-active ] && [[ "${3:-}" = *.timer ]]; then
  echo "${FIXTURE_TIMER_ACTIVE:-inactive}"
  [ "${FIXTURE_TIMER_ACTIVE:-inactive}" = active ] && exit 0 || exit 3
fi
prop="" unit="" scope=system
while [ $# -gt 0 ]; do
  case "$1" in
    --user) scope=user; shift ;;
    -p) prop="$2"; shift 2 ;;
    --) unit="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$unit:$scope" in
  app.slice:system|session.slice:system|actions.slice:user|user.slice:user|-.slice:user) exit 1 ;;
esac
awk -v u="$unit" -v p="$prop" '$1==u && $2==p {print $3; found=1} END {exit !found}' "$SYSTEMD_PROPS"
SHIM
chmod +x "$TMP/policy-bin/systemctl"
# Source only the production predicate; pass the canonical assertion's --root.
eval "$(sed -n '/^verify_retired_timer() {/,/^verify_automation_dropins() {/p' "$VERIFY" | sed '$d')"
MODERN_UNIT_DIR="$MODERN"
export VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_ACTIONS_UNIT="$TMP/actions.slice"
REPO_ROOT="$TMP/no-repository"
COUNT=14
if (verify_modern_psi_policy --root "$FIXTURE") >"$TMP/absent.log" 2>&1; then
  fail "missing mandatory assertion must fail closed"
fi
mkdir -p "$REPO_ROOT/scripts/host"
cp "$ROOT/scripts/host/assert-host-containment-release1.sh" "$REPO_ROOT/scripts/host/"
chmod 000 "$REPO_ROOT/scripts/host/assert-host-containment-release1.sh"
if (verify_modern_psi_policy --root "$FIXTURE") >"$TMP/unreadable.log" 2>&1; then
  fail "unreadable mandatory assertion must fail closed"
fi
chmod 755 "$REPO_ROOT/scripts/host/assert-host-containment-release1.sh"
export CONTAINMENT_LIVE_SYSTEMD=1 SYSTEMD_PROPS="$TMP/props"
export PATH="$TMP/policy-bin:$FIXTURE/bin:$PATH"
(verify_modern_psi_policy --root "$FIXTURE") >"$TMP/valid.log" 2>&1   || fail "canonical finite/auto predicate rejected valid fixture: $(cat "$TMP/valid.log")"
write_props 8589934592 10737418240 > "$TMP/props"
if (verify_modern_psi_policy --root "$FIXTURE") >"$TMP/caps.log" 2>&1; then
  fail "wrong live caps must fail canonical predicate"
fi
write_props 4831838208 5368709120 > "$TMP/props"
sed -i.bak 's/^user.slice ManagedOOMMemoryPressure auto$/user.slice ManagedOOMMemoryPressure kill/' "$TMP/props"
if (verify_modern_psi_policy --root "$FIXTURE") >"$TMP/kill.log" 2>&1; then
  fail "broad-root kill scope must fail canonical predicate"
fi
write_props 4831838208 5368709120 > "$TMP/props"
# The fixture wrapper runs the real assertion and only supplies its --root.
# A rollback-10 fixture also proves this does not depend on the live 14-runner host.
setup_passing_fixture "$FIXTURE" 10
COUNT=10
cat > "$REPO_ROOT/scripts/host/assert-host-containment-release1.sh" <<WRAPPER
#!/usr/bin/env bash
exec "$ROOT/scripts/host/assert-host-containment-release1.sh" "\$@" --root "$FIXTURE"
WRAPPER
chmod +x "$REPO_ROOT/scripts/host/assert-host-containment-release1.sh"
# Reject accidental reads from the native host cgroup and meminfo trees.
REAL_CAT=$(command -v cat)
REAL_AWK=$(command -v awk)
cat > "$TMP/policy-bin/cat" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in /sys/fs/cgroup/*|//sys/fs/cgroup/*|/proc/meminfo|//proc/meminfo) echo forbidden-host-read >&2; exit 97 ;; esac
done
exec "$REAL_CAT" "\$@"
SHIM
cat > "$TMP/policy-bin/awk" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in /sys/fs/cgroup/*|//sys/fs/cgroup/*|/proc/meminfo|//proc/meminfo) echo forbidden-host-read >&2; exit 97 ;; esac
done
exec "$REAL_AWK" "\$@"
SHIM
chmod +x "$TMP/policy-bin/cat" "$TMP/policy-bin/awk"
eval "$(sed -n '/^modern_envelope_required() {/,/^modern_envelope_budget() {/p' "$VERIFY" | sed '$d')"
sed -n '/^IS_MODERN_ENVELOPE=0$/,/modern finite host envelope detected/p' "$VERIFY" | sed '$d' > "$TMP/selector.sh"
echo fi >> "$TMP/selector.sh"
sed -n '/^PSI_OK=0$/,/^# (4) Physical-host RAM envelope/p' "$VERIFY" > "$TMP/gate3.sh"
MODERN_WRAPPER="$TMP/absent-codex-wrapper"
daemon_in_vm() { return 1; }
source "$TMP/selector.sh"
[ "$IS_MODERN_ENVELOPE" = 1 ] || fail "native Linux without wrapper fell through to legacy policy"
(source "$TMP/gate3.sh") >"$TMP/gate3.log" 2>&1   || fail "native Gate 8 (3) rejected hermetic rollback-10 fixture: $(cat "$TMP/gate3.log")"
grep -q 'Release 1 finite host caps' "$TMP/gate3.log"   || fail "native Gate 8 (3) did not use canonical assertion"
# The composed native host-docker branch must also require oomctl to monitor
# /actions.slice. Restore the production helpers (an earlier fixture stubbed
# host_docker_requires_actions_oomctl) and feed oomctl output from a stub.
eval "$(sed -n '/^host_docker_requires_actions_oomctl() {/,/^}/p' "$VERIFY")"
eval "$(sed -n '/^oomctl_lists_actions_slice() {/,/^}/p' "$VERIFY")"
mkdir -p "$TMP/oomctl-bin"
printf '#!/usr/bin/env bash\ncat "$OOMCTL_FIXTURE"\n' > "$TMP/oomctl-bin/oomctl"
chmod +x "$TMP/oomctl-bin/oomctl"
(DOCKER_CONTAINMENT_MODE=host-docker OOMCTL_FIXTURE="$TMP/oomctl-enrolled.txt" PATH="$TMP/oomctl-bin:$PATH"; export OOMCTL_FIXTURE; source "$TMP/gate3.sh") \
  >"$TMP/gate3-oomctl.log" 2>&1 || fail "native host-docker Gate 8 (3) rejected oomctl listing /actions.slice: $(cat "$TMP/gate3-oomctl.log")"
grep -q 'oomctl monitors /actions.slice' "$TMP/gate3-oomctl.log" \
  || fail "native host-docker Gate 8 (3) did not report the oomctl proof: $(cat "$TMP/gate3-oomctl.log")"
for oomctl_fixture in oomctl-empty oomctl-none; do
  if (DOCKER_CONTAINMENT_MODE=host-docker OOMCTL_FIXTURE="$TMP/$oomctl_fixture.txt" PATH="$TMP/oomctl-bin:$PATH"; export OOMCTL_FIXTURE; source "$TMP/gate3.sh") \
      >"$TMP/gate3-$oomctl_fixture.log" 2>&1; then
    fail "native host-docker Gate 8 (3) accepted $oomctl_fixture without /actions.slice under memory pressure"
  fi
  grep -q 'requires oomctl to list /actions.slice' "$TMP/gate3-$oomctl_fixture.log" \
    || fail "native host-docker Gate 8 (3) $oomctl_fixture failed for the wrong reason: $(cat "$TMP/gate3-$oomctl_fixture.log")"
done
printf 'max\n' > "$FIXTURE/sys/fs/cgroup/actions.slice/memory.max"
if (source "$TMP/selector.sh"; source "$TMP/gate3.sh") >"$TMP/gate3-poison.log" 2>&1; then
  fail "native Gate 8 (3) ignored poisoned fixture cgroup"
fi
printf '30064771072\n' > "$FIXTURE/sys/fs/cgroup/actions.slice/memory.max"
write_props 8589934592 10737418240 > "$TMP/props"
if (source "$TMP/selector.sh"; source "$TMP/gate3.sh") >"$TMP/gate3-bad.log" 2>&1; then
  fail "native Gate 8 (3) bypassed canonical live-cap failure"
fi
write_props 4831838208 5368709120 > "$TMP/props"
sed -i.bak 's/^user.slice ManagedOOMMemoryPressure auto$/user.slice ManagedOOMMemoryPressure kill/' "$TMP/props"
if (source "$TMP/selector.sh"; source "$TMP/gate3.sh") >"$TMP/gate3-kill.log" 2>&1; then
  fail "native selector without wrapper accepted forbidden kill scope"
fi
write_props 4831838208 5368709120 > "$TMP/props"
export FIXTURE_TIMER_ACTIVE=active FIXTURE_TIMER_ENABLED=enabled
if (source "$TMP/selector.sh"; source "$TMP/gate3.sh") >"$TMP/gate3-timer.log" 2>&1; then
  fail "native selector without wrapper accepted retired timer"
fi
unset FIXTURE_TIMER_ACTIVE FIXTURE_TIMER_ENABLED
daemon_in_vm() { return 0; }
source "$TMP/selector.sh"
[ "$IS_MODERN_ENVELOPE" = 0 ] || fail "legacy VM selector changed without modern artifacts"
echo "VERIFY_EXIT_GATE8_POLICY_TEST: PASS"

# Gate 8 retires both agent-scope-reaper and the PSI watcher. Neither may be
# enabled or still active after its unit file was removed.
mkdir -p "$TMP/timerbin"
cat > "$TMP/timerbin/systemctl" <<'EOF2'
#!/usr/bin/env bash
# stub: is-enabled and is-active have independent fixture states.
[ "${1:-}" = "--user" ] && shift
case "${1:-}" in
  is-enabled)
    if [ -n "${STUB_SYSTEMCTL_BROKEN:-}" ]; then
      echo "${STUB_BROKEN_MSG:-Failed to connect to bus: No medium found}" >&2; exit 1
    fi
    for t in ${STUB_ENABLED_TIMERS:-}; do [ "$t" = "${2:-}" ] && { echo enabled; exit 0; }; done
    if [ -n "${STUB_NOTFOUND:-}" ]; then echo not-found; exit 4; fi
    if [ -n "${STUB_ABSENT:-}" ]; then
      echo "Failed to get unit file state for ${2:-}: No such file or directory" >&2; exit 1
    fi
    echo disabled; exit 1 ;;
  is-active)
    if [ "${2:-}" = systemd-oomd ]; then echo inactive; exit 3; fi
    if [ -n "${STUB_ACTIVE_BROKEN:-}" ]; then
      echo "${STUB_ACTIVE_BROKEN_MSG:-Failed to connect to bus: No medium found}" >&2; exit 1
    fi
    for t in ${STUB_ACTIVE_TIMERS:-}; do [ "$t" = "${2:-}" ] && { echo active; exit 0; }; done
    echo inactive; exit 3 ;;
esac
exit 1
EOF2
chmod +x "$TMP/timerbin/systemctl"

# Exercise the real Linux Gate 8 pre-envelope block with no modern-envelope
# files. The helper-only cases below are insufficient: this proves the actual
# branch calls the policy before optional local-envelope detection.
run_gate8_timer_fixture_pre_envelope() {
  local gate_header modern_start gate_start timer_start timer_end original_fail
  gate_header=$(grep -n '^echo "--- Checking Gate 8: VM/AO/MCP containment ---"$' "$VERIFY" | cut -d: -f1)
  modern_start=$(grep -n '^IS_MODERN_ENVELOPE=0$' "$VERIFY" | cut -d: -f1)
  gate_start=$(awk -v min="$gate_header" -v max="$modern_start" \
    'NR >= min && NR < max && /^if \[ "\$\(uname -s\)" = "Linux" \]; then$/ { print NR; exit }' "$VERIFY")
  timer_start=$(grep -n '^verify_retired_timer() {' "$VERIFY" | cut -d: -f1)
  timer_end=$(awk -v start="$timer_start" 'NR > start && /^}$/ { print NR; exit }' "$VERIFY")
  [ -n "$gate_start" ] && [ -n "$timer_start" ] && [ -n "$timer_end" ] \
    || fail "could not extract Gate 8 Linux pre-envelope timer policy"

  original_fail=$(declare -f fail)
  GATE8_POLICY_FAILURE=""
  CONFIG_FILE="$TMP/valid.toml"
  fail() { GATE8_POLICY_FAILURE="$*"; }
  uname() { echo Linux; }
  verify_platform_actions_slice() { return 0; }
  containment_in_vm() { return 1; }
  verify_managed_runners_in_actions_slice() { return 0; }
  eval "$(sed -n "${timer_start},${timer_end}p" "$VERIFY")"
  verify_modern_timers() {
    verify_retired_timer agent-scope-reaper.timer || return 1
    verify_retired_timer psi-oom-watcher.timer
  }
  eval "$(sed -n "${gate_start},$((modern_start - 1))p" "$VERIFY")"
  GATE8_POLICY_RESULT="$GATE8_POLICY_FAILURE"
  eval "$original_fail"
}

PATH="$TMP/timerbin:$PATH"
unset STUB_NOTFOUND STUB_ABSENT STUB_SYSTEMCTL_BROKEN STUB_BROKEN_MSG
STUB_ENABLED_TIMERS="psi-oom-watcher.timer"
STUB_ACTIVE_TIMERS=""
export STUB_ENABLED_TIMERS
run_gate8_timer_fixture_pre_envelope
[ -n "$GATE8_POLICY_RESULT" ] \
  || fail "enabled PSI timer must fail through Gate 8 before optional envelope detection"
grep -Fq 'psi-oom-watcher.timer' <<<"$GATE8_POLICY_RESULT" \
  || fail "pre-envelope timer failure omitted diagnostic: $GATE8_POLICY_RESULT"
STUB_ENABLED_TIMERS=""
run_gate8_timer_fixture_pre_envelope
[ -z "$GATE8_POLICY_RESULT" ] \
  || fail "disabled PSI timer must pass through Gate 8 before optional envelope detection: $GATE8_POLICY_RESULT"
STUB_ABSENT=1
export STUB_ABSENT
run_gate8_timer_fixture_pre_envelope
[ -z "$GATE8_POLICY_RESULT" ] \
  || fail "absent PSI timer must pass through Gate 8 before optional envelope detection: $GATE8_POLICY_RESULT"
unset STUB_ABSENT

# Execute the real later Gate 8 PSI-admission branch with oomd inactive. Its
# failure must require an enrolled systemd-oomd cgroup only; the retired timer
# must never be offered as a fallback.
run_gate8_psi_admission() {
  local psi_start psi_end original_fail
  psi_start=$(grep -n '^# (3) PSI admission check' "$VERIFY" | cut -d: -f1)
  psi_end=$(grep -n '^# (4) Physical-host RAM envelope' "$VERIFY" | cut -d: -f1)
  [ -n "$psi_start" ] && [ -n "$psi_end" ] \
    || fail "could not extract the later Gate 8 PSI-admission branch"
  original_fail=$(declare -f fail)
  GATE8_PSI_FAILURE=""
  fail() { GATE8_PSI_FAILURE="$*"; }
  uname() { echo Linux; }
  # Legacy (non-modern-envelope) path: only an enrolled oomd cgroup may pass.
  IS_MODERN_ENVELOPE=0
  eval "$(sed -n "${psi_start},$((psi_end - 1))p" "$VERIFY")"
  GATE8_PSI_RESULT="$GATE8_PSI_FAILURE"
  eval "$original_fail"
}

STUB_ENABLED_TIMERS=""
STUB_ACTIVE_TIMERS=""
unset STUB_ABSENT STUB_NOTFOUND STUB_SYSTEMCTL_BROKEN STUB_ACTIVE_BROKEN
run_gate8_psi_admission
[ -n "$GATE8_PSI_RESULT" ] \
  || fail "unenrolled oomd must fail the later Gate 8 PSI-admission branch"
grep -Fq 'ManagedOOMMemoryPressure=kill' <<<"$GATE8_PSI_RESULT" \
  || fail "later Gate 8 PSI failure omitted enrolled-oomd remediation: $GATE8_PSI_RESULT"
! grep -Fq 'psi-oom-watcher' <<<"$GATE8_PSI_RESULT" \
  || fail "later Gate 8 PSI failure still offers the retired timer: $GATE8_PSI_RESULT"

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
# Disabled at boot is insufficient: an already-active timer can still launch
# the retired watcher, so this must fail through the same helper.
timers_rc=0
timers_out=$(PATH="$TMP/timerbin:$PATH" STUB_ENABLED_TIMERS="" STUB_ACTIVE_TIMERS="psi-oom-watcher.timer" \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" 2>&1) || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "disabled-but-active psi timer must fail Gate 8"
grep -Fq 'active' <<<"$timers_out" \
  || fail "disabled-but-active timer failure omitted runtime state: $timers_out"
# A broken user manager (query failure, not a known disabled/absent state)
# must fail closed rather than read as "timer disabled".
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_SYSTEMCTL_BROKEN=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "systemctl query failure must fail Gate 8 closed"
# A runtime-state query failure after `is-enabled` says disabled must also
# fail closed rather than treating the timer as stopped.
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_ACTIVE_BROKEN=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "active-state query failure must fail Gate 8 closed"
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
# A deleted unit file does not prove the previously loaded timer has stopped.
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_ABSENT=1 STUB_ACTIVE_TIMERS="psi-oom-watcher.timer" \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "absent-file but active psi timer must fail Gate 8"
# Likewise, a missing unit file must not bypass a failed runtime-state query.
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_ABSENT=1 STUB_ACTIVE_BROKEN=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "absent-file runtime-state query failure must fail Gate 8 closed"
# The deleted reaper has the same lifecycle requirement: an absent file does
# not establish that an already-loaded timer has stopped.
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_ABSENT=1 STUB_ACTIVE_TIMERS="agent-scope-reaper.timer" \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "absent-file but active reaper timer must fail Gate 8"
timers_rc=0
PATH="$TMP/timerbin:$PATH" STUB_ABSENT=1 STUB_ACTIVE_BROKEN=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || timers_rc=$?
[ "$timers_rc" -ne 0 ] || fail "absent-file reaper timer query failure must fail Gate 8 closed"
# systemd 255 prints exactly "not-found" (exit 4) for an absent unit, the
# normal state once install.sh has deleted the watcher unit files.
PATH="$TMP/timerbin:$PATH" STUB_NOTFOUND=1 \
  VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=modern_timers \
  bash "$VERIFY" >/dev/null 2>&1 || fail "systemd not-found (exit 4) for absent timer must pass"

echo "VERIFY_EXIT_GATE8_TEST: PASS"
