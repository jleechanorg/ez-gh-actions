#!/usr/bin/env bash
# Emit one aggregate-only, local-truth host snapshot for the public dashboard.
set -uo pipefail

HOST_CLASS=""
SERVICE_STATE_ONLY=false
FORCE_PARKED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-class)
      HOST_CLASS="${2:-}"
      shift 2
      ;;
    --service-state)
      SERVICE_STATE_ONLY=true
      shift
      ;;
    --parked)
      FORCE_PARKED=true
      shift
      ;;
    -h|--help)
      echo "usage: $0 --host-class mac|linux [--parked] | --service-state"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
if [[ "$SERVICE_STATE_ONLY" != true && "$HOST_CLASS" != "mac" && "$HOST_CLASS" != "linux" ]]; then
  echo "--host-class must be mac or linux" >&2
  exit 2
fi

CONFIG_FILE="${EZGHA_CONFIG_FILE:-$HOME/.config/ezgha/config.toml}"
STATE_DIR="${EZGHA_WATCHDOG_STATE_DIR:-$HOME/.local/state/ezgha/watchdog}"
SLOT_FILE="${EZGHA_SLOT_FILE:-$HOME/.config/ezgha/slot_assignments.toml}"
DOWN_WAIT_SECONDS="${EZGHA_DASHBOARD_DOWN_WAIT_SECONDS:-30}"
STATE_STALE_SECONDS="${EZGHA_WATCHDOG_STATE_STALE_SECONDS:-480}"
RESPAWN_EVIDENCE_WINDOW_MIN="${EZGHA_DASHBOARD_RESPAWN_WINDOW_MIN:-3}"

read_config() {
  python3 - "$CONFIG_FILE" <<'PY'
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as handle:
        config = tomllib.load(handle)
    count = config["runner"]["count"]
    prefix = config["runner"]["name_prefix"]
    image = config["runner"]["image"]
    disk_floor = config["limits"]["min_free_disk_gb"]
    if type(count) is not int or count <= 0:
        raise ValueError("invalid runner.count")
    if not isinstance(prefix, str) or not prefix:
        raise ValueError("invalid runner.name_prefix")
    if not isinstance(image, str) or not image:
        raise ValueError("invalid runner.image")
    if type(disk_floor) is not int or disk_floor < 0:
        raise ValueError("invalid limits.min_free_disk_gb")
except (OSError, KeyError, TypeError, ValueError, tomllib.TOMLDecodeError):
    raise SystemExit(1)
print(count)
print(prefix)
print(disk_floor)
PY
}

count_assignments() {
  awk '
    /^[[:space:]]*\[assignments\][[:space:]]*$/ { inside=1; next }
    /^[[:space:]]*\[/ { if (inside) exit }
    inside && /^[[:space:]]*[^#[:space:]][^=]*=/ { count++ }
    END { print count + 0 }
  ' "$SLOT_FILE" 2>/dev/null
}

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

parse_bsd_boottime() {
  sed -E 's/^[{ ]*sec *= *([0-9]+).*/\1/'
}

boot_time() {
  local value=""
  if [[ -r /proc/stat ]]; then
    value="$(awk '/^btime / { print $2; exit }' /proc/stat 2>/dev/null || true)"
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    value="$(sysctl -n kern.boottime 2>/dev/null | parse_bsd_boottime || true)"
  fi
  [[ "$value" =~ ^[0-9]+$ ]] && echo "$value"
}

BOOT_TIME="$(boot_time)"

read_fresh_uint() {
  local file="$1" mtime now value
  [[ -f "$file" ]] || return 1
  mtime="$(file_mtime "$file")"
  now="$(date +%s)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  (( mtime <= now )) || return 1
  if [[ "$BOOT_TIME" =~ ^[0-9]+$ ]] && (( mtime < BOOT_TIME )); then
    return 1
  fi
  (( now - mtime <= STATE_STALE_SECONDS )) || return 1
  value="$(cat "$file" 2>/dev/null)" || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  echo "$value"
}

probe_service_state() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local line pid status
    line="$(launchctl list 2>/dev/null | awk '$3 == "org.jleechanorg.ezgha" { print; exit }')"
    if [[ -z "$line" ]]; then
      echo "not-loaded"
      return
    fi
    pid="$(awk '{ print $1 }' <<<"$line")"
    status="$(awk '{ print $2 }' <<<"$line")"
    if [[ -n "$pid" && "$pid" != "-" ]]; then
      echo "active"
    elif [[ "$status" == "0" ]]; then
      echo "inactive"
    else
      echo "failed"
    fi
  elif [[ "$(uname -s)" == "Linux" ]]; then
    local state
    state="$(systemctl --user is-active ezgha.service 2>/dev/null || true)"
    case "$state" in
      active|inactive|failed) echo "$state" ;;
      *) echo "inactive" ;;
    esac
  else
    echo "unsupported"
  fi
}

