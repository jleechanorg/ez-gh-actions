#!/usr/bin/env bash
# queue-wait-alert.sh — Slack + SMS alert when CI jobs sit queued too long.
#
# Why: doctor-runner measures job-level queue wait (BAD > 20 min) but only when a human runs it,
# so a backed-up queue (2026-11-24: 49 queued jobs, oldest 54 min) paged nobody. This is the
# automatic detector. Normal pickup is seconds (cmux p50 ~3s, jeff-ubuntu p50 ~47s), so 20 min
# is a real backlog, not noise.
#
# Authority: operator instruction 2026-11-24 ("I want queue wait alerts and text alerts, same as
# how other text alerts work through GCP") — this overrides the earlier AGENTS.md rule that kept
# SMS off queue diagnostics. See AGENTS.md "Host-health Slack notifications and SMS scope".
#
# Path: an ERROR entry in Cloud Logging log ezgha-runner-alerts (source=queue-wait-alert)
# increments counter metric queue_wait_alert_count, which drives policy
# "[CRITICAL] ezgha: CI queue backed up" -> Slack channel + SMS channel
# (launchd/queue-wait-alert-policy.json).
#
# Verdict: oldest queued JOB wait (job created_at -> now) across ALERT_REPOS > QUEUE_WAIT_MIN for
# SUSTAIN_CYCLES consecutive runs. Run-level age is not used (concurrency/staged-gate runs sit
# queued for 30+ min while their jobs get runners in seconds). Throttled to one alert per
# COOLDOWN_SEC. An unreadable GitHub API logs WARNING BLIND (never ERROR: blindness must not text).
#
# Usage: queue-wait-alert.sh [--dry-run] [--test-alert] [--ensure-gcp-policy]
#   --test-alert        write one TEST ERROR entry (drives Slack+SMS end to end) and exit
#   --ensure-gcp-policy create/update the log metric and the Slack+SMS policy, then exit
# Env: ALERT_REPOS QUEUE_WAIT_MIN SUSTAIN_CYCLES COOLDOWN_SEC FRESH_HOURS MAX_RUN_CHECKS STATE_FILE
#      GH_BIN GCLOUD_BIN MAX_API_FAILURES GCP_ACCOUNT QUEUE_WAIT_SIMULATE_MIN (detector proof, skips the API)
set -euo pipefail

ALERT_REPOS="${ALERT_REPOS:-jleechanorg/worldarchitect.ai jleechanorg/ez-gh-actions}"
QUEUE_WAIT_MIN="${QUEUE_WAIT_MIN:-20}"
SUSTAIN_CYCLES="${SUSTAIN_CYCLES:-2}"
COOLDOWN_SEC="${COOLDOWN_SEC:-1800}"
FRESH_HOURS="${FRESH_HOURS:-8}"
MAX_RUN_CHECKS="${MAX_RUN_CHECKS:-40}"
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
    '{source:"queue-wait-alert",status:$s,severity:$sev,message:$m,oldest_wait_min:$w,queued_jobs:$q,repo:$r,ts:$t}')
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$NOW_ISO] [dry-run] would write $1 log: $payload"
  else
    "$GCLOUD_BIN" logging write ezgha-runner-alerts "$payload" --payload-type=json \
      --severity="$1" "${GCP_ARGS[@]}" >/dev/null
    echo "[$NOW_ISO] wrote $1 entry to ezgha-runner-alerts"
  fi
}

if [ "$TEST_ALERT" -eq 1 ]; then
  emit ERROR TEST "TEST ONLY: queue-wait-alert pipeline check (not a real backlog)" 0 0 ""
  exit 0
fi

