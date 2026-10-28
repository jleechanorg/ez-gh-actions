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
# ── Failure classification (2026-10-28, bead jleechan-v8ms) ───────────────────
# Every failed check is classified into exactly one cause, and the cause decides
# whether the operator is paged:
#
#   cause=fleet → the runner fleet cannot run anything (service down, docker
#                 unreachable, 0 local/peer containers, peer host unreachable).
#                 Severity ERROR ⇒ pages "[CRITICAL] ezgha: GitHub Actions
#                 Runners Down Alert" (alertPolicies/10378876199383442907).
#   cause=disk  → free space is under the admission floor but the fleet is
#                 otherwise healthy. Severity WARNING ⇒ logged, NOT paged, for
#                 `DISK_PAGE_AFTER_MIN` (default 15) minutes, because ezgha's own
#                 disk admission pause plus the scratch reclaimer normally
#                 self-heal a floor breach within minutes. A breach that persists
#                 past that window, or drops below `DISK_EMERGENCY_GB` (default
#                 15GB), escalates to ERROR and pages its own policy
#                 "[CRITICAL] ezgha: host disk below safety floor" — so the SMS
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
FLEET_POLICY_DOC="The ezgha runner fleet on this host cannot run jobs (service down, docker unreachable, 0 runner containers, or the peer host is unreachable). Source: scripts/ezgha-host-health-alert.sh with jsonPayload.cause=\"fleet\". Disk-floor breaches are NOT this alert; see '[CRITICAL] ezgha: host disk below safety floor'."
DISK_POLICY_NAME="[CRITICAL] ezgha: host disk below safety floor"
DISK_POLICY_SUBJECT="[CRITICAL] ezgha host disk below safety floor"
DISK_POLICY_DOC="Host free space has been under the ezgha admission floor for the sustained window (or below the emergency floor), so runner admission is paused. Source: scripts/ezgha-host-health-alert.sh with jsonPayload.cause=\"disk\"."
ALERT_CHANNELS='["projects/worldarchitecture-ai/notificationChannels/14071650426226468737", "projects/worldarchitecture-ai/notificationChannels/17167119139665448890"]'

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
  exit 0
fi

FLEET_FAILS=()
DISK_FAILS=()

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
  if [ "$PLATFORM" = "Linux" ]; then
    FLEET_FAILS+=("local: ezgha.service inactive or failed on systemd")
  else
    FLEET_FAILS+=("local: ezgha service not running on launchd")
  fi
fi

# ── 2. Local Docker & Containers ─────────────────────────────────────────────
CONTAINER_COUNT="${HEALTH_ALERT_CONTAINER_COUNT:-}"
DOCKER_UNREACHABLE=0
if [ -z "$CONTAINER_COUNT" ]; then
  if [ "$PLATFORM" = "Darwin" ] && [ -S "$HOME/.colima/default/docker.sock" ] && [ -z "${DOCKER_HOST:-}" ]; then
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
  fi
  if ! timeout 10 "$DOCKER_BIN" info >/dev/null 2>&1; then
    FLEET_FAILS+=("local: docker daemon unreachable or timed out")
    DOCKER_UNREACHABLE=1
    CONTAINER_COUNT=0
  else
    CONTAINER_COUNT=$(timeout 10 "$DOCKER_BIN" ps --filter label=ezgha=managed -q 2>/dev/null | wc -l || echo 0)
  fi
fi
CONTAINER_COUNT=$(printf '%d' "$CONTAINER_COUNT" 2>/dev/null || echo 0)
# A zero-container fleet is the core fleet-down signal, whichever way the count
# was obtained (live probe or an audit-mode override).
if [ "$CONTAINER_COUNT" -eq 0 ] && [ "$DOCKER_UNREACHABLE" -eq 0 ]; then
  FLEET_FAILS+=("local: 0 ezgha runner containers running")
fi

# ── 3. Local Disk Space ──────────────────────────────────────────────────────
FREE_GB="${HEALTH_ALERT_FREE_GB:-}"
if [ -z "$FREE_GB" ]; then
  if [ "$PLATFORM" = "Darwin" ]; then
    FREE_GB=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  else
    FREE_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo 0)
  fi
fi
FREE_GB=$(printf '%d' "$FREE_GB" 2>/dev/null || echo 0)
if [ "$FREE_GB" -lt "$DISK_FLOOR_GB" ]; then
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
    FLEET_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  else
    if [ "$PEER_SERVICE" != "active" ]; then
      FLEET_FAILS+=("peer($PEER_NAME): ezgha service is ${PEER_SERVICE}")
    fi
    if [ "$PEER_CNT" -eq 0 ]; then
      FLEET_FAILS+=("peer($PEER_NAME): 0 runner containers running")
    fi
    if [ "$PEER_FREE" -lt "$PEER_DISK_FLOOR_GB" ]; then
      DISK_FAILS+=("peer($PEER_NAME): disk space critical: ${PEER_FREE}GB free (floor: ${PEER_DISK_FLOOR_GB}GB)")
    fi
  fi
