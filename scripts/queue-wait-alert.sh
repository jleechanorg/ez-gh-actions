#!/usr/bin/env bash
# queue-wait-alert.sh — Slack + SMS alert when CI jobs sit queued too long.
#
# Discovers queued self-hosted jobs, not workflow age or running duration.
# Discovery must finish with complete counts before a queue verdict is allowed.
# WARNING BLIND/TRUNCATED and INFO HEARTBEAT never match the paging metric.
# ERROR QUEUE_BACKED_UP and explicit --test-alert retain the existing transport.
# This script does not grant merge, deployment or notification authority.
# Usage: queue-wait-alert.sh [--dry-run] [--test-alert] [--ensure-gcp-policy]
# Dependencies: bash, python3, jq, gh, and gcloud for non-dry notification runs.
set -euo pipefail

ALERT_REPOS="${ALERT_REPOS:-jleechanorg/worldarchitect.ai jleechanorg/worldai_frontend jleechanorg/ez-gh-actions}"
QUEUE_WAIT_MIN="${QUEUE_WAIT_MIN:-20}"
SUSTAIN_CYCLES="${SUSTAIN_CYCLES:-2}"
COOLDOWN_SEC="${COOLDOWN_SEC:-1800}"
MAX_RUN_CHECKS="${MAX_RUN_CHECKS:-60}"
MAX_API_CALLS="${MAX_API_CALLS:-200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_CALL_TIMEOUT_SEC="${GH_CALL_TIMEOUT_SEC:-30}"
GCLOUD_CALL_TIMEOUT_SEC="${GCLOUD_CALL_TIMEOUT_SEC:-60}"
MAX_RUN_SEC="${MAX_RUN_SEC:-240}" # whole-run deadline; must stay well under the 15 min stale-lock age
MAC_OFF="${MAC_RUNNER_DISABLED:-0}"
LINUX_OFF="${REMOTE_LINUX_DISABLED:-0}"
MAX_API_FAILURES="${MAX_API_FAILURES:-3}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/ezgha/queue_wait_alert.json}"
GH_BIN="${GH_BIN:-gh}"
GCLOUD_BIN="${GCLOUD_BIN-$(command -v gcloud || true)}"
PROJECT=worldarchitecture-ai
SIMULATE_MIN="${QUEUE_WAIT_SIMULATE_MIN:-}"

if [ -z "${GH_TOKEN:-}" ] && [ -r "$HOME/.config/ezgha/gh_token" ]; then
  GH_TOKEN=$(cat "$HOME/.config/ezgha/gh_token" 2>/dev/null || true)
  [ -n "$GH_TOKEN" ] && export GH_TOKEN
fi

DRY_RUN=0 TEST_ALERT=0 ENSURE_POLICY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;; --test-alert) TEST_ALERT=1 ;; --ensure-gcp-policy) ENSURE_POLICY=1 ;;
    *) echo "unknown arg: $a" >&2; exit 64 ;;
  esac
done
if [ "$DRY_RUN" -eq 0 ] && [ -z "$GCLOUD_BIN" ]; then
  echo "FATAL: gcloud not found; refusing to run without a working alert path" >&2; exit 3
fi
mkdir -p "$(dirname "$STATE_FILE")"
NOW_EPOCH=$(date +%s); NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GCP_ARGS=(--project="$PROJECT")
[ -z "${GCP_ACCOUNT:-}" ] || GCP_ARGS+=(--account="$GCP_ACCOUNT")

