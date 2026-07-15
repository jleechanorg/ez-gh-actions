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
DASHBOARD_DIR="${SCRIPTS_DIR}/dashboard"
STATE_DIR="${HOME}/.local/state/ezgha"
DASHBOARD_LABEL="org.jleechanorg.ezgha-runner-dashboard"
DASHBOARD_SCRIPTS=(
  publish_runner_dashboard.sh
  runner_dashboard_host_probe.sh
  build_runner_dashboard_snapshot.py
)
DASHBOARD_ASSETS=(index.html style.css dashboard.js)
DASHBOARD_TRANSACTION_ACTIVE=false
DASHBOARD_PAYLOAD_BACKUP=""
DASHBOARD_PLIST_DEST=""
DASHBOARD_PLIST_CANDIDATE=""
DASHBOARD_PLIST_BACKUP=""
DASHBOARD_HAD_PRIOR=0
DASHBOARD_PRIOR_UNLOADED=false
DASHBOARD_REPLACEMENT_INSTALLED=false

action="${1:-status}"
label_filter="${2:-}"

templates=("${LAUNCHD_DIR}"/*.plist.template)
if [[ "$action" == "install" && -n "$label_filter" ]]; then
  templates=("${LAUNCHD_DIR}/${label_filter}.plist.template")
  if [[ ! -f "${templates[0]}" ]]; then
    echo "ERROR: unknown launchd template label: ${label_filter}" >&2
    exit 2
  fi
fi

# Guard: fail loudly if a rendered plist still references a repo/worktree
# checkout path or has an unsubstituted @...@ placeholder left in it. A
# passing guard here is what would have caught the ez-gh-actions-sa1t
# incident (dead watchdog plist pointing at a deleted worktree) at install
# time instead of silently 41h later.
#
# The path/worktree checks scan the rendered file with XML comment blocks
# stripped first, so a template's own explanatory <!-- ... --> prose (e.g.
# this very script's templates document why they use @SCRIPTS_DIR@ "NOT a
# repo/worktree checkout path") can't trip the guard on itself. Only actual
# <string> values are checked.
verify_rendered_plist() {
  local dest="$1"
  local scanned
  scanned="$(sed '/<!--/,/-->/d' "$dest")"
  if grep -q '@[A-Z_]*@' <<<"$scanned"; then
    echo "ERROR: ${dest} still contains an unsubstituted @PLACEHOLDER@ — refusing to load it" >&2
    grep -n '@[A-Z_]*@' "$dest" >&2
    return 1
  fi
  if grep -qF "${REPO_PATH}" <<<"$scanned"; then
    echo "ERROR: ${dest} references the repo checkout path (${REPO_PATH}) — refusing to load it" >&2
    return 1
  fi
  if grep -qi 'worktree' <<<"$scanned"; then
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
  mkdir -p "${SCRIPTS_DIR}" "${DASHBOARD_DIR}" "${STATE_DIR}"
  chmod 0700 "${STATE_DIR}"
  if [[ "$label_filter" == "$DASHBOARD_LABEL" ]]; then
    for name in "${DASHBOARD_SCRIPTS[@]}"; do
      install -m 0755 "${REPO_PATH}/scripts/${name}" "${SCRIPTS_DIR}/${name}"
    done
    for name in "${DASHBOARD_ASSETS[@]}"; do
      install -m 0644 "${REPO_PATH}/dashboard/${name}" "${DASHBOARD_DIR}/${name}"
    done
    echo "dashboard payload installed: ${SCRIPTS_DIR}"
    return
  fi
  # *.sh entry points plus *.py helpers they shell out to as siblings (e.g.
  # refresh_gh_app_token.sh -> mint_gh_app_token.py) — both must land in the
  # same flat directory so sibling-relative lookups keep working post-install.
  for script in "${REPO_PATH}"/scripts/*.sh "${REPO_PATH}"/scripts/*.py; do
    [[ -f "$script" ]] || continue
    install -m 0755 "$script" "${SCRIPTS_DIR}/$(basename "$script")"
  done
  for asset in index.html style.css dashboard.js; do
    install -m 0644 "${REPO_PATH}/dashboard/${asset}" "${DASHBOARD_DIR}/${asset}"
  done
  echo "scripts installed: ${SCRIPTS_DIR}"
}

backup_dashboard_payload() {
  mkdir -p "${SCRIPTS_DIR}" "${DASHBOARD_DIR}" "${STATE_DIR}"
  chmod 0700 "${STATE_DIR}"
  DASHBOARD_PAYLOAD_BACKUP="$(
    mktemp -d "${STATE_DIR}/.runner-dashboard-backup.XXXXXX"
  )"
  mkdir -p "${DASHBOARD_PAYLOAD_BACKUP}/dashboard"
  for name in "${DASHBOARD_SCRIPTS[@]}"; do
    [[ ! -f "${SCRIPTS_DIR}/${name}" ]] || \
      cp -p "${SCRIPTS_DIR}/${name}" "${DASHBOARD_PAYLOAD_BACKUP}/${name}"
  done
  for name in "${DASHBOARD_ASSETS[@]}"; do
    [[ ! -f "${DASHBOARD_DIR}/${name}" ]] || \
      cp -p "${DASHBOARD_DIR}/${name}" "${DASHBOARD_PAYLOAD_BACKUP}/dashboard/${name}"
  done
  DASHBOARD_TRANSACTION_ACTIVE=true
}

restore_dashboard_payload() {
  local name
  for name in "${DASHBOARD_SCRIPTS[@]}"; do
    rm -f "${SCRIPTS_DIR}/${name}"
    [[ ! -f "${DASHBOARD_PAYLOAD_BACKUP}/${name}" ]] || \
      cp -p "${DASHBOARD_PAYLOAD_BACKUP}/${name}" "${SCRIPTS_DIR}/${name}"
  done
  for name in "${DASHBOARD_ASSETS[@]}"; do
    rm -f "${DASHBOARD_DIR}/${name}"
    [[ ! -f "${DASHBOARD_PAYLOAD_BACKUP}/dashboard/${name}" ]] || \
      cp -p "${DASHBOARD_PAYLOAD_BACKUP}/dashboard/${name}" "${DASHBOARD_DIR}/${name}"
  done
}

rollback_dashboard_install() {
  local rc=$?
  trap - EXIT
  if [[ "${DASHBOARD_TRANSACTION_ACTIVE}" == true ]]; then
    restore_dashboard_payload
    [[ -z "${DASHBOARD_PLIST_CANDIDATE}" ]] || rm -f "${DASHBOARD_PLIST_CANDIDATE}"
    if [[ "${DASHBOARD_REPLACEMENT_INSTALLED}" == true ]]; then
      rm -f "${DASHBOARD_PLIST_DEST}"
    fi
    if [[ "${DASHBOARD_HAD_PRIOR}" -eq 1 && -f "${DASHBOARD_PLIST_BACKUP}" ]]; then
      mv "${DASHBOARD_PLIST_BACKUP}" "${DASHBOARD_PLIST_DEST}"
      if [[ "${DASHBOARD_PRIOR_UNLOADED}" == true ]]; then
        launchctl load "${DASHBOARD_PLIST_DEST}" || \
          echo "ERROR: restored prior plist but could not reload it: ${DASHBOARD_PLIST_DEST}" >&2
      fi
    fi
    [[ -z "${DASHBOARD_PLIST_BACKUP}" ]] || rm -f "${DASHBOARD_PLIST_BACKUP}"
    rm -rf "${DASHBOARD_PAYLOAD_BACKUP}"
  fi
  exit "${rc}"
}

commit_dashboard_install() {
  rm -f "${DASHBOARD_PLIST_BACKUP}"
  rm -rf "${DASHBOARD_PAYLOAD_BACKUP}"
  DASHBOARD_TRANSACTION_ACTIVE=false
}

case "$action" in
  install)
    for tmpl in "${templates[@]}"; do
      if [[ "$(basename "$tmpl" .plist.template)" == "${DASHBOARD_LABEL}" ]]; then
        backup_dashboard_payload
        trap rollback_dashboard_install EXIT
        break
      fi
    done
    install_scripts
    for tmpl in "${templates[@]}"; do
      [[ -f "$tmpl" ]] || continue
      label="$(basename "$tmpl" .plist.template)"
      dest="${TARGET_DIR}/${label}.plist"
      candidate="${dest}.candidate.$$"
      backup="${dest}.backup.$$"
      had_prior=0
      if [[ "${label}" == "${DASHBOARD_LABEL}" ]]; then
        DASHBOARD_PLIST_DEST="${dest}"
        DASHBOARD_PLIST_CANDIDATE="${candidate}"
        DASHBOARD_PLIST_BACKUP="${backup}"
      fi
      sed -e "s|@HOME@|${HOME}|g" -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" "$tmpl" > "$candidate"
      if [[ "${label}" == "${DASHBOARD_LABEL}" && -n "${DOCKER_HOST_OVERRIDE:-}" ]]; then
        python3 - "$candidate" "$DOCKER_HOST_OVERRIDE" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = plistlib.loads(path.read_bytes())
payload["EnvironmentVariables"]["DOCKER_HOST"] = sys.argv[2]
with path.open("wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY
      fi
      verify_rendered_plist "$candidate" || { rm -f "$candidate"; exit 1; }
      verify_scripts_exist "$candidate" || { rm -f "$candidate"; exit 1; }
      if [[ -f "$dest" ]]; then
        cp -p "$dest" "$backup"
        had_prior=1
        if launchctl unload "$dest" 2>/dev/null; then
          [[ "${label}" != "${DASHBOARD_LABEL}" ]] || DASHBOARD_PRIOR_UNLOADED=true
        fi
      fi
      if [[ "${label}" == "${DASHBOARD_LABEL}" ]]; then
        DASHBOARD_HAD_PRIOR="${had_prior}"
      fi
      mv "$candidate" "$dest"
      [[ "${label}" != "${DASHBOARD_LABEL}" ]] || DASHBOARD_REPLACEMENT_INSTALLED=true
      echo "installed: $dest"
      launchctl load "$dest" || {
        rc=$?
        if [[ "${label}" == "${DASHBOARD_LABEL}" ]]; then
          exit "$rc"
        fi
        rm -f "$dest"
        if [[ "$had_prior" -eq 1 ]]; then
          mv "$backup" "$dest"
          launchctl load "$dest" || \
            echo "ERROR: restored prior plist but could not reload it: $dest" >&2
        fi
        exit "$rc"
      }
      rm -f "$backup"
      if [[ "${label}" == "${DASHBOARD_LABEL}" ]]; then
        commit_dashboard_install
      fi
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
    echo "usage: $0 {install [label]|remove|status}" >&2
    exit 2
    ;;
esac
