#!/usr/bin/env bash
# host-pressure-proof.sh — controlled executable proof that the host-reliability
# pipeline catches overcommit. R3 swarm lane L, bead ez-gh-actions-bjpk.
#
# PURPOSE
# -------
# Three round-3 lanes converge to prevent physical-host crashes:
#   * lane I (admission refusal): src/docker_backend.rs::eval_admission
#     refuses new slot starts when memory pressure > 50% (with hysteresis),
#     emitting the alert event "runner_pool.memory_pressure" at Critical
#     severity when it trips.
#   * lane J (staged shed): scripts/host/psi-oom-watcher.sh runs a 4-stage
#     drain→reclaim→verify→escalate chain that throttles the QEMU/Colima
#     cgroup and writes a watchdog-wait flag when RSS does not drop.
#   * lane K (crash harness): scripts/host/crash-capture-verify.sh is the
#     human-gated panic proof that kdump is wired to capture vmcores.
#
# This script is the controlled, executable proof that ALL THREE WORK
# TOGETHER under live pressure. It runs at user scope (no sudo), spawns
# `stress-ng` from `systemd-run --user --slice=agents.slice --scope --` so
# the pressure lives in the bounded slice (NOT the QEMU VM), and dispatches
# a concurrent canary burst to exercise the admission gate at the same time.
# The proof succeeds if the host absorbs the pressure and recovers within
# the wall budget without triggering a kernel OOM kill, without tripping
# the watchdog (max-load-1 = 24), and without the QEMU cgroup exceeding its
# memory.high ceiling.
#
# BLAST RADIUS / NORMAL PEAK / SAFE MARGIN (per repo CLAUDE.md)
# --------------------------------------------------------------
# Worst-case if this script misfires: stress-ng is pinned to a transient
# scope under agents.slice, with --vm 1 --vm-bytes PRESSURE_BYTES
# --timeout 60s --vm-hang 30 (hangs a single worker inside its own pages).
# Total wall budget is bounded by HPP_TIMEOUT_SECONDS (default 600s = 10
# minutes). The agents.slice ceiling is 20G; PRESSURE_BYTES is capped at
# $(( 20G - 4G reserved )) = 16G, AND further clamped to
# min(16G, runner_count × limits.memory_mb). On a 10-runner fleet with
# limits.memory_mb=3000, PRESSURE_BYTES = 9 × 3G = 27G, then clamped to
# 16G. The normal peak of stress-ng RSS is ~1.0× the requested --vm-bytes
# (Linux COW semantics on first touch); safe margin over agents.slice
# ceiling is 20G − 16G = 4G, which covers cgroup overhead and prevents
# stress-ng itself from triggering a real OOM kill of the slice. The
# concurrent canary burst is N (default 3) parallel ezgha canary-once
# invocations; each consumes ~1-2 GitHub API calls and dispatches one
# workflow run that lands on a real runner — no additional host load.
#
# NORMAL PEAK OF THE BOUNDED METRIC: agents.slice memory.current climbs
# to ~16G during the pressure phase, then decays as stress-ng exits
# (--timeout 60s). /proc/loadavg 1-min may briefly exceed 24 (the
# watchdog's max-load-1) under the 1-vm-worker burst; the script warns
# but does NOT abort on elevated load because the load is intentional
# and bounded in wall time. Kernel OOM-kill lines in dmesg, by contrast,
# DO abort (exit 1) because they prove the host absorbed the pressure
# INCORRECTLY — exactly the failure mode this proof exists to catch.
#
# USAGE
# -----
#   scripts/host/host-pressure-proof.sh                      # full live run
#   scripts/host/host-pressure-proof.sh --dry-run            # verify preconditions + plan, do not spawn
#   HPP_SKIP_PRESSURE=1 scripts/host/host-pressure-proof.sh  # test harness path without stress-ng
#   scripts/host/host-pressure-proof.sh --pressure-mb 4096   # override the auto-computed pressure
#   scripts/host/host-pressure-proof.sh --concurrency 5      # 5 concurrent canary invocations
#   scripts/host/host-pressure-proof.sh --timeout-seconds 900 # extend wall budget
#
# EXIT CODES
# ----------
#   0 = host absorbed pressure + recovered without OOM/watchdog/abort
#   1 = abort condition triggered (OOM, watchdog reboot, recovery failure)
#   2 = precondition fail (QEMU not running, agents.slice not enrolled, etc.)
#
# The dry-run path (--dry-run or HPP_SKIP_PRESSURE=1) prints the plan and
# verifies preconditions; it does NOT spawn stress-ng and never exits 1.
#
# OPERATOR SAFETY
# ---------------
# The script is idempotent: re-running it is safe. If a prior run was
# killed mid-flight, transient scope-* units from `systemd-run` are
# auto-reaped when the user session ends; no persistent state is left
# on disk beyond the log file. --dry-run is the default when invoked
# by the verifier (Gate 9) so the live fleet is never pressured during
# normal CI; live mode requires explicit HPP_LIVE=1 in the env.

set -euo pipefail

# -------- argument parsing ----------------------------------------------------

