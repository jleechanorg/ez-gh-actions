#!/usr/bin/env bash
# Hermetic tests for TestFlight terminal failure and stuck-run alert monitoring.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/testflight-workflow-alert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${GH_STUB_FAIL:-}" ]; then exit 1; fi
printf '%s\n' "$*" >> "${GH_CALL_LOG:?}"
jq -c '.workflow_runs[:100][] | @json' "${RUNS_FIXTURE:?}"
STUB
cat > "$TMP/gcloud" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GCLOUD_LOG:?}"
for arg in "$@"; do
  case "$arg" in
    --policy-from-file=*) cat "${arg#*=}" >> "${GCLOUD_LOG:?}"; jq -c . "${arg#*=}" >> "${POLICY_HISTORY:?}"; cp "${arg#*=}" "${POLICY_CAPTURE:?}" ;;
  esac
done
STUB
chmod +x "$TMP/gh" "$TMP/gcloud"
run() {
  if [ "${DEBUG_TEST:-0}" = 1 ]; then
    GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$TMP/state.json" \
      RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" "$SCRIPT" "$@" >/dev/null 2>&1
  else
    GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$TMP/state.json" \
      RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" \
      "$SCRIPT" "$@" >/dev/null 2>&1
  fi
}
error_count() { [ -f "$TMP/gcloud.log" ] && grep -c 'severity=ERROR' "$TMP/gcloud.log" || echo 0; }
old="$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
failure_old="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
new="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A failed TestFlight run must alert exactly once, even across monitor cycles.
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[{"id":410,"run_attempt":1,"name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old","html_url":"https://github.com/jleechanorg/worldai_frontend/actions/runs/410","head_sha":"abc"}]}
EOF
run || true
[ "$(error_count)" = 1 ] || fail "failed TestFlight run must emit ERROR"
run || true
[ "$(error_count)" = 1 ] || fail "same failed run attempt must be deduplicated"
pass "failed run alerts once per attempt"
sed 's/"run_attempt":1/"run_attempt":2/' "$TMP/runs.json" > "$TMP/runs.next" && mv "$TMP/runs.next" "$TMP/runs.json"
run || true
[ "$(error_count)" = 2 ] || fail "a new rerun attempt must alert independently"
pass "new failed attempt alerts independently"

# A still-running release beyond the threshold must alert; younger runs must not.
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[{"id":411,"run_attempt":1,"name":"iOS TestFlight","status":"in_progress","conclusion":null,"created_at":"$old","html_url":"https://github.com/jleechanorg/worldai_frontend/actions/runs/411","head_sha":"def"}]}
EOF
run || true
[ "$(error_count)" = 3 ] || fail "old in-progress run must emit ERROR"
sed -i '' 's/411/412/g' "$TMP/runs.json" 2>/dev/null || sed -i 's/411/412/g' "$TMP/runs.json"
sed -i '' "s/$old/$new/g" "$TMP/runs.json" 2>/dev/null || sed -i "s/$old/$new/g" "$TMP/runs.json"
run || true
[ "$(error_count)" = 3 ] || fail "young in-progress run must not alert"
pass "stuck run alerts and young run does not"
! grep -q -- '--paginate' "$TMP/gh-calls.log" || fail "bounded first-page query must not paginate past the newest 100 runs"
pass "recent-run scan stays bounded to newest page"

# Successful completions and other workflow runs are not incidents.
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[{"id":413,"run_attempt":1,"name":"iOS TestFlight","status":"completed","conclusion":"success","created_at":"$old","html_url":"https://github.com/jleechanorg/worldai_frontend/actions/runs/413","head_sha":"ghi"},{"id":414,"run_attempt":1,"name":"Mobile Check","status":"completed","conclusion":"failure","created_at":"$old","html_url":"https://github.com/jleechanorg/worldai_frontend/actions/runs/414","head_sha":"jkl"},{"id":415,"run_attempt":1,"name":"iOS TestFlight","status":"queued","conclusion":null,"created_at":"$old","html_url":"https://github.com/jleechanorg/worldai_frontend/actions/runs/415","head_sha":"mno"}]}
EOF
run || true
[ "$(error_count)" = 3 ] || fail "success and unrelated workflow must not alert"
pass "successes and unrelated workflows ignored"

# GitHub returns only the requested first 100 newest runs; still inspect a failure
# in that bounded page even when older workflow history exceeds the page size.
jq -n --arg t "$old" --arg ft "$failure_old" '{workflow_runs:([{id:499,run_attempt:1,name:"iOS TestFlight",status:"completed",conclusion:"failure",created_at:$ft,updated_at:$ft,html_url:"https://github.com/jleechanorg/worldai_frontend/actions/runs/499",head_sha:"pqr"}] + [range(1;101) as $i | {id:$i,run_attempt:1,name:"iOS TestFlight",status:"completed",conclusion:"success",created_at:$t,updated_at:$t,html_url:("https://github.com/jleechanorg/worldai_frontend/actions/runs/"+($i|tostring)),head_sha:"stu"}])}' > "$TMP/runs.json"
run || true
[ "$(error_count)" = 4 ] || fail "failure in newest 100 run page must alert when older history exceeds one page"
pass "failure detected with more than 100 historical runs"

