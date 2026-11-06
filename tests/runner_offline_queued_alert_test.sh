#!/usr/bin/env bash
# Hermetic coverage for runner-offline-queued-alert.sh: gh and gcloud are stubbed, but the
# stub applies the script's real --jq filters to fixture JSON so the filters are exercised.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/runner-offline-queued-alert.sh"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }; pass() { echo "PASS: $*"; }
cat > "$W/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_GH_FAIL:-}" ] || exit 1
filter=""; prev=""
for a in "$@"; do [ "$prev" = --jq ] && filter="$a"; prev="$a"; done
case "$*" in
  *actions/runners*) printf '%s' "${STUB_RUNNERS_JSON:-{\"runners\":[]\}}" | jq -r "$filter" ;;
  *actions/runs*) printf '%s' "${STUB_RUNS_JSON:-{\"workflow_runs\":[]\}}" | jq -r "$filter" ;;
esac
STUB
cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  *"alpha monitoring policies list"*)
    if [[ "$*" == *'displayName="[CRITICAL] Runner offline with queued runs"'* ]]; then
      [ -z "${STUB_CURRENT_POLICY:-}" ] || printf '%s\n' "$STUB_CURRENT_POLICY"
    elif [[ "$*" == *'displayName="[CRITICAL] Runner offline with queued runs: SMS (metric)"'* ]]; then
      [ -z "${STUB_LEGACY_POLICY:-}" ] || printf '%s\n' "$STUB_LEGACY_POLICY"
    fi
    exit 0
    ;;
  *"alpha monitoring policies create"*|*"alpha monitoring policies update"*)
    policy_file=""
    for arg in "$@"; do case "$arg" in --policy-from-file=*) policy_file="${arg#--policy-from-file=}" ;; esac; done
    if [ -n "${STUB_CAPTURE_DIR:-}" ] && [ -r "$policy_file" ]; then
      mkdir -p "$STUB_CAPTURE_DIR"
      cp "$policy_file" "$STUB_CAPTURE_DIR/policy.json"
    fi
    ;;
esac
STUB
chmod +x "$W/gh" "$W/gcloud"
run() { # name args...
  STATE_FILE="$W/state-$1.json" STUB_LOG="$W/log-$1" STUB_CAPTURE_DIR="${STUB_CAPTURE_DIR:-}" STUB_CURRENT_POLICY="${STUB_CURRENT_POLICY:-}" STUB_LEGACY_POLICY="${STUB_LEGACY_POLICY:-}" GH_BIN="$W/gh" GCLOUD_BIN="${GCLOUD_OVERRIDE-$W/gcloud}" "$S" "${@:2}" >/dev/null 2>&1 || true
}
sent() { if [ -f "$W/log-$1" ]; then grep -c "severity=ERROR" "$W/log-$1" || true; else echo 0; fi; }
old=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
runner() { echo "{\"runners\":[{\"name\":\"worldai-testflight-native-mac\",\"status\":\"$1\"},{\"name\":\"other\",\"status\":\"online\"}]}"; }
runs() { echo "{\"workflow_runs\":[{\"name\":\"$1\",\"created_at\":\"$2\"}]}"; }
export STUB_RUNS_JSON STUB_RUNNERS_JSON

STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
[ "$(sent a)" = 1 ] || fail "offline + old queued TestFlight run must alert"; pass "offline + old queue alerts"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
[ "$(sent a)" = 1 ] || fail "second run inside cooldown must be throttled"; pass "throttled within cooldown"
jq '.last_sent = 1' "$W/state-a.json" > "$W/s.tmp" && mv "$W/s.tmp" "$W/state-a.json"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
[ "$(sent a)" = 2 ] || fail "alert must repeat after cooldown expiry"; pass "re-alerts after cooldown"
STUB_RUNNERS_JSON=$(runner online) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
grep -q "severity=INFO" "$W/log-a" || fail "recovery must write INFO"; pass "recovery logged"
STUB_RUNNERS_JSON=$(runner online) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run b
[ "$(sent b)" = 0 ] || fail "online runner must not alert"; pass "online no alert"
MAX_ONLINE_QUEUED_MIN=20 STUB_RUNNERS_JSON=$(runner online) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run m
[ "$(sent m)" = 1 ] || fail "online runner with stalled queue must alert"; grep -q "stalled" "$W/log-m" || fail "alert log must mention stalled"; pass "online + stalled queue alerts"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON='{"workflow_runs":[]}' run c
[ "$(sent c)" = 0 ] || fail "empty queue must not alert"; pass "offline + empty queue no alert"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$new") run d
[ "$(sent d)" = 0 ] || fail "young queue must not alert"; pass "young queue no alert"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "Mobile Check" "$old") run i
[ "$(sent i)" = 0 ] || fail "queued run of an unrelated workflow must not alert"; pass "other workflow ignored"
STUB_RUNNERS_JSON='{"runners":[]}' STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run e
[ "$(sent e)" = 1 ] || fail "unregistered runner (missing) must alert"; pass "missing runner alerts"
STUB_RUNNERS_JSON=$(runner online) run f --simulate-offline
[ "$(sent f)" = 1 ] || fail "--simulate-offline must alert"; pass "simulate-offline alerts"
run g --test-sms; grep -q TEST "$W/log-g" || fail "--test-sms must write a TEST entry"; pass "test-sms writes TEST entry"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run h --dry-run
[ ! -f "$W/log-h" ] || fail "--dry-run must not call gcloud"; pass "dry-run silent"
# gh outage: silent below 3 consecutive failures, one BLIND alert at 3
for _ in 1 2; do STUB_GH_FAIL=1 run j; done
[ "$(sent j)" = 0 ] || fail "two gh failures must not alert"
STUB_GH_FAIL=1 run j
grep -q "BLIND" "$W/log-j" || fail "third consecutive gh failure must emit a BLIND alert"; pass "gh outage escalates after 3"
# missing gcloud must fail loudly (exit 3) and leave no throttle state
rc=0
STATE_FILE="$W/state-k.json" GH_BIN="$W/gh" GCLOUD_BIN="" PATH=/usr/bin:/bin \
  STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") "$S" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "missing gcloud must exit 3, got $rc"
[ ! -f "$W/state-k.json" ] || fail "missing gcloud must not write throttle state"
pass "missing gcloud fails loudly with no state"
# --ensure-gcp-policy must invoke stub gcloud to ensure logging metric and monitoring policy, and fail 4 on missing policy
mkdir -p "$W/policy-json"
STUB_CAPTURE_DIR="$W/policy-json" run l --ensure-gcp-policy
grep -q "logging metrics create runner_offline_queued_alert_count" "$W/log-l" || fail "--ensure-gcp-policy must ensure logging metric"
grep -q "alpha monitoring policies create" "$W/log-l" || fail "--ensure-gcp-policy must ensure monitoring policy"
grep -Fq 'displayName="[CRITICAL] Runner offline with queued runs"' "$W/log-l" || fail "--ensure-gcp-policy must look up the renamed Slack policy"
[ -r "$W/policy-json/policy.json" ] || fail "policy generator must provide its JSON to the local gcloud stub"
SLACK_CHANNEL="projects/worldarchitecture-ai/notificationChannels/14071650426226468737"
jq -e --arg slack "$SLACK_CHANNEL" \
  '(.displayName == "[CRITICAL] Runner offline with queued runs" and .notificationChannels == [$slack] and .enabled == true and .severity == "CRITICAL" and .alertStrategy.autoClose == "1800s" and .alertStrategy.notificationPrompts == ["OPENED"]) and (.conditions[0].conditionThreshold.filter == "metric.type=\"logging.googleapis.com/user/runner_offline_queued_alert_count\" AND resource.type=\"global\"" and .conditions[0].conditionThreshold.comparison == "COMPARISON_GT" and .conditions[0].conditionThreshold.thresholdValue == 0 and .conditions[0].conditionThreshold.duration == "0s" and .conditions[0].conditionThreshold.aggregations[0].alignmentPeriod == "60s" and .conditions[0].conditionThreshold.aggregations[0].perSeriesAligner == "ALIGN_DELTA" and .conditions[0].conditionThreshold.trigger.count == 1)' \
  "$W/policy-json/policy.json" > /dev/null || fail "queue policy must be Slack-only with its existing enabled condition and threshold"