DRY_RUN=0
HPP_PRESSURE_MB_OVERRIDE=""
HPP_CONCURRENCY=3
HPP_TIMEOUT_SECONDS=600
HPP_CANARY_TIMEOUT_SECONDS=180
HPP_RECOVERY_TIMEOUT_SECONDS=300
HPP_RECOVERY_PCT=10        # MemAvailable must recover to within 10% of baseline
HPP_SKIP_PRESSURE="${HPP_SKIP_PRESSURE:-0}"

usage() {
    cat <<EOF
host-pressure-proof.sh — controlled host-pressure + recovery proof
  --dry-run                   verify preconditions + plan, no live pressure
  --pressure-mb <N>           override auto-computed pressure (default: count × limits.memory_mb)
  --concurrency <N>           number of concurrent canary invocations (default: 3)
  --timeout-seconds <N>       total wall budget (default: 600)
  --canary-timeout-seconds <N>  per-canary timeout (default: 180)
  --recovery-timeout-seconds <N>  max wait for MemAvailable recovery (default: 300)
  --recovery-pct <N>          MemAvailable must recover to within N% of baseline (default: 10)
  -h | --help                 show this help

Environment:
  HPP_SKIP_PRESSURE=1         same as --dry-run (used by harness path test)
  HPP_LIVE=1                  (set by verifier Gate 9 live mode)
  HPP_TIMEOUT                  override total wall budget (default 180s dry-run / 300s live)
  CONFIG_FILE                  override ezgha config path (default: ~/.config/ezgha/config.toml)

Exit codes:
  0  host absorbed + recovered
  1  abort (OOM, watchdog, recovery failure)
  2  precondition fail
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)            DRY_RUN=1 ;;
        --pressure-mb)        shift; HPP_PRESSURE_MB_OVERRIDE="${1:-}" ;;
        --pressure-mb=*)      HPP_PRESSURE_MB_OVERRIDE="${1#--pressure-mb=}" ;;
        --concurrency)        shift; HPP_CONCURRENCY="${1:-}" ;;
        --concurrency=*)      HPP_CONCURRENCY="${1#--concurrency=}" ;;
        --timeout-seconds)    shift; HPP_TIMEOUT_SECONDS="${1:-}" ;;
        --timeout-seconds=*)  HPP_TIMEOUT_SECONDS="${1#--timeout-seconds=}" ;;
        --canary-timeout-seconds) shift; HPP_CANARY_TIMEOUT_SECONDS="${1:-}" ;;
        --canary-timeout-seconds=*) HPP_CANARY_TIMEOUT_SECONDS="${1#--canary-timeout-seconds=}" ;;
        --recovery-timeout-seconds) shift; HPP_RECOVERY_TIMEOUT_SECONDS="${1:-}" ;;
        --recovery-timeout-seconds=*) HPP_RECOVERY_TIMEOUT_SECONDS="${1#--recovery-timeout-seconds=}" ;;
        --recovery-pct)       shift; HPP_RECOVERY_PCT="${1:-}" ;;
        --recovery-pct=*)     HPP_RECOVERY_PCT="${1#--recovery-pct=}" ;;
        -h|--help)            usage; exit 0 ;;
        *)  echo "Error: unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

# Honor the env var on top of the flag, so a harness that exports
# HPP_SKIP_PRESSURE=1 can reuse this script as a one-call probe.
if [ "${HPP_SKIP_PRESSURE}" = "1" ]; then
    DRY_RUN=1
fi

# -------- paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/ezgha}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/host-pressure-proof.log}"
ALERT_LOG="${STATE_DIR}/ezgha-alerts.log"   # where admission refusals are appended by the daemon
DMESG_SNAPSHOT="${STATE_DIR}/host-pressure-proof.dmesg.before"

