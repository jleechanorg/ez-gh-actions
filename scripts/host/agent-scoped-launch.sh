#!/usr/bin/env bash
# Launch one of the supported agent CLIs in the finite agents.slice budget.
# A systemd scope keeps descendants (including MCP servers) in the same cgroup;
# --collect makes the transient scope disappear after the command exits.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <agent-name> <real-executable> [args...]" >&2
  exit 2
fi

command_name="$1"
shift
case "$command_name" in
  codex|claude|gemini|cursor|aider|cody) ;;
  *) echo "agent-scoped-launch.sh: unsupported agent CLI '$command_name'" >&2; exit 2 ;;
esac

# Explicit opt-out only. Any value other than an intentional 1 is ignored.
if [ "${AGENT_SLICE_OPT_OUT:-0}" = "1" ]; then
  echo "agent-scoped-launch.sh: explicit AGENT_SLICE_OPT_OUT=1; running unscoped" >&2
  exec "$@"
fi

command -v systemd-run >/dev/null 2>&1 || {
  echo "agent-scoped-launch.sh: systemd-run is required" >&2
  exit 1
}

# Tests and portable installs can point at the checked-in unit. In production
# this defaults to the user manager's installed unit, and fails closed when it
# is absent rather than silently creating an unbudgeted transient slice.
slice_unit="${AGENT_SLICE_UNIT_FILE:-${HOME}/.config/systemd/user/agents.slice}"
[ -f "$slice_unit" ] || {
  echo "agent-scoped-launch.sh: missing agents.slice at $slice_unit" >&2
  exit 1
}

# Explicit unit naming makes transient scopes discoverable by the orphan
# reaper (systemd's default is run-*.scope). Command names are allow-listed,
# so this identifier is safe for systemd's unit-name grammar.
unit_name="agent-${command_name}-$(date +%s)-$$"
exec systemd-run --user --slice=agents.slice --scope --collect --unit="$unit_name" -- "$@"
