#!/usr/bin/env bash
# psi-oom-watcher.sh — user-scope PSI (pressure stall information) early
# warning + last-resort SIGTERM watcher. Part of bead ez-gh-actions-0725
# (panel decision on ez-gh-actions-ah94, Tier 1 do-now).
#
# WHY THIS EXISTS AS A FALLBACK (not earlyoom):
# earlyoom is packaged in apt (candidate 1.7-2 on this host, confirmed
# 2026-07-10: `apt-cache policy earlyoom` shows "Installed: (none)") but
# apt-get install requires sudo, which this bead's scope excludes — that
# install command is documented instead in
# docs/host-ops-sudo-block-0725.md for the human operator. Separately: this
# host ALSO already runs systemd-oomd (confirmed active, PID present,
# `systemctl status systemd-oomd` = active/running, package
# systemd-oomd 255.4-1ubuntu8.16 installed by default on Ubuntu 24.04) with
# default policy managing user.slice, user-<uid>.slice, and the root slice
# (ManagedOOMSwap=auto, ManagedOOMMemoryPressure=auto). It has fired at
# least once historically (killed a Chrome tab under
# "being 80.85% > 50.00% for > 20s with reclaim activity" per journalctl).
# systemd-oomd's DEFAULT thresholds (SwapUsedLimit=90%,
# DefaultMemoryPressureLimit=60%/30s) evidently were NOT tight enough to
# prevent the 2026-07-10 D-state-pileup-to-load-218 incident — the
# recommended TUNING of systemd-oomd (or fallback earlyoom install) is
# system-scope work and lives in docs/host-ops-sudo-block-0725.md, not
# here.
#
# THIS SCRIPT is the piece that IS achievable at user scope without sudo:
# it polls /proc/pressure/memory (world-readable, no privilege required)
# and, only as a LAST RESORT after sustained danger-zone pressure, sends
# SIGTERM (never SIGKILL — see rationale below) to a single process that
# the invoking user owns. It is a narrow, conservative backstop meant to
# convert an uncontrolled thrash-to-reboot into one clean early
# intervention — it is explicitly NOT trying to replace systemd-oomd or
# earlyoom, both of which run with real privilege and broader visibility.
#
# WHICH PSI FIELD, AND WHY ("full avg10"):
# /proc/pressure/memory exposes two lines, "some" and "full", each with
# avg10/avg60/avg300/total. "some" = at least one task was stalled waiting
# on memory; "full" = ALL non-idle tasks were stalled simultaneously (i.e.
# the whole runqueue is blocked, not just one task) — see
# https://docs.kernel.org/accounting/psi.html. "full" is the correct signal
# for "we are in a genuine memory-thrash crisis" (the 2026-07-10 incident
# was exactly this: D-state pileup = the "full" case, effectively every
# task blocked). avg10 (10-second rolling average) is used as the trigger
# window because it reacts fast enough to catch a fast-developing thrash
# event without being pure instantaneous noise; avg60 is logged alongside
# for trend context but is not the enforcement field.
#
# TWO THRESHOLDS:
#   WARN_THRESHOLD  (default 10, i.e. full avg10 >= 10%) -> log loudly only.
#   CRIT_THRESHOLD  (default 40, i.e. full avg10 >= 40%) sustained for
#                   CRIT_CONSECUTIVE consecutive polls (default 2, i.e.
#                   ~2x POLL_INTERVAL_SEC of continuous crisis-level
#                   pressure, not a single noisy sample) -> SIGTERM action.
# These are deliberately well below "the host is already at load 218" —
# the entire point is to fire EARLY. They are also deliberately NOT hair
# trigger: a single noisy sample at CRIT level does not act; only sustained
# pressure across CRIT_CONSECUTIVE polls does.
#
# WHY SIGTERM, NEVER SIGKILL: SIGTERM gives the target process a chance to
# flush state / exit its own cleanup path (e.g. a coding agent CLI can
# save session state) rather than being killed mid-write. This mirrors the
# repo-wide convention already established for the fleet watchdog's own
# process-management posture. If a process ignores SIGTERM, this script
# does NOT escalate to SIGKILL — it logs and waits for the next polling
# cycle's re-evaluation (by which point RSS/pressure has likely already
# started dropping if the SIGTERM was heeded elsewhere in the process
# tree, or a human is now on notice via the log).
#
# COOLDOWN: after taking a SIGTERM action, no further action is taken for
# COOLDOWN_SEC (default 600s / 10min), even if pressure remains high. This
# is the single most important conservatism in this script: it exists to
# convert ONE crisis into ONE intervention, not to become a second source
# of repeated, cascading kills that could itself destabilize a session
# doing legitimate bursty work. The cooldown state is a mtime-stamped file
# under STATE_DIR so it survives across polling invocations (this script is
# designed to be invoked periodically by psi-oom-watcher.timer, not to
# loop forever itself — see that unit for the interval justification).
#
# EXCLUSION LIST (never targeted, in addition to "not the ezgha daemon and
# not itself" from the bead spec): the watcher's own process tree, and a
# short list of process names whose sudden SIGTERM would be actively
# dangerous to the user's ability to keep working / keep this very watcher
# running (systemd --user itself, the user's login shell's controlling
# tmux/screen *server* process, sshd, and Xorg/gnome-shell/a Wayland
# compositor). This is a conservative superset of the literal spec because
# "be conservative, don't become a second source of instability" (bead
# instruction) argues for it: killing the user's terminal multiplexer
# server or SSH session while they're trying to diagnose a memory crisis
# would be the exact kind of self-outage this bead's principle forbids.
#
# CRITICAL EXCLUSION FOUND DURING TESTING (2026-07-10): a live dry-run on
# jeff-ubuntu showed the single largest-RSS process under this user is
# `qemu-system-x86` (comm, truncated from qemu-system-x86_64) at ~32GB RSS
# — this IS the Colima VM backing the entire ezgha runner fleet
# (args contain `.../.lima/colima/...`). The bead's own framing says
# "Colima VM ... memory is already accounted for and is OUT OF SCOPE for
# this task" — SIGTERM-ing it would not just be out of scope, it would
# instantly kill every runner container and take down the fleet this whole
# repo exists to keep up, which is a categorically worse outcome than the
# swap-thrash this watcher is trying to prevent. qemu/colima/lima processes
# are therefore hard-excluded by both comm AND full args (defense in depth,
# since `comm` truncates to 15 chars and could theoretically collide). Note:
# `ps` on this host shows TWO qemu-system-x86 processes (the ~32GB main VM
# plus a smaller guest-agent-adjacent one) — both are covered because the
# exclusion matches on comm/args pattern, not a specific PID or RSS size.
#
# SECOND EXCLUSION FOUND DURING ADVERSARIAL VERIFICATION (2026-07-10,
# sidekick-memarch): after qemu/colima, the next-largest-RSS process on
# this host by a wide margin was `warp-terminal` (~760MB) — the user's GUI
# terminal emulator. This script's own stated rationale for excluding
# tmux/screen ("protect the user's ability to keep working") applies
# equally to the GUI terminal app hosting the user's session — SIGTERM-ing
# it would kill every pane/tab the user has open, including whatever
# terminal they'd use to investigate the very crisis this script fired for.
# Common GUI terminal emulators are therefore added to the exclusion list
# alongside the tmux/screen *server* processes already covered. This is
# scoped narrowly to terminal emulators specifically (not desktop apps in
# general, e.g. a browser) because that's the specific class this script's
# own "keep the user working" rationale already commits to protecting;
# widening further (e.g. to browsers) would start trading away the
# watcher's usefulness against a class of risk it was never designed to
# cover. After this exclusion, live `ps` on this host confirms the next
# candidates are legitimate `claude` CLI processes — i.e. the actual
# intended target class, confirming the watcher is not left toothless.
#
# USAGE (normally invoked by psi-oom-watcher.timer -> .service, but safe to
# run by hand for testing):
#   scripts/host/psi-oom-watcher.sh
#   DRY_RUN=1 scripts/host/psi-oom-watcher.sh   # log what it WOULD do, no signal sent
set -euo pipefail