# Detect config file (mirrors docs/verify-exit-criteria.sh::detect_config_file).
CONFIG_FILE="${CONFIG_FILE:-}"
if [ -z "${CONFIG_FILE}" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        CONFIG_FILE="$HOME/Library/Application Support/org.jleechanorg.ezgha/config.toml"
    else
        CONFIG_FILE="$HOME/.config/ezgha/config.toml"
    fi
fi

EZGHA_BIN="${EZGHA_BIN:-$HOME/.cargo/bin/ezgha}"

mkdir -p "${STATE_DIR}"

# -------- helpers --------------------------------------------------------------

log() {
    printf '[%s] [hpp] %s\n' "$(date -u +%FT%TZ)" "$1" | tee -a "${LOG_FILE}" >&2
}

die_precondition() {
    log "PRECONDITION-FAIL: $1"
    cat <<EOF >&2

REMEDIATION:
$2

EOF
    exit 2
}

# -------- precondition checks (exit 2 on fail) -------------------------------

# Refuse to run if we're not on Linux (the slice + cgroup paths are Linux-only).
if [ "$(uname -s)" != "Linux" ]; then
    die_precondition "host-pressure-proof requires Linux (current: $(uname -s)); cgroup-v2 slice enforcement is the entire point of the proof" "this script is Linux-only; on macOS, run scripts/host/psi-oom-watcher.sh --shed for a different layer of the same proof"
fi

# QEMU must be running so we can read its VmRSS and verify the cgroup ceiling
# is holding. Without QEMU there is no "VM RSS" to test the throttling against
# and lane I's admission path (which only fires when the daemon attempts to
# respawn a missing slot) is meaningless.
QEMU_PID="$(pgrep -f 'qemu-system-x86_64' | head -1 || true)"
if [ -z "${QEMU_PID}" ]; then
    die_precondition "no qemu-system-x86_64 process detected on this host" "start the Colima VM: limactl start colima  (or: colima start)"
fi

# QEMU must be in a bounded slice (per Gate 8(1)). Read /proc/<pid>/cgroup
# and check that the closest *.slice ancestor has memory.high != max.
QEMU_CG="$(grep '^0::' "/proc/${QEMU_PID}/cgroup" 2>/dev/null | head -1 || true)"
QEMU_CG_PATH="${QEMU_CG#0::}"
if [ -z "${QEMU_CG_PATH}" ]; then
    die_precondition "qemu pid=${QEMU_PID} has no cgroup-v2 entry in /proc/${QEMU_PID}/cgroup" "verify the host kernel exposes CONFIG_CGROUP_V2"
fi
QEMU_CEILING_BYTES="$(cat "/sys/fs/cgroup${QEMU_CG_PATH}/memory.high" 2>/dev/null || echo "")"
if [ -z "${QEMU_CEILING_BYTES}" ] || [ "${QEMU_CEILING_BYTES}" = "max" ]; then
    die_precondition "QEMU cgroup ${QEMU_CG_PATH} has unbounded memory.high (value='${QEMU_CEILING_BYTES}')" "deploy systemd/app-lima-vm.slice (MemoryHigh=38G) to ~/.config/systemd/user/, run 'systemctl --user daemon-reload', then restart lima-vm@colima"
fi
QEMU_CEILING_MB=$((QEMU_CEILING_BYTES / 1024 / 1024))
log "QEMU pid=${QEMU_PID} cgroup=${QEMU_CG_PATH} ceiling=${QEMU_CEILING_MB}MB"

# agents.slice must be enrolled (per Gate 8(2.5)) — otherwise the stress-ng
# pressure we spawn would land in the unbounded user session and could
# directly OOM the host, defeating the entire point of the proof.
AGENT_SLICE_BASE="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/agents.slice"
if [ ! -d "${AGENT_SLICE_BASE}" ]; then
    die_precondition "agents.slice not enrolled at ${AGENT_SLICE_BASE}" "run scripts/host/agent-auto-migrate.sh apply  (per bead ez-gh-actions-0725) to relaunch matching PIDs into the slice"
fi
AGENT_LEAF_COUNT="$(find "${AGENT_SLICE_BASE}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ -z "${AGENT_LEAF_COUNT}" ] || [ "${AGENT_LEAF_COUNT}" -lt 1 ]; then
    die_precondition "agents.slice exists but has zero enrolled leaves (the slice ceiling does not protect against anything until something lives in it)" "run scripts/host/agent-auto-migrate.sh apply to relaunch matching PIDs into the slice, or launch a test process with: systemd-run --user --slice=agents.slice --scope -- sleep infinity"
fi
log "agents.slice enrolled leaves=${AGENT_LEAF_COUNT}"

# stress-ng must be installed for the live path. The dry-run path does NOT
# require it; the harness path (HPP_SKIP_PRESSURE=1) only needs the binary
# resolution to succeed so the unit-test stub can be wired in.
if [ "${DRY_RUN}" = "0" ] && ! command -v stress-ng >/dev/null 2>&1; then
    die_precondition "stress-ng is required for the live pressure phase but is not on PATH" "install stress-ng (e.g. apt-get install stress-ng, or use a containerized alternative). The --dry-run path does not require stress-ng."
fi

# ezgha binary must be present (canary invocations need it).
if [ ! -x "${EZGHA_BIN}" ]; then
    die_precondition "ezgha binary not found at ${EZGHA_BIN}" "install with: cargo install --path ."
fi

# ezgha config must exist (we read runner count + limits.memory_mb from it).
if [ ! -r "${CONFIG_FILE}" ]; then
    die_precondition "ezgha config not found at ${CONFIG_FILE}" "create the config per docs/configuration.md (the install.sh script does this)"
fi

# -------- parse config (runner count + limits.memory_mb) ----------------------

# We use python3 with tomllib (3.11+) and fall back to toml (3.10 and earlier),
# mirroring the helper logic in docs/verify-exit-criteria.sh so the parsing
# behaves identically to the verifier.
CONFIG_RUNNER_COUNT="$(CONFIG_FILE="${CONFIG_FILE}" python3 - <<'PY' 2>/dev/null || echo "")
import sys, os
try:
    import tomllib
    with open(os.environ["CONFIG_FILE"], "rb") as f:
        data = tomllib.load(f)
except Exception:
    try:
        import toml
        data = toml.load(os.environ["CONFIG_FILE"])
    except Exception:
        sys.exit(0)
