#!/usr/bin/env bash
# Hermetic tests for GitHub Actions cost & hosted-macOS usage spike monitoring.
set -euo pipefail
unset GH_BILLING_TOKEN GH_TOKEN GITHUB_TOKEN

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
describe_env_token() {
  local var_name="$1"
  if [ "${!var_name+set}" != "set" ]; then
    printf '<unset>'
  elif [ -z "${!var_name}" ]; then
    printf '<empty>'
  elif [ "${!var_name}" = "billing-override-token" ]; then
    printf '<set:billing-override>'
  elif [ "${!var_name}" = "app-installation-token-must-not-be-used" ] || [ "${!var_name}" = "app-fallback-token" ]; then
    printf '<set:app-token>'
  else
    printf '<set:redacted>'
  fi
}
printf 'args=%s|GH_TOKEN=%s|GITHUB_TOKEN=%s\n' "$*" "$(describe_env_token GH_TOKEN)" "$(describe_env_token GITHUB_TOKEN)" >> "${GH_CALL_LOG:?}"
if [ -n "${GH_RACE_TAG:-}" ] && [[ "$*" == *"api rate_limit"* ]]; then
  printf 'ENTER %s\n' "${GH_RACE_TAG}" >> "${GH_RACE_TRACE_FILE:?}"
fi
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
  *"/orgs/"*"/repos?type=public"*)
    if [ -n "${PUBLIC_REPOS_FAIL:-}" ]; then exit 1; fi
    if [ -n "${PUBLIC_REPOS_FIXTURE:-}" ]; then cat "$PUBLIC_REPOS_FIXTURE"; else printf '[]\n'; fi
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
if [ -n "${GH_RACE_TAG:-}" ] && [[ "$*" == *"logging write"* ]]; then
  printf 'EXIT %s\n' "${GH_RACE_TAG}" >> "${GH_RACE_TRACE_FILE:?}"
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
  # Scenarios 1-27 pin the pre-calibration trip points so each keeps exercising its own mechanism
  # (unpriced-label minute counting, fallback pricing, cooldown, ...); scenario 28 covers the
  # shipped defaults end to end.
  HOME="$TMP/home" \
  GH_BIN="$TMP/bin/gh" \
  GCLOUD_BIN="$TMP/bin/gcloud" \
  STATE_FILE="$state_file" \
  BILLING_FIXTURE="${BILLING_FIXTURE:-$TMP/billing.json}" \
  GCLOUD_LOG="$gcloud_log" \
  GH_CALL_LOG="$gh_log" \
  POLICY_CAPTURE="$TMP/policy.json" \
  POLICY_HISTORY="$TMP/policy-history.jsonl" \
  NOW_ISO="${NOW_ISO:-2026-11-18T12:00:00Z}" \
  TARGET_DATE_UTC="${TARGET_DATE_UTC:-2026-11-18}" \
  DAILY_GROSS_WARN_USD="${TEST_DAILY_GROSS_WARN_USD:-25}" \
  DAILY_MACOS_MIN_WARN="${TEST_DAILY_MACOS_MIN_WARN:-60}" \
  MTD_GROSS_WARN_USD="${TEST_MTD_GROSS_WARN_USD:-250}" \
  "$SCRIPT" "$@"
}