PSI_FILE="${PSI_FILE:-/proc/pressure/memory}"
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/ezgha}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/psi-oom-watcher.log}"
COOLDOWN_MARKER="${STATE_DIR}/psi-oom-watcher.last-action"
STREAK_FILE="${STATE_DIR}/psi-oom-watcher.crit-streak"

WARN_THRESHOLD="${WARN_THRESHOLD:-10}"      # full avg10 percent
CRIT_THRESHOLD="${CRIT_THRESHOLD:-40}"      # full avg10 percent
CRIT_CONSECUTIVE="${CRIT_CONSECUTIVE:-2}"   # consecutive polls at/above CRIT before acting
COOLDOWN_SEC="${COOLDOWN_SEC:-600}"         # 10 minutes
DRY_RUN="${DRY_RUN:-0}"

# comm-based exclusions (exact match against ps -o comm=, which truncates
# at 15 chars — qemu-system-x86_64 truncates to "qemu-system-x86"). Grouped:
# core system/session processes, the VM backing the runner fleet
# (qemu/colima/lima), and GUI terminal emulators (see "SECOND EXCLUSION"
# comment above — warp-terminal was the real second-largest-RSS process
# found on jeff-ubuntu during adversarial verification).
#
# NOTE (fixed 2026-07-10, third adversarial re-verification pass): this
# list previously included the literal string "psi-oom-watcher\.sh", which
# can NEVER match -- when this script runs as a directly-executed
# shebang'd file (`./psi-oom-watcher.sh`), the kernel's comm field
# truncates at 15 bytes, dropping the ".sh" suffix entirely (comm is
# "psi-oom-watcher", exactly 15 chars). This was harmless in practice
# (self-exclusion is already guaranteed by the PID/PPID checks above,
# independent of this pattern) but was documentation-misleading. Fixed to
# the actual truncated value so the intent and the mechanism agree.
EXCLUDE_NAME_PATTERN='^(systemd|\(sd-pam\)|sshd|Xorg|gnome-shell|tmux: server|screen|psi-oom-watcher|ezgha|qemu-system-x86|colima|lima|dockerd|docker|warp-terminal|gnome-terminal|gnome-terminal-server|konsole|alacritty|kitty|xterm|terminator|tilix|foot|wezterm|ghostty)$'
# args-based exclusions (defense in depth for the comm-truncation case
# above, and to catch any Colima/Lima helper process whose comm doesn't
# start with one of the names above but whose full command line does).
EXCLUDE_ARGS_PATTERN='(qemu-system|\.lima/colima|/colima/|lima-colima)'

