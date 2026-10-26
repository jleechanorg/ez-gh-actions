#!/usr/bin/env bash
# ezgha-host-health-alert.sh — Dual-host mutual fleet health monitor & GCP Cloud Monitoring SMS alerter.
#
# Runs periodically on both Linux (jeff-ubuntu) and macOS (jeffreys-macbook-pro).
# Mutual monitoring ensures that if either host crashes, loses network, runs out of disk,
# or its runner daemon fails, the other host detects the failure and alerts.
#
# Checks per execution:
#   1. Local supervisor service status (ezgha)
#   2. Local Docker daemon responsiveness & runner container count
#   3. Local host disk space (enforces ezgha 30GB safety floor on Linux, 20GB on Mac)
#   4. Cross-host peer reachability & peer runner health (over LAN/Tailscale)
#
# When degraded, writes an ERROR log to Cloud Logging (ezgha-runner-alerts) in
# GCP project worldarchitecture-ai, triggering GCP Alert Policy 10378876199383442907
# which delivers an instant CRITICAL SMS text alert to the operator (+16502965127) and Slack.
# Auto-throttles to at most 1 SMS per 30 minutes while degraded; emits an INFO recovery
# log upon self-healing.
#
# Usage:
#   ./scripts/ezgha-host-health-alert.sh
#   ./scripts/ezgha-host-health-alert.sh --dry-run
#
set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST="$(hostname -s)"
PLATFORM="$(uname -s)"

# Locate gcloud binary
GCLOUD=""
if command -v gcloud >/dev/null 2>&1; then
  GCLOUD="$(command -v gcloud)"
elif [ -x "$HOME/google-cloud-sdk/bin/gcloud" ]; then
  GCLOUD="$HOME/google-cloud-sdk/bin/gcloud"
elif [ -x "/snap/bin/gcloud" ]; then
  GCLOUD="/snap/bin/gcloud"
fi

STATE_FILE="/tmp/ezgha_health_alert_state_${HOST}.json"
COOLDOWN_SEC=1800 # 30 minutes between repeat alerts

FAILED_CHECKS=()

# ── 1. Local Service Check ───────────────────────────────────────────────────
if [ "$PLATFORM" = "Linux" ]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  if ! systemctl --user is-active --quiet ezgha.service 2>/dev/null; then
    FAILED_CHECKS+=("local: ezgha.service inactive or failed on systemd")
  fi
elif [ "$PLATFORM" = "Darwin" ]; then
  if ! launchctl list | grep -q "org.jleechanorg.ezgha" 2>/dev/null && ! pgrep -x ezgha >/dev/null 2>&1; then
    FAILED_CHECKS+=("local: ezgha service not running on launchd")
  fi
fi

# ── 2. Local Docker & Containers ─────────────────────────────────────────────
if [ "$PLATFORM" = "Darwin" ]; then
  if [ -S "$HOME/.colima/default/docker.sock" ] && [ -z "${DOCKER_HOST:-}" ]; then
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
  fi
fi

if ! timeout 10 docker info >/dev/null 2>&1; then
  FAILED_CHECKS+=("local: docker daemon unreachable or timed out")
  CONTAINER_COUNT=0
else
  CONTAINER_COUNT=$(timeout 10 docker ps --filter label=ezgha=managed -q 2>/dev/null | wc -l || echo 0)
  CONTAINER_COUNT=$(printf '%d' "$CONTAINER_COUNT" 2>/dev/null || echo 0)
  if [ "$CONTAINER_COUNT" -eq 0 ]; then
    FAILED_CHECKS+=("local: 0 ezgha runner containers running")
  fi
fi

# ── 3. Local Disk Space ──────────────────────────────────────────────────────
if [ "$PLATFORM" = "Linux" ]; then
  FREE_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo 0)
  FREE_GB=$(printf '%d' "$FREE_GB" 2>/dev/null || echo 0)
  if [ "$FREE_GB" -lt 30 ]; then
    FAILED_CHECKS+=("local: host disk space critical: ${FREE_GB}GB free (safety floor: 30GB)")
  fi
elif [ "$PLATFORM" = "Darwin" ]; then
  FREE_GB=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  FREE_GB=$(printf '%d' "$FREE_GB" 2>/dev/null || echo 0)
  if [ "$FREE_GB" -lt 20 ]; then
    FAILED_CHECKS+=("local: host disk space low: ${FREE_GB}GB free")
  fi
fi

# ── 4. Cross-Host Peer Check (Mutual Monitoring) ─────────────────────────────
if [ "$PLATFORM" = "Linux" ]; then
  # Peer is Mac
  PEER_NAME="jeffreys-macbook-pro"
  PEER_CMD="pgrep -x ezgha >/dev/null 2>&1; echo \$?"
  PEER_RES=""
  if PEER_RES=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER_NAME" "$PEER_CMD" 2>/dev/null); then
    if [ "$PEER_RES" != "0" ]; then
      FAILED_CHECKS+=("peer($PEER_NAME): ezgha process not running")
    fi
  elif PEER_RES=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no 100.67.70.24 "$PEER_CMD" 2>/dev/null); then
    if [ "$PEER_RES" != "0" ]; then
      FAILED_CHECKS+=("peer($PEER_NAME): ezgha process not running (via Tailscale)")
    fi
  else
    FAILED_CHECKS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  fi
