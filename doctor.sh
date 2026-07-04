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
GH_FLAGS=()
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --detail|-v|--verbose) DETAIL=1 ;;
    --gh=*) GH_FLAGS=("-X" "gh"); echo "(note: --gh= not used in this build)"; ;;
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

# --- E. recent routing proof ---------------------------------------------
section "7. recent routing (last 8 ezgha-selftest runs)"
/usr/bin/gh run list -R "$EZGHA_REPO" -w ezgha-selftest -L 8 --json databaseId,conclusion,status --jq '.[] | "\(.databaseId) \(.conclusion)/\(.status)"' 2>/dev/null | head -8

# --- F. verdict ----------------------------------------------------------
section "verdict"
CRITICAL=0
[ "$SERVICE_STATE" != "active" ]            && CRITICAL=$((CRITICAL+1))
[ "$COLIMA_STATUS" = "Stopped" ]            && CRITICAL=$((CRITICAL+1))
! echo "$RAW" | jq -e '.runners[] | select(.name|startswith("ez-org-")) | select(.status=="online")' >/dev/null 2>&1 && \
                                          CRITICAL=$((CRITICAL+1))
[ "${CONTAINER_COUNT:-0}" -lt 14 ]         && CRITICAL=$((CRITICAL+1))
[ "$LOOP_FAILS" -gt 3 ]                    && CRITICAL=$((CRITICAL+1))

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