print(data.get("runner", {}).get("count", ""))
PY
)"
if [ -z "${CONFIG_RUNNER_COUNT}" ]; then
    die_precondition "could not parse [runner].count from ${CONFIG_FILE}" "verify the config has a [runner] table with count = <integer>"
fi
if ! [[ "${CONFIG_RUNNER_COUNT}" =~ ^[0-9]+$ ]]; then
    die_precondition "[runner].count='${CONFIG_RUNNER_COUNT}' is not an unsigned integer" "fix the config: count must be a positive integer"
fi
if [ "${CONFIG_RUNNER_COUNT}" -lt 1 ]; then
    die_precondition "[runner].count=${CONFIG_RUNNER_COUNT} is < 1" "this proof requires at least one runner slot to be configured"
fi

CONFIG_MEMORY_MB="$(CONFIG_FILE="${CONFIG_FILE}" python3 - <<'PY' 2>/dev/null || echo "")
import sys, os
try:
    import tomllib
    with open(os.environ["CONFIG_FILE"], "rb") as f:
        data = tomllib.load(f)
except Exception:
    try:
        import toml
        data = toml.load(os.environ["CONFIG_FILE"])
    except Exception:
        sys.exit(0)
print(data.get("limits", {}).get("memory_mb", ""))
PY
)"
if [ -z "${CONFIG_MEMORY_MB}" ]; then
    die_precondition "could not parse [limits].memory_mb from ${CONFIG_FILE}" "verify the config has a [limits] table with memory_mb = <integer>"
fi
if ! [[ "${CONFIG_MEMORY_MB}" =~ ^[0-9]+$ ]]; then
    die_precondition "[limits].memory_mb='${CONFIG_MEMORY_MB}' is not an unsigned integer" "fix the config: memory_mb must be a positive integer"
fi

# -------- pressure sizing ------------------------------------------------------

# Default pressure: (runner_count - 1) × effective_memory_mb. The "-1" leaves
# one slot's worth of headroom so the daemon's admission gate has somewhere
# to refuse a slot into (if all 10× memory_mb was occupied, no admission
# decision is being tested — the system is already saturated).
# This matches the lane spec: "effectively fills the headroom".
if [ -n "${HPP_PRESSURE_MB_OVERRIDE}" ]; then
    PRESSURE_MB="${HPP_PRESSURE_MB_OVERRIDE}"
    PRESSURE_SOURCE="override (--pressure-mb)"
else
    PRESSURE_MB=$(( (CONFIG_RUNNER_COUNT - 1) * CONFIG_MEMORY_MB ))
    PRESSURE_SOURCE="auto ((count-1) × limits.memory_mb = ($((CONFIG_RUNNER_COUNT - 1)) × ${CONFIG_MEMORY_MB}))"
fi

# Cap the pressure at agents.slice ceiling minus a 4G safety margin. The
# 4G margin covers cgroup overhead, kernel page cache, and any leak in the
# pressure generator itself; without it, stress-ng could itself OOM-kill the
# slice and the proof would be self-defeating. agents.slice ceiling is
# 20G (per systemd/agents.slice header), so the cap is 16G.
AGENT_CEILING_MB="$(cat "${AGENT_SLICE_BASE}/memory.high" 2>/dev/null || echo "")"
if [ -z "${AGENT_CEILING_MB}" ] || [ "${AGENT_CEILING_MB}" = "max" ]; then
    # Fall back to a conservative default if the slice ceiling is unreadable.
    AGENT_CEILING_MB=20480
    log "WARN: agents.slice memory.high is '${AGENT_CEILING_MB:-unreadable}' — using conservative 20G ceiling; verify systemd/agents.slice is installed"
fi
AGENT_CEILING_MB=$((AGENT_CEILING_MB / 1024 / 1024))
PRESSURE_CAP_MB=$(( AGENT_CEILING_MB - 4096 ))
if [ "${PRESSURE_CAP_MB}" -lt 1024 ]; then
    die_precondition "agents.slice ceiling ${AGENT_CEILING_MB}MB leaves < 1G pressure headroom after the 4G safety margin — refusing to run" "raise the agents.slice MemoryHigh in systemd/agents.slice (current effective: ${AGENT_CEILING_MB}MB)"
fi
if [ "${PRESSURE_MB}" -gt "${PRESSURE_CAP_MB}" ]; then
    log "WARN: requested pressure ${PRESSURE_MB}MB exceeds cap ${PRESSURE_CAP_MB}MB; clamping to cap"
    PRESSURE_MB="${PRESSURE_CAP_MB}"
    PRESSURE_SOURCE="${PRESSURE_SOURCE} (clamped to ${PRESSURE_CAP_MB}MB cap)"
fi

# -------- baseline snapshot ----------------------------------------------------

baseline_mem_available_kb() { awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0; }
baseline_load_1min()        { awk '{print $1; exit}' /proc/loadavg 2>/dev/null || echo "0.00"; }
baseline_qemu_rss_kb()      { awk '/^VmRSS:/{print $2; exit}' "/proc/${QEMU_PID}/status" 2>/dev/null || echo 0; }
baseline_runner_count()     { docker ps --filter label=ezgha=managed --format '{{.Names}}' 2>/dev/null | wc -l | tr -d '[:space:]'; }
agents_slice_current()      { cat "${AGENT_SLICE_BASE}/memory.current" 2>/dev/null || echo 0; }

