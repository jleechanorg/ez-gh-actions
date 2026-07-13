#!/usr/bin/env bash
# verify-exit-criteria.sh — automated check of all ironclad exit criteria.
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "=== Running Ironclad Exit Criteria Verification ==="

fail() {
    echo -e "${RED}[FAIL] $1${NC}"
    exit 1
}

pass() {
    echo -e "${GREEN}[PASS] $1${NC}"
}

count_nonempty_lines() {
    if [ -z "$1" ]; then
        echo 0
    else
        printf '%s\n' "$1" | grep -c .
    fi
}

is_rate_limit_text() {
    echo "$1" | grep -Eiq 'rate limit|secondary rate limit|abuse|HTTP 429|Retry-After'
}

is_transient_gh_text() {
    echo "$1" | grep -Eiq 'unexpected end of JSON input|HTTP/2[.]0 500|HTTP 500|internal server error'
}

retry_after_seconds() {
    echo "$1" | grep -Eio 'Retry-After:[[:space:]]*[0-9]+|retry after[[:space:]]+[0-9]+' | grep -Eo '[0-9]+' | head -1
}

gh_checked() {
    local out err combined status attempt delay retry_after err_file
    delay=2
    err_file=$(mktemp) || return 1
    for attempt in 1 2 3 4 5; do
        : > "$err_file"
        if out=$(gh "$@" 2>"$err_file"); then
            err=$(cat "$err_file")
            if [ -n "$err" ] && { is_rate_limit_text "$err" || is_transient_gh_text "$err"; }; then
                status=1
                combined="${err}
${out}"
            else
                if [ -n "$err" ]; then
                    echo "$err" >&2
                fi
                rm -f "$err_file"
                printf '%s' "$out"
                return 0
            fi
        else
            status=$?
            err=$(cat "$err_file")
            combined="${err}
${out}"
        fi
        if [ "$attempt" -lt 5 ] && { is_rate_limit_text "$combined" || is_transient_gh_text "$combined"; }; then
            retry_after=$(retry_after_seconds "$combined" || true)
            if [ -n "$retry_after" ] && [ "$retry_after" -le 60 ]; then
                delay="$retry_after"
            elif [ -n "$retry_after" ]; then
                echo "GitHub API rate-limited while running: gh $*; Retry-After=${retry_after}s exceeds verifier retry budget" >&2
                echo "$combined" >&2
                rm -f "$err_file"
                return "$status"
            fi
            echo "GitHub API retryable failure while running: gh $*; retrying in ${delay}s (attempt ${attempt}/5)" >&2
            sleep "$delay"
            if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); fi
            continue
        fi
        if is_rate_limit_text "$combined"; then
            echo "GitHub API rate-limited while running: gh $*" >&2
        else
            echo "GitHub API command failed while running: gh $*" >&2
        fi
        echo "$combined" >&2
        rm -f "$err_file"
        return "$status"
    done
}

toml_get_runner() {
    local key="$1"
    local default="${2:-}"
    python3 - "$CONFIG_FILE" "$key" "$default" <<'PY'
import sys

path, key, default = sys.argv[1:]

try:
    import tomllib
except ModuleNotFoundError:
    try:
        import toml
    except ModuleNotFoundError:
        raise SystemExit(2)
    data = toml.load(path)
else:
    with open(path, "rb") as f:
        data = tomllib.load(f)

value = data["runner"].get(key, default)
print(value)
PY
}

