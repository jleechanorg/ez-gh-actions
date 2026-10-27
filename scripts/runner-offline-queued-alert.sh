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
# Env: ALERT_REPO ALERT_RUNNER MIN_QUEUED_MIN COOLDOWN_SEC STATE_FILE GH_BIN GCLOUD_BIN
set -euo pipefail

REPO="${ALERT_REPO:-jleechanorg/worldai_frontend}"
RUNNER="${ALERT_RUNNER:-worldai-testflight-native-mac}"
MIN_QUEUED_MIN="${MIN_QUEUED_MIN:-10}"
COOLDOWN_SEC="${COOLDOWN_SEC:-1800}"
STATE_FILE="${STATE_FILE:-/tmp/ezgha_runner_offline_queued_${RUNNER}.json}"
GH_BIN="${GH_BIN:-gh}"
GCLOUD_BIN="${GCLOUD_BIN:-$(command -v gcloud || true)}"
DRY_RUN=0 SIMULATE=0 TEST_SMS=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;; --simulate-offline) SIMULATE=1 ;; --test-sms) TEST_SMS=1 ;;
    *) echo "unknown arg: $a" >&2; exit 64 ;;
  esac
done

NOW_EPOCH=$(date +%s); NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

emit() { # severity status message
  local payload
  payload=$(jq -nc --arg s "$2" --arg sev "$1" --arg m "$3" --arg r "$REPO" --arg n "$RUNNER" --arg t "$NOW_ISO" \
    '{source:"runner-offline-queued-alert",status:$s,severity:$sev,message:$m,repo:$r,runner:$n,ts:$t}')
  if [ "$DRY_RUN" -eq 1 ] || [ -z "$GCLOUD_BIN" ]; then
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

if [ "$SIMULATE" -eq 1 ]; then
  RUNNER_STATUS=offline; QUEUED=3; OLDEST_MIN=$((MIN_QUEUED_MIN + 5))
else
  RUNNER_STATUS=$("$GH_BIN" api "repos/$REPO/actions/runners" --paginate \
    --jq ".runners[] | select(.name==\"$RUNNER\") | .status" | head -1)
  [ -n "$RUNNER_STATUS" ] || RUNNER_STATUS=missing
  CREATED=$("$GH_BIN" api "repos/$REPO/actions/runs?status=queued&per_page=100" \
    --jq '[.workflow_runs[].created_at] | sort | .[]')
  QUEUED=$(printf '%s' "$CREATED" | grep -c . || true)
  OLDEST_MIN=0
  if [ "$QUEUED" -gt 0 ]; then
    OLDEST=$(printf '%s\n' "$CREATED" | head -1)
    OLDEST_EPOCH=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$OLDEST" +%s 2>/dev/null || date -u -d "$OLDEST" +%s)
    OLDEST_MIN=$(( (NOW_EPOCH - OLDEST_EPOCH) / 60 ))
  fi
fi

PREV=OK; LAST_SENT=0
if [ -f "$STATE_FILE" ]; then
  PREV=$(jq -r '.status // "OK"' "$STATE_FILE" 2>/dev/null || echo OK)
  LAST_SENT=$(jq -r '.last_sent // 0' "$STATE_FILE" 2>/dev/null || echo 0)
fi

if [ "$RUNNER_STATUS" != online ] && [ "$QUEUED" -gt 0 ] && [ "$OLDEST_MIN" -ge "$MIN_QUEUED_MIN" ]; then
  MSG="$RUNNER is $RUNNER_STATUS in $REPO with $QUEUED queued run(s), oldest ${OLDEST_MIN}m"
  echo "[$NOW_ISO] ALERT: $MSG" >&2
  if [ "$PREV" = FAIL ] && [ $((NOW_EPOCH - LAST_SENT)) -lt "$COOLDOWN_SEC" ]; then
    echo "[$NOW_ISO] throttled" >&2; exit 1
  fi
  emit ERROR DOWN "$MSG"
  [ "$DRY_RUN" -eq 1 ] || jq -nc --argjson t "$NOW_EPOCH" '{status:"FAIL",last_sent:$t}' > "$STATE_FILE"
  exit 1
fi

echo "[$NOW_ISO] OK: $RUNNER=$RUNNER_STATUS queued=$QUEUED oldest=${OLDEST_MIN}m"
if [ "$PREV" = FAIL ]; then
  emit INFO RECOVERED "$RUNNER is $RUNNER_STATUS; queue clear or below threshold"
fi
[ "$DRY_RUN" -eq 1 ] || jq -nc '{status:"OK",last_sent:0}' > "$STATE_FILE"
