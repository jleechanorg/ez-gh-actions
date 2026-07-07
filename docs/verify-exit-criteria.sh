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

# --- Gate 0: Deployed code == committed code ---
echo "--- Checking Gate 0: Deployed code == committed code ---"
DEPLOYED_SHA=$(~/.cargo/bin/ezgha --version 2>/dev/null | cut -d'-' -f2 || echo "none")
CURRENT_SHA=$(git rev-parse --short HEAD)
if [ "$DEPLOYED_SHA" != "$CURRENT_SHA" ]; then
    fail "Deployed binary SHA ($DEPLOYED_SHA) does not match current HEAD Git SHA ($CURRENT_SHA). Run cargo install --path ."
fi

if [ -n "$(git status --porcelain | grep -v 'docs/observe' || true)" ]; then
    echo "Warning: local uncommitted changes exist outside docs/observe:"
    git status --porcelain | grep -v 'docs/observe' || true
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
# Parse runner.count from config.toml
CONFIG_FILE="$HOME/.config/ezgha/config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    fail "Config file not found at $CONFIG_FILE"
fi
COUNT=$(toml_get_runner count 2>/dev/null || grep -E 'count\s*=\s*' "$CONFIG_FILE" | head -1 | awk -F'=' '{print $2}' | tr -d '[:space:]')

# Read name_prefix from config (default: ez-org-runner)
NAME_PREFIX=$(toml_get_runner name_prefix ez-org-runner 2>/dev/null || echo 'ez-org-runner')

if [ -z "$COUNT" ]; then
    fail "Could not parse runner.count from $CONFIG_FILE"
fi

RAW_RUNNERS=$(gh_checked api orgs/jleechanorg/actions/runners --paginate --slurp) || fail "Unable to list GitHub runners after retries"
ONLINE_RUNNERS=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '.[]?.runners[]? | select(.name | startswith($p)) | select(.status == "online") | .name') || fail "Gate 3: Unable to parse GitHub runner list"
ONLINE_COUNT=$(count_nonempty_lines "$ONLINE_RUNNERS")
BUSY_COUNT=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '[.[]?.runners[]? | select(.name | startswith($p)) | select(.busy == true)] | length') || fail "Gate 3: Unable to parse busy runner count"
EFFECTIVE_CAPACITY=$((ONLINE_COUNT))
# Note: busy runners are a subset of online runners; adding both double-counts
# them. EFFECTIVE_CAPACITY = total online (which already includes busy runners).

# Check offline runners
OFFLINE_COUNT=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '[.[]?.runners[]? | select(.name | startswith($p)) | select(.status == "offline")] | length') || fail "Gate 3: Unable to parse offline runner count"

# Local container check
CONTAINER_COUNT=$(docker ps --filter label=ezgha=managed --format '{{.Names}}' 2>/dev/null | wc -l)
CONTAINER_COUNT=$(printf '%d' "$CONTAINER_COUNT" 2>/dev/null || echo 0)

# Validate runner names match expected format (prefix-N)
INVALID_NAMES=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '.[]?.runners[]? | select(.name | startswith($p)) | .name') || fail "Gate 3: Unable to parse runner names"
INVALID_NAMES=$(echo "$INVALID_NAMES" | grep -vE "^.+-[0-9]+$" || true)
if [ -n "$INVALID_NAMES" ]; then
    fail "Invalid runner names registered on GitHub:\n$INVALID_NAMES"
fi

# EFFECTIVE_CAPACITY is only a reliable signal when the fleet is quiescent.
# When runners are actively cycling through jobs, GitHub de-registers a runner
# the instant its container exits (--rm) and doesn't show the replacement until
# the new container connects — there is always a respawn-gap window where
# ONLINE_COUNT < COUNT. Only enforce the threshold when no runners are busy.
# The quiescent block below (BUSY_COUNT=0) already checks the strict threshold.
if [ "$BUSY_COUNT" -eq 0 ] && [ "$EFFECTIVE_CAPACITY" -lt "$((COUNT - 1))" ]; then
    fail "Effective capacity ($EFFECTIVE_CAPACITY) is lower than target COUNT-1 ($((COUNT - 1))) [quiescent fleet]"
fi


# Quiescent sample check: if no busy runners, online count must equal target count, and offline count must be zero
if [ "$BUSY_COUNT" -eq 0 ]; then
    if [ "$ONLINE_COUNT" -lt "$COUNT" ]; then
        fail "Fleet is quiescent but online count ($ONLINE_COUNT) < target count ($COUNT)"
    fi
    if [ "$OFFLINE_COUNT" -gt 0 ]; then
        fail "Fleet is quiescent but has $OFFLINE_COUNT offline runners registered"
    fi
fi

# Slot file count is the authoritative local measure: it persists across the
# respawn gap (container finishes job → auto-removed by --rm → slot still
# reserved → daemon respawns within 30s). An instantaneous 'docker ps' count
# is always wrong under high utilization and triggers false failures.
SLOT_COUNT=0
SLOT_FILE="$HOME/.config/ezgha/slot_assignments.toml"
if [ -f "$SLOT_FILE" ]; then
    SLOT_COUNT=$(grep -c '\.' "$SLOT_FILE" 2>/dev/null || echo 0)
    # slot file has one entry per reserved slot; count lines with '=' as a proxy
    SLOT_COUNT=$(grep -c '=' "$SLOT_FILE" 2>/dev/null || echo 0)
fi
# Fall back to docker ps only if slot file is absent/empty
if [ "$SLOT_COUNT" -eq 0 ]; then
    SLOT_COUNT="$CONTAINER_COUNT"
fi
if [ "$SLOT_COUNT" -lt "$((COUNT - 1))" ] && [ "$CONTAINER_COUNT" -lt "$((COUNT - 1))" ]; then
    fail "Local managed container count ($CONTAINER_COUNT) is lower than COUNT-1 ($((COUNT - 1))) and slot file has only $SLOT_COUNT reserved slots"
fi
pass "Gate 3: Fleet capacity meets targets (Effective capacity: $EFFECTIVE_CAPACITY, Containers: $CONTAINER_COUNT, Slots: $SLOT_COUNT)"

# --- Gate 4: Real job execution ---
echo "--- Checking Gate 4: Real job execution ---"
CANARY_TIMEOUT_SECONDS="${CANARY_TIMEOUT_SECONDS:-600}"
if ! CANARY_OUT=$(~/.cargo/bin/ezgha --config "$CONFIG_FILE" canary-once --timeout-seconds "$CANARY_TIMEOUT_SECONDS" 2>&1); then
    echo "$CANARY_OUT"
    fail "Gate 4: fresh nonce-tracked canary did not complete successfully on ${NAME_PREFIX}-*"
fi
echo "$CANARY_OUT"
CANARY_RUN_ID=$(echo "$CANARY_OUT" | jq -r '.run_id // empty' 2>/dev/null || true)
CANARY_RUNNER=$(echo "$CANARY_OUT" | jq -r '.runner_name // empty' 2>/dev/null || true)
CANARY_TTS=$(echo "$CANARY_OUT" | jq -r '.time_to_start_seconds // empty' 2>/dev/null || true)
if [ -z "$CANARY_RUN_ID" ] || [ -z "$CANARY_RUNNER" ]; then
    fail "Gate 4: canary output lacked run_id or runner_name"
fi
echo "    [INFO] Fresh canary run $CANARY_RUN_ID started on $CANARY_RUNNER in ${CANARY_TTS:-?}s"
pass "Gate 4: Fresh nonce-tracked canary ran successfully on the ezgha fleet"

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
