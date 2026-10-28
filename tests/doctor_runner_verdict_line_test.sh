#!/usr/bin/env bash
# regression test: the verdict headline line must derive its counts from the
# per-slot LOCAL+REMOTE truth (section 9 EXECUTING_SLOTS/IDLE_SLOTS/
# DOWN_SLOTS/CYCLING_SLOTS + section 10 REMOTE_*_SLOTS, both already
# 2-sample/ssh-verified ground truth), never the GitHub API's
# online/total/busy counts or the Mac-LOCAL-ONLY container count --
# ez-gh-actions-5u3s.
#
# Root cause this guards against: the prior verdict line was
#   ok "fleet healthy: $ONLINE/$TOTAL runners online, $BUSY busy, \
#       $CONTAINER_COUNT containers up, $LOOP_FAILS loop errors"
# which mixed a GitHub-API-sourced $ONLINE/$TOTAL/$BUSY (untrustworthy under
# the secondary rate limit -- the SAME fleet was reported as 7/11/16/19/22
# across calls minutes apart, see repo CLAUDE.md "Fleet capacity standard")
# with a Mac-LOCAL-ONLY $CONTAINER_COUNT (blind to the other host's half of
# the two-host fleet), and never consulted the per-slot arrays that are the
# actual ground truth.
#
# This test extracts the ACTUAL compute_verdict_summary() function from
# doctor-runner (via sed, not a re-implementation) so it can't silently
# drift from the real logic, then exercises it against fixture per-slot
# counts covering:
#   (a) local+remote executing/idle-ok, no starvation, no down -> totals
#       aggregate both hosts correctly.
#   (b) starvation present -> idle slots reclassify from idle-ok to
#       idle-starved (not silently dropped).
#   (c) down slots (local + remote) counted in the down bucket, and the
#       cycling slots (mid-respawn, journal-confirmed) get their own
#       cycling bucket -- NOT folded into executing. The prior code
#       conflated cycling into executing, which inflated the executing
#       bucket with slots that have no Runner.Worker pid (a cycling slot
#       is containerless by definition).
#   (d) unreachable-remote case (regression test for PR #64 follow-up):
#       when the remote host is unreachable, its slots are not proven
#       EXECUTING/IDLE; they must appear in the headline `down` bucket so
#       `configured` stays at the full expected fleet size (not local-only)
#       and the verdict cannot silently green.
#
# Usage: bash tests/doctor_runner_verdict_line_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

# Extract the real compute_verdict_summary() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate -- keeps the test honest against code drift.
FUNC_START=$(grep -n '^compute_verdict_summary() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate compute_verdict_summary() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
FUNC_END=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_START + FUNC_END - 1))
FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")

# Assert the old API-count-mixed verdict line is actually gone (not just
# supplemented) -- the defect this fix targets was a headline verdict line
# that named $ONLINE/$TOTAL/$BUSY/$CONTAINER_COUNT together as if they were
# one consistent measurement; if that exact combination is still the
# headline ok() call, the scope-mixing defect is still reachable regardless
# of what else we added.
if grep -q 'ok "fleet healthy: \$ONLINE/\$TOTAL runners online' "$DOCTOR_SCRIPT"; then
  echo "FAIL: old API-count/container-count mixed verdict line still present in $DOCTOR_SCRIPT (should be replaced, not just supplemented)" >&2
  exit 1
fi

# Assert the new verdict line consults the per-slot arrays (not a fresh
# docker/API sample) by checking the call site passes the section-9/10
# arrays as arguments.
if ! grep -q 'compute_verdict_summary \\' "$DOCTOR_SCRIPT"; then
  echo "FAIL: compute_verdict_summary call site not found in $DOCTOR_SCRIPT" >&2
  exit 1
fi

