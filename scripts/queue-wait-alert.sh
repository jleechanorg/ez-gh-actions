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
# Why not reuse an existing probe: queue_probe.py does compute per-job waits but only for queued runs
# (not in-progress runs that still hold queued jobs), has no parked-leg filter, and is built for the
# public dashboard snapshot, so it is not coupled to a paging path here. queue-health.sh/doctor-runner
# only run under a human-run doctor and never alert; runner-offline-queued-alert.sh watches one named
# runner. The paging loop (~35 lines) and the parked-leg jq (copied from doctor-runner) are the cost.
#
# Parked legs: like doctor-runner, jobs aimed at an intentionally parked leg (MAC_RUNNER_DISABLED=1 /
# REMOTE_LINUX_DISABLED=1) cannot be served by design and are excluded, so they never text. The opt-out
# is never inferred; the cron installer sets MAC_RUNNER_DISABLED=1 while the Mac fleet is parked
# (AGENTS.md, bead jleechan-hxz0). Candidate runs are the first 100 queued and in-progress runs created within
# FRESH_HOURS (doctor's fresh window; older queued runs are ghost zombies with no jobs) and at most
# MAX_RUN_CHECKS runs are inspected within MAX_RUN_SEC; hitting either bound logs WARNING TRUNCATED (never texts).
# An unreadable cycle (GitHub API failure) neither counts as a breach nor resets the breach count; three in a
# row log WARNING BLIND. A missing gcloud is fatal on a real run (exit 3) so a broken alert path is never silent.
#
# Usage: queue-wait-alert.sh [--dry-run] [--test-alert] [--ensure-gcp-policy]
#   --test-alert        write one TEST ERROR entry (drives Slack+SMS end to end) and exit
#   --ensure-gcp-policy create/update the log metric and the Slack+SMS policy, then exit
# Env: ALERT_REPOS QUEUE_WAIT_MIN SUSTAIN_CYCLES COOLDOWN_SEC FRESH_HOURS MAX_RUN_CHECKS STATE_FILE
#      GH_BIN GCLOUD_BIN MAX_API_FAILURES GH_CALL_TIMEOUT_SEC MAC_RUNNER_DISABLED REMOTE_LINUX_DISABLED GCP_ACCOUNT QUEUE_WAIT_SIMULATE_MIN (detector proof, skips the API)
set -euo pipefail

ALERT_REPOS="${ALERT_REPOS:-jleechanorg/worldarchitect.ai jleechanorg/ez-gh-actions}"
QUEUE_WAIT_MIN="${QUEUE_WAIT_MIN:-20}"
SUSTAIN_CYCLES="${SUSTAIN_CYCLES:-2}"
COOLDOWN_SEC="${COOLDOWN_SEC:-1800}"
FRESH_HOURS="${FRESH_HOURS:-8}"
MAX_RUN_CHECKS="${MAX_RUN_CHECKS:-60}"
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
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return; fi
  local p w rc # no coreutils timeout (macOS): kill the call from a watchdog
  "$@" & p=$!
  ( sleep "$secs"; kill "$p" 2>/dev/null; sleep 2; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$p"; rc=$?
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
    '{source:"queue-wait-alert",status:$s,severity:$sev,message:$m,oldest_wait_min:$w,queued_jobs:$q,repo:$r,ts:$t}')
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$NOW_ISO] [dry-run] would write $1 log: $payload"
  else
    bounded "$GCLOUD_CALL_TIMEOUT_SEC" "$GCLOUD_BIN" logging write ezgha-runner-alerts "$payload" --payload-type=json \
      --severity="$1" "${GCP_ARGS[@]}" >/dev/null
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
BREACHES=0; LAST_SENT=0; API_FAILS=0; LAST_BLIND=0
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; } # corrupt state must not abort the run
if [ -f "$STATE_FILE" ]; then
  BREACHES=$(num "$(jq -r '.breaches // 0' "$STATE_FILE" 2>/dev/null || true)")
  LAST_SENT=$(num "$(jq -r '.last_sent // 0' "$STATE_FILE" 2>/dev/null || true)")
  API_FAILS=$(num "$(jq -r '.api_failures // 0' "$STATE_FILE" 2>/dev/null || true)")
  LAST_BLIND=$(num "$(jq -r '.last_blind // 0' "$STATE_FILE" 2>/dev/null || true)")
