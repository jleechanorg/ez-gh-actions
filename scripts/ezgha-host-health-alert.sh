#!/usr/bin/env bash
# ezgha-host-health-alert.sh — Dual-host mutual fleet health monitor & GCP Cloud Monitoring Slack notifier.
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
# ── Failure classification ─────────────────────────────────────────────────
# Each failed check has one cause; operational alerts route to Slack.
#
#   cause=fleet → a successful local Docker listing found zero running runner
#                 containers on an enabled host. Severity ERROR notifies
#                 "[CRITICAL] ezgha: GitHub Actions Runners Down Alert".
#   cause=blind → incomplete measurement, with persistent failures paging separately.
#   cause=peer  → peer-only failures remain WARNING diagnostics.
#   cause=disk  → free space is under the admission floor but the fleet is
#                 otherwise healthy. Severity WARNING ⇒ logged, NOT paged, for
#                 `DISK_PAGE_AFTER_MIN` (default 15) minutes, because ezgha's own
#                 disk admission pause plus the scratch reclaimer normally
#                 self-heal a floor breach within minutes. A breach that persists
#                 past that window, or drops below `DISK_EMERGENCY_GB` (default
#                 15GB), escalates to ERROR and pages its own policy
#                 "[CRITICAL] ezgha: host disk below safety floor" — so the Slack alert
#                 says disk, never "runners down".
#
# 2026-10-28 incident this classifies: a host-disk verdict was written as
# status=DOWN/severity=ERROR, the single "Runners Down" policy matched every
# ERROR entry in this log, and the operator was paged "[CRITICAL] ezgha Runners
# Down" every ~10 minutes for three hours while 16-19/20 runners were online and
# executing jobs. The 30-minute throttle never engaged because the state file
# lived in /tmp and the scratch reclaimer archived it; state now lives under
# $HOME/.local/state/ezgha.
#
# Usage:
#   ./scripts/ezgha-host-health-alert.sh
#   ./scripts/ezgha-host-health-alert.sh --dry-run
#   ./scripts/ezgha-host-health-alert.sh --ensure-policies
#
# Env overrides (production defaults in parentheses; the *_OVERRIDE-style hooks
# exist so tests can drive every verdict path without docker/ssh/gcloud):
#   HEALTH_ALERT_HOST (hostname -s)          HEALTH_ALERT_PLATFORM (uname -s)
#   HEALTH_ALERT_STATE_DIR (~/.local/state/ezgha)
#   HEALTH_ALERT_FREE_GB                     HEALTH_ALERT_CONTAINER_COUNT
#   HEALTH_ALERT_SERVICE_OK (1 healthy)      HEALTH_ALERT_PEER_OK (1 healthy; "" = probe)
#   HEALTH_ALERT_PEER_FREE_GB                HEALTH_ALERT_PEER_CONTAINERS
#   HEALTH_ALERT_PEER_SERVICE (active)
#   HEALTH_ALERT_DISK_FLOOR_GB (Linux 30, Darwin 20)
#   HEALTH_ALERT_DISK_EMERGENCY_GB (15)      HEALTH_ALERT_DISK_PAGE_AFTER_MIN (15)
#   HEALTH_ALERT_COOLDOWN_SEC (1800)         GCLOUD_BIN, DOCKER_BIN
#
set -euo pipefail

DRY_RUN=0
ENSURE_POLICIES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --ensure-policies) ENSURE_POLICIES=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 64 ;;
  esac
done

NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST="${HEALTH_ALERT_HOST:-$(hostname -s)}"
PLATFORM="${HEALTH_ALERT_PLATFORM:-$(uname -s)}"

GCP_PROJECT="${GCP_PROJECT:-worldarchitecture-ai}"
GCP_ACCOUNT="${GCP_ACCOUNT:-jleechan@gmail.com}"
LOG_NAME="ezgha-runner-alerts"

# Locate gcloud binary
GCLOUD="${GCLOUD_BIN:-}"
if [ -z "$GCLOUD" ]; then
  if command -v gcloud >/dev/null 2>&1; then
    GCLOUD="$(command -v gcloud)"
  elif [ -x "$HOME/google-cloud-sdk/bin/gcloud" ]; then
    GCLOUD="$HOME/google-cloud-sdk/bin/gcloud"
  elif [ -x "/snap/bin/gcloud" ]; then
    GCLOUD="/snap/bin/gcloud"
  fi
fi
DOCKER_BIN="${DOCKER_BIN:-docker}"

# ── Policy definitions (single source of truth, used by --ensure-policies) ────
FLEET_POLICY_NAME="[CRITICAL] ezgha: GitHub Actions Runners Down Alert"
FLEET_POLICY_SUBJECT="[CRITICAL] ezgha runner fleet down"
FLEET_POLICY_DOC="A successful Docker listing found zero running ezgha runner containers on this enabled host."
BLIND_POLICY_NAME="[CRITICAL] ezgha: runner health monitoring blind"
BLIND_POLICY_SUBJECT="[CRITICAL] ezgha runner health monitoring blind"
BLIND_POLICY_DOC="Runner health telemetry is persistently incomplete. See failed_checks for the unavailable measurements."
DISK_POLICY_NAME="[CRITICAL] ezgha: host disk below safety floor"
DISK_POLICY_SUBJECT="[CRITICAL] ezgha host disk below safety floor"
DISK_POLICY_DOC="Host free space has been under the ezgha admission floor for the sustained window (or below the emergency floor), so runner admission is paused. Source: scripts/ezgha-host-health-alert.sh with jsonPayload.cause=\"disk\"."
ALERT_CHANNELS='["projects/worldarchitecture-ai/notificationChannels/14071650426226468737"]'

