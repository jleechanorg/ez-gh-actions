#!/usr/bin/env bash
# Alert on failed or unusually long iOS TestFlight workflow runs.
# Uses the ezgha Cloud Logging -> Cloud Monitoring -> Slack/SMS path.
set -euo pipefail

REPO="${ALERT_REPO:-jleechanorg/worldai_frontend}"
WORKFLOW="${ALERT_WORKFLOW:-ios-testflight.yml}"
RUN_STUCK_MIN="${RUN_STUCK_MIN:-50}"
FAILURE_WINDOW_MIN="${FAILURE_WINDOW_MIN:-30}"
COOLDOWN_SEC="${COOLDOWN_SEC:-1800}"
MAX_API_FAILURES="${MAX_API_FAILURES:-3}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/ezgha/testflight-workflow-alert.json}"
GH_BIN="${GH_BIN:-gh}"
GCLOUD_BIN="${GCLOUD_BIN:-$(command -v gcloud || true)}"
GCP_PROJECT="${GCP_PROJECT:-worldarchitecture-ai}"
GCP_ACCOUNT="${GCP_ACCOUNT:-jleechan@gmail.com}"
LOG_NAME="${LOG_NAME:-ezgha-runner-alerts}"
SOURCE="ios-testflight-run-alert"
NOW="$(date +%s)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DRY_RUN=0 ENSURE_POLICY=0 TEST_ALERT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --ensure-gcp-policy) ENSURE_POLICY=1 ;;
    --test-alert) TEST_ALERT=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 64 ;;
  esac
done

if [ "$DRY_RUN" -eq 0 ] && [ -z "$GCLOUD_BIN" ]; then
  echo "FATAL: gcloud not found; refusing to monitor without an alert path" >&2; exit 3
fi

if [ "$ENSURE_POLICY" -eq 1 ]; then
  POLICY_RUN_FILE="$(mktemp)"
  POLICY_SMS_FILE="$(mktemp)"
  trap 'rm -f "$POLICY_RUN_FILE" "$POLICY_SMS_FILE"' EXIT
  jq -n --arg source "$SOURCE" --arg log "$LOG_NAME" --arg project "$GCP_PROJECT" \
    '("logName=\"projects/"+$project+"/logs/"+$log+"\" AND jsonPayload.source=\""+$source+"\"") as $common |
    {displayName:"[CRITICAL] WorldAI iOS TestFlight run monitor alert",
      documentation:{content:"An iOS TestFlight run failed, exceeded its run-time threshold, or the monitor cannot verify GitHub state.",mimeType:"text/markdown"},
      combiner:"OR",severity:"CRITICAL",
      conditions:[{displayName:"TestFlight run failure, stuck, or monitor blind",conditionMatchedLog:{filter:("("+$common+" AND severity>=ERROR AND (jsonPayload.status=\"RUN_FAILED\" OR jsonPayload.status=\"RUN_STUCK\")) OR ("+$common+" AND jsonPayload.status=\"BLIND\" AND severity>=WARNING)")}}],
      alertStrategy:{autoClose:"1800s",notificationRateLimit:{period:"300s"}},
      notificationChannels:["projects/worldarchitecture-ai/notificationChannels/14071650426226468737"],
      enabled:true,userLabels:{component:"worldai-testflight",severity:"critical"}}' > "$POLICY_RUN_FILE"
  jq -n --arg source "$SOURCE" --arg log "$LOG_NAME" --arg project "$GCP_PROJECT" --arg repo "$REPO" --arg workflow "$WORKFLOW" \
    '("logName=\"projects/"+$project+"/logs/"+$log+"\" AND jsonPayload.source=\""+$source+"\"") as $common |
    {displayName:"[CRITICAL] WorldAI iOS TestFlight consecutive failures",
      documentation:{content:"Three or more consecutive automatic TestFlight builds failed.",mimeType:"text/markdown"},
      combiner:"OR",severity:"CRITICAL",
      conditions:[{displayName:"TestFlight consecutive build failures",conditionMatchedLog:{filter:($common+" AND severity>=ERROR AND jsonPayload.status=\"SMS_FAILURE_STREAK\" AND jsonPayload.failure_streak>=3 AND jsonPayload.repo=\""+$repo+"\" AND jsonPayload.workflow=\""+$workflow+"\"")}}],
      alertStrategy:{autoClose:"1800s",notificationRateLimit:{period:"300s"}},
      notificationChannels:["projects/worldarchitecture-ai/notificationChannels/17167119139665448890"],
      enabled:true,userLabels:{component:"worldai-testflight",severity:"critical"}}' > "$POLICY_SMS_FILE"
  if [ "$DRY_RUN" -eq 1 ]; then
    jq -c . "$POLICY_RUN_FILE"
    jq -c . "$POLICY_SMS_FILE"
    exit 0
  fi
  [ -n "$GCLOUD_BIN" ] || { echo "FATAL: gcloud not found" >&2; exit 3; }
  GCP_ARGS=(--project="$GCP_PROJECT" --account="$GCP_ACCOUNT")
  for policy_file in "$POLICY_RUN_FILE" "$POLICY_SMS_FILE"; do
    display_name="$(jq -r .displayName "$policy_file")"
    existing="$("$GCLOUD_BIN" alpha monitoring policies list "${GCP_ARGS[@]}" \
      --filter="displayName=\"$display_name\"" --format='value(name)' 2>/dev/null | head -1)"
    if [ -n "$existing" ]; then
      "$GCLOUD_BIN" alpha monitoring policies update "$existing" --policy-from-file="$policy_file" "${GCP_ARGS[@]}" >/dev/null
      echo "[$NOW_ISO] updated policy '$display_name'"
    else
      "$GCLOUD_BIN" alpha monitoring policies create --policy-from-file="$policy_file" "${GCP_ARGS[@]}" >/dev/null
      echo "[$NOW_ISO] created policy '$display_name'"
    fi
  done
  exit 0
