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
#   scripts/host/psi-oom-watcher.sh --dry-run   # same, via flag
#   scripts/host/psi-oom-watcher.sh --priority-file /etc/ezgha/low-priority.list
#
# STAGED SHED CHAIN (R3 lane J, see bead ez-gh-actions-6478; R4 lane T fixes
# per beads ez-gh-actions-r3f10 / ez-gh-actions-r3f11): when the CRIT path
# is reached, run four bounded stages BEFORE the `kill -TERM` to a single
# user process — the per-process SIGTERM was the round-1 fallback that
# logged but otherwise reduced to "let the watchdog reboot the box" (see
# 2026-07-10 incident). Stage 1 drains lowest-priority managed containers;
# stage 2 writes a multi-GiB target to the QEMU cgroup's `memory.reclaim` to
# ask the kernel to release page cache + swap (does NOT signal processes);
# stage 3 sleeps 5s and verifies the QEMU RSS dropped by >= RSS_DROP_MIN_KB
# (default 1048576 = 1 GiB) — using a baseline RSS captured BEFORE stage 1,
# not after, so the comparison is honest; stage 4 only runs if the verify
# failed — it writes a watchdog-wait marker + logs CRITICAL and the original
# SIGTERM path is suppressed. The shed block is fully dry-runnable via
# `--dry-run` / `DRY_RUN=1` and is encoded as discrete functions so unit-
# test stubs can call them in isolation.
#
# R4 lane T (ez-gh-actions-r3f10): PSI_SHED_CHAIN is MANDATORY. The default
# below defines the canonical 4-stage chain; if the env var is unset OR
# empty at timer invocation (i.e. when this script is invoked as a
# oneshot without the --shed CLI flag), exit 64 — fail-closed. The empty
# default in round 3 was the cold-review-flagged defect: a staged shed
# that nobody wired up is a no-op defense. PSI_SHED_CHAIN is set in the
# systemd .service `Environment=` line (see systemd/psi-oom-watcher.service)
# so a fresh install gets it for free.
DEFAULT_PSI_SHED_CHAIN="drain,reclaim,verify,escalate"
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

# R3 lane J (ez-gh-actions-6478): when set, the CRIT path also runs the
# staged shed chain (drain/reclaim/verify/escalate) BEFORE the per-process
# SIGTERM fallback. R4 lane T (ez-gh-actions-r3f10): the chain is
# MANDATORY at timer invocation — empty/unset fails-closed with exit 64.
# The source of truth is the service unit's `Environment=` line (see
# systemd/psi-oom-watcher.service); DEFAULT_PSI_SHED_CHAIN above is the
# canonical chain shape, NOT a silent fallback at runtime — silent
# defaults are exactly the regression the cold review flagged. CLI flags
# (--shed / --dry-run / --priority-file) are parsed later, after the
# shed function definitions are in scope (forward references do not work
# in top-level bash evaluation order). NOTE: we deliberately do NOT
# default PSI_SHED_CHAIN here; that would mask the empty/unset case the
# validator exists to catch.
PSI_SHED_CHAIN="${PSI_SHED_CHAIN:-}"
_shed_mode=""
_shed_show_help=""
_shed_strict_required=0

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
EXCLUDE_NAME_PATTERN='^(systemd|\(sd-pam\)|sshd|Xorg|gnome-shell|tmux: server|screen|psi-oom-watcher|ezgha|qemu-system-x86|colima|lima|limactl|dockerd|docker|warp-terminal|gnome-terminal|gnome-terminal-server|konsole|alacritty|kitty|xterm|terminator|tilix|foot|wezterm|ghostty)$'
# args-based exclusions (defense in depth for the comm-truncation case
# above, and to catch any Colima/Lima helper process whose comm doesn't
# start with one of the names above but whose full command line does).
EXCLUDE_ARGS_PATTERN='(qemu-system|\.lima/colima|/colima/|lima-colima)'

