#!/usr/bin/env bash
# Hermetic tests for GitHub Actions cost & hosted-macOS usage spike monitoring.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/gh-actions-cost-alert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

mkdir -p "$TMP/home/.config/ezgha" "$TMP/bin"
printf 'app-installation-token-must-not-be-used\n' > "$TMP/home/.config/ezgha/gh_token"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'args=%s|GH_TOKEN=%s|GITHUB_TOKEN=%s\n' "$*" "${GH_TOKEN-<unset>}" "${GITHUB_TOKEN-<unset>}" >> "${GH_CALL_LOG:?}"
if [ -n "${GH_STUB_SLEEP:-}" ]; then
  sleep "${GH_STUB_SLEEP}"
fi
if [ -n "${GH_STUB_FAIL:-}" ]; then
  exit 1
fi
is_app_token=0
if [ "${GH_TOKEN:-}" = "app-installation-token-must-not-be-used" ] || [ "${GH_TOKEN:-}" = "app-fallback-token" ]; then
  is_app_token=1
fi
case "$*" in
  *"api rate_limit"*)
    if [ "$is_app_token" -eq 1 ]; then
      remaining="${APP_RATE_LIMIT_REMAINING:-10200}"
    else
      remaining="${RATE_LIMIT_REMAINING:-4500}"
    fi
    printf '{"resources":{"core":{"remaining":%s}}}\n' "$remaining" | jq -r '.resources.core.remaining // empty'
    ;;
  *"/organizations/"*"/settings/billing/usage"*|*"orgs/"*"/settings/billing/usage"*)
    if [ -n "${BILLING_STUB_FAIL:-}" ]; then
      echo "gh: HTTP 403: Resource not accessible" >&2
      exit 1
    fi
    if [[ "$*" == *"month=11&day=30"* ]]; then
      if [ -n "${BILLING_PREV_STUB_FAIL:-}" ]; then
        echo "gh: HTTP 503: previous month unavailable" >&2
        exit 1
      fi
      if [ -n "${BILLING_PREV_FIXTURE:-}" ]; then
        cat "$BILLING_PREV_FIXTURE"
        exit 0
      fi
    fi
    cat "${BILLING_FIXTURE:?}"
    ;;
  *"orgs/"*"/repos"*)
    cat "${REPOS_FIXTURE:?}"
    ;;
  *"/actions/runs/"*"/jobs"*)
    if [ -n "${JOBS_STUB_FAIL:-}" ]; then
      echo "gh: HTTP 500: jobs fetch error" >&2
      exit 1
    fi
    run_id="$(printf '%s' "$*" | sed -E 's#.*/actions/runs/([0-9]+)/jobs.*#\1#')"
    page_num=1
    page_re='[&?]page=([0-9]+)'
    if [[ "$*" =~ $page_re ]]; then
      page_num="${BASH_REMATCH[1]}"
    fi
    if [ -n "${JOBS_FIXTURE_DIR:-}" ] && [ -f "${JOBS_FIXTURE_DIR}/${run_id}_p${page_num}.json" ]; then
      cat "${JOBS_FIXTURE_DIR}/${run_id}_p${page_num}.json"
    elif [ -n "${JOBS_FIXTURE_DIR:-}" ] && [ -f "${JOBS_FIXTURE_DIR}/${run_id}.json" ]; then
      cat "${JOBS_FIXTURE_DIR}/${run_id}.json"
    else
      printf '{"jobs":[]}\n'
    fi
    ;;
  *"/actions/runs"*)
    if [ -n "${RUNS_STUB_FAIL:-}" ]; then
      echo "gh: HTTP 500: runs fetch error" >&2
      exit 1
    fi
    cat "${RUNS_FIXTURE:?}"
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 99
    ;;
esac
STUB

cat > "$TMP/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GCLOUD_LOG:?}"
if [ -n "${GCLOUD_STUB_SLEEP:-}" ]; then
  sleep "${GCLOUD_STUB_SLEEP}"
fi
if [ -n "${GCLOUD_WRITE_FAIL:-}" ] && [[ "$*" == *"logging write"* ]]; then
  echo "gcloud: transient logging write failure" >&2
  exit 1
fi
if [ -n "${GCLOUD_POLICY_FAIL:-}" ] && [[ "$*" == *"alpha monitoring policies"* ]]; then
  echo "gcloud: policy API permission denied" >&2
  exit 1
fi
for arg in "$@"; do
  case "$arg" in
    --policy-from-file=*)
      cat "${arg#*=}" >> "${GCLOUD_LOG:?}"
      jq -c . "${arg#*=}" >> "${POLICY_HISTORY:?}"
      cp "${arg#*=}" "${POLICY_CAPTURE:?}"
      ;;
  esac
done
if [[ "$*" == *"alpha monitoring policies list"* ]]; then
  [ -z "${STUB_EXISTING_POLICY:-}" ] || printf '%s\n' "$STUB_EXISTING_POLICY"
fi
STUB

chmod +x "$TMP/bin/gh" "$TMP/bin/gcloud"

run_alert() {
  local state_file="$1" gcloud_log="$2" gh_log="$3"
  shift 3
  HOME="$TMP/home" \
  GH_BIN="$TMP/bin/gh" \
  GCLOUD_BIN="$TMP/bin/gcloud" \
  STATE_FILE="$state_file" \
  BILLING_FIXTURE="${BILLING_FIXTURE:-$TMP/billing.json}" \
  GCLOUD_LOG="$gcloud_log" \
  GH_CALL_LOG="$gh_log" \
  POLICY_CAPTURE="$TMP/policy.json" \
  POLICY_HISTORY="$TMP/policy-history.jsonl" \
  TARGET_DATE_UTC="${TARGET_DATE_UTC:-2026-11-18}" \
  "$SCRIPT" "$@"
}