fi

emit() { # severity status run_id attempt message url sha [failure_streak]
  local severity="$1" status="$2" run_id="$3" attempt="$4" message="$5" url="$6" sha="$7" streak payload
  if [ "$#" -ge 8 ]; then streak="$8"; else streak=""; fi
  payload="$(jq -nc --arg source "$SOURCE" --arg status "$status" --arg sev "$severity" \
    --arg repo "$REPO" --arg workflow "$WORKFLOW" --arg id "$run_id" --arg attempt "$attempt" \
    --arg message "$message" --arg url "$url" --arg sha "$sha" --arg ts "$NOW_ISO" --arg streak "$streak" \
    '({source:$source,status:$status,severity:$sev,repo:$repo,workflow:$workflow,run_id:$id,attempt:$attempt,message:$message,url:$url,head_sha:$sha,ts:$ts} | if $streak == "" then . else . + {failure_streak:($streak|tonumber)} end)')"
  if [ "$DRY_RUN" -eq 1 ]; then echo "[$NOW_ISO] [dry-run] $payload"
  else "$GCLOUD_BIN" logging write "$LOG_NAME" "$payload" --payload-type=json --severity="$severity" --project="$GCP_PROJECT" --account="$GCP_ACCOUNT" >/dev/null; fi
}

if [ "$TEST_ALERT" -eq 1 ]; then
  emit ERROR TEST test 1 "TEST ONLY: TestFlight alert path validation" "https://github.com/$REPO/actions" test
  exit 0
fi

# gh may use the scoped GitHub App token already installed for the queue monitor.
if [ -z "${GH_TOKEN:-}" ] && [ -r "$HOME/.config/ezgha/gh_token" ]; then
  GH_TOKEN="$(cat "$HOME/.config/ezgha/gh_token" 2>/dev/null || true)"
  [ -z "$GH_TOKEN" ] || export GH_TOKEN
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.encoded" "$tmp.rows" "$tmp.streak_rows" "$tmp.err" "$tmp.state" "$tmp.snapshot" "$tmp.next"' EXIT
if [ "$DRY_RUN" -eq 1 ]; then
  # Keep every dry-run state mutation in a separate disposable snapshot.
  if [ -r "$STATE_FILE" ]; then cp "$STATE_FILE" "$tmp.snapshot"
  else printf '%s\n' '{"seen":{},"api_failures":0,"last_blind":0}' > "$tmp.snapshot"; fi
  STATE_FILE="$tmp.snapshot"