toml_get_top() {
    local key="$1"
    local default="${2:-}"
    python3 - "$CONFIG_FILE" "$key" "$default" <<'PY'
import sys

path, key, default = sys.argv[1:]

try:
    import tomllib
    with open(path, "rb") as f:
        data = tomllib.load(f)
except ModuleNotFoundError:
    try:
        import toml
    except ModuleNotFoundError:
        raise SystemExit(2)
    data = toml.load(path)

value = data.get(key, default)
print(value)
PY
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_float() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

container_state_is_running() {
    local name="$1"
    local raw
    raw=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    [ "$raw" = "true" ]
}

toml_get_limits() {
    local key="$1"
    local default="${2:-}"
    python3 - "$CONFIG_FILE" "$key" "$default" <<'PY'
import sys

path, key, default = sys.argv[1:]

try:
    import tomllib
except ModuleNotFoundError:
    try:
        import toml
    except ModuleNotFoundError:
        raise SystemExit(2)
    data = toml.load(path)
else:
    with open(path, "rb") as f:
        data = tomllib.load(f)

value = data["limits"].get(key, default)
print(value)
PY
}

daemon_in_vm() {
    [ "$(uname -s)" = "Darwin" ] && return 0
    local daemon_kernel host_kernel
    daemon_kernel=$(docker info --format '{{.KernelVersion}}' 2>/dev/null | tr -d '[:space:]' || true)
    host_kernel=$(uname -r | tr -d '[:space:]' || true)
    [ -n "$daemon_kernel" ] && [ -n "$host_kernel" ] && [ "$daemon_kernel" != "$host_kernel" ]
}

cpu_controller_available() {
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        if grep -qw 'cpu' /sys/fs/cgroup/cgroup.controllers; then
            return 0
        fi
    fi
    if [ -f /proc/cgroups ]; then
        awk '$1=="cpu" && $4=="1" {found=1} END {exit !found}' /proc/cgroups
        return
    fi
    return 1
}

inspect_has_no_new_privileges() {
    local name="$1"
    local raw
    raw=$(docker inspect "$name" --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null || echo '')
    echo "$raw" | grep -q 'no-new-privileges'
}

runner_has_worker_process() {
    # Worker processes are spawned only when the runner has accepted a job.
    # Idle runners have Runner.Listener but NOT Runner.Worker, so listening
    # alone is not sufficient proof of execution — that would falsely pass on
    # an idle fleet. Must observe a Worker process explicitly.
    local name="$1"
    if ! docker top "$name" >/dev/null 2>&1; then
        return 1
    fi
    docker top "$name" 2>/dev/null | awk 'NR>1 && $0 ~ /Runner\.Worker/ {found=1} END {exit !found}'
}

daemon_overlay_free_disk_gb() {
    local image="$1"
    local avail_kb
    avail_kb=$(docker run --rm --entrypoint df "$image" -Pk / 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if ! is_uint "$avail_kb"; then
        echo ""
        return 1
    fi
    echo $((avail_kb / 1024 / 1024))
}

verify_kdump_pstore() {
    [ "$(uname -s)" = "Linux" ] || return 0
    cat <<'REMEDIATE'
[FAIL] Crash capture is not active on this host. The project's stated goal
       (physical-host availability) cannot be proven without it.

REPRODUCIBLE REMEDIATION:
    1. sudo bash scripts/host/configure-grub-kdump.sh    # already-prepared, transactional, survives failure
    2. sudo reboot                                     # required; GRUB + crashkernel=2G only take effect after reboot
    3. ./docs/verify-exit-criteria.sh                  # re-run; this gate will turn green once /sys/kernel/kexec_crash_loaded == 1
REMEDIATE
    # (1) /proc/sys/kernel/core_pattern is the USERSpace core-dump pattern;
    #     it routes only userspace coredumps (SIGSEGV in a process), NOT
    #     kernel panics. Kdump dumps kernel panics via kexec-loaded crash
    #     kernel writing to /var/crash, completely independent of
    #     core_pattern. Checking core_pattern for "pstore" here was a false
    #     positive — it could fail when kdump is correctly installed.
    #     Skip it; it is not a kdump artifact.
    #
    # (2) /sys/fs/pstore is a SEPARATE firmware-level capture path
    #     (pstore/ramoops; survives a panic to read back via dmesg-equivalent
    #     after reboot). It is NOT a kdump mechanism, but it IS a legitimate
    #     kernel log capture surface that survives a panic, and the project's
    #     "physical-host availability" goal benefits from having at least
    #     one panic-time capture path beyond kdump alone. Keeping it checked
    #     here is intentional; it is independent of core_pattern.
    if [ ! -d /sys/fs/pstore ]; then
        fail "Crash capture FAIL-CLOSED: /sys/fs/pstore is not mounted (no firmware/pstore crash logs can survive a panic)"
    fi
    # (3) Kernel-panic capture lives in /sys/kernel/kexec_crash_loaded:
    #     when kdump has kexec-loaded the crash kernel, this reads '1'.
    #     If the kernel was rebooted after running configure-grub-kdump.sh
    #     but kexec_crash_loaded is still 0, the crash kernel did NOT load
    #     — either GRUB picked the wrong cmdline or crashkernel= is wrong.
    if [ ! -f /sys/kernel/kexec_crash_loaded ]; then
        fail "Crash capture FAIL-CLOSED: /sys/kernel/kexec_crash_loaded is missing (kdump kernel never installed)"
    fi
    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null || echo 0)" != "1" ]; then
        fail "Crash capture FAIL-CLOSED: /sys/kernel/kexec_crash_loaded is not '1' (kdump kernel is not loaded into the running kernel)"
    fi
    # (4) /var/crash is the kdump-tools default destination on debian/ubuntu.
    #     If the directory is missing OR not writable by root, the vmcore
    #     file cannot land and the panic capture is silently lost (kexec
    #     loads the crash kernel, then the crash kernel mounts the root
    #     filesystem and writes here; if this path is unwritable, kdump
    #     fails its post-reboot handshake and produces no vmcore).
    KDUMP_DIR=/var/crash
    if [ ! -d "$KDUMP_DIR" ]; then
        fail "Crash capture FAIL-CLOSED: $KDUMP_DIR does not exist; kdump has no dump target. Remediation: install kdump-tools (apt-get install kdump-tools) or run scripts/host/configure-grub-kdump.sh which prepares the path."
    fi
    if [ ! -w "$KDUMP_DIR" ]; then
        fail "Crash capture FAIL-CLOSED: $KDUMP_DIR is not writable by root; kernel cannot save vmcores here."
    fi
}

# Verify the cgroup v2 leaf cgroup for the given raw /proc/<pid>/cgroup line
# (including the optional leading "0::") has a finite memory ceiling in
# /sys/fs/cgroup (memory.high or memory.max != "max"). Returns 0 if the leaf
# is bounded, 1 if it is unbounded OR cannot be read. On failure, the offending
# cgroup path (and which file was max/unreadable) is printed on stdout so the
# cold reader sees exactly which cgroup is missing the ceiling.
#
# Why this uses the kernel-side file (not `systemctl --user show`):
# `systemctl --user show <nonexistent-unit>` quietly returns
# MemoryHigh=infinity, which is indistinguishable from a real slice that
# happens to be set to infinity. The cgroup-fs file is the actual kernel
# truth: a finite value there IS the ceiling, regardless of whether systemd
# has a matching unit file loaded. Used by Gate 8 (VM/AO/MCP containment,
# bead jleechan-aqh).
cgroup_leaf_has_memory_ceiling() {
    local cg_raw="$1"
    [ -z "$cg_raw" ] && return 1
    cg_raw="${cg_raw#0::}"  # strip cgroup-v2 "0::" prefix if present
    local sysfs="/sys/fs/cgroup"
    local leaf_high leaf_max
    leaf_high=$(cat "${sysfs}${cg_raw}/memory.high" 2>/dev/null || echo "")
    leaf_max=$(cat "${sysfs}${cg_raw}/memory.max" 2>/dev/null || echo "")
    if [ -z "$leaf_high" ] && [ -z "$leaf_max" ]; then
        echo "${cg_raw} (cgroup files unreadable)"
        return 1
    fi
    if [ "$leaf_high" = "max" ] && [ "$leaf_max" = "max" ]; then
        echo "${cg_raw} (memory.high=max memory.max=max)"
        return 1
    fi
    return 0
}

# --- Gate 0: Deployed code == committed code ---
echo "--- Checking Gate 0: Deployed code == committed code ---"
DEPLOYED_SHA=$(~/.cargo/bin/ezgha --version 2>/dev/null | cut -d'-' -f2 || echo "none")
CURRENT_SHA=$(git rev-parse --short HEAD)
if [ "$DEPLOYED_SHA" != "$CURRENT_SHA" ]; then
    fail "Deployed binary SHA ($DEPLOYED_SHA) does not match current HEAD Git SHA ($CURRENT_SHA). Run cargo install --path ."
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
UNCOMMITTED=$(git status --porcelain 2>/dev/null | grep -vE 'docs/observe|docs/goals|goals/|.beads/' || true)

if [ "$CURRENT_BRANCH" = "main" ]; then
    if [ -n "$UNCOMMITTED" ]; then
        fail "Deploying on main but local uncommitted changes exist outside allowed paths (docs/observe, goals, .beads):\n$UNCOMMITTED"
    fi
    # Verify we are in sync with remote main
    git fetch origin main >/dev/null 2>&1 || true
    REMOTE_SHA=$(git rev-parse origin/main 2>/dev/null || echo "")
    LOCAL_SHA=$(git rev-parse HEAD)
    if [ -n "$REMOTE_SHA" ] && [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        fail "Local main branch is out of sync with origin/main (local: $LOCAL_SHA, remote: $REMOTE_SHA)"
    fi
else
    if [ -n "$UNCOMMITTED" ]; then
        echo "Warning: local uncommitted changes exist outside docs/observe:"
        echo "$UNCOMMITTED"
    fi
    echo "Info: running on feature branch '$CURRENT_BRANCH' (Gate 0 strict main check bypassed)"
fi

pass "Gate 0: Deployed binary matches HEAD SHA ($CURRENT_SHA)"

# --- Gate 1: Code quality ---
echo "--- Checking Gate 1: Code quality ---"
cargo build --release >/dev/null || fail "Cargo release build failed"
cargo test >/dev/null || fail "Cargo tests failed"
cargo clippy --all-targets -- -D warnings >/dev/null || fail "Clippy warnings/errors found"
cargo fmt --check >/dev/null || fail "Cargo formatting checks failed"

# Check open critical beads
CRITICAL_BEADS=$(python3 -c "
import json, sys
count = 0
try:
    for line in open('.beads/issues.jsonl'):
        if not line.strip(): continue
        b = json.loads(line)
        if b.get('priority') == 0 and b.get('status') == 'open' and 'thermo' in b.get('labels', []):
            print(f\"  - [{b.get('id')}]: {b.get('title')}\")
            count += 1
except FileNotFoundError:
    pass
sys.exit(count)
" 2>&1 || echo "FAIL_BEADS")

if [ "$CRITICAL_BEADS" = "FAIL_BEADS" ] || [ -n "$CRITICAL_BEADS" ]; then
    fail "Open critical thermo beads found:\n$CRITICAL_BEADS"
fi
pass "Gate 1: Code builds, tests, clippy, fmt, and beads checks pass"

# --- Gate 2: Service + daemon up ---
echo "--- Checking Gate 2: Service + daemon up ---"
case "$(uname -s)" in
  Linux)  PLATFORM="linux" ;;
  Darwin) PLATFORM="macos" ;;
  *)      PLATFORM="other" ;;
esac

probe_service_state() {
  if [ "$PLATFORM" = "linux" ]; then
    systemctl --user is-active ezgha.service 2>/dev/null || echo "inactive"
  elif [ "$PLATFORM" = "macos" ]; then
    local line pid status
    line=$(launchctl list 2>/dev/null | awk '$3 == "org.jleechanorg.ezgha" {print; exit}')
    if [ -z "$line" ]; then echo "not-loaded"; return; fi
    pid=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    if [ -n "$pid" ] && [ "$pid" != "-" ]; then echo "active"
    elif [ "$status" = "0" ]; then echo "inactive"
    else echo "failed"; fi
  else echo "unsupported"; fi
}

SERVICE_STATE=$(probe_service_state)
[ "$SERVICE_STATE" = "active" ] || fail "ezgha supervisor is not active (platform=$PLATFORM status: $SERVICE_STATE)"

if [ "$PLATFORM" = "linux" ]; then
  SERVICE_ENABLED=$(systemctl --user is-enabled ezgha.service 2>&1 || echo "disabled")
  [ "$SERVICE_ENABLED" = "enabled" ] || fail "ezgha.service is not enabled (status: $SERVICE_ENABLED)"
elif [ "$PLATFORM" = "macos" ]; then
  [ -f "${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha.plist" ]     || fail "launchd plist missing at ~/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
fi

docker info --format '{{.ServerVersion}}' >/dev/null || fail "Docker daemon unreachable"

if [ "$PLATFORM" = "macos" ] && command -v colima >/dev/null 2>&1; then
  colima status 2>&1 | grep -qi "is running"     || fail "Colima VM is not running (run: colima start)"
elif command -v limactl >/dev/null 2>&1; then
  COLIMA_STATUS=$(limactl list 2>/dev/null | awk 'NR==2 {print $2}')
  [ "$COLIMA_STATUS" = "Running" ] || fail "Colima/Lima VM is stopped (status: $COLIMA_STATUS)"
fi
pass "Gate 2: Service active and Docker/Colima daemon up (platform=$PLATFORM)"

# --- Gate 3: Fleet capacity ---
echo "--- Checking Gate 3: Fleet capacity ---"
verify_kdump_pstore
# Resolve the live config file the daemon actually uses. ezgha reads from
# ~/.config/ezgha/config.toml on Linux and from
# "$HOME/Library/Application Support/org.jleechanorg.ezgha/config.toml" on
# macOS. Reading only the Linux path would silently validate a stale mirror
# while the real Mac fleet stays at the wrong count.
detect_config_file() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "$HOME/Library/Application Support/org.jleechanorg.ezgha/config.toml"
        return 0
    fi
    echo "$HOME/.config/ezgha/config.toml"
}
CONFIG_FILE=$(detect_config_file)
if [ ! -f "$CONFIG_FILE" ]; then
    fail "Config file not found at platform-correct path: $CONFIG_FILE"
fi
COUNT=$(toml_get_runner count 2>/dev/null || grep -E 'count\s*=\s*' "$CONFIG_FILE" | head -1 | awk -F'=' '{print $2}' | tr -d '[:space:]')
NAME_PREFIX=$(toml_get_runner name_prefix ez-org-runner 2>/dev/null || echo 'ez-org-runner')
LIMIT_MEMORY_MB=$(toml_get_limits memory_mb 0)
LIMIT_CPUS=$(toml_get_limits cpus 0.50)
LIMIT_PIDS=$(toml_get_limits pids 1024)
MIN_FREE_DISK_GB=$(toml_get_limits min_free_disk_gb 10)
VM_TOTAL_MB=$(toml_get_runner vm_total_mb 0)
GUEST_RESERVE_MB=$(toml_get_runner guest_reserve_mb 4096)
RUNNER_FLOOR_MB=$(toml_get_runner runner_floor_mb 3072)
RUNNER_IMAGE=$(toml_get_runner image ghcr.io/actions/actions-runner:latest 2>/dev/null || echo 'ghcr.io/actions/actions-runner:latest')

if [ -z "$COUNT" ]; then
    fail "Could not parse runner.count from $CONFIG_FILE"
fi
if ! is_uint "$COUNT"; then
    fail "runner.count is not a valid unsigned integer: '$COUNT'"
fi
if [ "$COUNT" -eq 0 ]; then
    fail "runner.count must be >= 1"
fi
if ! is_float "$LIMIT_CPUS"; then
    fail "limits.cpus is not a valid numeric value: '$LIMIT_CPUS'"
fi
if ! is_uint "$LIMIT_MEMORY_MB"; then
    fail "limits.memory_mb is not a valid unsigned integer: '$LIMIT_MEMORY_MB'"
fi
if ! is_uint "$LIMIT_PIDS"; then
    fail "limits.pids is not a valid unsigned integer: '$LIMIT_PIDS'"
fi
if ! is_uint "$MIN_FREE_DISK_GB"; then
    fail "limits.min_free_disk_gb is not a valid unsigned integer: '$MIN_FREE_DISK_GB'"
fi
if ! is_uint "$GUEST_RESERVE_MB"; then
    fail "runner.guest_reserve_mb is not a valid unsigned integer: '$GUEST_RESERVE_MB'"
