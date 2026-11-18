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
#     most 24 `rate_limit` + 24 `/settings/billing/usage` `gh api` calls/day
#     (48 calls/day, ~0.04% of the 5,000/hr personal REST quota; 0 calls
#     against the GitHub App token when personal quota >= 50).
#   - Bounded App-token fallback (only when personal `core.remaining < 50` or
#     `/settings/billing/usage` fails/403): uses `APP_TOKEN_FILE` when its
#     `core.remaining >= 200`, hard-capped at `MAX_APP_API_CALLS=60` App-token
#     API calls/hour (= 0.58% of the 10,400/hr App installation quota).
#   - Safe remaining margin: pre-checks `.resources.core.remaining` before
#     querying billing or scanning fallback runs and only emits `BLIND` if both
#     the billing API and App-token fallback are unavailable/exhausted.
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

emit() { # severity status day message gross_usd net_usd macos_min top_repo
  local severity="$1" status="$2" day="$3" message="$4" gross_usd="$5" net_usd="$6" macos_min="$7" top_repo="$8"
  local payload
  payload="$(jq -nc \
    --arg source "$SOURCE" \
    --arg status "$status" \
    --arg sev "$severity" \
    --arg org "$ALERT_ORG" \
    --arg day "$day" \
    --arg message "$message" \
    --arg top_repo "$top_repo" \
    --arg ts "$NOW_ISO" \
    --argjson gross "${gross_usd:-0}" \
    --argjson net "${net_usd:-0}" \
    --argjson macos_min "${macos_min:-0}" \
    '{
      source: $source,
      status: $status,
      severity: $sev,
      org: $org,
      day: $day,
      top_repo: $top_repo,
      gross_usd: $gross,
      net_usd: $net,
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
  emit ERROR TEST "$TODAY_UTC" "TEST ONLY: GitHub Actions cost alert pipeline check for $ALERT_ORG" 0 0 0 ""
  exit 0
fi

# CRITICAL AUTH DETAIL:
# Do NOT load ~/.config/ezgha/gh_token (GitHub App 4245332 lacks
# organization_administration=read and returns HTTP 403 on /settings/billing/usage).
# Use GH_BILLING_TOKEN when provided; otherwise unset GH_TOKEN/GITHUB_TOKEN so `gh`
# uses the host's authenticated user keyring.
if [ -n "${GH_BILLING_TOKEN:-}" ]; then
  export GH_TOKEN="$GH_BILLING_TOKEN"
else
  unset GH_TOKEN GITHUB_TOKEN
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp:?}" "$tmp.summary" "$tmp.err" "$tmp.state" "$tmp.snapshot" "$tmp.next" "$tmp.repos" "$tmp.runs" "$tmp.jobs" "$tmp.fallback_items"' EXIT

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
  local reason="$1"
  local failures last_blind
  failures="$(jq -r '.api_failures // 0' "$STATE_FILE")"
  failures=$((failures + 1))
  last_blind="$(jq -r '.last_blind // 0' "$STATE_FILE")"
  jq --argjson failures "$failures" '.api_failures = $failures' "$STATE_FILE" > "$tmp.state"
  if [ "$failures" -ge "$MAX_API_FAILURES" ] && [ $((NOW - last_blind)) -ge "$COOLDOWN_SEC" ]; then
    emit WARNING BLIND "$TODAY_UTC" \
      "GitHub Actions cost monitor cannot query billing usage for $ALERT_ORG after $failures consecutive failures ($reason)" \
      0 0 0 ""
    jq --argjson now "$NOW" '.last_blind = $now' "$tmp.state" > "$tmp.next"
    mv "$tmp.next" "$tmp.state"
  fi
  mv "$tmp.state" "$STATE_FILE"
  echo "[$NOW_ISO] WARN: $reason ($failures consecutive); cost state unverified" >&2
}