# Runs the script with its shipped defaults (no threshold overrides), for calibration coverage.
run_shipped_defaults() {
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
  NOW_ISO="${NOW_ISO:-2026-11-18T12:00:00Z}" \
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
  and (.documentation.content | contains("${log.extracted_label.status}") and contains("${log.extracted_label.detail}"))
  and .conditions[0].conditionMatchedLog.labelExtractors == {"status":"EXTRACT(jsonPayload.status)","detail":"EXTRACT(jsonPayload.message)"}
  and (.conditions[0].conditionMatchedLog.filter | contains("jsonPayload.source=\"gh-actions-cost-alert\"") and contains("severity>=ERROR") and contains("jsonPayload.status=\"BLIND\"") and contains("severity>=WARNING") and (contains("cause=\"fleet\"") | not))
' <<<"$policy_json" >/dev/null || fail "--ensure-gcp-policy --dry-run emitted invalid or fleet-coupled policy JSON"
POLICY_JSON="$policy_json" python3 - <<'PY' || fail "--ensure-gcp-policy filter semantics failed"
import json, os, re

flt = json.loads(os.environ["POLICY_JSON"])["conditions"][0]["conditionMatchedLog"]["filter"]
SEV = {"DEBUG": 100, "INFO": 200, "NOTICE": 300, "WARNING": 400, "ERROR": 500, "CRITICAL": 600}
tokens = re.findall(r'\(|\)|AND|OR|[A-Za-z0-9_.]+(?:>=|=)"[^"]*"|[A-Za-z0-9_.]+>=[A-Z]+', flt)

def parse_expr(pos=0):
    lhs, pos = parse_and(pos)
    while pos < len(tokens) and tokens[pos] == "OR":
        rhs, pos = parse_and(pos + 1)
        lhs = ("OR", lhs, rhs)
    return lhs, pos

def parse_and(pos):
    lhs, pos = parse_atom(pos)
    while pos < len(tokens) and tokens[pos] == "AND":
        rhs, pos = parse_atom(pos + 1)
        lhs = ("AND", lhs, rhs)
    return lhs, pos

def parse_atom(pos):
    tok = tokens[pos]
    if tok == "(":
        node, pos = parse_expr(pos + 1)
        assert tokens[pos] == ")", f"expected ), got {tokens[pos]}"
        return node, pos + 1
    return ("PRED", tok), pos + 1

def eval_ast(node, rec):
    op = node[0]
    if op == "OR":
        return eval_ast(node[1], rec) or eval_ast(node[2], rec)
    if op == "AND":
        return eval_ast(node[1], rec) and eval_ast(node[2], rec)
    pred = node[1]
    if pred.startswith("severity>="):
        return SEV[rec["severity"]] >= SEV[pred.split(">=", 1)[1]]
    field, val = pred.split("=", 1)
    val = val.strip('"')
    return rec.get(field) == val

ast, end_pos = parse_expr(0)
assert end_pos == len(tokens), f"unparsed filter tokens: {tokens[end_pos:]}"

log_name = "projects/worldarchitecture-ai/logs/ezgha-runner-alerts"
assert eval_ast(ast, {"logName": log_name, "jsonPayload.source": "gh-actions-cost-alert", "jsonPayload.status": "COST_SPIKE", "severity": "ERROR"})
assert eval_ast(ast, {"logName": log_name, "jsonPayload.source": "gh-actions-cost-alert", "jsonPayload.status": "BLIND", "severity": "WARNING"})
assert not eval_ast(ast, {"logName": log_name, "jsonPayload.source": "other", "jsonPayload.status": "BLIND", "severity": "WARNING"})
assert not eval_ast(ast, {"logName": log_name, "jsonPayload.source": "gh-actions-cost-alert", "jsonPayload.status": "OK", "severity": "WARNING"})
assert not eval_ast(ast, {"logName": log_name, "jsonPayload.source": "other", "jsonPayload.status": "COST_SPIKE", "severity": "ERROR"})
PY
pass "--ensure-gcp-policy --dry-run outputs valid Slack-only policy JSON isolated from cause=fleet"

# 6. Auth isolation: ignores ~/.config/ezgha/gh_token and pre-existing GH_TOKEN unless GH_BILLING_TOKEN is set.
: > "$TMP/gh-auth.log"
GH_TOKEN="wrong-app-token" GITHUB_TOKEN="wrong-env-token" \
  run_alert "$TMP/state-auth.json" "$TMP/gcloud-auth.log" "$TMP/gh-auth.log" >/dev/null
billing_call_line="$(grep '/settings/billing/usage' "$TMP/gh-auth.log" || true)"
[ -n "$billing_call_line" ] || fail "expected /settings/billing/usage call in gh-auth.log"
grep -q '|GH_TOKEN=<unset>|GITHUB_TOKEN=<unset>' <<<"$billing_call_line" || fail "billing usage request must unset GH_TOKEN and GITHUB_TOKEN (got: $billing_call_line)"
! grep -q 'wrong-app-token\|app-installation-token-must-not-be-used' "$TMP/gh-auth.log" || fail "script must never pass App/ambient GH_TOKEN"

: > "$TMP/gh-auth2.log"
GH_BILLING_TOKEN="billing-override-token" GH_TOKEN="wrong-app-token" \
  run_alert "$TMP/state-auth2.json" "$TMP/gcloud-auth2.log" "$TMP/gh-auth2.log" >/dev/null
grep -q '|GH_TOKEN=<set:billing-override>|' "$TMP/gh-auth2.log" || fail "GH_BILLING_TOKEN must be exported as GH_TOKEN when provided"

# Ambient/explicit secret must never appear in gh call log, stdout, or stderr (even on failure).
: > "$TMP/gh-redact.log"
probe_marker="dummy-dummy-marker"
GH_BILLING_TOKEN="$probe_marker" GH_STUB_FAIL=1 APP_TOKEN_FILE="$TMP/no-app-token" \
  run_alert "$TMP/state-redact.json" "$TMP/gcloud-redact.log" "$TMP/gh-redact.log" \
  >"$TMP/redact.out" 2>"$TMP/redact.err" || true
for f in "$TMP/gh-redact.log" "$TMP/redact.out" "$TMP/redact.err"; do
  ! grep -qF "$probe_marker" "$f" || fail "raw token leaked into $f"
done
grep -q '|GH_TOKEN=<set:redacted>|' "$TMP/gh-redact.log" || fail "fake gh stub must log <set:redacted> for arbitrary GH_BILLING_TOKEN"
pass "auth isolation avoids App token, honors GH_BILLING_TOKEN, and redacts raw tokens from logs/output"

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
grep -q 'orgs/jleechanorg/repos?sort=pushed&per_page=100|GH_TOKEN=<set:app-token>' "$TMP/gh-fallback.log" || fail "App-token fallback must query org repos with per_page=100 using APP_TOKEN_FILE"
grep -q 'repos/jleechanorg/disk_magician/actions/runs?per_page=100|GH_TOKEN=<set:app-token>' "$TMP/gh-fallback.log" || fail "App-token fallback must query actions/runs?per_page=100 without created-only filter"
grep -q 'repos/jleechanorg/disk_magician/actions/runs/9001/jobs?filter=all&per_page=100&page=1|GH_TOKEN=<set:app-token>' "$TMP/gh-fallback.log" || fail "App-token fallback must query job details with filter=all&per_page=100&page=1 using APP_TOKEN_FILE"
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
    app_calls="$(grep -c '|GH_TOKEN=<set:app-token>|' "$TMP/gh-fallback-403.log" || true)"
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

# Pinned-clock regression check: year-2027 NOW_EPOCH with pinned NOW_ISO keeps in_progress run 9102 deterministic.
: > "$TMP/gh-oldpush-2027.log"
NOW_EPOCH=1800000000 NOW_ISO="2026-11-18T12:00:00Z" \
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos-oldpush.json" RUNS_FIXTURE="$TMP/runs-cross.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-oldpush-2027.json" "$TMP/gcloud-oldpush-2027.log" "$TMP/gh-oldpush-2027.log" >/dev/null
[ "$(error_count "$TMP/gcloud-oldpush-2027.log")" = 1 ] || fail "year-2027 NOW_EPOCH with pinned NOW_ISO must not spuriously spike in_progress job"
grep -q '"day":"2026-11-17"' "$TMP/gcloud-oldpush-2027.log" || fail "pinned-clock fallback run must alert on 2026-11-17"
grep -q '"ts":"2026-11-18T12:00:00Z"' "$TMP/gcloud-oldpush-2027.log" || fail "NOW_ISO override must propagate to emitted payload ts"
grep -q 'runs/9102/jobs' "$TMP/gh-oldpush-2027.log" || fail "pinned-clock fallback run must inspect in_progress run 9102"
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

# Larger/ARM hosted labels must NOT match baseline standard rates and must mark mode=app_token_fallback_partial,
# while macos-26 and macos-26-intel ARE priced at $0.062/min and any non-self-hosted macos-* label (macos-15-large, macos-15-xlarge) still counts macos_min toward DAILY_MACOS_MIN_WARN.
cat > "$TMP/jobs/9301.json" <<'JSON'
{
  "total_count": 4,
  "jobs": [
    {"id":32,"labels":["ubuntu-24.04-16core"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T03:00:00Z"},
    {"id":33,"labels":["ubuntu-24.04-arm"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T02:00:00Z"},
    {"id":34,"labels":["macos-15-large"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T03:00:00Z"},
    {"id":35,"labels":["windows-2022-8core"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T03:00:00Z"}
  ]
}
JSON
larger_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-win.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-larger.json" "$TMP/gcloud-larger.log" "$TMP/gh-larger.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$larger_out" || fail "larger/ARM hosted labels like ubuntu-24.04-16core must mark mode=app_token_fallback_partial"
[ "$(error_count "$TMP/gcloud-larger.log")" = 1 ] || fail "120m macos-15-large must still trip DAILY_MACOS_MIN_WARN COST_SPIKE"
grep -q '"macos_minutes":120' "$TMP/gcloud-larger.log" || fail "120m macos-15-large must report macos_minutes=120"
grep -q '"gross_usd":0' "$TMP/gcloud-larger.log" || fail "larger unpriced labels must not be priced at baseline rates (gross_usd must be 0)"

cat > "$TMP/jobs/9301.json" <<'JSON'
{
  "total_count": 2,
  "jobs": [
    {"id":36,"labels":["macos-15-xlarge"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T02:15:00Z"},
    {"id":37,"labels":["ubuntu-24.04-16core"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T01:30:00Z"}
  ]
}
JSON
macos_xlarge_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-win.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-macos-xlarge.json" "$TMP/gcloud-macos-xlarge.log" "$TMP/gh-macos-xlarge.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$macos_xlarge_out" || fail "macos-15-xlarge unpriced label must mark mode=app_token_fallback_partial"
[ "$(error_count "$TMP/gcloud-macos-xlarge.log")" = 1 ] || fail "75m macos-15-xlarge must trip DAILY_MACOS_MIN_WARN COST_SPIKE"
grep -q '"macos_minutes":75' "$TMP/gcloud-macos-xlarge.log" || fail "macos-15-xlarge must report macos_minutes=75"
grep -q '"gross_usd":0' "$TMP/gcloud-macos-xlarge.log" || fail "macos-15-xlarge must keep gross_usd=0 when unpriced"

cat > "$TMP/jobs/9301.json" <<'JSON'
{
  "total_count": 2,
  "jobs": [
    {"id":360,"labels":["macos-26"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T09:20:00Z"},
    {"id":361,"labels":["macos-26-intel"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T09:20:00Z"}
  ]
}
JSON
macos26_priced_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-win.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-macos26-priced.json" "$TMP/gcloud-macos26-priced.log" "$TMP/gh-macos26-priced.log"
)"
grep -q 'mode=app_token_fallback ' <<<"$macos26_priced_out" || fail "macos-26 and macos-26-intel must price cleanly without partial mode"
[ "$(error_count "$TMP/gcloud-macos26-priced.log")" = 1 ] || fail "1000m macos-26 + macos-26-intel must emit COST_SPIKE"
grep -q '"macos_minutes":1000' "$TMP/gcloud-macos26-priced.log" || fail "macos-26 + macos-26-intel must sum to 1000 macos_minutes"
grep -q '"gross_usd":62' "$TMP/gcloud-macos26-priced.log" || fail "macos-26 + macos-26-intel must price 1000m at \$62.00"

# Empty jobs page while total_count > fetched_jobs and jq job parse error must both mark partial.
cat > "$TMP/jobs/9301.json" <<'JSON'
{"total_count": 5, "jobs": []}
JSON
empty_page_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-win.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-emptypage.json" "$TMP/gcloud-emptypage.log" "$TMP/gh-emptypage.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$empty_page_out" || fail "empty jobs page with total_count=5 must mark mode=app_token_fallback_partial"

cat > "$TMP/jobs/9301.json" <<'JSON'
{"total_count": 1, "jobs": [{"id": 38, "labels": ["macos-15"], "started_at": "bad-date"}]}
JSON
bad_job_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-win.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-badjob.json" "$TMP/gcloud-badjob.log" "$TMP/gh-badjob.log" 2>/dev/null
)"
grep -q 'mode=app_token_fallback_partial' <<<"$bad_job_out" || fail "jq parse error on jobs payload must mark mode=app_token_fallback_partial"
pass "fallback prices standard windows/macos/ubuntu jobs, counts all hosted macos-* minutes, and marks partial on unpriced/empty/parse-error pages"

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

# Without timeout/gtimeout binaries (PATH=$TMP/nobin), fallback subshell must NOT silence stderr (regression for exec 9>&- 2>/dev/null).
cat > "$TMP/billing-nobin-err.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":120.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":30.00,"discountAmount":30.00,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"}
  ]
}
JSON
nobin_write_rc=0
nobin_write_err="$(
  PATH="$TMP/nobin" GCLOUD_WRITE_FAIL=1 BILLING_FIXTURE="$TMP/billing-nobin-err.json" \
    run_alert "$TMP/state-nobin-err.json" "$TMP/gcloud-nobin-err.log" "$TMP/gh-nobin-err.log" 2>&1 >/dev/null
)" || nobin_write_rc=$?
[ "$nobin_write_rc" -ne 0 ] || fail "GCLOUD_WRITE_FAIL=1 with PATH=\$TMP/nobin must exit non-zero"
grep -q 'gcloud: transient logging write failure' <<<"$nobin_write_err" || fail "PATH=\$TMP/nobin GCLOUD_WRITE_FAIL=1 must surface gcloud stderr (got: $nobin_write_err)"
pass "wall-clock timeout bounds stalled gh calls cleanly and preserves stderr without timeout/gtimeout"

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
  DAILY_GROSS_WARN_USD=25 DAILY_MACOS_MIN_WARN=60 MTD_GROSS_WARN_USD=250 \
  "$SCRIPT"
)"
[ "$(error_count "$TMP/gcloud-rollover-fail.log")" = 1 ] || fail "simultaneous breaches must emit exactly 1 combined ERROR log (avoiding 300s rate-limit drop)"
grep -q '"status":"MULTI_BREACH"' "$TMP/gcloud-rollover-fail.log" || fail "combined simultaneous breaches must set status=MULTI_BREACH"
grep -q 'cost/macOS spike' "$TMP/gcloud-rollover-fail.log" || fail "combined alert must include COST_SPIKE text"
grep -q 'daily NET spend breach' "$TMP/gcloud-rollover-fail.log" || fail "combined alert must include NET_SPEND_BREACH text"
grep -q 'MTD NET spend breach' "$TMP/gcloud-rollover-fail.log" || fail "combined alert must include MTD_SPEND_BREACH text"
grep -q '"breach_keys":\["2026-12-01:COST_SPIKE","2026-12-01:NET_SPEND_BREACH","2026-12:MTD_NET_BREACH"\]' "$TMP/gcloud-rollover-fail.log" || fail "combined alert must include all breach_keys"
[ "$(jq -r '.sent["2026-12-01:COST_SPIKE"] // 0' "$TMP/state-rollover-fail.json")" != 0 ] || fail "combined alert must mark 2026-12-01:COST_SPIKE in .sent"
[ "$(jq -r '.sent["2026-12-01:NET_SPEND_BREACH"] // 0' "$TMP/state-rollover-fail.json")" != 0 ] || fail "combined alert must mark 2026-12-01:NET_SPEND_BREACH in .sent"
[ "$(jq -r '.sent["2026-12:MTD_NET_BREACH"] // 0' "$TMP/state-rollover-fail.json")" != 0 ] || fail "combined alert must mark 2026-12:MTD_NET_BREACH in .sent"
grep -q 'alerts_emitted=3' <<<"$rollover_fail_out" || fail "combined alert must report alerts_emitted=3"
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

# 18. Concurrent runs sharing STATE_FILE serialize via kernel flock without losing state updates,
#     respect live flock timeout (WARNING BLIND + rc=4), and recover immediately after SIGKILL.
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
: > "$TMP/cost-race.trace"
GH_RACE_TAG=1 GH_RACE_TRACE_FILE="$TMP/cost-race.trace" GCLOUD_STUB_SLEEP=0.8 BILLING_FIXTURE="$TMP/billing-lock1.json" \
  run_alert "$TMP/state-lock.json" "$TMP/gcloud-lock1.log" "$TMP/gh-lock1.log" >/dev/null &
pid1=$!
sleep 0.2
GH_RACE_TAG=2 GH_RACE_TRACE_FILE="$TMP/cost-race.trace" GCLOUD_STUB_SLEEP=0.4 BILLING_FIXTURE="$TMP/billing-lock2.json" \
  run_alert "$TMP/state-lock.json" "$TMP/gcloud-lock2.log" "$TMP/gh-lock2.log" >/dev/null &
pid2=$!
rc1=0
wait "$pid1" || rc1=$?
rc2=0
wait "$pid2" || rc2=$?
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] || fail "concurrent runs must both exit 0 (rc1=$rc1 rc2=$rc2)"
[ -f "$TMP/state-lock.json.flock" ] || fail "kernel flock file must exist after runs"
[ ! -d "$TMP/state-lock.json.lock" ] || fail "legacy .lock directory must not be created"
[ "$(jq -r '.sent["2026-11-17:COST_SPIKE"] // 0' "$TMP/state-lock.json")" != 0 ] || fail "concurrent run 1 sent key was lost"
[ "$(jq -r '.sent["2026-11-18:COST_SPIKE"] // 0' "$TMP/state-lock.json")" != 0 ] || fail "concurrent run 2 sent key was lost"
TRACE_FILE="$TMP/cost-race.trace" python3 - <<'PY' || fail "concurrent kernel flock allowed overlapping execution"
import os
from pathlib import Path
lines = [l.strip() for l in Path(os.environ["TRACE_FILE"]).read_text().splitlines() if l.strip()]
assert len(lines) == 4, f"expected 4 trace lines, got {lines!r}"
assert lines[0].startswith("ENTER ") and lines[1] == "EXIT " + lines[0].split()[1], f"overlap detected: {lines!r}"
assert lines[2].startswith("ENTER ") and lines[3] == "EXIT " + lines[2].split()[1], f"overlap detected: {lines!r}"
assert lines[0].split()[1] != lines[2].split()[1], f"expected two distinct contenders: {lines!r}"
PY

# Verify same-filesystem state staging succeeds with separate TMPDIR and leaves no staging temp files behind.
mkdir -p "$TMP/separate-tmpdir" "$TMP/state-dir"
TMPDIR="$TMP/separate-tmpdir" BILLING_FIXTURE="$TMP/billing-lock1.json" \
  run_alert "$TMP/state-dir/state.json" "$TMP/gcloud-staged.log" "$TMP/gh-staged.log" >/dev/null
[ -f "$TMP/state-dir/state.json" ] || fail "state file must exist after staged write"
shopt -s nullglob
leftover_stage=("$TMP/state-dir"/state.json.tmp.* "$TMP/state-dir"/state.json.next.*)
shopt -u nullglob
[ "${#leftover_stage[@]}" -eq 0 ] || fail "leftover state staging files found: ${leftover_stage[*]}"
! grep -q 'env GH_TOKEN=' "$SCRIPT" || fail "GH_TOKEN must not be passed in env/timeout argv"

# Live flock holder blocks contender until timeout (rc=4 + WARNING BLIND), while --dry-run does not block;
# SIGKILL (kill -9) on holder immediately releases the kernel lock so the next run acquires and succeeds cleanly.
printf '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0}\n' > "$TMP/state-lockto.json"
rm -f "$TMP/cost-flock.ready"
python3 - "$TMP/state-lockto.json.flock" "$TMP/cost-flock.ready" <<'PY' &
import fcntl, sys, time
from pathlib import Path

lock_path = Path(sys.argv[1])
ready_path = Path(sys.argv[2])
lock_path.parent.mkdir(parents=True, exist_ok=True)
f = open(lock_path, "a+")
fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
ready_path.write_text("locked\n")
time.sleep(30)
PY
blocker_pid=$!
while [ ! -f "$TMP/cost-flock.ready" ]; do sleep 0.05; done

BILLING_FIXTURE="$TMP/billing-lock1.json" \
  run_alert "$TMP/state-lockto.json" "$TMP/gcloud-lockto-dry.log" "$TMP/gh-lockto-dry.log" --dry-run >/dev/null || {
  kill -9 "$blocker_pid" 2>/dev/null || true
  wait "$blocker_pid" 2>/dev/null || true
  fail "--dry-run must not block on state flock"
}

lockto_rc=0
STATE_LOCK_TIMEOUT_SEC=1 BILLING_FIXTURE="$TMP/billing-lock1.json" \
  run_alert "$TMP/state-lockto.json" "$TMP/gcloud-lockto.log" "$TMP/gh-lockto.log" >/dev/null 2>"$TMP/lockto.err" || lockto_rc=$?
[ "$lockto_rc" -eq 4 ] || {
  kill -9 "$blocker_pid" 2>/dev/null || true
  wait "$blocker_pid" 2>/dev/null || true
  fail "state flock timeout must exit 4 (got $lockto_rc)"
}
grep -q 'FATAL: timed out waiting for state lock' "$TMP/lockto.err" || fail "state flock timeout must print FATAL: timed out waiting for state lock on stderr (got: $(cat "$TMP/lockto.err"))"
grep -q 'severity=WARNING' "$TMP/gcloud-lockto.log" || fail "state lock timeout must emit WARNING"
grep -q '"status":"BLIND"' "$TMP/gcloud-lockto.log" || fail "state lock timeout must emit BLIND status"
grep -q 'LOCK_TIMEOUT: state lock held > 1s' "$TMP/gcloud-lockto.log" || fail "state lock timeout must cite LOCK_TIMEOUT"

# SIGKILL active flock holder -> next run must immediately acquire kernel lock and update state cleanly.
kill -9 "$blocker_pid" 2>/dev/null || true
wait "$blocker_pid" 2>/dev/null || true
STATE_LOCK_TIMEOUT_SEC=2 BILLING_FIXTURE="$TMP/billing-lock1.json" \
  run_alert "$TMP/state-lockto.json" "$TMP/gcloud-lockrecover.log" "$TMP/gh-lockrecover.log" >/dev/null || \
  fail "run after SIGKILL of flock holder must immediately acquire kernel lock and succeed"
[ "$(jq -r '.sent["2026-11-17:COST_SPIKE"] // 0' "$TMP/state-lockto.json")" != 0 ] || \
  fail "post-SIGKILL flock acquisition must update state file"
pass "kernel flock serializes concurrent runs, emits BLIND on timeout, skips --dry-run, and releases immediately on SIGKILL"

# 19. --ensure-gcp-policy creates/updates with timeout bounds, exits non-zero, and surfaces gcloud stderr on failure.
run_alert "$TMP/state-pol-create.json" "$TMP/gcloud-pol-create.log" "$TMP/gh-pol-create.log" --ensure-gcp-policy >/dev/null
grep -q 'alpha monitoring policies create' "$TMP/gcloud-pol-create.log" || fail "--ensure-gcp-policy must create policy when none exists"

STUB_EXISTING_POLICY="projects/worldarchitecture-ai/alertPolicies/123" \
  run_alert "$TMP/state-pol-update.json" "$TMP/gcloud-pol-update.log" "$TMP/gh-pol-update.log" --ensure-gcp-policy >/dev/null
grep -q 'alpha monitoring policies update projects/worldarchitecture-ai/alertPolicies/123' "$TMP/gcloud-pol-update.log" || fail "--ensure-gcp-policy must update existing policy"

pol_err_rc=0
pol_err_out="$(GCLOUD_POLICY_FAIL=1 run_alert "$TMP/state-pol-err.json" "$TMP/gcloud-pol-err.log" "$TMP/gh-pol-err.log" --ensure-gcp-policy 2>&1)" || pol_err_rc=$?
[ "$pol_err_rc" -ne 0 ] || fail "--ensure-gcp-policy must exit non-zero when gcloud fails"
grep -q 'gcloud: policy API permission denied' <<<"$pol_err_out" || fail "--ensure-gcp-policy must surface gcloud stderr on failure"

start_ts="$(date +%s)"
pol_to_rc=0
GCLOUD_STUB_SLEEP=6 GCLOUD_CALL_TIMEOUT_SEC=1 \
  run_alert "$TMP/state-pol-timeout.json" "$TMP/gcloud-pol-timeout.log" "$TMP/gh-pol-timeout.log" --ensure-gcp-policy >/dev/null 2>&1 || pol_to_rc=$?
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))
[ "$pol_to_rc" -ne 0 ] || fail "--ensure-gcp-policy must exit non-zero when gcloud times out"
[ "$elapsed" -lt 5 ] || fail "stalled --ensure-gcp-policy gcloud call must be killed by GCLOUD_CALL_TIMEOUT_SEC=1 (took ${elapsed}s)"
pass "--ensure-gcp-policy creates/updates with timeout bounds, exits non-zero, and surfaces stderr on failure"

# 20. Midnight-crossing job interval splitting across UTC days and corrupt STATE_FILE recovery.
cat > "$TMP/runs-midnight.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9401,"status":"completed","conclusion":"success","created_at":"2026-11-16T23:30:00Z","updated_at":"2026-11-17T01:10:00Z"},
    {"id":9402,"status":"completed","conclusion":"success","created_at":"2026-11-17T22:55:00Z","updated_at":"2026-11-18T01:15:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9401.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":41,"labels":["macos-15"],"started_at":"2026-11-16T23:40:00Z","completed_at":"2026-11-17T01:10:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9402.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":42,"labels":["macos-15"],"started_at":"2026-11-17T23:00:00Z","completed_at":"2026-11-18T01:15:00Z"}
  ]
}
JSON
BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-midnight.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-midnight.json" "$TMP/gcloud-midnight.log" "$TMP/gh-midnight.log" >/dev/null
[ "$(error_count "$TMP/gcloud-midnight.log")" = 1 ] || fail "midnight-crossing jobs must emit combined COST_SPIKE"
grep -q '"breach_keys":\["2026-11-17:COST_SPIKE","2026-11-18:COST_SPIKE"\]' "$TMP/gcloud-midnight.log" || fail "midnight-crossing jobs must attribute overlap to both 2026-11-17 and 2026-11-18"
grep -q 'on 2026-11-17 (app_token_fallback): ~\$8.06 gross, 130 macOS min' "$TMP/gcloud-midnight.log" || fail "2026-11-17 must receive 70m + 60m = 130 macOS min (\$8.06)"
grep -q 'on 2026-11-18 (app_token_fallback): ~\$4.65 gross, 75 macOS min' "$TMP/gcloud-midnight.log" || fail "2026-11-18 must receive 75 macOS min (\$4.65)"

printf '{corrupt json\n' > "$TMP/state-corrupt.json"
cat > "$TMP/billing-corrupt-ok.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions Linux","quantity":10.0,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":0.06,"discountAmount":0.06,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"ez-gh-actions"}
  ]
}
JSON
BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
  run_alert "$TMP/state-corrupt.json" "$TMP/gcloud-corrupt.log" "$TMP/gh-corrupt.log" >/dev/null 2>"$TMP/corrupt.err"
grep -q 'severity=WARNING' "$TMP/gcloud-corrupt.log" || fail "corrupt STATE_FILE must emit WARNING BLIND"
grep -q '"status":"BLIND"' "$TMP/gcloud-corrupt.log" || fail "corrupt STATE_FILE must emit status=BLIND"
grep -q '"mode":"corrupt_state_file_reset"' "$TMP/gcloud-corrupt.log" || fail "corrupt STATE_FILE must emit mode=corrupt_state_file_reset"
grep -q 'STATE_FILE was corrupt and reset' "$TMP/gcloud-corrupt.log" || fail "corrupt STATE_FILE with healthy billing must report STATE_FILE was corrupt and reset"
! grep -q 'consecutive' "$TMP/gcloud-corrupt.log" || fail "corrupt STATE_FILE with healthy billing must NOT claim consecutive billing failures"
jq -e 'type == "object" and .api_failures == 0' "$TMP/state-corrupt.json" >/dev/null || fail "corrupt STATE_FILE must be reset to valid JSON and recover on healthy billing"
pass "midnight-crossing jobs clip accurately across UTC days and corrupt STATE_FILE resets with WARNING BLIND"

# 21. Zero-byte & multi-object STATE_FILE recovery: folds BLIND into simultaneous COST_SPIKE or emits WARNING BLIND alone,
#     top_net_repo ranks by netAmount, and short midnight-straddling jobs cap total minutes at ceil(dur/60).
: > "$TMP/state-empty-spike.json"
BILLING_FIXTURE="$TMP/billing-nobin-err.json" \
  run_alert "$TMP/state-empty-spike.json" "$TMP/gcloud-empty-spike.log" "$TMP/gh-empty-spike.log" >/dev/null 2>"$TMP/empty-spike.err"
[ "$(error_count "$TMP/gcloud-empty-spike.log")" = 1 ] || fail "0-byte STATE_FILE + COST_SPIKE must emit exactly 1 ERROR log"
! grep -q '"status":"BLIND"' "$TMP/gcloud-empty-spike.log" || fail "0-byte STATE_FILE + COST_SPIKE must fold BLIND into ERROR rather than emitting separate WARNING BLIND"
grep -q '; ALSO STATE_FILE was corrupt and reset' "$TMP/gcloud-empty-spike.log" || fail "0-byte STATE_FILE + COST_SPIKE must include '; ALSO STATE_FILE was corrupt and reset'"
! grep -q 'consecutive' "$TMP/gcloud-empty-spike.log" || fail "0-byte STATE_FILE + healthy billing must NOT claim consecutive billing failures"
grep -q 'corrupt_state_file_reset' "$TMP/gcloud-empty-spike.log" || fail "0-byte STATE_FILE + COST_SPIKE must cite corrupt_state_file_reset"
jq -e 'type == "object" and .api_failures == 0 and (.last_blind > 0) and (.sent["2026-11-18:COST_SPIKE"] > 0)' "$TMP/state-empty-spike.json" >/dev/null || \
  fail "0-byte STATE_FILE + COST_SPIKE must recover valid JSON state and record .sent + .last_blind"

: > "$TMP/state-empty-ok.json"
BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
  run_alert "$TMP/state-empty-ok.json" "$TMP/gcloud-empty-ok.log" "$TMP/gh-empty-ok.log" >/dev/null 2>"$TMP/empty-ok.err"
grep -q 'severity=WARNING' "$TMP/gcloud-empty-ok.log" || fail "0-byte STATE_FILE with \$0 spend must emit WARNING"
grep -q '"status":"BLIND"' "$TMP/gcloud-empty-ok.log" || fail "0-byte STATE_FILE with \$0 spend must emit status=BLIND"
grep -q '"mode":"corrupt_state_file_reset"' "$TMP/gcloud-empty-ok.log" || fail "0-byte STATE_FILE with \$0 spend must emit mode=corrupt_state_file_reset"
jq -e 'type == "object" and .api_failures == 0 and (.last_blind > 0)' "$TMP/state-empty-ok.json" >/dev/null || \
  fail "0-byte STATE_FILE with \$0 spend must recover valid JSON state"

printf '{}{}\n' > "$TMP/state-multiobj.json"
BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
  run_alert "$TMP/state-multiobj.json" "$TMP/gcloud-multiobj.log" "$TMP/gh-multiobj.log" >/dev/null 2>"$TMP/multiobj.err"
grep -q '"mode":"corrupt_state_file_reset"' "$TMP/gcloud-multiobj.log" || fail "multi-object STATE_FILE must trigger corrupt_state_file_reset"
jq -e 'type == "object" and .api_failures == 0' "$TMP/state-multiobj.json" >/dev/null || fail "multi-object STATE_FILE must recover to single JSON object"

cat > "$TMP/billing-net-rank.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":20.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":20.00,"discountAmount":20.00,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"free-heavy"},
    {"date":"2026-11-18T01:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":20.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":12.00,"discountAmount":0.0,"netAmount":12.00,"organizationName":"jleechanorg","repositoryName":"paid-culprit"}
  ]
}
JSON
BILLING_FIXTURE="$TMP/billing-net-rank.json" \
  run_alert "$TMP/state-net-rank.json" "$TMP/gcloud-net-rank.log" "$TMP/gh-net-rank.log" >/dev/null
grep -q 'top repo free-heavy' "$TMP/gcloud-net-rank.log" || fail "COST_SPIKE must name highest-gross repo free-heavy"
grep -q 'top repo paid-culprit (\$12.00 net, \$12.00 gross)' "$TMP/gcloud-net-rank.log" || fail "NET_SPEND_BREACH must rank top_net_repo by netAmount (paid-culprit)"

cat > "$TMP/runs-short-midnight.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9403,"status":"completed","conclusion":"success","created_at":"2026-11-17T12:00:00Z","updated_at":"2026-11-18T13:00:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9403.json" <<'JSON'
{
  "total_count": 3,
  "jobs": [
    {"id":43,"labels":["macos-15"],"started_at":"2026-11-17T12:00:00Z","completed_at":"2026-11-17T12:59:00Z"},
    {"id":44,"labels":["macos-15"],"started_at":"2026-11-17T23:59:50Z","completed_at":"2026-11-18T00:00:10Z"},
    {"id":45,"labels":["macos-15"],"started_at":"2026-11-18T12:00:00Z","completed_at":"2026-11-18T12:59:00Z"}
  ]
}
JSON
short_mid_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-short-midnight.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-short-mid.json" "$TMP/gcloud-short-mid.log" "$TMP/gh-short-mid.log"
)"
grep -q 'alerts_emitted=1' <<<"$short_mid_out" || fail "20s midnight-straddling job must allocate 1 total min across days (total 119m => only 1 day reaches 60m, got: $short_mid_out)"
pass "zero-byte/multi-object state recovery, netAmount top-repo ranking, and midnight split minute cap hold"

# 22. Invalid counter types in STATE_FILE trigger corrupt_state_file_reset + BLIND, and fallback self-hosted
#     classification requires explicit "self-hosted" or "self-hosted-native-macos" label (custom groups without it mark partial).
printf '{"sent":{},"api_failures":"bad"}\n' > "$TMP/state-badtype.json"
BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
  run_alert "$TMP/state-badtype.json" "$TMP/gcloud-badtype.log" "$TMP/gh-badtype.log" >/dev/null 2>"$TMP/badtype.err"
grep -q 'severity=WARNING' "$TMP/gcloud-badtype.log" || fail "invalid counter type in STATE_FILE must emit WARNING"
grep -q '"status":"BLIND"' "$TMP/gcloud-badtype.log" || fail "invalid counter type in STATE_FILE must emit status=BLIND"
grep -q '"mode":"corrupt_state_file_reset"' "$TMP/gcloud-badtype.log" || fail "invalid counter type in STATE_FILE must emit mode=corrupt_state_file_reset"
jq -e 'type == "object" and .api_failures == 0 and (.last_blind > 0)' "$TMP/state-badtype.json" >/dev/null || \
  fail "invalid counter type STATE_FILE must reset to valid numeric state"

cat > "$TMP/runs-custom-sh.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9404,"status":"completed","conclusion":"success","created_at":"2026-11-18T02:00:00Z","updated_at":"2026-11-18T04:00:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9404.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":46,"runner_group_name":"macos-restricted","labels":["custom-ci-box"],"started_at":"2026-11-18T02:00:00Z","completed_at":"2026-11-18T04:00:00Z"}
  ]
}
JSON
custom_sh_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-custom-sh.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-custom-sh.json" "$TMP/gcloud-custom-sh.log" "$TMP/gh-custom-sh.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$custom_sh_out" || fail "job without self-hosted/self-hosted-native-macos or standard hosted label must mark mode=app_token_fallback_partial (got: $custom_sh_out)"
grep -q 'fallback_incomplete=1' <<<"$custom_sh_out" || fail "ambiguous custom-group job must have fallback_incomplete=1 (got: $custom_sh_out)"
grep -q 'alerts_emitted=0' <<<"$custom_sh_out" || fail "unpriced non-macos job must emit 0 alerts (got: $custom_sh_out)"

