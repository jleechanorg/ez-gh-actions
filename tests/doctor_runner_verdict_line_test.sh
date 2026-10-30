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
mkdir -p "$API_TMP/bin" "$API_TMP/home/.config/ezgha"
printf 'synthetic-test-token\n' > "$API_TMP/home/.config/ezgha/gh_token"
# Synthetic contract fixtures; no live workflow or runner evidence is used.
if [ "$(uname -s)" = Darwin ]; then
  OLD_AT=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)
  TEN_AT=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)
  ONE_AT=$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)
else
  OLD_AT=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  TEN_AT=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  ONE_AT=$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)
fi
cat > "$API_TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_CALLS"
case "$*" in
  *orgs/*/actions/runners*)
    target=runners; json='{"runners":[{"name":"ez-runner-c-1","status":"online","busy":true}]}'
    if [[ "$*" = *' -i '* ]]; then target=token; json='HTTP/2.0 200 OK'; fi ;;
  *workflow\ run*) target=dispatch; json='' ;;
  *run\ view*)
    target=view; json='{"status":"completed","conclusion":"success"}'
    if [ "$FAKE_SCENARIO" = failed_canary ]; then json='{"status":"completed","conclusion":"failure"}'; fi ;;
  *run\ list*)
    target=recent; json='[{"databaseId":3}]'
    if [[ "$FAKE_SCENARIO" = recent_* ]]; then json='[{"databaseId":3},{"databaseId":5}]'; fi
    if [[ "$*" == *'-L 1 '* ]]; then
      if [ -f "$FAKE_STATE" ]; then target=poll; json='[{"databaseId":2}]'
      else target=baseline; json='[{"databaseId":1}]'; touch "$FAKE_STATE"; fi
    fi ;;
  *actions/runs\?*per_page=100*|*actions/runs\?*per_page=1)
    target=queue; json='{"workflow_runs":[],"total_count":0}'
    if [ "$LOCAL_STATE" = queue_unknown ]; then echo 'gh: HTTP 403: queue unavailable' >&2; exit 1; fi
    if [ "$FAKE_SCENARIO" != empty ] && [[ "$*" == *status=queued* ]]; then
      json=$(jq -nc --arg at "$FAKE_OLD_AT" '{total_count:1,workflow_runs:[{id:4,name:"concurrency-blocked",head_branch:"test",created_at:$at}]}')
    fi
    if [ "$FAKE_TARGET" = queue_queued ] && [[ "$*" == *status=queued* ]]; then target=queue_queued; fi
    if [ "$FAKE_TARGET" = queue_progress ] && [[ "$*" == *status=in_progress* ]]; then target=queue_progress; fi
    if [ "$FAKE_TARGET" = queue_later ] && [[ "$*" == *status=queued* ]]; then
      if [[ "$*" == *'page=1' ]]; then
        json=$(jq -nc --arg at "$FAKE_OLD_AT" '{total_count:101,workflow_runs:[range(100) | {id:(.+1),name:"queued",head_branch:"test",created_at:$at}]}')
      else target=queue_later; fi
    fi ;;
  *actions/runs\?*)
    target=mapruns; json='{"workflow_runs":[]}'
    if [ "$FAKE_TARGET" = mapjobs ] || [ "$FAKE_SCENARIO" != empty ]; then
      json='{"workflow_runs":[{"id":4,"html_url":"https://example.invalid/run/4","created_at":"2099-01-01T00:00:00Z"}]}'
      if [ "$FAKE_SCENARIO" != empty ]; then json=$(printf '%s' "$json" | jq --arg at "$FAKE_OLD_AT" '.workflow_runs[0].created_at = $at'); fi
    fi ;;
  *actions/runs/4/jobs*)
    target=mapjobs; json='{"jobs":[{"status":"in_progress","name":"test","runner_name":"ez-runner-c-1","html_url":"https://example.invalid/job/4","created_at":"2099-01-01T00:00:00Z","started_at":"2099-01-01T00:00:01Z"}]}'
    if [[ "$FAKE_SCENARIO" = job_wait* ]]; then
      json=$(printf '%s' "$json" | jq --arg at "$FAKE_OLD_AT" '.jobs[0] |= (.status = "queued" | .created_at = $at | .runner_name = null | .started_at = null)')
    fi ;;
  *actions/runs/*/jobs*)
    target=jobs; json='{"jobs":[{"runner_name":"ez-runner-c-1","conclusion":"success"}]}'
    if [[ "$FAKE_SCENARIO" = recent_failed* ]]; then json=$(printf '%s' "$json" | jq '.jobs[0].conclusion = "failure"'); fi
    if [[ "$FAKE_SCENARIO" = recent_*_mixed ]] && [[ "$*" = */5/jobs ]]; then
      echo 'gh: HTTP 403: second recent run unavailable' >&2; exit 1
    fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
