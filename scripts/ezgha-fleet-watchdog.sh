#!/usr/bin/env bash
# ezgha-fleet-watchdog.sh — enforce configured mac + linux runner count.
#
# Replaces the unversioned ~/.local/bin/ezgha-fleet-watchdog.sh (bead
# ez-gh-actions-2ik). Detects when the ezgha serve supervisor is alive but
# below the configured runner count (a known ezgha design gap: serve
# replaces churned slots but does not aggressively top up to N when below
# count) and restarts the supervisor on the affected host — but only after
# durable guardrails pass, added because the old script's "restart on any
# single below-target tick" behavior restarted ezgha.service 15 times in 3
# hours during a 2026-07-08 fleet churn incident. Since the daemon has zero
# SIGTERM handling, every one of those restarts orphaned in-flight GitHub
# runner registrations that a separate reaper then had to clean up.
#
# Guardrails (new in this version):
#   1. N=3 consecutive-miss threshold — do not restart on the first
#      below-target observation. A "miss" only counts when BOTH actual
#      managed-container count AND reserved-slot count are below the
#      configured target (the pre-existing ephemeral-churn guard). The
#      counter persists between invocations in a small per-host state file
#      under $EZGHA_WATCHDOG_STATE_DIR, since each systemd timer firing is a
#      fresh, stateless process. The counter resets to 0 on any tick that is
#      at-or-above target. A below-target-but-churning tick (slots still
#      cover target) leaves the counter untouched — it is not a real miss,
#      but it is also not evidence the fleet has recovered.
#   2. Load gate — before restarting, check the 1-minute load average and
#      SKIP the restart (log only, counter left unchanged) if it exceeds
#      $EZGHA_WATCHDOG_LOAD_THRESHOLD (default 12). Mirrors the pre-restart
#      check in this repo's CLAUDE.md Gate 0 section: mass cold respawns
#      under high load have tripped the host watchdog (max-load-1=24) and
#      rebooted the box twice. Applied to both hosts for consistency, even
#      though the mac path (launchctl kickstart) is lighter-weight than a
#      full systemd service restart.
#   3. Cooldown — no more than 1 restart per host per
#      $EZGHA_WATCHDOG_COOLDOWN_SECONDS (default 1800s / 30min), tracked via
#      a per-host last-restart timestamp state file. A restart attempt
#      inside the cooldown window is skipped and logged; the miss counter is
#      left as-is so the next eligible tick after cooldown expiry can act
#      immediately without waiting for 3 more fresh misses.
#   4. No duplicate logging — this script no longer tees its own log lines
#      to a file. Under the shipped systemd unit, `StandardOutput=append:...`
#      / `StandardError=append:...` captures stdout/stderr for you (see
#      systemd/ezgha-watchdog.service). Running this script by hand outside
#      systemd prints to the terminal only; redirect yourself if you want a
#      file (`./ezgha-fleet-watchdog.sh --dry-run >> /tmp/watchdog.log 2>&1`).
#      The old external script used `tee -a` INSIDE `log()` while the
#      systemd unit ALSO captured stdout via StandardOutput=append to the
#      SAME file — every line was written twice.
#   5. State freshness — miss_count and last_restart state files are
#      treated as stale (reset to 0 on read) by read_fresh_state() when
#      EITHER of two independent checks trips. Both are applied uniformly
#      by get_miss_count() and get_last_restart():
#        a) REBOOT guard (primary) — the state file's mtime predates the
#           current host boot time (Linux: /proc/stat `btime`; macOS:
#           `sysctl kern.boottime`). State files are plain files under
#           ~/.local/state, not tmpfs, so they survive a reboot, and the
#           systemd timer then fires 30s after boot (OnBootSec=30s). A
#           stale miss_count>=threshold left over from before the reboot
#           could otherwise restart a daemon that hasn't finished starting
#           (0 containers is legitimate mid-boot — the exact orphan-
#           registration harm this PR exists to prevent), and a stale-but-
#           recent last_restart could wrongly block a genuinely-needed
#           post-reboot restart for the full cooldown window. This check is
#           what catches a FAST reboot that the age backstop (b) would
#           miss: if the box reboots quickly, pre-reboot state can be
#           YOUNGER than STATE_STALE_SECONDS yet still belong to a dead
#           boot session. Fails safe — if boot time cannot be determined,
#           this check is skipped and behavior falls back to (b) alone, so
#           no new failure mode is introduced (bead ez-gh-actions-xfw).
#        b) AGE backstop (general staleness) — the file's mtime is older
#           than $EZGHA_WATCHDOG_STATE_STALE_SECONDS (default 480s / 8min —
#           4x the systemd timer's 120s tick interval, tolerating up to 3
#           skipped/slow ticks; inside the 6-10min band that keeps
#           genuinely-consecutive misses in a live run from ever being
#           mistaken for stale). Covers non-reboot staleness: e.g. the
#           watchdog was stopped for an extended period, or a timer tick
#           was skipped/delayed (system load, or a hung probe before the
#           C#2 timeout fix landed), leaving old counters to linger.
#      Because both checks apply on READ, a stale miss_count is normalized
#      to 0 BEFORE the current tick's increment/comparison in
#      evaluate_host() — a stale count can never combine with a fresh miss
#      to reach the threshold early.
#   6. Host-mismatch guard (both hosts) — check_mac() and check_linux()
#      each skip (log only) when invoked bare (no explicit --host filter)
#      on a host that doesn't match, rather than silently reading/acting on
#      the OTHER host's state via ssh. Without this, a bare invocation on
#      the Mac would run check_linux() over ssh using the Mac's own local
#      state files — a second, uncoordinated watchdog instance racing
#      against jeff-ubuntu's own systemd-timer-driven instance (separate
#      miss counters, separate cooldowns) against the SAME remote daemon.
#      Use `--host mac` / `--host linux` explicitly to force a cross-host
#      check.
#   7. Probe timeouts — every ezgha status probe and ssh invocation is
#      wrapped in `timeout 30 ...`. A hung probe (or a hung remote command —
#      ssh's own -o ConnectTimeout=5 only bounds the TCP handshake, not a
#      stuck remote process) would otherwise wedge this script's
#      `Type=oneshot` systemd unit indefinitely; since OnUnitActiveSec never
#      re-fires while the unit is still running, a single hang would
#      silently disable the watchdog exactly when the fleet needs it.
#      systemd/ezgha-watchdog.service also sets TimeoutStartSec=90 as an
#      independent backstop.
#
# Usage:
#   ./ezgha-fleet-watchdog.sh                  # check both hosts, fix if needed
#   ./ezgha-fleet-watchdog.sh --host mac       # only MacBook
#   ./ezgha-fleet-watchdog.sh --host linux     # only jeff-ubuntu
#   ./ezgha-fleet-watchdog.sh --dry-run        # report only, do not restart or mutate state
#
# Exit codes:
#   0 = both checked hosts at or above configured count (or a restart fired)
#   1 = one or more hosts below count and no restart was performed this tick
#       (waiting for miss threshold, in cooldown, load gate tripped, or dry-run)
#   2 = supervisor not installed / state unreadable on one or more hosts /
#       bad CLI arguments
#
# Env overrides (mainly for testing):
#   EZGHA_BIN                       ezgha binary path (default: $HOME/.cargo/bin/ezgha)
#   EZGHA_WATCHDOG_STATE_DIR        state dir (default: $HOME/.local/state/ezgha/watchdog)
#   EZGHA_WATCHDOG_MISS_THRESHOLD   consecutive misses before restart (default: 3)
#   EZGHA_WATCHDOG_LOAD_THRESHOLD   1-min load ceiling for restart (default: 12)
#   EZGHA_WATCHDOG_COOLDOWN_SECONDS minimum seconds between restarts per host (default: 1800)
#   EZGHA_WATCHDOG_STATE_STALE_SECONDS
#                                   max state-file age before miss_count/last_restart
#                                   are treated as stale and reset to 0 (default: 480)