cat > "$TMP/jobs/9404.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":460,"runner_group_name":"mac-builds","labels":["macos-build"],"started_at":"2026-11-18T02:00:00Z","completed_at":"2026-11-18T03:30:00Z"}
  ]
}
JSON
custom_mac_build_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-custom-sh.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-custom-macbuild.json" "$TMP/gcloud-custom-macbuild.log" "$TMP/gh-custom-macbuild.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$custom_mac_build_out" || fail "macos-build in custom group mac-builds must mark mode=app_token_fallback_partial (got: $custom_mac_build_out)"
grep -q '"macos_minutes":90' "$TMP/gcloud-custom-macbuild.log" || fail "90m macos-build in custom group must count 90 macos_minutes (never \$0 self-hosted)"

cat > "$TMP/jobs/9404.json" <<'JSON'
{
  "total_count": 2,
  "jobs": [
    {"id":461,"runner_group_name":"macos-restricted","labels":["self-hosted-native-macos"],"started_at":"2026-11-18T02:00:00Z","completed_at":"2026-11-18T04:00:00Z"},
    {"id":47,"runner_group_name":"GitHub Actions","labels":["macos-15"],"started_at":"2026-11-18T04:00:00Z","completed_at":"2026-11-18T05:00:00Z"}
  ]
}
JSON
custom_sh_paired_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-custom-sh.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-custom-sh-paired.json" "$TMP/gcloud-custom-sh-paired.log" "$TMP/gh-custom-sh-paired.log"
)"
grep -q 'mode=app_token_fallback ' <<<"$custom_sh_paired_out" || fail "paired self-hosted-native-macos + GitHub Actions macos-15 must report mode=app_token_fallback (got: $custom_sh_paired_out)"
grep -q '"macos_minutes":60' "$TMP/gcloud-custom-sh-paired.log" || fail "self-hosted-native-macos job must add 0 macOS minutes (expected 60 total)"
grep -q '~\$3\.72 gross' "$TMP/gcloud-custom-sh-paired.log" || fail "self-hosted-native-macos job must add \$0 gross (expected \$3.72 total)"
pass "invalid STATE_FILE counter types reset with BLIND and strict self-hosted label classification avoids misclassifying custom hosted groups"