error_count() {
  local log="$1"
  if [ -f "$log" ]; then
    grep -c 'severity=ERROR' "$log" || true
  else
    echo 0
  fi
}

# 1. Healthy low usage -> exit 0, zero ERROR logs written.
cat > "$TMP/billing.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions Linux","quantity":45.0,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":2.90,"discountAmount":2.88,"netAmount":0.02,"organizationName":"jleechanorg","repositoryName":"ez-gh-actions"}
  ]
}
JSON
run_alert "$TMP/state-healthy.json" "$TMP/gcloud-healthy.log" "$TMP/gh-healthy.log" >/dev/null
[ "$(error_count "$TMP/gcloud-healthy.log")" = 0 ] || fail "healthy low usage must emit zero ERROR logs"
pass "healthy low usage exits 0 with zero ERROR logs"

# 2. Exact Nov 17 gross macOS spike -> emits ERROR with source="gh-actions-cost-alert", status="COST_SPIKE",
#    citing disk_magician, 2389 macOS min, and $148.12 gross (even when evaluated on Nov 18 UTC).
cat > "$TMP/billing.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-17T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":2389.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":148.12,"discountAmount":148.12,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"},
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions Linux","quantity":20.0,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":0.12,"discountAmount":0.12,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"ez-gh-actions"}
  ]
}
JSON
run_alert "$TMP/state-spike.json" "$TMP/gcloud-spike.log" "$TMP/gh-spike.log" >/dev/null
[ "$(error_count "$TMP/gcloud-spike.log")" = 1 ] || fail "Nov 17 gross macOS spike must emit exactly 1 ERROR log"
grep -q 'logging write ezgha-runner-alerts ' "$TMP/gcloud-spike.log" || fail "alert must write to ezgha-runner-alerts"
grep -q '"source":"gh-actions-cost-alert"' "$TMP/gcloud-spike.log" || fail "payload must set source=gh-actions-cost-alert"
grep -q '"status":"COST_SPIKE"' "$TMP/gcloud-spike.log" || fail "payload must set status=COST_SPIKE"
grep -q 'disk_magician' "$TMP/gcloud-spike.log" || fail "message must cite top repo disk_magician"
grep -q '2389' "$TMP/gcloud-spike.log" || fail "message must cite 2389 macOS min"
grep -q '\$148\.12' "$TMP/gcloud-spike.log" || fail "message must cite \$148.12 gross"
! grep -q '"cause":"fleet"' "$TMP/gcloud-spike.log" || fail "cost alert must never emit cause=fleet"
pass "Nov 17 gross macOS spike emits COST_SPIKE ERROR citing repo, minutes, and gross USD"

# 3. Cooldown suppression & independent net-spend breach alert.
run_alert "$TMP/state-spike.json" "$TMP/gcloud-spike.log" "$TMP/gh-spike.log" >/dev/null
[ "$(error_count "$TMP/gcloud-spike.log")" = 1 ] || fail "immediate re-run within COOLDOWN_SEC must suppress duplicate COST_SPIKE ERROR"
cat > "$TMP/billing.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-17T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":2389.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":148.12,"discountAmount":148.12,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"},
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":10.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":16.00,"discountAmount":1.00,"netAmount":15.00,"organizationName":"jleechanorg","repositoryName":"worldai_frontend"}
  ]
}
JSON
run_alert "$TMP/state-spike.json" "$TMP/gcloud-spike.log" "$TMP/gh-spike.log" >/dev/null
[ "$(error_count "$TMP/gcloud-spike.log")" = 2 ] || fail "jump to netAmount=15.00 (>= DAILY_NET_WARN_USD=10) must alert despite COST_SPIKE cooldown"
pass "cooldown suppresses same day/status while net-spend breach still alerts"

# 4. BLIND handling: 3 consecutive gh failures emit WARNING with status="BLIND" without advancing last_sent,
#    so a subsequent COST_SPIKE immediately emits ERROR.
cat > "$TMP/billing.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-17T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":2389.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":148.12,"discountAmount":148.12,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"}
  ]
}
JSON
for _ in 1 2 3; do
  GH_STUB_FAIL=1 run_alert "$TMP/state-blind.json" "$TMP/gcloud-blind.log" "$TMP/gh-blind.log" >/dev/null 2>&1 || true
done
[ "$(error_count "$TMP/gcloud-blind.log")" = 0 ] || fail "BLIND must not emit ERROR"
grep -q 'severity=WARNING' "$TMP/gcloud-blind.log" || fail "3 consecutive gh failures must emit WARNING"
grep -q '"status":"BLIND"' "$TMP/gcloud-blind.log" || fail "3 consecutive gh failures must emit status=BLIND"
[ "$(jq -r '.last_sent // 0' "$TMP/state-blind.json")" = 0 ] || fail "BLIND must not advance last_sent"
run_alert "$TMP/state-blind.json" "$TMP/gcloud-blind.log" "$TMP/gh-blind.log" >/dev/null
[ "$(error_count "$TMP/gcloud-blind.log")" = 1 ] || fail "COST_SPIKE immediately after BLIND must emit ERROR"
pass "BLIND emits WARNING after 3 failures without advancing last_sent"

