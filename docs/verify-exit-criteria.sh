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
except ModuleNotFoundError:
    try:
        import toml
except ModuleNotFoundError:
    raise SystemExit(2)
    data = toml.load(path)
else:
    with open(path, "rb") as f:
        data = tomllib.load(f)

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
    local name="$1"
    if ! docker top "$name" >/dev/null 2>&1; then
        return 1
    fi
    docker top "$name" 2>/dev/null | awk 'NR>1 && $0 ~ /Runner\.Worker|Runner\.Listener/ {found=1} END {exit !found}'
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
    if [ ! -d /sys/fs/pstore ]; then
        echo "    [WARN] Crash-capture evidence missing: /sys/fs/pstore is not mounted"
        return 0
    fi
    if [ ! -r /proc/sys/kernel/core_pattern ]; then
        echo "    [WARN] Crash-capture evidence missing: /proc/sys/kernel/core_pattern unavailable"
        return 0
    fi
    if [ ! -f /sys/kernel/kexec_crash_loaded ]; then
        echo "    [WARN] Crash-capture evidence missing: /sys/kernel/kexec_crash_loaded unavailable"
        return 0
    fi
    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null || echo 0)" != "1" ]; then
        echo "    [WARN] Crash-capture evidence missing: /sys/kernel/kexec_crash_loaded is not enabled (value != 1)"
        return 0
    fi
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
# Parse runner.count from config.toml
CONFIG_FILE="$HOME/.config/ezgha/config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    fail "Config file not found at $CONFIG_FILE"
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
    if [ "$SLOT_MEMORY_BYTES" -lt "$RUNNER_FLOOR_BYTES" ] || [ "$SLOT_MEMORY_BYTES" -gt "$EXPECTED_MEMORY_BYTES" ]; then
        fail "slot $SLOT_NAME memory limit $SLOT_MEMORY_BYTES out of bounds: expected between $RUNNER_FLOOR_BYTES and $EXPECTED_MEMORY_BYTES bytes"
    fi
    if [ "$SLOT_MEMORY_SWAP_BYTES" -lt "$RUNNER_FLOOR_BYTES" ] || [ "$SLOT_MEMORY_SWAP_BYTES" -gt "$EXPECTED_MEMORY_BYTES" ]; then
        fail "slot $SLOT_NAME memory-swap limit $SLOT_MEMORY_SWAP_BYTES out of bounds: expected between $RUNNER_FLOOR_BYTES and $EXPECTED_MEMORY_BYTES bytes"
    fi
    if [ "$SLOT_NANO_CPUS" -ne "$EXPECTED_NANO_CPUS" ]; then
        if [ "$SLOT_CPU_QUOTA" -le 0 ] || [ "$SLOT_CPU_PERIOD" -le 0 ]; then
            fail "slot $SLOT_NAME CPU enforcement unavailable: HostConfig.NanoCpus=${SLOT_NANO_CPUS}, CPUQuota=${SLOT_CPU_QUOTA}, CPUPeriod=${SLOT_CPU_PERIOD}"
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
    if ! runner_has_worker_process "$SLOT_NAME"; then
        fail "slot $SLOT_NAME is not executing Runner.Worker/Listener"
    fi
    EXPECTED_RUNNING=$((EXPECTED_RUNNING + 1))
done

if [ "$EXPECTED_RUNNING" -ne "$COUNT" ]; then
    fail "Fleet execution check failed: expected $COUNT running slots with Worker process, saw $EXPECTED_RUNNING"
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
SLOT_COUNT=$(grep -c '=' "$SLOT_FILE_STATE_DIR/slot_assignments.toml" 2>/dev/null || echo 0)

if [ "$CONTAINER_COUNT" -lt "$COUNT" ] || [ "$SLOT_COUNT" -lt "$COUNT" ]; then
    fail "Local fleet reconciliation evidence incomplete: containers=$CONTAINER_COUNT, slot file entries=$SLOT_COUNT, target=$COUNT"
fi

pass "Gate 3: Full local per-slot execution and envelope enforcement proof passed (slots=$COUNT, per-slot workers=$EXPECTED_RUNNING)"

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