bounded() { # bounded <seconds> cmd...: a hung gh/gcloud must not stack cron runs on the fleet host
  local secs="$1"; shift
  if [ -z "${QUEUE_WAIT_FORCE_WATCHDOG:-}" ] && command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return; fi
  local p w rc # no coreutils timeout (macOS): kill the call from a watchdog
  "$@" & p=$!
  ( sleep "$secs"; kill "$p" 2>/dev/null; sleep 2; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  rc=0; wait "$p" || rc=$? # never let a killed child's status trip set -e
  kill "$w" 2>/dev/null || true; wait "$w" 2>/dev/null || true
  return "$rc"
}
gh_call() { bounded "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" "$@"; }

if [ "$ENSURE_POLICY" -eq 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  POLICY_FILE="${POLICY_FILE:-$SCRIPT_DIR/../launchd/queue-wait-alert-policy.json}"
  [ -f "$POLICY_FILE" ] || { echo "FATAL: policy file not found: $POLICY_FILE" >&2; exit 4; }
  [ "$DRY_RUN" -eq 0 ] || { echo "[$NOW_ISO] [dry-run] would ensure metric queue_wait_alert_count and policy from $POLICY_FILE"; exit 0; }
  METRIC_ARGS=(queue_wait_alert_count --description="ERROR entries for a backed-up CI queue (drives Slack+SMS policy)"
    --log-filter='logName="projects/worldarchitecture-ai/logs/ezgha-runner-alerts" AND jsonPayload.source="queue-wait-alert" AND severity>=ERROR AND (jsonPayload.status="QUEUE_BACKED_UP" OR jsonPayload.status="TEST")'
    "${GCP_ARGS[@]}")
  "$GCLOUD_BIN" logging metrics create "${METRIC_ARGS[@]}" 2>/dev/null || "$GCLOUD_BIN" logging metrics update "${METRIC_ARGS[@]}"
  POLICY_NAME="$(jq -r '.displayName' "$POLICY_FILE")"
  EXISTING=$("$GCLOUD_BIN" alpha monitoring policies list "${GCP_ARGS[@]}" --filter="displayName=\"${POLICY_NAME}\"" --format='value(name)' | head -1)
  if [ -n "$EXISTING" ]; then
    "$GCLOUD_BIN" alpha monitoring policies update "$EXISTING" --policy-from-file="$POLICY_FILE" "${GCP_ARGS[@]}"
  else
    "$GCLOUD_BIN" alpha monitoring policies create --policy-from-file="$POLICY_FILE" "${GCP_ARGS[@]}"
  fi
  exit 0
fi

emit() { # severity status message oldest_min queued_jobs repo
  local payload
  payload=$(jq -nc --arg s "$2" --arg sev "$1" --arg m "$3" --arg t "$NOW_ISO" \
    --argjson w "${4:-0}" --argjson q "${5:-0}" --arg r "${6:-}" \
    --argjson evidence "${ALERT_EVIDENCE:-[]}" \
    '{source:"queue-wait-alert",status:$s,severity:$sev,message:$m,oldest_wait_min:$w,queued_jobs:$q,repo:$r,ts:$t,jobs:$evidence}')
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$NOW_ISO] [dry-run] would write $1 log: $payload"
  else
    # A failed or timed-out write returns 1 and aborts the run before save(), so LAST_SENT is not advanced and the next run retries.
    if ! bounded "$GCLOUD_CALL_TIMEOUT_SEC" "$GCLOUD_BIN" logging write ezgha-runner-alerts "$payload" --payload-type=json \
        --severity="$1" "${GCP_ARGS[@]}" >/dev/null; then
      echo "[$NOW_ISO] ERROR: gcloud logging write failed or timed out; alert not recorded, will retry next run" >&2
      return 1
    fi
    echo "[$NOW_ISO] wrote $1 entry to ezgha-runner-alerts"
  fi
}

if [ "$TEST_ALERT" -eq 1 ]; then
  emit ERROR TEST "TEST ONLY: queue-wait-alert pipeline check (not a real backlog)" 0 0 ""
  exit 0
fi

# One run at a time: an overlapping cron run would race on the state file and double-alert.
# Portable mkdir lock (atomic everywhere, no flock needed); a lock older than 15 min is a crashed run's (a live run is bounded by MAX_RUN_SEC + gcloud timeout, about 5 min).
LOCKDIR="$STATE_FILE.lockdir"
if [ "$DRY_RUN" -eq 0 ]; then
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      rmdir "$LOCKDIR" 2>/dev/null || true
      mkdir "$LOCKDIR" 2>/dev/null || { echo "[$NOW_ISO] lost the stale-lock race; skipping"; exit 0; }
    else
      echo "[$NOW_ISO] another queue-wait-alert run holds the lock; skipping"; exit 0
    fi
  fi
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
fi
# Preserve the prior state schema for upgrades; new per-job state is separate.
BREACHES=0; LAST_SENT=0; API_FAILS=0; LAST_BLIND=0
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
STATE='{"last_sent":0}'
if [ -f "$STATE_FILE" ]; then
  STATE=$(jq -ce 'if type=="object" then . else {} end' "$STATE_FILE" 2>/dev/null || echo '{}')
fi
BREACHES=$(num "$(printf '%s' "$STATE" | jq -r '.breaches // 0')")
LAST_SENT=$(num "$(printf '%s' "$STATE" | jq -r '.last_sent // 0')")
API_FAILS=$(num "$(printf '%s' "$STATE" | jq -r '.api_failures // 0')")
LAST_BLIND=$(num "$(printf '%s' "$STATE" | jq -r '.last_blind // 0')")
save() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  printf '%s\n' "$STATE" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"
}
heartbeat() { # Durable local proof exists even when the remote logging path is down.
  local status="$1" delivered="$2" reason="$3" hb
  hb=$(jq -nc --arg t "$NOW_ISO" --arg s "$status" --arg d "$delivered" --arg r "$reason" \
    --argjson complete "$COMPLETE" '{ts:$t,status:$s,complete:$complete,delivery:$d,reason:$r}')
  if [ "$DRY_RUN" -eq 1 ]; then echo "[$NOW_ISO] [dry-run] HEARTBEAT $hb"; return; fi
  printf '%s\n' "$hb" > "$STATE_FILE.heartbeat.tmp.$$" && mv "$STATE_FILE.heartbeat.tmp.$$" "$STATE_FILE.heartbeat.json"
}
COMPLETE=false
SCAN='{}'
if [ -n "$SIMULATE_MIN" ]; then
  SCAN=$(jq -nc --argjson w "$SIMULATE_MIN" '{complete:true,excluded:0,jobs:[{key:"simulated:1",id:1,repo:"simulated",wait_min:$w,status:"queued",html_url:"simulated"}]}')