# 5. --ensure-gcp-policy --dry-run: valid policy JSON routed to Slack channel, never cause="fleet".
policy_json="$(run_alert "$TMP/state-policy.json" "$TMP/gcloud-policy.log" "$TMP/gh-policy.log" --ensure-gcp-policy --dry-run)"
[ ! -e "$TMP/state-policy.json" ] || fail "--ensure-gcp-policy --dry-run must not write persistent state"
[ ! -e "$TMP/gcloud-policy.log" ] || fail "--ensure-gcp-policy --dry-run must not invoke gcloud"
jq -e '
  .displayName == "[CRITICAL] GitHub Actions cost or hosted macOS spike"
  and .notificationChannels == ["projects/worldarchitecture-ai/notificationChannels/14071650426226468737"]
  and .enabled == true
  and .severity == "CRITICAL"
  and (.conditions[0].conditionMatchedLog.filter | contains("jsonPayload.source=\"gh-actions-cost-alert\"") and contains("severity>=ERROR") and (contains("cause=\"fleet\"") | not))
' <<<"$policy_json" >/dev/null || fail "--ensure-gcp-policy --dry-run emitted invalid or fleet-coupled policy JSON"
pass "--ensure-gcp-policy --dry-run outputs valid Slack-only policy JSON isolated from cause=fleet"

# 6. Auth isolation: ignores ~/.config/ezgha/gh_token and pre-existing GH_TOKEN unless GH_BILLING_TOKEN is set.
: > "$TMP/gh-auth.log"
GH_TOKEN="wrong-app-token" GITHUB_TOKEN="wrong-env-token" \
  run_alert "$TMP/state-auth.json" "$TMP/gcloud-auth.log" "$TMP/gh-auth.log" >/dev/null
grep -q '|GH_TOKEN=<unset>|GITHUB_TOKEN=<unset>' "$TMP/gh-auth.log" || fail "script must unset GH_TOKEN/GITHUB_TOKEN when GH_BILLING_TOKEN is unset"
! grep -q 'wrong-app-token\|app-installation-token-must-not-be-used' "$TMP/gh-auth.log" || fail "script must never pass App/ambient GH_TOKEN"

: > "$TMP/gh-auth2.log"
GH_BILLING_TOKEN="explicit-billing-pat" GH_TOKEN="wrong-app-token" \
  run_alert "$TMP/state-auth2.json" "$TMP/gcloud-auth2.log" "$TMP/gh-auth2.log" >/dev/null
grep -q '|GH_TOKEN=explicit-billing-pat|' "$TMP/gh-auth2.log" || fail "GH_BILLING_TOKEN must be exported as GH_TOKEN when provided"
pass "auth isolation avoids App token and honors GH_BILLING_TOKEN"

# 7. Rate-limit guard: core.remaining < 50 skips billing API and counts toward BLIND when no App fallback exists.
: > "$TMP/gh-rl.log"
for _ in 1 2 3; do
  APP_TOKEN_FILE="$TMP/no-app-token" RATE_LIMIT_REMAINING=12 run_alert "$TMP/state-rl.json" "$TMP/gcloud-rl.log" "$TMP/gh-rl.log" >/dev/null 2>&1 || true
done
! grep -q 'settings/billing/usage' "$TMP/gh-rl.log" || fail "low core rate limit (<50) must skip /settings/billing/usage"
grep -q '"status":"BLIND"' "$TMP/gcloud-rl.log" || fail "repeated low rate-limit skips without fallback must emit BLIND WARNING"
pass "rate_limit < 50 skips billing query and triggers BLIND after 3 cycles"

# 8. --dry-run must not mutate persistent state or invoke gcloud.
before_sha="$(shasum -a 256 "$TMP/state-spike.json")"
run_alert "$TMP/state-spike.json" "$TMP/gcloud-dryrun.log" "$TMP/gh-dryrun.log" --dry-run >/dev/null
after_sha="$(shasum -a 256 "$TMP/state-spike.json")"
[ "$before_sha" = "$after_sha" ] || fail "--dry-run must not modify existing STATE_FILE"
[ ! -e "$TMP/gcloud-dryrun.log" ] || fail "--dry-run must not call gcloud"
pass "--dry-run preserves STATE_FILE and does not invoke gcloud"