else
  mkdir -p "$(dirname "$STATE_FILE")"
  if [ ! -f "$STATE_FILE" ]; then printf '%s\n' '{"seen":{},"api_failures":0,"last_blind":0}' > "$STATE_FILE"; fi
  jq --argjson now "$NOW" '.seen = ((.seen // {}) | with_entries(select(.value > ($now - 172800))))' \
    "$STATE_FILE" > "$STATE_FILE.next"
  mv "$STATE_FILE.next" "$STATE_FILE"
fi
if ! "$GH_BIN" api "repos/$REPO/actions/workflows/$WORKFLOW/runs?per_page=100" --jq '.workflow_runs[] | @json' > "$tmp.encoded" 2>"$tmp.err" || ! jq -r . "$tmp.encoded" > "$tmp"; then
  failures="$(jq -r '.api_failures // 0' "$STATE_FILE")"; failures=$((failures + 1))
  last_blind="$(jq -r '.last_blind // 0' "$STATE_FILE")"
  jq --argjson failures "$failures" --argjson now "$NOW" '.api_failures=$failures' "$STATE_FILE" > "$tmp.state"
  if [ "$failures" -ge "$MAX_API_FAILURES" ] && [ $((NOW - last_blind)) -ge "$COOLDOWN_SEC" ]; then
    emit WARNING BLIND '' '' "TestFlight run monitor cannot reach GitHub after $failures consecutive failures; run status is unverified" "" ""
    jq --argjson now "$NOW" '.last_blind=$now' "$tmp.state" > "$tmp.next"; mv "$tmp.next" "$tmp.state"
  fi
  mv "$tmp.state" "$STATE_FILE"
  echo "[$NOW_ISO] WARN: GitHub API failed ($failures consecutive); release state unknown" >&2
  exit 2
fi
jq -r '[.id, (.run_number // "-"), .run_attempt, (.event // "-"), (.status // "-"), (.conclusion // "-"), (.name // "-"), (.run_started_at // .created_at // "-"), (.updated_at // .created_at // "-"), (.html_url // "-"), (.head_sha // "-")] | @tsv' \
  "$tmp" > "$tmp.rows"
jq -sr 'sort_by((.run_number // 0), (.run_attempt // 0))[] | [.id, (.run_number // "-"), .run_attempt, (.event // "-"), (.status // "-"), (.conclusion // "-"), (.html_url // "-"), (.head_sha // "-")] | @tsv' \
  "$tmp" > "$tmp.streak_rows"

jq '.api_failures=0' "$STATE_FILE" > "$tmp.state"; mv "$tmp.state" "$STATE_FILE"
count="$(wc -l < "$tmp.rows" | tr -d ' ')"
[ "$count" -le 100 ] || { echo "ERROR: workflow run listing exceeded 100 entries" >&2; exit 1; }
while IFS=$'\t' read -r id run_number attempt event status conclusion name created completed url sha; do
  [ -n "$id" ] || continue
  [ -n "$id" ] && [ -n "$attempt" ] && [ -n "$created" ] || continue
  # Workflow ID API is authoritative; retain the name check as a fail-safe.
  [ "$name" = "iOS TestFlight" ] || continue
  reason="" timestamp="$created"
  if [ "$status" = completed ] && [ "$conclusion" != success ] && [ "$conclusion" != skipped ] && [ "$conclusion" != neutral ] && [ "$conclusion" != cancelled ]; then
    reason=RUN_FAILED; timestamp="$completed"
    epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" +%s 2>/dev/null || date -u -d "$timestamp" +%s 2>/dev/null || echo 0)"
    age=$((NOW - epoch))
    [ "$epoch" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -le $((FAILURE_WINDOW_MIN * 60)) ] || continue
  elif [ "$status" = in_progress ]; then
    epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null || date -u -d "$created" +%s 2>/dev/null || echo 0)"
    [ "$epoch" -gt 0 ] && [ $((NOW - epoch)) -ge $((RUN_STUCK_MIN * 60)) ] || continue
    reason=RUN_STUCK
  else
    continue
  fi
  fingerprint="$id:$attempt:$reason"
  if jq -e --arg f "$fingerprint" '.seen[$f] != null' "$STATE_FILE" >/dev/null; then continue; fi
  if [ "$reason" = RUN_FAILED ]; then message="TestFlight workflow run $id attempt $attempt finished with conclusion '$conclusion'"
  else message="TestFlight workflow run $id attempt $attempt has been in progress for at least ${RUN_STUCK_MIN} minutes"; fi
  if emit ERROR "$reason" "$id" "$attempt" "$message" "$url" "$sha"; then
    jq --arg f "$fingerprint" --argjson now "$NOW" '.seen[$f]=$now' "$STATE_FILE" > "$tmp.state"
    mv "$tmp.state" "$STATE_FILE"
  else
    echo "ERROR: alert sink failed for run $id" >&2; exit 3
  fi
