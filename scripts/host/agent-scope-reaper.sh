#!/usr/bin/env bash
# Reap abandoned transient agent-* scopes without touching a live session.
set -euo pipefail

GRACE_SECONDS="${AGENT_SCOPE_GRACE_SECONDS:-900}"
STATE_DIR="${AGENT_SCOPE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ezgha}"
LOG_FILE="${AGENT_SCOPE_REAPER_LOG:-$STATE_DIR/agent-scope-reaper.log}"
UNIT_FIXTURE="${AGENT_SCOPE_UNIT_FIXTURE:-}"
NOW="${AGENT_SCOPE_NOW_EPOCH:-$(date +%s)}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local reason="$1" unit="$2" action="$3"
  printf '{"ts":"%s","unit":"%s","action":"%s","reason":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$unit" "$action" "$reason" >> "$LOG_FILE"
}

scope_has_primary_cli() {
  local unit="$1" map_entry flag control_group proc_file pid comm
  # Fixture map is per scope (unit=1 means a primary CLI remains). This keeps
  # regression tests honest without a global pgrep shortcut.
  if [ -n "${AGENT_SCOPE_PRIMARY_MAP:-}" ]; then
    IFS=',' read -ra map_entries <<< "$AGENT_SCOPE_PRIMARY_MAP"
    for map_entry in "${map_entries[@]}"; do
      if [ "${map_entry%%=*}" = "$unit" ]; then
        flag="${map_entry#*=}"
        [ "$flag" = 1 ]
        return
      fi
    done
    return 1
  fi
  if [ -n "${AGENT_SCOPE_PRIMARY_FIXTURE:-}" ]; then
    [ "${AGENT_SCOPE_PRIMARY_FIXTURE}" = "1" ]
    return
  fi
  control_group="$(systemctl --user show "$unit" -p ControlGroup --value 2>/dev/null || true)"
  [ -n "$control_group" ] || return 2
  proc_file="/sys/fs/cgroup${control_group}/cgroup.procs"
  [ -r "$proc_file" ] || return 2
  while read -r pid; do
    [ -r "/proc/$pid/comm" ] || continue
    comm="$(<"/proc/$pid/comm")"
    case "${comm%%$'\n'*}" in
      codex|claude|gemini|cursor|aider|cody) return 0 ;;
    esac
  done < "$proc_file"
  return 1
}

list_scopes() {
  if [ -n "$UNIT_FIXTURE" ]; then
    cat "$UNIT_FIXTURE"
  else
    systemctl --user list-units --type=scope --all --no-legend --plain \
      | awk '$1 ~ /^agent-[^ ]+\.scope$/ {print $1}' \
      | while read -r unit; do
          started=$(systemctl --user show "$unit" -p ActiveEnterTimestamp --value || true)
          [ -n "$started" ] || continue
          epoch=$(date -d "$started" +%s 2>/dev/null || true)
          [ -n "$epoch" ] && printf '%s|%s\n' "$unit" "$epoch"
        done
  fi
}

while IFS='|' read -r unit started; do
  [ -n "$unit" ] || continue
  case "$unit" in agent-*.scope) ;; *) log "ignored non-agent scope" "$unit" "ignore"; continue ;; esac
  [[ "$started" =~ ^[0-9]+$ ]] || { log "missing start timestamp" "$unit" "ignore"; continue; }
  age=$((NOW - started))
  if [ "$age" -lt "$GRACE_SECONDS" ]; then
    log "scope age ${age}s is below grace ${GRACE_SECONDS}s" "$unit" "keep"
    continue
  fi
  if scope_has_primary_cli "$unit"; then
    log "primary agent CLI remains; orphan stop deferred" "$unit" "defer"
    continue
  elif [ "$?" -eq 2 ]; then
    log "cannot inspect scope cgroup; orphan stop deferred" "$unit" "defer"
    continue
  fi
  if [ "${AGENT_SCOPE_DRY_RUN:-0}" = "1" ]; then
    log "aged ${age}s and no primary CLI (dry-run)" "$unit" "would-stop"
  elif systemctl --user stop "$unit"; then
    log "aged ${age}s and no primary CLI" "$unit" "stop"
  else
    log "aged ${age}s and no primary CLI; stop failed" "$unit" "stop-failed"
  fi
done < <(list_scopes)
