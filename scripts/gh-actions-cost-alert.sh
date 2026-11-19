#!/usr/bin/env bash
# gh-actions-cost-alert.sh — Alert on daily/MTD GitHub Actions gross spend,
# net billed spend, or hosted macOS minute spikes via ezgha's Cloud Logging ->
# Cloud Monitoring -> Slack pipeline.
#
# Why this exists:
#   GitHub's org billing budget tracks only NET billed spend (~$0 when public
#   repos receive a 100% discount) and ignores free-tier gross usage spikes
#   such as Nov 17's 2,389 hosted macOS minutes ($148.12 gross).
#
# Blast radius:
#   - Normal peak (primary billing API): StartInterval=3600 (24 runs/day) -> at
#     most 24 `rate_limit` + 24 `/organizations/<org>/settings/billing/usage`
#     `gh api` calls/day (48 calls/day, ~0.04% of the 5,000/hr personal REST
#     quota; plus at most 1 extra previous-month day call on day-1 rollover).
#     0 calls against the GitHub App token unless personal quota < 50 or
#     `/settings/billing/usage` fails/403.
#   - Bounded App-token fallback (only when personal `core.remaining < 50` or
#     `/settings/billing/usage` fails/403): uses `APP_TOKEN_FILE`
#     (`~/.config/ezgha/gh_token`) when its `core.remaining >= 200`, hard-capped
#     at `MAX_APP_API_CALLS=60` App-token API calls/hour (= 0.58% of the
#     10,400/hr App installation quota). Prioritizes org repos by `pushed`
#     without excluding stale-push repos, includes `in_progress` and recently
#     updated runs across `>= YESTERDAY_UTC`, paginates `/jobs?filter=all&per_page=100`
#     within budget, prices standard macos/ubuntu/windows runners gross-only
#     (`net_usd=null`, `mtd_gross=null`, `mtd_net=null`), fires `ERROR COST_SPIKE`
#     immediately on observed spikes, marks `app_token_fallback_partial` on any
#     scan/pricing gap, and NEVER resets `api_failures` (only full authoritative
#     `/settings/billing/usage` success resets `api_failures=0`).
#   - Alert isolation: emits `jsonPayload.source="gh-actions-cost-alert"` into
#     a dedicated Cloud Monitoring policy (`[CRITICAL] GitHub Actions cost or
#     hosted macOS spike`, Slack-only) with `COOLDOWN_SEC=21600` (6h) and
#     `notificationRateLimit=300s`, NEVER sharing `cause="fleet"` or its
#     20/day incident quota. Read-only against GitHub APIs.
#
# Usage:
#   gh-actions-cost-alert.sh [--dry-run] [--ensure-gcp-policy] [--test-alert]
set -euo pipefail

ALERT_ORG="${ALERT_ORG:-jleechanorg}"
DAILY_GROSS_WARN_USD="${DAILY_GROSS_WARN_USD:-25}"
DAILY_MACOS_MIN_WARN="${DAILY_MACOS_MIN_WARN:-60}"
DAILY_NET_WARN_USD="${DAILY_NET_WARN_USD:-10}"
MTD_NET_WARN_USD="${MTD_NET_WARN_USD:-40}"
MTD_GROSS_WARN_USD="${MTD_GROSS_WARN_USD:-250}"
COOLDOWN_SEC="${COOLDOWN_SEC:-21600}"
MAX_API_FAILURES="${MAX_API_FAILURES:-3}"
MIN_RATE_LIMIT_REMAINING="${MIN_RATE_LIMIT_REMAINING:-50}"
MIN_APP_RATE_LIMIT_REMAINING="${MIN_APP_RATE_LIMIT_REMAINING:-200}"
MAX_APP_API_CALLS="${MAX_APP_API_CALLS:-60}"
FALLBACK_REPOS_PER_PAGE="${FALLBACK_REPOS_PER_PAGE:-100}"
FALLBACK_RUNS_PER_PAGE="${FALLBACK_RUNS_PER_PAGE:-100}"
FALLBACK_JOBS_PER_PAGE="${FALLBACK_JOBS_PER_PAGE:-100}"
GH_CALL_TIMEOUT_SEC="${GH_CALL_TIMEOUT_SEC:-30}"
GCLOUD_CALL_TIMEOUT_SEC="${GCLOUD_CALL_TIMEOUT_SEC:-30}"
STATE_LOCK_TIMEOUT_SEC="${STATE_LOCK_TIMEOUT_SEC:-30}"
APP_TOKEN_FILE="${APP_TOKEN_FILE:-$HOME/.config/ezgha/gh_token}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/ezgha/gh-actions-cost-alert.json}"
GH_BIN="${GH_BIN:-gh}"
GCLOUD_BIN="${GCLOUD_BIN:-$(command -v gcloud || true)}"
GCP_PROJECT="${GCP_PROJECT:-worldarchitecture-ai}"
GCP_ACCOUNT="${GCP_ACCOUNT:-jleechan@gmail.com}"
LOG_NAME="${LOG_NAME:-ezgha-runner-alerts}"
SLACK_CHANNEL="${SLACK_CHANNEL:-projects/worldarchitecture-ai/notificationChannels/14071650426226468737}"
POLICY_DISPLAY_NAME="${POLICY_DISPLAY_NAME:-[CRITICAL] GitHub Actions cost or hosted macOS spike}"
SOURCE="gh-actions-cost-alert"
NOW="${NOW_EPOCH:-$(date +%s)}"
NOW_ISO="${NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
TODAY_UTC="${TARGET_DATE_UTC:-$(date -u +%Y-%m-%d)}"
YESTERDAY_UTC="$(date -u -j -v-1d -f '%Y-%m-%d' "$TODAY_UTC" +%Y-%m-%d 2>/dev/null || date -u -d "$TODAY_UTC - 1 day" +%Y-%m-%d)"
[[ "$YESTERDAY_UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "FATAL: invalid YESTERDAY_UTC='$YESTERDAY_UTC'" >&2; exit 2; }
YEAR="${TODAY_UTC:0:4}"
MONTH="$((10#${TODAY_UTC:5:2}))"
YEAR_MONTH="${TODAY_UTC:0:7}"
YEST_YEAR="${YESTERDAY_UTC:0:4}"
YEST_MONTH="$((10#${YESTERDAY_UTC:5:2}))"
YEST_DAY="$((10#${YESTERDAY_UTC:8:2}))"
YEST_YEAR_MONTH="${YESTERDAY_UTC:0:7}"

DRY_RUN=0
ENSURE_POLICY=0
TEST_ALERT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --ensure-gcp-policy) ENSURE_POLICY=1 ;;
    --test-alert) TEST_ALERT=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 64 ;;
  esac