if [[ "$SERVICE_STATE_ONLY" == true ]]; then
  probe_service_state
  exit 0
fi

classify_slot() {
  local name="$1" running table
  running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    echo "DOWN"
    return 0
  fi
  if ! table="$(docker top "$name" -eo pid,comm 2>/dev/null)"; then
    return 1
  fi
  if grep -Eq 'Runner\.Worker|[[:space:]]Worker$' <<<"$table"; then
    echo "EXECUTING"
  elif grep -Eq 'Runner\.Listener|[[:space:]]Listener$' <<<"$table"; then
    echo "IDLE"
  else
    return 1
  fi
}

recent_respawn_evidence() {
  local name="$1" logs=""
  if [[ "$(uname -s)" == "Linux" ]]; then
    logs="$(journalctl --user -u ezgha.service --since "$RESPAWN_EVIDENCE_WINDOW_MIN minutes ago" --no-pager 2>/dev/null || true)"
  else
    # The macOS launchd log has no reliably parseable timestamps. Historical
    # respawn lines must not downgrade a persistently missing fleet to cycling.
    return 1
  fi
  grep -q "respawned ephemeral runner $name$" <<<"$logs"
}

CONFIG_OK=false
TARGET=""
PREFIX=""
DISK_FLOOR_GB=""
config_output="$(read_config 2>/dev/null || true)"
if [[ "$(printf '%s\n' "$config_output" | awk 'NF { count++ } END { print count + 0 }')" -eq 3 ]]; then
  TARGET="$(printf '%s\n' "$config_output" | sed -n '1p')"
  PREFIX="$(printf '%s\n' "$config_output" | sed -n '2p')"
  DISK_FLOOR_GB="$(printf '%s\n' "$config_output" | sed -n '3p')"
  CONFIG_OK=true
fi

PARKED=false
PARKED_REASON=""
PARKED_SLOTS=0
if [[ "$FORCE_PARKED" == true ]]; then
  PARKED=true
elif [[ "$HOST_CLASS" == "mac" && "${MAC_RUNNER_DISABLED:-0}" == "1" ]]; then
  PARKED=true
elif [[ "$HOST_CLASS" == "linux" && "${REMOTE_LINUX_DISABLED:-0}" == "1" ]]; then
  PARKED=true
fi

SERVICE_OK=false
[[ "$(probe_service_state)" == "active" ]] && SERVICE_OK=true

DOCKER_OK=false
PROCESS_OK=false
EXECUTING=""
IDLE=""
CYCLING=""
DOWN=""
RESERVED=""
SLOTS_META=""

slot_phase_and_elapsed() {
  local name="$1" state="$2" detail_table=""
  if [[ "$state" != "EXECUTING" ]]; then
    printf '\t\n'
    return 0
  fi
  detail_table="$(docker top "$name" -eo pid,etimes,comm,args 2>/dev/null || true)"
  python3 - "$detail_table" <<'PY'
import re
import sys

table = sys.argv[1]
elapsed_s = None
phase = ""
phase_rules = (
    ("playwright", r"playwright"),
    ("jest", r"\bjest\b"),
    ("pytest", r"\bpytest\b"),
    ("git index-pack", r"git\s+index-pack"),
    ("git fetch", r"git\b.*\bfetch\b"),
    ("gh api tarball", r"gh\s+api.*tarball"),
    ("npm ci", r"\bnpm\s+ci\b"),
    ("pip", r"\bpip3?\s+install\b"),
    ("cargo", r"\bcargo\b"),
    ("gcloud", r"\bgcloud\b"),
    ("mypy", r"\bmypy\b"),
    ("setup-python", r"setup-python"),
)
for line in table.splitlines()[1:]:
    parts = line.strip().split(None, 3)
    if len(parts) < 3:
        continue
    if "Runner.Worker" in line and parts[1].isdigit():
        elapsed_s = int(parts[1])
    rest = parts[3] if len(parts) == 4 else parts[2]
    for label, pat in phase_rules:
        if re.search(pat, rest, re.IGNORECASE):
            phase = label
            break
elapsed_min = round(elapsed_s / 60.0, 1) if elapsed_s is not None else ""
print(f"{elapsed_min}\t{phase}")
PY
}

