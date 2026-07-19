#!/usr/bin/env bash
# agent-cli-scoped.sh — opt-IN wrapper that launches a command inside the
# `agents.slice` systemd --user slice (see systemd/agents.slice for the
# MemoryHigh=20G rationale and blast-radius statement). Part of bead
# ez-gh-actions-0725 (panel decision on ez-gh-actions-ah94, Tier 1 do-now #2).
#
# USAGE:
#   scripts/host/agent-cli-scoped.sh claude --dangerously-skip-permissions
#   scripts/host/agent-cli-scoped.sh codex exec "some task"
#   scripts/host/agent-cli-scoped.sh --auto-attach <command>     # re-launch of a
#                                                                 #   running session
#   AGENT_SLICE_OPT_OUT=1 scripts/host/agent-cli-scoped.sh <command>
#                                                                # opt-OUT escape hatch
#
# WHAT THIS DOES: `systemd-run --user --slice=agents.slice --scope -- "$@"`
# creates a transient scope unit under agents.slice and execs "$@" as its
# main process (systemd-run --scope runs the command in the CURRENT
# terminal/session, attached to stdio, not detached — you get normal
# foreground behavior, just cgroup-scoped).
#
# ROUND-3 POLICY FLIP (2026-07-12, supersedes the original opt-IN rule):
# The default for AGENT CLI PROCESSES flipped to AUTO-MIGRATE — every
# interactive agent CLI session is supposed to live in agents.slice by
# default. Use scripts/host/agent-auto-migrate.sh for that workflow;
# this wrapper is now the explicit opt-IN/opt-OUT path used to:
#   - opt-OUT for one session: `AGENT_SLICE_OPT_OUT=1` env-var short-
#     circuits the systemd-run and runs the command unscoped (e.g. for
#     a session the operator is intentionally taking out of the slice
#     for debugging).
#   - opt-IN for a NEW session: default behavior runs the command
#     inside agents.slice.
#   - re-LAUNCH a RUNNING session into the slice without keeping the
#     original alive: `--auto-attach` uses the same systemd-run pathway
#     and is invoked by agent-auto-migrate.sh; the human can also call
#     it directly to enroll a session manually.
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
# self-inflicted instability this bead exists to avoid. Use
# scripts/host/agent-auto-migrate.sh (which relaunches through systemd-run)
# instead — that pathway is the round-3 default and is what this wrapper
# delegates to when called with --auto-attach.
set -euo pipefail

AUTO_ATTACH=0
if [ "${1:-}" = "--auto-attach" ]; then
  AUTO_ATTACH=1
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") [--auto-attach] <command> [args...]" >&2
  echo "  launches <command> inside the agents.slice systemd --user slice (MemoryHigh=20G)." >&2
  echo "  --auto-attach            flag indicating the caller migrated an existing session" >&2
  echo "  AGENT_SLICE_OPT_OUT=1    env-var escape hatch — runs the command UNSCOPED" >&2
  exit 2
fi

if ! command -v systemd-run >/dev/null 2>&1; then
  echo "agent-cli-scoped.sh: systemd-run not found on PATH — this wrapper requires systemd (Linux only)." >&2
  exit 1
fi

# Opt-OUT escape hatch (round-3 policy: default ON, --opt-out per session).
# Setting AGENT_SLICE_OPT_OUT=1 to a non-empty value short-circuits and
# runs the command unscoped. The slice still appears in cgroup listings
# but the command never joins it (it's a deliberate escape hatch, NOT a
# silent pass-through — operators who set this are on the hook for
# tracking why they opted out, e.g. when Gate 8 (2) flags the session).
if [ "${AGENT_SLICE_OPT_OUT:-0}" != "0" ] && [ -n "${AGENT_SLICE_OPT_OUT:-}" ]; then
  echo "agent-cli-scoped.sh: AGENT_SLICE_OPT_OUT=${AGENT_SLICE_OPT_OUT} — running <$*> UNSCOPED (not in agents.slice)." >&2
  exec "$@"
fi

SLICE_UNIT="${HOME}/.config/systemd/user/agents.slice"
if [ ! -f "${SLICE_UNIT}" ]; then
  echo "agent-cli-scoped.sh: ${SLICE_UNIT} not found." >&2
  echo "  Install it first: mkdir -p ~/.config/systemd/user && cp systemd/agents.slice ~/.config/systemd/user/ && systemctl --user daemon-reload" >&2
  echo "  Refusing to run unscoped — systemd-run would otherwise create an ad-hoc slice with NO MemoryHigh applied, silently defeating the point of this wrapper." >&2
  exit 1
fi

# --auto-attach is a tag (the relaunch-via-systemd-run mechanism is
# unchanged; the flag exists so the operator/migration script can mark
# the invocation as a re-launch of a previously-running session that has
# already been SIGTERMed by the auto-migrate helper, NOT a fresh attach).
if [ "$AUTO_ATTACH" = "1" ]; then
  echo "agent-cli-scoped.sh: --auto-attach invoked by migration helper; relaunching <$*> into agents.slice." >&2
fi

exec systemd-run --user --slice=agents.slice --scope --quiet -- "$@"