if [[ "$FAKE_SCENARIO" = *_mixed ]] && [[ "$*" = *repos/test/other/* ]] && [ "$FAKE_TARGET" = "$target" ]; then
  echo 'gh: HTTP 403: other repository unavailable' >&2; exit 1
fi
if [ "$FAKE_TARGET" = "$target" ]; then
  case "$FAKE_REPLY" in
    error) echo 'gh: HTTP 403: API rate limit exceeded' >&2; exit 1 ;;
    partial) printf '%s\n' "$json"; echo 'gh: HTTP 403: partial response' >&2; exit 1 ;;
    long_error) printf '%02000d\n' 0; echo 'gh: HTTP 403: partial response' >&2; exit 1 ;;
    malformed) echo 'not JSON'; exit 0 ;;
    schema) echo '{}'; exit 0 ;;
    null) json=null ;;
    array) json='[]' ;;
    null_runs) json='{"workflow_runs":null,"total_count":0}' ;;
    object_runs) json='{"workflow_runs":{},"total_count":0}' ;;
    invalid_count) json='{"workflow_runs":[],"total_count":"0"}' ;;
    negative_count) json='{"workflow_runs":[],"total_count":-1}' ;;
    boolean_count) json='{"workflow_runs":[],"total_count":true}' ;;
    null_member) json=$(printf '%s' "$json" | jq 'if type == "array" then [null] elif has("status") then .status = null else with_entries(if (.value | type) == "array" then .value = [null] else . end) end') ;;
    denied) echo 'HTTP/2.0 401 Unauthorized'; exit 1 ;;
    rate_limited) echo 'HTTP/2.0 429 Too Many Requests'; exit 1 ;;
    invalid_record) json='{"workflow_runs":[{"id":"4"}],"total_count":1}' ;;
    bad_timestamp) json='{"workflow_runs":[{"id":4,"name":"test","head_branch":"test","created_at":"2026-10-28T00:00:00"}],"total_count":1}' ;;
    missing_conclusion) json=$(printf '%s' "$json" | jq 'del(.conclusion)') ;;
    bad_conclusion) json=$(printf '%s' "$json" | jq '.conclusion = 42') ;;
    empty_body) exit 0 ;;
    bad_page) printf '%s\n{}\n' "$json"; exit 0 ;;
    missing_runner) json=$(printf '%s' "$json" | jq 'del(.jobs[0].runner_name)') ;;
    unknown_status) json=$(printf '%s' "$json" | jq '.jobs[0].status = "nonsense"') ;;
    invalid_runner) json=$(printf '%s' "$json" | jq '.jobs[0].runner_name = 42') ;;
    missing_name) json=$(printf '%s' "$json" | jq 'del(.jobs[0].name)') ;;
    missing_started) json=$(printf '%s' "$json" | jq 'del(.jobs[0].started_at)') ;;
    invalid_started) json=$(printf '%s' "$json" | jq '.jobs[0].started_at = 42') ;;
    empty_created|bad_created|old_bad_created|normalized_created|zero_year_created)
      at=''; [ "$FAKE_REPLY" != bad_created ] || at=not-a-timestamp
      [ "$FAKE_REPLY" != old_bad_created ] || at=0000-invalid
      [ "$FAKE_REPLY" != normalized_created ] || at=2026-02-31T00:00:00Z
      [ "$FAKE_REPLY" != zero_year_created ] || at=0000-01-01T00:00:00Z
      if [ "$target" = mapruns ]; then
        json=$(jq -nc --arg at "$at" '{workflow_runs:[{id:4,html_url:"https://example.invalid/run/4",created_at:$at}]}')
      else
        json=$(printf '%s' "$json" | jq --arg at "$at" '.jobs[0].created_at = $at')
      fi ;;
    empty_started|bad_started)
      at=''; [ "$FAKE_REPLY" != bad_started ] || at=not-a-timestamp
      json=$(printf '%s' "$json" | jq --arg at "$at" '.jobs[0].started_at = $at') ;;
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
if [[ "$FAKE_SCENARIO" = *_mixed ]]; then EXPLICIT_WORK_REPOS+=' test/other'; fi
SERVICE_STATE=active; COLIMA_STATUS=NotInstalled
LOCAL_CONFIG_FILE=unused; SLOT_FILE=unused; DEFAULT_CONFIGURED_COUNT=20
LOCAL_COUNT=20; REMOTE_COUNT=4; CONTAINER_COUNT=20
REMOTE_LABEL=fixture-mac
QUEUE_REPO=test/repo; STALE_HOURS=8
RESPAWN_EVIDENCE_WINDOW_MIN=3
LOOP_FAILS=4; LOOP_WINDOW=3; QUEUE_TAIL_WARN_MIN=20
QUEUE_TAIL_BAD=0; QUEUE_RC=0; HOST_LIFECYCLE_CRITICAL=0
GH_TOKEN_STALE_CRITICAL=0; SLOT_PROOF_CRITICAL=0
EXECUTING_SLOTS=(); IDLE_SLOTS=(); DOWN_SLOTS=(); CYCLING_SLOTS=()
REMOTE_EXECUTING_SLOTS=(m1 m2 m3 m4)
REMOTE_IDLE_SLOTS=(); REMOTE_DOWN_SLOTS=(); REMOTE_CYCLING_SLOTS=()
for n in $(seq 1 20); do EXECUTING_SLOTS+=("ez-runner-c-$n"); done
case "$LOCAL_STATE" in
  down) unset 'EXECUTING_SLOTS[19]'; DOWN_SLOTS=(ez-runner-c-20) ;;
  idle) unset 'EXECUTING_SLOTS[19]'; IDLE_SLOTS=(ez-runner-c-20) ;;
  remote_down) unset 'REMOTE_EXECUTING_SLOTS[3]'; REMOTE_DOWN_SLOTS=(m4) ;;
  remote_idle) unset 'REMOTE_EXECUTING_SLOTS[3]'; REMOTE_IDLE_SLOTS=(m4) ;;
esac
SH
{
  printf 'SCRIPT_DIR=%q\n' "$REPO_ROOT"
  sed -n '/^API_UNVERIFIED=0$/,/^# --- end GitHub response helper/p' "$DOCTOR_SCRIPT"
  sed -n '/^section "4b\./,/^# --- C\./p' "$DOCTOR_SCRIPT" | sed '$d'
  sed -n '/^# --- C\. GitHub-side/,/^# --- D\. live docker/p' "$DOCTOR_SCRIPT" | sed '$d'
  sed -n '/^section "7\. real job/,/^# --- F1b\./p' "$DOCTOR_SCRIPT" | sed '$d'
  sed -n '/^EXPLICIT_WORK_REPOS=/,/^# --- F2\./p' "$DOCTOR_SCRIPT" | sed '$d'
  printf '%s\n' 'printf "JOBMAP queued=%s errors=%s\n" "$JOBLEVEL_QUEUED_COUNT" "$JOBLEVEL_FETCH_ERRORS"'
  sed -n '/^# --- F2\./,/^# --- F3\./p' "$DOCTOR_SCRIPT" | sed '$d'
  sed -n '/^IDLE_STARVED_THRESHOLD_MIN=/,/^# --- F4\./p' "$DOCTOR_SCRIPT" | sed '$d'
  # Render the real local inventory using cached fixture states, with no probes.
  sed -n '/^LOCAL_SLOT_STATE_TABLE=""$/,/^# IDLE is only/p' "$DOCTOR_SCRIPT" | sed '$d'
  sed -n '/^job_evidence_for_runner() {/,/^}/p' "$DOCTOR_SCRIPT"
  sed -n '/^list_slot_work() {/,/^# Local fleet —/p' "$DOCTOR_SCRIPT" | sed '$d'
  cat <<'SH'
CONFIGURED_COUNT=$LOCAL_COUNT
list_slot_work "$RUNNER_NAME_PREFIX" "$LOCAL_COUNT" localhost fixture-local
SH
  # The remote critical checks consume fixture slots, without SSH/probes.
  sed -n '/^  if \[ "${#REMOTE_DOWN_SLOTS\[@\]}"/,/^  fi$/p' "$DOCTOR_SCRIPT"
  sed -n '/^  if \[ "${#REMOTE_IDLE_SLOTS\[@\]}"/,/^  fi$/p' "$DOCTOR_SCRIPT"
  cat <<'SH'
printf "QUEUE rc=%s bad=%s STARVED=%s\n" "$QUEUE_RC" "$QUEUE_TAIL_BAD" "$STARVED_PRESENT"
SH
  sed -n '/^CRITICAL=0$/,$p' "$DOCTOR_SCRIPT"
} >> "$HARNESS"
bash -n "$HARNESS"

api_case() {
  local target="$1" reply="$2" expected="$3" local_state="${4:-healthy}" prove="${5:-0}" scenario="${6:-empty}"
  local label="$target-$reply-$local_state-prove$prove-$scenario" rc=0 out at="$OLD_AT"
  case "$scenario" in job_wait_10*) at="$TEN_AT" ;; job_wait_1_*) at="$ONE_AT" ;; esac
  out="$API_TMP/$label.log"
  # Distinct state per case; the fake canary baseline and poll cannot collide.
  PATH="$API_TMP/bin:$PATH" TMPDIR="$API_TMP" FAKE_STATE="$API_TMP/$label.state" \
    HOME="$API_TMP/home" XDG_CONFIG_HOME="$API_TMP/home/.config" XDG_STATE_HOME="$API_TMP/home/.local/state" \
    FAKE_CALLS="$API_TMP/$label.calls" FAKE_OLD_AT="$at" FAKE_SCENARIO="$scenario" \
    FAKE_TARGET="$target" FAKE_REPLY="$reply" LOCAL_STATE="$local_state" PROVE="$prove" \
    bash "$HARNESS" > "$out" 2>&1 || rc=$?
  if [ "$rc" -ne "$expected" ] || grep -Eq 'UNEXPECTED LIVE PROBE|unexpected gh call:' "$out"; then
    echo "FAIL: $label rc=$rc expected=$expected"; cat "$out"; OVERALL_PASS=false; return
  fi
  if [ "$expected" -eq 2 ]; then
    if ! grep -q 'verdict: UNVERIFIED' "$out" ||
       grep -Eq 'fleet healthy:|gate FAILED|IDLE-STARVED|total=0 online=0|\[BAD\].*queue tail' "$out"; then
      echo "FAIL: $label fabricated proof/failure"; cat "$out"; OVERALL_PASS=false; return
    fi
    if [[ "$reply" = *error ]] && ! grep -q 'HTTP 403' "$out"; then
      echo "FAIL: $label lost actual error"; OVERALL_PASS=false; return
    fi
    if [[ "$target" = mapjobs || "$target" = mapruns ]] && ! grep -q 'JOBMAP .*errors=[1-9]' "$out"; then
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
  if [ "$expected" -eq 0 ] && ! grep -q '8. GitHub Actions queue health' "$out"; then
    echo "FAIL: $label bypassed actual queue health"; OVERALL_PASS=false; return
  fi
  if [ "$expected" -eq 2 ] && [ "$local_state" = idle ] && [ "$target" = mapjobs ] &&
     ! grep -q 'ez-runner-c-20 *IDLE-UNVERIFIED *job queue evidence unavailable' "$out"; then
    echo "FAIL: $label inventory claimed idle health without job proof"; cat "$out"; OVERALL_PASS=false; return
  fi
  if [ "$scenario" = recent_success_mixed ] && ! grep -q 'confirmed successes=1' "$out"; then
    echo "FAIL: $label erased confirmed recent success"; cat "$out"; OVERALL_PASS=false; return
  fi
  if [[ "$scenario" = job_wait_10* ]] && [ "$expected" -eq 1 ]; then
    if ! grep -q 'bad=0 STARVED=1' "$out"; then
      echo "FAIL: $label lost independent starvation proof"; cat "$out"; OVERALL_PASS=false; return
    fi
  elif [[ "$scenario" = job_wait* ]] && [ "$expected" -eq 1 ] &&
     ! grep -Eq 'QUEUE rc=[01] bad=1 STARVED=1' "$out"; then
    echo "FAIL: $label bypassed proven queue/starvation failure"; cat "$out"; OVERALL_PASS=false; return
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
api_case mapjobs unknown_status 2 idle
api_case mapjobs queued_null 0
api_case mapjobs queued_empty 0
for status in queued in_progress completed waiting requested pending; do api_case mapjobs "status_$status" 0; done
api_case runners pages 0
api_case none healthy 2 queue_unknown
api_case runners error 1 down
api_case runners error 2 idle
for target in baseline dispatch poll view jobs; do
  api_case "$target" error 2 healthy 1
  if [ "$target" != dispatch ]; then api_case "$target" malformed 2 healthy 1; fi
done
api_case none healthy 0 healthy 1

# Rejection counterexamples must traverse the real queue and starvation blocks.
for state in healthy idle remote_idle; do
  api_case mapjobs error 2 "$state" 0 concurrency
done
for state in down remote_down; do api_case mapjobs error 1 "$state" 0 concurrency; done
api_case none healthy 0 healthy 0 concurrency
api_case none healthy 1 healthy 0 job_wait
api_case none healthy 1 idle 0 job_wait
api_case none healthy 1 remote_idle 0 job_wait
for target in mapruns mapjobs; do
  for reply in empty_created bad_created old_bad_created normalized_created zero_year_created; do api_case "$target" "$reply" 2; done
done
for reply in empty_started bad_started; do api_case mapjobs "$reply" 2; done

# Retain positive job evidence when another repository/status fetch is unknown.
for target in mapruns mapjobs; do
  for state in healthy idle remote_idle; do
    api_case "$target" mixed 1 "$state" 0 job_wait_mixed
    api_case "$target" mixed 2 "$state" 0 concurrency_mixed
  done
done
# Every workflow-run ingress rejects schema-invalid successful HTTP responses.
for target in queue queue_queued queue_progress queue_later; do
  for reply in error malformed schema null array null_runs object_runs invalid_count negative_count boolean_count null_member invalid_record bad_timestamp; do
    api_case "$target" "$reply" 2
    api_case "$target" "$reply" 1 down
    api_case "$target" "$reply" 1 idle 0 job_wait
  done
done
# Unknowns at unrelated ingress points cannot suppress an observed job failure.
for target in runners recent jobs baseline dispatch poll view; do
  prove=0; [[ "$target" = baseline || "$target" = dispatch || "$target" = poll || "$target" = view ]] && prove=1
  api_case "$target" error 1 idle "$prove" job_wait
done
for target in runners recent jobs mapruns mapjobs baseline poll view; do
  prove=0; [[ "$target" = baseline || "$target" = poll || "$target" = view ]] && prove=1
  for reply in empty_body null null_member bad_page; do
    api_case "$target" "$reply" 2 healthy "$prove"
    api_case "$target" "$reply" 1 down "$prove"
  done
done
for reply in missing_conclusion bad_conclusion; do api_case view "$reply" 2 healthy 1; done
api_case jobs error 1 healthy 1 failed_canary
api_case none healthy 1 healthy 1 failed_canary
api_case runners error 1 healthy 1 failed_canary
api_case recent error 1 healthy 1 failed_canary
api_case queue error 1 healthy 1 failed_canary
api_case none healthy 2 healthy 0 recent_success_mixed
api_case none healthy 2 healthy 0 recent_failed_mixed
api_case none healthy 1 healthy 0 recent_failed_complete
for target in mapruns mapjobs; do
  api_case "$target" mixed 2 healthy 0 job_wait_10_mixed
  for state in idle remote_idle; do
    api_case "$target" mixed 1 "$state" 0 job_wait_10_mixed
    api_case "$target" mixed 2 "$state" 0 job_wait_1_mixed
  done
done
api_case none healthy 0 healthy 0 job_wait_10
api_case none healthy 1 idle 0 job_wait_10
api_case none healthy 0 idle 0 job_wait_1_complete
for reply in error partial long_error malformed denied rate_limited; do
  expected=2; [ "$reply" != denied ] || expected=1
  api_case token "$reply" "$expected"
  api_case token "$reply" 1 down
done

# Standalone callers traverse the same response validator without a job map.
for target in queue_queued queue_progress queue_later; do
  for reply in healthy schema null_runs invalid_count invalid_record bad_timestamp; do
    expected=2; [ "$reply" != healthy ] || expected=0
    label="standalone-$target-$reply"; rc=0
    PATH="$API_TMP/bin:$PATH" HOME="$API_TMP/home" TMPDIR="$API_TMP" \
      XDG_CONFIG_HOME="$API_TMP/home/.config" XDG_STATE_HOME="$API_TMP/home/.local/state" \
      FAKE_CALLS="$API_TMP/$label.calls" FAKE_STATE="$API_TMP/$label.state" \
      FAKE_OLD_AT="$ONE_AT" FAKE_TARGET="$target" FAKE_REPLY="$reply" \
      FAKE_SCENARIO=empty LOCAL_STATE=healthy \
      bash "$REPO_ROOT/scripts/queue-health.sh" > "$API_TMP/$label.log" 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ] && ! grep -q 'unexpected gh call:' "$API_TMP/$label.log"; then
      echo "PASS: $label exit=$rc"
    else
      echo "FAIL: $label rc=$rc expected=$expected"; cat "$API_TMP/$label.log"; OVERALL_PASS=false
    fi
  done
done

echo "API receipts: $API_TMP"
echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