done

if [ "$DRY_RUN" -eq 0 ] && [ -z "$GCLOUD_BIN" ]; then
  echo "FATAL: gcloud not found; refusing to monitor without an alert path" >&2
  exit 3
fi

resolve_python3() {
  local cand=""
  if [ -n "${PYTHON3_BIN:-}" ] && [ -x "${PYTHON3_BIN}" ]; then
    printf '%s' "$PYTHON3_BIN"
    return 0
  fi
  cand="$(command -v python3 2>/dev/null || true)"
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    printf '%s' "$cand"
    return 0
  fi
  for cand in /usr/bin/python3 /opt/homebrew/bin/python3; do
    if [ -x "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

run_with_timeout() {
  local timeout_sec="$1"
  shift
  local timeout_bin="" rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" -k 5 "$timeout_sec" "$@" 9>&- || rc=$?
    return "$rc"
  fi
  # Capture stdout via a temp file so any orphaned child (e.g. sleep inside a stub/subshell)
  # cannot keep a command-substitution pipe open after the main child is killed on timeout.
  local out_tmp
  out_tmp="$(mktemp)"
  (
    exec 9>&- 2>/dev/null || true
    exec "$@"
  ) > "$out_tmp" &
  local pid=$!
  local deadline=$((SECONDS + timeout_sec))
  while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$out_tmp"
    return 124
  fi
  wait "$pid" || rc=$?
  cat "$out_tmp"
  rm -f "$out_tmp"
  return "$rc"
}

if [ "$ENSURE_POLICY" -eq 1 ]; then
  POLICY_FILE="$(mktemp)"
  POLICY_ERR="${POLICY_FILE}.err"
  trap 'rm -f "${POLICY_FILE:?}" "${POLICY_ERR:?}"' EXIT
  jq -n \
    --arg source "$SOURCE" \
    --arg log "$LOG_NAME" \
    --arg project "$GCP_PROJECT" \
    --arg display "$POLICY_DISPLAY_NAME" \
    --arg channel "$SLACK_CHANNEL" \
    '("logName=\"projects/"+$project+"/logs/"+$log+"\" AND jsonPayload.source=\""+$source+"\"") as $common |
    {
      displayName: $display,
      documentation: {
        content: "GitHub Actions daily/MTD gross spend, net spend, or hosted macOS minute spike detected (or cost monitor blind).",
        mimeType: "text/markdown"
      },
      combiner: "OR",
      severity: "CRITICAL",
      conditions: [
        {
          displayName: "GitHub Actions cost or hosted macOS spike",
          conditionMatchedLog: {
            filter: ("("+$common+" AND severity>=ERROR) OR ("+$common+" AND jsonPayload.status=\"BLIND\" AND severity>=WARNING)")
          }
        }
      ],
      alertStrategy: {
        autoClose: "21600s",
        notificationRateLimit: {period: "300s"}
      },
      notificationChannels: [$channel],
      enabled: true,
      userLabels: {
        component: "ezgha-cost-alert",
        severity: "critical"
      }
    }' > "$POLICY_FILE"

  if [ "$DRY_RUN" -eq 1 ]; then
    jq -c . "$POLICY_FILE"
    exit 0
  fi

  [ -n "$GCLOUD_BIN" ] || { echo "FATAL: gcloud not found" >&2; exit 3; }
  GCP_ARGS=(--project="$GCP_PROJECT" --account="$GCP_ACCOUNT")
  rc=0
  existing_raw="$(run_with_timeout "$GCLOUD_CALL_TIMEOUT_SEC" "$GCLOUD_BIN" alpha monitoring policies list "${GCP_ARGS[@]}" \
      --filter="displayName=\"$POLICY_DISPLAY_NAME\"" --format='value(name)' 2>"$POLICY_ERR" 9>&-)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$POLICY_ERR" >&2
    exit "$rc"
  fi
  existing="$(printf '%s\n' "$existing_raw" | head -1)"
  if [ -n "$existing" ]; then
    rc=0
    run_with_timeout "$GCLOUD_CALL_TIMEOUT_SEC" "$GCLOUD_BIN" alpha monitoring policies update "$existing" --policy-from-file="$POLICY_FILE" "${GCP_ARGS[@]}" >/dev/null 2>"$POLICY_ERR" 9>&- || rc=$?
    if [ "$rc" -ne 0 ]; then
      cat "$POLICY_ERR" >&2
      exit "$rc"
    fi
    echo "[$NOW_ISO] updated policy '$POLICY_DISPLAY_NAME'"
  else
    rc=0
    run_with_timeout "$GCLOUD_CALL_TIMEOUT_SEC" "$GCLOUD_BIN" alpha monitoring policies create --policy-from-file="$POLICY_FILE" "${GCP_ARGS[@]}" >/dev/null 2>"$POLICY_ERR" 9>&- || rc=$?
    if [ "$rc" -ne 0 ]; then
      cat "$POLICY_ERR" >&2
      exit "$rc"
    fi
    echo "[$NOW_ISO] created policy '$POLICY_DISPLAY_NAME'"
  fi
  exit 0
fi

emit() { # severity status day message gross_usd net_usd macos_min top_repo [mode] [mtd_gross] [mtd_net] [breach_keys_json]
  local severity="$1" status="$2" day="$3" message="$4" gross_usd="$5" net_usd="$6" macos_min="$7" top_repo="$8"
  local mode="${9:-billing_api}" mtd_gross="${10:-null}" mtd_net="${11:-null}" breach_keys_json="${12:-[]}"
  local payload
  payload="$(jq -nc \
    --arg source "$SOURCE" \
    --arg status "$status" \
    --arg sev "$severity" \
    --arg org "$ALERT_ORG" \
    --arg day "$day" \
    --arg mode "$mode" \
    --arg message "$message" \
    --arg top_repo "$top_repo" \
    --arg ts "$NOW_ISO" \
    --argjson gross "${gross_usd:-0}" \
    --argjson net "${net_usd:-null}" \
    --argjson macos_min "${macos_min:-0}" \
    --argjson mtd_gross "${mtd_gross:-null}" \
    --argjson mtd_net "${mtd_net:-null}" \
    --argjson breach_keys "${breach_keys_json:-[]}" \
    '{
      source: $source,
      status: $status,
      severity: $sev,
      org: $org,
      day: $day,
      mode: $mode,
      top_repo: $top_repo,
      gross_usd: $gross,
      net_usd: $net,
      mtd_gross: $mtd_gross,
      mtd_net: $mtd_net,
      macos_minutes: $macos_min,
      breach_keys: $breach_keys,
      message: $message,
      ts: $ts
    }')"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$NOW_ISO] [dry-run] $payload"
  else
    run_with_timeout "$GCLOUD_CALL_TIMEOUT_SEC" "$GCLOUD_BIN" logging write "$LOG_NAME" "$payload" --payload-type=json \
      --severity="$severity" --project="$GCP_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 9>&-
  fi
}