BREACHES=0; LAST_SENT=0; API_FAILS=0; LAST_BLIND=0
if [ -f "$STATE_FILE" ]; then
  BREACHES=$(jq -r '.breaches // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  LAST_SENT=$(jq -r '.last_sent // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  API_FAILS=$(jq -r '.api_failures // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  LAST_BLIND=$(jq -r '.last_blind // 0' "$STATE_FILE" 2>/dev/null || echo 0)
fi
save() { # breaches last_sent api_failures last_blind
  [ "$DRY_RUN" -eq 1 ] || jq -nc --argjson b "$1" --argjson t "$2" --argjson f "$3" --argjson l "$4" \
    '{breaches:$b,last_sent:$t,api_failures:$f,last_blind:$l}' > "$STATE_FILE"
}

# Oldest queued JOB wait (minutes) and queued-job count across ALERT_REPOS; sets OLDEST_MIN QUEUED_JOBS WORST_REPO.
measure() {
  OLDEST_MIN=0; QUEUED_JOBS=0; WORST_REPO=""
  if [ -n "$SIMULATE_MIN" ]; then OLDEST_MIN="$SIMULATE_MIN"; QUEUED_JOBS=1; WORST_REPO=simulated; return 0; fi
  local cutoff repo ids id created c epoch wait
  cutoff=$((NOW_EPOCH - FRESH_HOURS * 3600))
  for repo in $ALERT_REPOS; do
    ids=$("$GH_BIN" api "repos/$repo/actions/runs?status=queued&per_page=100" \
      --jq ".workflow_runs[] | select((.created_at|fromdateiso8601) > $cutoff) | [.created_at,.id] | @tsv" | sort | head -n "$MAX_RUN_CHECKS" | cut -f2) || return 1
    for id in $ids; do
      created=$("$GH_BIN" api "repos/$repo/actions/runs/$id/jobs?per_page=100" \
        --jq '.jobs[] | select(.status=="queued") | .created_at') || return 1
      for c in $created; do
        QUEUED_JOBS=$((QUEUED_JOBS + 1))
        epoch=$(jq -nr --arg c "$c" '$c|fromdateiso8601')
        wait=$(( (NOW_EPOCH - epoch) / 60 ))
        if [ "$wait" -gt "$OLDEST_MIN" ]; then OLDEST_MIN=$wait; WORST_REPO=$repo; fi
      done
    done
  done
}

if ! measure; then
  API_FAILS=$((API_FAILS + 1))
  echo "[$NOW_ISO] WARN: gh API failed ($API_FAILS consecutive); no verdict this cycle" >&2
  if [ "$API_FAILS" -ge "$MAX_API_FAILURES" ] && [ $((NOW_EPOCH - LAST_BLIND)) -ge "$COOLDOWN_SEC" ]; then
    emit WARNING BLIND "queue-wait monitor cannot reach GitHub ($API_FAILS consecutive failures); no queue verdict" 0 0 ""
    LAST_BLIND=$NOW_EPOCH
  fi
  save "$BREACHES" "$LAST_SENT" "$API_FAILS" "$LAST_BLIND"
  exit 0
fi

if [ "$OLDEST_MIN" -gt "$QUEUE_WAIT_MIN" ]; then
  BREACHES=$((BREACHES + 1))
  echo "[$NOW_ISO] queue breach $BREACHES/$SUSTAIN_CYCLES: oldest job wait ${OLDEST_MIN}m > ${QUEUE_WAIT_MIN}m ($QUEUED_JOBS queued job(s), $WORST_REPO)"
  if [ "$BREACHES" -ge "$SUSTAIN_CYCLES" ] && [ $((NOW_EPOCH - LAST_SENT)) -ge "$COOLDOWN_SEC" ]; then
    emit ERROR QUEUE_BACKED_UP "CI queue backed up: oldest queued job has waited ${OLDEST_MIN}m (threshold ${QUEUE_WAIT_MIN}m), ${QUEUED_JOBS} job(s) queued, worst repo ${WORST_REPO}" "$OLDEST_MIN" "$QUEUED_JOBS" "$WORST_REPO"
    LAST_SENT=$NOW_EPOCH
  fi
else
  echo "[$NOW_ISO] queue ok: oldest job wait ${OLDEST_MIN}m <= ${QUEUE_WAIT_MIN}m ($QUEUED_JOBS queued job(s))"
  BREACHES=0
fi
save "$BREACHES" "$LAST_SENT" 0 "$LAST_BLIND"
