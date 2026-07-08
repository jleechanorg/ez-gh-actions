#!/usr/bin/env bash
# Poll Mac + Linux fleet every 10 minutes. Log to artifacts/fleet-poll.log
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$REPO/artifacts/fleet-poll.log"
INTERVAL="${FLEET_POLL_INTERVAL_SEC:-600}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

poll_once() {
  log "=== fleet poll ==="
  MAC_N=$(docker ps --filter label=ezgha=managed -q 2>/dev/null | wc -l | tr -d ' ')
  MAC_CFG=$(awk -F= '/^count/ {gsub(/ /,"",$2); print $2; exit}' "$HOME/.config/ezgha/config.toml" 2>/dev/null || echo "?")
  log "Mac containers: ${MAC_N}/${MAC_CFG}"
  ~/.cargo/bin/ezgha status 2>/dev/null | head -6 | sed 's/^/  /' >> "$LOG" || log "  Mac ezgha status failed"

  if ssh -o ConnectTimeout=8 jeff-ubuntu 'true' 2>/dev/null; then
    read -r LIN_N LIN_CFG <<< "$(ssh -o ConnectTimeout=8 jeff-ubuntu 'export PATH="$HOME/.cargo/bin:$PATH"; n=$(docker ps --filter label=ezgha=managed -q | wc -l); c=$(awk -F= "/^count/ {gsub(/ /,\"\",\$2); print \$2; exit}" ~/.config/ezgha/config.toml); echo "$n $c"')"
    log "Linux containers: ${LIN_N}/${LIN_CFG}"
    WD=$(ssh -o ConnectTimeout=8 jeff-ubuntu 'journalctl --user --since "10 min ago" -u ezgha.service --no-pager 2>/dev/null | rg -ci "watchdog timeout|SIGABRT" || echo 0')
    log "Linux watchdog kills (10m): ${WD}"
    ssh -o ConnectTimeout=8 jeff-ubuntu 'export PATH="$HOME/.cargo/bin:$PATH"; systemctl --user is-active ezgha.service' 2>/dev/null | sed 's/^/  linux service: /' >> "$LOG" || log "  Linux SSH failed"
  else
    log "Linux: SSH unreachable"
  fi

  if command -v gh >/dev/null 2>&1; then
    Q=$(gh api "repos/jleechanorg/worldarchitect.ai/actions/runs?status=queued&per_page=1" -q '.total_count' 2>/dev/null || echo "?")
    IP=$(gh api "repos/jleechanorg/worldarchitect.ai/actions/runs?status=in_progress&per_page=1" -q '.total_count' 2>/dev/null || echo "?")
    log "Queue: queued=${Q} in_progress=${IP}"
  fi
  log "---"
}

log "fleet-poll started (interval=${INTERVAL}s) pid=$$"
poll_once
while true; do
  sleep "$INTERVAL"
  poll_once
done
