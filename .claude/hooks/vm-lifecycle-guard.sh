#!/usr/bin/env bash
# vm-lifecycle-guard.sh — PreToolUse(Bash) hook: block destructive VM/backend
# lifecycle commands unless this session is the designated deploy-owner.
#
# Why: 2026-07-14 outage — a read-only verifier subagent ran
# `colima stop --force` mid-recovery and killed the prod runner VM, and a
# `docker system prune` class action deleted ezgha-runner:latest while the
# fleet was down (in-use images survive, idle runner image does not).
# Short-timeout `colima start` kills also CREATE the "vz driver is running
# but host agent is not" stale state. Beads: jleechan-rvv1, jleechan-kobt.
#
# Scope: repo-level (.claude/settings.json in ez-gh-actions). Sessions in
# other repos are NOT covered — see CLAUDE.md "VM lifecycle is
# deploy-owner-only" for the policy statement agents must follow anyway.
#
# Bypass: export EZGHA_DEPLOY_OWNER=1 (human deploy-owner sessions only).

set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=""
[ -z "$cmd" ] && exit 0

if [ "${EZGHA_DEPLOY_OWNER:-0}" = "1" ]; then
  exit 0
fi

# Destructive VM lifecycle + image-destroying verbs. `colima/limactl start`
# is allowed (recovery direction) but stop/delete/prune are blocked.
# Anchored to command position (line start / ; & | ` $( prefix) so commands
# that merely MENTION these strings (grep, echo, docs) are not blocked.
cmdpos='(^|[;&|`]|\$\()[[:space:]]*(timeout[[:space:]]+[0-9]+[a-z]*[[:space:]]+)?'
pattern="${cmdpos}((colima|limactl)[[:space:]]+(stop|delete|factory-reset)|docker[[:space:]]+(system|image)[[:space:]]+prune|docker[[:space:]]+rmi[[:space:]][^;&|]*ezgha-runner|docker[[:space:]]+context[[:space:]]+(rm|use))"

if printf '%s' "$cmd" | grep -qE "$pattern"; then
  echo "BLOCKED by vm-lifecycle-guard: '$cmd' matches a destructive VM/backend lifecycle pattern." >&2
  echo "These commands are deploy-owner-only (2026-07-14 incident: verifier subagent killed prod VM; prune deleted ezgha-runner:latest)." >&2
  echo "If you are the human deploy-owner, re-run with EZGHA_DEPLOY_OWNER=1 exported." >&2
  exit 2
fi

exit 0