# 9. Bounded App-token fallback when personal rate_limit=0 (or billing returns 403):
#    - Scans BOTH YESTERDAY_UTC and TODAY_UTC (created=YESTERDAY..TODAY)
#    - Evaluates daily gross/macOS only: net_usd=null, mtd_gross=null, mtd_net=null (no NET_SPEND_BREACH or MTD_SPEND_BREACH)
#    - Immediately fires ERROR COST_SPIKE on >= 60m macos-15 (even on yesterday!)
#    - Preserves api_failures toward BLIND (only authoritative /organizations/.../settings/billing/usage resets api_failures)
mkdir -p "$TMP/jobs"
cat > "$TMP/repos.json" <<'JSON'
[
  {"name":"disk_magician","full_name":"jleechanorg/disk_magician","private":true,"pushed_at":"2026-11-18T00:30:00Z"}
]
JSON
cat > "$TMP/runs.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9001,"status":"completed","conclusion":"success","created_at":"2026-11-17T10:10:00Z"},
    {"id":9002,"status":"completed","conclusion":"skipped","created_at":"2026-11-18T00:20:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9001.json" <<'JSON'
{
  "jobs": [
    {"id":1,"labels":["macos-15"],"started_at":"2026-11-17T10:00:00Z","completed_at":"2026-11-17T11:15:00Z"},
    {"id":2,"labels":["ubuntu-latest"],"started_at":"2026-11-17T10:00:00Z","completed_at":"2026-11-17T10:10:00Z"},
    {"id":3,"labels":["self-hosted-native-macos"],"started_at":"2026-11-17T10:00:00Z","completed_at":"2026-11-17T12:00:00Z"}
  ]
}
JSON
: > "$TMP/gh-fallback.log"
fallback_stdout="$(
  RATE_LIMIT_REMAINING=0 APP_RATE_LIMIT_REMAINING=10200 \
  REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-fallback.json" "$TMP/gcloud-fallback.log" "$TMP/gh-fallback.log"
)"
[ "$(error_count "$TMP/gcloud-fallback.log")" = 1 ] || fail "App-token fallback with private 75m macos-15 yesterday must emit exactly 1 COST_SPIKE ERROR (never NET_SPEND_BREACH or MTD_SPEND_BREACH)"
! grep -q '"status":"BLIND"' "$TMP/gcloud-fallback.log" || fail "single fallback cycle (api_failures=1 < 3) must not emit BLIND yet"
grep -q '"status":"COST_SPIKE"' "$TMP/gcloud-fallback.log" || fail "App-token fallback must emit status=COST_SPIKE"
grep -q '"day":"2026-11-17"' "$TMP/gcloud-fallback.log" || fail "App-token fallback must attribute yesterday run to 2026-11-17"
grep -q '"mode":"app_token_fallback"' "$TMP/gcloud-fallback.log" || fail "App-token fallback payload must set mode=app_token_fallback"
grep -q '"net_usd":null' "$TMP/gcloud-fallback.log" || fail "App-token fallback payload must set net_usd=null"
grep -q '"mtd_gross":null' "$TMP/gcloud-fallback.log" || fail "App-token fallback payload must set mtd_gross=null"
grep -q '"mtd_net":null' "$TMP/gcloud-fallback.log" || fail "App-token fallback payload must set mtd_net=null"
grep -q 'disk_magician' "$TMP/gcloud-fallback.log" || fail "App-token fallback alert must cite disk_magician"
grep -q '"macos_minutes":75' "$TMP/gcloud-fallback.log" || fail "App-token fallback alert must cite macos_minutes=75 (excluding self-hosted)"
grep -q 'mode=app_token_fallback' <<<"$fallback_stdout" || fail "fallback stdout must label mode=app_token_fallback"
grep -q 'mtd_gross=null' <<<"$fallback_stdout" || fail "fallback stdout must label mtd_gross=null"
grep -q 'mtd_net=null' <<<"$fallback_stdout" || fail "fallback stdout must label mtd_net=null"
grep -q 'orgs/jleechanorg/repos?sort=pushed&per_page=100|GH_TOKEN=app-installation-token-must-not-be-used' "$TMP/gh-fallback.log" || fail "App-token fallback must query org repos with per_page=100 using APP_TOKEN_FILE"
grep -q 'repos/jleechanorg/disk_magician/actions/runs?per_page=100|GH_TOKEN=app-installation-token-must-not-be-used' "$TMP/gh-fallback.log" || fail "App-token fallback must query actions/runs?per_page=100 without created-only filter"
grep -q 'repos/jleechanorg/disk_magician/actions/runs/9001/jobs?filter=all&per_page=100&page=1|GH_TOKEN=app-installation-token-must-not-be-used' "$TMP/gh-fallback.log" || fail "App-token fallback must query job details with filter=all&per_page=100&page=1 using APP_TOKEN_FILE"
! grep -q 'runs/9002/jobs' "$TMP/gh-fallback.log" || fail "skipped runs must not consume job API calls"
[ "$(jq -r '.api_failures' "$TMP/state-fallback.json")" = 1 ] || fail "fallback must increment api_failures instead of resetting to 0"

# Run 2 more fallback cycles (total 3 consecutive primary failures even though fallback detected spike):
# MUST still emit WARNING BLIND at api_failures=3, and only recover api_failures=0 when primary billing succeeds!
for _ in 2 3; do
  RATE_LIMIT_REMAINING=0 APP_RATE_LIMIT_REMAINING=10200 \
    REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
    run_alert "$TMP/state-fallback.json" "$TMP/gcloud-fallback.log" "$TMP/gh-fallback.log" >/dev/null
