#!/usr/bin/env bash
# install-host-health-alert-cron.sh — install/refresh the Linux-side cron entry for
# scripts/ezgha-host-health-alert.sh.
#
# Why this exists (bead jleechan-v8ms): the Linux half of the mutual host-health
# monitor was hand-installed in jeff-ubuntu's crontab, so no fresh machine would
# reproduce it — the repo's "no orphaned one-off fixes" rule requires the wiring to
# live in a git-tracked installer. The macOS half is the launchd agent
# `launchd/org.jleechanorg.ezgha-host-health-alert.plist.template`.
#
# The crontab is edited by marker: only lines containing this script's filename are
# replaced or removed; every other line is preserved byte-for-byte.
#
# Usage:
#   ./scripts/install-host-health-alert-cron.sh            # install/refresh
#   ./scripts/install-host-health-alert-cron.sh --dry-run  # print the plan
#   ./scripts/install-host-health-alert-cron.sh --remove   # uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/ezgha-host-health-alert.sh"
MARKER="ezgha-host-health-alert.sh"
SCHEDULE="${HOST_HEALTH_ALERT_SCHEDULE:-*/2 * * * *}"
PATH_PREFIX="${HOST_HEALTH_ALERT_PATH:-$HOME/google-cloud-sdk/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin}"
LOG_FILE="${HOST_HEALTH_ALERT_LOG:-/tmp/ezgha-host-health-alert.log}"

DRY_RUN=0
REMOVE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --remove) REMOVE=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 64 ;;
  esac
done

if [ ! -x "$TARGET" ]; then
  echo "FATAL: $TARGET missing or not executable" >&2
  exit 3
fi

CURRENT="$(crontab -l 2>/dev/null || true)"
KEPT="$(printf '%s\n' "$CURRENT" | grep -v -F "$MARKER" || true)"

if [ "$REMOVE" -eq 1 ]; then
  NEW="$KEPT"
  ACTION="remove"
else
  LINE="$SCHEDULE PATH=$PATH_PREFIX $TARGET >> $LOG_FILE 2>&1"
  if [ -n "$KEPT" ]; then
    NEW="$KEPT
$LINE"
  else
    NEW="$LINE"
  fi
  ACTION="install"
fi

# Trim leading blank lines produced when the previous crontab was empty.
NEW="$(printf '%s\n' "$NEW" | sed '/^[[:space:]]*$/d')"

if [ "$ACTION" = "install" ] && [ -z "$NEW" ]; then
  echo "FATAL: refusing to install an empty crontab" >&2
  exit 4
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would $ACTION this crontab:"
  printf '%s\n' "$NEW"
  exit 0
fi

printf '%s\n' "$NEW" | crontab -
echo "cron entry: $ACTION for $TARGET"
crontab -l 2>/dev/null | grep -F "$MARKER" || true