elif [ "$PLATFORM" = "Linux" ]; then
  PEER_CMD="pgrep -x ezgha >/dev/null 2>&1; echo \$?"
  PEER_RES=""
  if PEER_RES=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER_NAME" "$PEER_CMD" 2>/dev/null); then
    if [ "$PEER_RES" != "0" ]; then
      FLEET_FAILS+=("peer($PEER_NAME): ezgha process not running")
    fi
  elif PEER_RES=$(timeout 6 ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no 100.67.70.24 "$PEER_CMD" 2>/dev/null); then
    if [ "$PEER_RES" != "0" ]; then
      FLEET_FAILS+=("peer($PEER_NAME): ezgha process not running (via Tailscale)")
    fi
  else
    FLEET_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  fi
elif [ "$PLATFORM" = "Darwin" ]; then
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
    FLEET_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  fi

  if [ -n "$PEER_OUT" ]; then
    PEER_FREE=$(echo "$PEER_OUT" | awk '{print $1}')
    PEER_SVC=$(echo "$PEER_OUT" | awk '{print $2}')
    PEER_CNT=$(echo "$PEER_OUT" | awk '{print $3}')
    PEER_FREE=$(printf '%d' "$PEER_FREE" 2>/dev/null || echo 0)
    PEER_CNT=$(printf '%d' "$PEER_CNT" 2>/dev/null || echo 0)

    if [ "$PEER_SVC" != "active" ]; then
      FLEET_FAILS+=("peer($PEER_NAME): ezgha.service is $PEER_SVC")
    fi
    if [ "$PEER_CNT" -eq 0 ]; then
      FLEET_FAILS+=("peer($PEER_NAME): 0 runner containers running")
    fi
    if [ "$PEER_FREE" -lt "$PEER_DISK_FLOOR_GB" ]; then
      DISK_FAILS+=("peer($PEER_NAME): disk space critical: ${PEER_FREE}GB free (floor: ${PEER_DISK_FLOOR_GB}GB)")
    fi
  fi
fi