mkdir -p "${STATE_DIR}"

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$1" | tee -a "${LOG_FILE}" >&2
}

if [ ! -r "${PSI_FILE}" ]; then
  log "PSI file ${PSI_FILE} not readable — kernel may lack CONFIG_PSI, or this is not Linux. Exiting without action."
  exit 0
fi

# Parse the "full avg10=X.XX ..." line. Format per kernel docs:
#   some avg10=0.00 avg60=0.00 avg300=0.00 total=0
#   full avg10=0.00 avg60=0.00 avg300=0.00 total=0
full_line="$(grep '^full' "${PSI_FILE}")"
full_avg10="$(printf '%s' "${full_line}" | sed -n 's/.*avg10=\([0-9.]*\).*/\1/p')"
full_avg60="$(printf '%s' "${full_line}" | sed -n 's/.*avg60=\([0-9.]*\).*/\1/p')"

if [ -z "${full_avg10}" ]; then
  log "failed to parse 'full avg10' from ${PSI_FILE} (line: ${full_line}) — exiting without action."
  exit 0
fi

# Integer-truncated comparison (bash has no float arithmetic) — sufficient
# for threshold comparisons at whole-percent granularity.
full_avg10_int="${full_avg10%%.*}"
[ -z "${full_avg10_int}" ] && full_avg10_int=0

if [ "${full_avg10_int}" -lt "${WARN_THRESHOLD}" ]; then
  # Healthy — reset the crit streak counter and exit quietly (no log spam
  # at healthy steady-state; only WARN/CRIT states are logged).
  rm -f "${STREAK_FILE}"
  exit 0
fi

log "WARN: memory pressure elevated — full avg10=${full_avg10}% avg60=${full_avg60}% (warn>=${WARN_THRESHOLD}%, crit>=${CRIT_THRESHOLD}%)"

if [ "${full_avg10_int}" -lt "${CRIT_THRESHOLD}" ]; then
  rm -f "${STREAK_FILE}"
  exit 0
fi