# Assert P1 #1: cycling is NOT folded into executing. The pre-fix code had
# `executing=$((l_exec + r_exec + l_cyc + r_cyc))` -- a cycling slot
# (containerless, mid-respawn) was silently counted as executing. The
# fix renames the buckets so cycling is its own count and only true
# EXECUTING slots contribute to executing.
if grep -q 'local executing=$((l_exec + r_exec + l_cyc + r_cyc))' "$DOCTOR_SCRIPT" \
   || grep -q 'executing=$((l_exec + r_exec + l_cyc + r_cyc))' "$DOCTOR_SCRIPT"; then
  echo "FAIL: cycling is still folded into executing in compute_verdict_summary -- P1 #1 regression" >&2
  exit 1
fi

run_case() {
  local label="$1" l_exec="$2" l_idle="$3" l_down="$4" l_cyc="$5" \
        r_exec="$6" r_idle="$7" r_down="$8" r_cyc="$9" starved="${10}" \
        exp_total="${11}" exp_configured="${12}" exp_exec="${13}" \
        exp_idle_ok="${14}" exp_idle_starved="${15}" exp_down="${16}" \
        exp_cycling="${17}"

  eval "$FUNC_SRC"

  local out total configured executing idle_ok idle_starved down cycling
  out=$(compute_verdict_summary "$l_exec" "$l_idle" "$l_down" "$l_cyc" \
                                 "$r_exec" "$r_idle" "$r_down" "$r_cyc" "$starved")
  read -r total configured executing idle_ok idle_starved down cycling <<< "$out"

  local pass=true
  [ "$total" -eq "$exp_total" ] || pass=false
  [ "$configured" -eq "$exp_configured" ] || pass=false
  [ "$executing" -eq "$exp_exec" ] || pass=false
  [ "$idle_ok" -eq "$exp_idle_ok" ] || pass=false
  [ "$idle_starved" -eq "$exp_idle_starved" ] || pass=false
  [ "$down" -eq "$exp_down" ] || pass=false
  [ "$cycling" -eq "$exp_cycling" ] || pass=false

  if [ "$pass" = "true" ]; then
    echo "  [$label] total=$total configured=$configured executing=$executing cycling=$cycling idle_ok=$idle_ok idle_starved=$idle_starved down=$down -- PASS"
    return 0
  else
    echo "  [$label] got: total=$total configured=$configured executing=$executing cycling=$cycling idle_ok=$idle_ok idle_starved=$idle_starved down=$down" \
         "| expected: total=$exp_total configured=$exp_configured executing=$exp_exec cycling=$exp_cycling idle_ok=$exp_idle_ok idle_starved=$exp_idle_starved down=$exp_down -- FAIL"
    return 1
  fi
}

echo "--- doctor-runner verdict-line summary regression ---"
OVERALL_PASS=true

# Case (a): 14 local (12 executing + 2 idle, no starvation, matching the
# current 14-Linux contract) + 6 remote (6 executing, current
# 6-Mac contract) = 20 configured. The two idle slots are IDLE-OK when the
# queue is not starved, so the live-slot gate keeps this healthy.
run_case "local18exec-2idle-remote4exec-bucket-math" \
  18 2 0 0  4 0 0 0  0 \
  24 24 22 2 0 0 0 || OVERALL_PASS=false

# Case (b): same as (a) but starvation present -- the 2 local idle slots
# must reclassify from idle-ok to idle-starved, not vanish.
run_case "local18exec-2idle-remote4exec-starved" \
  18 2 0 0  4 0 0 0  1 \
  24 24 22 0 2 0 0 || OVERALL_PASS=false

# Case (c): 2 local DOWN + 1 remote DOWN, 1 local CYCLING (mid-respawn,
# journal-confirmed). PROVES the fix: cycling is its own bucket, NOT
# silently added to executing (pre-fix would have read executing=17
# including the 1 cycling; correct reading is executing=16 and
# cycling=1).
run_case "local-2down-1cycling-remote-1down" \
  12 2 2 1  4 1 1 0  0 \
  23 23 16 3 0 3 1 || OVERALL_PASS=false