# ── Thresholds ───────────────────────────────────────────────────────────────
if [ "$PLATFORM" = "Darwin" ]; then
  DISK_FLOOR_GB="${HEALTH_ALERT_DISK_FLOOR_GB:-20}"
else
  DISK_FLOOR_GB="${HEALTH_ALERT_DISK_FLOOR_GB:-30}"
fi
PEER_DISK_FLOOR_GB="${HEALTH_ALERT_PEER_DISK_FLOOR_GB:-30}"
DISK_EMERGENCY_GB="${HEALTH_ALERT_DISK_EMERGENCY_GB:-15}"
DISK_PAGE_AFTER_MIN="${HEALTH_ALERT_DISK_PAGE_AFTER_MIN:-15}"
COOLDOWN_SEC="${HEALTH_ALERT_COOLDOWN_SEC:-1800}"

# Daemon CRITICAL follow-up. The daemon writes Slack alerts to alerts.jsonl;
# a CRITICAL entry means the daemon itself decided something is badly wrong
# (admission paused, refill stuck, queue starvation). Keep this operational
# signal available through Slack, but do not let it broaden SMS eligibility.
# Route recent daemon CRITICALs by event type. Window and file are overridable.
ALERTS_JSONL="${HEALTH_ALERT_ALERTS_FILE:-$HOME/.local/state/ezgha/alerts.jsonl}"
SLACK_CRITICAL_WINDOW_MIN="${HEALTH_ALERT_SLACK_CRITICAL_WINDOW_MIN:-15}"
SLACK_ESCALATE="${HEALTH_ALERT_SLACK_ESCALATE:-1}"

STATE_DIR="${HEALTH_ALERT_STATE_DIR:-$HOME/.local/state/ezgha}"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/host-health-alert-${HOST}.json"
# Pre-2026-10-28 location: archived by the /tmp scratch reclaimer, which reset the
# throttle and produced repeated pages. Read once for continuity, never written.
LEGACY_STATE_FILE="/tmp/ezgha_health_alert_state_${HOST}.json"

if [ "$ENSURE_POLICIES" -eq 1 ]; then
  if [ -z "$GCLOUD" ]; then
    echo "FATAL: gcloud not found; cannot ensure policies" >&2
    exit 3
  fi
  GCP_ARGS=(--project="$GCP_PROJECT" --account="$GCP_ACCOUNT")
  ensure_policy() { # name cause doc subject
    local name="$1" cause="$2" doc="$3" subject="$4"
    local cond_filter="logName=\"projects/${GCP_PROJECT}/logs/${LOG_NAME}\" AND severity>=ERROR AND jsonPayload.cause=\"${cause}\""
    local policy_file; policy_file="$(mktemp)"
    jq -n \
      --arg name "$name" --arg doc "$doc" --arg subject "$subject" \
      --arg filter "$cond_filter" --arg cause "$cause" \
      --argjson channels "$ALERT_CHANNELS" \
      '{
        displayName: $name,
        documentation: {content: $doc, mimeType: "text/markdown", subject: $subject},
        combiner: "OR",
        severity: "CRITICAL",
        conditions: [{displayName: ("ezgha " + $cause + " failure entry"), conditionMatchedLog: {filter: $filter}}],
        alertStrategy: {autoClose: "1800s", notificationRateLimit: {period: "300s"}},
        notificationChannels: $channels,
        enabled: true,
        userLabels: {component: "ezgha-runners", severity: "critical", cause: $cause}
      }' > "$policy_file"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[$NOW_ISO] [dry-run] would ensure policy '$name' (filter: $cond_filter)"
      rm -f "$policy_file"; return 0
    fi
    local existing
    existing="$("$GCLOUD" alpha monitoring policies list "${GCP_ARGS[@]}" \
      --filter="displayName=\"${name}\"" --format='value(name)' 2>/dev/null | head -1)"
    if [ -n "$existing" ]; then
      "$GCLOUD" alpha monitoring policies update "$existing" --policy-from-file="$policy_file" "${GCP_ARGS[@]}" >/dev/null
      echo "[$NOW_ISO] updated policy '$name' ($existing)"
    else
      "$GCLOUD" alpha monitoring policies create --policy-from-file="$policy_file" "${GCP_ARGS[@]}" >/dev/null
      echo "[$NOW_ISO] created policy '$name'"
    fi
    rm -f "$policy_file"
  }
  ensure_policy "$FLEET_POLICY_NAME" fleet "$FLEET_POLICY_DOC" "$FLEET_POLICY_SUBJECT"
  ensure_policy "$DISK_POLICY_NAME" disk "$DISK_POLICY_DOC" "$DISK_POLICY_SUBJECT"
  ensure_policy "$BLIND_POLICY_NAME" blind "$BLIND_POLICY_DOC" "$BLIND_POLICY_SUBJECT"
  exit 0
