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
#     10,400/hr App installation quota). Scans `YESTERDAY_UTC..TODAY_UTC`
#     gross-only (`net_usd=null`, `mtd_gross=null`, `mtd_net=null`), fires
#     `ERROR COST_SPIKE` immediately on observed gross/macOS spikes, and
#     NEVER resets `api_failures` (only an authoritative `/settings/billing/usage`
#     success resets `api_failures=0`, preserving `WARNING BLIND` reporting).
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
NOW="$(date +%s)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

if [ "$ENSURE_POLICY" -eq 1 ]; then
  POLICY_FILE="$(mktemp)"
  trap 'rm -f "${POLICY_FILE:?}"' EXIT
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
  existing="$("$GCLOUD_BIN" alpha monitoring policies list "${GCP_ARGS[@]}" \
    --filter="displayName=\"$POLICY_DISPLAY_NAME\"" --format='value(name)' 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then
    "$GCLOUD_BIN" alpha monitoring policies update "$existing" --policy-from-file="$POLICY_FILE" "${GCP_ARGS[@]}" >/dev/null
    echo "[$NOW_ISO] updated policy '$POLICY_DISPLAY_NAME'"
  else
    "$GCLOUD_BIN" alpha monitoring policies create --policy-from-file="$POLICY_FILE" "${GCP_ARGS[@]}" >/dev/null
    echo "[$NOW_ISO] created policy '$POLICY_DISPLAY_NAME'"
  fi
  exit 0
fi

emit() { # severity status day message gross_usd net_usd macos_min top_repo [mode] [mtd_gross] [mtd_net]
  local severity="$1" status="$2" day="$3" message="$4" gross_usd="$5" net_usd="$6" macos_min="$7" top_repo="$8"
  local mode="${9:-billing_api}" mtd_gross="${10:-null}" mtd_net="${11:-null}"
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
      message: $message,
      ts: $ts
    }')"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$NOW_ISO] [dry-run] $payload"
  else
    "$GCLOUD_BIN" logging write "$LOG_NAME" "$payload" --payload-type=json \
      --severity="$severity" --project="$GCP_PROJECT" --account="$GCP_ACCOUNT" >/dev/null
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
trap 'rm -f "${tmp:?}" "$tmp.summary" "$tmp.err" "$tmp.state" "$tmp.snapshot" "$tmp.next" "$tmp.repos" "$tmp.runs" "$tmp.jobs" "$tmp.fallback_items" "$tmp.yest" "$tmp.merged"' EXIT

if [ "$DRY_RUN" -eq 1 ]; then
  if [ -r "$STATE_FILE" ]; then
    cp "$STATE_FILE" "$tmp.snapshot"
  else
    printf '%s\n' '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0}' > "$tmp.snapshot"
  fi
  STATE_FILE="$tmp.snapshot"
else
  mkdir -p "$(dirname "$STATE_FILE")"
  if [ ! -f "$STATE_FILE" ]; then
    printf '%s\n' '{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0}' > "$STATE_FILE"
  fi
  jq --argjson cutoff "$((NOW - 3024000))" \
    '.sent = ((.sent // {}) | with_entries(select(.value > $cutoff))) | .last_sent = (.last_sent // 0) | .api_failures = (.api_failures // 0) | .last_blind = (.last_blind // 0)' \
    "$STATE_FILE" > "$tmp.next"
  mv "$tmp.next" "$STATE_FILE"
fi

record_blind_failure() {
  local reason="$1" mode="${2:-blind}"
  local failures last_blind
  failures="$(jq -r '.api_failures // 0' "$STATE_FILE")"
  failures=$((failures + 1))
  last_blind="$(jq -r '.last_blind // 0' "$STATE_FILE")"
  jq --argjson failures "$failures" '.api_failures = $failures' "$STATE_FILE" > "$tmp.state"
  if [ "$failures" -ge "$MAX_API_FAILURES" ] && [ $((NOW - last_blind)) -ge "$COOLDOWN_SEC" ]; then
    emit WARNING BLIND "$TODAY_UTC" \
      "GitHub Actions cost monitor cannot query authoritative billing usage for $ALERT_ORG after $failures consecutive failures ($reason)" \
      0 null 0 "" "$mode" null null
    jq --argjson now "$NOW" '.last_blind = $now' "$tmp.state" > "$tmp.next"
    mv "$tmp.next" "$tmp.state"
  fi
  mv "$tmp.state" "$STATE_FILE"
  echo "[$NOW_ISO] WARN: $reason ($failures consecutive); authoritative billing state unverified" >&2
}

FALLBACK_INCOMPLETE=0
FALLBACK_CAP_HIT=0
FALLBACK_MODE="app_token_fallback"

