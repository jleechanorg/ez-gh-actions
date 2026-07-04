#!/usr/bin/env bash
# doctor.sh — ez-gh-actions fleet health check. Read-only.
# Outputs a one-shot human-readable report; --json emits machine-parseable
# status for the loop agent (or a follow-up Claude Code session) to drive
# iteration. Designed to fail loudly on the things that previously caused
# silent fleet decay (slot-file desync, missing daemons, container/reg drift).
set -euo pipefail

# --- arg parsing ---------------------------------------------------------
JSON=0
DETAIL=0
PROVE=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --detail|-v|--verbose) DETAIL=1 ;;
    --prove) PROVE=1 ;;   # dispatch a live canary job and verify it runs on our fleet
    -h|--help)
      echo "usage: doctor.sh [--prove] [--detail]"
      echo "  --prove   dispatch a live ezgha-selftest and verify it runs on ez-org-runner-* (adds ~1-2 min)"
      echo "  --detail  verbose output"
      echo "env: LOOP_WINDOW (min, default 3), ROUTING_N (runs, default 6), ORG, EZGHA_REPO"
      exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ORG="${ORG:-jleechanorg}"
EZGHA_REPO="${EZGHA_REPO:-jleechanorg/ez-gh-actions}"

# --- helpers -------------------------------------------------------------
section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
bad() { printf '  [BAD]  %s\n' "$*"; }
info() { printf '  [..]   %s\n' "$*"; }

# --- A. local daemon + service ------------------------------------------
section "1. ezgha service"
SERVICE_STATE=$(systemctl --user is-active ezgha.service 2>&1 || true)
case "$SERVICE_STATE" in
  active)   ok "ezgha.service = active" ;;
  *)        bad "ezgha.service = $SERVICE_STATE (expected active)" ;;
esac
SYSTEMD_ENABLED=$(systemctl --user is-enabled ezgha.service 2>&1 || true)
info "ezgha.service enabled=$SYSTEMD_ENABLED"

section "2. docker daemon"
if DOCKER_INFO=$(docker info --format '{{.ServerVersion}} {{.NCPU}} {{.MemTotal}}' 2>&1); then
  ok "docker daemon reachable (version/cpu/mem: $DOCKER_INFO)"
else
  bad "docker daemon unreachable: $DOCKER_INFO"
fi

section "3. colima VM (the daemon's host)"
if command -v limactl >/dev/null 2>&1; then
  COLIMA_STATUS=$(limactl list 2>/dev/null | awk 'NR==2 {print $2}')
  case "$COLIMA_STATUS" in
    Running) ok "colima VM running" ;;
    Stopped) bad "colima VM stopped — docker daemon is unreachable; start with: limactl start colima" ;;
    *)       warn "colima VM status: ${COLIMA_STATUS:-unknown}" ;;
  esac
else
  info "limactl not installed (this host uses Docker Desktop or a remote daemon)"
fi

# --- B. ezgha runtime state ---------------------------------------------
section "4. ezgha runtime state"
SERVICE_RSS=$(ps -o rss= -p $(pgrep -f '^target/release/ezgha' 2>/dev/null | head -1) 2>/dev/null || echo "?")
info "binary PID RSS=${SERVICE_RSS} KB"
# Count ensure_count failures in a TIME window, not a line window. ezgha logs
# roughly one line per 30s, so `-n 200` spans ~100 minutes and keeps stale
# errors from a since-recovered incident red long after the fleet is healthy.
# Health means CURRENT health: only the last LOOP_WINDOW minutes count.
LOOP_WINDOW="${LOOP_WINDOW:-3}"
LOOP_FAILS=$(journalctl --user -u ezgha.service --since "${LOOP_WINDOW} minutes ago" --no-pager 2>/dev/null | grep -c 'ensure_count failed' || true)
LAST_LOOP=$(journalctl --user -u ezgha.service --no-pager -n 1 2>/dev/null | sed -n '1p' | cut -c1-40 || true)
info "ensure_count failed occurrences in last ${LOOP_WINDOW} min: $LOOP_FAILS"
info "most recent journal line: $LAST_LOOP"
SLOT_FILE="$HOME/.config/ezgha/slot_assignments.toml"
if [ -f "$SLOT_FILE" ]; then
  ASSIGNED=$(grep -c '=' "$SLOT_FILE" 2>/dev/null || echo 0)
  ok "slot_assignments.toml present ($ASSIGNED slots reserved)"