fi

DISK_FAILS=()
BLIND_CHECKS=()
BLIND_PERSISTENT=0
DOCKER_BLIND=0
DISK_BLIND=0
DAEMON_READ_BLIND=0
HOST_DISK_FAILURE_TS=""
OPERATIONAL_NOTE=""
QUEUE_NOTE=""
SATURATION_NOTE=""
# Peer diagnostics have their own cause and severity.
PEER_FAILS=()

# ── 0. Intentionally parked platform (bead jleechan-hxz0) ────────────────────
# A deliberately suspended platform is a DECISION, not an outage, and the two
# must never render the same way. Without this, parking the Mac (launchd
# disabled + 0 containers + count=4 in config) reads as "runners down" and pages
# "[CRITICAL] ezgha: GitHub Actions Runners Down Alert" every ~30 minutes,
# forever -- which is exactly what happened on 2026-11-05.
#
# Declared, never inferred: a daemon that CRASHED also reads as "not running",
# so inferring would silently absorb the real outages this script exists to
# catch. Unset keeps today's fail-closed behaviour.
#   MAC_RUNNER_DISABLED=1        parks the macOS leg
#   REMOTE_LINUX_DISABLED=1      parks the Linux leg
LOCAL_LEG_PARKED=0
case "$PLATFORM" in
  Darwin) if [ "${MAC_RUNNER_DISABLED:-0}" = "1" ]; then LOCAL_LEG_PARKED=1; fi ;;
  Linux)  if [ "${REMOTE_LINUX_DISABLED:-0}" = "1" ]; then LOCAL_LEG_PARKED=1; fi ;;
esac

# ── 1. Local Service Check ───────────────────────────────────────────────────
SERVICE_OK="${HEALTH_ALERT_SERVICE_OK:-}"
if [ -z "$SERVICE_OK" ]; then
  SERVICE_OK=1
  if [ "$PLATFORM" = "Linux" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
    systemctl --user is-active --quiet ezgha.service 2>/dev/null || SERVICE_OK=0
  elif [ "$PLATFORM" = "Darwin" ]; then
    if ! launchctl list 2>/dev/null | grep -q "org.jleechanorg.ezgha" && ! pgrep -x ezgha >/dev/null 2>&1; then
      SERVICE_OK=0
    fi
  fi
fi
if [ "$SERVICE_OK" != "1" ]; then
  OPERATIONAL_NOTE="local: ezgha supervisor inactive or unavailable"
fi

# ── 2. Local Docker & Containers ─────────────────────────────────────────────
# Paging contract: only a successful, complete listing can establish zero.
# A failed command may still print rows; discard its entire output.
# One validator for both local and peer inventories. Empty input is a valid
# zero only when the producing Docker command itself succeeded.
# shellcheck disable=SC2016 # $0 belongs to awk.
RUNNER_ID_COUNT_AWK='
  length($0) != 64 || /[^0-9a-f]/ || seen[$0]++ { exit 1 }
  END { print NR }
'
CONTAINER_COUNT="${HEALTH_ALERT_CONTAINER_COUNT:-}"
if [ -z "$CONTAINER_COUNT" ]; then
  if [ "$PLATFORM" = "Darwin" ] && [ -S "$HOME/.colima/default/docker.sock" ] && [ -z "${DOCKER_HOST:-}" ]; then
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
  fi
  CONTAINER_COUNT=$(
    timeout 10 "$DOCKER_BIN" ps --no-trunc --filter label=ezgha=managed --filter status=running -q 2>/dev/null | awk "$RUNNER_ID_COUNT_AWK"
  ) || CONTAINER_COUNT=""
fi
if ! [[ "$CONTAINER_COUNT" =~ ^(0|[1-9][0-9]*)$ ]]; then
  CONTAINER_COUNT=null
  DOCKER_BLIND=1
  BLIND_CHECKS+=("local: Docker runner listing failed or was incomplete")
fi

# ── 3. Local Disk Space ──────────────────────────────────────────────────────
FREE_GB="${HEALTH_ALERT_FREE_GB:-}"
if [ -z "$FREE_GB" ]; then
  if [ "$PLATFORM" = "Darwin" ]; then
    FREE_GB=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}') || FREE_GB=""
  else
    FREE_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {sub(/G$/, "", $4); print $4}') || FREE_GB=""
  fi
fi
if ! [[ "$FREE_GB" =~ ^(0|[1-9][0-9]*)$ ]]; then
  FREE_GB=null
  DISK_BLIND=1
  BLIND_CHECKS+=("local: host free disk measurement unavailable")
elif [ "$FREE_GB" -lt "$DISK_FLOOR_GB" ]; then
  if [ "$PLATFORM" = "Darwin" ]; then
    DISK_FAILS+=("local: host disk space low: ${FREE_GB}GB free (floor: ${DISK_FLOOR_GB}GB)")
  else
    DISK_FAILS+=("local: host disk space critical: ${FREE_GB}GB free (safety floor: ${DISK_FLOOR_GB}GB)")
  fi
fi