# At or above CRIT threshold — bump the consecutive-poll streak counter.
streak=0
[ -f "${STREAK_FILE}" ] && streak="$(cat "${STREAK_FILE}" 2>/dev/null || echo 0)"
streak=$((streak + 1))
echo "${streak}" > "${STREAK_FILE}"

log "CRIT: full avg10=${full_avg10}% >= ${CRIT_THRESHOLD}% (consecutive poll ${streak}/${CRIT_CONSECUTIVE})"

if [ "${streak}" -lt "${CRIT_CONSECUTIVE}" ]; then
  log "CRIT streak below action threshold (${streak}/${CRIT_CONSECUTIVE}) — waiting for next poll before acting."
  exit 0
fi

# Cooldown check — never act more than once per COOLDOWN_SEC, regardless of
# how long the crisis persists.
now_epoch="$(date +%s)"
if [ -f "${COOLDOWN_MARKER}" ]; then
  last_epoch="$(cat "${COOLDOWN_MARKER}" 2>/dev/null || echo 0)"
  elapsed=$((now_epoch - last_epoch))
  if [ "${elapsed}" -lt "${COOLDOWN_SEC}" ]; then
    log "CRIT threshold sustained but cooldown active (${elapsed}s/${COOLDOWN_SEC}s since last action) — logging only, no signal sent."
    exit 0
  fi
fi

# Find the single largest-RSS process owned by the invoking user, excluding
# this script's own process tree, the ezgha daemon, and the safety
# exclusion list above.
self_pid="$$"
self_ppid="${PPID:-0}"

target_pid=""
target_rss=""
target_comm=""
# ps output: PID RSS(KB) COMM ARGS..., sorted descending by RSS, current
# user only. ARGS is intentionally the last field (unquoted, "greedy") so
# read's word-splitting folds the whole remaining command line into it.
while read -r pid rss comm args; do
  [ -z "${pid}" ] && continue
  [ "${pid}" = "${self_pid}" ] && continue
  [ "${pid}" = "${self_ppid}" ] && continue
  if [[ "${comm}" =~ ${EXCLUDE_NAME_PATTERN} ]]; then
    continue
  fi
  if [[ "${args}" =~ ${EXCLUDE_ARGS_PATTERN} ]]; then
    continue
  fi
  target_pid="${pid}"
  target_rss="${rss}"
  target_comm="${comm}"
  break
done < <(ps -u "$(id -u)" -o pid=,rss=,comm=,args= --sort=-rss)

if [ -z "${target_pid}" ]; then
  log "CRIT action triggered but no eligible target process found (all candidates excluded) — no signal sent."
  exit 0
fi

target_rss_mb=$((target_rss / 1024))

if [ "${DRY_RUN}" = "1" ]; then
  # BUG FIXED (2026-07-10, third adversarial re-verification pass): this
  # branch previously wrote COOLDOWN_MARKER and cleared STREAK_FILE exactly
  # like a real SIGTERM action, even though nothing was sent. That meant a
  # human running a DRY_RUN rehearsal during an actual incident would
  # silently arm the 10-minute cooldown and suppress REAL protection for
  # the rest of that window -- disabling the safety mechanism precisely
  # when it's needed most. DRY_RUN is now purely observational: it logs
  # what it would do and touches NO cooldown/streak state at all, so a
  # rehearsal can never suppress a real intervention.
  log "DRY_RUN: would send SIGTERM to pid=${target_pid} comm=${target_comm} rss=${target_rss_mb}MB (full avg10=${full_avg10}%, streak=${streak}) -- DRY_RUN does not touch cooldown/streak state; real protection remains fully armed after this rehearsal"
  exit 0
fi

log "ACTION: sending SIGTERM to pid=${target_pid} comm=${target_comm} rss=${target_rss_mb}MB — sustained memory pressure full avg10=${full_avg10}% for ${streak} consecutive polls. Cooldown ${COOLDOWN_SEC}s starts now."
if kill -TERM "${target_pid}" 2>>"${LOG_FILE}"; then
  log "SIGTERM delivered to pid=${target_pid}."
else
  log "SIGTERM delivery to pid=${target_pid} FAILED (process may have already exited)."
fi

echo "${now_epoch}" > "${COOLDOWN_MARKER}"
rm -f "${STREAK_FILE}"