mkdir -p "${STATE_DIR}"

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$1" | tee -a "${LOG_FILE}" >&2
}
##############################################################################
# STAGED SHED CHAIN (R3 lane J, ez-gh-actions-6478)
##############################################################################
# Each stage is a function so unit-test stubs can call them in isolation.
# `run_shed_stages` dispatches them in order, exports SHED_RESULT so the
# caller (or a future hook) can decide whether the watchdog can stay armed.
# The full chain is also exposed via `scripts/host/psi-oom-watcher.sh --shed`
# for one-shot invocation outside the polling loop (useful for hand-driven
# pressure-injection tests).
##############################################################################

# Override knobs (with safe defaults that match the bead example).
LOW_PRIORITY_CONTAINERS="${LOW_PRIORITY_CONTAINERS:-ez-mac-runner-b-1 ez-mac-runner-b-2 ez-runner-c-9 ez-runner-c-10}"
PRIORITY_FILE="${PRIORITY_FILE:-}"
RSS_DROP_MIN_KB="${RSS_DROP_MIN_KB:-1048576}"   # 1 GiB in kB
SHED_VERIFY_DELAY="${SHED_VERIFY_DELAY:-5}"    # seconds between write+verify
SHED_FLAG_DIR="${SHED_FLAG_DIR:-/run/ezgha}"
SHED_FLAG_FILE="${SHED_FLAG_DIR}/watchdog-wait-required.flag"

# Reset on every invocation so callers can `source` and probe.
SHED_RESULT=""
SHED_QEMU_PID=""
SHED_QEMU_CG=""
SHED_QEMU_CG_PATH=""

# ---------------- helpers ----------------
_shed_log() {
  # Stage-internal logger that prefixes the stage tag for post-mortem grep.
  printf '[%s] [shed/%s] %s\n' "$(date -u +%FT%TZ)" "$1" "$2" | tee -a "${LOG_FILE}" >&2
}

_shed_dry() {
  # Echo a dry-run action without performing it. Returns 0 unless DRY_RUN is off.
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[%s] [shed/%s] DRY_RUN %s\n' "$(date -u +%FT%TZ)" "$1" "$2" | tee -a "${LOG_FILE}" >&2
    return 0
  fi
  return 1
}

_shed_priority_list() {
  # Emit one container name per line. LOW_PRIORITY_CONTAINERS may be
  # space-separated OR newline-separated; both are accepted (tokens split
  # on whitespace). A optional PRIORITY_FILE (one name per line, '#'
  # comments and blank lines ignored) is appended to the env list. The
  # caller (stage1_drain) MUST iterate by word, not by line, because the
  # env list can be either format.
  printf '%s\n' "${LOW_PRIORITY_CONTAINERS}"
  if [ -n "${PRIORITY_FILE}" ]; then
    if [ -r "${PRIORITY_FILE}" ]; then
      # Strip comments/blank lines in-place and emit each surviving line.
      sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "${PRIORITY_FILE}"
    else
      _shed_log priority "${PRIORITY_FILE} set but not readable; ignoring"
    fi
  fi
}

# ---------------- Stage 1: Drain ----------------
stage1_drain() {
  # Stop low-priority containers gracefully (10s SIGTERM window). Track
  # which actually exited to spot containers that ignored SIGTERM (which
  # is logged but does not abort the chain — the chain continues to
  # stage 2 regardless of stage 1 outcome, per bead spec). Words in both
  # the env list (space-separated) and the priority file (line-separated)
  # are iterated uniformly — word splitting handles both.
  local stopped=0 attempted=0
  # Collect names into an array that tolerates BOTH space-separated env
  # values and line-separated file entries (use newline as IFS, then walk
  # each entry, splitting on internal whitespace just in case).
  local names=()
  local raw=""
  while IFS= read -r raw || [ -n "${raw}" ]; do
    # shellcheck disable=SC2206
    parts=( ${raw} )
    for p in "${parts[@]}"; do
      [ -z "${p}" ] && continue
      case "${p}" in '#'*) continue ;; esac
      names+=( "${p}" )
    done
  done < <(_shed_priority_list)

  if [ "${#names[@]}" -eq 0 ]; then
    _shed_log stage1 "summary: empty priority list; nothing to drain"
    return 0
  fi

  local name
  for name in "${names[@]}"; do
    attempted=$((attempted + 1))
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
      _shed_log stage1 "skip ${name} (not running)"
      continue
    fi
    if _shed_dry stage1 "docker stop --time 10 ${name}"; then
      stopped=$((stopped + 1))
      continue
    fi
    if docker stop --time 10 "${name}" >/dev/null 2>>"${LOG_FILE}"; then
      stopped=$((stopped + 1))
      _shed_log stage1 "stopped ${name}"
    else
      _shed_log stage1 "docker stop ${name} failed (continuing chain)"
    fi
  done

  _shed_log stage1 "summary: attempted=${attempted} stopped=${stopped}"
  return 0
}