# ── 4. Cross-Host Peer Check (Mutual Monitoring) ─────────────────────────────
PEER_NAME=""
if [ "$PLATFORM" = "Linux" ]; then
  PEER_NAME="jeffreys-macbook-pro"
elif [ "$PLATFORM" = "Darwin" ]; then
  PEER_NAME="jeff-ubuntu"
fi

PEER_OK="${HEALTH_ALERT_PEER_OK:-}"
if [ -n "$PEER_OK" ]; then
  # Test/override path: peer verdict supplied directly.
  PEER_SERVICE="${HEALTH_ALERT_PEER_SERVICE:-active}"
  PEER_CNT="${HEALTH_ALERT_PEER_CONTAINERS:-4}"
  PEER_FREE="${HEALTH_ALERT_PEER_FREE_GB:-100}"
  if [ "$PEER_OK" != "1" ]; then
    PEER_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  else
    if [ "$PEER_SERVICE" != "active" ]; then
      PEER_FAILS+=("peer($PEER_NAME): ezgha service is ${PEER_SERVICE}")
    fi
    if ! [[ "$PEER_CNT" =~ ^(0|[1-9][0-9]*)$ ]]; then
      PEER_FAILS+=("peer($PEER_NAME): Docker runner count unavailable")
    elif [ "$PEER_CNT" = 0 ]; then
      PEER_FAILS+=("peer($PEER_NAME): 0 runner containers running")
    fi
    if ! [[ "$PEER_FREE" =~ ^(0|[1-9][0-9]*)$ ]]; then
      PEER_FAILS+=("peer($PEER_NAME): free disk measurement unavailable")
    elif [ "$PEER_FREE" -lt "$PEER_DISK_FLOOR_GB" ]; then
      PEER_FAILS+=("peer($PEER_NAME): disk space critical: ${PEER_FREE}GB free (floor: ${PEER_DISK_FLOOR_GB}GB)")
    fi
  fi
elif [ "$PLATFORM" = "Linux" ]; then
  PEER_CMD="pgrep -x ezgha >/dev/null 2>&1 || pgrep -f Runner.Listener >/dev/null 2>&1; echo \$?"
  PEER_RES=""
  if PEER_RES=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER_NAME" "$PEER_CMD" 2>/dev/null); then
    if [ "$PEER_RES" != "0" ]; then
      PEER_FAILS+=("peer($PEER_NAME): ezgha process not running")
    fi
  elif PEER_RES=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no 100.67.70.24 "$PEER_CMD" 2>/dev/null); then
    if [ "$PEER_RES" != "0" ]; then
      PEER_FAILS+=("peer($PEER_NAME): ezgha process not running (via Tailscale)")
    fi
  else
    PEER_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  fi
elif [ "$PLATFORM" = "Darwin" ]; then
  # The peer shell expands its own variables.
  # shellcheck disable=SC2016
  PEER_PROBE='
    set -o pipefail
    FREE=$(df -BG / 2>/dev/null | awk "NR==2 {sub(/G$/, \"\", \$4); print \$4}") || FREE=null;
    FREE=${FREE:-null};
    SVC=$(XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus systemctl --user is-active ezgha.service 2>/dev/null) || SVC=inactive;
    CNT=$(docker ps --no-trunc --filter label=ezgha=managed --filter status=running -q 2>/dev/null | awk '"'"'$RUNNER_ID_COUNT_AWK'"'"') || CNT=null;
    echo "$FREE $SVC $CNT"
  '
  PEER_OUT=""
  if PEER_OUT=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes "$PEER_NAME" "$PEER_PROBE" 2>/dev/null); then
    :
  elif PEER_OUT=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes "${PEER_NAME}-ts" "$PEER_PROBE" 2>/dev/null); then
    :
  else
    PEER_OUT=""
    PEER_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  fi

  if [ "${#PEER_FAILS[@]}" -eq 0 ]; then
    PEER_FREE=$(echo "$PEER_OUT" | awk '{print $1}')
    PEER_SVC=$(echo "$PEER_OUT" | awk '{print $2}')
    PEER_CNT=$(echo "$PEER_OUT" | awk '{print $3}')

    if [ "$PEER_SVC" != "active" ]; then
      PEER_FAILS+=("peer($PEER_NAME): ezgha.service is $PEER_SVC")
    fi
    if ! [[ "$PEER_CNT" =~ ^(0|[1-9][0-9]*)$ ]]; then
      PEER_FAILS+=("peer($PEER_NAME): Docker runner count unavailable")
    elif [ "$PEER_CNT" = 0 ]; then
      PEER_FAILS+=("peer($PEER_NAME): 0 runner containers running")
    fi
    if ! [[ "$PEER_FREE" =~ ^(0|[1-9][0-9]*)$ ]]; then
      PEER_FAILS+=("peer($PEER_NAME): free disk measurement unavailable")
    elif [ "$PEER_FREE" -lt "$PEER_DISK_FLOOR_GB" ]; then
      PEER_FAILS+=("peer($PEER_NAME): disk space critical: ${PEER_FREE}GB free (floor: ${PEER_DISK_FLOOR_GB}GB)")
    fi
  fi
fi

