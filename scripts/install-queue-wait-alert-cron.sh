#!/usr/bin/env bash
# install-queue-wait-alert-cron.sh — install/refresh the cron entry for scripts/queue-wait-alert.sh
# (every 5 min). Only lines containing the script's filename are replaced; other crontab lines are
# preserved. Usage: ./scripts/install-queue-wait-alert-cron.sh [--dry-run|--remove]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/queue-wait-alert.sh"
MARKER="queue-wait-alert.sh"
SCHEDULE="${QUEUE_WAIT_ALERT_SCHEDULE:-*/5 * * * *}"
PATH_PREFIX="${QUEUE_WAIT_ALERT_PATH:-$HOME/google-cloud-sdk/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin}"
MAC_OFF="${QUEUE_WAIT_ALERT_MAC_DISABLED:-1}" # Mac fleet parked (bead jleechan-hxz0); set 0 when restored
LOG_FILE="${QUEUE_WAIT_ALERT_LOG:-$HOME/.local/state/ezgha/queue-wait-alert.log}"
DRY_RUN=0 REMOVE=0
for arg in "$@"; do
  case "$arg" in --dry-run) DRY_RUN=1 ;; --remove) REMOVE=1 ;; *) echo "unknown arg: $arg" >&2; exit 64 ;; esac
done
if [ "$REMOVE" -eq 0 ]; then
  [ -r "$SCRIPT_DIR/queue_wait_discovery.py" ] || { echo "FATAL: queue_wait_discovery.py must be installed beside $TARGET" >&2; exit 3; }
  command -v python3 >/dev/null || { echo "FATAL: python3 is required for queued-job discovery" >&2; exit 3; }
  command -v jq >/dev/null || { echo "FATAL: jq is required for queued-job evidence" >&2; exit 3; }
fi
[ -x "$TARGET" ] || { echo "FATAL: $TARGET missing or not executable" >&2; exit 3; }
# A transient crontab failure must not make us rewrite the crontab from nothing (that would drop the host-health cron).
CURRENT="$(crontab -l 2>&1)" || case "$CURRENT" in *"no crontab"*) CURRENT="" ;; *) echo "FATAL: crontab -l failed: $CURRENT" >&2; exit 5 ;; esac
KEPT="$(printf '%s\n' "$CURRENT" | grep -v -F "$MARKER" || true)"
if [ "$REMOVE" -eq 1 ]; then NEW="$KEPT"; ACTION=remove
else NEW="$(printf '%s\n%s\n' "$KEPT" "$SCHEDULE MAC_RUNNER_DISABLED=$MAC_OFF PATH=$PATH_PREFIX $TARGET >> $LOG_FILE 2>&1")"; ACTION=install; fi
NEW="$(printf '%s\n' "$NEW" | sed '/^[[:space:]]*$/d')"
if [ "$ACTION" = install ] && [ -z "$NEW" ]; then echo "FATAL: refusing to install an empty crontab" >&2; exit 4; fi
if [ "$DRY_RUN" -eq 1 ]; then echo "[dry-run] would $ACTION this crontab:"; printf '%s\n' "$NEW"; exit 0; fi
mkdir -p "$(dirname "$LOG_FILE")"
printf '%s\n' "$NEW" | crontab -
echo "cron entry: $ACTION for $TARGET"
crontab -l 2>/dev/null | grep -F "$MARKER" || true