if [ "$TEST_ALERT" -eq 1 ]; then
  emit ERROR TEST "$TODAY_UTC" "TEST ONLY: GitHub Actions cost alert pipeline check for $ALERT_ORG" 0 0 0 "" "test" null null
  exit 0
fi

# CRITICAL AUTH DETAIL:
# Do NOT pass ~/.config/ezgha/gh_token to /settings/billing/usage (GitHub App 4245332
# lacks organization_administration=read and returns HTTP 403 there).
# Primary path uses GH_BILLING_TOKEN when provided, else the host's user gh keyring.
# ~/.config/ezgha/gh_token is used ONLY by run_app_token_fallback for bounded
# gross-only repo/run/job inspection when primary billing auth/quota is unavailable.
if [ -n "${GH_BILLING_TOKEN:-}" ]; then
  export GH_TOKEN="$GH_BILLING_TOKEN"
else
  unset GH_TOKEN GITHUB_TOKEN
fi

tmp="$(mktemp)"
STATE_LOCK_FILE="${STATE_FILE}.flock"
STATE_LOCK_HELD=0
STATE_STAGE_TMP=""
STATE_NEXT_TMP=""
release_state_lock() {
  if [ "${STATE_LOCK_HELD:-0}" -eq 1 ]; then
    exec 9>&- 2>/dev/null || true
    STATE_LOCK_HELD=0
  fi
}
cleanup() {
  [ -z "${STATE_STAGE_TMP:-}" ] || rm -f "$STATE_STAGE_TMP"
  [ -z "${STATE_NEXT_TMP:-}" ] || rm -f "$STATE_NEXT_TMP"
  rm -f "${tmp:?}" "$tmp.summary" "$tmp.err" "$tmp.snapshot" "$tmp.repos" "$tmp.runs" "$tmp.jobs" "$tmp.fallback_items" "$tmp.yest" "$tmp.merged"
  release_state_lock
}
trap cleanup EXIT