# ── 4b. Daemon CRITICAL follow-up ─────────────────────────────────────────
# Daemon keys describe diagnostic categories. They never establish capacity.
if [ "$SLACK_ESCALATE" = "1" ] && [ -f "$ALERTS_JSONL" ]; then
  if CRITICAL_ROWS=$(tail -400 "$ALERTS_JSONL" | jq -Rr --argjson now "$NOW_EPOCH" --argjson window "$SLACK_CRITICAL_WINDOW_MIN" '
    fromjson? | objects | select(.severity == "CRITICAL")
    | select(.ts_unix | type == "number" and . == floor and . > 0)
    | select(.ts_unix <= $now and (($now - .ts_unix) / 60 | floor) <= $window)
    | [.ts_unix, (.event_key | strings // "")] | @tsv
  '); then
    while IFS=$'\t' read -r CRIT_TS CRIT_KEY; do
      [ -n "$CRIT_TS" ] || continue
      CRIT_AGE_MIN=$(( (NOW_EPOCH - CRIT_TS) / 60 ))
      CRIT_REASON="local: daemon CRITICAL alert ${CRIT_AGE_MIN}m ago (${CRIT_KEY:-unknown})"
      case "$CRIT_KEY" in
        runner_pool.host_disk_floor|runner_pool.disk_floor)
          DISK_FAILS+=("$CRIT_REASON")
          ;;
        runner_pool.disk_measurement_unavailable)
          # The producer emits this key only after consecutive failed measurements.
          BLIND_PERSISTENT=1
          BLIND_CHECKS+=("$CRIT_REASON")
          ;;
        runner_pool.host_disk_measurement_unavailable)
          # Only a second distinct producer timestamp is new evidence. Reading
          # the same retained log row on another monitor tick is not a retry.
          if [ -n "$HOST_DISK_FAILURE_TS" ] && [ "$HOST_DISK_FAILURE_TS" != "$CRIT_TS" ]; then
            BLIND_PERSISTENT=1
          fi
          HOST_DISK_FAILURE_TS="$CRIT_TS"
          BLIND_CHECKS+=("$CRIT_REASON")
          ;;
        queue.starvation.busy_but_starving)
          SATURATION_NOTE="$CRIT_REASON"
          ;;
        queue.starvation.tail.critical)
          QUEUE_NOTE="$CRIT_REASON"
          ;;
        *)
          OPERATIONAL_NOTE="${OPERATIONAL_NOTE:+$OPERATIONAL_NOTE; }$CRIT_REASON"
          ;;
      esac
    done <<< "$CRITICAL_ROWS"
  else
    DAEMON_READ_BLIND=1
    BLIND_CHECKS+=("local: daemon alert log read or decode failed")
  fi
fi