else
  info "slot_assignments.toml absent (no reservations)"
fi

# --- C. GitHub-side runner fleet ----------------------------------------
section "5. GitHub org runner fleet ($ORG)"
RAW=$(/usr/bin/gh api "orgs/$ORG/actions/runners" --paginate 2>/dev/null || echo '{"runners":[]}')
TOTAL=$(echo "$RAW" | jq '.total_count // (.runners | length)')
ONLINE=$(echo "$RAW" | jq '[.runners[] | select(.status=="online")] | length')
OFFLINE=$(echo "$RAW" | jq '[.runners[] | select(.status=="offline")] | length')
BUSY=$(echo "$RAW" | jq '[.runners[] | select(.busy==true)] | length')
echo "  total=$TOTAL online=$ONLINE offline=$OFFLINE busy=$BUSY"
EZ_RUNNERS=$(echo "$RAW" | jq -r '.runners[] | select(.name | startswith("ez-org-")) | "\(.name) \(.status)"')
if [ -n "$EZ_RUNNERS" ]; then
  echo "$EZ_RUNNERS" | while read -r n s; do
    case "$s" in
      online) ok "ezgha: $n $s" ;;
      *)      bad "ezgha: $n $s" ;;
    esac
  done
else
  bad "no ez-org-runner-* registrations on GitHub"
fi
COLIMA_RUNNERS=$(echo "$RAW" | jq -r '.runners[] | select(.name | startswith("org-runner-")) | "\(.name) \(.status)"')
if [ -n "$COLIMA_RUNNERS" ]; then
  echo "  (colima leftovers still present, not auto-cleaned by ezgha):"
  echo "$COLIMA_RUNNERS" | while read -r n s; do
    warn "colima: $n $s"
  done
fi

# --- D. live docker containers ------------------------------------------
section "6. live docker containers (ezgha-managed)"
CONTAINER_NAMES=$(docker ps --filter label=ezgha=managed --format '{{.Names}} {{.Status}}' 2>/dev/null || true)
CONTAINER_COUNT=$(docker ps --filter label=ezgha=managed --format '{{.Names}}' 2>/dev/null | wc -l)
CONTAINER_COUNT=$(printf '%d' "$CONTAINER_COUNT" 2>/dev/null || echo 0)
info "managed containers running: $CONTAINER_COUNT (expected: configured runner.count)"
echo "$CONTAINER_NAMES" | head -20

# --- E. recent routing proof: jobs REALLY ran on ez-org-runner-* ---------
# "online" is not "working". This section proves recent GitHub Actions jobs
# were actually EXECUTED by ez-org-runner-* runners by reading each run's
# jobs API and confirming the runner_name that handled it belongs to our
# fleet. A completed run whose runner_name is NOT ez-org-runner-* means the
# job went to colima / GitHub-hosted / somewhere else.
section "7. real job-execution proof (last ${ROUTING_N:-6} ezgha-selftest runs)"
ROUTING_N="${ROUTING_N:-6}"
REAL_ON_FLEET=0
REAL_TOTAL=0
while read -r rid; do
  [ -z "$rid" ] && continue
  REAL_TOTAL=$((REAL_TOTAL+1))
  jobs=$(/usr/bin/gh api "repos/$EZGHA_REPO/actions/runs/$rid/jobs" 2>/dev/null)
  rn=$(echo "$jobs" | jq -r '.jobs[0].runner_name // "?"' 2>/dev/null)
  conc=$(echo "$jobs" | jq -r '.jobs[0].conclusion // "?"' 2>/dev/null)
  if [[ "$rn" == ez-org-runner-* ]]; then
    ok "run $rid: $conc on $rn (our fleet)"
    [ "$conc" = "success" ] && REAL_ON_FLEET=$((REAL_ON_FLEET+1))
  else
    warn "run $rid: $conc on $rn (NOT an ez-org-runner)"
  fi