set -uo pipefail

EZGHA="${EZGHA_BIN:-$HOME/.cargo/bin/ezgha}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DRY_RUN=0
HOST_FILTER=""

STATE_DIR="${EZGHA_WATCHDOG_STATE_DIR:-$HOME/.local/state/ezgha/watchdog}"
MISS_THRESHOLD="${EZGHA_WATCHDOG_MISS_THRESHOLD:-3}"
LOAD_THRESHOLD="${EZGHA_WATCHDOG_LOAD_THRESHOLD:-12}"
COOLDOWN_SECONDS="${EZGHA_WATCHDOG_COOLDOWN_SECONDS:-1800}"
# See guardrail 5 in the header comment above for the full rationale on this
# default (4x the 120s timer tick interval, inside the 6-10min band).
STATE_STALE_SECONDS="${EZGHA_WATCHDOG_STATE_STALE_SECONDS:-480}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --host requires an argument (mac|linux)" >&2
        exit 2
      fi
      HOST_FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,124p' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

log() { echo "[$TS] $*"; }

mkdir -p "$STATE_DIR" 2>/dev/null || true

# parse_bsd_boottime extracts the boot epoch (the `sec` field) from macOS/BSD
# `sysctl kern.boottime` output, read on stdin
# ("{ sec = 1700000000, usec = 0 } Mon ..."). The `^[{ ]*` anchor is
# load-bearing: a naive `.*sec` is GREEDY and matches the LAST "sec" in the
# string — the "usec" substring — capturing microseconds (0..999999) instead
# of the epoch, which would silently break the reboot guard on every Mac
# (bead ez-gh-actions-xfw skeptic finding). Anchoring to the leading `{`/
# spaces forces the FIRST "sec" (the epoch). Factored out of boot_time() so
# it can be unit-tested against a literal fixture on non-macOS CI, where
# boot_time() itself always takes the Linux /proc/stat branch.
parse_bsd_boottime() { # stdin: sysctl kern.boottime output -> epoch seconds
  sed -E 's/^[{ ]*sec *= *([0-9]+).*/\1/'
}