# ── 5. Decision & Alert Dispatch ─────────────────────────────────────────────
PREV_STATUS="OK"
PREV_LAST_SENT_FLEET=0
PREV_LAST_SENT_DISK=0
PREV_DISK_SINCE=0
PREV_DOCKER_BLIND=0
PREV_DISK_BLIND=0
PREV_DAEMON_READ_BLIND=0
FLEET_OPEN=0
DISK_OPEN=0
PEER_OPEN=0
NOW_LAST_BLIND=0
read_state() { # file
  local f="$1"
  [ -f "$f" ] || return 0
  PREV_STATUS=$(sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1)
  PREV_LAST_SENT_FLEET=$(sed -n 's/.*"last_sent_fleet":[[:space:]]*\([0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
  PREV_LAST_SENT_DISK=$(sed -n 's/.*"last_sent_disk":[[:space:]]*\([0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
  PREV_DISK_SINCE=$(sed -n 's/.*"disk_breach_since":[[:space:]]*\([0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
  # Read only explicit cause bits where present. For older state, infer a
  # cause from an unambiguous status; bare legacy FAIL identifies neither.
  read_flag() { sed -n "s/.*\"$1\":[[:space:]]*\([01]\).*/\1/p" "$f" | head -1; }
  FLEET_OPEN=$(read_flag fleet_open)
  DISK_OPEN=$(read_flag disk_open)
  PEER_OPEN=$(read_flag peer_open)
  if [ -z "$FLEET_OPEN" ]; then
    FLEET_OPEN=0
    [ "$PREV_STATUS" != DOWN ] || FLEET_OPEN=1
  fi
  if [ -z "$DISK_OPEN" ]; then
    DISK_OPEN=0
    case "$PREV_STATUS" in DISK|DEGRADED) DISK_OPEN=1 ;; esac
  fi
  if [ -z "$PEER_OPEN" ]; then
    PEER_OPEN=0
    [ "$PREV_STATUS" != PEER ] || PEER_OPEN=1
  fi
  PREV_DOCKER_BLIND=$(read_flag docker_blind)
  PREV_DISK_BLIND=$(read_flag disk_blind)
  PREV_DAEMON_READ_BLIND=$(read_flag daemon_read_blind)
  NOW_LAST_BLIND=$(sed -n 's/.*"last_sent_blind":[[:space:]]*\([0-9]*\).*/\1/p' "$f" | head -1)
  NOW_LAST_BLIND="${NOW_LAST_BLIND:-0}"
  PREV_STATUS="${PREV_STATUS:-OK}"
  PREV_LAST_SENT_FLEET="${PREV_LAST_SENT_FLEET:-0}"
  PREV_LAST_SENT_DISK="${PREV_LAST_SENT_DISK:-0}"
  PREV_DISK_SINCE="${PREV_DISK_SINCE:-0}"
}
read_state "$STATE_FILE"
if [ ! -f "$STATE_FILE" ]; then
  read_state "$LEGACY_STATE_FILE"
  if [ -f "$LEGACY_STATE_FILE" ]; then
    # Legacy file only had a single last_sent + status; treat it as fleet continuity.
    LEGACY_LAST=$(sed -n 's/.*"last_sent":[[:space:]]*\([0-9]*\).*/\1/p' "$LEGACY_STATE_FILE" 2>/dev/null | head -1)
    PREV_LAST_SENT_FLEET="${LEGACY_LAST:-0}"
    PREV_LAST_SENT_DISK="${LEGACY_LAST:-0}"
  fi
fi

save_state() { # status last_sent_fleet last_sent_disk disk_since
  local status="$1" last_fleet="$2"
  # Keep the preexisting DOWN display while capacity is unknown; independent
  # cause bits also retain incidents through notes and peer/disk branches.
  if [ "$CONTAINER_COUNT" = null ] && [ "$FLEET_OPEN" = 1 ] && [ "$status" != DISABLED ]; then
    status=DOWN
  fi
  printf '{"status":"%s", "last_sent_fleet":%s, "last_sent_disk":%s, "disk_breach_since":%s, "fleet_open":%s, "disk_open":%s, "peer_open":%s, "docker_blind":%s, "disk_blind":%s, "daemon_read_blind":%s, "last_sent_blind":%s, "updated_at":"%s"}\n' \
    "$status" "$last_fleet" "$3" "$4" "$FLEET_OPEN" "$DISK_OPEN" "$PEER_OPEN" "$DOCKER_BLIND" "$DISK_BLIND" "$DAEMON_READ_BLIND" "$NOW_LAST_BLIND" "$NOW_ISO" > "$STATE_FILE"
}

emit() { # severity payload-json
  local severity="$1" payload="$2"
  EMIT_OK=1
  if [ -n "$GCLOUD" ] && [ "$DRY_RUN" -eq 0 ]; then
    # --payload-type=json is required: gcloud defaults to a text payload, which
    # leaves jsonPayload null and blinds the policies that filter on
    # jsonPayload.cause.
    if "$GCLOUD" logging write "$LOG_NAME" "$payload" --payload-type=json \
      --severity="$severity" --project="$GCP_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 2>&1; then
      echo "[$NOW_ISO] Dispatched ${severity} entry to Cloud Logging (${LOG_NAME})"
    else
      EMIT_OK=0
      echo "[$NOW_ISO] Cloud Logging rejected the ${severity} entry for ${LOG_NAME}" >&2
    fi
  else
    echo "[$NOW_ISO] [dry-run/no-gcloud] would dispatch ${severity}: ${payload}"
  fi
}

json_checks() { printf '%s\n' "$@" | jq -R . | jq -s .; }

BLIND_COUNT=${#BLIND_CHECKS[@]}
DISK_COUNT=${#DISK_FAILS[@]}
PEER_COUNT=${#PEER_FAILS[@]}
DISK_SINCE=$PREV_DISK_SINCE
NOW_LAST_FLEET=$PREV_LAST_SENT_FLEET
NOW_LAST_DISK=$PREV_LAST_SENT_DISK
EXIT_CODE=0

# ── Intentionally parked leg: report DISABLED at INFO, never DOWN/CRITICAL. ──
if [ "$LOCAL_LEG_PARKED" -eq 1 ]; then
  echo "[$NOW_ISO] DISABLED: $HOST ($PLATFORM) is intentionally parked (operator opt-out) — 0 slot(s) expected, not an outage" >&2
  if [ "$DISK_COUNT" -gt 0 ]; then
    echo "[$NOW_ISO] note: parked host has a disk diagnostic" >&2
  fi
  NOW_LAST_BLIND=0
  PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DISABLED", "cause":"parked", "severity":"INFO", "failed_checks":[], "container_count":%s, "free_gb":%s, "ts":"%s"}' \
    "$HOST" "$PLATFORM" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
  emit INFO "$PAYLOAD"
  save_state "DISABLED" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit "$EXIT_CODE"
fi

recover() {
  local payload
  payload=$(printf '{"host":"%s", "platform":"%s", "status":"RECOVERED", "cause":"%s", "container_count":%s, "free_gb":%s, "ts":"%s"}' \
    "$HOST" "$PLATFORM" "$1" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
  emit INFO "$payload"
  [ "$EMIT_OK" = 1 ]
}

# Recovery belongs to the measured signal, not the poll's display status.
if [ "$FLEET_OPEN" = 1 ] && [ "$CONTAINER_COUNT" != null ] && [ "$CONTAINER_COUNT" -gt 0 ]; then
  if recover fleet; then FLEET_OPEN=0; NOW_LAST_FLEET=0; fi
fi
if [ "$DISK_COUNT" -eq 0 ] && [ "$FREE_GB" != null ] && [ "$FREE_GB" -ge "$DISK_FLOOR_GB" ]; then
  DISK_SINCE=0
  if [ "$DISK_OPEN" = 1 ] && recover disk; then DISK_OPEN=0; NOW_LAST_DISK=0; fi
fi
if [ "$PEER_OPEN" = 1 ] && [ "$PEER_COUNT" -eq 0 ]; then
  if recover peer; then PEER_OPEN=0; fi
fi

if [ "$CONTAINER_COUNT" = 0 ]; then
  # ── Fleet is genuinely down: page, subject "Runners Down". ────────────────
  # Exit status contract: a *verdict* is a successful probe, so this exits 0.
  # Exit non-zero is reserved for "the probe itself could not run". Recording a
  # monitoring verdict as a job failure made the macOS launchd agent show
  # "last exit 1" permanently, which is indistinguishable from a dead agent.
  EXIT_CODE=0
  ALL_FAILS=("local: 0 ezgha runner containers running")
  if [ -n "$OPERATIONAL_NOTE" ]; then ALL_FAILS+=("$OPERATIONAL_NOTE"); fi
  REASONS=$(IFS='; '; echo "${ALL_FAILS[*]}")
  if [ "$DISK_COUNT" -gt 0 ]; then
    REASONS="${REASONS}; $(IFS='; '; echo "${DISK_FAILS[*]}")"
  fi
  echo "[$NOW_ISO] FLEET DOWN on $HOST ($CONTAINER_COUNT containers, ${FREE_GB}GB free): $REASONS" >&2
  SINCE_LAST=$(( NOW_EPOCH - NOW_LAST_FLEET ))
  if [ "$FLEET_OPEN" = 1 ] && [ "$SINCE_LAST" -lt "$COOLDOWN_SEC" ]; then
    echo "[$NOW_ISO] fleet alert throttled (last sent ${SINCE_LAST}s ago, cooldown ${COOLDOWN_SEC}s)" >&2
  else
    if [ "$DISK_COUNT" -gt 0 ]; then ALL_FAILS+=("${DISK_FAILS[@]}"); fi
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DOWN", "cause":"fleet", "severity":"CRITICAL", "failed_checks":%s, "container_count":%s, "free_gb":%s, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(json_checks "${ALL_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit ERROR "$PAYLOAD"
    if [ "$EMIT_OK" -eq 1 ]; then NOW_LAST_FLEET=$NOW_EPOCH; fi
  fi
  FLEET_OPEN=1
  save_state "DOWN" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit "$EXIT_CODE"
fi

# Two consecutive incomplete polls establish persistence for local probes.
# The blind cooldown is independent of the fleet and disk routes.
if [ "$BLIND_COUNT" -gt 0 ]; then
  BLIND_SEVERITY=WARNING
  if [ "$BLIND_PERSISTENT" = 1 ] ||
     { [ "$DOCKER_BLIND" = 1 ] && [ "$PREV_DOCKER_BLIND" = 1 ]; } ||
     { [ "$DISK_BLIND" = 1 ] && [ "$PREV_DISK_BLIND" = 1 ]; } ||
     { [ "$DAEMON_READ_BLIND" = 1 ] && [ "$PREV_DAEMON_READ_BLIND" = 1 ]; }; then
    BLIND_SEVERITY=ERROR
  fi
  if [ "$BLIND_SEVERITY" = WARNING ] || [ "$(( NOW_EPOCH - NOW_LAST_BLIND ))" -ge "$COOLDOWN_SEC" ]; then
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"BLIND", "cause":"blind", "severity":"%s", "failed_checks":%s, "container_count":%s, "free_gb":%s, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$BLIND_SEVERITY" "$(json_checks "${BLIND_CHECKS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit "$BLIND_SEVERITY" "$PAYLOAD"
    if [ "$BLIND_SEVERITY" = ERROR ] && [ "$EMIT_OK" -eq 1 ]; then NOW_LAST_BLIND=$NOW_EPOCH; fi
  fi
else
  NOW_LAST_BLIND=0
fi

if [ -n "$SATURATION_NOTE" ] && [ "$CONTAINER_COUNT" != null ]; then
  PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"SATURATION", "cause":"saturation", "severity":"WARNING", "failed_checks":%s, "container_count":%s, "free_gb":%s, "ts":"%s"}' \
    "$HOST" "$PLATFORM" "$(json_checks "$SATURATION_NOTE")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
  emit WARNING "$PAYLOAD"
elif [ -n "${QUEUE_NOTE:-$SATURATION_NOTE}" ]; then
  OPERATIONAL_NOTE="${OPERATIONAL_NOTE:+$OPERATIONAL_NOTE; }${QUEUE_NOTE:-$SATURATION_NOTE}"
fi

record_peer_degradation() {
  # Peer degradation is diagnostic, never a fleet page.
  # Emit on transition so a persistent problem does not spam.
  PEER_REASONS=$(IFS='; '; echo "${PEER_FAILS[*]}")
  echo "[$NOW_ISO] PEER DEGRADED on $HOST (local: $CONTAINER_COUNT containers, ${FREE_GB}GB free; cause=peer, no page): $PEER_REASONS" >&2
  # Preserve a coexisting operational diagnostic without assigning it page authority.
  PEER_CHECKS=("${PEER_FAILS[@]}")
  if [ -n "${OPERATIONAL_NOTE:-}" ]; then
    echo "[$NOW_ISO] OPERATIONAL NOTE on $HOST: $OPERATIONAL_NOTE" >&2
    PEER_CHECKS+=("$OPERATIONAL_NOTE")
  fi
  if [ "$PEER_OPEN" = 0 ]; then
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DEGRADED", "cause":"peer", "severity":"WARNING", "failed_checks":%s, "container_count":%s, "free_gb":%s, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(json_checks "${PEER_CHECKS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit WARNING "$PAYLOAD"
  fi
  PEER_OPEN=1
}

if [ "$DISK_COUNT" -gt 0 ]; then
  # ── Fleet healthy, disk under floor: log, page only on a sustained breach. ─
  EXIT_CODE=0
  if [ "$DISK_SINCE" -eq 0 ]; then DISK_SINCE=$NOW_EPOCH; fi
  BREACH_MIN=$(( (NOW_EPOCH - DISK_SINCE) / 60 ))
  REASONS=$(IFS='; '; echo "${DISK_FAILS[*]}")

  ESCALATE=0
  if [ "$FREE_GB" != null ] && [ "$FREE_GB" -lt "$DISK_EMERGENCY_GB" ]; then ESCALATE=1; fi
  if [ "$BREACH_MIN" -ge "$DISK_PAGE_AFTER_MIN" ]; then ESCALATE=1; fi

  if [ "$ESCALATE" -eq 1 ]; then
    SINCE_LAST=$(( NOW_EPOCH - NOW_LAST_DISK ))
    if [ "$DISK_OPEN" = 1 ] && [ "$SINCE_LAST" -lt "$COOLDOWN_SEC" ]; then
      echo "[$NOW_ISO] disk alert throttled (last sent ${SINCE_LAST}s ago, cooldown ${COOLDOWN_SEC}s)" >&2
    else
      echo "[$NOW_ISO] DISK BELOW FLOOR ${BREACH_MIN}m on $HOST (${CONTAINER_COUNT} containers, ${FREE_GB}GB free): $REASONS" >&2
      PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DEGRADED", "cause":"disk", "severity":"CRITICAL", "failed_checks":%s, "container_count":%s, "free_gb":%s, "disk_breach_min":%d, "ts":"%s"}' \
        "$HOST" "$PLATFORM" "$(json_checks "${DISK_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$BREACH_MIN" "$NOW_ISO")
      emit ERROR "$PAYLOAD"
      if [ "$EMIT_OK" = 1 ]; then NOW_LAST_DISK=$NOW_EPOCH; fi
    fi
    DISK_OPEN=1
    STATUS=DISK
  else
    echo "[$NOW_ISO] DISK DEGRADED ${BREACH_MIN}m on $HOST (${CONTAINER_COUNT} containers, ${FREE_GB}GB free): $REASONS — within ${DISK_PAGE_AFTER_MIN}m self-heal window, not paging" >&2
    # Fold the transient daemon CRITICAL into the note list so a suppressed
    # fleet page is still recorded, without claiming cause=fleet.
    DISK_NOTE_FAILS=("${DISK_FAILS[@]}")
    if [ -n "${OPERATIONAL_NOTE:-}" ]; then DISK_NOTE_FAILS+=("$OPERATIONAL_NOTE"); fi
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DEGRADED", "cause":"disk", "severity":"WARNING", "failed_checks":%s, "container_count":%s, "free_gb":%s, "disk_breach_min":%d, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(json_checks "${DISK_NOTE_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$BREACH_MIN" "$NOW_ISO")
    emit WARNING "$PAYLOAD"
    DISK_OPEN=1
    STATUS=DEGRADED
  fi
  # The local disk decision must be recorded before any peer warning.
  if [ "$PEER_COUNT" -gt 0 ]; then record_peer_degradation; fi
  save_state "$STATUS" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit "$EXIT_CODE"
fi

if [ "$PEER_COUNT" -gt 0 ]; then
  record_peer_degradation
  save_state "PEER" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit 0
fi

# ── Healthy ─────────────────────────────────────────────────────────────────
if [ "$BLIND_COUNT" -eq 0 ]; then
  echo "[$NOW_ISO] MUTUAL HEALTH CHECK OK on $HOST (Local: $CONTAINER_COUNT containers, ${FREE_GB}GB free; Peer healthy)"
fi

# Record operational diagnostics on transition to avoid repeating them every poll.
if [ -n "${OPERATIONAL_NOTE:-}" ]; then
  echo "[$NOW_ISO] OPERATIONAL NOTE on $HOST: $OPERATIONAL_NOTE" >&2
  if [ "$PREV_STATUS" != "NOTE" ]; then
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DEGRADED", "cause":"operational", "severity":"WARNING", "failed_checks":%s, "container_count":%s, "free_gb":%s, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(json_checks "$OPERATIONAL_NOTE")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit WARNING "$PAYLOAD"
  fi
  save_state "NOTE" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit 0
fi

save_state "OK" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
exit 0
