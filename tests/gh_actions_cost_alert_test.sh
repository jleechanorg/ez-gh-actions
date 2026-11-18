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
    if [[ "$*" == *"month=11&day=30"* ]] && [ -n "${BILLING_PREV_FIXTURE:-}" ]; then
      cat "$BILLING_PREV_FIXTURE"
    else
      cat "${BILLING_FIXTURE:?}"
    fi
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
    if [ -n "${JOBS_FIXTURE_DIR:-}" ] && [ -f "${JOBS_FIXTURE_DIR}/${run_id}.json" ]; then
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
  BILLING_FIXTURE="$TMP/billing.json" \
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
grep -q 'orgs/jleechanorg/repos?sort=pushed&per_page=15|GH_TOKEN=app-installation-token-must-not-be-used' "$TMP/gh-fallback.log" || fail "App-token fallback must query org repos using APP_TOKEN_FILE"
grep -q 'repos/jleechanorg/disk_magician/actions/runs?created=2026-11-17..2026-11-18&per_page=50|GH_TOKEN=app-installation-token-must-not-be-used' "$TMP/gh-fallback.log" || fail "App-token fallback must query created=YESTERDAY..TODAY"
grep -q 'repos/jleechanorg/disk_magician/actions/runs/9001/jobs|GH_TOKEN=app-installation-token-must-not-be-used' "$TMP/gh-fallback.log" || fail "App-token fallback must query job details using APP_TOKEN_FILE"
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
partial_repos15="$(BILLING_STUB_FAIL=1 MAX_APP_API_CALLS=60 REPOS_FIXTURE="$TMP/repos15.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" run_alert "$TMP/state-r15.json" "$TMP/gcloud-r15.log" "$TMP/gh-r15.log")"
grep -q 'mode=app_token_fallback_partial' <<<"$partial_repos15" || fail "15-repo page saturation with pushed_at >= yesterday must mark mode=app_token_fallback_partial"
partial_runs50="$(BILLING_STUB_FAIL=1 MAX_APP_API_CALLS=60 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs50.json" JOBS_FIXTURE_DIR="$TMP/jobs" run_alert "$TMP/state-r50.json" "$TMP/gcloud-r50.log" "$TMP/gh-r50.log")"
grep -q 'mode=app_token_fallback_partial' <<<"$partial_runs50" || fail "50-run page saturation must mark mode=app_token_fallback_partial"
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
