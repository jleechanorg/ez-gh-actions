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
LOG_FILE="${QUEUE_WAIT_ALERT_LOG:-$HOME/.local/state/ezgha/queue-wait-alert.log}"
DRY_RUN=0 REMOVE=0
for arg in "$@"; do
  case "$arg" in --dry-run) DRY_RUN=1 ;; --remove) REMOVE=1 ;; *) echo "unknown arg: $arg" >&2; exit 64 ;; esac
done
[ -x "$TARGET" ] || { echo "FATAL: $TARGET missing or not executable" >&2; exit 3; }
KEPT="$(crontab -l 2>/dev/null | grep -v -F "$MARKER" || true)"
if [ "$REMOVE" -eq 1 ]; then NEW="$KEPT"; ACTION=remove
else NEW="$(printf '%s\n%s\n' "$KEPT" "$SCHEDULE PATH=$PATH_PREFIX $TARGET >> $LOG_FILE 2>&1")"; ACTION=install; fi
NEW="$(printf '%s\n' "$NEW" | sed '/^[[:space:]]*$/d')"
if [ "$ACTION" = install ] && [ -z "$NEW" ]; then echo "FATAL: refusing to install an empty crontab" >&2; exit 4; fi
if [ "$DRY_RUN" -eq 1 ]; then echo "[dry-run] would $ACTION this crontab:"; printf '%s\n' "$NEW"; exit 0; fi
mkdir -p "$(dirname "$LOG_FILE")"
printf '%s\n' "$NEW" | crontab -
echo "cron entry: $ACTION for $TARGET"
crontab -l 2>/dev/null | grep -F "$MARKER" || true