if [[ "$PARKED" == true && "$CONFIG_OK" == true ]]; then
  PARKED_REASON="operator_disabled"
  PARKED_SLOTS="$TARGET"
  SERVICE_OK=true
  DOCKER_OK=true
  PROCESS_OK=true
  EXECUTING=0
  IDLE=0
  CYCLING=0
  DOWN=0
  RESERVED=0
  for ((slot=1; slot<=TARGET; slot++)); do
    SLOTS_META+="${slot}|PARKED||operator_disabled"$'\n'
  done
elif [[ "$CONFIG_OK" == true ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_OK=true
  PROCESS_OK=true
  EXECUTING=0
  IDLE=0
  CYCLING=0
  DOWN=0
  RESERVED="$(count_assignments)"
  [[ "$RESERVED" =~ ^[0-9]+$ ]] || RESERVED=""

  down_candidates=()
  declare -a slot_states=()
  declare -a slot_elapsed=()
  declare -a slot_phase=()
  for ((slot=1; slot<=TARGET; slot++)); do
    name="${PREFIX}-${slot}"
    if ! state="$(classify_slot "$name")"; then
      PROCESS_OK=false
      break
    fi
    slot_states[slot]="$state"
    slot_elapsed[slot]=""
    slot_phase[slot]=""
    case "$state" in
      EXECUTING)
        EXECUTING=$((EXECUTING + 1))
        meta="$(slot_phase_and_elapsed "$name" "EXECUTING" 2>/dev/null || true)"
        slot_elapsed[slot]="${meta%%$'\t'*}"
        slot_phase[slot]="${meta#*$'\t'}"
        ;;
      IDLE) IDLE=$((IDLE + 1)) ;;
      DOWN) down_candidates+=("$slot:$name") ;;
    esac
  done

  if [[ "$PROCESS_OK" == true && "${#down_candidates[@]}" -gt 0 ]]; then
    sleep "$DOWN_WAIT_SECONDS"
    for entry in "${down_candidates[@]}"; do
      slot="${entry%%:*}"
      name="${entry#*:}"
      if ! state="$(classify_slot "$name")"; then
        PROCESS_OK=false
        break
      fi
      slot_states[slot]="$state"
      case "$state" in
        EXECUTING)
          EXECUTING=$((EXECUTING + 1))
          meta="$(slot_phase_and_elapsed "$name" "EXECUTING" 2>/dev/null || true)"
          slot_elapsed[slot]="${meta%%$'\t'*}"
          slot_phase[slot]="${meta#*$'\t'}"
          ;;
        IDLE) IDLE=$((IDLE + 1)) ;;
        DOWN)
          if recent_respawn_evidence "$name"; then
            CYCLING=$((CYCLING + 1))
            slot_states[slot]="CYCLING"
            slot_phase[slot]="respawning"
          else
            DOWN=$((DOWN + 1))
          fi
          ;;
      esac
    done
  fi

  if [[ "$PROCESS_OK" == true ]]; then
    for ((slot=1; slot<=TARGET; slot++)); do
      SLOTS_META+="${slot}|${slot_states[$slot]}|${slot_elapsed[$slot]}|${slot_phase[$slot]}"$'\n'
    done
  fi
fi

if [[ "$PROCESS_OK" != true ]]; then
  EXECUTING=""
  IDLE=""
  CYCLING=""
  DOWN=""
  SLOTS_META=""
fi

