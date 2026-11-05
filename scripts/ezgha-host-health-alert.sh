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
#   cause=fleet → the local fleet cannot run jobs (service down, Docker
#                 unreachable, or no local containers). Severity ERROR notifies
#                 "[CRITICAL] ezgha: GitHub Actions Runners Down Alert".
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
FLEET_POLICY_DOC="The ezgha runner fleet on this host cannot run jobs (service down, docker unreachable, or 0 runner containers on this host, or a recent daemon CRITICAL such as an admission pause). A degraded PEER host is explicitly NOT this alert (cause=\"peer\", WARNING). Disk-floor breaches are NOT this alert; see '[CRITICAL] ezgha: host disk below safety floor'. Source: scripts/ezgha-host-health-alert.sh with jsonPayload.cause=\"fleet\"."
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
# Promote a recent daemon CRITICAL into cause=fleet so the Slack policy captures
# it. Window and file are overridable for hermetic tests.
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
  exit 0
fi

FLEET_FAILS=()
DISK_FAILS=()
# Peer-host failures are NOT this host's fleet outage. They used to be appended
# to FLEET_FAILS, so a down Mac paged the "GitHub Actions Runners Down" policy
# every 30 minutes while 20 healthy Linux containers were running (observed
# continuously 2026-11-04). Peer verdicts carry their own cause and never reach
# the fleet policy filter (severity>=ERROR AND cause="fleet").
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
if [ "$SERVICE_OK" != "1" ] && [ "$LOCAL_LEG_PARKED" -ne 1 ]; then
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
    # A parked host has no docker running BY CONSTRUCTION, so an unreachable
    # daemon is the decision, not a defect (bead jleechan-hxz0).
    if [ "$LOCAL_LEG_PARKED" -ne 1 ]; then
      FLEET_FAILS+=("local: docker daemon unreachable or timed out")
    fi
    DOCKER_UNREACHABLE=1
    CONTAINER_COUNT=0
  else
    CONTAINER_COUNT=$(timeout 10 "$DOCKER_BIN" ps --filter label=ezgha=managed -q 2>/dev/null | wc -l || echo 0)
  fi
fi
CONTAINER_COUNT=$(printf '%d' "$CONTAINER_COUNT" 2>/dev/null || echo 0)
# A zero-container fleet is the core fleet-down signal, whichever way the count
# was obtained (live probe or an audit-mode override).
if [ "$CONTAINER_COUNT" -eq 0 ] && [ "$DOCKER_UNREACHABLE" -eq 0 ] && [ "$LOCAL_LEG_PARKED" -ne 1 ]; then
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
    PEER_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  else
    if [ "$PEER_SERVICE" != "active" ]; then
      PEER_FAILS+=("peer($PEER_NAME): ezgha service is ${PEER_SERVICE}")
    fi
    if [ "$PEER_CNT" -eq 0 ]; then
      PEER_FAILS+=("peer($PEER_NAME): 0 runner containers running")
    fi
    if [ "$PEER_FREE" -lt "$PEER_DISK_FLOOR_GB" ]; then
      PEER_FAILS+=("peer($PEER_NAME): disk space critical: ${PEER_FREE}GB free (floor: ${PEER_DISK_FLOOR_GB}GB)")
    fi
  fi
elif [ "$PLATFORM" = "Linux" ]; then
  PEER_CMD="pgrep -x ezgha >/dev/null 2>&1; echo \$?"
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
    PEER_FAILS+=("peer($PEER_NAME): host unreachable over LAN and Tailscale")
  fi

  if [ -n "$PEER_OUT" ]; then
    PEER_FREE=$(echo "$PEER_OUT" | awk '{print $1}')
    PEER_SVC=$(echo "$PEER_OUT" | awk '{print $2}')
    PEER_CNT=$(echo "$PEER_OUT" | awk '{print $3}')
    PEER_FREE=$(printf '%d' "$PEER_FREE" 2>/dev/null || echo 0)
    PEER_CNT=$(printf '%d' "$PEER_CNT" 2>/dev/null || echo 0)

    if [ "$PEER_SVC" != "active" ]; then
      PEER_FAILS+=("peer($PEER_NAME): ezgha.service is $PEER_SVC")
    fi
    if [ "$PEER_CNT" -eq 0 ]; then
      PEER_FAILS+=("peer($PEER_NAME): 0 runner containers running")
    fi
    if [ "$PEER_FREE" -lt "$PEER_DISK_FLOOR_GB" ]; then
      PEER_FAILS+=("peer($PEER_NAME): disk space critical: ${PEER_FREE}GB free (floor: ${PEER_DISK_FLOOR_GB}GB)")
    fi
  fi
fi