done
[ "$(jq -r '.api_failures' "$TMP/state-fallback.json")" = 3 ] || fail "3 fallback runs must record api_failures=3"
grep -q '"status":"BLIND"' "$TMP/gcloud-fallback.log" || fail "3 consecutive billing skips with fallback must still emit WARNING BLIND"
# Primary billing recovery resets api_failures=0
cat > "$TMP/billing.json" <<'JSON'
{"usageItems": [{"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions Linux","quantity":10.0,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":0.06,"discountAmount":0.06,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"ez-gh-actions"}]}
JSON
run_alert "$TMP/state-fallback.json" "$TMP/gcloud-fallback.log" "$TMP/gh-fallback.log" >/dev/null
[ "$(jq -r '.api_failures' "$TMP/state-fallback.json")" = 0 ] || fail "successful authoritative billing query must reset api_failures=0"
pass "App-token fallback scans yesterday..today gross-only, preserves api_failures toward BLIND, and resets on billing recovery"

# 10. Truncated/incomplete App-token fallback (MAX_APP_API_CALLS=2, page-size truncation, or API error):
#     - Respects MAX_APP_API_CALLS=2 (<= 2 App calls)
#     - Labels mode=app_token_fallback_partial (never OK with $0)
#     - Emits WARNING BLIND after 3 cycles noting partial fallback / MAX_APP_API_CALLS
: > "$TMP/gh-fallback-403.log"
for cycle in 1 2 3; do
  partial_out="$(
    BILLING_STUB_FAIL=1 RATE_LIMIT_REMAINING=4500 APP_RATE_LIMIT_REMAINING=10200 MAX_APP_API_CALLS=2 \
    REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
    run_alert "$TMP/state-fallback403.json" "$TMP/gcloud-fallback403.log" "$TMP/gh-fallback-403.log"
  )"
  ! grep -q ' OK:' <<<"$partial_out" || fail "truncated fallback must never report OK"
  grep -q 'mode=app_token_fallback_partial' <<<"$partial_out" || fail "truncated fallback stdout must set mode=app_token_fallback_partial"
  grep -q 'mtd_gross=null' <<<"$partial_out" || fail "truncated fallback stdout must set mtd_gross=null"
  grep -q 'mtd_net=null' <<<"$partial_out" || fail "truncated fallback stdout must set mtd_net=null"
  if [ "$cycle" -eq 1 ]; then
    app_calls="$(grep -c '|GH_TOKEN=app-installation-token-must-not-be-used|' "$TMP/gh-fallback-403.log" || true)"
    [ "$app_calls" -le 2 ] || fail "MAX_APP_API_CALLS=2 cap exceeded: got $app_calls calls"
  fi
done
grep -q '"status":"BLIND"' "$TMP/gcloud-fallback403.log" || fail "3 cycles of billing 403 + truncated MAX_APP_API_CALLS=2 must emit WARNING BLIND"
grep -q 'MAX_APP_API_CALLS' "$TMP/gcloud-fallback403.log" || fail "BLIND message must note MAX_APP_API_CALLS truncation"

# Also check page-size=15 repos, page-size=50 runs, and mid-loop gh api failure mark mode=app_token_fallback_partial.
python3 - "$TMP/repos15.json" <<'PY'
import json, sys
repos = [{"name": f"repo-{i}", "full_name": f"jleechanorg/repo-{i}", "private": False, "pushed_at": "2026-11-17T12:00:00Z"} for i in range(15)]
open(sys.argv[1], "w").write(json.dumps(repos))
PY
python3 - "$TMP/runs50.json" <<'PY'
import json, sys
runs = {"workflow_runs": [{"id": 8000 + i, "status": "completed", "conclusion": "skipped", "created_at": "2026-11-18T00:00:00Z"} for i in range(50)]}
open(sys.argv[1], "w").write(json.dumps(runs))
PY
python3 - "$TMP/runs50-old.json" <<'PY'
import json, sys
runs = {"workflow_runs": [{"id": 8500 + i, "status": "completed", "conclusion": "skipped", "created_at": "2026-10-01T00:00:00Z"} for i in range(50)]}
open(sys.argv[1], "w").write(json.dumps(runs))
PY
partial_repos15="$(FALLBACK_REPOS_PER_PAGE=15 BILLING_STUB_FAIL=1 MAX_APP_API_CALLS=60 REPOS_FIXTURE="$TMP/repos15.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" run_alert "$TMP/state-r15.json" "$TMP/gcloud-r15.log" "$TMP/gh-r15.log")"
grep -q 'mode=app_token_fallback_partial' <<<"$partial_repos15" || fail "repo page saturation must mark mode=app_token_fallback_partial"
partial_runs50="$(FALLBACK_RUNS_PER_PAGE=50 BILLING_STUB_FAIL=1 MAX_APP_API_CALLS=60 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs50.json" JOBS_FIXTURE_DIR="$TMP/jobs" run_alert "$TMP/state-r50.json" "$TMP/gcloud-r50.log" "$TMP/gh-r50.log")"
grep -q 'mode=app_token_fallback_partial' <<<"$partial_runs50" || fail "run page saturation must mark mode=app_token_fallback_partial"
partial_runs50_old="$(FALLBACK_RUNS_PER_PAGE=50 BILLING_STUB_FAIL=1 MAX_APP_API_CALLS=60 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs50-old.json" JOBS_FIXTURE_DIR="$TMP/jobs" run_alert "$TMP/state-r50old.json" "$TMP/gcloud-r50old.log" "$TMP/gh-r50old.log")"
grep -q 'mode=app_token_fallback_partial' <<<"$partial_runs50_old" || fail "run page saturation must mark mode=app_token_fallback_partial regardless of oldest created_at"
partial_err="$(BILLING_STUB_FAIL=1 RUNS_STUB_FAIL=1 MAX_APP_API_CALLS=60 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" run_alert "$TMP/state-rerr.json" "$TMP/gcloud-rerr.log" "$TMP/gh-rerr.log")"
grep -q 'mode=app_token_fallback_partial' <<<"$partial_err" || fail "mid-loop gh api failure must mark mode=app_token_fallback_partial"
pass "incomplete/truncated fallback marks app_token_fallback_partial and preserves BLIND alerting"

# 11. Month rollover: TARGET_DATE_UTC=2026-12-01 fetches both month=12 and month=11&day=30,
#     detects 2026-11-30 spike, and does NOT include 2026-11-30 in 2026-12 MTD totals.
cat > "$TMP/billing.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-12-01T00:15:00Z","product":"actions","sku":"Actions Linux","quantity":20.0,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":0.12,"discountAmount":0.12,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"ez-gh-actions"}
  ]
}
JSON
cat > "$TMP/billing-prev.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-30T23:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":2389.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":148.12,"discountAmount":148.12,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"}
  ]
}
JSON
: > "$TMP/gh-rollover.log"
rollover_out="$(
  TARGET_DATE_UTC=2026-12-01 \
  BILLING_PREV_FIXTURE="$TMP/billing-prev.json" \
  run_alert "$TMP/state-rollover.json" "$TMP/gcloud-rollover.log" "$TMP/gh-rollover.log"
)"
grep -q '/organizations/jleechanorg/settings/billing/usage?year=2026&month=12' "$TMP/gh-rollover.log" || fail "must query /organizations/jleechanorg/settings/billing/usage for current month"
grep -q '/organizations/jleechanorg/settings/billing/usage?year=2026&month=11&day=30' "$TMP/gh-rollover.log" || fail "must query previous month day=30 on month rollover"
[ "$(error_count "$TMP/gcloud-rollover.log")" = 1 ] || fail "2026-11-30 spike must emit exactly 1 ERROR on 2026-12-01"
grep -q '"day":"2026-11-30"' "$TMP/gcloud-rollover.log" || fail "rollover alert must cite day 2026-11-30"
grep -q 'mtd_gross=\$0.12' <<<"$rollover_out" || fail "2026-12 MTD must exclude 2026-11-30 usage (got: $rollover_out)"
pass "month rollover fetches previous month day, alerts on yesterday spike, and scopes MTD to current month"