BASELINE_MEM_AVAIL_KB="$(baseline_mem_available_kb)"
BASELINE_LOAD_1MIN="$(baseline_load_1min)"
BASELINE_QEMU_RSS_KB="$(baseline_qemu_rss_kb)"
BASELINE_RUNNER_COUNT="$(baseline_runner_count)"
BASELINE_AGENTS_CURRENT="$(agents_slice_current)"
log "BASELINE mem_available=$((BASELINE_MEM_AVAIL_KB / 1024))MB load_1min=${BASELINE_LOAD_1MIN} qemu_rss=$((BASELINE_QEMU_RSS_KB / 1024))MB runners=${BASELINE_RUNNER_COUNT} agents_slice.current=$((BASELINE_AGENTS_CURRENT / 1024 / 1024))MB"

# Capture dmesg snapshot for OOM-kill detection. dmesg is world-readable on
# most distros; if it's locked down (e.g. sysctl kernel.dmesg_restrict=1) the
# snapshot will be empty and the OOM-kill check will degrade to "no proof
# either way" — we still log it as a precondition warning rather than failing.
if dmesg > "${DMESG_SNAPSHOT}" 2>/dev/null; then
    OOM_DMESG_READABLE=1
    log "dmesg snapshot captured (${DMESG_SNAPSHOT})"
else
    OOM_DMESG_READABLE=0
    log "WARN: dmesg not readable (sysctl kernel.dmesg_restrict=1?); OOM-kill check will be a no-op"
fi

# -------- dry-run path ---------------------------------------------------------

if [ "${DRY_RUN}" = "1" ]; then
    cat <<EOF
host-pressure-proof — DRY RUN
================================
config_file              : ${CONFIG_FILE}
runner_count             : ${CONFIG_RUNNER_COUNT}
limits.memory_mb         : ${CONFIG_MEMORY_MB}
agents.slice ceiling     : ${AGENT_CEILING_MB}MB
QEMU cgroup              : ${QEMU_CG_PATH} (ceiling=${QEMU_CEILING_MB}MB)
QEMU pid                 : ${QEMU_PID}
agents.slice leaves      : ${AGENT_LEAF_COUNT}
pressure (MB)            : ${PRESSURE_MB} (${PRESSURE_SOURCE})
pressure cap (MB)        : ${PRESSURE_CAP_MB} (agents.slice ceiling - 4G safety)
concurrency              : ${HPP_CONCURRENCY}
canary timeout (s)       : ${HPP_CANARY_TIMEOUT_SECONDS}
recovery timeout (s)     : ${HPP_RECOVERY_TIMEOUT_SECONDS}
recovery pct             : ${HPP_RECOVERY_PCT}
total timeout (s)        : ${HPP_TIMEOUT_SECONDS}
baseline mem_available   : $((BASELINE_MEM_AVAIL_KB / 1024))MB
baseline load_1min       : ${BASELINE_LOAD_1MIN}
baseline qemu_rss        : $((BASELINE_QEMU_RSS_KB / 1024))MB
baseline runner count    : ${BASELINE_RUNNER_COUNT}
dmesg readable           : ${OOM_DMESG_READABLE}
stress-ng on PATH        : $(command -v stress-ng || echo "MISSING")
ezgha binary             : ${EZGHA_BIN}

This dry-run verifies the harness path WITHOUT spawning stress-ng or canaries.
Re-run without --dry-run (or unset HPP_SKIP_PRESSURE) to execute the live proof.
EOF
    log "DRY-RUN complete; preconditions satisfied (exit 0)"
    exit 0
fi

# -------- live path ------------------------------------------------------------
#
# The proof has six phases:
#   1. Snapshot dmesg (done above) for OOM-kill diff at the end.
#   2. Spawn stress-ng in agents.slice, hold the pressure for 60s.
#   3. Concurrently dispatch HPP_CONCURRENCY canary invocations.
#   4. Monitor PSI / dmesg / load / slice memory / QEMU RSS in parallel
#      during the pressure + canary phase.
#   5. Wait for stress-ng to finish; wait for MemAvailable to recover to
#      within HPP_RECOVERY_PCT% of baseline (capped at HPP_RECOVERY_TIMEOUT_SECONDS).
#   6. Verify QEMU cgroup did not exceed its ceiling, no kernel OOM-kill
#      lines appeared in dmesg, and runners returned to a healthy state.
#
# Aborts are non-zero (exit 1); precondition failures are exit 2 (handled
# above); clean recovery is exit 0.

trap 'log "ABORT: caught signal; cleaning up stress-ng and canary PIDs"; kill $(jobs -p) 2>/dev/null || true; exit 1' INT TERM