run_app_token_fallback() {
  local reason="$1"
  local app_token app_rem calls_used=0
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

  : > "$tmp.fallback_items"
  local repo_name full_name is_private run_id
  while IFS=$'\t' read -r repo_name full_name is_private; do
    [ -n "$full_name" ] || continue
    [ "$calls_used" -lt "$MAX_APP_API_CALLS" ] || break
    if ! GH_TOKEN="$app_token" "$GH_BIN" api "repos/${full_name}/actions/runs?created=${TODAY_UTC}&per_page=50" > "$tmp.runs" 2>"$tmp.err"; then
      calls_used=$((calls_used + 1))
      continue
    fi
    calls_used=$((calls_used + 1))

    while IFS= read -r run_id; do
      [ -n "$run_id" ] || continue
      [ "$calls_used" -lt "$MAX_APP_API_CALLS" ] || break
      if ! GH_TOKEN="$app_token" "$GH_BIN" api "repos/${full_name}/actions/runs/${run_id}/jobs" > "$tmp.jobs" 2>"$tmp.err"; then
        calls_used=$((calls_used + 1))
        continue
      fi
      calls_used=$((calls_used + 1))

      jq -c --arg day "$TODAY_UTC" --arg repo "$repo_name" --arg now_iso "$NOW_ISO" --argjson is_private "$is_private" '
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
        [(.jobs // [])[] | . as $j | job_mins as $m |
          if ($j | is_hosted_macos) then {macos_min: $m, gross: ($m * 0.062), net: (if $is_private then ($m * 0.062) else 0 end)}
          elif ($j | is_hosted_ubuntu) then {macos_min: 0, gross: ($m * 0.006), net: (if $is_private then ($m * 0.006) else 0 end)}
          else {macos_min: 0, gross: 0, net: 0}
          end
        ] | {
          day: $day,
          repo: $repo,
          macos_min: (map(.macos_min) | add // 0),
          gross_usd: (map(.gross) | add // 0),
          net_usd: (map(.net) | add // 0)
        }
      ' "$tmp.jobs" >> "$tmp.fallback_items"
    done < <(jq -r '(.workflow_runs // [])[] | select((.conclusion // "") != "skipped") | .id // empty' "$tmp.runs" 2>/dev/null || true)
  done < <(jq -r --arg yesterday "$YESTERDAY_UTC" --arg today "$TODAY_UTC" '
    (.[]? | select(((.pushed_at // $today)[:10]) >= $yesterday) | [(.name // ""), (.full_name // ""), (.private // false)] | @tsv)
  ' "$tmp.repos" 2>/dev/null || true)

  jq -sc --arg today "$TODAY_UTC" '
    def sum_gross: (map(.gross_usd // 0) | add // 0);
    def sum_net: (map(.net_usd // 0) | add // 0);
    def sum_macos_min: (map(.macos_min // 0) | add // 0);
    . as $rows
    | ($rows | group_by(.repo) | map({
        repo: .[0].repo,
        gross_usd: sum_gross,
        net_usd: sum_net,
        macos_min: sum_macos_min
      }) | sort_by(-.gross_usd, -.macos_min, -.net_usd)) as $repos
    | {
        mtd: {
          gross_usd: ($rows | sum_gross),
          net_usd: ($rows | sum_net),
          macos_min: ($rows | sum_macos_min)
        },
        days: [{
          day: $today,
          gross_usd: ($rows | sum_gross),
          net_usd: ($rows | sum_net),
          macos_min: ($rows | sum_macos_min),
          top_repo: ($repos[0].repo // "(none)"),
          top_repo_gross_usd: ($repos[0].gross_usd // 0),
          top_repo_net_usd: ($repos[0].net_usd // 0),
          top_repo_macos_min: ($repos[0].macos_min // 0)
        }]
      }
  ' "$tmp.fallback_items" > "$tmp.summary"
  echo "[$NOW_ISO] INFO: billing fallback via App token ($reason; app_api_calls=$calls_used/$MAX_APP_API_CALLS)" >&2
  return 0
}

used_fallback=0
fallback_reason=""
if ! remaining="$("$GH_BIN" api rate_limit --jq '.resources.core.remaining // empty' 2>"$tmp.err")"; then
  fallback_reason="gh api rate_limit failed"
elif [[ "$remaining" =~ ^[0-9]+$ ]] && [ "$remaining" -lt "$MIN_RATE_LIMIT_REMAINING" ]; then
  fallback_reason="GitHub core rate limit remaining=$remaining (< $MIN_RATE_LIMIT_REMAINING)"
elif ! "$GH_BIN" api "orgs/${ALERT_ORG}/settings/billing/usage?year=${YEAR}&month=${MONTH}" > "$tmp" 2>"$tmp.err" || \
     ! jq -e '.usageItems | type == "array"' "$tmp" >/dev/null 2>&1; then
  fallback_reason="gh api billing usage failed"
fi

if [ -n "$fallback_reason" ]; then
  if run_app_token_fallback "$fallback_reason"; then
    used_fallback=1
  else
    record_blind_failure "$fallback_reason"
    exit 2
  fi
fi

jq '.api_failures = 0' "$STATE_FILE" > "$tmp.state"
mv "$tmp.state" "$STATE_FILE"

if [ "$used_fallback" -eq 0 ]; then
  jq -c --arg today "$TODAY_UTC" --arg yesterday "$YESTERDAY_UTC" '
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
    | {
        mtd: {
          gross_usd: ($all_actions | sum_gross),
          net_usd: ($all_actions | sum_net),
          macos_min: ($all_actions | sum_macos_min)
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

mtd_gross="$(jq -r '.mtd.gross_usd' "$tmp.summary")"
mtd_net="$(jq -r '.mtd.net_usd' "$tmp.summary")"
mtd_macos="$(jq -r '.mtd.macos_min' "$tmp.summary")"
mtd_gross_fmt="$(fmt_usd "$mtd_gross")"
mtd_net_fmt="$(fmt_usd "$mtd_net")"
mtd_macos_fmt="$(fmt_min "$mtd_macos")"

alerted=0
while IFS=$'\t' read -r day d_gross d_net d_macos top_repo top_gross top_net top_macos; do
  [ -n "$day" ] || continue
  d_gross_fmt="$(fmt_usd "$d_gross")"
  d_net_fmt="$(fmt_usd "$d_net")"
  d_macos_fmt="$(fmt_min "$d_macos")"
  top_gross_fmt="$(fmt_usd "$top_gross")"
  top_net_fmt="$(fmt_usd "$top_net")"
  top_macos_fmt="$(fmt_min "$top_macos")"

  if ge_num "$d_gross" "$DAILY_GROSS_WARN_USD" || ge_num "$d_macos" "$DAILY_MACOS_MIN_WARN"; then
    key="${day}:COST_SPIKE"
    if should_emit "$key"; then
      msg="GitHub Actions cost/macOS spike in $ALERT_ORG on $day: \$${d_gross_fmt} gross, ${d_macos_fmt} macOS min (\$${d_net_fmt} net); top repo $top_repo (${top_macos_fmt} macOS min, \$${top_gross_fmt} gross); MTD \$${mtd_gross_fmt} gross / \$${mtd_net_fmt} net"
      if emit ERROR COST_SPIKE "$day" "$msg" "$d_gross" "$d_net" "$d_macos" "$top_repo"; then
        mark_emitted "$key"
        alerted=$((alerted + 1))
      else
        echo "ERROR: alert sink failed for $key" >&2; exit 3
      fi
    fi
  fi

  if ge_num "$d_net" "$DAILY_NET_WARN_USD"; then
    key="${day}:NET_SPEND_BREACH"
    if should_emit "$key"; then
      msg="GitHub Actions daily NET spend breach in $ALERT_ORG on $day: \$${d_net_fmt} net (>= \$${DAILY_NET_WARN_USD}; \$${d_gross_fmt} gross, ${d_macos_fmt} macOS min); top repo $top_repo (\$${top_net_fmt} net, \$${top_gross_fmt} gross); MTD \$${mtd_net_fmt} net"
      if emit ERROR NET_SPEND_BREACH "$day" "$msg" "$d_gross" "$d_net" "$d_macos" "$top_repo"; then
        mark_emitted "$key"
        alerted=$((alerted + 1))
      else
        echo "ERROR: alert sink failed for $key" >&2; exit 3
      fi
    fi
  fi
done < <(jq -r '.days[] | [.day, .gross_usd, .net_usd, .macos_min, .top_repo, .top_repo_gross_usd, .top_repo_net_usd, .top_repo_macos_min] | @tsv' "$tmp.summary")

if ge_num "$mtd_net" "$MTD_NET_WARN_USD"; then
  key="${YEAR_MONTH}:MTD_NET_BREACH"
  if should_emit "$key"; then
    msg="GitHub Actions MTD NET spend breach in $ALERT_ORG (${YEAR_MONTH}): \$${mtd_net_fmt} net (>= \$${MTD_NET_WARN_USD}; \$${mtd_gross_fmt} gross, ${mtd_macos_fmt} macOS min)"
    if emit ERROR MTD_SPEND_BREACH "$TODAY_UTC" "$msg" "$mtd_gross" "$mtd_net" "$mtd_macos" ""; then
      mark_emitted "$key"
      alerted=$((alerted + 1))
    else
      echo "ERROR: alert sink failed for $key" >&2; exit 3
    fi
  fi
fi

if ge_num "$mtd_gross" "$MTD_GROSS_WARN_USD"; then
  key="${YEAR_MONTH}:MTD_GROSS_BREACH"
  if should_emit "$key"; then
    msg="GitHub Actions MTD GROSS usage breach in $ALERT_ORG (${YEAR_MONTH}): \$${mtd_gross_fmt} gross (>= \$${MTD_GROSS_WARN_USD}; \$${mtd_net_fmt} net, ${mtd_macos_fmt} macOS min)"
    if emit ERROR MTD_SPEND_BREACH "$TODAY_UTC" "$msg" "$mtd_gross" "$mtd_net" "$mtd_macos" ""; then
      mark_emitted "$key"
      alerted=$((alerted + 1))
    else
      echo "ERROR: alert sink failed for $key" >&2; exit 3
    fi
  fi
fi

echo "[$NOW_ISO] OK: org=$ALERT_ORG mtd_gross=\$${mtd_gross_fmt} mtd_net=\$${mtd_net_fmt} mtd_macos_min=${mtd_macos_fmt} alerts_emitted=${alerted}"