# 12. Fallback ignores pushed_at cutoff and includes cross-midnight updated_at + in_progress runs.
cat > "$TMP/repos-oldpush.json" <<'JSON'
[
  {"name":"scheduled_ci","full_name":"jleechanorg/scheduled_ci","private":true,"pushed_at":"2026-10-01T00:00:00Z"}
]
JSON
cat > "$TMP/runs-cross.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9101,"status":"completed","conclusion":"success","created_at":"2026-11-16T23:55:00Z","updated_at":"2026-11-17T01:20:00Z"},
    {"id":9102,"status":"in_progress","conclusion":null,"created_at":"2026-11-15T10:00:00Z","updated_at":"2026-11-15T10:05:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9101.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":1,"labels":["macos-15"],"started_at":"2026-11-17T00:05:00Z","completed_at":"2026-11-17T01:20:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9102.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":2,"labels":["ubuntu-latest"],"started_at":"2026-11-18T00:00:00Z","completed_at":null}
  ]
}
JSON
: > "$TMP/gh-oldpush.log"
BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos-oldpush.json" RUNS_FIXTURE="$TMP/runs-cross.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-oldpush.json" "$TMP/gcloud-oldpush.log" "$TMP/gh-oldpush.log" >/dev/null
[ "$(error_count "$TMP/gcloud-oldpush.log")" = 1 ] || fail "fallback must scan old pushed_at repos and cross-midnight runs"
grep -q '"day":"2026-11-17"' "$TMP/gcloud-oldpush.log" || fail "cross-midnight job starting 2026-11-17 must alert on 2026-11-17"
grep -q 'runs/9102/jobs' "$TMP/gh-oldpush.log" || fail "in_progress run must be inspected even with older timestamps"
pass "fallback scans independent of pushed_at and captures cross-midnight and in_progress runs"