# 23. Round-18 fixes: hosted larger/ARM runners in custom org runner groups are NOT misclassified as $0 self-hosted,
#     fractional/bool .sent timestamps trigger corrupt_state_file_reset, and corrupt reset with < MAX_API_FAILURES
#     never falsely claims consecutive billing failures.
cat > "$TMP/runs-custom-hosted.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9405,"status":"completed","conclusion":"success","created_at":"2026-11-18T02:00:00Z","updated_at":"2026-11-18T04:00:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9405.json" <<'JSON'
{
  "total_count": 2,
  "jobs": [
    {"id":48,"runner_group_name":"custom-org-larger","labels":["macos-15-large"],"started_at":"2026-11-18T02:00:00Z","completed_at":"2026-11-18T03:15:00Z"},
    {"id":49,"runner_group_name":"custom-org-larger","labels":["ubuntu-24.04-arm"],"started_at":"2026-11-18T02:00:00Z","completed_at":"2026-11-18T03:00:00Z"}
  ]
}
JSON
custom_hosted_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-custom-hosted.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-custom-hosted.json" "$TMP/gcloud-custom-hosted.log" "$TMP/gh-custom-hosted.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$custom_hosted_out" || fail "hosted larger/ARM labels in custom runner group must mark mode=app_token_fallback_partial (got: $custom_hosted_out)"
grep -q 'fallback_incomplete=1' <<<"$custom_hosted_out" || fail "hosted larger/ARM labels in custom runner group must mark fallback_incomplete=1"
[ "$(error_count "$TMP/gcloud-custom-hosted.log")" = 1 ] || fail "75m macos-15-large in custom runner group must emit COST_SPIKE"
grep -q '"macos_minutes":75' "$TMP/gcloud-custom-hosted.log" || fail "macos-15-large in custom runner group must count 75 macos_minutes"
grep -q '"gross_usd":0' "$TMP/gcloud-custom-hosted.log" || fail "unpriced larger/ARM hosted labels in custom runner group must keep gross_usd=0"