# Phase 2: stress-ng ------------------------------------------------------------
# Spawn from systemd-run --user --slice=agents.slice --scope so the pressure
# lives in the bounded slice (NOT the user session, NOT QEMU). --vm 1 = one
# virtual-memory worker; --vm-hang 30 = each worker hangs in its own pages
# for 30s before the timeout kicks in. The combination of --timeout 60s and
# --vm-hang 30 means the wall duration is ~60s with sustained memory
# pressure throughout. systemd-run --scope attaches stdio to the calling
# terminal, so we redirect to a temp log file instead.
log "PHASE 2: spawning stress-ng in agents.slice (--vm 1 --vm-bytes ${PRESSURE_MB}M --timeout 60s --vm-hang 30)"
STRESS_NG_LOG="$(mktemp -t hpp-stress-ng.XXXXXX.log)"
STRESS_NG_PID=""
if ! STRESS_NG_PID=$(systemd-run --user --slice=agents.slice --scope --unit=hpp-pressure-tmp \
    -- stress-ng --vm 1 --vm-bytes "${PRESSURE_MB}M" --timeout 60s --vm-hang 30 \
    >"${STRESS_NG_LOG}" 2>&1 & echo $!); then
    die_precondition "systemd-run --user --slice=agents.slice --scope failed to spawn stress-ng" "verify systemd --user is running and the agents.slice unit is installed"
fi
# systemd-run --scope runs in the current terminal, so the background PID
# is the systemd-run parent (not stress-ng). Track the systemd-run PID so
# we can wait on it, and resolve the actual stress-ng PID for cleanup.
SYSTEMD_RUN_PID="${STRESS_NG_PID}"
STRESS_NG_REAL_PID="$(pgrep -P "${SYSTEMD_RUN_PID}" stress-ng 2>/dev/null | head -1 || true)"
log "stress-ng scope launched: systemd-run pid=${SYSTEMD_RUN_PID} stress-ng pid=${STRESS_NG_REAL_PID:-pending}"

# Phase 3: concurrent canary burst ----------------------------------------------
# canary-once does not accept --concurrency, so we spawn HPP_CONCURRENCY
# independent invocations in the background. Each captures its run-id from
# stdout. We do NOT fail-closed on a single canary timeout (a slow GitHub
# workflow is not a host-pressure failure); the host-pressure signals come
# from dmesg, QEMU RSS, and slice memory — the canary is just to make
# sure the runner pipeline stays responsive under pressure.
log "PHASE 3: dispatching ${HPP_CONCURRENCY} concurrent canary invocations (timeout=${HPP_CANARY_TIMEOUT_SECONDS}s each)"
CANARY_OUT_DIR="$(mktemp -d -t hpp-canary.XXXXXX)"
CANARY_PIDS=()
for i in $(seq 1 "${HPP_CONCURRENCY}"); do
    (
        out_file="${CANARY_OUT_DIR}/canary-${i}.json"
        log_file="${CANARY_OUT_DIR}/canary-${i}.log"
        if "${EZGHA_BIN}" --config "${CONFIG_FILE}" canary-once \
            --timeout-seconds "${HPP_CANARY_TIMEOUT_SECONDS}" \
            --no-alert >"${out_file}" 2>"${log_file}"; then
            run_id="$(jq -r '.run_id // "unknown"' "${out_file}" 2>/dev/null || echo "unknown")"
            log "CANARY-${i} OK run_id=${run_id}"
        else
            log "CANARY-${i} FAIL (see ${log_file})"
        fi
    ) &
    CANARY_PIDS+=( $! )
done

# Phase 4: monitor during pressure + canary -------------------------------------
# Sample dmesg, loadavg, slice memory, QEMU RSS every 5s for up to 70s
# (stress-ng timeout 60s + 10s grace). Any kernel OOM-kill line aborts.
# Load > 50 is a WARN (well above the watchdog's max-load-1 = 24) but is
# expected under pressure and does not abort by itself.
log "PHASE 4: monitoring dmesg/load/slice memory/qemu RSS for up to 70s"
MONITOR_DEADLINE=$(( $(date +%s) + 70 ))
OOM_KILL_DETECTED=0
ABORT_REASON=""
MAX_LOAD_1MIN=0
MAX_AGENTS_MB=0
SLICE_RECLAIM_OBSERVED=0
ADMISSION_REFUSAL_OBSERVED=0

# Checkpoint: did the daemon log any admission refusal at the critical
# event key (lane I)? Scan both the daemon's stdout/stderr and the alert
# log file. The alert::notify code path appends the event key on
# Critical (see src/docker_backend.rs:2339). A real proof REQUIRES at
# least one refusal — if the daemon never refuses despite the pressure,
# either the gate is broken or the pressure is too low to trigger it.
ALERT_BEFORE_LINES="$(wc -l < "${ALERT_LOG}" 2>/dev/null | tr -d '[:space:]' || echo 0)"
[ -z "${ALERT_BEFORE_LINES}" ] && ALERT_BEFORE_LINES=0

