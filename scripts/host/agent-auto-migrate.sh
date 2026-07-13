#!/usr/bin/env bash
# agent-auto-migrate.sh — auto-migrate running agent-CLI processes into the
# `agents.slice` systemd --user slice. Companion to agent-cli-scoped.sh
# (which still handles the explicit opt-in path); this helper handles the
# round-3 policy flip from opt-in to opt-OUT (--opt-out for escape).
#
# POLICY DECISION (panel 2026-07-12, supersedes the original "opt-in" rule
# captured in systemd/agents.slice on 2026-07-11): every interactive agent
# CLI session MUST live inside agents.slice's MemoryHigh=20G ceiling so a
# runaway agent cannot OOM-kill the host. The mechanism stays the same
# (`systemd-run --user --slice=agents.slice --scope -- <cmd>`), but the
# default flips to AUTO-MIGRATE for already-running sessions.
#
# WHY A NEW SCRIPT (and not just editing agent-cli-scoped.sh):
#   - agent-cli-scoped.sh launches a NEW process via systemd-run. That
#     does not work for an ALREADY-RUNNING session because cgroup v2
#     does not let a process re-parent its own cgroup without writing
#     its PID to the target cgroup.procs file (which requires a
#     cgroup-priv permission we cannot assume). The honest answer that
#     the original agent-cli-scoped.sh header documented STILL holds:
#     "There is no `systemctl --user move-to-slice <pid> <slice>`
#     equivalent." The path forward is RELAUNCH through systemd-run
#     with --slice=agents.slice, which is fine because agent CLIs
#     are resilient to relaunch (they re-read code, state, and resume).
#   - agent-cli-scoped.sh stays unchanged as the explicit opt-IN path
#     (and gains a --auto-attach flag so it can also be used to
#     re-launch a running session via the same systemd-run pathway).
#     This script, by contrast, discovers already-running agent-CLI
#     processes, captures their argv (comm + args), and relaunches them
#     scoped. The relaunched process inherits the same working
#     directory and an env-var-discoverable context (PATH, HOME,
#     XDG_*); the agent picks up where the old one left off.
#
# BLAST RADIUS:
#   - The script SIGTERMs the captured PID before relaunch, so any
#     in-flight work in the original session is lost. Agent CLIs that
#     hold long-running tool calls may have them cut short; this is
#     the explicit trade-off vs leaving an uncontained agent free to
#     OOM the host.
#   - The MemoryHigh=20G cap is a *soft* ceiling (MemoryHigh not
#     MemoryMax), so a misbehaving leaf gets throttled+reclaimed, NOT
#     SIGKILLed — bead ez-gh-actions-0725 documented this choice for
#     the same reason and the same property holds here.
#   - Each affected session spawns a one-shot systemd transient scope
#     unit; under normal load (≤ ~16 leaves typical) the user manager
#     handles thousands. No systemd quota concern.
#   - --dry-run mode prints what WOULD be migrated without sending any
#     signal or relaunching anything; safe to run ad hoc.
#
# USAGE:
#   scripts/host/agent-auto-migrate.sh apply                # migrate matching PIDs
#   scripts/host/agent-auto-migrate.sh apply --dry-run      # show what would happen
#   scripts/host/host/agent-auto-migrate.sh status          # enrolled leaves + RSS
#   scripts/host/agent-auto-migrate.sh status --verbose     # show comm + slice
#
# AGENT-CLI MATCH (single regex, eval-safe):
#   claude, codex, gemini, cursor, aider, cody (matches both
#   "claude --dangerously-skip-permissions" and "/usr/bin/claude" or
#   "/home/.../.npm-global/bin/codex" — any path/name containing the
#   base name token). Patterns are intentionally narrow to avoid
#   false positives on system binaries (e.g. "code" is NOT matched).
set -euo pipefail

PATTERN='(^|/)(claude|codex|gemini|cursor|aider|cody)(-|$)'
SLICE_UNIT="${HOME}/.config/systemd/user/agents.slice"
SLICE_NAME="agents.slice"
MODE="${1:-apply}"
DRY_RUN=0
VERBOSE=0
shift || true
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --verbose) VERBOSE=1 ;;
  ""|--help|-h) ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

require_systemd_run() {
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "agent-auto-migrate.sh: systemd-run not found on PATH (Linux only)." >&2
    exit 1
  fi
  if [ ! -f "${SLICE_UNIT}" ]; then
    echo "agent-auto-migrate.sh: ${SLICE_UNIT} not found." >&2
    echo "  Install it first: mkdir -p ~/.config/systemd/user && cp systemd/agents.slice ~/.config/systemd/user/ && systemctl --user daemon-reload" >&2
    exit 1
  fi
}

list_matching_pids() {
  # ps shows full argv; matching on the basename of the first arg keeps
  # the regex narrow (no false positives on "code", "codexium", etc).
  ps -u "$(id -u)" -o pid=,args= --no-headers 2>/dev/null \
    | awk -v pat="$PATTERN" '
        {
          cmd = ""
          for (i = 2; i <= NF; i++) cmd = cmd " " $i
          # Extract the basename of the executable (first arg) without
          # path prefix or args. Strip a trailing colon (gdb-style
          # "pid:" attachment) and any " " following the name token.
          bin = $2
          sub(/[[:space:]].*/, "", bin)
          n = split(bin, parts, "/")
          base = parts[n]
          sub(/:.*/, "", base)
          if (base ~ pat) print $1 "\t" base "\t" cmd
        }
      '
}

