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
    --policy-from-file=*) cat "${arg#*=}" >> "${GCLOUD_LOG:?}"; cp "${arg#*=}" "${POLICY_CAPTURE:?}" ;;
  esac
done
STUB
chmod +x "$TMP/gh" "$TMP/gcloud"
run() {
  if [ "${DEBUG_TEST:-0}" = 1 ]; then
    GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$TMP/state.json" \
      RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" "$SCRIPT" "$@"
  else
    GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" STATE_FILE="$TMP/state.json" \
      RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" POLICY_CAPTURE="$TMP/policy.json" \
      "$SCRIPT" "$@" >/dev/null 2>&1
  fi
}
error_count() { [ -f "$TMP/gcloud.log" ] && grep -c 'severity=ERROR' "$TMP/gcloud.log" || echo 0; }
old="$(date -u -v-60M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '60 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
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

# The alert policy installer must target only this monitor's ERROR events.
run --ensure-gcp-policy
grep -q 'ios-testflight-run-alert' "$TMP/gcloud.log" || fail "policy setup must select TestFlight alert source"
jq -e '.conditions | length == 1 and any(.[]; (.conditionMatchedLog.filter | contains("jsonPayload.status=\"RUN_FAILED\"") and contains("jsonPayload.status=\"RUN_STUCK\"") and contains("severity>=ERROR") and contains("jsonPayload.status=\"BLIND\"") and contains("severity>=WARNING")))' "$TMP/policy.json" >/dev/null || fail "policy must use one condition for run and blind alerts"
pass "policy setup is scoped to TestFlight monitor"

# Dry run may read state but must not create or rewrite persistent state.
before="$(shasum -a 256 "$TMP/state.json")"
run --dry-run
after="$(shasum -a 256 "$TMP/state.json")"
[ "$before" = "$after" ] || fail "--dry-run rewrote the existing state file"
STATE_FILE="$TMP/missing-state.json" GH_BIN="$TMP/gh" GCLOUD_BIN="$TMP/gcloud" \
  RUNS_FIXTURE="$TMP/runs.json" GCLOUD_LOG="$TMP/gcloud.log" GH_CALL_LOG="$TMP/gh-calls.log" \
  "$SCRIPT" --ensure-gcp-policy --dry-run >/dev/null 2>&1
[ ! -e "$TMP/missing-state.json" ] || fail "policy dry-run created persistent state"
pass "dry-run does not mutate state"