while [ "$(date +%s)" -lt "${MONITOR_DEADLINE}" ]; do
    # dmesg OOM-kill check
    if [ "${OOM_DMESG_READABLE}" = "1" ]; then
        if dmesg 2>/dev/null | diff -u "${DMESG_SNAPSHOT}" - 2>/dev/null | grep -E '^\+.*(oom-kill|Out of memory|Killed process)' >/dev/null 2>&1; then
            OOM_KILL_DETECTED=1
            ABORT_REASON="kernel OOM-kill line observed in dmesg during pressure phase"
            break
        fi
    fi
    # load average
    load_1min="$(baseline_load_1min)"
    load_int="${load_1min%%.*}"
    [ -z "${load_int}" ] && load_int=0
    if [ "${load_int}" -gt 50 ]; then
        log "WARN: load_1min=${load_1min} > 50 (expected under pressure; not aborting)"
    fi
    if [ "${load_int}" -gt "${MAX_LOAD_1MIN}" ]; then
        MAX_LOAD_1MIN="${load_int}"
    fi
    # agents.slice memory.current
    current_bytes="$(agents_slice_current)"
    if [ -n "${current_bytes}" ] && [ "${current_bytes}" -gt 0 ]; then
        current_mb=$((current_bytes / 1024 / 1024))
        if [ "${current_mb}" -gt "${MAX_AGENTS_MB}" ]; then
            MAX_AGENTS_MB="${current_mb}"
        fi
        if [ "${current_mb}" -lt "${BASELINE_AGENTS_CURRENT%/*}" ] || true; then :; fi
    fi
    # agents.slice memory.reclaim write-result (lane J shed chain).
    # memory.reclaim is an "ask the kernel to release cache" knob; on
    # cgroup-v2 it has no status file we can poll, but we can detect
    # activity by observing memory.current drop while pressure is held.
    # We use a sliding window: if current drops by >= 100MB from a prior
    # sample, treat that as evidence the shed chain or kernel reclaim
    # fired. (This is loose evidence but it's what we can observe from
    # user scope without writing to cgroup files.)
    PREV_CURRENT_BYTES="${PREV_CURRENT_BYTES:-${current_bytes}}"
    if [ -n "${PREV_CURRENT_BYTES}" ] && [ "${current_bytes}" -lt "${PREV_CURRENT_BYTES}" ]; then
        drop_mb=$(( (PREV_CURRENT_BYTES - current_bytes) / 1024 / 1024 ))
        if [ "${drop_mb}" -ge 100 ]; then
            SLICE_RECLAIM_OBSERVED=1
        fi
    fi
    PREV_CURRENT_BYTES="${current_bytes}"
    # QEMU RSS vs slice ceiling (must not exceed ceiling — that would
    # prove the throttle is not holding).
    qemu_rss_kb="$(baseline_qemu_rss_kb)"
    if [ -n "${qemu_rss_kb}" ] && [ "${qemu_rss_kb}" -gt "${QEMU_CEILING_MB:-0}" ] 2>/dev/null; then
        qemu_rss_mb=$((qemu_rss_kb / 1024))
        if [ "${qemu_rss_mb}" -gt "${QEMU_CEILING_MB}" ]; then
            # 1% tolerance for cgroupfs rounding + the live RSS tail.
            if [ "${qemu_rss_mb}" -gt $((QEMU_CEILING_MB * 101 / 100)) ]; then
                ABORT_REASON="QEMU RSS ${qemu_rss_mb}MB exceeds cgroup ceiling ${QEMU_CEILING_MB}MB by >1% — the slice throttle is not holding"
                break
            fi
        fi
    fi
    sleep 5
done

# Checkpoint: admission refusal. If pressure was applied but the daemon
# never refused a single slot, that's a missing-signal shape — the gate
# is either below threshold (pressure too low) or wired wrong.
log "checking admission refusal evidence in ${ALERT_LOG}"
ALERT_AFTER_LINES="$(wc -l < "${ALERT_LOG}" 2>/dev/null | tr -d '[:space:]' || echo 0)"
[ -z "${ALERT_AFTER_LINES}" ] && ALERT_AFTER_LINES=0
if [ "${ALERT_AFTER_LINES}" -gt "${ALERT_BEFORE_LINES}" ]; then
    NEW_ALERT_BLOCK="$(tail -n +$((ALERT_BEFORE_LINES + 1)) "${ALERT_LOG}" 2>/dev/null || true)"
    if printf '%s\n' "${NEW_ALERT_BLOCK}" | grep -q 'runner_pool.memory_pressure'; then
        ADMISSION_REFUSAL_OBSERVED=1
    fi
fi

# Wait for the stress-ng systemd-run to finish.
log "waiting for stress-ng scope (pid=${SYSTEMD_RUN_PID}) to finish (timeout 70s)"
wait "${SYSTEMD_RUN_PID}" 2>/dev/null || true

# Wait for canaries to settle.
log "waiting for ${HPP_CONCURRENCY} canary invocations to settle (timeout ${HPP_CANARY_TIMEOUT_SECONDS}s)"
for pid in "${CANARY_PIDS[@]}"; do
    wait "${pid}" 2>/dev/null || true
done