done < "$tmp.rows"

# Merge completed automatic outcomes in run order so late completions are retained.
while IFS=$'\t' read -r id run_number attempt event status conclusion url sha; do
  [ "$status" = completed ] || continue
  [[ "$run_number" =~ ^[0-9]+$ ]] || continue
  [[ "$attempt" =~ ^[0-9]+$ ]] || continue
  [ "$conclusion" != "-" ] || continue
  success_number="$(jq -r '.streak_last_success_number // 0' "$STATE_FILE")"
  success_attempt="$(jq -r '.streak_last_success_attempt // 0' "$STATE_FILE")"
  if [ "$run_number" -lt "$success_number" ] || { [ "$run_number" -eq "$success_number" ] && [ "$attempt" -le "$success_attempt" ]; }; then
    continue
  fi
  if [ "$event" = push ] && [ "$conclusion" = success ]; then
    jq --argjson number "$run_number" --argjson attempt "$attempt" \
      '.streak_last_success_number=$number | .streak_last_success_attempt=$attempt | .streak_failures=((.streak_failures // []) | map(select((.run_number > $number) or (.run_number == $number and .attempt > $attempt)))) | .failure_streak=(.streak_failures|length) | .streak_notified=false' \
      "$STATE_FILE" > "$tmp.state"
    mv "$tmp.state" "$STATE_FILE"
    continue
  fi
  [ "$event" = push ] || continue
  case "$conclusion" in failure|timed_out|action_required|startup_failure) ;; *) continue ;; esac
  if jq -e --arg id "$id" --argjson number "$run_number" --argjson attempt "$attempt" \
      'any(.streak_failures[]?; .id==$id and .run_number==$number and .attempt==$attempt)' "$STATE_FILE" >/dev/null; then
    continue
  fi
  jq --arg id "$id" --argjson number "$run_number" --argjson attempt "$attempt" --arg url "$url" --arg sha "$sha" \
    '.streak_failures=(((.streak_failures // []) + [{id:$id,run_number:$number,attempt:$attempt,url:$url,head_sha:$sha}]) | sort_by(.run_number,.attempt) | .[-3:]) | .failure_streak=(.streak_failures|length)' \
    "$STATE_FILE" > "$tmp.state"
  mv "$tmp.state" "$STATE_FILE"

done < "$tmp.streak_rows"

# Decide once from the final folded state so a newer success in this response
# suppresses any threshold reached by older history in the same response.
streak="$(jq -r '.failure_streak // 0' "$STATE_FILE")"
notified="$(jq -r '.streak_notified // false' "$STATE_FILE")"
if [ "$streak" -ge 3 ] && [ "$notified" != true ]; then
  latest="$(jq -c '.streak_failures[-1] // {}' "$STATE_FILE")"
  latest_id="$(jq -r '.id // ""' <<<"$latest")"
  latest_attempt="$(jq -r '.attempt // ""' <<<"$latest")"
  latest_url="$(jq -r '.url // "-" ' <<<"$latest")"
  latest_sha="$(jq -r '.head_sha // "-" ' <<<"$latest")"
  message="TestFlight workflow has at least 3 consecutive failed automatic builds; latest run $latest_id attempt $latest_attempt"
  if ! emit ERROR SMS_FAILURE_STREAK "$latest_id" "$latest_attempt" "$message" "$latest_url" "$latest_sha" "$streak"; then
    echo "ERROR: SMS streak alert sink failed at run $latest_id" >&2; exit 3
  fi
  jq '.streak_notified=true' "$STATE_FILE" > "$tmp.state"
  mv "$tmp.state" "$STATE_FILE"
fi
echo "[$NOW_ISO] OK: inspected $count recent TestFlight run(s); no new alert"