# 13. Fallback paginates jobs (?filter=all&per_page=100&page=N) and marks partial if budget prevents page 2.
cat > "$TMP/runs-page.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9201,"status":"completed","conclusion":"success","created_at":"2026-11-18T00:10:00Z","updated_at":"2026-11-18T01:30:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9201_p1.json" <<'JSON'
{
  "total_count": 2,
  "jobs": [
    {"id":11,"labels":["ubuntu-latest"],"started_at":"2026-11-18T00:10:00Z","completed_at":"2026-11-18T00:15:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9201_p2.json" <<'JSON'
{
  "total_count": 2,
  "jobs": [
    {"id":12,"labels":["macos-15"],"started_at":"2026-11-18T00:15:00Z","completed_at":"2026-11-18T01:30:00Z"}
  ]
}
JSON
: > "$TMP/gh-jobpage.log"
jobpage_out="$(
  BILLING_STUB_FAIL=1 FALLBACK_JOBS_PER_PAGE=1 MAX_APP_API_CALLS=10 \
  REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-page.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-jobpage.json" "$TMP/gcloud-jobpage.log" "$TMP/gh-jobpage.log"
)"
grep -q 'runs/9201/jobs?filter=all&per_page=1&page=2' "$TMP/gh-jobpage.log" || fail "fallback must paginate remaining job pages"
[ "$(error_count "$TMP/gcloud-jobpage.log")" = 1 ] || fail "paginated page-2 macos-15 spike must emit COST_SPIKE"
grep -q 'mode=app_token_fallback ' <<<"$jobpage_out" || fail "fully paginated jobs must report mode=app_token_fallback"

jobpage_cap_out="$(
  BILLING_STUB_FAIL=1 FALLBACK_JOBS_PER_PAGE=1 MAX_APP_API_CALLS=4 \
  REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-page.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-jobpage-cap.json" "$TMP/gcloud-jobpage-cap.log" "$TMP/gh-jobpage-cap.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$jobpage_cap_out" || fail "truncated job pagination under MAX_APP_API_CALLS must report app_token_fallback_partial"
pass "fallback paginates jobs with filter=all and marks partial when call budget blocks remaining pages"

# 14. Fallback prices windows-* ($0.010/min) and marks unpriced hosted runners partial.
cat > "$TMP/runs-win.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9301,"status":"completed","conclusion":"success","created_at":"2026-11-18T01:00:00Z","updated_at":"2026-11-18T06:00:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9301.json" <<'JSON'
{
  "total_count": 10,
  "jobs": [
    {"id":21,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":22,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":23,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":24,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":25,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":26,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":27,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":28,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":29,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"},
    {"id":30,"labels":["windows-latest"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T06:00:00Z"}
  ]
}
JSON
BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-win.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-win.json" "$TMP/gcloud-win.log" "$TMP/gh-win.log" >/dev/null
[ "$(error_count "$TMP/gcloud-win.log")" = 1 ] || fail "3000m windows-latest (\$30.00 >= \$25) must emit COST_SPIKE"
grep -q '\$30\.00' "$TMP/gcloud-win.log" || fail "windows-latest fallback must price 3000m at \$30.00"

cat > "$TMP/jobs/9301.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":31,"labels":["custom-hosted-gpu"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T02:00:00Z"}
  ]
}
JSON
unpriced_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-win.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-unpriced.json" "$TMP/gcloud-unpriced.log" "$TMP/gh-unpriced.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$unpriced_out" || fail "unpriced hosted runner label must mark mode=app_token_fallback_partial"
pass "fallback prices windows-* jobs and marks unpriced hosted runners partial"

# 15. Wall-clock timeout bounds stalled primary gh api calls (even without timeout/gtimeout binaries).
mkdir -p "$TMP/nobin"
ln -s "$(command -v bash)" "$TMP/nobin/bash"
ln -s "$(command -v jq)" "$TMP/nobin/jq"
ln -s "$(command -v awk)" "$TMP/nobin/awk"
ln -s "$(command -v date)" "$TMP/nobin/date"
ln -s "$(command -v sed)" "$TMP/nobin/sed"
ln -s "$(command -v tr)" "$TMP/nobin/tr"
ln -s "$(command -v mktemp)" "$TMP/nobin/mktemp"
ln -s "$(command -v mkdir)" "$TMP/nobin/mkdir"
ln -s "$(command -v rmdir)" "$TMP/nobin/rmdir"
ln -s "$(command -v sleep)" "$TMP/nobin/sleep"
ln -s "$(command -v rm)" "$TMP/nobin/rm"
ln -s "$(command -v mv)" "$TMP/nobin/mv"
ln -s "$(command -v cp)" "$TMP/nobin/cp"
ln -s "$(command -v dirname)" "$TMP/nobin/dirname"
ln -s "$(command -v cat)" "$TMP/nobin/cat"
start_ts="$(date +%s)"
PATH="$TMP/nobin" GH_STUB_SLEEP=6 GH_CALL_TIMEOUT_SEC=1 APP_TOKEN_FILE="$TMP/no-app-token" \
  run_alert "$TMP/state-timeout.json" "$TMP/gcloud-timeout.log" "$TMP/gh-timeout.log" >/dev/null 2>&1 || true
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))
[ "$elapsed" -lt 5 ] || fail "stalled gh api call must be killed by GH_CALL_TIMEOUT_SEC=1 (took ${elapsed}s)"
[ "$(jq -r '.api_failures' "$TMP/state-timeout.json")" = 1 ] || fail "timed-out gh api call must increment api_failures"
pass "wall-clock timeout bounds stalled gh calls cleanly"

# 16. Day-1 rollover failure preserves current-month spikes & api_failures=0 resets only after jq parse succeeds.
cat > "$TMP/billing-dec.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-12-01T00:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":20.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":60.00,"discountAmount":10.00,"netAmount":50.00,"organizationName":"jleechanorg","repositoryName":"worldai_frontend"}
  ]
}
JSON
rollover_fail_out="$(
  TARGET_DATE_UTC=2026-12-01 \
  BILLING_PREV_STUB_FAIL=1 \
  BILLING_FIXTURE="$TMP/billing-dec.json" \
  HOME="$TMP/home" GH_BIN="$TMP/bin/gh" GCLOUD_BIN="$TMP/bin/gcloud" \
  STATE_FILE="$TMP/state-rollover-fail.json" GCLOUD_LOG="$TMP/gcloud-rollover-fail.log" \
  GH_CALL_LOG="$TMP/gh-rollover-fail.log" POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" \
  "$SCRIPT"
)"
grep -q '"status":"COST_SPIKE"' "$TMP/gcloud-rollover-fail.log" || fail "day-1 rollover failure must still emit current-month COST_SPIKE"
grep -q '"status":"NET_SPEND_BREACH"' "$TMP/gcloud-rollover-fail.log" || fail "day-1 rollover failure must still emit current-month NET_SPEND_BREACH"
grep -q '"status":"MTD_SPEND_BREACH"' "$TMP/gcloud-rollover-fail.log" || fail "day-1 rollover failure must still emit current-month MTD_SPEND_BREACH"
grep -q 'mode=billing_api_partial' <<<"$rollover_fail_out" || fail "day-1 rollover failure must report mode=billing_api_partial"
[ "$(jq -r '.api_failures' "$TMP/state-rollover-fail.json")" = 1 ] || fail "day-1 rollover failure must increment api_failures instead of resetting to 0"

cat > "$TMP/billing-badjson.json" <<'JSON'
{"usageItems":[{"date":"2026-11-18T00:00:00Z","product":"actions","grossAmount":"not-a-number"}]}
JSON
printf '{"sent":{},"last_sent":0,"api_failures":2,"last_blind":0}\n' > "$TMP/state-badparse.json"
APP_TOKEN_FILE="$TMP/no-app-token" HOME="$TMP/home" GH_BIN="$TMP/bin/gh" GCLOUD_BIN="$TMP/bin/gcloud" \
  STATE_FILE="$TMP/state-badparse.json" BILLING_FIXTURE="$TMP/billing-badjson.json" \
  GCLOUD_LOG="$TMP/gcloud-badparse.log" GH_CALL_LOG="$TMP/gh-badparse.log" \
  POLICY_CAPTURE="$TMP/policy.json" POLICY_HISTORY="$TMP/policy-history.jsonl" \
  TARGET_DATE_UTC=2026-11-18 "$SCRIPT" >/dev/null 2>&1 || true
