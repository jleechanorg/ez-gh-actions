#!/usr/bin/env bash
# install-launchagents.sh — install/reinstall/remove ez-gh-actions launchd
# plist templates from this directory into ~/Library/LaunchAgents.
#
# Usage:
#   ./launchd/install-launchagents.sh install    # substitute + load all templates
#   ./launchd/install-launchagents.sh remove     # unload + delete all installed plists
#   ./launchd/install-launchagents.sh status     # launchctl list | grep org.jleechanorg.ezgha
set -euo pipefail

REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHD_DIR="${REPO_PATH}/launchd"
TARGET_DIR="${HOME}/Library/LaunchAgents"

action="${1:-status}"

templates=("${LAUNCHD_DIR}"/*.plist.template)

case "$action" in
  install)
    for tmpl in "${templates[@]}"; do
      [[ -f "$tmpl" ]] || continue
      label="$(basename "$tmpl" .plist.template)"
      dest="${TARGET_DIR}/${label}.plist"
      sed -e "s|@HOME@|${HOME}|g" -e "s|@REPO_PATH@|${REPO_PATH}|g" "$tmpl" > "$dest"
      echo "installed: $dest"
      launchctl unload "$dest" 2>/dev/null || true
      launchctl load "$dest"
      echo "loaded: $label"
    done
    ;;
  remove)
    for tmpl in "${templates[@]}"; do
      [[ -f "$tmpl" ]] || continue
      label="$(basename "$tmpl" .plist.template)"
      dest="${TARGET_DIR}/${label}.plist"
      if [[ -f "$dest" ]]; then
        launchctl unload "$dest" 2>/dev/null || true
        rm -f "$dest"
        echo "removed: $dest"
      fi
    done
    ;;
  status)
    launchctl list | grep -i "org.jleechanorg.ezgha" || echo "no ezgha launchd jobs loaded"
    ;;
  *)
    echo "usage: $0 {install|remove|status}" >&2
    exit 2
    ;;
esac