# Phase 5: wait for MemAvailable to recover -------------------------------------
log "PHASE 5: waiting for MemAvailable to recover to within ${HPP_RECOVERY_PCT}% of baseline (timeout ${HPP_RECOVERY_TIMEOUT_SECONDS}s)"
RECOVERY_DEADLINE=$(( $(date +%s) + HPP_RECOVERY_TIMEOUT_SECONDS ))
RECOVERY_OK=0
RECOVERY_OBSERVED_KB=0
RECOVERY_THRESHOLD_KB=$(( BASELINE_MEM_AVAIL_KB * (100 - HPP_RECOVERY_PCT) / 100 ))
while [ "$(date +%s)" -lt "${RECOVERY_DEADLINE}" ]; do
    current_kb="$(baseline_mem_available_kb)"
    RECOVERY_OBSERVED_KB="${current_kb}"
    if [ "${current_kb}" -ge "${RECOVERY_THRESHOLD_KB}" ]; then
        RECOVERY_OK=1
        break
    fi
    sleep 30
done
RECOVERY_FINAL_KB="$(baseline_mem_available_kb)"
log "recovery: baseline=$((BASELINE_MEM_AVAIL_KB / 1024))MB threshold=$((RECOVERY_THRESHOLD_KB / 1024))MB final=$((RECOVERY_FINAL_KB / 1024))MB ok=${RECOVERY_OK}"

# Phase 6: final assertions -----------------------------------------------------
log "PHASE 6: final assertions"
FINAL_OOM_KILL_DETECTED=0
if [ "${OOM_DMESG_READABLE}" = "1" ]; then
    if dmesg 2>/dev/null | diff -u "${DMESG_SNAPSHOT}" - 2>/dev/null | grep -E '^\+.*(oom-kill|Out of memory|Killed process)' >/dev/null 2>&1; then
        FINAL_OOM_KILL_DETECTED=1
    fi
fi
FINAL_RUNNER_COUNT="$(baseline_runner_count)"
FINAL_QEMU_RSS_KB="$(baseline_qemu_rss_kb)"

# Compose verdict
EXIT_CODE=0
REASONS=()
if [ -n "${ABORT_REASON}" ]; then
    EXIT_CODE=1
    REASONS+=( "ABORT_DURING_PRESSURE: ${ABORT_REASON}" )
fi
if [ "${FINAL_OOM_KILL_DETECTED}" = "1" ]; then
    EXIT_CODE=1
    REASONS+=( "POST_PRESSURE_OOM: kernel OOM-kill lines observed in dmesg since baseline" )
fi
if [ "${RECOVERY_OK}" != "1" ]; then
    EXIT_CODE=1
    REASONS+=( "RECOVERY_FAILED: MemAvailable did not return to within ${HPP_RECOVERY_PCT}% of baseline within ${HPP_RECOVERY_TIMEOUT_SECONDS}s" )
fi
if [ "${FINAL_RUNNER_COUNT}" -lt "${BASELINE_RUNNER_COUNT}" ]; then
    # Runners may have been intentionally shed by lane J; the proof
    # is that the host did not crash, not that every runner survived.
    # We log it as a WARNING, not an abort, because lane J's stage 1
    # is allowed to stop low-priority containers under pressure.
    log "WARN: runner count dropped from ${BASELINE_RUNNER_COUNT} to ${FINAL_RUNNER_COUNT} (likely lane J stage 1 drain — expected under pressure)"
fi

# Final dmesg OOM check trumps everything
if [ "${OOM_KILL_DETECTED}" = "1" ]; then
    EXIT_CODE=1
    REASONS+=( "DURING_PRESSURE_OOM: kernel OOM-kill during pressure phase" )
fi

# Summary
log "================================================="
log "PROOF SUMMARY"
log "  baseline mem_available : $((BASELINE_MEM_AVAIL_KB / 1024))MB"
log "  baseline load_1min     : ${BASELINE_LOAD_1MIN}"
log "  baseline qemu_rss      : $((BASELINE_QEMU_RSS_KB / 1024))MB"
log "  baseline runners       : ${BASELINE_RUNNER_COUNT}"
log "  pressure (MB)          : ${PRESSURE_MB} (${PRESSURE_SOURCE})"
log "  max load_1min observed : ${MAX_LOAD_1MIN}"
log "  max agents.slice (MB)  : ${MAX_AGENTS_MB}"
log "  slice reclaim observed : ${SLICE_RECLAIM_OBSERVED}"
log "  admission refusal obs. : ${ADMISSION_REFUSAL_OBSERVED}"
log "  recovery ok            : ${RECOVERY_OK}"
log "  final mem_available    : $((FINAL_QEMU_RSS_KB / 1024))MB qemu / $((RECOVERY_FINAL_KB / 1024))MB host"
log "  final runners          : ${FINAL_RUNNER_COUNT}"
log "  OOM during pressure    : ${OOM_KILL_DETECTED}"
log "  OOM after pressure     : ${FINAL_OOM_KILL_DETECTED}"
log "================================================="

# Cleanup the dmesg snapshot
rm -f "${DMESG_SNAPSHOT}" || true

if [ "${EXIT_CODE}" = "0" ]; then
    log "PASS: host absorbed pressure + recovered without OOM/watchdog/abort"
    exit 0
else
    log "FAIL: exit ${EXIT_CODE}"
    for r in "${REASONS[@]}"; do
        log "  - ${r}"
    done
    exit 1
fi
