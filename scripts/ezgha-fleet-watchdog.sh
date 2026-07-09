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
#   2 = supervisor not installed / state unreadable on one or more hosts
#
# Env overrides (mainly for testing):
#   EZGHA_BIN                     ezgha binary path (default: $HOME/.cargo/bin/ezgha)
#   EZGHA_WATCHDOG_STATE_DIR      state dir (default: $HOME/.local/state/ezgha/watchdog)
#   EZGHA_WATCHDOG_MISS_THRESHOLD consecutive misses before restart (default: 3)
#   EZGHA_WATCHDOG_LOAD_THRESHOLD 1-min load ceiling for restart (default: 12)
#   EZGHA_WATCHDOG_COOLDOWN_SECONDS minimum seconds between restarts per host (default: 1800)

set -uo pipefail

EZGHA="${EZGHA_BIN:-$HOME/.cargo/bin/ezgha}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DRY_RUN=0
HOST_FILTER=""

STATE_DIR="${EZGHA_WATCHDOG_STATE_DIR:-$HOME/.local/state/ezgha/watchdog}"
MISS_THRESHOLD="${EZGHA_WATCHDOG_MISS_THRESHOLD:-3}"
LOAD_THRESHOLD="${EZGHA_WATCHDOG_LOAD_THRESHOLD:-12}"
COOLDOWN_SECONDS="${EZGHA_WATCHDOG_COOLDOWN_SECONDS:-1800}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST_FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,58p' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

log() { echo "[$TS] $*"; }

mkdir -p "$STATE_DIR" 2>/dev/null || true

boot_time() {
  if [[ -n "${EZGHA_WATCHDOG_BOOT_TIME_OVERRIDE:-}" ]]; then
    echo "$EZGHA_WATCHDOG_BOOT_TIME_OVERRIDE"
    return
  fi

  if [[ "$(uname -s)" == "Linux" ]]; then
    local bt=""
    if [[ -f /proc/stat ]]; then
      bt=$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null || true)
    fi
    if [[ -n "$bt" && "$bt" =~ ^[0-9]+$ ]]; then
      echo "$bt"
    else
      date -d "$(uptime -s)" +%s 2>/dev/null || echo 0
    fi
  else
    # macOS: "{ sec = 1735689600, usec = 0 } ..."
    local bt=""
    bt=$(sysctl -n kern.boottime 2>/dev/null | sed -En 's/.*sec = ([0-9]+).*/\1/p' || true)
    if [[ -n "$bt" && "$bt" =~ ^[0-9]+$ ]]; then
      echo "$bt"
    else
      echo 0
    fi
  fi
}

get_miss_count() { # $1=host
  local file="$STATE_DIR/$1.miss_count"
  if [[ -f "$file" ]]; then
    local mtime bt
    mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
    bt=$(boot_time)
    if [[ "$bt" != "0" && "$mtime" != "0" && "$mtime" -lt "$bt" ]]; then
      echo 0
      return
    fi
  fi
  cat "$file" 2>/dev/null || echo 0
}

set_miss_count() { # $1=host $2=count
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  echo "$2" > "$STATE_DIR/$1.miss_count"
}

get_last_restart() { # $1=host -> epoch seconds, 0 if never
  local file="$STATE_DIR/$1.last_restart"
  if [[ -f "$file" ]]; then
    local mtime bt
    mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
    bt=$(boot_time)
    if [[ "$bt" != "0" && "$mtime" != "0" && "$mtime" -lt "$bt" ]]; then
      echo 0
      return
    fi
  fi
  cat "$file" 2>/dev/null || echo 0
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
    ssh -o ConnectTimeout=5 jeff-ubuntu "systemctl --user restart ezgha.service" 2>&1
  fi
}

# evaluate_host applies the miss-threshold / cooldown / load-gate guardrails
# and restarts via $5 (a function name) only when all three clear.
# Returns: 0 = at target or restart fired; 1 = below target, no action taken.
evaluate_host() {
  local host="$1" configured="$2" actual="$3" slots="$4" restart_fn="$5"
  local label
  label="$(echo "$host" | tr '[:lower:]' '[:upper:]')"

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
  actual=$("$EZGHA" status 2>/dev/null | grep -oE "managed containers: [0-9]+" | grep -oE "[0-9]+")
  slots=$(slot_count)

  if [[ -z "$configured" || -z "$actual" ]]; then
    log "MAC: cannot read state (config=$configured actual=$actual)"
    return 2
  fi

  evaluate_host "mac" "$configured" "$actual" "$slots" do_restart_mac
}

check_linux() {
  if [[ -n "$HOST_FILTER" && "$HOST_FILTER" != "linux" ]]; then return 0; fi
  local configured actual slots
  if [[ "$(uname -s)" == "Linux" ]]; then
    configured=$(grep -E "^count = " "$HOME/.config/ezgha/config.toml" 2>/dev/null | grep -oE "[0-9]+")
    actual=$("$EZGHA" status 2>/dev/null | grep -oE "managed containers: [0-9]+" | grep -oE "[0-9]+")
    slots=$(slot_count)
  else
    configured=$(ssh -o ConnectTimeout=5 jeff-ubuntu 'grep -E "^count = " ~/.config/ezgha/config.toml 2>/dev/null | grep -oE "[0-9]+"' 2>/dev/null)
    actual=$(ssh -o ConnectTimeout=5 jeff-ubuntu '$HOME/.cargo/bin/ezgha status 2>/dev/null | grep -oE "managed containers: [0-9]+" | grep -oE "[0-9]+"' 2>/dev/null)
    # Same single-value-capture fix as slot_count() above, applied inline
    # since this runs on the remote host via ssh rather than calling the
    # local function.
    slots=$(ssh -o ConnectTimeout=5 jeff-ubuntu 'n=$(grep -c "=" ~/.config/ezgha/slot_assignments.toml 2>/dev/null); echo "${n:-0}"' 2>/dev/null)
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