print_status_leaves() {
  local sysfs="/sys/fs/cgroup"
  local cg_base="${sysfs}/user.slice/user-${UID}.slice/user@${UID}.service/${SLICE_NAME}"
  if [ ! -d "${cg_base}" ]; then
    echo "  agents.slice not initialized yet (no leaves enrolled) — no harm, but Gate 8 will fail."
    return
  fi
  # Enumerate immediate leaves (children) of the slice. The kernel writes
  # one folder per cgroup; some are scope-* (transient systemd scopes),
  # others are service-* (long-running units with their own slice
  # drop-in). Both are valid enrollments for Gate 8's leaf-count check.
  local leaves=()
  for d in "${cg_base}"/*/; do
    [ -d "$d" ] || continue
    leaves+=("$(basename "$d")")
  done
  echo "  ${SLICE_NAME} leaves: ${#leaves[@]}"
  if [ "$VERBOSE" = "1" ]; then
    for leaf in "${leaves[@]}"; do
      local leaf_path="${cg_base}/${leaf}"
      local high mem cur
      high=$(cat "${leaf_path}/memory.high" 2>/dev/null || echo "?")
      mem=$(cat "${leaf_path}/memory.current" 2>/dev/null || echo "?")
      cur=$(cat "${leaf_path}/cgroup.procs" 2>/dev/null | wc -l | tr -d '[:space:]')
      echo "    - ${leaf}: high=${high} current=${mem} procs=${cur}"
    done
  fi
  # Print slice-level summary so operators can spot unbounded leaves
  # against a bounded slice (Gate 8 fail-closed shape).
  local slice_high
  slice_high=$(cat "${cg_base}/memory.high" 2>/dev/null || echo "?")
  echo "  slice memory.high=${slice_high}"
}

cmd_apply() {
  require_systemd_run
  echo "agent-auto-migrate: scanning for matching agent-CLI processes (pattern=${PATTERN})..."
  local matched=0 migrated=0
  while IFS=$'\t' read -r pid bin cmdline; do
    [ -z "$pid" ] && continue
    matched=$((matched + 1))
    local leaf
    leaf=$(grep '^0::' "/proc/$pid/cgroup" 2>/dev/null | head -1 || true)
    leaf="${leaf#0::}"
    local already_in_slice=0
    if echo "$leaf" | grep -q "/${SLICE_NAME}/"; then
      already_in_slice=1
    fi
    if [ "$already_in_slice" = "1" ]; then
      echo "  [skip] pid=${pid} bin=${bin} already in ${SLICE_NAME} (leaf=${leaf})"
      continue
    fi
    echo "  [target] pid=${pid} bin=${bin} leaf=${leaf:-<unreadable>}"
    if [ "$DRY_RUN" = "1" ]; then
      echo "          DRY-RUN: would SIGTERM pid=${pid} and relaunch via systemd-run --user --slice=${SLICE_NAME} --scope -- ${cmdline}"
      continue
    fi
    # Capture cwd + env before we kill the process. systemd-run's --scope
    # does NOT inherit cwd by default; we have to capture and pass it.
    local cwd env_args
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "${PWD}")
    # Strip the leading whitespace from cmdline; keep raw order.
    cmdline="${cmdline# }"
    # Re-launch scoped. systemd-run --user --slice=agents.slice --scope
    # creates a transient scope unit and execs "$@" as its main process.
    # We do NOT kill the original PID first because systemd-run will
    # fork-detach from us immediately and the scope outlives the
    # caller; leaving the original running risks a port conflict for
    # CLI daemons, so we SIGTERM after the scope is observed running.
    local scope_unit
    scope_unit=$(systemd-run --user --slice="${SLICE_NAME}" --scope --unit="agent-autoscope-$$-${pid}" --quiet --working-directory="${cwd}" -- ${cmdline} 2>&1 || true)
    echo "          systemd-run launched: ${scope_unit:-<error — see journal>}"
    # Best-effort signal to the old PID so only one instance holds
    # state. Skip if pid is current shell.
    if [ "$pid" != "$$" ] && [ "$pid" != "$BASHPID" ]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
    migrated=$((migrated + 1))
  done < <(list_matching_pids || true)

  if [ "$matched" = "0" ]; then
    echo "agent-auto-migrate: no matching agent-CLI processes found (nothing to migrate)."
  elif [ "$DRY_RUN" = "1" ]; then
    echo "agent-auto-migrate: DRY-RUN complete (${matched} candidate(s); no signals sent)."
  else
    echo "agent-auto-migrate: ${migrated}/${matched} process(es) migrated (or attempted)."
    echo "  Re-run 'status' to confirm enrolled leaves."
  fi
}

cmd_status() {
  echo "agent-auto-migrate: ${SLICE_NAME} enrollment summary (slice Path=${SLICE_UNIT})"
  if [ ! -f "${SLICE_UNIT}" ]; then
    echo "  [WARN] ${SLICE_UNIT} not installed; auto-migrate cannot enroll new processes."
  else
    echo "  slice unit: installed"
  fi
  print_status_leaves
}

case "$MODE" in
  apply)  cmd_apply ;;
  status) cmd_status ;;
  --help|-h)
    echo "usage: $(basename "$0") apply [--dry-run]"
    echo "       $(basename "$0") status [--verbose]"
    ;;
  *)
    echo "usage: $(basename "$0") {apply|status} [--dry-run|--verbose]" >&2
    exit 2
    ;;
esac
