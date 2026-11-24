#!/usr/bin/env bash
# Regression test: queued jobs targeting an intentionally parked leg
# (MAC_RUNNER_DISABLED=1 or REMOTE_LINUX_DISABLED=1) must be excluded from
# JOBLEVEL_QUEUED_COUNT and JOBLEVEL_OLDEST_QUEUED_MIN so they do not trigger
# false QUEUE_TAIL_BAD=1 or IDLE-STARVED [BAD] verdicts on the active leg.
# Generic or empty-labeled jobs must NEVER be excluded.
#
# Usage: bash tests/doctor_runner_parked_leg_queue_test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

[ -f "$DOCTOR_SCRIPT" ] || { echo "FAIL: doctor-runner not found at $DOCTOR_SCRIPT" >&2; exit 1; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR:?}"' EXIT

# Extract real production blocks from doctor-runner (never a reimplementation).
F1B_START=$(grep -n '^iso_elapsed_min() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
F1B_END=$(grep -n '^# Count fetch failures' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
[ -n "$F1B_START" ] && [ -n "$F1B_END" ] || {
  echo "FAIL: could not locate section-F1b job-index block in $DOCTOR_SCRIPT" >&2
  exit 1
}
F1B_SRC=$(sed -n "${F1B_START},$((F1B_END - 1))p" "$DOCTOR_SCRIPT")

STARVE_START=$(grep -n '^IDLE_STARVED_THRESHOLD_MIN=' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
STARVE_END=$(grep -n '^\[ "${#EXECUTING_SLOTS\[@\]}" -gt 0 \]' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
[ -n "$STARVE_START" ] && [ -n "$STARVE_END" ] || {
  echo "FAIL: could not locate section-9 starvation block in $DOCTOR_SCRIPT" >&2
  exit 1
}
STARVE_SRC=$(sed -n "${STARVE_START},$((STARVE_END - 1))p" "$DOCTOR_SCRIPT")

SEC10_START=$(grep -n '^SECTION10_DOWN_RESAMPLE_SECONDS=' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
SEC10_END=$(grep -n '^job_evidence_for_runner() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
[ -n "$SEC10_START" ] && [ -n "$SEC10_END" ] || {
  echo "FAIL: could not locate section-10 job-map summary block in $DOCTOR_SCRIPT" >&2
  exit 1
}
SEC10_SRC=$(sed -n "${SEC10_START},$((SEC10_END - 1))p" "$DOCTOR_SCRIPT")

# Dynamic UTC timestamps so fixtures remain fresh (< STALE_HOURS=8h) and
# meaningfully older/newer than thresholds (QUEUE_TAIL_WARN_MIN=20, IDLE_STARVED_THRESHOLD_MIN=5).
TS_OLD=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=45)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
TS_RECENT=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/fixtures"
cat > "$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != "api" ]; then
  echo "unexpected gh subcommand: $*" >&2
  exit 1
fi
path="${2:-}"
case "$path" in
  repos/*/actions/runs\?status=queued*)
    cat "$FIXTURE_DIR/runs_queued.json"
    ;;
  repos/*/actions/runs\?status=in_progress*)
    if [ -f "$FIXTURE_DIR/runs_in_progress.json" ]; then
      cat "$FIXTURE_DIR/runs_in_progress.json"
    else
      echo '{"workflow_runs": [], "total_count": 0}'
    fi
    ;;
  repos/*/actions/runs/*/jobs*)
    rid="${path##*/runs/}"
    rid="${rid%%/jobs*}"
    cat "$FIXTURE_DIR/jobs_${rid}.json"
    ;;
  *)
    echo "unexpected gh api path: $path" >&2
    exit 1
    ;;
esac
SH
chmod +x "$TMP_DIR/bin/gh"

run_case() {
  local label="$1" platform="$2" mac_off="$3" linux_off="$4" runs_json="$5" jobs_setup_fn="$6"
  local case_dir="$TMP_DIR/case_${label}"
  mkdir -p "$case_dir"
  printf '%s\n' "$runs_json" > "$case_dir/runs_queued.json"
  echo '{"workflow_runs": [], "total_count": 0}' > "$case_dir/runs_in_progress.json"
  "$jobs_setup_fn" "$case_dir"

  (
    set -euo pipefail
    export PATH="$TMP_DIR/bin:$PATH"
    export FIXTURE_DIR="$case_dir"
    export PLATFORM="$platform"
    export MAC_RUNNER_DISABLED="$mac_off"
    export REMOTE_LINUX_DISABLED="$linux_off"
    export EZGHA_APP_TOKEN_AVAILABLE=1
    export EXPLICIT_WORK_REPOS="jleechanorg/ez-gh-actions"
    export QUEUE_REPO="jleechanorg/ez-gh-actions"
    export QUEUE_TAIL_WARN_MIN=20
    export IDLE_STARVED_THRESHOLD_MIN=5
    export STALE_HOURS=8
    export SCRIPT_DIR="$REPO_ROOT"

    section() { printf '=== %s ===\n' "$*"; }
    ok() { printf '  [OK]   %s\n' "$*"; }
    warn() { printf '  [WARN] %s\n' "$*"; }
    bad() { printf '  [BAD]  %s\n' "$*"; }
    info() { printf '  [..]   %s\n' "$*"; }

    RUNNER_JOB_INDEX_FILE="$case_dir/job_index.json"
    JOBMAP_ERRORS_FILE="$case_dir/job_errors.log"
    : > "$JOBMAP_ERRORS_FILE"

    eval "$F1B_SRC"

    JOBLEVEL_FETCH_ERRORS=0
    QUEUE_TAIL_BAD=0
    QUEUE_RC=0
    set +e
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/queue-health.sh" || QUEUE_RC=$?
    set -e
    [ "${QUEUE_RC:-0}" -eq 1 ] && QUEUE_TAIL_BAD=1

    DOWN_SLOTS=()
    IDLE_SLOTS=("ez-runner-c-1" "ez-runner-c-2")
    EXECUTING_SLOTS=()
    CYCLING_SLOTS=()
    RESPAWN_FETCH_FAILED_LOCAL=0

    eval "$STARVE_SRC"
    eval "$SEC10_SRC"

    echo "RESULT queued=${JOBLEVEL_QUEUED_COUNT:-unset} parked=${JOBLEVEL_PARKED_QUEUED_COUNT:-unset} tail_bad=${QUEUE_TAIL_BAD:-unset} starved=${STARVED_PRESENT:-unset} critical=${SLOT_PROOF_CRITICAL:-unset}"
  ) 2>&1
}

FAIL=0
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! grep -Fq -- "$needle" <<< "$haystack"; then
    echo "FAIL [$label]: expected output to contain: $needle" >&2
    FAIL=1
  fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if grep -Fq -- "$needle" <<< "$haystack"; then
    echo "FAIL [$label]: did NOT expect output to contain: $needle" >&2
    FAIL=1
  fi
}

# Case A: MAC_RUNNER_DISABLED=1 + 2 old self-hosted-macos queued jobs + idle Linux slots
# -> NOT QUEUE_TAIL_BAD, NOT IDLE-STARVED, logs excluded parked-leg queued jobs.
setup_case_a() {
  local d="$1"
  cat > "$d/jobs_101.json" <<JSON
{"jobs":[
  {"name":"Mac virtiofs canary","status":"queued","runner_name":null,"html_url":"https://example.test/101/1","started_at":null,"created_at":"$TS_OLD","labels":["self-hosted","ezgha","self-hosted-macos"]},
  {"name":"Mac UI smoke","status":"queued","runner_name":null,"html_url":"https://example.test/101/2","started_at":null,"created_at":"$TS_OLD","labels":["self-hosted","macOS"]}
]}
JSON
}
RUNS_A="{\"workflow_runs\":[{\"id\":101,\"name\":\"Mac virtiofs canary\",\"head_branch\":\"main\",\"html_url\":\"https://example.test/runs/101\",\"created_at\":\"$TS_OLD\"}]}"
out_a=$(run_case "caseA" "linux" "1" "0" "$RUNS_A" setup_case_a)
echo "--- Case A ---"
echo "$out_a"
assert_contains "Case A counts" "$out_a" "RESULT queued=0 parked=2 tail_bad=0 starved=0 critical=0"
assert_not_contains "Case A no IDLE-STARVED" "$out_a" "IDLE-STARVED"
assert_contains "Case A IDLE-OK" "$out_a" "IDLE-OK (nothing queued)"
assert_contains "Case A parked-leg log" "$out_a" "excluded 2 queued job(s) targeting an intentionally parked leg"

# Case B: MAC_RUNNER_DISABLED=1 + 1 old [self-hosted, self-hosted-mikey, Linux] queued job + idle Linux slots
# -> STILL fails QUEUE_TAIL_BAD / IDLE-STARVED.
setup_case_b() {
  local d="$1"
  cat > "$d/jobs_102.json" <<JSON
{"jobs":[
  {"name":"Linux CI","status":"queued","runner_name":null,"html_url":"https://example.test/102/1","started_at":null,"created_at":"$TS_OLD","labels":["self-hosted","self-hosted-mikey","Linux"]}
]}
JSON
}
RUNS_B="{\"workflow_runs\":[{\"id\":102,\"name\":\"CI\",\"head_branch\":\"main\",\"html_url\":\"https://example.test/runs/102\",\"created_at\":\"$TS_OLD\"}]}"
out_b=$(run_case "caseB" "linux" "1" "0" "$RUNS_B" setup_case_b)
echo "--- Case B ---"
echo "$out_b"
assert_contains "Case B counts" "$out_b" "RESULT queued=1 parked=0 tail_bad=1 starved=1 critical=2"
assert_contains "Case B IDLE-STARVED" "$out_b" "[BAD]  IDLE-STARVED"

# Case C: MAC_RUNNER_DISABLED=0 + 1 old self-hosted-macos queued job
# -> STILL counted as active queued job (not excluded when not parked).
setup_case_c() {
  local d="$1"
  cat > "$d/jobs_103.json" <<JSON
{"jobs":[
  {"name":"Mac virtiofs canary","status":"queued","runner_name":null,"html_url":"https://example.test/103/1","started_at":null,"created_at":"$TS_OLD","labels":["self-hosted","ezgha","self-hosted-macos"]}
]}
JSON
}
RUNS_C="{\"workflow_runs\":[{\"id\":103,\"name\":\"Mac virtiofs canary\",\"head_branch\":\"main\",\"html_url\":\"https://example.test/runs/103\",\"created_at\":\"$TS_OLD\"}]}"
out_c=$(run_case "caseC" "linux" "0" "0" "$RUNS_C" setup_case_c)
echo "--- Case C ---"
echo "$out_c"
assert_contains "Case C counts" "$out_c" "RESULT queued=1 parked=0 tail_bad=1 starved=1 critical=2"
assert_contains "Case C IDLE-STARVED" "$out_c" "[BAD]  IDLE-STARVED"

# Case D: Generic labels [self-hosted, self-hosted-mikey] and empty labels [] with MAC_RUNNER_DISABLED=1
# -> STILL counted as active queued jobs.
setup_case_d() {
  local d="$1"
  cat > "$d/jobs_104.json" <<JSON
{"jobs":[
  {"name":"Generic self-hosted","status":"queued","runner_name":null,"html_url":"https://example.test/104/1","started_at":null,"created_at":"$TS_OLD","labels":["self-hosted","self-hosted-mikey"]},
  {"name":"Unlabeled job","status":"queued","runner_name":null,"html_url":"https://example.test/104/2","started_at":null,"created_at":"$TS_OLD","labels":[]}
]}
JSON
}
RUNS_D="{\"workflow_runs\":[{\"id\":104,\"name\":\"Generic CI\",\"head_branch\":\"main\",\"html_url\":\"https://example.test/runs/104\",\"created_at\":\"$TS_OLD\"}]}"
out_d=$(run_case "caseD" "linux" "1" "0" "$RUNS_D" setup_case_d)
echo "--- Case D ---"
echo "$out_d"
assert_contains "Case D counts" "$out_d" "RESULT queued=2 parked=0 tail_bad=1 starved=1 critical=2"
assert_contains "Case D IDLE-STARVED" "$out_d" "[BAD]  IDLE-STARVED"

# Case E: Mixed queue (2 old parked Mac jobs + 1 recent 2m Linux job) -> active oldest is 2m (< 5m, < 20m)
setup_case_e() {
  local d="$1"
  cat > "$d/jobs_105.json" <<JSON
{"jobs":[
  {"name":"Mac virtiofs canary","status":"queued","runner_name":null,"html_url":"https://example.test/105/1","started_at":null,"created_at":"$TS_OLD","labels":["self-hosted","self-hosted-macos"]},
  {"name":"Mac runner job","status":"queued","runner_name":null,"html_url":"https://example.test/105/2","started_at":null,"created_at":"$TS_OLD","labels":["ez-mac-runner"]},
  {"name":"Recent Linux CI","status":"queued","runner_name":null,"html_url":"https://example.test/105/3","started_at":null,"created_at":"$TS_RECENT","labels":["self-hosted-linux"]}
]}
JSON
}
RUNS_E="{\"workflow_runs\":[{\"id\":105,\"name\":\"Mixed CI\",\"head_branch\":\"main\",\"html_url\":\"https://example.test/runs/105\",\"created_at\":\"$TS_OLD\"}]}"
out_e=$(run_case "caseE" "linux" "1" "0" "$RUNS_E" setup_case_e)
echo "--- Case E ---"
echo "$out_e"
assert_contains "Case E counts" "$out_e" "RESULT queued=1 parked=2 tail_bad=0 starved=0 critical=0"
assert_not_contains "Case E no IDLE-STARVED" "$out_e" "IDLE-STARVED"
assert_contains "Case E parked-leg log" "$out_e" "excluded 2 queued job(s) targeting an intentionally parked leg"

# Case F: REMOTE_LINUX_DISABLED=1 on macOS + old self-hosted-linux / ez-runner-c jobs -> excluded
setup_case_f() {
  local d="$1"
  cat > "$d/jobs_106.json" <<JSON
{"jobs":[
  {"name":"Linux fleet job","status":"queued","runner_name":null,"html_url":"https://example.test/106/1","started_at":null,"created_at":"$TS_OLD","labels":["self-hosted","self-hosted-linux"]},
  {"name":"Linux prefix job","status":"queued","runner_name":null,"html_url":"https://example.test/106/2","started_at":null,"created_at":"$TS_OLD","labels":["ez-runner-c"]}
]}
JSON
}
RUNS_F="{\"workflow_runs\":[{\"id\":106,\"name\":\"Linux CI\",\"head_branch\":\"main\",\"html_url\":\"https://example.test/runs/106\",\"created_at\":\"$TS_OLD\"}]}"
out_f=$(run_case "caseF" "macos" "0" "1" "$RUNS_F" setup_case_f)
echo "--- Case F ---"
echo "$out_f"
assert_contains "Case F counts" "$out_f" "RESULT queued=0 parked=2 tail_bad=0 starved=0 critical=0"
assert_contains "Case F parked-leg log" "$out_f" "excluded 2 queued job(s) targeting an intentionally parked leg"

if [ "$FAIL" -eq 0 ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