else
  SCAN=$(ALERT_REPOS="$ALERT_REPOS" MAX_RUN_CHECKS="$MAX_RUN_CHECKS" MAX_API_CALLS="$MAX_API_CALLS" \
    MAX_RUN_SEC="$MAX_RUN_SEC" GH_BIN="$GH_BIN" GH_CALL_TIMEOUT_SEC="$GH_CALL_TIMEOUT_SEC" \
    MAC_RUNNER_DISABLED="$MAC_OFF" REMOTE_LINUX_DISABLED="$LINUX_OFF" QUEUE_NOW_EPOCH="$NOW_EPOCH" \
    python3 "$SCRIPT_DIR/queue_wait_discovery.py") || true
fi
if ! printf '%s' "$SCAN" | jq -e '.complete == true and (.jobs|type)=="array"' >/dev/null 2>&1; then
  API_FAILS=$((API_FAILS + 1))
  REASON=$(printf '%s' "$SCAN" | jq -r '.reason // "discovery failed"' 2>/dev/null || echo 'discovery failed')
  STATUS=BLIND; case "$REASON" in *OverflowError*) STATUS=TRUNCATED ;; esac
  echo "[$NOW_ISO] WARN $STATUS: $REASON; no verdict this cycle" >&2
  STATE=$(printf '%s' "$STATE" | jq -c --argjson f "$API_FAILS" '.api_failures=$f')
  save
  heartbeat "$STATUS" unknown "$REASON"
  if { [ "$STATUS" = TRUNCATED ] || [ "$API_FAILS" -ge "$MAX_API_FAILURES" ]; } && [ $((NOW_EPOCH - LAST_BLIND)) -ge "$COOLDOWN_SEC" ]; then
    if emit WARNING "$STATUS" "queue discovery incomplete: $REASON; no queue verdict" 0 0 ""; then
      STATE=$(printf '%s' "$STATE" | jq -c --argjson t "$NOW_EPOCH" '.last_blind=$t'); save
    else heartbeat "$STATUS" failed "$REASON; logging write failed"; exit 1; fi
  fi
  exit 0