# ── 5. Decision & Alert Dispatch ─────────────────────────────────────────────
PREV_STATUS="OK"
PREV_LAST_SENT_FLEET=0
PREV_LAST_SENT_DISK=0
PREV_DISK_SINCE=0
read_state() { # file
  local f="$1"
  [ -f "$f" ] || return 0
  PREV_STATUS=$(sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1)
  PREV_LAST_SENT_FLEET=$(sed -n 's/.*"last_sent_fleet":[[:space:]]*\([0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
  PREV_LAST_SENT_DISK=$(sed -n 's/.*"last_sent_disk":[[:space:]]*\([0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
  PREV_DISK_SINCE=$(sed -n 's/.*"disk_breach_since":[[:space:]]*\([0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
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
  printf '{"status":"%s", "last_sent_fleet":%s, "last_sent_disk":%s, "disk_breach_since":%s, "updated_at":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$NOW_ISO" > "$STATE_FILE"
}

emit() { # severity payload-json
  local severity="$1" payload="$2"
  if [ -n "$GCLOUD" ] && [ "$DRY_RUN" -eq 0 ]; then
    "$GCLOUD" logging write "$LOG_NAME" "$payload" \
      --severity="$severity" --project="$GCP_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 2>&1 || true
    echo "[$NOW_ISO] Dispatched ${severity} entry to Cloud Logging (${LOG_NAME})"
  else
    echo "[$NOW_ISO] [dry-run/no-gcloud] would dispatch ${severity}: ${payload}"
  fi
}

json_checks() { printf '%s\n' "$@" | jq -R . | jq -s .; }

FLEET_COUNT=${#FLEET_FAILS[@]}
DISK_COUNT=${#DISK_FAILS[@]}
DISK_SINCE=$PREV_DISK_SINCE
NOW_LAST_FLEET=$PREV_LAST_SENT_FLEET
NOW_LAST_DISK=$PREV_LAST_SENT_DISK
EXIT_CODE=0

if [ "$FLEET_COUNT" -gt 0 ]; then
  # ── Fleet is genuinely down: page, subject "Runners Down". ────────────────
  EXIT_CODE=1
  REASONS=$(IFS='; '; echo "${FLEET_FAILS[*]}")
  if [ "$DISK_COUNT" -gt 0 ]; then
    REASONS="${REASONS}; $(IFS='; '; echo "${DISK_FAILS[*]}")"
  fi
  echo "[$NOW_ISO] FLEET DOWN on $HOST ($CONTAINER_COUNT containers, ${FREE_GB}GB free): $REASONS" >&2
  SINCE_LAST=$(( NOW_EPOCH - NOW_LAST_FLEET ))
  if [ "$PREV_STATUS" = "DOWN" ] && [ "$SINCE_LAST" -lt "$COOLDOWN_SEC" ]; then
    echo "[$NOW_ISO] fleet alert throttled (last sent ${SINCE_LAST}s ago, cooldown ${COOLDOWN_SEC}s)" >&2
  else
    ALL_FAILS=("${FLEET_FAILS[@]}")
    if [ "$DISK_COUNT" -gt 0 ]; then ALL_FAILS+=("${DISK_FAILS[@]}"); fi
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DOWN", "cause":"fleet", "severity":"CRITICAL", "failed_checks":%s, "container_count":%d, "free_gb":%d, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(json_checks "${ALL_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit ERROR "$PAYLOAD"
    NOW_LAST_FLEET=$NOW_EPOCH
  fi
  save_state "DOWN" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit "$EXIT_CODE"
fi

if [ "$DISK_COUNT" -gt 0 ]; then
  # ── Fleet healthy, disk under floor: log, page only on a sustained breach. ─
  EXIT_CODE=1
  if [ "$DISK_SINCE" -eq 0 ]; then DISK_SINCE=$NOW_EPOCH; fi
  BREACH_MIN=$(( (NOW_EPOCH - DISK_SINCE) / 60 ))
  REASONS=$(IFS='; '; echo "${DISK_FAILS[*]}")

  ESCALATE=0
  if [ "$FREE_GB" -lt "$DISK_EMERGENCY_GB" ]; then ESCALATE=1; fi
  if [ "$BREACH_MIN" -ge "$DISK_PAGE_AFTER_MIN" ]; then ESCALATE=1; fi

  if [ "$ESCALATE" -eq 1 ]; then
    SINCE_LAST=$(( NOW_EPOCH - NOW_LAST_DISK ))
    if [ "$PREV_STATUS" = "DISK" ] && [ "$SINCE_LAST" -lt "$COOLDOWN_SEC" ]; then
      echo "[$NOW_ISO] disk alert throttled (last sent ${SINCE_LAST}s ago, cooldown ${COOLDOWN_SEC}s)" >&2
    else
      echo "[$NOW_ISO] DISK BELOW FLOOR ${BREACH_MIN}m on $HOST (${CONTAINER_COUNT} containers, ${FREE_GB}GB free): $REASONS" >&2
      PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DEGRADED", "cause":"disk", "severity":"CRITICAL", "failed_checks":%s, "container_count":%d, "free_gb":%d, "disk_breach_min":%d, "ts":"%s"}' \
        "$HOST" "$PLATFORM" "$(json_checks "${DISK_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$BREACH_MIN" "$NOW_ISO")
      emit ERROR "$PAYLOAD"
      NOW_LAST_DISK=$NOW_EPOCH
    fi
    save_state "DISK" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  else
    echo "[$NOW_ISO] DISK DEGRADED ${BREACH_MIN}m on $HOST (${CONTAINER_COUNT} containers, ${FREE_GB}GB free): $REASONS — within ${DISK_PAGE_AFTER_MIN}m self-heal window, not paging" >&2
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DEGRADED", "cause":"disk", "severity":"WARNING", "failed_checks":%s, "container_count":%d, "free_gb":%d, "disk_breach_min":%d, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(json_checks "${DISK_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$BREACH_MIN" "$NOW_ISO")
    emit WARNING "$PAYLOAD"
    save_state "DEGRADED" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  fi
  exit "$EXIT_CODE"
fi

# ── Healthy ─────────────────────────────────────────────────────────────────
echo "[$NOW_ISO] MUTUAL HEALTH CHECK OK on $HOST (Local: $CONTAINER_COUNT containers, ${FREE_GB}GB free; Peer healthy)"

if [ "$PREV_STATUS" = "DOWN" ] || [ "$PREV_STATUS" = "FAIL" ] || [ "$PREV_STATUS" = "DISK" ] || [ "$PREV_STATUS" = "DEGRADED" ]; then
  echo "[$NOW_ISO] Host $HOST and peer have recovered! Emitting recovery log to GCP..."
  RECOVERED_CAUSES=()
  case "$PREV_STATUS" in
    DOWN|FAIL) RECOVERED_CAUSES+=("fleet") ;;
  esac
  case "$PREV_STATUS" in
    DISK|DEGRADED|FAIL) RECOVERED_CAUSES+=("disk") ;;
  esac
  for cause in "${RECOVERED_CAUSES[@]}"; do
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"RECOVERED", "cause":"%s", "container_count":%d, "free_gb":%d, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$cause" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit INFO "$PAYLOAD"
  done
fi

save_state "OK" 0 0 0
exit 0