# API failure cannot be reported as healthy; repeated failures emit a BLIND diagnostic.
for _ in 1 2 3; do GH_STUB_FAIL=1 run || true; done
grep -q 'BLIND' "$TMP/gcloud.log" || fail "repeated API failures must emit BLIND diagnostic"
grep -q '"status":"BLIND"' "$TMP/gcloud.log" || fail "BLIND diagnostic status must remain distinct"
pass "API blindness is surfaced separately"

# The policy installer keeps per-run alerts Slack-only and adds a separate SMS streak policy.
: > "$TMP/policy-history.jsonl"
run --ensure-gcp-policy
[ "$(wc -l < "$TMP/policy-history.jsonl" | tr -d ' ')" = 2 ] || fail "policy setup must ensure both independent policies"
jq -se 'any(.[]; (.displayName | contains("run monitor")) and (.notificationChannels == ["projects/worldarchitecture-ai/notificationChannels/14071650426226468737"]) and (.conditions[0].conditionMatchedLog.filter | contains("RUN_FAILED") and contains("RUN_STUCK") and contains("BLIND"))) and any(.[]; (.displayName | contains("consecutive failures")) and (.notificationChannels == ["projects/worldarchitecture-ai/notificationChannels/17167119139665448890"]) and (.conditions[0].conditionMatchedLog.filter | contains("SMS_FAILURE_STREAK") and contains("failure_streak>=3") and contains("jleechanorg/worldai_frontend") and contains("ios-testflight.yml")))' "$TMP/policy-history.jsonl" >/dev/null || fail "policies must route current run statuses to Slack and thresholded streaks to SMS"
pass "policy setup separates Slack run alerts from SMS streak escalation"

# The streak path repeats the existing workflow-name fail-safe and accepts only build failures/timeouts.
ELIGIBILITY_STATE="$TMP/eligibility-state.json"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":730,"run_number":1,"run_attempt":1,"event":"push","name":"Unrelated workflow","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$ELIGIBILITY_STATE" RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/eligibility-gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" "$SCRIPT" >/dev/null 2>&1
[ "$(jq -r '.failure_streak // 0' "$ELIGIBILITY_STATE")" = 0 ] || fail "unrelated run name must not advance the SMS streak"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":731,"run_number":2,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"action_required","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$ELIGIBILITY_STATE" RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/eligibility-gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" "$SCRIPT" >/dev/null 2>&1
[ "$(jq -r '.failure_streak // 0' "$ELIGIBILITY_STATE")" = 0 ] || fail "action_required must not count as a completed build failure"
[ "$(grep -c 'SMS_FAILURE_STREAK' "$TMP/eligibility-gcloud.log" || true)" = 0 ] || fail "unrelated or action_required outcomes must not trigger SMS"
pass "name fail-safe and SMS conclusion whitelist hold"

# A success later in the same first API batch suppresses historical escalation.
BATCH_STATE="$TMP/batch-state.json"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":704,"run_number":4,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"success","created_at":"$new","updated_at":"$new"},
 {"id":703,"run_number":3,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":702,"run_number":2,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":701,"run_number":1,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$BATCH_STATE" RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/batch-gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'SMS_FAILURE_STREAK' "$TMP/batch-gcloud.log" || true)" = 0 ] || fail "success later in the same first API batch must suppress historical streak SMS"
[ "$(jq -r '.failure_streak // 0' "$BATCH_STATE")" = 0 ] || fail "same-batch recovery must leave the current streak at zero"
pass "same-batch newer success suppresses historical escalation"