fi
COMPLETE=true
QUEUED_JOBS=$(printf '%s' "$SCAN" | jq '.jobs|length')
OLDEST_MIN=$(printf '%s' "$SCAN" | jq '.jobs[0].wait_min // 0')
WORST_REPO=$(printf '%s' "$SCAN" | jq -r '.jobs[0].repo // ""')
EXCLUDED=$(printf '%s' "$SCAN" | jq '.excluded // 0')
[ "$EXCLUDED" -eq 0 ] || echo "[$NOW_ISO] excluded $EXCLUDED queued job(s) aimed at a parked leg or GitHub-hosted runner"
# Only complete cycles update per-job observations. Partial cycles neither recover
# a backlog nor invent a second sample. A complete absent/below-threshold job resets.
NEXT=$(jq -nc --argjson old "$STATE" --argjson scan "$SCAN" --argjson threshold "$QUEUE_WAIT_MIN" '
  reduce ($scan.jobs[] | select(.wait_min > $threshold)) as $j
    ({}; .[$j.key] = {cycles:((($old.jobs[$j.key].cycles // 0)|if type=="number" then . else 0 end)+1),
      last_sent:($old.jobs[$j.key].last_sent // 0),created_at:$j.created_at})')
ALERT_EVIDENCE=$(jq -nc --argjson jobs "$(printf '%s' "$SCAN" | jq '.jobs')" --argjson state "$NEXT" \
  --argjson sustain "$SUSTAIN_CYCLES" --argjson now "$NOW_EPOCH" --argjson cooldown "$COOLDOWN_SEC" '
  [$jobs[] | select($state[.key].cycles >= $sustain) | select(($now - ($state[.key].last_sent // 0)) >= $cooldown)]')
BREACHES=$(printf '%s' "$NEXT" | jq '[.[].cycles]|max // 0')
if [ "$OLDEST_MIN" -gt "$QUEUE_WAIT_MIN" ]; then
  echo "[$NOW_ISO] queue breach $BREACHES/$SUSTAIN_CYCLES: oldest job wait ${OLDEST_MIN}m > ${QUEUE_WAIT_MIN}m ($QUEUED_JOBS queued job(s), $WORST_REPO)"
else
  echo "[$NOW_ISO] queue ok: oldest job wait ${OLDEST_MIN}m <= ${QUEUE_WAIT_MIN}m ($QUEUED_JOBS queued job(s))"
fi
# Save observations before delivery so a failed write retries without losing sustain.
STATE=$(printf '%s' "$STATE" | jq -c --argjson jobs "$NEXT" --argjson b "$BREACHES" '.last_sent=(.last_sent // 0)|.jobs=$jobs|.breaches=$b|.api_failures=0')
save
heartbeat COMPLETE pending ''
if [ "$(printf '%s' "$ALERT_EVIDENCE" | jq length)" -gt 0 ]; then
  if ! emit ERROR QUEUE_BACKED_UP "CI queue backed up: verified queued self-hosted jobs exceed ${QUEUE_WAIT_MIN}m; see job evidence" "$OLDEST_MIN" "$QUEUED_JOBS" "$WORST_REPO"; then
    heartbeat BLIND failed 'alert not recorded, will retry next run'; exit 1
  fi
  STATE=$(printf '%s' "$STATE" | jq -c --argjson evidence "$ALERT_EVIDENCE" --argjson t "$NOW_EPOCH" '
    .last_sent=$t | reduce $evidence[] as $j (. ; .jobs[$j.key].last_sent=$t)')
  save
fi
ALERT_EVIDENCE='[]'
if emit INFO HEARTBEAT "complete queue observation; $QUEUED_JOBS queued self-hosted jobs, $EXCLUDED excluded" "$OLDEST_MIN" "$QUEUED_JOBS" "$WORST_REPO"; then
  heartbeat COMPLETE ok ''
else heartbeat BLIND failed 'heartbeat logging write failed'; exit 1; fi