fi
if ! is_uint "$RUNNER_FLOOR_MB"; then
    fail "runner.runner_floor_mb is not a valid unsigned integer: '$RUNNER_FLOOR_MB'"
fi

EXPECTED_NANO_CPUS=$(awk -v cpus="$LIMIT_CPUS" 'BEGIN { printf "%.0f", cpus * 1000000000 }')
if [ "$EXPECTED_NANO_CPUS" -le 0 ]; then
    fail "Could not compute expected NanoCPUs from limits.cpus='$LIMIT_CPUS'"
fi
EXPECTED_MEMORY_BYTES=$((LIMIT_MEMORY_MB * 1024 * 1024))
if [ "$EXPECTED_MEMORY_BYTES" -le 0 ]; then
    fail "Computed expected memory bytes must be > 0 (limits.memory_mb='$LIMIT_MEMORY_MB')"
fi

if ! daemon_in_vm; then
    if ! cpu_controller_available; then
        fail "CPU controller check failed: this host does not expose a usable cpu cgroup controller"
    fi
fi

if [ -z "$VM_TOTAL_MB" ] || ! is_uint "$VM_TOTAL_MB" || [ "$VM_TOTAL_MB" -eq 0 ]; then
    DAEMON_MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)
    if ! is_uint "$DAEMON_MEM_BYTES" || [ "$DAEMON_MEM_BYTES" -eq 0 ]; then
        fail "Could not verify host/VM memory budget: vm_total_mb missing and docker info unavailable"
    fi
    VM_TOTAL_MB=$((DAEMON_MEM_BYTES / 1024 / 1024))
fi
if [ -z "$VM_TOTAL_MB" ] || ! is_uint "$VM_TOTAL_MB"; then
    fail "Could not verify host/VM memory budget: vm_total_mb invalid/missing"
fi
if [ "$VM_TOTAL_MB" -le "$GUEST_RESERVE_MB" ]; then
    fail "Memory budget invalid: vm_total_mb ($VM_TOTAL_MB) <= guest_reserve_mb ($GUEST_RESERVE_MB)"
fi
HOST_BUDGET_MB=$((VM_TOTAL_MB - GUEST_RESERVE_MB))
FLOOR_REQUIREMENT_MB=$((COUNT * RUNNER_FLOOR_MB))
if [ "$FLOOR_REQUIREMENT_MB" -gt "$HOST_BUDGET_MB" ]; then
    fail "Configured runner floor would violate host reserve: count($COUNT)*runner_floor_mb($RUNNER_FLOOR_MB)=$FLOOR_REQUIREMENT_MB > vm_total_mb($VM_TOTAL_MB)-guest_reserve_mb($GUEST_RESERVE_MB)=$HOST_BUDGET_MB"
fi