# ---------------- Stage 2: Reclaim QEMU ----------------
# Resolve QEMU cgroup (v2 unified) and ask the kernel to release its
# reclaimable memory. `memory.reclaim` is a no-op when RSS is already
# below high water — safe to call repeatedly (idempotent).
#
# R4 lane T (ez-gh-actions-r3f11): the original write of `1` (a single
# byte) was rejected by the kernel as effectively a no-op — cgroup-v2
# `memory.reclaim` interprets the value as "reclaim UP TO <N> bytes". A
# 1-byte target is satisfied instantly and the kernel does nothing
# meaningful. Write SHED_RECLAIM_TARGET_BYTES (default 8 GiB) instead.
# The kernel simply stops when it has freed that much OR when it runs
# out of reclaimable pages; either is fine. If memory.high or
# memory.max for the cgroup is reachable and lower, prefer 0 (the kernel
# treats 0 as "reclaim up to your limit" per cgroup-v2 docs). We write
# 8 GiB as a defensive lower bound — large enough that an actual multi-
# GiB QEMU RSS drop is achievable in SHED_VERIFY_DELAY seconds, small
# enough that a healthy QEMU at 4 GiB won't be pummeled.
stage2_reclaim_qemu() {
  local reclaim_target_bytes="${SHED_RECLAIM_TARGET_BYTES:-8589934592}"   # 8 GiB
  SHED_QEMU_PID="$(pgrep -f qemu-system-x86_64 2>/dev/null | head -1 || true)"
  if [ -z "${SHED_QEMU_PID}" ]; then
    _shed_log stage2 "no qemu-system-x86_64 pid found — skipping reclaim"
    return 0
  fi

  SHED_QEMU_CG="$(awk -F'::' '/^0:/{print $2; exit}' "/proc/${SHED_QEMU_PID}/cgroup" 2>/dev/null || true)"
  if [ -z "${SHED_QEMU_CG}" ]; then
    # Defensive fallback: also strip the `0::` prefix from any cgroup-v2 line
    # in case the kernel format has shifted (e.g. controller id changed).
    SHED_QEMU_CG="$(awk -F':' '{ for (i=1;i<=NF;i++) if (match($i, "^/")) { print $i; exit } }' "/proc/${SHED_QEMU_PID}/cgroup" 2>/dev/null || true)"
  fi
  if [ -z "${SHED_QEMU_CG}" ]; then
    _shed_log stage2 "no cgroup line for qemu pid=${SHED_QEMU_PID} — skipping reclaim"
    return 0
  fi

  SHED_QEMU_CG_PATH="/sys/fs/cgroup${SHED_QEMU_CG}"
  if [ ! -w "${SHED_QEMU_CG_PATH}/memory.reclaim" ]; then
    if _shed_dry stage2 "write ${reclaim_target_bytes} to ${SHED_QEMU_CG_PATH}/memory.reclaim (skipping: not writable)"; then
      return 0
    fi
    _shed_log stage2 "${SHED_QEMU_CG_PATH}/memory.reclaim not writable — skipping reclaim (likely needs root or v1 cgroup)"
    return 0
  fi

  if _shed_dry stage2 "printf %d > ${SHED_QEMU_CG_PATH}/memory.reclaim (target_bytes=${reclaim_target_bytes})"; then
    return 0
  fi

  # R4 lane T (ez-gh-actions-r3f11): multi-GiB target so the kernel
  # actually does meaningful reclaim work. The kernel parses the value as
  # a decimal byte count and reclaims up to that many bytes.
  if printf '%d\n' "${reclaim_target_bytes}" > "${SHED_QEMU_CG_PATH}/memory.reclaim" 2>>"${LOG_FILE}"; then
    _shed_log stage2 "wrote ${reclaim_target_bytes} bytes (8 GiB) to ${SHED_QEMU_CG_PATH}/memory.reclaim (pid=${SHED_QEMU_PID})"
  else
    _shed_log stage2 "write to memory.reclaim failed (continuing chain)"
  fi
  return 0
}