cat > "$TMP/jobs/9405.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":50,"runner_group_name":"custom-org-larger","labels":["ubuntu-24.04-arm"],"started_at":"2026-11-18T02:00:00Z","completed_at":"2026-11-18T03:00:00Z"}
  ]
}
JSON
ubuntu_arm_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-custom-hosted.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-ubuntu-arm.json" "$TMP/gcloud-ubuntu-arm.log" "$TMP/gh-ubuntu-arm.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$ubuntu_arm_out" || fail "ubuntu-24.04-arm in custom runner group must mark mode=app_token_fallback_partial (got: $ubuntu_arm_out)"
grep -q 'fallback_incomplete=1' <<<"$ubuntu_arm_out" || fail "ubuntu-24.04-arm in custom runner group must mark fallback_incomplete=1"

printf '{"sent":{"2026-11-18:COST_SPIKE":123.45},"last_sent":0,"api_failures":0,"last_blind":0}\n' > "$TMP/state-float-sent.json"
BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
  run_alert "$TMP/state-float-sent.json" "$TMP/gcloud-float-sent.log" "$TMP/gh-float-sent.log" >/dev/null 2>"$TMP/float-sent.err"
grep -q 'severity=WARNING' "$TMP/gcloud-float-sent.log" || fail "fractional .sent timestamp must emit WARNING BLIND"
grep -q '"mode":"corrupt_state_file_reset"' "$TMP/gcloud-float-sent.log" || fail "fractional .sent timestamp must trigger corrupt_state_file_reset"
grep -q 'STATE_FILE was corrupt and reset' "$TMP/gcloud-float-sent.log" || fail "fractional .sent reset with healthy billing must report STATE_FILE was corrupt and reset"
! grep -q 'consecutive' "$TMP/gcloud-float-sent.log" || fail "fractional .sent reset with healthy billing must NOT claim consecutive billing failures"
jq -e '.sent == {} and .api_failures == 0 and (.last_blind > 0)' "$TMP/state-float-sent.json" >/dev/null || fail "fractional .sent state must reset cleanly"