# Consecutive failure streak: completed push builds in run order.
STREAK_STATE="$TMP/streak-state.json"
streak_run() {
 GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$STREAK_STATE" RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/streak-gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" "$SCRIPT" >/dev/null 2>&1
}
streak_sms_count() { [ -f "$TMP/streak-gcloud.log" ] && grep -c 'SMS_FAILURE_STREAK' "$TMP/streak-gcloud.log" || echo 0; }
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":503,"run_number":3,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":502,"run_number":2,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":501,"run_number":1,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
streak_run || true
[ "$(streak_sms_count)" = 1 ] || fail "third distinct completed push failure must emit one streak escalation"
grep 'SMS_FAILURE_STREAK' "$TMP/streak-gcloud.log" | grep -Eq '"failure_streak":3([,}])' || fail "streak escalation must include failure_streak=3"
streak_run || true
[ "$(streak_sms_count)" = 1 ] || fail "repeated polling must not duplicate an active streak SMS"
pass "third failure escalates once with structured streak count"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":504,"run_number":4,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":503,"run_number":3,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":502,"run_number":2,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
streak_run || true
[ "$(streak_sms_count)" = 1 ] || fail "fourth failure must not repeat escalation"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":505,"run_number":5,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"success","created_at":"$new","updated_at":"$new"},
 {"id":504,"run_number":4,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":503,"run_number":3,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 0 ] || fail "newer success must reset streak"
[ "$(streak_sms_count)" = 1 ] || fail "success reset must not emit SMS"
pass "fourth failure is quiet and newer success resets streak"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":510,"run_number":10,"run_attempt":1,"event":"workflow_dispatch","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$new","updated_at":"$new"},
 {"id":509,"run_number":9,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"cancelled","created_at":"$new","updated_at":"$new"},
 {"id":508,"run_number":8,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"skipped","created_at":"$new","updated_at":"$new"},
 {"id":507,"run_number":7,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"neutral","created_at":"$new","updated_at":"$new"},
 {"id":506,"run_number":6,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$new","updated_at":"$new"}
]}
EOF
streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 1 ] || fail "manual, cancelled, and older failures must not override latest eligible outcome"
[ "$(streak_sms_count)" = 1 ] || fail "non-qualified events must not trigger SMS"
pass "manual dispatch and cancellation do not qualify"

# Late completion joins a streak until a newer success anchors it; API blindness preserves it.
STREAK_STATE="$TMP/order-state.json"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":612,"run_number":12,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":611,"run_number":11,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":610,"run_number":10,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"in_progress","conclusion":null,"created_at":"$old"}
]}
EOF
streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 2 ] || fail "two completed failures after pending run 10 must be retained"
GH_STUB_FAIL=1 streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 2 ] || fail "GitHub API failure must preserve the known streak"
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":612,"run_number":12,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":611,"run_number":11,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"},
 {"id":610,"run_number":10,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 3 ] || fail "late run 10 failure must join 11/12 when no newer success exists"
[ "$(streak_sms_count)" = 2 ] || fail "late third failure must emit one additional streak SMS"
grep 'SMS_FAILURE_STREAK' "$TMP/streak-gcloud.log" | tail -1 | grep -q '"run_id":"612"' || fail "late failure escalation must identify latest run 12"
pass "late failure completes the streak and API errors preserve state"

# A previously observed newer success prevents an older late failure from reopening a streak.
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":613,"run_number":13,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"success","created_at":"$new","updated_at":"$new"}
]}
EOF
streak_run || true
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":610,"run_number":10,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$failure_old","updated_at":"$failure_old"}
]}
EOF
streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 0 ] || fail "late old failure after newer success must not reopen streak"
[ "$(streak_sms_count)" = 2 ] || fail "old failure after success must not page"
pass "newer success closes the late-completion window"

# Distinct rerun attempts count once each; polling either attempt is idempotent.
cat > "$TMP/runs.json" <<EOF
{"workflow_runs":[
 {"id":614,"run_number":14,"run_attempt":2,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"timed_out","created_at":"$new","updated_at":"$new"},
 {"id":614,"run_number":14,"run_attempt":1,"event":"push","name":"iOS TestFlight","status":"completed","conclusion":"failure","created_at":"$new","updated_at":"$new"}
]}
EOF
streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 2 ] || fail "two attempts of one workflow run must be separate deduplicated outcomes"
streak_run || true
[ "$(jq -r .failure_streak "$STREAK_STATE")" = 2 ] || fail "repeated polling must not recount rerun attempts"
pass "rerun attempts are distinct and polling remains idempotent"

# Dry run may read state but must not create or rewrite persistent state.
before="$(shasum -a 256 "$TMP/state.json")"
run --dry-run
after="$(shasum -a 256 "$TMP/state.json")"
[ "$before" = "$after" ] || fail "--dry-run rewrote the existing state file"
STATE_FILE="$TMP/missing-state.json" GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" \
  RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" \
  "$SCRIPT" --ensure-gcp-policy --dry-run > "$TMP/policy-preview.jsonl"
[ ! -e "$TMP/missing-state.json" ] || fail "policy dry-run created persistent state"
[ "$(wc -l < "$TMP/policy-preview.jsonl" | tr -d ' ')" = 2 ] || fail "policy dry-run must print both exact policy JSON documents"
jq -se 'length == 2' "$TMP/policy-preview.jsonl" >/dev/null || fail "policy dry-run output must be parseable JSON per line"
pass "dry-run does not mutate state"