DISK_OK=false
DISK_STATUS="unknown"
DISK_FREE_GB=""
if [[ "$CONFIG_OK" == true ]]; then
  DISK_OUTPUT=""
  HOST_DISK_OUTPUT=""
  HOST_DISK_PATH="/"
  HOST_DISK_FLOOR_GB="$DISK_FLOOR_GB"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    HOST_DISK_PATH="/System/Volumes/Data"
    # No Mac-specific floor bump here: src/docker_backend.rs removed the
    # hardcoded 40GB Mac host floor (see commit f388a8b, "honor configured
    # Mac disk floor") after it flapped the fleet all day 2026-07-14 — the
    # 926GB Mac host's steady-state free space (35-46GB) sits inside a 40GB
    # floor. The configured limits.min_free_disk_gb is the sole admission
    # floor on every platform now; 40GB survives only as a warning-only
    # pressure-alert threshold (MACOS_HOST_DISK_PRESSURE_ALERT_GB) that does
    # not gate admission and this dashboard does not need to mirror.
  fi
  DAEMON_DISK_CONTAINER=""
  if [[ "$DOCKER_OK" == true && "$PARKED" != true ]]; then
    for ((slot=1; slot<=TARGET; slot++)); do
      candidate="${PREFIX}-${slot}"
      if [[ "$(docker inspect -f '{{.State.Running}}' "$candidate" 2>/dev/null || true)" == "true" ]]; then
        DAEMON_DISK_CONTAINER="$candidate"
        break
      fi
    done
  fi
  if [[ -n "$DAEMON_DISK_CONTAINER" ]] && \
    DISK_OUTPUT="$(docker exec "$DAEMON_DISK_CONTAINER" df -Pk / 2>/dev/null)"; then
    DAEMON_FREE_KB="$(awk 'NR == 2 { print $4 }' <<<"$DISK_OUTPUT")"
  else
    DAEMON_FREE_KB=""
  fi
  if HOST_DISK_OUTPUT="$(df -Pk "$HOST_DISK_PATH" 2>/dev/null)"; then
    HOST_FREE_KB="$(awk 'NR == 2 { print $4 }' <<<"$HOST_DISK_OUTPUT")"
  else
    HOST_FREE_KB=""
  fi
  if [[ "$DAEMON_FREE_KB" =~ ^[0-9]+$ && "$HOST_FREE_KB" =~ ^[0-9]+$ ]]; then
    DISK_OK=true
    MIN_FREE_KB="$DAEMON_FREE_KB"
    (( HOST_FREE_KB < MIN_FREE_KB )) && MIN_FREE_KB="$HOST_FREE_KB"
    DISK_FREE_GB="$(awk -v kb="$MIN_FREE_KB" 'BEGIN { printf "%.1f", kb / 1048576 }')"
    if (( DAEMON_FREE_KB >= DISK_FLOOR_GB * 1024 * 1024 &&
      HOST_FREE_KB >= HOST_DISK_FLOOR_GB * 1024 * 1024 )); then
      DISK_STATUS="healthy"
    else
      DISK_STATUS="critical"
    fi
  elif [[ "$PARKED" == true && "$HOST_FREE_KB" =~ ^[0-9]+$ ]]; then
    DISK_OK=true
    DISK_FREE_GB="$(awk -v kb="$HOST_FREE_KB" 'BEGIN { printf "%.1f", kb / 1048576 }')"
    if (( HOST_FREE_KB >= HOST_DISK_FLOOR_GB * 1024 * 1024 )); then
      DISK_STATUS="healthy"
    else
      DISK_STATUS="critical"
    fi
  fi
fi

PAUSE_REASON=""
if [[ "$PARKED" == true ]]; then
  PAUSE_REASON="operator_disabled"
elif [[ "$DISK_STATUS" == "critical" && "${DOWN:-0}" =~ ^[0-9]+$ && "${DOWN:-0}" -gt 0 ]]; then
  PAUSE_REASON="disk_floor_paused"
fi

WATCHDOG_OK=false
WATCHDOG_MISSES=""
WATCHDOG_THRESHOLD=""
if WATCHDOG_MISSES="$(read_fresh_uint "$STATE_DIR/$HOST_CLASS.miss_count")" && \
  WATCHDOG_THRESHOLD="$(read_fresh_uint "$STATE_DIR/$HOST_CLASS.miss_threshold")" && \
  [[ "$WATCHDOG_THRESHOLD" =~ ^[1-9][0-9]*$ ]]; then
  WATCHDOG_OK=true