# ---------------- Stage 3: Verify ----------------
# R4 lane T (ez-gh-actions-r3f11): the previous version of this stage
# captured baseline RSS HERE, which was already AFTER stages 1+2 had run
# (drain had stopped containers, reclaim had told the kernel to free
# memory). That made the comparison `baseline - now` always near zero
# (or even negative under further compaction / page-cache churn), so the
# "ok" branch was effectively unconditional. Fix: capture baseline RSS
# UP-FRONT in `run_shed_stages` (BEFORE stage1_drain), stash it via the
# exported `SHED_BASELINE_RSS`, and have this stage consume that
# pre-drain snapshot only. Falls back to local capture if the variable
# is empty (e.g. this stage invoked in isolation by a test stub).
stage3_verify() {
  local baseline now kb_drop
  # Prefer the pre-drain baseline captured by run_shed_stages.
  baseline="${SHED_BASELINE_RSS:-}"
  if [ -z "${baseline}" ]; then
    # Fallback path: stage called in isolation. We still capture
    # immediately (which is honest, since nothing has happened yet),
    # but log that we're falling back so test stubs can be fixed.
    if [ -z "${SHED_QEMU_PID}" ] || ! [ -r "/proc/${SHED_QEMU_PID}/status" ]; then
      _shed_log stage3 "no live qemu pid to verify against — cannot declare success"
      SHED_RESULT="fail"
      return 0
    fi
    baseline="$(awk '/^VmRSS:/{print $2; exit}' "/proc/${SHED_QEMU_PID}/status" 2>/dev/null || echo 0)"
    _shed_log stage3 "fallback baseline (no SHED_BASELINE_RSS staged) RSS=${baseline} kB"
  fi

  if [ -z "${SHED_QEMU_PID}" ] || ! [ -r "/proc/${SHED_QEMU_PID}/status" ]; then
    _shed_log stage3 "no live qemu pid to verify against — cannot declare success"
    SHED_RESULT="fail"
    return 0
  fi

  _shed_log stage3 "pre-drain baseline RSS=${baseline} kB (pid=${SHED_QEMU_PID}); sleeping ${SHED_VERIFY_DELAY}s"
  sleep "${SHED_VERIFY_DELAY}"
  now="$(awk '/^VmRSS:/{print $2; exit}' "/proc/${SHED_QEMU_PID}/status" 2>/dev/null || echo 0)"
  kb_drop=$((baseline - now))
  _shed_log stage3 "post-RSS=${now} kB drop=${kb_drop} kB (target>=${RSS_DROP_MIN_KB})"

  if [ "${kb_drop}" -ge "${RSS_DROP_MIN_KB}" ]; then
    SHED_RESULT="ok"
  else
    SHED_RESULT="fail"
  fi
  return 0
}