run_app_token_fallback() {
  local reason="$1"
  local app_token app_rem calls_used=0 repo_count last_pushed runs_count
  FALLBACK_INCOMPLETE=0
  FALLBACK_CAP_HIT=0
  FALLBACK_MODE="app_token_fallback"

  [ -r "$APP_TOKEN_FILE" ] || return 1
  app_token="$(tr -d '\r\n' < "$APP_TOKEN_FILE" 2>/dev/null || true)"
  [ -n "$app_token" ] || return 1

  if [ "$MAX_APP_API_CALLS" -lt 2 ]; then
    return 1
  fi
  if ! app_rem="$(GH_TOKEN="$app_token" "$GH_BIN" api rate_limit --jq '.resources.core.remaining // empty' 2>"$tmp.err")"; then
    return 1
  fi
  calls_used=1
  if [[ "$app_rem" =~ ^[0-9]+$ ]] && [ "$app_rem" -lt "$MIN_APP_RATE_LIMIT_REMAINING" ]; then
    return 1
  fi

  if [ "$calls_used" -ge "$MAX_APP_API_CALLS" ]; then
    return 1
  fi
  if ! GH_TOKEN="$app_token" "$GH_BIN" api "orgs/${ALERT_ORG}/repos?sort=pushed&per_page=15" > "$tmp.repos" 2>"$tmp.err"; then
    return 1
  fi
  calls_used=$((calls_used + 1))

  repo_count="$(jq 'length' "$tmp.repos" 2>/dev/null || echo 0)"
  last_pushed="$(jq -r 'if length > 0 then ((.[-1].pushed_at // "")[:10]) else "" end' "$tmp.repos" 2>/dev/null || true)"
  if [ "$repo_count" -ge 15 ] && [ -n "$last_pushed" ] && [[ ! "$last_pushed" < "$YESTERDAY_UTC" ]]; then
    FALLBACK_INCOMPLETE=1
  fi

  : > "$tmp.fallback_items"
  local repo_name full_name run_id run_day
  while IFS=$'\t' read -r repo_name full_name; do
    [ -n "$full_name" ] || continue
    if [ "$calls_used" -ge "$MAX_APP_API_CALLS" ]; then
      FALLBACK_INCOMPLETE=1
      FALLBACK_CAP_HIT=1
      break
    fi
    if ! GH_TOKEN="$app_token" "$GH_BIN" api "repos/${full_name}/actions/runs?created=${YESTERDAY_UTC}..${TODAY_UTC}&per_page=50" > "$tmp.runs" 2>"$tmp.err"; then
      FALLBACK_INCOMPLETE=1
      calls_used=$((calls_used + 1))
      continue
    fi
    calls_used=$((calls_used + 1))

    runs_count="$(jq '(.workflow_runs // []) | length' "$tmp.runs" 2>/dev/null || echo 0)"
    if [ "$runs_count" -ge 50 ]; then
      FALLBACK_INCOMPLETE=1
    fi

    while IFS=$'\t' read -r run_id run_day; do
      [ -n "$run_id" ] || continue
      if [ "$calls_used" -ge "$MAX_APP_API_CALLS" ]; then
        FALLBACK_INCOMPLETE=1
        FALLBACK_CAP_HIT=1
        break
      fi
      if ! GH_TOKEN="$app_token" "$GH_BIN" api "repos/${full_name}/actions/runs/${run_id}/jobs" > "$tmp.jobs" 2>"$tmp.err"; then
        FALLBACK_INCOMPLETE=1
        calls_used=$((calls_used + 1))
        continue
      fi
      calls_used=$((calls_used + 1))

      jq -c --arg run_day "${run_day:-$TODAY_UTC}" --arg repo "$repo_name" --arg now_iso "$NOW_ISO" '
        def is_self_hosted:
          any((.labels // [])[]; ascii_downcase as $l | ($l == "self-hosted" or ($l | startswith("self-hosted-")) or $l == "worldai-testflight-native-mac"));
        def job_mins:
          if (.started_at // null) == null then 0
          else
            (((.completed_at // $now_iso) | fromdateiso8601) - (.started_at | fromdateiso8601)) as $secs
            | if $secs > 0 then (($secs / 60) | ceil) else 0 end
          end;
        def is_hosted_macos:
          (is_self_hosted | not) and any((.labels // [])[]; ascii_downcase | startswith("macos-"));
        def is_hosted_ubuntu:
          (is_self_hosted | not) and any((.labels // [])[]; ascii_downcase | startswith("ubuntu-"));
        (.jobs // [])[] | . as $j | job_mins as $m |
        (((.started_at // $run_day) | tostring)[:10]) as $jday |
        (if ($j | is_hosted_macos) then {macos_min: $m, gross: ($m * 0.062)}
         elif ($j | is_hosted_ubuntu) then {macos_min: 0, gross: ($m * 0.006)}
         else {macos_min: 0, gross: 0}
         end)
        | {
            day: $jday,
            repo: $repo,
            macos_min: .macos_min,
            gross_usd: .gross
          }
      ' "$tmp.jobs" >> "$tmp.fallback_items"
    done < <(jq -r '(.workflow_runs // [])[] | select((.conclusion // "") != "skipped") | [(.id // empty), ((.created_at // "")[:10])] | @tsv' "$tmp.runs" 2>/dev/null || true)
  done < <(jq -r --arg yesterday "$YESTERDAY_UTC" --arg today "$TODAY_UTC" '
    (.[]? | select(((.pushed_at // $today)[:10]) >= $yesterday) | [(.name // ""), (.full_name // "")] | @tsv)
  ' "$tmp.repos" 2>/dev/null || true)

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
run_mode="billing_api"
fallback_reason=""
if ! remaining="$("$GH_BIN" api rate_limit --jq '.resources.core.remaining // empty' 2>"$tmp.err")"; then
  fallback_reason="gh api rate_limit failed"
elif [[ "$remaining" =~ ^[0-9]+$ ]] && [ "$remaining" -lt "$MIN_RATE_LIMIT_REMAINING" ]; then
  fallback_reason="GitHub core rate limit remaining=$remaining (< $MIN_RATE_LIMIT_REMAINING)"
elif ! "$GH_BIN" api "/organizations/${ALERT_ORG}/settings/billing/usage?year=${YEAR}&month=${MONTH}" > "$tmp" 2>"$tmp.err" || \
     ! jq -e '.usageItems | type == "array"' "$tmp" >/dev/null 2>&1; then
  fallback_reason="gh api billing usage failed"
elif [ "$YEST_YEAR_MONTH" != "$YEAR_MONTH" ]; then
  if ! "$GH_BIN" api "/organizations/${ALERT_ORG}/settings/billing/usage?year=${YEST_YEAR}&month=${YEST_MONTH}&day=${YEST_DAY}" > "$tmp.yest" 2>"$tmp.err" || \
     ! jq -e '.usageItems | type == "array"' "$tmp.yest" >/dev/null 2>&1; then
    fallback_reason="gh api billing usage (previous month ${YEST_YEAR_MONTH}) failed"
  else
    jq -sc '{usageItems: ((.[0].usageItems // []) + (.[1].usageItems // []))}' "$tmp" "$tmp.yest" > "$tmp.merged"
    mv "$tmp.merged" "$tmp"
  fi
fi

if [ -n "$fallback_reason" ]; then
  if run_app_token_fallback "$fallback_reason"; then
    used_fallback=1
    run_mode="$FALLBACK_MODE"
  else
    record_blind_failure "$fallback_reason" "blind"
    exit 2
  fi
fi

if [ "$used_fallback" -eq 0 ]; then
  jq '.api_failures = 0' "$STATE_FILE" > "$tmp.state"
  mv "$tmp.state" "$STATE_FILE"

  jq -c --arg today "$TODAY_UTC" --arg yesterday "$YESTERDAY_UTC" --arg year_month "$YEAR_MONTH" '
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
    | {
        mtd: {
          gross_usd: ($mtd_actions | sum_gross),
          net_usd: ($mtd_actions | sum_net),
          macos_min: ($mtd_actions | sum_macos_min)
        },
        days: ([$yesterday, $today] | unique | map(day_summary(.; $all_actions)))
      }
  ' "$tmp" > "$tmp.summary"
fi

fmt_usd() { awk -v v="$1" 'BEGIN{printf "%.2f", v + 0}'; }
fmt_min() { awk -v v="$1" 'BEGIN{if (v + 0 == int(v + 0)) printf "%d", v + 0; else printf "%.1f", v + 0}'; }
ge_num() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a + 0 >= b + 0)}'; }

should_emit() {
  local key="$1" prev
  prev="$(jq -r --arg k "$key" '.sent[$k] // 0' "$STATE_FILE")"
  [ $((NOW - prev)) -ge "$COOLDOWN_SEC" ]
}

mark_emitted() {
  local key="$1"
  jq --arg k "$key" --argjson now "$NOW" '.sent[$k] = $now | .last_sent = $now' "$STATE_FILE" > "$tmp.state"
  mv "$tmp.state" "$STATE_FILE"
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
      if emit ERROR COST_SPIKE "$day" "$msg" "$d_gross" "$d_net" "$d_macos" "$top_repo" "$run_mode" "$mtd_gross" "$mtd_net"; then
        mark_emitted "$key"
        alerted=$((alerted + 1))
      else
        echo "ERROR: alert sink failed for $key" >&2; exit 3
      fi
    fi
  fi

  if [ "$used_fallback" -eq 0 ] && [ "$d_net" != "null" ] && ge_num "$d_net" "$DAILY_NET_WARN_USD"; then
    key="${day}:NET_SPEND_BREACH"
    if should_emit "$key"; then
      msg="GitHub Actions daily NET spend breach in $ALERT_ORG on $day: \$${d_net_fmt} net (>= \$${DAILY_NET_WARN_USD}; \$${d_gross_fmt} gross, ${d_macos_fmt} macOS min); top repo $top_repo (\$${top_net_fmt} net, \$${top_gross_fmt} gross); MTD \$${mtd_net_fmt} net"
      if emit ERROR NET_SPEND_BREACH "$day" "$msg" "$d_gross" "$d_net" "$d_macos" "$top_repo" "$run_mode" "$mtd_gross" "$mtd_net"; then
        mark_emitted "$key"
        alerted=$((alerted + 1))
      else
        echo "ERROR: alert sink failed for $key" >&2; exit 3
      fi
    fi
  fi
done < <(jq -r '.days[] | [.day, .gross_usd, (.net_usd // "null"), .macos_min, .top_repo, .top_repo_gross_usd, (.top_repo_net_usd // "null"), .top_repo_macos_min] | @tsv' "$tmp.summary")

if [ "$used_fallback" -eq 0 ] && [ "$mtd_net" != "null" ] && ge_num "$mtd_net" "$MTD_NET_WARN_USD"; then
  key="${YEAR_MONTH}:MTD_NET_BREACH"
  if should_emit "$key"; then
    msg="GitHub Actions MTD NET spend breach in $ALERT_ORG (${YEAR_MONTH}): \$${mtd_net_fmt} net (>= \$${MTD_NET_WARN_USD}; \$${mtd_gross_fmt} gross, ${mtd_macos_fmt} macOS min)"
    if emit ERROR MTD_SPEND_BREACH "$TODAY_UTC" "$msg" "$mtd_gross" "$mtd_net" "$mtd_macos" "" "$run_mode" "$mtd_gross" "$mtd_net"; then
      mark_emitted "$key"
      alerted=$((alerted + 1))
    else
      echo "ERROR: alert sink failed for $key" >&2; exit 3
    fi
  fi
fi

if [ "$used_fallback" -eq 0 ] && [ "$mtd_gross" != "null" ] && ge_num "$mtd_gross" "$MTD_GROSS_WARN_USD"; then
  key="${YEAR_MONTH}:MTD_GROSS_BREACH"
  if should_emit "$key"; then
    msg="GitHub Actions MTD GROSS usage breach in $ALERT_ORG (${YEAR_MONTH}): \$${mtd_gross_fmt} gross (>= \$${MTD_GROSS_WARN_USD}; \$${mtd_net_fmt} net, ${mtd_macos_fmt} macOS min)"
    if emit ERROR MTD_SPEND_BREACH "$TODAY_UTC" "$msg" "$mtd_gross" "$mtd_net" "$mtd_macos" "" "$run_mode" "$mtd_gross" "$mtd_net"; then
      mark_emitted "$key"
      alerted=$((alerted + 1))
    else
      echo "ERROR: alert sink failed for $key" >&2; exit 3
    fi
  fi
fi

if [ "$used_fallback" -eq 1 ]; then
  if [ "$FALLBACK_CAP_HIT" -eq 1 ]; then
    blind_detail="${fallback_reason}; App fallback ran (${run_mode}, hit MAX_APP_API_CALLS=${MAX_APP_API_CALLS})"
  elif [ "$FALLBACK_INCOMPLETE" -eq 1 ]; then
    blind_detail="${fallback_reason}; partial App fallback ran (${run_mode})"
  else
    blind_detail="${fallback_reason}; gross-only App fallback ran (${run_mode})"
  fi
  record_blind_failure "$blind_detail" "$run_mode"
  failures_now="$(jq -r '.api_failures // 0' "$STATE_FILE")"
  echo "[$NOW_ISO] DEGRADED: org=$ALERT_ORG mode=$run_mode mtd_gross=null mtd_net=null mtd_macos_min=null api_failures=$failures_now fallback_incomplete=$FALLBACK_INCOMPLETE alerts_emitted=${alerted}"
else
  echo "[$NOW_ISO] OK: org=$ALERT_ORG mode=$run_mode mtd_gross=\$${mtd_gross_fmt} mtd_net=\$${mtd_net_fmt} mtd_macos_min=${mtd_macos_fmt} alerts_emitted=${alerted}"
fi