fi
if [[ "$WATCHDOG_OK" != true ]]; then
  # The `&&` chain above can partially succeed (e.g. miss_count reads fine
  # but miss_threshold is missing/stale) and still leave WATCHDOG_MISSES set
  # from its own successful assignment before the chain short-circuits. Per
  # the snapshot builder's explicit-degraded-telemetry contract, a not-ok
  # watchdog_state source must report both fields as null/absent — a
  # half-filled telemetry pair (numbers with unknown ok=false) is exactly
  # the inconsistent state that made a healthy 10/10 linux fleet on
  # jeff-ubuntu (miss_count present, miss_threshold file missing) fail
  # snapshot validity.
  WATCHDOG_MISSES=""
  WATCHDOG_THRESHOLD=""
fi

HOST_CLASS="$HOST_CLASS" TARGET="$TARGET" EXECUTING="$EXECUTING" IDLE="$IDLE" \
CYCLING="$CYCLING" DOWN="$DOWN" RESERVED="$RESERVED" DISK_STATUS="$DISK_STATUS" \
DISK_FREE_GB="$DISK_FREE_GB" DISK_FLOOR_GB="$DISK_FLOOR_GB" \
PARKED="$PARKED" PARKED_SLOTS="$PARKED_SLOTS" PARKED_REASON="$PARKED_REASON" \
PAUSE_REASON="$PAUSE_REASON" SLOTS_META="$SLOTS_META" \
WATCHDOG_MISSES="$WATCHDOG_MISSES" WATCHDOG_THRESHOLD="$WATCHDOG_THRESHOLD" \
CONFIG_OK="$CONFIG_OK" SERVICE_OK="$SERVICE_OK" \
DOCKER_OK="$DOCKER_OK" PROCESS_OK="$PROCESS_OK" DISK_OK="$DISK_OK" WATCHDOG_OK="$WATCHDOG_OK" \
python3 - <<'PY'
import json
import os

def count(name):
    value = os.environ.get(name, "")
    return int(value) if value.isdigit() else None

def opt_float(name):
    value = os.environ.get(name, "")
    try:
        return float(value) if value else None
    except ValueError:
        return None

host_class = os.environ["HOST_CLASS"]
pause_reason = os.environ.get("PAUSE_REASON") or None
slots = []
for raw in os.environ.get("SLOTS_META", "").splitlines():
    if not raw.strip():
        continue
    parts = raw.split("|")
    if len(parts) < 4:
        continue
    slot_num = int(parts[0])
    state = parts[1]
    elapsed = float(parts[2]) if parts[2] else None
    phase = parts[3] or ("disk_floor_paused" if state == "DOWN" and pause_reason == "disk_floor_paused" else None)
    slots.append({
        "slot_id": f"{host_class}-{slot_num}",
        "slot": slot_num,
        "state": state,
        "elapsed_minutes": elapsed,
        "phase_badge": phase,
    })

free_gb = opt_float("DISK_FREE_GB")
floor_gb = count("DISK_FLOOR_GB")

payload = {
    "schema_version": 1,
    "host_class": host_class,
    "parked": os.environ["PARKED"] == "true",
    "parked_slots": count("PARKED_SLOTS") or 0,
    "parked_reason": os.environ.get("PARKED_REASON") or None,
    "pause_reason": pause_reason,
    "sources": {
        "config": {"ok": os.environ["CONFIG_OK"] == "true"},
        "service": {"ok": os.environ["SERVICE_OK"] == "true"},
        "docker": {"ok": os.environ["DOCKER_OK"] == "true"},
        "process_probe": {"ok": os.environ["PROCESS_OK"] == "true"},
        "disk": {"ok": os.environ["DISK_OK"] == "true"},
        "watchdog_state": {"ok": os.environ["WATCHDOG_OK"] == "true"},
    },
    "fleet": {
        "configured": count("TARGET"),
        "executing": count("EXECUTING"),
        "idle": count("IDLE"),
        "cycling": count("CYCLING"),
        "down": count("DOWN"),
        "reserved": count("RESERVED"),
    },
    "disk": {"status": os.environ["DISK_STATUS"]},
    "disk_free_gb": free_gb,
    "disk_floor_gb": floor_gb,
    "watchdog": {
        "consecutive_misses": count("WATCHDOG_MISSES"),
        "restart_after": count("WATCHDOG_THRESHOLD"),
    },
    "slots": slots,
}
print(json.dumps(payload, sort_keys=True))
PY