printf '{"sent":{"2026-11-18:COST_SPIKE":true},"last_sent":0,"api_failures":0,"last_blind":0}\n' > "$TMP/state-bool-sent.json"
BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-bool-sent.json" "$TMP/gcloud-bool-sent.log" "$TMP/gh-bool-sent.log" >/dev/null 2>"$TMP/bool-sent.err"
[ "$(error_count "$TMP/gcloud-bool-sent.log")" = 1 ] || fail "corrupt boolean .sent + fallback spike must emit COST_SPIKE ERROR"
grep -q '; ALSO STATE_FILE was corrupt and reset' "$TMP/gcloud-bool-sent.log" || fail "corrupt .sent + 1/3 billing failure + spike must include '; ALSO STATE_FILE was corrupt and reset'"
! grep -q 'consecutive' "$TMP/gcloud-bool-sent.log" || fail "corrupt .sent + 1/3 billing failure must NOT claim consecutive failures"
[ "$(jq -r '.api_failures' "$TMP/state-bool-sent.json")" = 1 ] || fail "corrupt reset + 1 primary failure must persist api_failures=1 (not 4)"
pass "hosted larger/ARM custom groups stay partial, fractional/bool .sent resets cleanly, and corrupt-state wording is separated from billing failures"

# 24. Round-19 fixes:
#     a) Durable pending_corrupt_reset survives failed gcloud logging write and clears only after emit succeeds
#     b) Fallback enumeration shape validation marks partial when workflow_runs or repos payload is malformed
#     c) Empty "" repositoryName normalizes to (org-level) without shifting TSV columns
printf '{corrupt\n' > "$TMP/state-pending-reset.json"
if GCLOUD_WRITE_FAIL=1 BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
    run_alert "$TMP/state-pending-reset.json" "$TMP/gcloud-pending-reset.log" "$TMP/gh-pending-reset.log" >/dev/null 2>&1; then
  fail "corrupt reset with GCLOUD_WRITE_FAIL=1 must exit non-zero"
fi
[ "$(jq -r '.pending_corrupt_reset' "$TMP/state-pending-reset.json")" = "true" ] || \
  fail "failed gcloud emit after corrupt reset must persist pending_corrupt_reset=true"

BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
  run_alert "$TMP/state-pending-reset.json" "$TMP/gcloud-pending-retry.log" "$TMP/gh-pending-retry.log" >/dev/null 2>"$TMP/pending-retry.err"
grep -q '"mode":"corrupt_state_file_reset"' "$TMP/gcloud-pending-retry.log" || \
  fail "next healthy run with pending_corrupt_reset=true must emit WARNING BLIND corrupt_state_file_reset"
[ "$(jq -r '.pending_corrupt_reset' "$TMP/state-pending-reset.json")" = "false" ] || \
  fail "successful emit must clear pending_corrupt_reset=false"

BILLING_FIXTURE="$TMP/billing-corrupt-ok.json" \
  run_alert "$TMP/state-pending-reset.json" "$TMP/gcloud-pending-after.log" "$TMP/gh-pending-after.log" >/dev/null
[ ! -e "$TMP/gcloud-pending-after.log" ] || fail "subsequent healthy run after pending_corrupt_reset cleared must emit zero logs"

cat > "$TMP/runs-badshape.json" <<'JSON'
{"workflow_runs": {"not": "a list"}}
JSON
bad_runs_shape_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-badshape.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-badshape.json" "$TMP/gcloud-badshape.log" "$TMP/gh-badshape.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$bad_runs_shape_out" || \
  fail "non-list workflow_runs must mark mode=app_token_fallback_partial (got: $bad_runs_shape_out)"

cat > "$TMP/repos-badshape.json" <<'JSON'
{"message": "not a repo list"}
JSON
bad_repos_shape_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos-badshape.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-badrepos.json" "$TMP/gcloud-badrepos.log" "$TMP/gh-badrepos.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$bad_repos_shape_out" || \
  fail "non-array repos response must mark mode=app_token_fallback_partial (got: $bad_repos_shape_out)"

cat > "$TMP/billing-empty-repo.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":120.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":30.00,"discountAmount":15.00,"netAmount":15.00,"organizationName":"jleechanorg","repositoryName":""}
  ]
}
JSON
BILLING_FIXTURE="$TMP/billing-empty-repo.json" \
  run_alert "$TMP/state-emptyrepo.json" "$TMP/gcloud-emptyrepo.log" "$TMP/gh-emptyrepo.log" >/dev/null
grep -q '"top_repo":"(org-level)"' "$TMP/gcloud-emptyrepo.log" || \
  fail "empty repositoryName must normalize to (org-level) without shifting TSV fields"
grep -q '"gross_usd":30' "$TMP/gcloud-emptyrepo.log" || fail "normalized (org-level) row must preserve gross_usd=30"
grep -q '"net_usd":15' "$TMP/gcloud-emptyrepo.log" || fail "normalized (org-level) row must preserve net_usd=15"
grep -q '"macos_minutes":120' "$TMP/gcloud-emptyrepo.log" || fail "normalized (org-level) row must preserve macos_minutes=120"
pass "Round-19 fixes: durable pending_corrupt_reset, fallback shape validation, and empty repositoryName TSV normalization hold"

# 25. Round-20 fixes:
#     a) Primary billing Actions row missing grossAmount or date fails primary parse, increments api_failures, and runs fallback
#     b) Fallback marks mode=app_token_fallback_partial when a repo lacks non-empty string full_name or a run lacks integer id
cat > "$TMP/billing-missing-gross.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-18T00:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":120.0,"unitType":"Minutes","netAmount":0.0,"repositoryName":"worldarchitect.ai"}
  ]
}
JSON
printf '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0,"pending_corrupt_reset":false}\n' > "$TMP/state-missing-gross.json"
missing_gross_out="$(
  BILLING_FIXTURE="$TMP/billing-missing-gross.json" \
  REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-missing-gross.json" "$TMP/gcloud-missing-gross.log" "$TMP/gh-missing-gross.log"
)"
grep -q 'mode=app_token_fallback' <<<"$missing_gross_out" || \
  fail "Actions billing row missing grossAmount must fail primary parse and invoke App-token fallback (got: $missing_gross_out)"
[ "$(jq -r '.api_failures' "$TMP/state-missing-gross.json")" = 1 ] || \
  fail "Actions billing row missing grossAmount must increment api_failures=1 instead of clearing it"

cat > "$TMP/billing-bad-date.json" <<'JSON'
{
  "usageItems": [
    {"date":"not-a-date","product":"Actions","sku":"Actions macOS 3-core","quantity":120.0,"unitType":"Minutes","grossAmount":7.44,"netAmount":0.0,"repositoryName":"worldarchitect.ai"}
  ]
}
JSON
printf '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0,"pending_corrupt_reset":false}\n' > "$TMP/state-bad-date.json"
bad_date_out="$(
  BILLING_FIXTURE="$TMP/billing-bad-date.json" \
  REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-bad-date.json" "$TMP/gcloud-bad-date.log" "$TMP/gh-bad-date.log"
)"
grep -q 'mode=app_token_fallback' <<<"$bad_date_out" || \
  fail "Actions billing row with invalid date must fail primary parse and invoke App-token fallback (got: $bad_date_out)"
[ "$(jq -r '.api_failures' "$TMP/state-bad-date.json")" = 1 ] || \
  fail "Actions billing row with invalid date must increment api_failures=1"

cat > "$TMP/repos-missing-fullname.json" <<'JSON'
[
  {"name":"ok-repo","full_name":"jleechanorg/worldarchitect.ai"},
  {"name":"broken-repo","full_name":""}
]
JSON
missing_fullname_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos-missing-fullname.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-missing-fullname.json" "$TMP/gcloud-missing-fullname.log" "$TMP/gh-missing-fullname.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$missing_fullname_out" || \
  fail "repo missing non-empty full_name must mark mode=app_token_fallback_partial (got: $missing_fullname_out)"