[ "$(jq -r '.api_failures' "$TMP/state-badparse.json")" = 3 ] || fail "jq summary failure must increment api_failures"
grep -q '"status":"BLIND"' "$TMP/gcloud-badparse.log" || fail "3rd failure via jq summary parse error must emit BLIND"
pass "day-1 rollover failure preserves current-month spikes and api_failures resets only after jq parse"

# 17. Fallback sink failure still persists api_failures; 3rd failure + spike sends single combined notification.
printf '{"sent":{},"last_sent":0,"api_failures":2,"last_blind":0}\n' > "$TMP/state-sinkfail.json"
if BILLING_STUB_FAIL=1 GCLOUD_WRITE_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
    run_alert "$TMP/state-sinkfail.json" "$TMP/gcloud-sinkfail.log" "$TMP/gh-sinkfail.log" >/dev/null 2>&1; then
  fail "gcloud write failure must return non-zero"
fi
[ "$(jq -r '.api_failures' "$TMP/state-sinkfail.json")" = 3 ] || fail "primary billing failure must be recorded even if COST_SPIKE gcloud write fails"
[ "$(jq -r '.sent["2026-11-17:COST_SPIKE"] // 0' "$TMP/state-sinkfail.json")" = 0 ] || fail "failed COST_SPIKE write must remain eligible for retry"

BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-sinkfail.json" "$TMP/gcloud-sinkrecover.log" "$TMP/gh-sinkrecover.log" >/dev/null
[ "$(error_count "$TMP/gcloud-sinkrecover.log")" = 1 ] || fail "retry must emit COST_SPIKE once"
! grep -q '"status":"BLIND"' "$TMP/gcloud-sinkrecover.log" || fail "when COST_SPIKE already fires in same run, BLIND must be combined into that notification rather than suppressed by 300s rate limit"
grep -q 'ALSO BLIND' "$TMP/gcloud-sinkrecover.log" || fail "single COST_SPIKE notification must include ALSO BLIND condition"
[ "$(jq -r '.last_blind // 0' "$TMP/state-sinkfail.json")" != 0 ] || fail "combined notification must update last_blind"
pass "fallback sink failure preserves api_failures and combines simultaneous COST_SPIKE + BLIND into one notification"

# 18. Concurrent runs sharing STATE_FILE serialize via lockdir without losing state updates.
printf '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0}\n' > "$TMP/state-lock.json"
cat > "$TMP/billing-lock1.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-17T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":120.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":30.00,"discountAmount":30.00,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"}
  ]
}
JSON
cat > "$TMP/billing-lock2.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-18T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":120.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":35.00,"discountAmount":0.0,"netAmount":35.00,"organizationName":"jleechanorg","repositoryName":"worldai_frontend"}
  ]
}
JSON
GCLOUD_STUB_SLEEP=1 BILLING_FIXTURE="$TMP/billing-lock1.json" run_alert "$TMP/state-lock.json" "$TMP/gcloud-lock1.log" "$TMP/gh-lock1.log" >/dev/null &
pid1=$!
sleep 0.2
BILLING_FIXTURE="$TMP/billing-lock2.json" run_alert "$TMP/state-lock.json" "$TMP/gcloud-lock2.log" "$TMP/gh-lock2.log" >/dev/null &
pid2=$!
wait "$pid1" "$pid2"
[ "$(jq -r '.sent["2026-11-17:COST_SPIKE"] // 0' "$TMP/state-lock.json")" != 0 ] || fail "concurrent run 1 sent key was lost"
[ "$(jq -r '.sent["2026-11-18:COST_SPIKE"] // 0' "$TMP/state-lock.json")" != 0 ] || fail "concurrent run 2 sent key was lost"
pass "concurrent runs serialize STATE_FILE updates via lockdir"

# 19. --ensure-gcp-policy creates/updates with timeout bounds and surfaces gcloud stderr on failure.
run_alert "$TMP/state-pol-create.json" "$TMP/gcloud-pol-create.log" "$TMP/gh-pol-create.log" --ensure-gcp-policy >/dev/null
grep -q 'alpha monitoring policies create' "$TMP/gcloud-pol-create.log" || fail "--ensure-gcp-policy must create policy when none exists"

STUB_EXISTING_POLICY="projects/worldarchitecture-ai/alertPolicies/123" \
  run_alert "$TMP/state-pol-update.json" "$TMP/gcloud-pol-update.log" "$TMP/gh-pol-update.log" --ensure-gcp-policy >/dev/null
grep -q 'alpha monitoring policies update projects/worldarchitecture-ai/alertPolicies/123' "$TMP/gcloud-pol-update.log" || fail "--ensure-gcp-policy must update existing policy"

pol_err_out="$(GCLOUD_POLICY_FAIL=1 run_alert "$TMP/state-pol-err.json" "$TMP/gcloud-pol-err.log" "$TMP/gh-pol-err.log" --ensure-gcp-policy 2>&1 || true)"
grep -q 'gcloud: policy API permission denied' <<<"$pol_err_out" || fail "--ensure-gcp-policy must surface gcloud stderr on failure"

start_ts="$(date +%s)"
GCLOUD_STUB_SLEEP=6 GCLOUD_CALL_TIMEOUT_SEC=1 \
  run_alert "$TMP/state-pol-timeout.json" "$TMP/gcloud-pol-timeout.log" "$TMP/gh-pol-timeout.log" --ensure-gcp-policy >/dev/null 2>&1 || true
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))
[ "$elapsed" -lt 5 ] || fail "stalled --ensure-gcp-policy gcloud call must be killed by GCLOUD_CALL_TIMEOUT_SEC=1 (took ${elapsed}s)"
pass "--ensure-gcp-policy creates/updates with timeout bounds and surfaces stderr on failure"