# ---------------- Stage 4: Escalate ----------------
# Marker file (world-readable so watchdog without sudo can read it),
# CRITICAL log line, and non-zero exit. Idempotent: rewriting a present
# flag refreshes its mtime but does not change the meaning.
stage4_escalate() {
  mkdir -p "${SHED_FLAG_DIR}" 2>/dev/null || true
  chmod 0755 "${SHED_FLAG_DIR}" 2>/dev/null || true

  local ts reason pressure streak_info
  ts="$(date -u +%FT%TZ)"
  pressure="${full_avg10:-n/a}"
  streak_info="${streak:-n/a}"
  reason="qemu RSS did not drop >= ${RSS_DROP_MIN_KB} kB after stage1+stage2 (full avg10=${pressure}, streak=${streak_info})"
  if _shed_dry stage4 "write escalation flag ${SHED_FLAG_FILE} (reason=${reason})"; then
    return 0
  fi

  # Atomically (to the extent `install` allows) write a 0644 flag with the
  # reason embedded so the watchdog / next boot can read it directly.
  umask 0222 || true   # ensure resulting file is world-readable
  printf 'shed_escalate_at=%s reason=%s\n' "${ts}" "${reason}" > "${SHED_FLAG_FILE}.tmp" 2>>"${LOG_FILE}" \
    && mv -f "${SHED_FLAG_FILE}.tmp" "${SHED_FLAG_FILE}" 2>>"${LOG_FILE}" \
    || _shed_log stage4 "failed to write escalation flag at ${SHED_FLAG_FILE}"
  chmod 0644 "${SHED_FLAG_FILE}" 2>/dev/null || true

  _shed_log stage4 "CRITICAL ${reason}; escalation flag written to ${SHED_FLAG_FILE}"
  return 1   # signal the caller that chain did not free enough memory
}

# ---------------- Dispatcher ----------------
run_shed_stages() {
  SHED_RESULT=""
  SHED_BASELINE_RSS=""
  # R4 lane T (ez-gh-actions-r3f11): capture pre-drain RSS BEFORE
  # stage1_drain so the verify stage measures an HONEST delta. Stage 2
  # populates SHED_QEMU_PID lazily; if it's still empty (no qemu running),
  # we leave SHED_BASELINE_RSS empty too and stage3_verify falls back to
  # its in-stage capture path.
  SHED_QEMU_PID_TMP="$(pgrep -f qemu-system-x86_64 2>/dev/null | head -1 || true)"
  if [ -n "${SHED_QEMU_PID_TMP}" ] && [ -r "/proc/${SHED_QEMU_PID_TMP}/status" ]; then
    SHED_BASELINE_RSS="$(awk '/^VmRSS:/{print $2; exit}' "/proc/${SHED_QEMU_PID_TMP}/status" 2>/dev/null || echo 0)"
  fi
  _shed_log chain "begin dry_run=${DRY_RUN} priority_file='${PRIORITY_FILE}' low_priority='${LOW_PRIORITY_CONTAINERS}' pre_drain_baseline_rss_kB=${SHED_BASELINE_RSS:-n/a}"
  stage1_drain
  stage2_reclaim_qemu
  stage3_verify
  if [ "${SHED_RESULT}" = "ok" ]; then
    _shed_log chain "OK — watchdog may continue to wait; suppressing per-process SIGTERM fallback"
    return 0
  fi
  stage4_escalate || return 1
  return 0
}

# ---------------- CLI surface for the shed block ----------------
# Allow `scripts/host/psi-oom-watcher.sh --shed` to run ONLY the shed
# dispatch (outside the polling loop) for hand-driven pressure tests.
# Also parse --dry-run / --priority-file flags at top level BEFORE the
# normal watcher loop, so the existing dry-run path keeps its meaning.
_parse_shed_args() {
  while [ "${1:-}" != "" ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --priority-file) shift; PRIORITY_FILE="${1:-}" ;;
      --priority-file=*) PRIORITY_FILE="${1#--priority-file=}" ;;
      --shed) _shed_mode=1 ;;
      --shed=*) _shed_mode=1; PSI_SHED_CHAIN="${1#--shed=}" ;;
      --help|-h) _shed_show_help=1 ;;
      *) ;;  # silently ignore unknown — the watcher accepts positional args historically
    esac
    shift || true
  done
}