# boot_time prints the host's boot time in epoch seconds, or nothing if it
# cannot be determined. Linux: the `btime <epoch>` line in /proc/stat.
# macOS/BSD: `sysctl kern.boottime` via parse_bsd_boottime (see above).
# An unknown boot time is left empty ON PURPOSE so read_fresh_state's
# reboot guard (guardrail 5a) degrades to a no-op — preserving prior
# behavior rather than guessing and risking a new failure mode.
boot_time() {
  local bt=""
  if [[ -r /proc/stat ]]; then
    bt="$(awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null || true)"
  fi
  if [[ ! "$bt" =~ ^[0-9]+$ ]]; then
    bt="$(sysctl -n kern.boottime 2>/dev/null | parse_bsd_boottime || true)"
  fi
  [[ "$bt" =~ ^[0-9]+$ ]] && echo "$bt"
}

# Boot time is fixed for the life of the host, so resolve it once here
# instead of on every read_fresh_state() call. Empty when undeterminable.
BOOT_TIME="$(boot_time)"

# read_fresh_state prints the value stored in state file $1, unless the
# file is considered stale, in which case "0" is printed instead
# (guardrail 5). A file is stale if EITHER (a) its mtime predates the
# current boot time ($BOOT_TIME) — the REBOOT guard — OR (b) its mtime is
# older than $STATE_STALE_SECONDS — the general-staleness AGE backstop. The
# reboot check is what catches a FAST reboot whose pre-reboot state is
# still younger than STATE_STALE_SECONDS (a reboot is one way a state file
# can belong to a dead boot session while still looking recent); the age
# check catches non-reboot staleness. Used by BOTH get_miss_count() and
# get_last_restart(). Fails safe at every step: missing file -> "0" (base
# case); unreadable mtime -> NOT treated as stale (falls through to the
# stored value) rather than crashing or guessing; unknown $BOOT_TIME ->
# reboot check skipped, age check still applies (bead ez-gh-actions-xfw).
read_fresh_state() { # $1=state file path -> stored value, or 0 if missing/stale
  local file="$1"
  [[ -f "$file" ]] || { echo 0; return; }

  local mtime
  mtime="$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || true)"
  if [[ "$mtime" =~ ^[0-9]+$ ]]; then
    # (a) REBOOT guard: state written before the current boot cannot
    # describe the current boot session. Applies even to a file younger
    # than STATE_STALE_SECONDS. Skipped when boot time is unknown.
    if [[ "$BOOT_TIME" =~ ^[0-9]+$ ]] && (( mtime < BOOT_TIME )); then
      echo 0
      return
    fi
    # (b) AGE backstop: non-reboot staleness.
    local now
    now="$(date +%s)"
    if (( now - mtime > STATE_STALE_SECONDS )); then
      echo 0
      return
    fi
  fi

  cat "$file" 2>/dev/null || echo 0
}