cat > "$TMP/runs-missing-id.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9404,"status":"completed","conclusion":"success","created_at":"2026-11-18T02:00:00Z","updated_at":"2026-11-18T04:00:00Z"},
    {"id":"not-an-int","status":"completed","conclusion":"success","created_at":"2026-11-18T02:00:00Z","updated_at":"2026-11-18T04:00:00Z"}
  ]
}
JSON
missing_id_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-missing-id.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-missing-id.json" "$TMP/gcloud-missing-id.log" "$TMP/gh-missing-id.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$missing_id_out" || \
  fail "workflow_run lacking integer id must mark mode=app_token_fallback_partial (got: $missing_id_out)"
pass "Round-20 fixes: primary Actions row schema validation and fallback repo/run ID partial detection hold"

# 26. Round-21 fixes:
#     a) Day-1 month rollover with malformed Actions row in prior-month response stays in billing_api_partial
#        and preserves valid current-month daily + MTD metrics (does NOT discard into gross-only fallback).
#     b) App-token fallback leaves zero temporary files (including .repo_list / .run_ids) in TMPDIR.
cat > "$TMP/billing-dec-valid.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-12-01T00:15:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":20.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":60.00,"discountAmount":10.00,"netAmount":50.00,"organizationName":"jleechanorg","repositoryName":"worldai_frontend"}
  ]
}
JSON
cat > "$TMP/billing-prev-badrow.json" <<'JSON'
{
  "usageItems": [
    {"date":"not-a-date","product":"Actions","sku":"Actions macOS 3-core","quantity":10.0,"unitType":"Minutes","grossAmount":99.00,"netAmount":99.00,"repositoryName":"worldarchitect.ai"}
  ]
}
JSON
printf '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0,"pending_corrupt_reset":false}\n' > "$TMP/state-prev-badrow.json"
prev_badrow_out="$(
  TARGET_DATE_UTC=2026-12-01 \
  BILLING_FIXTURE="$TMP/billing-dec-valid.json" \
  BILLING_PREV_FIXTURE="$TMP/billing-prev-badrow.json" \
  REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-prev-badrow.json" "$TMP/gcloud-prev-badrow.log" "$TMP/gh-prev-badrow.log"
)"
grep -q 'mode=billing_api_partial' <<<"$prev_badrow_out" || \
  fail "malformed prior-month Actions row on rollover must stay mode=billing_api_partial (got: $prev_badrow_out)"
! grep -q 'app_token_fallback' <<<"$prev_badrow_out" || \
  fail "malformed prior-month Actions row must NOT discard valid current-month data into fallback (got: $prev_badrow_out)"
grep -q 'mtd_gross=60.00 mtd_net=50.00' <<<"$prev_badrow_out" || \
  fail "malformed prior-month Actions row must preserve current-month MTD gross/net (got: $prev_badrow_out)"
grep -q '"net_usd":50' "$TMP/gcloud-prev-badrow.log" || \
  fail "malformed prior-month Actions row must preserve current-month daily net_usd=50 alert"
[ "$(jq -r '.api_failures' "$TMP/state-prev-badrow.json")" = 1 ] || \
  fail "malformed prior-month Actions row must increment api_failures=1"

ISOLATED_TMPDIR="$TMP/fallback-clean-tmpdir"
mkdir -p "$ISOLATED_TMPDIR"
TMPDIR="$ISOLATED_TMPDIR" \
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-tmpclean.json" "$TMP/gcloud-tmpclean.log" "$TMP/gh-tmpclean.log" >/dev/null
leftover_tmp_files="$(find "$ISOLATED_TMPDIR" -mindepth 1)"
[ -z "$leftover_tmp_files" ] || \
  fail "App-token fallback must leave zero temp files in TMPDIR (found: $leftover_tmp_files)"
pass "Round-21 fixes: prior-month rollover schema isolation and fallback temp-file cleanup hold"

# 27. Round-22 fixes:
#     a) P1-1: Rollover prior-month row with object-valued sku/unitType/repositoryName fails prior-month validation
#        and preserves valid current-month net/MTD breach in billing_api_partial mode
#     b) P1-3: App-token fallback recognizes xcode-* labels (e.g. xcode-27) as hosted macOS (macos_minutes + unpriced partial)
cat > "$TMP/billing-prev-badsku.json" <<'JSON'
{
  "usageItems": [
    {"date":"2026-11-30T12:00:00Z","product":"actions","sku":{"bad":1},"quantity":10.0,"unitType":"Minutes","grossAmount":99.00,"netAmount":99.00,"repositoryName":"worldarchitect.ai"}
  ]
}
JSON
printf '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0,"pending_corrupt_reset":false}\n' > "$TMP/state-prev-badsku.json"
prev_badsku_out="$(
  TARGET_DATE_UTC=2026-12-01 \
  BILLING_FIXTURE="$TMP/billing-dec-valid.json" \
  BILLING_PREV_FIXTURE="$TMP/billing-prev-badsku.json" \
  REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-prev-badsku.json" "$TMP/gcloud-prev-badsku.log" "$TMP/gh-prev-badsku.log"
)"
grep -q 'mode=billing_api_partial' <<<"$prev_badsku_out" || \
  fail "object-valued sku in prior-month rollover row must stay mode=billing_api_partial (got: $prev_badsku_out)"
! grep -q 'app_token_fallback' <<<"$prev_badsku_out" || \
  fail "object-valued sku in prior-month rollover row must NOT discard valid current-month data into fallback"
grep -q 'mtd_gross=60.00 mtd_net=50.00' <<<"$prev_badsku_out" || \
  fail "object-valued sku in prior-month rollover row must preserve current-month MTD gross/net (got: $prev_badsku_out)"
grep -q '"net_usd":50' "$TMP/gcloud-prev-badsku.log" || \
  fail "object-valued sku in prior-month rollover row must preserve current-month daily net_usd=50 alert"

cat > "$TMP/runs-xcode.json" <<'JSON'
{
  "workflow_runs": [
    {"id":9501,"status":"completed","conclusion":"success","created_at":"2026-11-18T01:00:00Z","updated_at":"2026-11-18T02:15:00Z"}
  ]
}
JSON
cat > "$TMP/jobs/9501.json" <<'JSON'
{
  "total_count": 1,
  "jobs": [
    {"id":51,"labels":["xcode-27"],"started_at":"2026-11-18T01:00:00Z","completed_at":"2026-11-18T02:15:00Z"}
  ]
}
JSON
xcode_out="$(
  BILLING_STUB_FAIL=1 REPOS_FIXTURE="$TMP/repos.json" RUNS_FIXTURE="$TMP/runs-xcode.json" JOBS_FIXTURE_DIR="$TMP/jobs" \
  run_alert "$TMP/state-xcode.json" "$TMP/gcloud-xcode.log" "$TMP/gh-xcode.log"
)"
grep -q 'mode=app_token_fallback_partial' <<<"$xcode_out" || \
  fail "xcode-27 unpriced hosted macOS label must mark mode=app_token_fallback_partial (got: $xcode_out)"
[ "$(error_count "$TMP/gcloud-xcode.log")" = 1 ] || \
  fail "75m xcode-27 must trip DAILY_MACOS_MIN_WARN COST_SPIKE"
grep -q '"macos_minutes":75' "$TMP/gcloud-xcode.log" || \
  fail "xcode-27 must report macos_minutes=75"
grep -q '"gross_usd":0' "$TMP/gcloud-xcode.log" || \
  fail "xcode-27 unpriced hosted label must keep gross_usd=0"
pass "Round-22 fixes: prior-month sku/unitType/repositoryName validation and xcode-* fallback macOS detection hold"