elif [ "$PLATFORM" = "Darwin" ]; then
  # Peer is Linux (jeff-ubuntu)
  PEER_NAME="jeff-ubuntu"
  PEER_PROBE='
    FREE=$(df -BG / 2>/dev/null | awk "NR==2 {gsub(\"G\",\"\"); print \$4}");
    SVC=$(XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus systemctl --user is-active ezgha.service 2>/dev/null || echo inactive);
    CNT=$(docker ps --filter label=ezgha=managed -q 2>/dev/null | wc -l || echo 0);
    echo "$FREE $SVC $CNT"
  '
  PEER_OUT=""
  if PEER_OUT=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes "$PEER_NAME" "$PEER_PROBE" 2>/dev/null); then
    :
  elif PEER_OUT=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes "${PEER_NAME}-ts" "$PEER_PROBE" 2>/dev/null); then
    :
  else
    FAILED_CHECKS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  fi

  if [ -n "$PEER_OUT" ]; then
    PEER_FREE=$(echo "$PEER_OUT" | awk '{print $1}')
    PEER_SVC=$(echo "$PEER_OUT" | awk '{print $2}')
    PEER_CNT=$(echo "$PEER_OUT" | awk '{print $3}')
    PEER_FREE=$(printf '%d' "$PEER_FREE" 2>/dev/null || echo 0)
    PEER_CNT=$(printf '%d' "$PEER_CNT" 2>/dev/null || echo 0)

    if [ "$PEER_SVC" != "active" ]; then
      FAILED_CHECKS+=("peer($PEER_NAME): ezgha.service is $PEER_SVC")
    fi
    if [ "$PEER_FREE" -lt 30 ]; then
      FAILED_CHECKS+=("peer($PEER_NAME): disk space critical: ${PEER_FREE}GB free (floor: 30GB)")
    fi
    if [ "$PEER_CNT" -eq 0 ]; then
      FAILED_CHECKS+=("peer($PEER_NAME): 0 runner containers running")
    fi
  fi
fi

# ── 5. Decision & Alert Dispatch ─────────────────────────────────────────────
PREV_STATUS="OK"
LAST_SENT=0
if [ -f "$STATE_FILE" ]; then
  PREV_STATUS=$(sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" 2>/dev/null || echo "OK")
  LAST_SENT=$(sed -n 's/.*"last_sent":[[:space:]]*\([0-9]*\).*/\1/p' "$STATE_FILE" 2>/dev/null || echo 0)
fi
LAST_SENT=${LAST_SENT:-0}

if [ "${#FAILED_CHECKS[@]}" -gt 0 ]; then
  REASONS=$(IFS='; '; echo "${FAILED_CHECKS[*]}")
  echo "[$NOW_ISO] HEALTH CHECK FAILED on $HOST ($CONTAINER_COUNT containers, ${FREE_GB}GB free): $REASONS" >&2

  SINCE_LAST=$(( NOW_EPOCH - LAST_SENT ))
  if [ "$PREV_STATUS" = "FAIL" ] && [ "$SINCE_LAST" -lt "$COOLDOWN_SEC" ]; then
    echo "[$NOW_ISO] Alert throttled (last sent ${SINCE_LAST}s ago, cooldown ${COOLDOWN_SEC}s)" >&2
    exit 1
  fi

  if [ -n "$GCLOUD" ] && [ "$DRY_RUN" -eq 0 ]; then
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DOWN", "severity":"CRITICAL", "failed_checks":%s, "container_count":%d, "free_gb":%d, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(printf '%s\n' "${FAILED_CHECKS[@]}" | jq -R . | jq -s .)" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")

    "$GCLOUD" logging write ezgha-runner-alerts \
      "$PAYLOAD" \
      --severity=ERROR \
      --project=worldarchitecture-ai \
      --account=jleechan@gmail.com >/dev/null 2>&1 || true

    echo "[$NOW_ISO] Dispatched [CRITICAL] SMS/Slack alert via Cloud Logging to GCP"
  else
    echo "[$NOW_ISO] [dry-run/no-gcloud] would dispatch [CRITICAL] alert payload for $HOST"
  fi

  echo "{\"status\":\"FAIL\", \"last_sent\":$NOW_EPOCH, \"updated_at\":\"$NOW_ISO\"}" > "$STATE_FILE"
  exit 1
else
  echo "[$NOW_ISO] MUTUAL HEALTH CHECK OK on $HOST (Local: $CONTAINER_COUNT containers, ${FREE_GB}GB free; Peer healthy)"

  if [ "$PREV_STATUS" = "FAIL" ]; then
    echo "[$NOW_ISO] Host $HOST and peer have recovered! Emitting recovery log to GCP..."
    if [ -n "$GCLOUD" ] && [ "$DRY_RUN" -eq 0 ]; then
      PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"RECOVERED", "container_count":%d, "free_gb":%d, "ts":"%s"}' \
        "$HOST" "$PLATFORM" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")

      "$GCLOUD" logging write ezgha-runner-alerts \
        "$PAYLOAD" \
        --severity=INFO \
        --project=worldarchitecture-ai \
        --account=jleechan@gmail.com >/dev/null 2>&1 || true
    fi
  fi

  echo "{\"status\":\"OK\", \"last_sent\":0, \"updated_at\":\"$NOW_ISO\"}" > "$STATE_FILE"
  exit 0
fi