_shed_show_help() {
  cat <<EOF
psi-oom-watcher.sh — PSI early-warning + staged QEMU/RSS shed (R3 lane J, R4 lane T)

Polling mode (default):
  scripts/host/psi-oom-watcher.sh             # run one polling tick
  DRY_RUN=1 scripts/host/psi-oom-watcher.sh   # one polling tick, log only

Shed chain (R3 lane J, ez-gh-actions-6478; R4 mandatory chain):
  scripts/host/psi-oom-watcher.sh --shed [--dry-run] \\
    [--priority-file /path/to/low-priority.list]
  scripts/host/psi-oom-watcher.sh --shed=drain,reclaim,verify,escalate [--dry-run]

Environment:
  WARN_THRESHOLD, CRIT_THRESHOLD, CRIT_CONSECUTIVE, COOLDOWN_SEC
  LOW_PRIORITY_CONTAINERS    space-separated list (default has 4)
  PRIORITY_FILE              optional list file (one name per line, # comments)
  RSS_DROP_MIN_KB            verify threshold (default 1048576 = 1 GiB)
  SHED_VERIFY_DELAY          seconds between reclaim and verify (default 5)
  SHED_RECLAIM_TARGET_BYTES  reclaim target (default 8589934592 = 8 GiB)
  DRY_RUN                    1 = no-op every stage, log only
  PSI_SHED_CHAIN             mandatory at timer invocation (default: drain,reclaim,verify,escalate)
                             empty/unset -> exit 64 fail-closed (R4 lane T fix)

Stages:
  1 drain     — docker stop --time 10 <name> for each low-priority container
  2 reclaim   — printf %d > <qemu-cgroup>/memory.reclaim (kernel, no signal; default 8 GiB)
  3 verify    — sleep SHED_VERIFY_DELAY, measure qemu VmRSS drop vs PRE-DRAIN baseline
  4 escalate  — write world-readable flag at \${SHED_FLAG_FILE}, log CRITICAL
EOF
}

# R4 lane T (ez-gh-actions-r3f10): validate PSI_SHED_CHAIN.
#
# Behavior (as specified):
#   * Strict mode (poll timer / --shed invocation, NOT --dry-run):
#       - empty/missing chain -> exit 64, fail-closed.
#       - chain present but missing one or more of the 4 canonical stages
#         -> also exit 64 (a chain without verify/escalate is not the
#         staged shed the cold review required).
#   * Dry-run mode (--dry-run):
#       - empty/missing chain -> still log the fail-closed message AND
#         print the plan, exit 0 (so the verifier can SEE the dry-run
#         output and the install-owner can see what's missing).
#       - chain present but missing stages -> log "incomplete chain"
#         WARNING, still print the plan, exit 0.
#
# `strict` is 1 by default; 0 means dry-run (warn-but-print-plan).
_validate_shed_chain() {
  local strict="${1:-1}"
  local chain="${PSI_SHED_CHAIN:-}"
  local canon="${DEFAULT_PSI_SHED_CHAIN}"
  if [ -z "${chain}" ]; then
    if [ "${strict}" = "1" ]; then
      printf '[%s] [FAIL] PSI_SHED_CHAIN is empty; the staged shed chain is mandatory for the host-pressure reliability boundary. Set Environment=PSI_SHED_CHAIN=<stages> in the .service or use the --shed=<chain> CLI flag.\n' "$(date -u +%FT%TZ)" | tee -a "${LOG_FILE}" >&2
      exit 64
    fi
    log "shed-chain WARNING: PSI_SHED_CHAIN is empty; --dry-run printing plan only, no chain will run"
    return 0
  fi

  # Compare each canonical stage (order-independent for validity check;
  # execution order is fixed in run_shed_stages).
  local stage missing=0
  for stage in drain reclaim verify escalate; do
    case ",${chain}," in
      *,"${stage}",*) ;;
      *) missing=$((missing + 1));;
    esac
  done
  if [ "${missing}" -gt 0 ]; then
    if [ "${strict}" = "1" ]; then
      printf '[%s] [FAIL] PSI_SHED_CHAIN=%q is incomplete (missing %d of 4 canonical stages: drain,reclaim,verify,escalate). Aborting; a staged shed missing stages is no defense at all.\n' "$(date -u +%FT%TZ)" "${chain}" "${missing}" | tee -a "${LOG_FILE}" >&2
      exit 64
    fi
    log "shed-chain WARNING: incomplete chain PSI_SHED_CHAIN=${chain} (missing stages: ${chain} vs canonical ${DEFAULT_PSI_SHED_CHAIN}); --dry-run printing plan only"
  fi
  return 0
}