# ── 4b. Daemon CRITICAL follow-up ─────────────────────────────────────────
# The daemon records every Slack alert it sends in alerts.jsonl. A CRITICAL there
# is a verdict the container/disk probes can miss entirely — an admission pause
# with the unit still "active" looks healthy from the outside, and on 2026-11-04
# that exact shape (runner image missing) sat at 0 runners for 15 hours while the
# only record was a Slack message nobody read. Promote a recent daemon CRITICAL
# into cause=fleet so the existing Slack policy carries the operational follow-up.
if [ "$SLACK_ESCALATE" = "1" ] && [ -f "$ALERTS_JSONL" ]; then
  RECENT_CRIT=$(tail -400 "$ALERTS_JSONL" 2>/dev/null | grep '"severity":"CRITICAL"' | tail -1)
  if [ -n "$RECENT_CRIT" ]; then
    CRIT_TS=$(printf '%s' "$RECENT_CRIT" | sed -n 's/.*"ts_unix":[[:space:]]*\([0-9]*\).*/\1/p')
    CRIT_KEY=$(printf '%s' "$RECENT_CRIT" | sed -n 's/.*"event_key":[[:space:]]*"\([^"]*\)".*/\1/p')
    CRIT_TS="${CRIT_TS:-0}"
    CRIT_AGE_MIN=$(( (NOW_EPOCH - CRIT_TS) / 60 ))
    if [ "$CRIT_TS" -gt 0 ] && [ "$CRIT_AGE_MIN" -ge 0 ] && [ "$CRIT_AGE_MIN" -le "$SLACK_CRITICAL_WINDOW_MIN" ]; then
      FLEET_FAILS+=("local: daemon CRITICAL alert ${CRIT_AGE_MIN}m ago (${CRIT_KEY:-unknown})")
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
PEER_COUNT=${#PEER_FAILS[@]}
DISK_SINCE=$PREV_DISK_SINCE
NOW_LAST_FLEET=$PREV_LAST_SENT_FLEET
NOW_LAST_DISK=$PREV_LAST_SENT_DISK
EXIT_CODE=0

# ── Intentionally parked leg: report DISABLED at INFO, never DOWN/CRITICAL. ──
# Placed after the fleet-down branch inputs are computed (a parked leg
# contributed no FLEET_FAILS) and before every page-emitting branch, so a parked
# host still reports real disk trouble separately while never claiming
# "runners down". Severity is what actually gates the SMS: the policy matches
# severity>=ERROR, so INFO cannot page.
if [ "$LOCAL_LEG_PARKED" -eq 1 ] && [ "$FLEET_COUNT" -eq 0 ]; then
  echo "[$NOW_ISO] DISABLED: $HOST ($PLATFORM) is intentionally parked (operator opt-out) — 0 slot(s) expected, not an outage" >&2
  if [ "$DISK_COUNT" -gt 0 ]; then
    echo "[$NOW_ISO] note: parked host still reports ${FREE_GB}GB free under its floor; pre-existing/independent" >&2
  fi
  PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DISABLED", "cause":"parked", "severity":"INFO", "failed_checks":%s, "container_count":%d, "free_gb":%d, "ts":"%s"}' \
    "$HOST" "$PLATFORM" "$(json_checks "${FLEET_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
  emit INFO "$PAYLOAD"
  save_state "DISABLED" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit "$EXIT_CODE"
fi

if [ "$FLEET_COUNT" -gt 0 ]; then
  # ── Fleet is genuinely down: page, subject "Runners Down". ────────────────
  # Exit status contract: a *verdict* is a successful probe, so this exits 0.
  # Exit non-zero is reserved for "the probe itself could not run". Recording a
  # monitoring verdict as a job failure made the macOS launchd agent show
  # "last exit 1" permanently, which is indistinguishable from a dead agent.
  EXIT_CODE=0
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

if [ "$PEER_COUNT" -gt 0 ]; then
  # ── Peer-only degradation: reported, never a fleet page. ──────────────────
  # This host is running jobs; the peer is not. Emit on transition only so a
  # long peer outage does not write a log entry every 2 minutes.
  PEER_REASONS=$(IFS='; '; echo "${PEER_FAILS[*]}")
  echo "[$NOW_ISO] PEER DEGRADED on $HOST (local: $CONTAINER_COUNT containers, ${FREE_GB}GB free; cause=peer, no page): $PEER_REASONS" >&2
  if [ "$PREV_STATUS" != "PEER" ]; then
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"DEGRADED", "cause":"peer", "severity":"WARNING", "failed_checks":%s, "container_count":%d, "free_gb":%d, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$(json_checks "${PEER_FAILS[@]}")" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit WARNING "$PAYLOAD"
  fi
  save_state "PEER" "$NOW_LAST_FLEET" "$NOW_LAST_DISK" "$DISK_SINCE"
  exit 0
fi

if [ "$DISK_COUNT" -gt 0 ]; then
  # ── Fleet healthy, disk under floor: log, page only on a sustained breach. ─
  EXIT_CODE=0
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

if [ "$PREV_STATUS" = "DOWN" ] || [ "$PREV_STATUS" = "FAIL" ] || [ "$PREV_STATUS" = "DISK" ] || [ "$PREV_STATUS" = "DEGRADED" ] || [ "$PREV_STATUS" = "PEER" ]; then
  echo "[$NOW_ISO] Host $HOST and peer have recovered! Emitting recovery log to GCP..."
  RECOVERED_CAUSES=()
  case "$PREV_STATUS" in
    DOWN|FAIL) RECOVERED_CAUSES+=("fleet") ;;
  esac
  case "$PREV_STATUS" in
    DISK|DEGRADED|FAIL) RECOVERED_CAUSES+=("disk") ;;
  esac
  case "$PREV_STATUS" in
    PEER) RECOVERED_CAUSES+=("peer") ;;
  esac
  for cause in "${RECOVERED_CAUSES[@]}"; do
    PAYLOAD=$(printf '{"host":"%s", "platform":"%s", "status":"RECOVERED", "cause":"%s", "container_count":%d, "free_gb":%d, "ts":"%s"}' \
      "$HOST" "$PLATFORM" "$cause" "$CONTAINER_COUNT" "$FREE_GB" "$NOW_ISO")
    emit INFO "$PAYLOAD"
  done
fi

save_state "OK" 0 0 0
exit 0