get_miss_count() { # $1=host
  read_fresh_state "$STATE_DIR/$1.miss_count"
}

set_miss_count() { # $1=host $2=count
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  echo "$2" > "$STATE_DIR/$1.miss_count"
}

set_miss_threshold() { # $1=host
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  echo "$MISS_THRESHOLD" > "$STATE_DIR/$1.miss_threshold"
}

get_last_restart() { # $1=host -> epoch seconds, 0 if never
  read_fresh_state "$STATE_DIR/$1.last_restart"
}

set_last_restart() { # $1=host $2=epoch
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  echo "$2" > "$STATE_DIR/$1.last_restart"
}

cooldown_active() { # $1=host -> 0 (true/active) or 1 (false/clear)
  local last now
  last="$(get_last_restart "$1")"
  now="$(date +%s)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last < COOLDOWN_SECONDS ))
}

load_1min() {
  if [[ -r /proc/loadavg ]]; then
    awk '{print $1}' /proc/loadavg
  else
    # macOS / BSD uptime has no /proc/loadavg; parse "load averages: 1.23 ..."
    uptime | sed -E 's/.*load averages?:? *([0-9.]+).*/\1/'
  fi
}

load_gate_ok() {
  local load
  load="$(load_1min 2>/dev/null || echo 0)"
  awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN { exit !(l+0 <= t+0) }'
}

slot_count() {
  # NOTE: `grep -c PATTERN file || echo 0` is a latent bug inherited from the
  # original external script — when the file exists but has zero matches,
  # `grep -c` itself prints "0" to stdout AND exits 1, so the `||` fallback
  # ALSO echoes "0", yielding a corrupted two-line "0\n0" value. Capture into
  # a variable first so only one value is ever emitted.
  local n
  n="$(grep -c '=' "$HOME/.config/ezgha/slot_assignments.toml" 2>/dev/null)"
  echo "${n:-0}"
}

# shellcheck disable=SC2317  # invoked indirectly via evaluate_host's $restart_fn
do_restart_mac() {
  launchctl kickstart -k "gui/$(id -u)/org.jleechanorg.ezgha" 2>&1
}

# shellcheck disable=SC2317  # invoked indirectly via evaluate_host's $restart_fn
do_restart_linux() {
  if [[ "$(uname -s)" == "Linux" ]]; then
    systemctl --user restart ezgha.service 2>&1
  else
    timeout 30 ssh -o ConnectTimeout=5 jeff-ubuntu "systemctl --user restart ezgha.service" 2>&1
  fi
}

