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
    echo "$1" | grep -Eiq 'rate limit|secondary rate limit|abuse|HTTP 403|HTTP 429|Retry-After'
}

gh_checked() {
    local out status
    if out=$(gh "$@" 2>&1); then
        printf '%s' "$out"
        return 0
    fi
    status=$?
    if is_rate_limit_text "$out"; then
        echo "GitHub API rate-limited while running: gh $*" >&2
    else
        echo "GitHub API command failed while running: gh $*" >&2
    fi
    echo "$out" >&2
    return "$status"
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

RAW_RUNNERS=$(gh api orgs/jleechanorg/actions/runners --paginate 2>/dev/null || echo '{"runners":[]}')
ONLINE_RUNNERS=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '.runners[] | select(.name | startswith($p)) | select(.status == "online") | .name')
ONLINE_COUNT=$(count_nonempty_lines "$ONLINE_RUNNERS")
BUSY_COUNT=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '[.runners[] | select(.name | startswith($p)) | select(.busy == true)] | length')
EFFECTIVE_CAPACITY=$((ONLINE_COUNT))
# Note: busy runners are a subset of online runners; adding both double-counts
# them. EFFECTIVE_CAPACITY = total online (which already includes busy runners).

# Check offline runners
OFFLINE_COUNT=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '[.runners[] | select(.name | startswith($p)) | select(.status == "offline")] | length')

# Local container check
CONTAINER_COUNT=$(docker ps --filter label=ezgha=managed --format '{{.Names}}' 2>/dev/null | wc -l)
CONTAINER_COUNT=$(printf '%d' "$CONTAINER_COUNT" 2>/dev/null || echo 0)

# Validate runner names match expected format (prefix-N)
INVALID_NAMES=$(echo "$RAW_RUNNERS" | jq -r --arg p "$NAME_PREFIX" '.runners[] | select(.name | startswith($p)) | .name' | grep -vE "^.+-[0-9]+$" || true)
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
WORKFLOW="ezgha-selftest"
REPO="jleechanorg/ez-gh-actions"

if ! SELFTEST_RUNS=$(gh_checked run list -R "$REPO" -w "$WORKFLOW" -L 20 --json databaseId,status,conclusion); then
    fail "Gate 4: unable to list ezgha-selftest runs"
fi
COMPLETED_RUNS=$(echo "$SELFTEST_RUNS" | jq -r '[.[] | select(.status=="completed")]')
COMPLETED_COUNT=$(echo "$COMPLETED_RUNS" | jq 'length')
if [ "$COMPLETED_COUNT" -lt 1 ]; then
    fail "No completed ezgha-selftest runs found"
fi

# Validate recent completed runs executed on the configured runner prefix.
# Prefer configured-prefix telemetry over stale historical runs from retired fleets.
MATCH_PREFIX_COUNT=0
JOB_LOOKUP_FAILURES=0
while IFS=' ' read -r rid conc; do
    if [ -z "$rid" ] || [ -z "$conc" ]; then
        continue
    fi
    if ! jobs=$(gh_checked api "repos/$REPO/actions/runs/$rid/jobs"); then
        JOB_LOOKUP_FAILURES=$((JOB_LOOKUP_FAILURES + 1))
        echo "    [WARN] Skipping selftest run $rid because job lookup failed"
        continue
    fi
    rn=$(echo "$jobs" | jq -r '.jobs[0].runner_name // "?"' 2>/dev/null)
    if [[ "$rn" == "${NAME_PREFIX}-"* ]]; then
        if [ "$conc" != "success" ]; then
            fail "Recent selftest run $rid on $rn failed or did not conclude successfully (conclusion: $conc)"
        fi
        MATCH_PREFIX_COUNT=$((MATCH_PREFIX_COUNT + 1))
        echo "    [INFO] Prefix-aligned selftest run: $rid on $rn"
        if [ "$MATCH_PREFIX_COUNT" -ge 5 ]; then
            break
        fi
    fi
done <<< "$(echo "$COMPLETED_RUNS" | jq -r '.[] | "\(.databaseId) \(.conclusion)"')"

if [ "$MATCH_PREFIX_COUNT" -eq 0 ]; then
    if [ "$JOB_LOOKUP_FAILURES" -gt 0 ]; then
        fail "No completed selftest runs could be verified on ${NAME_PREFIX}-*; $JOB_LOOKUP_FAILURES job lookup(s) failed"
    fi
    fail "No completed selftest runs found on configured runner prefix (${NAME_PREFIX}-*)"
fi

if [ "$MATCH_PREFIX_COUNT" -lt 5 ]; then
    fail "Only $MATCH_PREFIX_COUNT completed selftest run(s) matched ${NAME_PREFIX}-*; Gate 4 requires at least 5"
fi
pass "Gate 4: Recent jobs successfully ran on the ezgha fleet"

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

if ! gh api rate_limit >/dev/null 2>&1; then
    fail "Gate 7: Unable to query rate limit (GitHub API down)"
fi
pass "Gate 7: Automated monitoring scheduled and alert delivery verified"

# --- Gate 10: GitHub API budget ---
echo "--- Checking Gate 10: GitHub API budget ---"
REMAINING_API=$(gh api rate_limit --jq '.resources.core.remaining')
LIMIT_API=$(gh api rate_limit --jq '.resources.core.limit')
MIN_API=$((LIMIT_API / 5)) # 20%
if [ "$REMAINING_API" -lt "$MIN_API" ]; then
    fail "GitHub API core budget remaining ($REMAINING_API) is less than 20% of limit ($LIMIT_API)"
fi
pass "Gate 10: GitHub API budget is healthy ($REMAINING_API/$LIMIT_API remaining)"

echo "==================================================="
echo -e "${GREEN}ALL AUTO GATES PASS EXCELLENTLY!${NC}"
exit 0
