#!/usr/bin/env bash
# runner-offline-queued-alert.sh — SMS when a named self-hosted runner is not online
# while workflow runs sit queued behind it (2026-10-27: worldai-testflight-native-mac
# stayed offline ~10h and every iOS TestFlight push queued).
#
# Reuses the existing GCP path: an ERROR entry in Cloud Logging log
# `ezgha-runner-alerts` (project worldarchitecture-ai) trips the alert policy that
# texts the operator and posts to Slack. Throttled to one text per COOLDOWN_SEC.
#
# Usage: runner-offline-queued-alert.sh [--dry-run] [--simulate-offline] [--test-sms]
#   --simulate-offline  treat the runner as offline and runs as queued (detector proof)
#   --test-sms          write one clearly labelled TEST entry and exit
# Env: ALERT_REPO ALERT_RUNNER ALERT_WORKFLOW MIN_QUEUED_MIN COOLDOWN_SEC STATE_FILE GH_BIN GCLOUD_BIN
#      MAX_API_FAILURES (consecutive gh failures before a "monitor blind" alert)
set -euo pipefail

REPO="${ALERT_REPO:-jleechanorg/worldai_frontend}"
RUNNER="${ALERT_RUNNER:-worldai-testflight-native-mac}"
MIN_QUEUED_MIN="${MIN_QUEUED_MIN:-10}"
COOLDOWN_SEC="${COOLDOWN_SEC:-1800}"
WORKFLOW="${ALERT_WORKFLOW-iOS TestFlight}" # only runs of this workflow count; empty = all
MAX_API_FAILURES="${MAX_API_FAILURES:-3}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/ezgha/runner_offline_queued_${RUNNER}.json}"
mkdir -p "$(dirname "$STATE_FILE")"
GH_BIN="${GH_BIN:-gh}"
GCLOUD_BIN="${GCLOUD_BIN-$(command -v gcloud || true)}"
DRY_RUN=0 SIMULATE=0 TEST_SMS=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;; --simulate-offline) SIMULATE=1 ;; --test-sms) TEST_SMS=1 ;;
    *) echo "unknown arg: $a" >&2; exit 64 ;;
  esac
done

if [ "$DRY_RUN" -eq 0 ] && [ -z "$GCLOUD_BIN" ]; then
  echo "FATAL: gcloud not found; refusing to run without a working alert path" >&2; exit 3
fi

NOW_EPOCH=$(date +%s); NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

emit() { # severity status message
  local payload
  payload=$(jq -nc --arg s "$2" --arg sev "$1" --arg m "$3" --arg r "$REPO" --arg n "$RUNNER" --arg t "$NOW_ISO" \
    '{source:"runner-offline-queued-alert",status:$s,severity:$sev,message:$m,repo:$r,runner:$n,ts:$t}')
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$NOW_ISO] [dry-run] would write $1 log: $payload"
  else
    "$GCLOUD_BIN" logging write ezgha-runner-alerts "$payload" --payload-type=json \
      --severity="$1" --project=worldarchitecture-ai --account=jleechan@gmail.com >/dev/null
    echo "[$NOW_ISO] wrote $1 entry to ezgha-runner-alerts"
  fi
}

if [ "$TEST_SMS" -eq 1 ]; then
  emit ERROR TEST "TEST ONLY: runner-offline-queued-alert pipeline check for $RUNNER (not a real outage)"
  exit 0
fi

PREV=OK; LAST_SENT=0; API_FAILS=0
if [ -f "$STATE_FILE" ]; then
  PREV=$(jq -r '.status // "OK"' "$STATE_FILE" 2>/dev/null || echo OK)
  LAST_SENT=$(jq -r '.last_sent // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  API_FAILS=$(jq -r '.api_failures // 0' "$STATE_FILE" 2>/dev/null || echo 0)
fi
save() { # status last_sent api_failures
  [ "$DRY_RUN" -eq 1 ] || jq -nc --arg s "$1" --argjson t "$2" --argjson f "$3" '{status:$s,last_sent:$t,api_failures:$f}' > "$STATE_FILE"
}

if [ "$SIMULATE" -eq 1 ]; then
  RUNNER_STATUS=offline; QUEUED=3; OLDEST_MIN=$((MIN_QUEUED_MIN + 5))
elif ! RUNNER_STATUS=$("$GH_BIN" api "repos/$REPO/actions/runners" --paginate \
      --jq ".runners[] | select(.name==\"$RUNNER\") | .status" | head -1) ||
     ! CREATED=$("$GH_BIN" api "repos/$REPO/actions/runs?status=queued&per_page=100" --paginate \
      --jq ".workflow_runs[] | select(\"$WORKFLOW\" == \"\" or .name == \"$WORKFLOW\") | .created_at" | sort); then
  API_FAILS=$((API_FAILS + 1))
  echo "[$NOW_ISO] WARN: gh API failed ($API_FAILS consecutive); no verdict this cycle" >&2
  if [ "$API_FAILS" -ge "$MAX_API_FAILURES" ] && [ $((NOW_EPOCH - LAST_SENT)) -ge "$COOLDOWN_SEC" ]; then
    emit ERROR BLIND "runner monitor cannot reach GitHub for $API_FAILS consecutive checks ($RUNNER in $REPO unverified)"
    LAST_SENT=$NOW_EPOCH
  fi
  save "$PREV" "$LAST_SENT" "$API_FAILS"
  exit 2
else
  [ -n "$RUNNER_STATUS" ] || RUNNER_STATUS=missing
  QUEUED=$(printf '%s' "$CREATED" | grep -c . || true)
  OLDEST_MIN=0
  if [ "$QUEUED" -gt 0 ]; then
    OLDEST=$(printf '%s\n' "$CREATED" | head -1)
    OLDEST_EPOCH=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$OLDEST" +%s 2>/dev/null || date -u -d "$OLDEST" +%s)
    OLDEST_MIN=$(( (NOW_EPOCH - OLDEST_EPOCH) / 60 ))
  fi
fi

if [ "$RUNNER_STATUS" != online ] && [ "$QUEUED" -gt 0 ] && [ "$OLDEST_MIN" -ge "$MIN_QUEUED_MIN" ]; then
  MSG="$RUNNER is $RUNNER_STATUS in $REPO with $QUEUED queued run(s), oldest ${OLDEST_MIN}m"
  echo "[$NOW_ISO] ALERT: $MSG" >&2
  if [ "$PREV" = FAIL ] && [ $((NOW_EPOCH - LAST_SENT)) -lt "$COOLDOWN_SEC" ]; then
    echo "[$NOW_ISO] throttled" >&2; exit 1
  fi
  emit ERROR DOWN "$MSG"
  save FAIL "$NOW_EPOCH" 0
  exit 1
fi

echo "[$NOW_ISO] OK: $RUNNER=$RUNNER_STATUS queued=$QUEUED oldest=${OLDEST_MIN}m"
if [ "$PREV" = FAIL ]; then
  emit INFO RECOVERED "$RUNNER is $RUNNER_STATUS; queue clear or below threshold"
fi
save OK 0 0