# Case (d): unreachable-remote regression (P1 #2 from PR #64 cold review).
# Remote host unreachable -> 4 remote slots are UNPROVEN, so they
# contribute as DOWN. `configured` must stay at the full 24 (NOT collapse
# to local-only 20), and `down` must include all 4 unreachable slots.
# Fleet-capacity numbers match this repo's CURRENT CLAUDE.md contract
# (20 Linux + 4 Mac = 24), not the prior 14 Linux + 6 Mac = 20 contract.
# This mirrors what doctor-runner now does at the unreachable branch:
# it synthesizes REMOTE_DOWN_SLOTS entries so the verdict gate sees
# REMOTE_COUNT down slots. Driving this through compute_verdict_summary
# directly proves the math doesn't silently lose the unreachable half
# of the fleet.
run_case "local-20exec-remote-unreachable-4down" \
  20 0 0 0  0 0 4 0  0 \
  24 24 20 0 0 4 0 || OVERALL_PASS=false

# API proof regression (jleechan-6vlf). Exercise extracted production sections,
# including their final exit status, with no Docker, SSH, or provider access.
SCRATCH="${DOCTOR_WORKER_OUTPUT:-${DISKM_SCRATCH:-${TMPDIR:-/tmp}}}"
API_TMP=$(mktemp -d "$SCRATCH/verdict-api.XXXXXX")
mkdir -p "$API_TMP/bin"
cat > "$API_TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  *orgs/*/actions/runners*) target=runners; json='{"runners":[{"name":"ez-runner-c-1","status":"online","busy":true}]}' ;;
  *workflow\ run*) target=dispatch; json='' ;;
  *run\ view*) target=view; json='{"status":"completed","conclusion":"success"}' ;;
  *run\ list*)
    target=recent; json='[{"databaseId":3}]'
    if [[ "$*" == *'-L 1 '* ]]; then
      if [ -f "$FAKE_STATE" ]; then target=poll; json='[{"databaseId":2}]'
      else target=baseline; json='[{"databaseId":1}]'; touch "$FAKE_STATE"; fi
    fi ;;
  *actions/runs\?*)
    target=mapruns; json='{"workflow_runs":[]}'
    if [ "$FAKE_TARGET" = mapjobs ]; then
      json='{"workflow_runs":[{"id":4,"html_url":"https://example.invalid/run/4","created_at":"2099-01-01T00:00:00Z"}]}'
    fi ;;
  *actions/runs/4/jobs*) target=mapjobs; json='{"jobs":[{"status":"in_progress","name":"test","runner_name":"ez-runner-c-1","html_url":"https://example.invalid/job/4","created_at":"2099-01-01T00:00:00Z","started_at":"2099-01-01T00:00:01Z"}]}' ;;
  *actions/runs/*/jobs*) target=jobs; json='{"jobs":[{"runner_name":"ez-runner-c-1","conclusion":"success"}]}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
if [ "$FAKE_TARGET" = "$target" ]; then
  case "$FAKE_REPLY" in
    error) echo 'gh: HTTP 403: API rate limit exceeded' >&2; exit 1 ;;
    partial) printf '%s\n' "$json"; echo 'gh: HTTP 403: partial response' >&2; exit 1 ;;
    long_error) printf '%02000d\n' 0; echo 'gh: HTTP 403: partial response' >&2; exit 1 ;;
    malformed) echo 'not JSON'; exit 0 ;;
    schema) echo '{}'; exit 0 ;;
    missing_runner) json=$(printf '%s' "$json" | jq 'del(.jobs[0].runner_name)') ;;
    unknown_status) json=$(printf '%s' "$json" | jq '.jobs[0].status = "nonsense"') ;;
    invalid_runner) json=$(printf '%s' "$json" | jq '.jobs[0].runner_name = 42') ;;
    missing_name) json=$(printf '%s' "$json" | jq 'del(.jobs[0].name)') ;;
    missing_started) json=$(printf '%s' "$json" | jq 'del(.jobs[0].started_at)') ;;
    invalid_started) json=$(printf '%s' "$json" | jq '.jobs[0].started_at = 42') ;;
    queued_null) json=$(printf '%s' "$json" | jq '.jobs[0] |= (.status = "queued" | .runner_name = null | .started_at = null)') ;;
    queued_empty) json=$(printf '%s' "$json" | jq '.jobs[0] |= (.status = "queued" | .runner_name = "" | .started_at = null)') ;;
    status_*) json=$(printf '%s' "$json" | jq --arg status "${FAKE_REPLY#status_}" '.jobs[0].status = $status') ;;
    empty)
      case "$target" in
        runners) json='{"runners":[]}' ;;
        recent) json='[]' ;;
        jobs) json='{"jobs":[]}' ;;
      esac ;;
    pages) printf '%s\n' "$json" "$json"; exit 0 ;;
  esac
fi
printf '%s\n' "$json"
SH
chmod +x "$API_TMP/bin/gh"
# Fail closed if a future extraction accidentally reaches local probe commands.
for tool in docker ssh; do
  printf '#!/usr/bin/env bash\necho "UNEXPECTED LIVE PROBE" >&2\nexit 99\n' > "$API_TMP/bin/$tool"
  chmod +x "$API_TMP/bin/$tool"
done

HARNESS="$API_TMP/harness.sh"
cat > "$HARNESS" <<'SH'
set -euo pipefail
section() { :; }; info() { echo "INFO $*"; }; ok() { echo "OK $*"; }
warn() { echo "WARN $*"; }; bad() { echo "BAD $*"; }
sleep() { :; }
read_config_runner_count() { echo 20; }
emit_failure_remediation() { echo "FAILURE critical=$1"; }
ORG=test; EZGHA_REPO=test/repo; RUNNER_NAME_PREFIX=ez-runner-c
PLATFORM=linux; EXPLICIT_WORK_REPOS=test/repo
SERVICE_STATE=active; COLIMA_STATUS=NotInstalled
LOCAL_CONFIG_FILE=unused; SLOT_FILE=unused; DEFAULT_CONFIGURED_COUNT=20
LOCAL_COUNT=20; REMOTE_COUNT=4; CONTAINER_COUNT=20
LOOP_FAILS=4; LOOP_WINDOW=3; QUEUE_TAIL_WARN_MIN=20
QUEUE_TAIL_BAD=0; QUEUE_RC=0; HOST_LIFECYCLE_CRITICAL=0
GH_TOKEN_STALE_CRITICAL=0; SLOT_PROOF_CRITICAL=0
EXECUTING_SLOTS=(); IDLE_SLOTS=(); DOWN_SLOTS=(); CYCLING_SLOTS=()
REMOTE_EXECUTING_SLOTS=(m1 m2 m3 m4)
REMOTE_IDLE_SLOTS=(); REMOTE_DOWN_SLOTS=(); REMOTE_CYCLING_SLOTS=()
for n in $(seq 1 20); do EXECUTING_SLOTS+=("c$n"); done
case "$LOCAL_STATE" in
  down) unset 'EXECUTING_SLOTS[19]'; DOWN_SLOTS=(c20); SLOT_PROOF_CRITICAL=1 ;;
  starved) unset 'EXECUTING_SLOTS[19]'; IDLE_SLOTS=(c20); SLOT_PROOF_CRITICAL=1 ;;
  queue_unknown) QUEUE_RC=2; QUEUE_TAIL_BAD=1 ;;
esac
SH
{
  sed -n '/^API_UNVERIFIED=0$/,/^# --- end GitHub response helper/p' "$DOCTOR_SCRIPT"
  sed -n '/^# --- C\. GitHub-side/,/^# --- D\. live docker/p' "$DOCTOR_SCRIPT" | sed '$d'
  sed -n '/^section "7\. real job/,/^# --- F1b\./p' "$DOCTOR_SCRIPT" | sed '$d'
  sed -n '/^EXPLICIT_WORK_REPOS=/,/^# --- F2\./p' "$DOCTOR_SCRIPT" | sed '$d'
  printf '%s\n' 'printf "JOBMAP queued=%s errors=%s\n" "$JOBLEVEL_QUEUED_COUNT" "$JOBLEVEL_FETCH_ERRORS"'
  sed -n '/^CRITICAL=0$/,$p' "$DOCTOR_SCRIPT"
} >> "$HARNESS"
bash -n "$HARNESS"

api_case() {
  local target="$1" reply="$2" expected="$3" local_state="${4:-healthy}" prove="${5:-0}"
  local label="$target-$reply-$local_state-prove$prove" rc=0 out
  out="$API_TMP/$label.log"
  # Distinct state per case; the fake canary baseline and poll cannot collide.
  PATH="$API_TMP/bin:$PATH" TMPDIR="$API_TMP" FAKE_STATE="$API_TMP/$label.state" \
    FAKE_TARGET="$target" FAKE_REPLY="$reply" LOCAL_STATE="$local_state" PROVE="$prove" \
    bash "$HARNESS" > "$out" 2>&1 || rc=$?
  if [ "$rc" -ne "$expected" ] || grep -q 'UNEXPECTED LIVE PROBE' "$out"; then
    echo "FAIL: $label rc=$rc expected=$expected"; cat "$out"; OVERALL_PASS=false; return
  fi
  if [ "$expected" -eq 2 ]; then
    if ! grep -q 'verdict: UNVERIFIED' "$out" ||
       grep -Eq 'fleet healthy:|runners-online gate FAILED|real-execution gate FAILED|canary gate FAILED|total=0 online=0' "$out"; then
      echo "FAIL: $label fabricated proof/failure"; cat "$out"; OVERALL_PASS=false; return
    fi
    if [[ "$reply" = *error ]] && ! grep -q 'HTTP 403' "$out"; then
      echo "FAIL: $label lost actual error"; OVERALL_PASS=false; return
    fi
    if [ "$target" = mapjobs ] && ! grep -q 'JOBMAP .*errors=[1-9]' "$out"; then
      echo "FAIL: $label missing job-map failure ledger entry"; OVERALL_PASS=false; return
    fi
  elif [ "$expected" -eq 0 ]; then
    grep -q 'fleet healthy: 24/24' "$out" || { echo "FAIL: $label missing local truth"; OVERALL_PASS=false; return; }
    if [[ "$reply" = queued_* ]] && ! grep -q 'JOBMAP queued=1 errors=0' "$out"; then
      echo "FAIL: $label unassigned queued job was dropped"; OVERALL_PASS=false; return
    fi
  elif [ "$local_state" != healthy ]; then
    grep -q 'per-slot execution-proof gate FAILED' "$out" || { echo "FAIL: $label lost local failure"; OVERALL_PASS=false; return; }
  else
    grep -q 'gate FAILED' "$out" || { echo "FAIL: $label empty response did not fail"; OVERALL_PASS=false; return; }
  fi
  echo "PASS: $label exit=$rc"
}

for target in runners recent jobs mapruns mapjobs; do
  for reply in error malformed schema; do api_case "$target" "$reply" 2; done
done
api_case runners partial 2
api_case runners long_error 2
api_case recent pages 2
api_case jobs pages 2
for target in runners recent jobs; do api_case "$target" empty 1; done
api_case none healthy 0
api_case mapjobs healthy 0
for reply in missing_runner unknown_status invalid_runner missing_name missing_started invalid_started; do
  api_case mapjobs "$reply" 2
done
api_case mapjobs missing_runner 1 down
api_case mapjobs unknown_status 1 starved
api_case mapjobs queued_null 0
api_case mapjobs queued_empty 0
for status in queued in_progress completed waiting requested pending; do api_case mapjobs "status_$status" 0; done
api_case runners pages 0
api_case none healthy 2 queue_unknown
api_case runners error 1 down
api_case runners error 1 starved
for target in baseline dispatch poll view jobs; do
  api_case "$target" error 2 healthy 1
  if [ "$target" != dispatch ]; then api_case "$target" malformed 2 healthy 1; fi
done
api_case none healthy 0 healthy 1

echo "API receipts: $API_TMP"
echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