# evaluate_host applies the miss-threshold / cooldown / load-gate guardrails
# and restarts via $5 (a function name) only when all three clear.
# Returns: 0 = at target or restart fired; 1 = below target, no action taken.
evaluate_host() {
  local host="$1" configured="$2" actual="$3" slots="$4" restart_fn="$5"
  local label
  label="$(echo "$host" | tr '[:lower:]' '[:upper:]')"
  set_miss_threshold "$host"

  log "$label: configured=$configured, managed=$actual, slots=$slots"

  if [[ "$actual" -ge "$configured" ]]; then
    set_miss_count "$host" 0
    return 0
  fi

  if [[ "$slots" -ge "$configured" ]]; then
    log "$label: managed containers below target but all slots are reserved; assuming ephemeral churn, no restart (miss counter unchanged)"
    return 0
  fi

  local misses
  misses="$(get_miss_count "$host")"
  [[ "$misses" =~ ^[0-9]+$ ]] || misses=0
  misses=$((misses + 1))
  set_miss_count "$host" "$misses"
  log "$label: BELOW TARGET ($actual < $configured, slots=$slots < $configured) — consecutive miss $misses/$MISS_THRESHOLD"

  if (( misses < MISS_THRESHOLD )); then
    log "$label: waiting for $MISS_THRESHOLD consecutive misses before restarting (currently $misses)"
    return 1
  fi

  if cooldown_active "$host"; then
    log "$label: restart threshold reached but a restart already happened within the last $((COOLDOWN_SECONDS / 60)) minutes — skipping (cooldown); miss counter left at $misses"
    return 1
  fi

  if ! load_gate_ok; then
    log "$label: restart threshold reached but 1-min load average ($(load_1min)) exceeds $LOAD_THRESHOLD — skipping restart (load gate); miss counter NOT reset"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "$label: DRY-RUN — would restart now (miss=$misses >= $MISS_THRESHOLD, cooldown clear, load ok)"
    return 1
  fi

  log "$label: RESTARTING (miss=$misses >= $MISS_THRESHOLD, cooldown clear, load ok)"
  local restart_output restart_rc=0
  restart_output="$("$restart_fn" 2>&1)" || restart_rc=$?
  while IFS= read -r line; do log "$label: $line"; done <<< "$restart_output"
  if [[ "$restart_rc" -eq 0 ]]; then
    set_last_restart "$host" "$(date +%s)"
    set_miss_count "$host" 0
  else
    log "$label: RESTART FAILED (exit=$restart_rc) — miss counter and last-restart NOT updated, will retry next eligible tick"
  fi
  return 0
}

check_mac() {
  if [[ -n "$HOST_FILTER" && "$HOST_FILTER" != "mac" ]]; then return 0; fi
  # KNOWN GAP: unlike check_linux(), this function has no ssh-based remote
  # fallback for reaching the actual Mac host from a non-Mac invoker — this
  # repo has no established `ssh macbook`-style convention to mirror (only
  # `ssh jeff-ubuntu` exists). If invoked bare (no --host mac) on a non-Darwin
  # host, it would otherwise silently read the LOCAL host's own ezgha state
  # and mislabel it "MAC". Guard against that footgun explicitly. This is not
  # exploitable in production today because the shipped
  # systemd/ezgha-watchdog.service always passes --host linux, which skips
  # this function entirely via the HOST_FILTER check above.
  if [[ "$(uname -s)" != "Darwin" && "$HOST_FILTER" != "mac" ]]; then
    log "MAC: skipping — running on non-Darwin host with no explicit --host mac filter (no ssh fallback implemented; see comment above check_mac)"
    return 0
  fi
  if ! command -v "$EZGHA" >/dev/null 2>&1; then
    log "MAC: ezgha binary not found at $EZGHA"
    return 2
  fi

  local configured actual slots config_file="$HOME/.config/ezgha/config.toml"
  configured=$(grep -E "^count = " "$config_file" 2>/dev/null | grep -oE "[0-9]+")
  actual=$(timeout 30 "$EZGHA" status 2>/dev/null | grep -oE "managed containers: [0-9]+" | grep -oE "[0-9]+")
  slots=$(slot_count)

  if [[ -z "$configured" || -z "$actual" ]]; then
    log "MAC: cannot read state (config=$configured actual=$actual)"
    return 2
  fi

  evaluate_host "mac" "$configured" "$actual" "$slots" do_restart_mac
}