# Now that all shed functions are defined, parse CLI flags and short-circuit
# --help / --shed modes BEFORE the PSI read so they work even when
# /proc/pressure/memory is missing (e.g. macOS smoke test, CI environment).
_parse_shed_args "$@"

if [ "${_shed_show_help:-0}" = "1" ]; then
  _shed_show_help
  exit 0
fi
if [ "${_shed_mode:-0}" = "1" ]; then
  # R4 lane T (ez-gh-actions-r3f10): explicit --shed mode ALSO fails-closed
  # on an empty/incomplete chain unless --dry-run was passed (where we
  # warn-but-print-plan so the verifier can SEE the dry-run output).
  _validate_shed_chain "$( [ "${DRY_RUN}" = "1" ] && echo 0 || echo 1 )"
  log "shed-mode invoked (dry_run=${DRY_RUN} priority_file='${PRIORITY_FILE}' chain='${PSI_SHED_CHAIN}')"
  if run_shed_stages; then
    log "shed-mode: SHED_RESULT=${SHED_RESULT}"
    exit 0
  fi
  log "shed-mode: SHED_RESULT=${SHED_RESULT} (chain failed; watchdog-wait flag raised)"
  exit 1
fi

# R4 lane T (ez-gh-actions-r3f10): polling-mode (timer-fired) entry must
# also fail-closed on an empty/incomplete PSI_SHED_CHAIN. The .service
# unit's `Environment=PSI_SHED_CHAIN=drain,reclaim,verify,escalate` line
# is what populates this for a fresh install; if it is missing, we
# refuse to run rather than silently fall back to the round-1 single-
# process SIGTERM behavior (which the round-3 cold review flagged as
# "staged shed that isn't wired up is no defense").
_validate_shed_chain 1


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

# R3 lane J (ez-gh-actions-6478): when PSI_SHED_CHAIN is set, run the staged
# shed chain FIRST. If it recovers enough memory, the watchdog stays armed
# and the per-process SIGTERM fallback below is suppressed for this tick.
if [ -n "${PSI_SHED_CHAIN}" ]; then
  if run_shed_stages && [ "${SHED_RESULT}" = "ok" ]; then
    log "ACTION(staged-shed): SHED_RESULT=ok — per-process SIGTERM fallback suppressed for this tick (cooldown still armed; full avg10=${full_avg10}%, streak=${streak}/${CRIT_CONSECUTIVE})"
    echo "${now_epoch}" > "${COOLDOWN_MARKER}"
    rm -f "${STREAK_FILE}"
    exit 0
  fi
  log "ACTION(staged-shed): SHED_RESULT=${SHED_RESULT:-fail} — falling through to per-process SIGTERM fallback"
fi

log "ACTION: sending SIGTERM to pid=${target_pid} comm=${target_comm} rss=${target_rss_mb}MB — sustained memory pressure full avg10=${full_avg10}% for ${streak} consecutive polls. Cooldown ${COOLDOWN_SEC}s starts now."
if kill -TERM "${target_pid}" 2>>"${LOG_FILE}"; then
  log "SIGTERM delivered to pid=${target_pid}."
else
  log "SIGTERM delivery to pid=${target_pid} FAILED (process may have already exited)."
fi

echo "${now_epoch}" > "${COOLDOWN_MARKER}"
rm -f "${STREAK_FILE}"

