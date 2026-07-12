#!/usr/bin/env bash
# agent-cli-scoped.sh — opt-in wrapper that launches a command inside the
# `agents.slice` systemd --user slice (see systemd/agents.slice for the
# MemoryHigh=20G rationale and blast-radius statement). Part of bead
# ez-gh-actions-0725 (panel decision on ez-gh-actions-ah94, Tier 1 do-now #2).
#
# USAGE:
#   scripts/host/agent-cli-scoped.sh claude --dangerously-skip-permissions
#   scripts/host/agent-cli-scoped.sh codex exec "some task"
#
# WHAT THIS DOES: `systemd-run --user --slice=agents.slice --scope -- "$@"`
# creates a transient scope unit under agents.slice and execs "$@" as its
# main process (systemd-run --scope runs the command in the CURRENT
# terminal/session, attached to stdio, not detached — you get normal
# foreground behavior, just cgroup-scoped).
#
# PREREQUISITE: ~/.config/systemd/user/agents.slice must exist (install by
# copying systemd/agents.slice there — this repo does NOT do that
# automatically; see install.sh comments for why these host-wide units are
# intentionally kept out of the ezgha-*-prefixed auto-install loop). If the
# slice unit is missing, systemd-run will still create an ad-hoc transient
# slice with no MemoryHigh applied (silently NOT what you want), so this
# script checks for the unit file first and fails loudly rather than
# running unscoped-but-silently.
#
# CAN AN ALREADY-RUNNING SESSION BE MOVED IN AFTER THE FACT?
# Honest answer: not via any supported systemd CLI subcommand. There is no
# `systemctl --user move-to-slice <pid> <slice>` equivalent. `machinectl`/
# `systemd-run` only scope *new* processes at launch time. In principle,
# because this host's user manager has cgroup v2 delegation with the
# "memory" and "pids" controllers available under
# user.slice/user-<uid>.slice/user@<uid>.service/ (confirmed 2026-07-10:
# `cat .../user@<uid>.service/cgroup.controllers` -> "memory pids"), a
# privileged-enough-in-its-own-subtree user process COULD in theory move an
# existing PID into agents.slice's cgroup by writing that PID to
# .../agents.slice/cgroup.procs directly. This is UNTESTED here and not
# something this script implements: cgroup migration semantics for a
# process with open file descriptors, ptys, and job-control state
# established outside the target cgroup are easy to get subtly wrong, and
# getting it wrong on a live agent session is exactly the kind of
# self-inflicted instability this bead exists to avoid. Recommendation: use
# this wrapper for *new* agent CLI invocations going forward; do not
# attempt to retrofit already-running sessions.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") <command> [args...]" >&2
  echo "  launches <command> inside the agents.slice systemd --user slice (MemoryHigh=20G)" >&2
  exit 2
fi

if ! command -v systemd-run >/dev/null 2>&1; then
  echo "agent-cli-scoped.sh: systemd-run not found on PATH — this wrapper requires systemd (Linux only)." >&2
  exit 1
fi

SLICE_UNIT="${HOME}/.config/systemd/user/agents.slice"
if [ ! -f "${SLICE_UNIT}" ]; then
  echo "agent-cli-scoped.sh: ${SLICE_UNIT} not found." >&2
  echo "  Install it first: mkdir -p ~/.config/systemd/user && cp systemd/agents.slice ~/.config/systemd/user/ && systemctl --user daemon-reload" >&2
  echo "  Refusing to run unscoped — systemd-run would otherwise create an ad-hoc slice with NO MemoryHigh applied, silently defeating the point of this wrapper." >&2
  exit 1
fi

exec systemd-run --user --slice=agents.slice --scope --quiet -- "$@"
