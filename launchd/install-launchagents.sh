#!/usr/bin/env bash
# install-launchagents.sh — install/reinstall/remove ez-gh-actions launchd
# plist templates from this directory into ~/Library/LaunchAgents.
#
# Scripts referenced by these plists are NEVER exec'd from this repo/worktree
# checkout — they are copied (install -m 0755) to the stable user-scope
# location ~/.local/libexec/ezgha/ before the plist is rendered, and the
# rendered plist references ONLY that stable path via @SCRIPTS_DIR@. This is
# the uv-tool-install pattern: the repo is source, the libexec dir is what
# actually runs. See bead ez-gh-actions-sa1t (a worktree deletion silently
# killed the watchdog job for ~41h because its plist pointed at a disposable
# worktree path).
#
# Usage:
#   ./launchd/install-launchagents.sh install    # copy scripts + substitute + load all templates
#   ./launchd/install-launchagents.sh remove     # unload + delete all installed plists + libexec dir
#   ./launchd/install-launchagents.sh status     # launchctl list | grep org.jleechanorg.ezgha
set -euo pipefail

REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHD_DIR="${REPO_PATH}/launchd"
TARGET_DIR="${HOME}/Library/LaunchAgents"
SCRIPTS_DIR="${HOME}/.local/libexec/ezgha"

action="${1:-status}"

templates=("${LAUNCHD_DIR}"/*.plist.template)

# Guard: fail loudly if a rendered plist still references a repo/worktree
# checkout path or has an unsubstituted @...@ placeholder left in it. A
# passing guard here is what would have caught the ez-gh-actions-sa1t
# incident (dead watchdog plist pointing at a deleted worktree) at install
# time instead of silently 41h later.
verify_rendered_plist() {
  local dest="$1"
  if grep -q '@[A-Z_]*@' "$dest"; then
    echo "ERROR: ${dest} still contains an unsubstituted @PLACEHOLDER@ — refusing to load it" >&2
    grep -n '@[A-Z_]*@' "$dest" >&2
    return 1
  fi
  if grep -qF "${REPO_PATH}" "$dest"; then
    echo "ERROR: ${dest} references the repo checkout path (${REPO_PATH}) — refusing to load it" >&2
    return 1
  fi
  if grep -qi 'worktree' "$dest"; then
    echo "ERROR: ${dest} references a 'worktree' path — refusing to load it" >&2
    return 1
  fi
  return 0
}

# Guard: every script path a rendered plist points at must exist and be
# executable at the stable install location.
verify_scripts_exist() {
  local dest="$1"
  local script
  while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    if [[ ! -x "$script" ]]; then
      echo "ERROR: ${dest} references ${script}, which does not exist or is not executable" >&2
      return 1
    fi
  done < <(grep -oE "${SCRIPTS_DIR}/[A-Za-z0-9_.-]+\.sh" "$dest" || true)
  return 0
}

install_scripts() {
  mkdir -p "${SCRIPTS_DIR}"
  # *.sh entry points plus *.py helpers they shell out to as siblings (e.g.
  # refresh_gh_app_token.sh -> mint_gh_app_token.py) — both must land in the
  # same flat directory so sibling-relative lookups keep working post-install.
  for script in "${REPO_PATH}"/scripts/*.sh "${REPO_PATH}"/scripts/*.py; do
    [[ -f "$script" ]] || continue
    install -m 0755 "$script" "${SCRIPTS_DIR}/$(basename "$script")"
  done
  echo "scripts installed: ${SCRIPTS_DIR}"
}

case "$action" in
  install)
    install_scripts
    for tmpl in "${templates[@]}"; do
      [[ -f "$tmpl" ]] || continue
      label="$(basename "$tmpl" .plist.template)"
      dest="${TARGET_DIR}/${label}.plist"
      sed -e "s|@HOME@|${HOME}|g" -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" "$tmpl" > "$dest"
      verify_rendered_plist "$dest" || { rm -f "$dest"; exit 1; }
      verify_scripts_exist "$dest" || { rm -f "$dest"; exit 1; }
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
    rm -rf "${SCRIPTS_DIR}"
    echo "removed: ${SCRIPTS_DIR}"
    ;;
  status)
    launchctl list | grep -i "org.jleechanorg.ezgha" || echo "no ezgha launchd jobs loaded"
    ;;
  *)
    echo "usage: $0 {install|remove|status}" >&2
    exit 2
    ;;
esac