# 28. Shipped-default calibration (operator ask 2026-11-20): ordinary baseline hosted usage must stay
#     silent, while the 2026-11-17 incident and MTD gross runaway keep paging.
cat > "$TMP/billing-cal-baseline.json" <<'JSON'
{"usageItems":[
 {"date":"2026-11-19T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":1083.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":67.15,"discountAmount":67.15,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"},
 {"date":"2026-11-19T00:00:00Z","product":"actions","sku":"Actions Linux","quantity":1369.0,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":8.21,"discountAmount":8.02,"netAmount":0.19,"organizationName":"jleechanorg","repositoryName":"worldarchitect.ai"},
 {"date":"2026-11-19T00:00:00Z","product":"actions","sku":"Actions storage","quantity":100.0,"unitType":"GigabyteHours","pricePerUnit":0.00033602,"grossAmount":0.03,"discountAmount":0.01,"netAmount":0.02,"organizationName":"jleechanorg","repositoryName":"worldarchitect.ai"}
]}
JSON
BILLING_FIXTURE="$TMP/billing-cal-baseline.json" TARGET_DATE_UTC=2026-11-19 \
  run_shipped_defaults "$TMP/state-cal-baseline.json" "$TMP/gcloud-cal-baseline.log" "$TMP/gh-cal-baseline.log" >/dev/null
[ "$(error_count "$TMP/gcloud-cal-baseline.log")" = 0 ] || \
  fail "2026-11-19 baseline (1083 macOS min, \$75.57 gross, \$0.21 net) must not alert at shipped defaults"
pass "shipped defaults stay silent on the 2026-11-19 baseline (1083 macOS min, \$75.57 gross)"

cat > "$TMP/billing-cal-spike.json" <<'JSON'
{"usageItems":[
 {"date":"2026-11-17T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":2389.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":148.12,"discountAmount":148.12,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"}
]}
JSON
BILLING_FIXTURE="$TMP/billing-cal-spike.json" TARGET_DATE_UTC=2026-11-18 \
  run_shipped_defaults "$TMP/state-cal-spike.json" "$TMP/gcloud-cal-spike.log" "$TMP/gh-cal-spike.log" >/dev/null
[ "$(error_count "$TMP/gcloud-cal-spike.log")" = 1 ] || \
  fail "2026-11-17 incident (2389 macOS min, \$148.12 gross) must still emit exactly 1 ERROR at shipped defaults"
grep -q '"status":"COST_SPIKE"' "$TMP/gcloud-cal-spike.log" || \
  fail "2026-11-17 incident must keep status=COST_SPIKE at shipped defaults"
pass "shipped defaults still page on the 2026-11-17 incident (2389 macOS min, \$148.12 gross)"

# 10 x \$92.75/day = \$927.50 MTD (the real 2026-11 MTD on 2026-11-20) stays below both gross gates.
{
  printf '{"usageItems":['
  for d in 01 02 03 04 05 06 07 08 09 10; do
    printf '{"date":"2026-11-%sT00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":1496.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":92.752,"discountAmount":92.752,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"}' "$d"
    [ "$d" = 10 ] || printf ','
  done
  printf ']}\n'
} > "$TMP/billing-cal-mtd.json"
BILLING_FIXTURE="$TMP/billing-cal-mtd.json" TARGET_DATE_UTC=2026-11-20 \
  run_shipped_defaults "$TMP/state-cal-mtd.json" "$TMP/gcloud-cal-mtd.log" "$TMP/gh-cal-mtd.log" >/dev/null
[ "$(error_count "$TMP/gcloud-cal-mtd.log")" = 0 ] || \
  fail "MTD \$927.43-equivalent (10 x \$92.75/day) must stay under DAILY_GROSS_WARN_USD=100 and MTD_GROSS_WARN_USD=1500"
pass "shipped defaults keep November MTD (10 x \$92.75/day) informational"

cat > "$TMP/billing-cal-mtd-breach.json" <<'JSON'
{"usageItems":[
 {"date":"2026-11-18T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":25000.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":1550.0,"discountAmount":1550.0,"netAmount":0.0,"organizationName":"jleechanorg","repositoryName":"disk_magician"}
]}
JSON
BILLING_FIXTURE="$TMP/billing-cal-mtd-breach.json" TARGET_DATE_UTC=2026-11-19 \
  run_shipped_defaults "$TMP/state-cal-mtd-breach.json" "$TMP/gcloud-cal-mtd-breach.log" "$TMP/gh-cal-mtd-breach.log" >/dev/null
[ "$(error_count "$TMP/gcloud-cal-mtd-breach.log")" = 1 ] || \
  fail "MTD gross \$1550 (>= MTD_GROSS_WARN_USD=1500) must emit exactly 1 combined ERROR at shipped defaults"
grep -q 'MTD GROSS usage breach' "$TMP/gcloud-cal-mtd-breach.log" || \
  fail "MTD gross runaway must keep the MTD GROSS usage breach text"
grep -q '"status":"MULTI_BREACH"' "$TMP/gcloud-cal-mtd-breach.log" || \
  fail "simultaneous COST_SPIKE + MTD gross breach must report status=MULTI_BREACH"
pass "shipped defaults still page on MTD gross runaway (\$1550) as a combined MULTI_BREACH"

# 29. Free public standard usage is informational, not a cash-spend emergency.
# Private, unknown visibility/SKU, larger runners, net/storage and BLIND stay alertable.
cat > "$TMP/public-repos.json" <<'JSON'
[{"name":"disk_magician","private":false,"visibility":"public","owner":{"login":"jleechanorg"}}]
JSON
cat > "$TMP/free-public-billing.json" <<'JSON'
{"usageItems":[
 {"date":"2026-11-17T00:00:00Z","product":"actions","sku":"Actions macOS 3-core","quantity":13020,"unitType":"Minutes","grossAmount":807.24,"netAmount":0,"repositoryName":"disk_magician"},
 {"date":"2026-11-18T00:00:00Z","product":"actions","sku":"Actions storage","quantity":2000,"unitType":"GigabyteHours","grossAmount":0.7,"netAmount":0.7,"repositoryName":"disk_magician"}
]}
JSON
PUBLIC_REPOS_FIXTURE="$TMP/public-repos.json" BILLING_FIXTURE="$TMP/free-public-billing.json" \
 run_alert "$TMP/state-free-public.json" "$TMP/gcloud-free-public.log" "$TMP/gh-free-public.log" >/dev/null
[ "$(error_count "$TMP/gcloud-free-public.log")" = 0 ] || fail "free public standard minutes plus sub-threshold storage must not emit ERROR"
grep -q 'severity=INFO' "$TMP/gcloud-free-public.log" || fail "free usage must stay visible as INFO"
grep -q 'FREE_PUBLIC_USAGE' "$TMP/gcloud-free-public.log" || fail "free public usage must be labelled informational"
# Passing six-hour cooldown cannot turn unchanged allowed free usage back into a page.
PUBLIC_REPOS_FIXTURE="$TMP/public-repos.json" BILLING_FIXTURE="$TMP/free-public-billing.json" NOW_EPOCH=1999999999 \
 run_alert "$TMP/state-free-public.json" "$TMP/gcloud-free-public.log" "$TMP/gh-free-public.log" >/dev/null
[ "$(error_count "$TMP/gcloud-free-public.log")" = 0 ] || fail "historical free usage must not page after cooldown"
# New free public usage is permitted too; this is not just a historical suppression.
jq '.usageItems[0].date="2026-11-18T12:00:00Z" | .usageItems[0].quantity=14000 | .usageItems[0].grossAmount=868' "$TMP/free-public-billing.json" > "$TMP/new-free-billing.json"
PUBLIC_REPOS_FIXTURE="$TMP/public-repos.json" BILLING_FIXTURE="$TMP/new-free-billing.json" \
 run_alert "$TMP/state-new-free.json" "$TMP/gcloud-new-free.log" "$TMP/gh-new-free.log" >/dev/null
[ "$(error_count "$TMP/gcloud-new-free.log")" = 0 ] || fail "new allowed free standard public usage must not page"
# No metadata proof, lookup failure, private object, and wrong-owner data all fail closed.
for case_name in unknown failed private wrong-owner larger paid storage; do
  cp "$TMP/free-public-billing.json" "$TMP/case-billing.json"
  cp "$TMP/public-repos.json" "$TMP/case-public.json"
  lookup_fail=""
  case "$case_name" in
    unknown) printf '[]\n' > "$TMP/case-public.json" ;;
    failed) lookup_fail=1 ;;
    private) jq '.[0].private=true | .[0].visibility="private"' "$TMP/public-repos.json" > "$TMP/case-public.json" ;;
    wrong-owner) jq '.[0].owner.login="other-org"' "$TMP/public-repos.json" > "$TMP/case-public.json" ;;
    larger) jq '.usageItems[0].sku="Actions macOS 12-core"' "$TMP/free-public-billing.json" > "$TMP/case-billing.json" ;;
    paid) jq '.usageItems[0].netAmount=15' "$TMP/free-public-billing.json" > "$TMP/case-billing.json" ;;
    storage) jq '.usageItems[1].grossAmount=45 | .usageItems[1].netAmount=45' "$TMP/free-public-billing.json" > "$TMP/case-billing.json" ;;
  esac
  PUBLIC_REPOS_FIXTURE="$TMP/case-public.json" PUBLIC_REPOS_FAIL="$lookup_fail" BILLING_FIXTURE="$TMP/case-billing.json" \
   run_alert "$TMP/state-case-$case_name.json" "$TMP/gcloud-case-$case_name.log" "$TMP/gh-case-$case_name.log" >/dev/null
  [ "$(error_count "$TMP/gcloud-case-$case_name.log")" = 1 ] || fail "$case_name must retain one combined charge/unknown-risk ERROR"
done
# Only validated public rows may lower severity. Exhausting the five-page bound is safe.
python3 - "$TMP/public-repos.json" "$TMP/public-100.json" <<'PYREPOS'
import json,sys
row=json.load(open(sys.argv[1]))[0]
json.dump([dict(row,name="public-repo-"+str(i)) for i in range(100)],open(sys.argv[2],"w"))
PYREPOS
PUBLIC_REPOS_FIXTURE="$TMP/public-100.json" BILLING_FIXTURE="$TMP/free-public-billing.json" \
 run_alert "$TMP/state-public-cap.json" "$TMP/gcloud-public-cap.log" "$TMP/gh-public-cap.log" >/dev/null
[ "$(grep -c '/repos?type=public' "$TMP/gh-public-cap.log")" = 5 ] || fail "public lookup must be capped at five pages"
[ "$(error_count "$TMP/gcloud-public-cap.log")" = 1 ] || fail "unseen repo after page cap must remain alertable"
pass "free public standard usage stays INFO across cooldown/new usage; private, unknown, larger, paid and storage stay ERROR; visibility lookup bounded"