acquire_state_lock() {
  local py_bin="" rc=0
  if ! py_bin="$(resolve_python3)"; then
    echo "FATAL: python3 not found; cannot acquire state lock $STATE_LOCK_FILE" >&2
    return 1
  fi
  mkdir -p "$(dirname "$STATE_LOCK_FILE")"
  if ! exec 9>>"$STATE_LOCK_FILE"; then
    echo "FATAL: failed to open state lock $STATE_LOCK_FILE" >&2
    return 1
  fi
  chmod 600 "$STATE_LOCK_FILE" 2>/dev/null || true
  "$py_bin" - "$STATE_LOCK_TIMEOUT_SEC" <<'PY' || rc=$?
import errno
import fcntl
import sys
import time

timeout = max(0.0, float(sys.argv[1]))
deadline = time.monotonic() + timeout
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except OSError as exc:
        if exc.errno not in (errno.EACCES, errno.EAGAIN):
            print(f"FATAL: flock failed: {exc}", file=sys.stderr)
            sys.exit(2)
    if time.monotonic() >= deadline:
        sys.exit(1)
    time.sleep(0.1)
PY
  if [ "$rc" -ne 0 ]; then
    exec 9>&- 2>/dev/null || true
    if [ "$rc" -eq 1 ]; then
      echo "FATAL: timed out waiting for state lock $STATE_LOCK_FILE" >&2
    fi
    return 1
  fi
  STATE_LOCK_HELD=1
  return 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  if [ -r "$STATE_FILE" ]; then
    cp "$STATE_FILE" "$tmp.snapshot"
  else
    printf '%s\n' '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0}' > "$tmp.snapshot"
  fi
  STATE_FILE="$tmp.snapshot"
  STATE_STAGE_TMP="${STATE_FILE}.tmp.$$"
  STATE_NEXT_TMP="${STATE_FILE}.next.$$"
else
  if ! acquire_state_lock; then
    emit WARNING BLIND "$TODAY_UTC" \
      "LOCK_TIMEOUT: state lock held > ${STATE_LOCK_TIMEOUT_SEC}s for $ALERT_ORG; monitoring blocked" \
      0 null 0 "" "lock_timeout" null null || true
    exit 4
  fi
  STATE_STAGE_TMP="${STATE_FILE}.tmp.$$"
  STATE_NEXT_TMP="${STATE_FILE}.next.$$"
  if [ ! -f "$STATE_FILE" ]; then
    printf '%s\n' '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0}' > "$STATE_STAGE_TMP"
    mv -f "$STATE_STAGE_TMP" "$STATE_FILE"
  fi
  jq --argjson cutoff "$((NOW - 3024000))" \
    '.sent = ((.sent // {}) | with_entries(select(.value > $cutoff))) | .last_sent = (.last_sent // 0) | .api_failures = (.api_failures // 0) | .last_blind = (.last_blind // 0)' \
    "$STATE_FILE" > "$STATE_NEXT_TMP"
  mv -f "$STATE_NEXT_TMP" "$STATE_FILE"
fi

FAILURES_NOW=0
BLIND_DUE=0
BLIND_COMBINED=0
BLIND_REASON=""
PRIMARY_FAILED=0

increment_api_failure() {
  local failures last_blind
  failures="$(jq -r '.api_failures // 0' "$STATE_FILE")"
  failures=$((failures + 1))
  last_blind="$(jq -r '.last_blind // 0' "$STATE_FILE")"
  jq --argjson failures "$failures" '.api_failures = $failures' "$STATE_FILE" > "$STATE_STAGE_TMP"
  mv -f "$STATE_STAGE_TMP" "$STATE_FILE"
  FAILURES_NOW="$failures"
  BLIND_DUE=0
  if [ "$failures" -ge "$MAX_API_FAILURES" ] && [ $((NOW - last_blind)) -ge "$COOLDOWN_SEC" ]; then
    BLIND_DUE=1
  fi
}

emit_blind_if_due() {
  local reason="$1" mode="${2:-blind}"
  if [ "$BLIND_DUE" -eq 1 ] && [ "$BLIND_COMBINED" -eq 0 ]; then
    emit WARNING BLIND "$TODAY_UTC" \
      "GitHub Actions cost monitor cannot query authoritative billing usage for $ALERT_ORG after $FAILURES_NOW consecutive failures ($reason)" \
      0 null 0 "" "$mode" null null
    jq --argjson now "$NOW" '.last_blind = $now' "$STATE_FILE" > "$STATE_STAGE_TMP"
    mv -f "$STATE_STAGE_TMP" "$STATE_FILE"
  fi
  echo "[$NOW_ISO] WARN: $reason ($FAILURES_NOW consecutive); authoritative billing state unverified" >&2
}

FALLBACK_INCOMPLETE=0
FALLBACK_CAP_HIT=0
FALLBACK_MODE="app_token_fallback"

run_app_token_fallback() {
  local reason="$1"
  local app_token app_rem calls_used=0 repo_count runs_count
  FALLBACK_INCOMPLETE=0
  FALLBACK_CAP_HIT=0
  FALLBACK_MODE="app_token_fallback"

  [ -r "$APP_TOKEN_FILE" ] || return 1
  app_token="$(tr -d '\r\n' < "$APP_TOKEN_FILE" 2>/dev/null || true)"
  [ -n "$app_token" ] || return 1

  if [ "$MAX_APP_API_CALLS" -lt 2 ]; then
    return 1
  fi
  if ! app_rem="$(GH_TOKEN="$app_token" run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" api rate_limit --jq '.resources.core.remaining // empty' 2>"$tmp.err")"; then
    return 1
  fi
  calls_used=1
  if [[ "$app_rem" =~ ^[0-9]+$ ]] && [ "$app_rem" -lt "$MIN_APP_RATE_LIMIT_REMAINING" ]; then
    return 1
  fi

  if [ "$calls_used" -ge "$MAX_APP_API_CALLS" ]; then
    return 1
  fi
  if ! GH_TOKEN="$app_token" run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" api "orgs/${ALERT_ORG}/repos?sort=pushed&per_page=${FALLBACK_REPOS_PER_PAGE}" > "$tmp.repos" 2>"$tmp.err"; then
    return 1
  fi
  calls_used=$((calls_used + 1))

  if ! repo_count="$(jq 'length' "$tmp.repos" 2>"$tmp.err")"; then
    FALLBACK_INCOMPLETE=1
    repo_count=0
  fi
  if [ "$repo_count" -ge "$FALLBACK_REPOS_PER_PAGE" ]; then
    FALLBACK_INCOMPLETE=1
  fi

  : > "$tmp.fallback_items"
  local repo_name full_name run_id run_day
  local job_page fetched_jobs page_jobs_count total_jobs
  while IFS=$'\t' read -r repo_name full_name; do
    [ -n "$full_name" ] || continue
    if [ "$calls_used" -ge "$MAX_APP_API_CALLS" ]; then
      FALLBACK_INCOMPLETE=1
      FALLBACK_CAP_HIT=1
      break
    fi
    if ! GH_TOKEN="$app_token" run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" api "repos/${full_name}/actions/runs?per_page=${FALLBACK_RUNS_PER_PAGE}" > "$tmp.runs" 2>"$tmp.err"; then
      FALLBACK_INCOMPLETE=1
      calls_used=$((calls_used + 1))
      continue
    fi
    calls_used=$((calls_used + 1))

    if ! runs_count="$(jq '(.workflow_runs // []) | length' "$tmp.runs" 2>"$tmp.err")"; then
      FALLBACK_INCOMPLETE=1
      runs_count=0
    fi
    if [ "$runs_count" -ge "$FALLBACK_RUNS_PER_PAGE" ]; then
      FALLBACK_INCOMPLETE=1
    fi

    while IFS=$'\t' read -r run_id run_day; do
      [ -n "$run_id" ] || continue
      job_page=1
      fetched_jobs=0
      while true; do
        if [ "$calls_used" -ge "$MAX_APP_API_CALLS" ]; then
          FALLBACK_INCOMPLETE=1
          FALLBACK_CAP_HIT=1
          break
        fi
        if ! GH_TOKEN="$app_token" run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" api "repos/${full_name}/actions/runs/${run_id}/jobs?filter=all&per_page=${FALLBACK_JOBS_PER_PAGE}&page=${job_page}" > "$tmp.jobs" 2>"$tmp.err"; then
          FALLBACK_INCOMPLETE=1
          calls_used=$((calls_used + 1))
          break
        fi
        calls_used=$((calls_used + 1))

        if ! jq -c --arg run_day "${run_day:-$TODAY_UTC}" --arg yesterday "$YESTERDAY_UTC" --arg today "$TODAY_UTC" --arg repo "$repo_name" --arg now_iso "$NOW_ISO" '
          def is_self_hosted:
            any((.labels // [])[]; ascii_downcase as $l | ($l == "self-hosted" or ($l | startswith("self-hosted-")) or $l == "worldai-testflight-native-mac"));
          def job_mins:
            if (.started_at // null) == null then 0
            else
              (((.completed_at // $now_iso) | fromdateiso8601) - (.started_at | fromdateiso8601)) as $secs
              | if $secs > 0 then (($secs / 60) | ceil) else 0 end
            end;
          def is_standard_macos:
            (is_self_hosted | not) and (any((.labels // [])[]; ascii_downcase | test("^macos-(latest|13|14|15)(-intel|-arm64)?$")) and (any((.labels // [])[]; ascii_downcase | test("(large|xlarge|[0-9]+-?core)")) | not));
          def is_any_hosted_macos:
            (is_self_hosted | not) and any((.labels // [])[]; ascii_downcase | startswith("macos-"));
          def is_standard_ubuntu:
            (is_self_hosted | not) and (any((.labels // [])[]; ascii_downcase | test("^ubuntu-(latest|[0-9]{2}\\.[0-9]{2})(-arm)?$")) and (any((.labels // [])[]; ascii_downcase | test("(large|xlarge|[0-9]+-?core|-arm$)")) | not));
          def is_standard_windows:
            (is_self_hosted | not) and (any((.labels // [])[]; ascii_downcase | test("^windows-(latest|[0-9]{4})$")) and (any((.labels // [])[]; ascii_downcase | test("(large|xlarge|[0-9]+-?core)")) | not));
          (.jobs // [])[] | . as $j | job_mins as $m |
          (((.started_at // $run_day) | tostring)[:10]) as $jday |
          select($jday == $yesterday or $jday == $today) |
          (if ($j | is_standard_macos) then {macos_min: $m, gross: ($m * 0.062), unpriced: false}
           elif ($j | is_any_hosted_macos) then {macos_min: $m, gross: 0, unpriced: ($m > 0)}
           elif ($j | is_standard_ubuntu) then {macos_min: 0, gross: ($m * 0.006), unpriced: false}
           elif ($j | is_standard_windows) then {macos_min: 0, gross: ($m * 0.010), unpriced: false}
           elif (($j | is_self_hosted | not) and $m > 0) then {macos_min: 0, gross: 0, unpriced: true}
           else {macos_min: 0, gross: 0, unpriced: false}
           end)
          | {
              day: $jday,
              repo: $repo,
              macos_min: .macos_min,
              gross_usd: .gross,
              unpriced_hosted: .unpriced
            }
        ' "$tmp.jobs" >> "$tmp.fallback_items" 2>"$tmp.err"; then
          FALLBACK_INCOMPLETE=1
        fi

        if ! page_jobs_count="$(jq '(.jobs // []) | length' "$tmp.jobs" 2>"$tmp.err")"; then
          FALLBACK_INCOMPLETE=1
          page_jobs_count=0
        fi
        if ! total_jobs="$(jq '(.total_count // -1)' "$tmp.jobs" 2>"$tmp.err")"; then
          FALLBACK_INCOMPLETE=1
          total_jobs=-1
        fi
        fetched_jobs=$((fetched_jobs + page_jobs_count))
        if [ "$page_jobs_count" -eq 0 ]; then
          if [ "$total_jobs" -gt "$fetched_jobs" ]; then
            FALLBACK_INCOMPLETE=1
          fi
          break
        fi
        if [ "$total_jobs" -ge 0 ]; then
          if [ "$fetched_jobs" -ge "$total_jobs" ]; then
            break
          fi
        elif [ "$page_jobs_count" -lt "$FALLBACK_JOBS_PER_PAGE" ]; then
          break
        fi
        job_page=$((job_page + 1))
      done
      if [ "$FALLBACK_CAP_HIT" -eq 1 ]; then
        break
      fi
    done < <(jq -r --arg yesterday "$YESTERDAY_UTC" '
      (.workflow_runs // [])[]
      | select((.conclusion // "") != "skipped" and ((((.updated_at // .created_at // "")[:10]) >= $yesterday) or ((.status // "") == "in_progress") or ((.status // "") == "queued")))
      | [(.id // empty), ((.created_at // "")[:10])]
      | @tsv
    ' "$tmp.runs" 2>/dev/null || true)
    if [ "$FALLBACK_CAP_HIT" -eq 1 ]; then
      break
    fi
  done < <(jq -r '
    (.[]? | [(.name // ""), (.full_name // "")] | @tsv)
  ' "$tmp.repos" 2>/dev/null || true)

  if [ -s "$tmp.fallback_items" ] && jq -se 'any(.[]; .unpriced_hosted == true)' "$tmp.fallback_items" >/dev/null 2>&1; then
    FALLBACK_INCOMPLETE=1
  fi

  jq -sc --arg yesterday "$YESTERDAY_UTC" --arg today "$TODAY_UTC" '
    def sum_gross: (map(.gross_usd // 0) | add // 0);
    def sum_macos_min: (map(.macos_min // 0) | add // 0);
    def day_summary($d; $rows):
      ($rows | map(select(.day == $d))) as $items
      | ($items | group_by(.repo) | map({
          repo: .[0].repo,
          gross_usd: sum_gross,
          macos_min: sum_macos_min
        }) | sort_by(-.gross_usd, -.macos_min)) as $repos
      | {
          day: $d,
          gross_usd: ($items | sum_gross),
          net_usd: null,
          macos_min: ($items | sum_macos_min),
          top_repo: ($repos[0].repo // "(none)"),
          top_repo_gross_usd: ($repos[0].gross_usd // 0),
          top_repo_net_usd: null,
          top_repo_macos_min: ($repos[0].macos_min // 0)
        };
    . as $rows
    | {
        mtd: {
          gross_usd: null,
          net_usd: null,
          macos_min: null
        },
        days: ([$yesterday, $today] | unique | map(day_summary(.; $rows)))
      }
  ' "$tmp.fallback_items" > "$tmp.summary"
  if [ "$FALLBACK_INCOMPLETE" -eq 1 ]; then
    FALLBACK_MODE="app_token_fallback_partial"
  fi
  echo "[$NOW_ISO] INFO: gross-only billing fallback via App token ($reason; mode=$FALLBACK_MODE; app_api_calls=$calls_used/$MAX_APP_API_CALLS)" >&2
  return 0
}

used_fallback=0
rollover_yest_failed=0
rollover_fail_reason=""
run_mode="billing_api"
fallback_reason=""
if ! remaining="$(run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" api rate_limit --jq '.resources.core.remaining // empty' 2>"$tmp.err")"; then
  fallback_reason="gh api rate_limit failed"
elif [[ "$remaining" =~ ^[0-9]+$ ]] && [ "$remaining" -lt "$MIN_RATE_LIMIT_REMAINING" ]; then
  fallback_reason="GitHub core rate limit remaining=$remaining (< $MIN_RATE_LIMIT_REMAINING)"
elif ! run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" api "/organizations/${ALERT_ORG}/settings/billing/usage?year=${YEAR}&month=${MONTH}" > "$tmp" 2>"$tmp.err" || \
     ! jq -e '.usageItems | type == "array"' "$tmp" >/dev/null 2>&1; then
  fallback_reason="gh api billing usage failed"
elif [ "$YEST_YEAR_MONTH" != "$YEAR_MONTH" ]; then
  if ! run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" api "/organizations/${ALERT_ORG}/settings/billing/usage?year=${YEST_YEAR}&month=${YEST_MONTH}&day=${YEST_DAY}" > "$tmp.yest" 2>"$tmp.err" || \
     ! jq -e '.usageItems | type == "array"' "$tmp.yest" >/dev/null 2>&1; then
    rollover_yest_failed=1
    rollover_fail_reason="gh api billing usage (previous month ${YEST_YEAR_MONTH}) failed"
    run_mode="billing_api_partial"
  else
    jq -sc '{usageItems: ((.[0].usageItems // []) + (.[1].usageItems // []))}' "$tmp" "$tmp.yest" > "$tmp.merged"
    mv "$tmp.merged" "$tmp"
  fi
fi

if [ -z "$fallback_reason" ]; then
  if ! jq -c --arg today "$TODAY_UTC" --arg yesterday "$YESTERDAY_UTC" --arg year_month "$YEAR_MONTH" --argjson include_yest "$((1 - rollover_yest_failed))" '
    def is_macos_min: (((.sku // "") | test("macos"; "i")) and (((.unitType // "") | ascii_downcase) == "minutes"));
    def sum_gross: (map(.grossAmount // 0) | add // 0);
    def sum_net: (map(.netAmount // 0) | add // 0);
    def sum_macos_min: (map(if is_macos_min then (.quantity // 0) else 0 end) | add // 0);
    def day_summary($d; $all_actions):
      ($all_actions | map(select(((.date // "")[:10]) == $d))) as $items
      | ($items | group_by(.repositoryName // "(org-level)") | map({
          repo: (.[0].repositoryName // "(org-level)"),
          gross_usd: sum_gross,
          net_usd: sum_net,
          macos_min: sum_macos_min
        }) | sort_by(-.gross_usd, -.macos_min, -.net_usd)) as $repos
      | {
          day: $d,
          gross_usd: ($items | sum_gross),
          net_usd: ($items | sum_net),
          macos_min: ($items | sum_macos_min),
          top_repo: ($repos[0].repo // "(none)"),
          top_repo_gross_usd: ($repos[0].gross_usd // 0),
          top_repo_net_usd: ($repos[0].net_usd // 0),
          top_repo_macos_min: ($repos[0].macos_min // 0)
        };
    [(.usageItems // [])[] | select(((.product // "") | ascii_downcase) == "actions")] as $all_actions
    | [$all_actions[] | select(((.date // "")[:7]) == $year_month)] as $mtd_actions
    | (if $include_yest == 1 then [$yesterday, $today] else [$today] end) as $target_days
    | {
        mtd: {
          gross_usd: ($mtd_actions | sum_gross),
          net_usd: ($mtd_actions | sum_net),
          macos_min: ($mtd_actions | sum_macos_min)
        },
        days: ($target_days | unique | map(day_summary(.; $all_actions)))
      }
  ' "$tmp" > "$tmp.summary" 2>"$tmp.err"; then
    fallback_reason="gh api billing usage summary parse failed"
  elif [ "$rollover_yest_failed" -eq 0 ]; then
    jq '.api_failures = 0' "$STATE_FILE" > "$STATE_STAGE_TMP"
    mv -f "$STATE_STAGE_TMP" "$STATE_FILE"
  fi
fi

if [ -n "$fallback_reason" ]; then
  if run_app_token_fallback "$fallback_reason"; then
    used_fallback=1
    run_mode="$FALLBACK_MODE"
  else
    increment_api_failure
    emit_blind_if_due "$fallback_reason" "blind"
    exit 2
  fi
fi

if [ "$used_fallback" -eq 1 ]; then
  PRIMARY_FAILED=1
  if [ "$FALLBACK_CAP_HIT" -eq 1 ]; then
    BLIND_REASON="${fallback_reason}; App fallback ran (${run_mode}, hit MAX_APP_API_CALLS=${MAX_APP_API_CALLS})"
  elif [ "$FALLBACK_INCOMPLETE" -eq 1 ]; then
    BLIND_REASON="${fallback_reason}; partial App fallback ran (${run_mode})"
  else
    BLIND_REASON="${fallback_reason}; gross-only App fallback ran (${run_mode})"
  fi
  increment_api_failure
elif [ "$rollover_yest_failed" -eq 1 ]; then
  PRIMARY_FAILED=1
  BLIND_REASON="$rollover_fail_reason"
  increment_api_failure
fi

fmt_usd() { awk -v v="$1" 'BEGIN{printf "%.2f", v + 0}'; }
fmt_min() { awk -v v="$1" 'BEGIN{if (v + 0 == int(v + 0)) printf "%d", v + 0; else printf "%.1f", v + 0}'; }
ge_num() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a + 0 >= b + 0)}'; }

should_emit() {
  local key="$1" prev
  prev="$(jq -r --arg k "$key" '.sent[$k] // 0' "$STATE_FILE")"
  [ $((NOW - prev)) -ge "$COOLDOWN_SEC" ]
}

append_blind_context() {
  local base="$1"
  if [ "$PRIMARY_FAILED" -eq 1 ] && [ "$BLIND_DUE" -eq 1 ] && [ "$BLIND_COMBINED" -eq 0 ]; then
    printf '%s; ALSO BLIND: authoritative billing usage failed %s consecutive times (%s)' "$base" "$FAILURES_NOW" "$BLIND_REASON"
  else
    printf '%s' "$base"
  fi
}

DUE_KEYS=()
DUE_STATUSES=()
DUE_DAYS=()
DUE_MSGS=()
DUE_GROSS=()
DUE_NET=()
DUE_MACOS=()
DUE_REPO=()

queue_due_breach() { # key status day msg gross net macos_min top_repo
  DUE_KEYS+=("$1")
  DUE_STATUSES+=("$2")
  DUE_DAYS+=("$3")
  DUE_MSGS+=("$4")
  DUE_GROSS+=("$5")
  DUE_NET+=("$6")
  DUE_MACOS+=("$7")
  DUE_REPO+=("$8")
}

mtd_gross="$(jq -r '.mtd.gross_usd // "null"' "$tmp.summary")"
mtd_net="$(jq -r '.mtd.net_usd // "null"' "$tmp.summary")"
mtd_macos="$(jq -r '.mtd.macos_min // "null"' "$tmp.summary")"
if [ "$mtd_gross" != "null" ]; then
  mtd_gross_fmt="$(fmt_usd "$mtd_gross")"
else
  mtd_gross_fmt="null"
fi
if [ "$mtd_net" != "null" ]; then
  mtd_net_fmt="$(fmt_usd "$mtd_net")"
else
  mtd_net_fmt="null"
fi
if [ "$mtd_macos" != "null" ]; then
  mtd_macos_fmt="$(fmt_min "$mtd_macos")"
else
  mtd_macos_fmt="null"
fi

alerted=0
while IFS=$'\t' read -r day d_gross d_net d_macos top_repo top_gross top_net top_macos; do
  [ -n "$day" ] || continue
  d_gross_fmt="$(fmt_usd "$d_gross")"
  d_macos_fmt="$(fmt_min "$d_macos")"
  top_gross_fmt="$(fmt_usd "$top_gross")"
  top_macos_fmt="$(fmt_min "$top_macos")"
  if [ "$d_net" != "null" ]; then
    d_net_fmt="$(fmt_usd "$d_net")"
    top_net_fmt="$(fmt_usd "$top_net")"
  else
    d_net_fmt="null"
    top_net_fmt="null"
  fi

  if ge_num "$d_gross" "$DAILY_GROSS_WARN_USD" || ge_num "$d_macos" "$DAILY_MACOS_MIN_WARN"; then
    key="${day}:COST_SPIKE"
    if should_emit "$key"; then
      if [ "$used_fallback" -eq 1 ]; then
        msg="GitHub Actions estimated gross/macOS spike in $ALERT_ORG on $day (${run_mode}): ~\$${d_gross_fmt} gross, ${d_macos_fmt} macOS min (net=unknown, MTD=unknown); top repo $top_repo (${top_macos_fmt} macOS min, ~\$${top_gross_fmt} gross)"
      else
        msg="GitHub Actions cost/macOS spike in $ALERT_ORG on $day: \$${d_gross_fmt} gross, ${d_macos_fmt} macOS min (\$${d_net_fmt} net); top repo $top_repo (${top_macos_fmt} macOS min, \$${top_gross_fmt} gross); MTD \$${mtd_gross_fmt} gross / \$${mtd_net_fmt} net"
      fi
      queue_due_breach "$key" COST_SPIKE "$day" "$msg" "$d_gross" "$d_net" "$d_macos" "$top_repo"
    fi
  fi

  if [ "$used_fallback" -eq 0 ] && [ "$d_net" != "null" ] && ge_num "$d_net" "$DAILY_NET_WARN_USD"; then
    key="${day}:NET_SPEND_BREACH"
    if should_emit "$key"; then
      msg="GitHub Actions daily NET spend breach in $ALERT_ORG on $day: \$${d_net_fmt} net (>= \$${DAILY_NET_WARN_USD}; \$${d_gross_fmt} gross, ${d_macos_fmt} macOS min); top repo $top_repo (\$${top_net_fmt} net, \$${top_gross_fmt} gross); MTD \$${mtd_net_fmt} net"
      queue_due_breach "$key" NET_SPEND_BREACH "$day" "$msg" "$d_gross" "$d_net" "$d_macos" "$top_repo"
    fi
  fi
done < <(jq -r '.days[] | [.day, .gross_usd, (.net_usd // "null"), .macos_min, .top_repo, .top_repo_gross_usd, (.top_repo_net_usd // "null"), .top_repo_macos_min] | @tsv' "$tmp.summary")

if [ "$used_fallback" -eq 0 ] && [ "$mtd_net" != "null" ] && ge_num "$mtd_net" "$MTD_NET_WARN_USD"; then
  key="${YEAR_MONTH}:MTD_NET_BREACH"
  if should_emit "$key"; then
    msg="GitHub Actions MTD NET spend breach in $ALERT_ORG (${YEAR_MONTH}): \$${mtd_net_fmt} net (>= \$${MTD_NET_WARN_USD}; \$${mtd_gross_fmt} gross, ${mtd_macos_fmt} macOS min)"
    queue_due_breach "$key" MTD_SPEND_BREACH "$TODAY_UTC" "$msg" "$mtd_gross" "$mtd_net" "$mtd_macos" ""
  fi
fi

if [ "$used_fallback" -eq 0 ] && [ "$mtd_gross" != "null" ] && ge_num "$mtd_gross" "$MTD_GROSS_WARN_USD"; then
  key="${YEAR_MONTH}:MTD_GROSS_BREACH"
  if should_emit "$key"; then
    msg="GitHub Actions MTD GROSS usage breach in $ALERT_ORG (${YEAR_MONTH}): \$${mtd_gross_fmt} gross (>= \$${MTD_GROSS_WARN_USD}; \$${mtd_net_fmt} net, ${mtd_macos_fmt} macOS min)"
    queue_due_breach "$key" MTD_SPEND_BREACH "$TODAY_UTC" "$msg" "$mtd_gross" "$mtd_net" "$mtd_macos" ""
  fi
fi

if [ "${#DUE_KEYS[@]}" -gt 0 ]; then
  combined_status="${DUE_STATUSES[0]}"
  for _s in "${DUE_STATUSES[@]}"; do
    if [ "$_s" != "$combined_status" ]; then
      combined_status="MULTI_BREACH"
      break
    fi
  done
  combined_msg="${DUE_MSGS[0]}"
  for ((_i = 1; _i < ${#DUE_MSGS[@]}; _i++)); do
    combined_msg="${combined_msg} | ${DUE_MSGS[$_i]}"
  done
  combined_msg="$(append_blind_context "$combined_msg")"
  breach_keys_json="$(printf '%s\n' "${DUE_KEYS[@]}" | jq -R . | jq -sc .)"
  if emit ERROR "$combined_status" "${DUE_DAYS[0]}" "$combined_msg" \
       "${DUE_GROSS[0]}" "${DUE_NET[0]}" "${DUE_MACOS[0]}" "${DUE_REPO[0]}" \
       "$run_mode" "$mtd_gross" "$mtd_net" "$breach_keys_json"; then
    mark_blind=0
    if [ "$PRIMARY_FAILED" -eq 1 ] && [ "$BLIND_DUE" -eq 1 ] && [ "$BLIND_COMBINED" -eq 0 ]; then
      mark_blind=1
      BLIND_COMBINED=1
    fi
    jq --argjson keys "$breach_keys_json" --argjson now "$NOW" --argjson mark_blind "$mark_blind" '
      reduce $keys[] as $k (.; .sent[$k] = $now)
      | .last_sent = $now
      | if $mark_blind == 1 then .last_blind = $now else . end
    ' "$STATE_FILE" > "$STATE_STAGE_TMP"
    mv -f "$STATE_STAGE_TMP" "$STATE_FILE"
    alerted="${#DUE_KEYS[@]}"
  else
    echo "ERROR: alert sink failed for ${DUE_KEYS[*]}" >&2
    exit 3
  fi
fi

if [ "$PRIMARY_FAILED" -eq 1 ]; then
  emit_blind_if_due "$BLIND_REASON" "$run_mode"
  echo "[$NOW_ISO] DEGRADED: org=$ALERT_ORG mode=$run_mode mtd_gross=${mtd_gross_fmt} mtd_net=${mtd_net_fmt} mtd_macos_min=${mtd_macos_fmt} api_failures=${FAILURES_NOW} fallback_incomplete=$FALLBACK_INCOMPLETE alerts_emitted=${alerted}"
else
  echo "[$NOW_ISO] OK: org=$ALERT_ORG mode=$run_mode mtd_gross=\$${mtd_gross_fmt} mtd_net=\$${mtd_net_fmt} mtd_macos_min=${mtd_macos_fmt} alerts_emitted=${alerted}"
fi