fi
save() { # breaches last_sent api_failures last_blind
  [ "$DRY_RUN" -eq 1 ] && return 0
  jq -nc --argjson b "$1" --argjson t "$2" --argjson f "$3" --argjson l "$4" \
    '{breaches:$b,last_sent:$t,api_failures:$f,last_blind:$l}' > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"
}
# Same parked-leg rule as doctor-runner (_PARKED_LEG_JQ): generic/empty labels are never excluded.
PARKED_JQ='def is_parked_leg($mac_off; $linux_off):
  ((.labels // []) | map(tostring | ascii_downcase)) as $l
  | (($mac_off == "1" and ($l | any(. == "self-hosted-macos" or . == "macos" or . == "ez-mac-runner" or startswith("ez-mac-runner-"))))
     or ($linux_off == "1" and ($l | any(. == "self-hosted-linux" or . == "linux" or . == "ez-runner-c" or startswith("ez-runner-c-")))));
'

# Oldest queued JOB wait (minutes) and count across ALERT_REPOS, parked-leg jobs excluded;
# sets OLDEST_MIN QUEUED_JOBS EXCLUDED WORST_REPO TRUNCATED.
measure() {
  OLDEST_MIN=0; QUEUED_JOBS=0; EXCLUDED=0; WORST_REPO=""; TRUNCATED=0
  if [ -n "$SIMULATE_MIN" ]; then OLDEST_MIN="$SIMULATE_MIN"; QUEUED_JOBS=1; WORST_REPO=simulated; return 0; fi
  local cutoff repo st runs_json ids id jobs_json waits w checked=0
  cutoff=$((NOW_EPOCH - FRESH_HOURS * 3600))
  for repo in $ALERT_REPOS; do
   # queued runs, plus in_progress runs (a partly running run can still hold queued jobs, as doctor-runner sweeps)
   for st in queued in_progress; do
    runs_json=$(gh_call api "repos/$repo/actions/runs?status=$st&per_page=100") || return 1
    ids=$(printf '%s' "$runs_json" | jq -r --argjson cut "$cutoff" \
      '[.workflow_runs[]? | select((.created_at|fromdateiso8601) > $cut)] | sort_by(.created_at) | .[].id') || return 1
    for id in $ids; do
      if [ "$checked" -ge "$MAX_RUN_CHECKS" ] || [ $(( $(date +%s) - NOW_EPOCH )) -ge "$MAX_RUN_SEC" ]; then TRUNCATED=1; break; fi
      checked=$((checked + 1))
      jobs_json=$(gh_call api --paginate "repos/$repo/actions/runs/$id/jobs?per_page=100") || return 1
      waits=$(printf '%s' "$jobs_json" | jq -r --argjson now "$NOW_EPOCH" --arg mac_off "$MAC_OFF" --arg linux_off "$LINUX_OFF" \
        "$PARKED_JQ"'.jobs[]? | select(.status=="queued") | if is_parked_leg($mac_off; $linux_off) then "X" else ((($now - (.created_at|fromdateiso8601)) / 60) | floor | tostring) end') || return 1
      for w in $waits; do
        if [ "$w" = X ]; then EXCLUDED=$((EXCLUDED + 1)); continue; fi
        QUEUED_JOBS=$((QUEUED_JOBS + 1))
        if [ "$w" -gt "$OLDEST_MIN" ]; then OLDEST_MIN=$w; WORST_REPO=$repo; fi
      done
    done
    [ "$TRUNCATED" -eq 0 ] || break
   done
   [ "$TRUNCATED" -eq 0 ] || break
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

if [ "$TRUNCATED" -eq 1 ] && [ $((NOW_EPOCH - LAST_BLIND)) -ge "$COOLDOWN_SEC" ]; then
  emit WARNING TRUNCATED "queue-wait monitor hit its $MAX_RUN_CHECKS-run inspection cap; the oldest job may be outside the sample" 0 0 ""
  LAST_BLIND=$NOW_EPOCH
fi
[ "$EXCLUDED" -eq 0 ] || echo "[$NOW_ISO] excluded $EXCLUDED queued job(s) aimed at a parked leg"
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