pass "offline queue policy stays enabled, Slack-only, and retains its exact threshold"
# A pre-cutover installation may still use the old SMS display name. Update that
# exact policy identity in place instead of creating a second alert policy.
mkdir -p "$W/legacy-policy-json"
legacy_policy_id="projects/worldarchitecture-ai/alertPolicies/8721806324101644324"
STUB_LEGACY_POLICY="$legacy_policy_id" STUB_CAPTURE_DIR="$W/legacy-policy-json" run legacy --ensure-gcp-policy
grep -Fq "alpha monitoring policies update $legacy_policy_id" "$W/log-legacy" || fail "legacy SMS-named policy must be updated in place"
if grep -q "alpha monitoring policies create" "$W/log-legacy"; then fail "legacy SMS-named policy must not create a duplicate"; fi
jq -e --arg slack "$SLACK_CHANNEL" '.displayName == "[CRITICAL] Runner offline with queued runs" and .notificationChannels == [$slack]' "$W/legacy-policy-json/policy.json" > /dev/null || fail "legacy policy update must converge to the live Slack-only name and destination"
pass "legacy SMS-named policy is renamed in place without a duplicate"
# Existing current and legacy matches, including duplicates, all converge in place.
current_policy_1="projects/worldarchitecture-ai/alertPolicies/9900000000000000001"
current_policy_2="projects/worldarchitecture-ai/alertPolicies/9900000000000000002"
legacy_policy_2="projects/worldarchitecture-ai/alertPolicies/9900000000000000003"
STUB_CURRENT_POLICY="$current_policy_1
$current_policy_2" STUB_LEGACY_POLICY="$legacy_policy_2" STUB_LOG="$W/log-converged" \
  STUB_CAPTURE_DIR="$W/converged-policy-json" STATE_FILE="$W/state-converged.json" \
  GCLOUD_BIN="$W/gcloud" GH_BIN="$W/gh" "$S" --ensure-gcp-policy > /dev/null 2>&1
for policy_id in "$current_policy_1" "$current_policy_2" "$legacy_policy_2"; do
  grep -Fq "alpha monitoring policies update $policy_id" "$W/log-converged" || fail "existing policy $policy_id must be updated in place"
done
[ "$(grep -c "alpha monitoring policies update" "$W/log-converged")" = 3 ] || fail "all three existing policy IDs must be updated once"
if grep -q "alpha monitoring policies create" "$W/log-converged"; then fail "existing current + legacy policies must not create another policy"; fi
jq -e --arg slack "$SLACK_CHANNEL" '.displayName == "[CRITICAL] Runner offline with queued runs" and .notificationChannels == [$slack]' "$W/converged-policy-json/policy.json" > /dev/null || fail "every existing policy update must use the canonical Slack-only definition"
pass "all existing current and legacy policy matches converge in place without creating duplicates"
rc=0; STATE_FILE="$W/state-missing-policy.json" POLICY_FILE="$W/nonexistent.json" GCLOUD_BIN="$W/gcloud" "$S" --ensure-gcp-policy >/dev/null 2>&1 || rc=$?
[ "$rc" = 4 ] || fail "missing POLICY_FILE must exit 4, got $rc"
pass "ensure-gcp-policy ensures metric and policy and fails closed on missing file"