done < <(/usr/bin/gh run list -R "$EZGHA_REPO" -w ezgha-selftest -L "$ROUTING_N" --json databaseId --jq '.[].databaseId' 2>/dev/null)
info "real jobs succeeded on our fleet: $REAL_ON_FLEET / $REAL_TOTAL"

# --- E2. optional live canary: dispatch a job and prove it runs NOW ------
# `--prove` dispatches a fresh ezgha-selftest and blocks until it completes,
# then confirms the runner_name is ez-org-runner-* and conclusion=success.
# This is the strongest "handled for real, right now" proof.
CANARY_OK=""
if [ "$PROVE" = "1" ]; then
  section "7b. live canary (dispatch + verify a job runs on our fleet NOW)"
  before=$(/usr/bin/gh run list -R "$EZGHA_REPO" -w ezgha-selftest -L 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)
  /usr/bin/gh workflow run ezgha-selftest -R "$EZGHA_REPO" >/dev/null 2>&1
  info "dispatched canary; waiting for a new run to appear + complete (up to 180s)..."
  cid=""
  for _ in $(seq 1 18); do
    sleep 10
    latest=$(/usr/bin/gh run list -R "$EZGHA_REPO" -w ezgha-selftest -L 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)
    [ "$latest" != "$before" ] && [ "$latest" != "0" ] && { cid="$latest"; break; }
  done
  if [ -z "$cid" ]; then
    bad "canary never appeared — dispatch failed or no runner picked it up"
  else
    for _ in $(seq 1 18); do
      st=$(/usr/bin/gh run view "$cid" -R "$EZGHA_REPO" --json status,conclusion --jq '.status' 2>/dev/null)
      [ "$st" = "completed" ] && break
      sleep 10
    done
    jobs=$(/usr/bin/gh api "repos/$EZGHA_REPO/actions/runs/$cid/jobs" 2>/dev/null)
    rn=$(echo "$jobs" | jq -r '.jobs[0].runner_name // "?"')
    conc=$(echo "$jobs" | jq -r '.jobs[0].conclusion // "?"')
    if [[ "$rn" == ez-org-runner-* ]] && [ "$conc" = "success" ]; then
      ok "canary run $cid: success on $rn — fleet is handling real jobs NOW"
      CANARY_OK=1
    else
      bad "canary run $cid: $conc on $rn (expected success on ez-org-runner-*)"
    fi
  fi
fi

# --- F. verdict ----------------------------------------------------------
section "verdict"
CRITICAL=0
[ "$SERVICE_STATE" != "active" ]            && CRITICAL=$((CRITICAL+1))
[ "$COLIMA_STATUS" = "Stopped" ]            && CRITICAL=$((CRITICAL+1))
! echo "$RAW" | jq -e '.runners[] | select(.name|startswith("ez-org-")) | select(.status=="online")' >/dev/null 2>&1 && \
                                          CRITICAL=$((CRITICAL+1))
[ "${CONTAINER_COUNT:-0}" -lt 14 ]         && CRITICAL=$((CRITICAL+1))
[ "$LOOP_FAILS" -gt 3 ]                    && CRITICAL=$((CRITICAL+1))
# real-execution gate: at least one recent job must have succeeded on our fleet
[ "${REAL_ON_FLEET:-0}" -lt 1 ]            && CRITICAL=$((CRITICAL+1))
# canary gate (only when --prove): the live job must have run on our fleet
[ "$PROVE" = "1" ] && [ -z "$CANARY_OK" ]  && CRITICAL=$((CRITICAL+1))

if [ "$CRITICAL" -gt 0 ]; then
  bad "fleet unhealthy: $CRITICAL critical check(s) failed"
  echo
  echo "Suggested remediation:"
  echo "  1. Stop and restart ezgha: systemctl --user restart ezgha.service"
  echo "  2. Reset slot file:       rm ~/.config/ezgha/slot_assignments.toml"
  echo "  3. Start colima if down:  limactl start colima"
  echo "  4. Re-run ./doctor.sh --detail after each step"
  exit 1
fi
ok "fleet healthy: $ONLINE/$TOTAL runners online, $BUSY busy, $CONTAINER_COUNT containers up, $LOOP_FAILS loop errors"
exit 0