check_linux() {
  if [[ -n "$HOST_FILTER" && "$HOST_FILTER" != "linux" ]]; then return 0; fi
  # Mirror of check_mac()'s Darwin guard. This function has an ssh-based
  # remote path (below) that lets it manage jeff-ubuntu from a non-Linux
  # host (e.g. running this script by hand on the Mac). That path reads and
  # writes state files under THIS invoking host's own
  # $EZGHA_WATCHDOG_STATE_DIR — completely independent of the
  # miss-counter/last-restart state kept by the watchdog process that
  # already runs natively ON jeff-ubuntu via the shipped systemd unit
  # (systemd/ezgha-watchdog.service, which always passes --host linux). Two
  # uncoordinated processes tracking separate miss-counters for the SAME
  # remote daemon could each independently decide to restart it —
  # reintroducing the exact restart-flapping this whole PR exists to
  # prevent. Guard against a bare (no --host) invocation on a non-Linux host
  # exactly like check_mac() guards against a bare invocation on a
  # non-Darwin host; an explicit `--host linux` still opts in to the ssh
  # path deliberately.
  if [[ "$(uname -s)" != "Linux" && "$HOST_FILTER" != "linux" ]]; then
    log "LINUX: skipping — running on non-Linux host with no explicit --host linux filter (ssh path would use locally-scoped state uncoordinated with the native jeff-ubuntu watchdog; see comment above check_linux)"
    return 0
  fi
  local configured actual slots
  if [[ "$(uname -s)" == "Linux" ]]; then
    configured=$(grep -E "^count = " "$HOME/.config/ezgha/config.toml" 2>/dev/null | grep -oE "[0-9]+")
    actual=$(timeout 30 "$EZGHA" status 2>/dev/null | grep -oE "managed containers: [0-9]+" | grep -oE "[0-9]+")
    slots=$(slot_count)
  else
    configured=$(timeout 30 ssh -o ConnectTimeout=5 jeff-ubuntu 'grep -E "^count = " ~/.config/ezgha/config.toml 2>/dev/null | grep -oE "[0-9]+"' 2>/dev/null)
    # shellcheck disable=SC2016  # single quotes intentional: $HOME/$(...) must expand on the REMOTE host, not locally. (shellcheck normally recognizes this for a bare `ssh` invocation but loses that context once wrapped in `timeout`.)
    actual=$(timeout 30 ssh -o ConnectTimeout=5 jeff-ubuntu '$HOME/.cargo/bin/ezgha status 2>/dev/null | grep -oE "managed containers: [0-9]+" | grep -oE "[0-9]+"' 2>/dev/null)
    # Same single-value-capture fix as slot_count() above, applied inline
    # since this runs on the remote host via ssh rather than calling the
    # local function.
    # shellcheck disable=SC2016  # single quotes intentional: $(...) must run on the REMOTE host, not locally. (same shellcheck ssh-context quirk as above)
    slots=$(timeout 30 ssh -o ConnectTimeout=5 jeff-ubuntu 'n=$(grep -c "=" ~/.config/ezgha/slot_assignments.toml 2>/dev/null); echo "${n:-0}"' 2>/dev/null)
  fi

  if [[ -z "$configured" || -z "$actual" ]]; then
    log "LINUX: cannot read state (configured=$configured actual=$actual)"
    return 2
  fi

  evaluate_host "linux" "$configured" "$actual" "$slots" do_restart_linux
}

EXIT=0
check_mac || EXIT=$?
check_linux || EXIT=$?

if [[ "$EXIT" -eq 0 ]]; then
  log "OK: checked hosts at configured count (or restarted this tick)"
elif [[ "$EXIT" -eq 2 ]]; then
  log "WARN: one or more hosts missing ezgha or unreachable — manual intervention needed"
fi

exit $EXIT