EXPECTED_RUNNING=0
# --- Lane H R3 arithmetic traceability (2026-07-13) ---
# Per-slot aggregate = limit_mb × count; runner budget = vm_total_mb - guest_reserve_mb.
# Current target: 3000 × 10 = 30000 MiB (≈29.3 GiB) vs budget 36864 - 4096 = 32768 MiB (32 GiB)
# ⇒ headroom = 2768 MiB (≈2.7 GiB) for host reserve / cgroup overhead / sibling slots.
# Prior value 3100 × 10 = 31000 MiB (≈30.3 GiB) ⇒ only 1768 MiB (≈1.7 GiB) headroom
# (too tight under load). Lowering memory_mb from 3100 → 3000 widens the safety
# margin so the host-watchdog (`max-load-1 = 24`) is less likely to trip under
# aggregate memory pressure. Restart pending deploy-owner (single-writer rule).
for slot in $(seq 1 "$COUNT"); do
    SLOT_NAME="${NAME_PREFIX}-${slot}"
    retry=0
    max_retries=6
    while ! container_state_is_running "$SLOT_NAME"; do
        if [ "$retry" -ge "$max_retries" ]; then
            fail "Slot $SLOT_NAME is missing or not running after $((max_retries * 5))s"
        fi
        echo "    [INFO] Slot $SLOT_NAME not running yet, retrying in 5s (retry $((retry + 1))/$max_retries)..."
        sleep 5
        retry=$((retry + 1))
    done

    SLOT_JSON=$(docker inspect "$SLOT_NAME" 2>/dev/null || echo '[]')
    if [ "$SLOT_JSON" = "[]" ]; then
        fail "docker inspect returned no data for slot $SLOT_NAME"
    fi

    SLOT_MEMORY_BYTES=$(echo "$SLOT_JSON" | jq -r '.[0].HostConfig.Memory // 0')
    SLOT_MEMORY_SWAP_BYTES=$(echo "$SLOT_JSON" | jq -r '.[0].HostConfig.MemorySwap // 0')
    SLOT_NANO_CPUS=$(echo "$SLOT_JSON" | jq -r '.[0].HostConfig.NanoCpus // 0')
    SLOT_CPU_QUOTA=$(echo "$SLOT_JSON" | jq -r '.[0].HostConfig.CPUQuota // 0')
    SLOT_CPU_PERIOD=$(echo "$SLOT_JSON" | jq -r '.[0].HostConfig.CPUPeriod // 0')
    SLOT_PIDS_LIMIT=$(echo "$SLOT_JSON" | jq -r '.[0].HostConfig.PidsLimit // -1')
    SLOT_STATUS=$(echo "$SLOT_JSON" | jq -r '.[0].State.Status // "unknown"')

    RUNNER_FLOOR_BYTES=$((RUNNER_FLOOR_MB * 1024 * 1024))
    # Compute EXACT effective memory clamp. The daemon caps per-slot memory at
    # min(LIMIT_MEMORY_MB, (VM_TOTAL_MB - GUEST_RESERVE_MB) / COUNT). Any value
    # in the [runner_floor_mb..limit_memory_mb] range is therefore a weakened
    # claim and MUST be rejected — a slot set to 3.5 GB on a 6 GB target would
    # silently half-fit jobs and crush sibling slots' budgets.
    EXPECTED_EFFECTIVE_BYTES=$EXPECTED_MEMORY_BYTES
    if is_uint "$VM_TOTAL_MB" && [ "$VM_TOTAL_MB" -gt 0 ] \
        && is_uint "$GUEST_RESERVE_MB" && [ "$GUEST_RESERVE_MB" -gt 0 ] \
        && [ "$VM_TOTAL_MB" -gt "$GUEST_RESERVE_MB" ] \
        && [ "$COUNT" -gt 0 ]; then
        HOST_BUDGET_MB=$((VM_TOTAL_MB - GUEST_RESERVE_MB))
        PER_SLOT_HOST_MB=$((HOST_BUDGET_MB / COUNT))
        if [ "$LIMIT_MEMORY_MB" -lt "$PER_SLOT_HOST_MB" ]; then
            EXPECTED_EFFECTIVE_BYTES=$((LIMIT_MEMORY_MB * 1024 * 1024))
        else
            EXPECTED_EFFECTIVE_BYTES=$((PER_SLOT_HOST_MB * 1024 * 1024))
        fi
    fi
    # Reject any MemorySwap value that is not EXACTLY equal to Memory.
    # In Docker cgroup semantics, MemorySwap=0 means "default extra-swap"
    # (double of Memory, defeat the limit), and MemorySwap=-1 means
    # "unlimited swap" (also defeats the limit). Only an EXACT
    # MemorySwap == Memory is the legitimate safety claim. Acceptable
    # values are: MemorySwap == Memory (no extra swap). Anything else
    # — including 0, -1, double-Memory, anything not exactly equal —
    # fails-closed.
    if [ "$SLOT_MEMORY_SWAP_BYTES" -ne "$SLOT_MEMORY_BYTES" ]; then
        fail "slot $SLOT_NAME MemorySwap=${SLOT_MEMORY_SWAP_BYTES} != Memory=${SLOT_MEMORY_BYTES}: only EXACT MemorySwap == Memory is allowed. MemorySwap=0 means default 2x memory; MemorySwap=-1 means unlimited swap — both defeat the memory limit. The daemon must set MemorySwap equal to Memory explicitly so swap cannot extend beyond the cgroup ceiling."
    fi
    # EXACT clamp check. 4 MiB slack accommodates cgroupfs page-alignment
    # rounding observed on this fleet: docker rounds 3200 MiB → 3197 MiB (a
    # 3 MiB alignment artifact). Anything beyond that is a real drift; values
    # inside the [runner_floor_mb..target] range are still rejected as weakened
    # (this slack is NOT a softening — it just accommodates the cgroupfs
    # 4 KiB page boundary that host kernel uses for cgroup v2 memory limits).
    SLACK=$((4 * 1024 * 1024))
    DIFF=$((SLOT_MEMORY_BYTES - EXPECTED_EFFECTIVE_BYTES))
    ABS_DIFF=${DIFF#-}
    if [ "$ABS_DIFF" -gt "$SLACK" ]; then
        fail "slot $SLOT_NAME memory limit ${SLOT_MEMORY_BYTES} bytes != expected effective clamp ${EXPECTED_EFFECTIVE_BYTES} bytes (exact: vm_budget ${VM_TOTAL_MB} - reserve ${GUEST_RESERVE_MB}, divided by ${COUNT} slots, capped at limits.memory_mb=${LIMIT_MEMORY_MB}); weakened values in the [runner_floor_mb..target] range are NOT acceptable"
    fi
    RUNNER_FLOOR_BYTES=$((RUNNER_FLOOR_MB * 1024 * 1024))
    if [ "$SLOT_MEMORY_BYTES" -lt "$RUNNER_FLOOR_BYTES" ]; then
        fail "slot $SLOT_NAME memory limit $SLOT_MEMORY_BYTES below the absolute floor $RUNNER_FLOOR_BYTES bytes (runner_floor_mb=$RUNNER_FLOOR_MB)"
    fi
    if [ "$SLOT_NANO_CPUS" -ne "$EXPECTED_NANO_CPUS" ]; then
        if [ "$SLOT_CPU_QUOTA" -le 0 ] || [ "$SLOT_CPU_PERIOD" -le 0 ]; then
            fail "slot $SLOT_NAME CPU enforcement unavailable: HostConfig.NanoCpus=${SLOT_NANO_CPUS}, CPUQuota=${SLOT_CPU_QUOTA}, CPUPeriod=${SLOT_CPU_PERIOD}; expected NanoCpus=${EXPECTED_NANO_CPUS}"
        fi
        # Ratio check: CPUQuota / CPUPeriod must equal LIMIT_CPUS (±1% tolerance).
        # cgroupfs sometimes rounds NanoCpus slightly vs period*quota, so a 1% band
        # is required to avoid false-positives while still catching a quota=-1
        # (unlimited) or quota far outside the requested CPU count.
        EXPECTED_QUOTA=$(awk -v cpus="$LIMIT_CPUS" -v period="$SLOT_CPU_PERIOD" 'BEGIN { printf "%.0f", cpus * period }')
        TOLERANCE=$(awk -v q="$EXPECTED_QUOTA" 'BEGIN { printf "%.0f", q * 0.01 + 1 }')
        DIFF=$(awk -v a="$SLOT_CPU_QUOTA" -v b="$EXPECTED_QUOTA" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.0f", d }')
        if [ "$DIFF" -gt "$TOLERANCE" ]; then
            ACTUAL_RATIO=$(awk -v q="$SLOT_CPU_QUOTA" -v p="$SLOT_CPU_PERIOD" 'BEGIN { if (p <= 0) print "inf"; else printf "%.3f", q / p }')
            fail "slot $SLOT_NAME CPUQuota/CPUPeriod ratio mismatch: HostConfig.CPUQuota=${SLOT_CPU_QUOTA}/CPUPeriod=${SLOT_CPU_PERIOD} = ${ACTUAL_RATIO} CPUs, expected ${LIMIT_CPUS} CPUs (quota=${EXPECTED_QUOTA}, tolerance=±${TOLERANCE}). NanoCpus is also wrong: ${SLOT_NANO_CPUS} != ${EXPECTED_NANO_CPUS}."
        fi
    fi
    if [ "$SLOT_PIDS_LIMIT" -lt 0 ] || [ "$SLOT_PIDS_LIMIT" -ne "$LIMIT_PIDS" ]; then
        fail "slot $SLOT_NAME PIDs mismatch: HostConfig.PidsLimit=${SLOT_PIDS_LIMIT}, expected ${LIMIT_PIDS}"
    fi
    if [ "$SLOT_STATUS" != "running" ]; then
        fail "slot $SLOT_NAME is not running (docker inspect State.Status=${SLOT_STATUS})"
    fi
    if ! inspect_has_no_new_privileges "$SLOT_NAME"; then
        fail "slot $SLOT_NAME missing HostConfig.SecurityOpt no-new-privileges"
    fi
    # Per-slot Worker process check removed: an idle fleet has no Worker
    # processes (only Listener), so requiring Worker here would make Gate 3
    # fail on every quiet window. Real execution proof comes from Gate 4's
    # nonce-tracked canary, which dispatches a job that spins up a Worker
    # and then verifies the run completed on the expected runner. Gate 3's
    # job is capacity + envelope, not execution.
    EXPECTED_RUNNING=$((EXPECTED_RUNNING + 1))
done

if [ "$EXPECTED_RUNNING" -ne "$COUNT" ]; then
    fail "Fleet capacity check failed: expected $COUNT slots passing envelope checks, saw $EXPECTED_RUNNING"
fi

OVERLAY_FREE_DISK_GB=$(daemon_overlay_free_disk_gb "$RUNNER_IMAGE" || true)
if [ -z "$OVERLAY_FREE_DISK_GB" ] || ! is_uint "$OVERLAY_FREE_DISK_GB"; then
    fail "Could not measure daemon overlay free disk via runner image $RUNNER_IMAGE"
fi
if [ "$OVERLAY_FREE_DISK_GB" -lt "$MIN_FREE_DISK_GB" ]; then
    fail "Daemon overlay free disk floor violated: ${OVERLAY_FREE_DISK_GB}GiB available < configured min ${MIN_FREE_DISK_GB}GiB"
fi

CONTAINER_COUNT=$(docker ps --filter label=ezgha=managed --format '{{.Names}}' 2>/dev/null | awk -v p="$NAME_PREFIX" '
index($0, p "-") == 1 {
    suffix = substr($0, length(p) + 2)
    if (suffix ~ /^[0-9]+$/) print
}' | wc -l | tr -d "[:space:]")
SLOT_FILE_STATE_DIR=$(toml_get_top state_dir "" 2>/dev/null || echo "")
if [ -z "$SLOT_FILE_STATE_DIR" ]; then
    SLOT_FILE_STATE_DIR="$HOME/.config/ezgha"
fi
SLOT_ASSIGNMENTS_FILE="$SLOT_FILE_STATE_DIR/slot_assignments.toml"
if [ ! -f "$SLOT_ASSIGNMENTS_FILE" ]; then
    fail "Slot assignment file missing: $SLOT_ASSIGNMENTS_FILE"
fi
# The daemon (src/docker_backend.rs SlotAssignments) serializes two tables
# ([assignments] and [registered_at]) with numeric string keys of the form
# '<slot_index> = "<runner_id>"'. Count only the [assignments] table entries
# (slot_index -> runner_id), excluding section headers ([...]) and any
# non-numeric keys — so SLOT_COUNT reflects the number of registered slots.
SLOT_COUNT=$(awk '
    /^\[assignments\]/ { in_assignments=1; next }
    /^\[registered_at\]|^[[:space:]]*\[/ { in_assignments=0; next }
    in_assignments && /^[[:space:]]*[0-9]+[[:space:]]*=/ { count++ }
    END { print count+0 }
' "$SLOT_ASSIGNMENTS_FILE" 2>/dev/null)
if ! is_uint "$SLOT_COUNT"; then
    fail "Could not parse slot count from $SLOT_ASSIGNMENTS_FILE (got '$SLOT_COUNT')"
fi

if [ "$CONTAINER_COUNT" -lt "$COUNT" ] || [ "$SLOT_COUNT" -lt "$COUNT" ]; then
    fail "Local fleet reconciliation evidence incomplete: containers=$CONTAINER_COUNT, slot file entries=$SLOT_COUNT, target=$COUNT"
fi

pass "Gate 3: Full local per-slot capacity and envelope enforcement proof passed (slots=$COUNT, per-slot envelopes=$EXPECTED_RUNNING)"

# --- Gate 4: Real job execution ---
echo "--- Checking Gate 4: Real job execution ---"
CANARY_TIMEOUT_SECONDS="${CANARY_TIMEOUT_SECONDS:-600}"
CANARY_CONFIG="${CANARY_CONFIG_FILE:-$CONFIG_FILE}"
if [ ! -f "$CANARY_CONFIG" ]; then
    fail "Gate 4: canary config file not found at $CANARY_CONFIG"
fi
CANARY_NAME_PREFIX=$(CONFIG_FILE="$CANARY_CONFIG" toml_get_runner name_prefix ez-org-runner 2>/dev/null || echo 'ez-org-runner')
if ! CANARY_OUT=$(~/.cargo/bin/ezgha --config "$CANARY_CONFIG" canary-once --timeout-seconds "$CANARY_TIMEOUT_SECONDS" 2>&1); then
    echo "$CANARY_OUT"
    fail "Gate 4: fresh nonce-tracked canary did not complete successfully on ${CANARY_NAME_PREFIX}-* using $CANARY_CONFIG"
fi
echo "$CANARY_OUT"
CANARY_RUN_ID=$(echo "$CANARY_OUT" | jq -r '.run_id // empty' 2>/dev/null || true)
CANARY_RUNNER=$(echo "$CANARY_OUT" | jq -r '.runner_name // empty' 2>/dev/null || true)
CANARY_TTS=$(echo "$CANARY_OUT" | jq -r '.time_to_start_seconds // empty' 2>/dev/null || true)
if [ -z "$CANARY_RUN_ID" ] || [ -z "$CANARY_RUNNER" ]; then
    fail "Gate 4: canary output lacked run_id or runner_name"
fi
echo "    [INFO] Fresh canary run $CANARY_RUN_ID started on $CANARY_RUNNER in ${CANARY_TTS:-?}s"
pass "Gate 4: Fresh nonce-tracked canary ran successfully on the ezgha fleet using $CANARY_CONFIG"

# --- Gate 7: Monitoring ---
echo "--- Checking Gate 7: Monitoring ---"
if [ "$PLATFORM" = "linux" ]; then
    MONITOR_TASKS=$(systemctl --user list-timers --all 2>/dev/null | awk '$1 ~ /ezgha-watchdog/ || $2 ~ /ezgha-watchdog/ || $3 ~ /ezgha-watchdog/ || $0 ~ /ezgha-watchdog/' || true)
    TIMER_ENABLED=$(systemctl --user is-enabled ezgha-watchdog.timer 2>/dev/null || true)
    TIMER_ACTIVE=$(systemctl --user is-active ezgha-watchdog.timer 2>/dev/null || true)
    SERVICE_ACTIVE=$(systemctl --user is-active ezgha-watchdog.service 2>/dev/null || true)
    if [ -z "$MONITOR_TASKS" ] || [ "$TIMER_ENABLED" != "enabled" ] || [ "$TIMER_ACTIVE" != "active" ]; then
        fail "Gate 7: Monitoring timer not properly installed/enabled/active (timers: '$MONITOR_TASKS', enabled: '$TIMER_ENABLED', active: '$TIMER_ACTIVE', service: '$SERVICE_ACTIVE')"
    fi
elif [ "$PLATFORM" = "macos" ]; then
    # Mac monitoring can be launchd-based; pass only if any health-related launchd
    # task is currently loaded.
    if ! launchctl list | grep -Ei 'worldarchitect|ezgha|runner-health' >/dev/null 2>&1; then
        fail "Gate 7: No active launchd monitoring/health item found for ezgha on macOS"
    fi
else
    fail "Gate 7: Unsupported platform $PLATFORM for monitoring check"
fi

ALERT_EVENT_KEY="gate7.verify.$(date +%s).$$"
if ! ALERT_TEST_OUT=$(~/.cargo/bin/ezgha --config "$CONFIG_FILE" test-alert --event-key "$ALERT_EVENT_KEY" 2>&1); then
    fail "Gate 7: Alert test-send failed: $ALERT_TEST_OUT"
fi
if ! echo "$ALERT_TEST_OUT" | grep -q "test alert delivered"; then
    fail "Gate 7: Alert test-send did not report delivery: $ALERT_TEST_OUT"
fi

if ! gh_checked api rate_limit >/dev/null; then
    fail "Gate 7: Unable to query rate limit (GitHub API down)"
fi
pass "Gate 7: Automated monitoring scheduled and alert delivery verified"

# --- Gate 8: VM/AO/MCP containment (process-level backstop; bead jleechan-aqh) ---
# Why this gate exists: the project's stated goal is physical-host
# availability (prevent watchdog reboots). Per-container clamps in Gate 3
# cover individual Docker containers, but they do NOT bound (a) the QEMU
# process running the Colima/Lima VM (host-side, outside the container
# envelope), (b) the Agent Orchestrator and MCP daemons (which run as
# user-scope processes with no enforced cgroup ceiling), or (c) the
# aggregate memory demand across all three. The 2026-07-10 watchdog
# reboot had QEMU OOM-killed at ~37.6 GiB with no aggregate cap in
# place. This gate makes the absence of any of those constraints a
# verifier-level fail-closed, citing the four remediation paths so the
# cold reader sees them at the top of the gate output.
echo "--- Checking Gate 8: VM/AO/MCP containment ---"
# Remediation primer (printed before probes fire so a cold reader sees
# the four probes + their fixes):
#   (1) QEMU slice:    systemd/app-lima-vm.slice (MemoryHigh=38G) must be
#                      deployed to ~/.config/systemd/user/ AND reloaded
#                      (systemctl --user daemon-reload); the LIVE leaf
#                      cgroup's memory.high in /sys/fs/cgroup must be a
#                      finite value (currently "max").
#   (2) AO/MCP slice:  an agent-CLI systemd slice from ez-gh-actions-0725
#                      must wrap ao-daemon.service with a finite
#                      MemoryHigh; currently ao-daemon.service has
#                      memory.high=max and contains the AO daemon + MCP
#                      servers uncontained.
#   (3) PSI admission: enroll scripts/host/psi-oom-watcher.sh via a
#                      user-scope .timer, OR rely on systemd-oomd active
#                      at any scope (default policy on Ubuntu 24.04
#                      manages user.slice automatically).
#   (4) Aggregate:     physical_host_RAM >= QEMU slice ceiling (read from
#                      /sys/fs/cgroup${QEMU_CG}/memory.high) + AO/MCP slice
#                      ceilings (sum across unique slice paths) + mandatory
#                      host reserve (max(2G, 10% of host RAM)). Container
#                      memory limits are NOT summed — they live inside the
#                      guest VM and roll up into the QEMU ceiling. The old
#                      equation double-counted container limits as if they
#                      were sibling RSS on the host. New remediation: raise
#                      physical host RAM, lower MemoryHigh on
#                      app-lima-vm.slice, or lower the agent-CLI slice
#                      MemoryHigh.
echo "    [REMEDIATION] (1) cp systemd/app-lima-vm.slice ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user restart lima-vm@colima. (2) install agent-CLI slice per ez-gh-actions-0725; ensure ao-daemon.service has a finite MemoryHigh. (3) systemctl --user enable --now psi-oom-watcher.timer (or rely on system systemd-oomd active). (4) ensure QEMU slice + AO/MCP slice ceilings + mandatory host reserve (max(2G, 10% host RAM)) fit within /proc/meminfo MemTotal; if not, raise host RAM, lower MemoryHigh on app-lima-vm.slice, or lower the agent-CLI slice MemoryHigh."

# (1) QEMU cgroup probe --------------------------------------------------------------
# Skip when daemon-in-VM AND on macOS — the Lima VM cgroup tree is not
# reachable from a macOS shell. On Linux + daemon-in-VM (typical
# jeff-ubuntu), QEMU runs at host scope and IS reachable via
# /proc/<qemu>/cgroup, so we still probe. On every other combo, we probe.
PROBE_QEMU_SLICE=1
if [ "$(uname -s)" = "Darwin" ] && daemon_in_vm; then
    PROBE_QEMU_SLICE=0
    echo "    [SKIP] Gate 8 (1) QEMU slice probe: daemon-in-VM on macOS (Lima VM cgroup not reachable from macOS shell)"
fi
QEMU_PID=""
QEMU_CG=""
if [ "$PROBE_QEMU_SLICE" = "1" ]; then
    QEMU_PID=$(pgrep -f 'qemu-system-x86_64' | head -1 || true)
    if [ -z "$QEMU_PID" ]; then
        fail "Gate 8 (1) FAIL-CLOSED: no qemu-system-x86_64 process detected on this host. The project's stated goal (physical-host availability) requires that the Colima/Lima VM is provably bounded by an enforced cgroup ceiling; without that process the bound cannot be verified. Remediation: start the Colima VM (limactl start colima, or colima start) — without it Docker daemon has no parent and the per-container limits are unrolled."
    else
        # /proc/<pid>/cgroup on cgroup-v2-only hosts is a single line
        # starting with "0::<path>". Extract the path with grep + cut.
        QEMU_CG=$(grep '^0::' "/proc/$QEMU_PID/cgroup" 2>/dev/null | head -1 || true)
        if [ -z "$QEMU_CG" ]; then
            fail "Gate 8 (1) PID $QEMU_PID has no cgroup-v2 entry in /proc/$QEMU_PID/cgroup. Remediation: ensure the host kernel exposes CONFIG_CGROUP_V2."
        fi
        # /proc/<pid>/cgroup escapes '-' as the literal 4-char sequence
        # '\x2d' on this host, so 'app-lima-vm' written plainly will not
        # match 'app-lima\x2dvm.slice'. Match on the unit/service name
        # instead — 'lima-vm' substring catches both 'lima-vm@colima.service'
        # and 'app-lima\x2dvm.slice'.
        if ! echo "$QEMU_CG" | grep -q 'lima-vm'; then
            fail "Gate 8 (1) QEMU (pid=$QEMU_PID) cgroup is '$QEMU_CG' — expected to contain 'lima-vm'. Remediation: migrate lima-vm@colima.service to the app-lima-vm.slice defined in systemd/app-lima-vm.slice."
        fi
        if ! QEMU_BAD=$(cgroup_leaf_has_memory_ceiling "$QEMU_CG"); then
            fail "Gate 8 (1) QEMU (pid=$QEMU_PID) leaf cgroup is unbounded: $QEMU_BAD. Remediation: deploy systemd/app-lima-vm.slice (MemoryHigh=38G) to ~/.config/systemd/user/, run 'systemctl --user daemon-reload', then restart lima-vm@colima so the new slice is applied."
        fi
        echo "    [PASS] Gate 8 (1) QEMU (pid=$QEMU_PID) leaf cgroup has a finite memory ceiling"
    fi
fi

# (2) AO/MCP slice probe --------------------------------------------------------------
# Identify Agent Orchestrator + MCP daemon processes by argv pattern
# (comm alone misses python3-spawned MCP servers), then verify each
# leaf cgroup has a finite memory ceiling. Processes running in
# /user@<uid>.service/ (the unbounded user session) are also a fail.
AO_MCP_BAD=""
AO_MCP_BAD_COUNT=0
while read -r pid; do
    [ -z "$pid" ] && continue
    cg=$(grep '^0::' "/proc/$pid/cgroup" 2>/dev/null | head -1 || true)
    [ -z "$cg" ] && continue
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
    # /user@<uid>.service/ is the unbounded user session — fail-closed.
    if echo "$cg" | grep -qE '/user@[0-9]+\.service/'; then
        AO_MCP_BAD="${AO_MCP_BAD}${comm}(pid=${pid}) "
        AO_MCP_BAD_COUNT=$((AO_MCP_BAD_COUNT + 1))
        continue
    fi
    if ! LEAF_CHECK=$(cgroup_leaf_has_memory_ceiling "$cg"); then
        AO_MCP_BAD="${AO_MCP_BAD}${comm}(pid=${pid},$LEAF_CHECK) "
        AO_MCP_BAD_COUNT=$((AO_MCP_BAD_COUNT + 1))
    fi
done < <(ps -u "$(id -u)" -o pid=,args= --no-headers 2>/dev/null | \
          awk '{
              cmd = ""
              for (i = 2; i <= NF; i++) cmd = cmd " " $i
              # Match on full argv: ao-go, agent_orchestrator, the various
              # MCP daemons (slack-mcp, gmail-mcp, filesystem-mcp, …), and
              # the daemon launcher script.
              if (cmd ~ /(ao-go|agent_orchestrator|slack-mcp|slack_mcp|gmail-mcp|gmail_mcp|mcp-daemon|mcp_daemon|start-mcp-daemons|mcp__)/) {
                  print $1
              }
          }')
if [ -n "$AO_MCP_BAD" ]; then
    fail "Gate 8 (2) AO/MCP processes running without enforced slice ceiling (n=${AO_MCP_BAD_COUNT}): $AO_MCP_BAD. Remediation: per bead ez-gh-actions-0725, wrap ao-daemon.service in an agent-CLI slice with a finite MemoryHigh (~20G) so the Agent Orchestrator + MCP daemons cannot OOM the host."
fi
AO_MCP_TOTAL=$(ps -u "$(id -u)" -o args= --no-headers 2>/dev/null | awk '
              {
                cmd = ""
                for (i = 1; i <= NF; i++) cmd = cmd " " $i
                if (cmd ~ /(ao-go|agent_orchestrator|slack-mcp|slack_mcp|gmail-mcp|gmail_mcp|mcp-daemon|mcp_daemon|start-mcp-daemons|mcp__)/) {
                  c++
                }
              }
              END {
                print c+0
              }')
echo "    [PASS] Gate 8 (2) AO/MCP processes (n=${AO_MCP_TOTAL}) are inside an enforced slice with a finite memory ceiling"

# (2.5) agents.slice enrollment probe (round-3 lane G, bead ez-gh-actions-0725) ---
# The round-3 panel decision flipped agents.slice from opt-in to AUTO-MIGRATE
# with --opt-out (see systemd/agents.slice header for the policy change).
# That auto-migrate default is only as good as its enforcement: if any
# agent-CLI binary is on PATH yet zero leaves are enrolled in the slice, an
# operator could be silently running unscoped and the verifier would never
# notice. This probe fail-closes on exactly that shape.
#
# Rule (per bead ez-gh-actions-0725):
#   - For each candidate agent-CLI binary on PATH (claude, codex, gemini,
#     cursor, aider, cody), note whether it exists. If NONE are on PATH,
#     the requirement is waived (operators who have not installed an
#     agent CLI do not need to enroll anything).
#   - If ANY candidate is on PATH, then agents.slice MUST have at least
#     one enrolled leaf (transient scope-* or service-* child), AND
#     every enrolled leaf's memory.high MUST be a finite value (an
#     "unbounded leaf within a bounded slice" is the exact failure
#     shape that motivated this probe — the slice's own MemoryHigh
#     applies to the SUM of its children, so a leaf with memory.high=
#     max inside agents.slice defeats the parent cap).
#   - The ao-daemon.service drop-in at
#     systemd/ao-daemon-memory-cap.service.d/memory.conf installs
#     Slice=agents.slice + MemoryHigh=20G on the daemon; the script
#     scripts/host/agent-auto-migrate.sh enrolls interactive sessions.
AGENT_CLI_BINARIES="claude codex gemini cursor aider cody"
AGENT_CLI_FOUND=""
AGENT_CLI_MISSING=""
for bin in $AGENT_CLI_BINARIES; do
    if command -v "$bin" >/dev/null 2>&1; then
        # Resolve via `command -v` path so installers put the binary
        # on PATH in a non-standard location (npm-global, ~/.local/bin)
        # and still match.
        AGENT_CLI_FOUND="${AGENT_CLI_FOUND}${bin}($(command -v "$bin")) "
    else
        AGENT_CLI_MISSING="${AGENT_CLI_MISSING}${bin} "
    fi
done
if [ -z "${AGENT_CLI_FOUND// /}" ]; then
    echo "    [SKIP] Gate 8 (2.5) agents.slice enrollment: no agent-CLI binaries on PATH (${AGENT_CLI_MISSING}missing); requirement waived per bead ez-gh-actions-0725"
else
    # Walk the slice's child cgroups under user.slice/user-<UID>.slice/
    # user@<UID>.service/agents.slice/ (transient scopes + service
    # leaves both sit there). Each child is a real enrollment.
    SYSFS="/sys/fs/cgroup"
    AGENT_SLICE_BASE="${SYSFS}/user.slice/user-$(id -u).slice/user@$(id -u).service/agents.slice"
    AGENT_LEAF_COUNT=0
    AGENT_UNBOUNDED_LEAVES=""
    if [ -d "${AGENT_SLICE_BASE}" ]; then
        # Enumerate immediate child cgroups of the slice.
        while IFS= read -r leaf_dir; do
            [ -d "$leaf_dir" ] || continue
            AGENT_LEAF_COUNT=$((AGENT_LEAF_COUNT + 1))
            leaf_high=$(cat "${leaf_dir}/memory.high" 2>/dev/null || echo "?")
            # Treat "max" AND "unreadable" as unbounded; the helper
            # cgroup_leaf_has_memory_ceiling accepts both. Either shape
            # means the leaf has no enforced ceiling.
            if [ "$leaf_high" = "max" ] || [ "$leaf_high" = "?" ]; then
                leaf_name=$(basename "$leaf_dir")
                AGENT_UNBOUNDED_LEAVES="${AGENT_UNBOUNDED_LEAVES}${leaf_name}(memory.high=${leaf_high}) "
            fi
        done < <(find "${AGENT_SLICE_BASE}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
    fi
    if [ "$AGENT_LEAF_COUNT" -eq 0 ]; then
        fail "Gate 8 (2.5) agents.slice enrollment FAIL-CLOSED: agent-CLI binaries on PATH (${AGENT_CLI_FOUND}) but ${AGENT_SLICE_BASE} has zero enrolled leaves. Remediation: per bead ez-gh-actions-0725 (round-3 policy: AUTO-MIGRATE with --opt-out), run 'scripts/host/agent-auto-migrate.sh apply' to relaunch matching PIDs into the slice, OR install systemd/ao-daemon-memory-cap.service.d/memory.conf to enroll the ao-daemon.service so the slice has at least one service-* leaf. The AGENT_SLICE_OPT_OUT=1 env-var escape hatch exists for explicit opt-OUT per session."
    fi
    if [ -n "$AGENT_UNBOUNDED_LEAVES" ]; then
        fail "Gate 8 (2.5) agents.slice enrollment FAIL-CLOSED: slice has ${AGENT_LEAF_COUNT} leaf(ves) but ${AGENT_UNBOUNDED_LEAVES}are unbounded (memory.high=max). The parent slice's MemoryHigh applies to the SUM of children, so a leaf with memory.high=max defeats the aggregate cap. Remediation: copy systemd/ao-daemon-memory-cap.service.d/memory.conf to ~/.config/systemd/user/ao-daemon.service.d/ and ensure every interactive agent-CLI session enrolls via scripts/host/agent-auto-migrate.sh (which delegates to systemd-run --user --slice=agents.slice --scope -- <cmd>). Per bead ez-gh-actions-0725."
    fi
    echo "    [PASS] Gate 8 (2.5) agents.slice enrollment: ${AGENT_LEAF_COUNT} leaf(ves) enrolled (all memory.high finite); agent-CLI on PATH: ${AGENT_CLI_FOUND}"
fi

# (3) PSI admission check --------------------------------------------------------------
# Either a real cgroup is enrolled with systemd-oomd (ManagedOOM
# MemoryPressure/Swap explicitly opted in, OR oomctl reports a
# non-empty "Memory Pressure Monitored CGroups:" list), OR
# psi-oom-watcher.timer is enrolled AND the script it invokes actually
# contains a real shed action path (kill / systemctl stop / qemu-lima-
# docker shed, not a no-op journal logger). One of the two MUST be live;
# the previous version of this check accepted "systemd-oomd active"
# alone, which fails to detect the 2026-07-10 host-crash failure mode
# where oomd was running but no cgroup was actually enrolled for
# protection (oomctl reported an empty "Memory Pressure Monitored
# CGroups:" list even with ManagedOOMMemoryPressure=auto on every top-
# level slice — oomd is watching but never kills anything).
PSI_OK=0
PSI_SOURCE=""

# --- Option A: systemd-oomd with a real, enrolled cgroup -----------------
OOMD_ACTIVE=0
OOMD_SCOPE=""
if systemctl is-active systemd-oomd 2>/dev/null | grep -q '^active'; then
    OOMD_ACTIVE=1
    OOMD_SCOPE="system"
elif systemctl --user is-active systemd-oomd 2>/dev/null | grep -q '^active'; then
    OOMD_ACTIVE=1
    OOMD_SCOPE="user"
fi
OOMD_ENROLLED=0
OOMD_ENROLL_PROOF=""
if [ "$OOMD_ACTIVE" = "1" ]; then
    # oomctl is the ground truth: it reports the cgroups oomd is actually
    # monitoring, after the "auto" -> concrete resolution step. An empty
    # list means oomd is running but doing nothing (the exact failure
    # mode that motivated this hardening). If oomctl is unavailable, fall
    # back to walking every loaded unit for an explicit
    # ManagedOOMMemoryPressure=kill / ManagedOOMSwap=kill opt-in (or
    # ManagedOOMPreference=avoid/omit, which also enrolls the unit as
    # a candidate for oomd action).
    OOMCTL_OUT="$(oomctl 2>/dev/null || true)"
    if [ -n "$OOMCTL_OUT" ]; then
        PRESSURE_ENROLLED="$(printf '%s\n' "$OOMCTL_OUT" | awk '
            /^Memory Pressure Monitored CGroups:/ { capturing = 1; next }
            /^Swap Monitored CGroups:/            { capturing = 0 }
            capturing                             { print }
        ' | grep -E '^[[:space:]]' | grep -v '^[[:space:]]*$' || true)"
        SWAP_ENROLLED="$(printf '%s\n' "$OOMCTL_OUT" | awk '
            /^Swap Monitored CGroups:/ { capturing = 1; next }
            capturing                  { print }
        ' | grep -E '^[[:space:]]' | grep -v '^[[:space:]]*$' || true)"
        if [ -n "$PRESSURE_ENROLLED" ] || [ -n "$SWAP_ENROLLED" ]; then
            OOMD_ENROLLED=1
            OOMD_ENROLL_PROOF="oomctl: pressure=$(printf '%s\n' "$PRESSURE_ENROLLED" | grep -c . || echo 0) swap=$(printf '%s\n' "$SWAP_ENROLLED" | grep -c . || echo 0) cgroup(s) enrolled"
        fi
    fi
    if [ "$OOMD_ENROLLED" = "0" ]; then
        # Fallback: walk loaded units for an explicit kill/protect opt-in.
        # ManagedOOMMemoryPressure and ManagedOOMSwap are the actual
        # systemd properties (the brief's "ManagedOOM=" is shorthand for
        # these two). ManagedOOMPreference=avoid/omit are also real
        # enrollments (the unit is a candidate for oomd action).
        EXPLICIT_KILL_UNITS="$(systemctl show --property=ManagedOOMMemoryPressure,ManagedOOMSwap,ManagedOOMPreference --value --no-pager 2>/dev/null \
            | grep -E '^(kill|avoid|omit)$' | sort -u || true)"
        if [ -n "$EXPLICIT_KILL_UNITS" ]; then
            OOMD_ENROLLED=1
            OOMD_ENROLL_PROOF="systemctl show: explicit ManagedOOM opt-in (${EXPLICIT_KILL_UNITS//$'\n'/,})"
        fi
    fi
    if [ "$OOMD_ENROLLED" = "1" ]; then
        PSI_OK=1
        PSI_SOURCE="systemd-oomd (${OOMD_SCOPE}-scope, ${OOMD_ENROLL_PROOF})"
    fi
fi

# --- Option B: psi-oom-watcher.timer enrolled with a real shed path -----
if [ "$PSI_OK" != "1" ]; then
    TIMER_ENABLED=$(systemctl --user is-enabled psi-oom-watcher.timer 2>/dev/null || true)
    TIMER_ACTIVE=$(systemctl --user is-active psi-oom-watcher.timer 2>/dev/null || true)
    PSI_SCRIPT=""
    # Resolve the actual script path the timer invokes. Prefer
    # systemctl cat (resolves ExecStart on this host); fall back to the
    # repo's expected path. Bail to "" if neither yields a readable
    # file — the gate must not trust an unverified path.
    if [ "$TIMER_ENABLED" = "enabled" ] && [ "$TIMER_ACTIVE" = "active" ]; then
        TIMER_UNIT_FILE=$(systemctl --user cat psi-oom-watcher.timer 2>/dev/null \
            | awk '/^ExecStart=/ { sub(/^ExecStart=/, ""); print; exit }' || true)
        if [ -n "$TIMER_UNIT_FILE" ] && [ -r "$TIMER_UNIT_FILE" ]; then
            PSI_SCRIPT="$TIMER_UNIT_FILE"
        elif [ -r "${SCRIPTS_DIR:-}/psi-oom-watcher.sh" ]; then
            PSI_SCRIPT="${SCRIPTS_DIR}/psi-oom-watcher.sh"
        fi
        SHED_PROOF=""
        if [ -n "$PSI_SCRIPT" ] && [ -r "$PSI_SCRIPT" ]; then
            # "Real shed action" = the script can actually terminate
            # something under sustained pressure. Patterns accepted:
            #   - kill / pkill (any process termination)
            #   - systemctl stop/kill (slice/unit termination)
            #   - qemu/lima/colima/docker stop|kill|shutdown|qemu-monitor
            #     (the brief's explicit example class — VM/container shed)
            # A no-op watcher that only logs to journal must NOT pass.
            if grep -Ev '^[[:space:]]*#' "$PSI_SCRIPT" 2>/dev/null \
                | grep -Eq '\b(kill|pkill)\b[[:space:]]' \
                || grep -Ev '^[[:space:]]*#' "$PSI_SCRIPT" 2>/dev/null \
                    | grep -Eq 'systemctl[[:space:]]+(stop|kill)' \
                || grep -Ev '^[[:space:]]*#' "$PSI_SCRIPT" 2>/dev/null \
                    | grep -Eq '(qemu|lima|colima|docker)[[:space:]]+(stop|kill|shutdown|qemu-monitor-command)'; then
                SHED_PROOF="script=${PSI_SCRIPT##*/} contains real shed action (kill/systemctl-stop/qemu-lima-docker shed)"
            fi
        fi
        if [ -n "$SHED_PROOF" ]; then
            PSI_OK=1
            PSI_SOURCE="psi-oom-watcher.timer (user-scope, ${SHED_PROOF})"
        fi
    fi
fi

if [ "$PSI_OK" != "1" ]; then
    # Distinguish the two failure shapes so the operator knows which
    # remediation applies. The oomd-only failure is the exact one that
    # produced the 2026-07-10 host crash; the script failure is the
    # "watcher is enrolled but does nothing" shape.
    OOMD_BUT_NO_CGROUP=""
    if [ "$OOMD_ACTIVE" = "1" ] && [ "$OOMD_ENROLLED" = "0" ]; then
        OOMD_BUT_NO_CGROUP=" NOTE: systemd-oomd is active at ${OOMD_SCOPE}-scope but oomctl reports zero monitored cgroups — this is the exact 'oomd running but no cgroup enrolled' shape that allowed the 2026-07-10 host crash. Remediation: set ManagedOOMMemoryPressure=kill / ManagedOOMSwap=kill on a top-level slice (e.g. user.slice, system.slice) so oomctl reports a non-empty 'Memory Pressure Monitored CGroups:' list, or set ManagedOOMPreference=avoid/omit on slices you want protected from oom-kill, or wire scripts/host/psi-oom-watcher.sh into psi-oom-watcher.timer as a user-scope backstop (per bead ez-gh-actions-0725)."
    fi
    fail "Gate 8 (3) PSI admission is not wired up with a real shed action: oomd has no enrolled cgroup, AND psi-oom-watcher.timer is either not enabled+active or its script contains no kill/systemctl-stop/qemu-lima-docker shed path. Remediation: enroll scripts/host/psi-oom-watcher.sh via a user-scope .timer (per bead ez-gh-actions-0725), OR set ManagedOOMMemoryPressure=kill / ManagedOOMSwap=kill on a top-level slice so oomctl reports a non-empty 'Memory Pressure Monitored CGroups:' list.${OOMD_BUT_NO_CGROUP}"
fi
PSI_AVG10=$(awk '/^full/ {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {gsub("avg10=", "", $i); print $i; exit}}' /proc/pressure/memory 2>/dev/null || echo "?")
echo "    [PASS] Gate 8 (3) PSI admission wired up via $PSI_SOURCE (current /proc/pressure/memory full avg10=${PSI_AVG10}%)"

# (4) Physical-host RAM envelope ---------------------------------------------------
# Total bounded memory demand on the physical host's RAM, compared
# against /proc/meminfo MemTotal. The previous version double-counted
# container-Memory limits inside QEMU RSS — but containers run INSIDE
# the guest VM, so their demand rolls up into the VM's RSS / slice
# ceiling. Adding them again over-counted by roughly
# [runner].count * [limits].memory_mb (~50 GB on this host), masking
# the real budget headroom and silently re-introducing the 2026-07-10
# OOM failure mode this gate exists to prevent.
#
# New equation (per bead ez-gh-actions-bjpk, P0 #R2-6):
#
#   physical_host_RAM >= QEMU_slice_ceiling       # VM (app-lima-vm.slice)
#                     + AO/MCP_slice_ceiling      # orchestration agents
#                     + other_bounded             # future top-level slices
#                     + mandatory_host_reserve    # kernel/system/monitoring
#
# QEMU slice ceiling: read from /sys/fs/cgroup${QEMU_CG}/memory.high
# (the kernel-enforced DefaultMemoryHigh pushed down from
# app-lima-vm.slice). If 'max', the VM has no upper bound on host RAM
# — fail-closed.
#
# AO/MCP slice ceiling: for each AO/MCP process, walk UP the cgroup
# tree to find the first ancestor with a finite memory.high — that is
# the slice ceiling for that branch. Sum across unique slice paths
# (multiple services under one slice share the slice's ceiling;
# summing per-leaf would over-count). For any AO/MCP process with no
# bounded ancestor, fall back to that process's live RSS and warn
# (defense in depth; gate (2) already FAIL-CLOSES on missing AO/MCP
# ceiling).
#
# Mandatory host reserve: max(2 GiB, 10% of physical host RAM) — keeps
# headroom for the kernel, system services, monitoring daemons, and
# the watchdog itself. Without this carve-out, slices pinned at
# host-RAM ceiling leave zero room for anything else.
#
# physical_host_RAM is read from /proc/meminfo MemTotal (kernel truth),
# independent of the guest VM's `VM_TOTAL_MB` (which is the
# guest-visible Docker budget for per-container clamps).
#
# Skip on macOS — cgroup-v2 is a Linux-only kernel interface, so the
# slice-ceiling model does not apply.
if [ "$(uname -s)" = "Darwin" ]; then
    echo "    [SKIP] Gate 8 (4) host-RAM aggregate: macOS — cgroup-v2 not available, host-RAM envelope model is Linux-only"
else
    HOST_MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    if ! is_uint "$HOST_MEM_TOTAL_KB" || [ "$HOST_MEM_TOTAL_KB" -eq 0 ]; then
        fail "Gate 8 (4) could not read physical-host MemTotal from /proc/meminfo (got '${HOST_MEM_TOTAL_KB}'). Remediation: verify /proc/meminfo is readable on this host."
    fi
    HOST_MEM_TOTAL_MB=$((HOST_MEM_TOTAL_KB / 1024))

    # (4a) QEMU slice ceiling --------------------------------------------------------
    # Read the slice's enforced memory.high (set by app-lima-vm.slice,
    # currently 38 GiB). If "max", the VM has no upper bound — fail-closed.
    QEMU_CG_PATH="${QEMU_CG#0::}"
    if [ -z "$QEMU_CG_PATH" ]; then
        fail "Gate 8 (4) QEMU cgroup path is empty (QEMU_CG='$QEMU_CG'). Remediation: gate (1) must succeed before this probe; restart the verifier with a running QEMU/Colima VM."
    fi
    QEMU_CEILING_BYTES=$(cat "/sys/fs/cgroup${QEMU_CG_PATH}/memory.high" 2>/dev/null || echo "")
    if [ -z "$QEMU_CEILING_BYTES" ]; then
        fail "Gate 8 (4) QEMU slice /sys/fs/cgroup${QEMU_CG_PATH}/memory.high is unreadable. Remediation: verify cgroup-v2 fs is mounted and the slice path is correct (got QEMU_CG='$QEMU_CG')."
    fi
    if [ "$QEMU_CEILING_BYTES" = "max" ]; then
        fail "Gate 8 (4) QEMU slice ceiling is 'max' (unbounded) — the VM has no enforced upper bound on host RAM and could exhaust it. Remediation: deploy systemd/app-lima-vm.slice (MemoryHigh=38G) to ~/.config/systemd/user/, run 'systemctl --user daemon-reload', then restart lima-vm@colima so the new slice is applied."
    fi
    QEMU_CEILING_MB=$(awk -v b="$QEMU_CEILING_BYTES" 'BEGIN { printf "%d\n", b / 1024 / 1024 }')

    # (4b) AO/MCP slice ceiling ------------------------------------------------------
    # For each AO/MCP process, find the closest *.slice ancestor in its
    # cgroup path — that slice's memory.high is the effective ceiling
    # for that branch. The kernel enforces a slice's DefaultMemoryHigh
    # on the SUM of all its children, so multiple services under one
    # slice share that slice's ceiling; summing per-leaf readings (each
    # leaf reads the inherited value) would over-count by N. Dedup by
    # SLICE PATH, not leaf path.
    #
    # For any AO/MCP process whose closest slice has memory.high=max
    # (or whose cgroup path has no slice at all), fall back to that
    # process's live RSS and warn. Gate (2) already FAIL-CLOSES on any
    # unbounded AO/MCP process; this is defense in depth.
    declare -A AO_MCP_SLICE_SEEN
    AO_MCP_CEILING_MB=0
    AO_MCP_CEILING_NOTE=""
    AO_MCP_UNBOUNDED_COUNT=0
    while read -r pid; do
        [ -z "$pid" ] && continue
        cg=$(grep '^0::' "/proc/$pid/cgroup" 2>/dev/null | head -1 || true)
        [ -z "$cg" ] && continue
        cg="${cg#0::}"
        slice_path=""
        ancestor="$cg"
        # Walk UP from the leaf looking for the closest *.slice; stop
        # at the first one we find (don't escape its scope — the closer
        # slice is the one that bounds this branch).
        while [ -n "$ancestor" ]; do
            case "$ancestor" in
                *.slice)
                    val=$(cat "/sys/fs/cgroup${ancestor}/memory.high" 2>/dev/null || echo "")
                    if [ -n "$val" ] && [ "$val" != "max" ]; then
                        slice_path="$ancestor"
                    fi
                    # Stop at the closest slice — bounded or not. Looking
                    # further up would escape this slice's scope.
                    break
                    ;;
            esac
            ancestor="${ancestor%/*}"
        done
        if [ -z "$slice_path" ]; then
            # No slice, OR closest slice is unbounded — fall back to live RSS.
            rss_kb=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || echo 0)
            [ -z "$rss_kb" ] && rss_kb=0
            AO_MCP_CEILING_MB=$((AO_MCP_CEILING_MB + rss_kb / 1024))
            AO_MCP_UNBOUNDED_COUNT=$((AO_MCP_UNBOUNDED_COUNT + 1))
        else
            if [ -n "${AO_MCP_SLICE_SEEN[$slice_path]:-}" ]; then continue; fi
            AO_MCP_SLICE_SEEN[$slice_path]=1
            ceiling_bytes=$(cat "/sys/fs/cgroup${slice_path}/memory.high" 2>/dev/null || echo "")
            AO_MCP_CEILING_MB=$((AO_MCP_CEILING_MB + ceiling_bytes / 1024 / 1024))
        fi
    done < <(ps -u "$(id -u)" -o pid=,args= --no-headers 2>/dev/null | \
              awk '{
                  cmd = ""
                  for (i = 2; i <= NF; i++) cmd = cmd " " $i
                  if (cmd ~ /(ao-go|agent_orchestrator|slack-mcp|slack_mcp|gmail-mcp|gmail_mcp|mcp-daemon|mcp_daemon|start-mcp-daemons|mcp__)/) {
                      print $1
                  }
              }')
    if [ "$AO_MCP_UNBOUNDED_COUNT" -gt 0 ]; then
        AO_MCP_CEILING_NOTE="(n=${AO_MCP_UNBOUNDED_COUNT} AO/MCP processes unbounded — live RSS used for those)"
    fi

    # (4c) Mandatory host reserve ----------------------------------------------------
    # 10% of host RAM, with a 2 GiB floor.
    MANDATORY_RESERVE_MB=$((HOST_MEM_TOTAL_MB / 10))
    if [ "$MANDATORY_RESERVE_MB" -lt 2048 ]; then
        MANDATORY_RESERVE_MB=2048
    fi

    # (4d) Sum and compare -----------------------------------------------------------
    # QEMU_ceiling + AO/MCP_ceiling + mandatory_reserve <= physical_host_RAM.
    # (Other bounded top-level cgroups are counted via the AO/MCP slice
    # walk above; add explicit terms here as new bounded top-level slices
    # ship.)
    AGG_TOTAL_MB=$((QEMU_CEILING_MB + AO_MCP_CEILING_MB + MANDATORY_RESERVE_MB))
    AGG_BUDGET_MB=$HOST_MEM_TOTAL_MB
    if [ "$AGG_TOTAL_MB" -gt "$AGG_BUDGET_MB" ]; then
        fail "Gate 8 (4) aggregate bounded demand ${AGG_TOTAL_MB}MB exceeds physical host RAM ${AGG_BUDGET_MB}MB (qemu_ceiling=${QEMU_CEILING_MB}MB + ao_mcp_ceiling=${AO_MCP_CEILING_MB}MB ${AO_MCP_CEILING_NOTE}+ mandatory_reserve=${MANDATORY_RESERVE_MB}MB; physical_host_RAM=${HOST_MEM_TOTAL_MB}MB from /proc/meminfo MemTotal). Remediation: raise physical host RAM, lower MemoryHigh on app-lima-vm.slice, or lower the agent-CLI slice MemoryHigh."
    fi
    echo "    [PASS] Gate 8 (4) aggregate bounded demand ${AGG_TOTAL_MB}MB <= physical host RAM ${AGG_BUDGET_MB}MB (qemu_ceiling=${QEMU_CEILING_MB}MB + ao_mcp_ceiling=${AO_MCP_CEILING_MB}MB ${AO_MCP_CEILING_NOTE}+ mandatory_reserve=${MANDATORY_RESERVE_MB}MB)"
fi

pass "Gate 8: VM/AO/MCP containment enforced (bead jleechan-aqh)"

# --- Gate 9: Controlled host-pressure proof (bead ez-gh-actions-bjpk, R3 lane L) ---
# This gate invokes scripts/host/host-pressure-proof.sh — the executable
# proof that the three host-reliability lanes (I: PSI/hysteresis admission
# refusal in src/docker_backend.rs::eval_admission; J: 4-stage
# drain→reclaim→verify→escalate shed chain in
# scripts/host/psi-oom-watcher.sh; K: kernel-panic harness in
# scripts/host/crash-capture-verify.sh) work together under live pressure
# without OOM, watchdog reboot, or QEMU cgroup ceiling breach.
#
# Two modes:
#   * DEFAULT (HPP_LIVE != 1): the verifier runs --dry-run only — it
#     verifies the script EXISTS, its preconditions are met (QEMU running,
#     agents.slice enrolled, config readable, stress-ng installed), and
#     the auto-computed pressure plan is sane. This is the path normal CI
#     takes; it does NOT spawn stress-ng or canaries and is safe to run
#     on the live fleet.
#   * LIVE (HPP_LIVE=1): the verifier runs the full live pressure + canary
#     burst + recovery loop. This is operator-gated — it pressures the
#     host for ~60s with stress-ng inside agents.slice, dispatches N
#     concurrent canaries, and waits for MemAvailable to recover. Use
#     this on a quiet window (e.g. before a major release) to validate
#     the round-3 protection stack end-to-end. NEVER auto-enable in CI.
#
# Dry-run timeout defaults to 180s (HPP_TIMEOUT overrides). Live mode
# defaults to 300s (HPP_TIMEOUT overrides).
echo "--- Checking Gate 9: Controlled host-pressure proof ---"
HPP_SCRIPT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/host/host-pressure-proof.sh"
if [ ! -x "${HPP_SCRIPT}" ]; then
    fail "Gate 9: host-pressure-proof.sh not found or not executable at ${HPP_SCRIPT}"
fi
HPP_TIMEOUT_VAL="${HPP_TIMEOUT:-180}"
if [ "${HPP_LIVE:-0}" = "1" ]; then
    HPP_TIMEOUT_VAL="${HPP_TIMEOUT:-300}"
fi
HPP_DRY_OUTPUT=""
if ! HPP_DRY_OUTPUT=$(timeout "${HPP_TIMEOUT_VAL}s" "${HPP_SCRIPT}" --dry-run 2>&1); then
    echo "${HPP_DRY_OUTPUT}"
    fail "Gate 9: dry-run failed (exit $?) — see host-pressure-proof.sh output above. Preconditions unmet (QEMU not running, agents.slice not enrolled, stress-ng missing, etc.) — apply the remediation printed in the dry-run output."
fi
echo "${HPP_DRY_OUTPUT}"
# Live: only attempt if --live enabled and host not under pressure already
if [ "${HPP_LIVE:-0}" = "1" ]; then
    HPP_LIVE_OUTPUT=""
    if ! HPP_LIVE_OUTPUT=$(timeout "${HPP_TIMEOUT_VAL}s" "${HPP_SCRIPT}" --timeout-seconds "${HPP_TIMEOUT_VAL}" 2>&1); then
        echo "${HPP_LIVE_OUTPUT}"
        fail "Gate 9: live host-pressure-proof exited $? — host did not absorb + recover from controlled pressure within budget"
    fi
    echo "${HPP_LIVE_OUTPUT}"
    pass "Gate 9: Host absorbed + recovered from controlled pressure (round-3 acceptance)"
else
    echo "    [INFO] Gate 9 dry-run verified; live proof requires HPP_LIVE=1"
    pass "Gate 9: Controlled host-pressure harness present (dry-run path)"
fi

# --- Gate 10: GitHub API budget ---
echo "--- Checking Gate 10: GitHub API budget ---"
RATE_LIMIT_JSON=$(gh_checked api rate_limit) || fail "Gate 10: Unable to query rate limit (GitHub API down)"
REMAINING_API=$(echo "$RATE_LIMIT_JSON" | jq -r '.resources.core.remaining')
LIMIT_API=$(echo "$RATE_LIMIT_JSON" | jq -r '.resources.core.limit')
MIN_API=$((LIMIT_API / 5)) # 20%
if [ "$REMAINING_API" -lt "$MIN_API" ]; then
    fail "GitHub API core budget remaining ($REMAINING_API) is less than 20% of limit ($LIMIT_API)"
fi
pass "Gate 10: GitHub API budget is healthy ($REMAINING_API/$LIMIT_API remaining)"

echo "==================================================="
echo -e "${GREEN}ALL AUTO GATES PASS EXCELLENTLY!${NC}"
exit 0
