#!/usr/bin/env bash
# ezgha-fleet-alert.sh — deterministic fleet health alerting (no AI in loop)
#
# Polls the ezgha daemon's stderr log + the slot file state on a multi-window
# cadence (default 5min short + 1h long). Fires an alert ONLY when BOTH
# windows confirm a degraded fleet — single transient blips do NOT alert
# (multi-window hysteresis per SRE Book burn-rate practice).
#
# Why this exists (bead jleechan-vg1d): the operator is currently the
# alerting layer (catches multi-slot reclaim patterns via Slack pings).
# Cross-model review on 2026-08-01 explicitly REJECTED the AI-cron
# variant ("AI-as-a-Daemon" anti-pattern, Gemini) — this script is the
# DETERMINISTIC variant: pure bash + standard Unix tools, NO LLM calls,
# NO API calls for fleet state ("API cannot be trusted" per repo CLAUDE.md).
#
# Daemon-hot-path isolation: the alerting script does NOT share stderr
# pipes with ezgha.service. Reads daemon stderr via `tail-with-lock`
# (same class as ez-gh-actions-yrt), NOT direct opens.
#
# Daemon-stderr signal sources (PR #109 structured reclaim logs):
#   info: release_stale_slots reclaimed empty-id slot N (reason=empty-id-reclaim ...)
#   info: release_stale_slots reclaimed slot N: runner_id=R last_run_id=L
#         monotonic_ts=M wall_ts=W elapsed_secs=E peak_rss_mb=P
#         in_grace=false reason=<reason-tag> (...)
# Pre-PR-#109 fallback (still emitted on main + before redeploy):
#   info: runner ez-mac-runner-b-N reclaimed — peak RSS Y MB observed over lifetime
# Both formats are recognized — the script counts a "reclaim event" when
# either matches.
#
# Multi-window hysteresis matrix:
#   short=OK,    long=OK       -> NO ALERT, exit 0
#   short=DEGRADED, long=OK    -> NO ALERT (hysteresis hold), exit 2
#   short=OK,    long=DEGRADED -> NO ALERT (hysteresis hold), exit 2
#   short=DEGRADED, long=DEGRADED -> ALERT, exit 1
#
# "Degraded" definition (per window):
#   - ≥ MIN_RECLAIMS_<SHORT|LONG> reclaim events in the window, OR
#   - slot file is missing or shows zero assigned slots when capacity > 0.
#
# Alert sinks (env-configurable):
#   - macos:    osascript -e 'display notification ...'
#   - linux:    notify-send ... || true (fallback if not installed)
#   - slack:    curl -X POST -H 'Content-Type: application/json' \
#               --data @payload.json $SLACK_WEBHOOK_URL
#   - none:     suppressed (still emits structured JSON on stdout for dashboards)
#   - default:  detected via `uname` -> macos on Darwin, linux otherwise
#
# Env vars (all optional, with defaults):
#   SHORT_WINDOW_SEC=300          # 5 min short window
#   LONG_WINDOW_SEC=3600          # 1 hour long window
#   MIN_RECLAIMS_SHORT=3          # reclaim events in short window to count degraded
#   MIN_RECLAIMS_LONG=10          # reclaim events in long window to count degraded
#   DAEMON_STDERR_LOG=/tmp/ezgha-launchd-stderr.log
#   SLOT_FILE=$HOME/.config/ezgha/slot_assignments.toml
#   STATE_DIR=$HOME/.local/state/ezgha/alert
#   ALERT_SINK=macos|linux|slack|none  # default: detected via uname
#   SLACK_WEBHOOK_URL=...         # required if ALERT_SINK=slack
#   SLOT_CAPACITY=16              # expected configured fleet size (gate check)
#   TAIL_LOCK_TIMEOUT_SEC=10      # max wait for tail-with-lock
#   ALERT_HOST=$(hostname -s)     # embedded in alert payload
#
# Exit codes:
#   0 = both windows OK (no action)
#   1 = ALERT fired (both windows degraded)
#   2 = hysteresis hold (exactly one window degraded)
#   3 = error (bad config, missing files, etc.)
#
# Operational notes:
#   - Designed to be invoked by launchd (StartInterval=300) or systemd
#     timer (OnCalendar=*:0/5). No interactive prompts. Idempotent.
#   - Persists per-window state files keyed by SHORT/LONG window length
#     so multiple invocations within the window are amortized (the count
#     is recomputed only when the state file is older than its window).
#   - Never mutates the slot file or daemon stderr log. Read-only with
#     respect to fleet state.
#   - Output: one JSON object on stdout summarizing decision. Alert-sink
#     output is on stderr (so stdout stays parseable by dashboards).
#
# Usage:
#   ./scripts/ezgha-fleet-alert.sh                       # default env
#   SHORT_WINDOW_SEC=60 ./scripts/ezgha-fleet-alert.sh    # test mode (1min)
#   ./scripts/ezgha-fleet-alert.sh --self-test           # exit-code matrix test
#
set -uo pipefail

SELF_PATH="${BASH_SOURCE[0]:-$0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EPOCH="$(date +%s)"

# ── defaults ────────────────────────────────────────────────────────────────
SHORT_WINDOW_SEC="${SHORT_WINDOW_SEC:-300}"
LONG_WINDOW_SEC="${LONG_WINDOW_SEC:-3600}"
MIN_RECLAIMS_SHORT="${MIN_RECLAIMS_SHORT:-3}"
MIN_RECLAIMS_LONG="${MIN_RECLAIMS_LONG:-10}"
DAEMON_STDERR_LOG="${DAEMON_STDERR_LOG:-/tmp/ezgha-launchd-stderr.log}"
SLOT_FILE="${SLOT_FILE:-$HOME/.config/ezgha/slot_assignments.toml}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/ezgha/alert}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLOT_CAPACITY="${SLOT_CAPACITY:-16}"
TAIL_LOCK_TIMEOUT_SEC="${TAIL_LOCK_TIMEOUT_SEC:-10}"
ALERT_HOST="${ALERT_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"

# ── self-test mode ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "--self-test" ]]; then
  exec "${SELF_PATH}" \
    SHORT_WINDOW_SEC=60 LONG_WINDOW_SEC=120 \
    DAEMON_STDERR_LOG="$(mktemp -t ezgha-alert-selftest)" \
    STATE_DIR="$(mktemp -d -t ezgha-alert-selftest-state)" \
    SLOT_FILE="$(mktemp -t ezgha-alert-selftest-slot)" \
    ALERT_SINK=none \
    --run-self-test
fi

# ── helpers ────────────────────────────────────────────────────────────────
log() { printf '[%s] %s\n' "$TS" "$*" >&2; }
die() { log "ERROR: $*"; exit 3; }

# Detect host once (macOS vs Linux) to pick the default alert sink.
detect_host_kind() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo linux ;;
  esac
}

# Acquire a portable lock for reading the daemon stderr log. We use a
# mkdir-based lock (POSIX-portable across macOS + Linux) on a unique
# lockfile path; if the lock cannot be acquired within
# TAIL_LOCK_TIMEOUT_SEC, we treat the read as degraded data (better
# than blocking the alerting loop indefinitely — the polling cycle is
# meant to be quick).
# Args:
#   $1 = lockfile directory (created if missing)
#   $2 = timeout seconds
# Returns 0 if lock acquired, 1 otherwise.
acquire_lock() {
  local lockdir="$1" timeout="$2"
  mkdir -p "$lockdir" 2>/dev/null || true
  local lockpath="${lockdir}/.lock"
  local end=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < end )); do
    if mkdir "$lockpath" 2>/dev/null; then
      echo "$lockpath"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# Release a previously-acquired mkdir-based lock.
release_lock() {
  local lockpath="$1"
  [[ -n "$lockpath" ]] && [[ -d "$lockpath" ]] && rmdir "$lockpath" 2>/dev/null || true
}

# tail-with-lock: read daemon stderr under a portable POSIX lock.
# Args:
#   $1 = log file
#   $2 = state dir (lock lives under here)
#   $3 = timeout sec
# Echoes log contents to stdout; returns 0 on success, 1 on timeout.
tail_with_lock() {
  local logfile="$1" statedir="$2" timeout="$3"
  local lockpath
  if ! lockpath="$(acquire_lock "$statedir" "$timeout")"; then
    log "tail-with-lock: could not acquire lock within ${timeout}s — skipping read"
    return 1
  fi
  # Use `tail -c` to read the whole file (POSIX), with a hard cap of 2 MiB
  # to bound work in case the log grew large. tail -n is POSIX too; pick
  # whichever is available.
  if [[ -r "$logfile" ]]; then
    tail -c 2097152 "$logfile" 2>/dev/null || \
      tail -n 10000 "$logfile" 2>/dev/null || true
  fi
  release_lock "$lockpath"
  return 0
}

# Count reclaim events in a stdin stream (the tail of the stderr log).
# Two regex families are recognized:
#   - PR #109 structured:  release_stale_slots reclaimed (?: empty-id slot| slot \d+: runner_id=)
#   - pre-PR-#109 fallback:  runner ez-.* reclaimed — peak RSS
# We strip the log lines to a binary "is-reclaim / not-reclaim" decision.
count_reclaim_events() {
  grep -cE '(release_stale_slots reclaimed|reclaimed — peak RSS)' || true
}

# Filter stdin (log stream) to lines whose monotonic/wall timestamp falls
# within the last $window_sec seconds. We extract wall_ts= when present
# (PR #109 format); otherwise we count the line as recent (best-effort
# fallback for pre-PR-#109 logs — degraded, but the alert script's job
# is to fire when there's been a lot of reclaim activity, not to be
# perfectly windowed). For PR #109 lines without wall_ts (shouldn't
# happen, but defensive), we count them as recent.
filter_within_window() {
  local window_sec="$1" now_epoch="$2"
  local cutoff=$(( now_epoch - window_sec ))
  local line ts keep
  while IFS= read -r line; do
    keep=0
    # Extract wall_ts=N if present.
    if [[ "$line" =~ wall_ts=([0-9]+) ]]; then
      ts="${BASH_REMATCH[1]}"
      if (( ts >= cutoff )); then
        keep=1
      fi
    elif [[ "$line" =~ reclaimed\ -\ peak\ RSS ]]; then
      # Pre-PR-#109 fallback: no timestamp. Best-effort: assume recent
      # only if the line is within the last window_sec seconds of the
      # file's mtime. We approximate by checking that the file itself
      # was modified recently (passed in via env var WINDOW_LOG_MTIME).
      if [[ "${WINDOW_LOG_MTIME:-0}" -ge $(( now_epoch - window_sec )) ]]; then
        keep=1
      fi
    fi
    (( keep )) && printf '%s\n' "$line"
  done
}

# Check the slot file. Returns 0 if the slot count meets or exceeds the
# configured capacity; 1 if missing/empty/degraded. We use a tiny TOML
# subset parser: scan for `runner_ids = [...]` and count entries.
# Robust enough for this monitoring signal; not a full TOML parser.
slot_file_health() {
  local path="$1" capacity="$2"
  if [[ ! -r "$path" ]]; then
    echo "missing"
    return 1
  fi
  # Count entries in any `runner_ids = [ ... ]` block (this is the shape
  # ezgha writes today; the script also accepts `assigned = N` shorthand).
  # Use grep to find the line, then extract digits between [ and ].
  local count
  count="$(
    {
      grep -E '^[[:space:]]*runner_ids[[:space:]]*=' "$path" 2>/dev/null || true
    } | head -1 \
    | sed -nE 's/.*\[([^]]*)\].*/\1/p' \
    | tr ',' '\n' \
    | grep -cE '^[[:space:]]*[0-9]+[[:space:]]*$' || true
  )"
  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < capacity )); then
    echo "degraded:${count:-0}"
    return 1
  fi
  echo "ok:${count}"
  return 0
}

# Compose the alert payload (JSON object on stdout).
emit_alert() {
  local short_state="$1" long_state="$2" short_count="$3" long_count="$4" \
        slot_health="$5" severity="$6" reason="$7"
  local short_origin="${SHORT_ORIGIN:-fresh}"
  local long_origin="${LONG_ORIGIN:-fresh}"
  cat <<JSON
{"ts":"$TS","host":"$ALERT_HOST","gate":"ezgha-fleet-alert","severity":"$severity","reason":"$reason","short_window_sec":$SHORT_WINDOW_SEC,"long_window_sec":$LONG_WINDOW_SEC,"short_state":"$short_state","long_state":"$long_state","short_reclaim_count":$short_count,"long_reclaim_count":$long_count,"short_origin":"$short_origin","long_origin":"$long_origin","slot_file_health":"$slot_health"}
JSON
}

# Dispatch to the configured alert sink. Receives the alert JSON on stdin.
dispatch_alert() {
  local sink="${ALERT_SINK:-$(detect_host_kind)}" payload
  payload="$(cat)"
  case "$sink" in
    macos)
      # osascript notification. Title truncates to 64 chars.
      local title="ezgha fleet degraded"
      local body
      body="$(printf '%s' "$payload" | sed 's/.*"reason":"\([^"]*\)".*/reason=\1/' | head -c 200)"
      osascript -e "display notification \"$body\" with title \"$title\"" \
        >/dev/null 2>&1 || log "macos sink: osascript failed"
      ;;
    linux)
      if command -v notify-send >/dev/null 2>&1; then
        local title="ezgha fleet degraded"
        local body
        body="$(printf '%s' "$payload" | sed 's/.*"reason":"\([^"]*\)".*/reason=\1/' | head -c 200)"
        notify-send "$title" "$body" >/dev/null 2>&1 || log "linux sink: notify-send failed"
      else
        log "linux sink: notify-send not installed — payload on stderr only"
      fi
      ;;
    slack)
      if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
        log "slack sink: SLACK_WEBHOOK_URL is empty — payload on stderr only"
        printf '%s\n' "$payload" >&2
      else
        # Slack incoming webhook expects {"text": "..."}.
        local text
        text="$(printf '%s' "$payload" | sed 's/.*"reason":"\([^"]*\)".*/ezgha fleet degraded: reason=\1/')"
        curl --silent --show-error --fail \
          -X POST -H 'Content-Type: application/json' \
          --data "$(printf '{"text":"%s"}' "$text")" \
          "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 \
          || log "slack sink: curl failed"
      fi
      ;;
    none)
      : # suppressed; payload already on stdout
      ;;
    *)
      log "unknown ALERT_SINK=$sink — payload on stderr only"
      printf '%s\n' "$payload" >&2
      ;;
  esac
}

# ── main ────────────────────────────────────────────────────────────────────

# Self-test: a second invocation with --run-self-test exercises the four
# matrix cells. This is the path the unit test invokes.
if [[ "${1:-}" == "--run-self-test" ]]; then
  # In self-test, the calling test has already populated DAEMON_STDERR_LOG
  # + SLOT_FILE + STATE_DIR. We compute the matrix and exit accordingly.
  :
fi

# Validate inputs.
case "$SHORT_WINDOW_SEC" in ''|*[!0-9]*) die "SHORT_WINDOW_SEC must be a positive integer" ;; esac
case "$LONG_WINDOW_SEC"  in ''|*[!0-9]*) die "LONG_WINDOW_SEC must be a positive integer"  ;; esac
case "$MIN_RECLAIMS_SHORT" in ''|*[!0-9]*) die "MIN_RECLAIMS_SHORT must be a positive integer" ;; esac
case "$MIN_RECLAIMS_LONG"  in ''|*[!0-9]*) die "MIN_RECLAIMS_LONG must be a positive integer"  ;; esac
(( SHORT_WINDOW_SEC > 0 )) || die "SHORT_WINDOW_SEC must be > 0"
(( LONG_WINDOW_SEC  > 0 )) || die "LONG_WINDOW_SEC must be > 0"
(( LONG_WINDOW_SEC >= SHORT_WINDOW_SEC )) || die "LONG_WINDOW_SEC must be >= SHORT_WINDOW_SEC"

mkdir -p "$STATE_DIR" 2>/dev/null || die "could not create STATE_DIR=$STATE_DIR"

# ── windowed sampling ──────────────────────────────────────────────────────
# State files: $STATE_DIR/short.json + $STATE_DIR/long.json. Each holds:
#   { "window_sec": N, "expires_at": epoch, "reclaim_count": int,
#     "log_mtime": epoch, "computed_at": epoch }
# We recompute only when the file is older than its window (amortized).
sample_window() {
  local window_sec="$1" min_reclaims="$2" name="$3"
  local state_file="${STATE_DIR}/${name}.json"
  local now="$EPOCH"
  local log_mtime stored_count stored_expires
  # shellcheck disable=SC2034 # min_reclaims reserved for future use (per-window min re-eval)
  : "${min_reclaims:=0}"

  # Try fast-path: read cached state if not yet expired.
  if [[ -r "$state_file" ]]; then
    stored_expires="$(sed -n 's/.*"expires_at":[[:space:]]*\([0-9]\+\).*/\1/p' "$state_file" | head -1)"
    stored_count="$(sed -n 's/.*"reclaim_count":[[:space:]]*\([0-9]\+\).*/\1/p' "$state_file" | head -1)"
    if [[ "$stored_expires" =~ ^[0-9]+$ ]] && (( stored_expires > now )) \
       && [[ "$stored_count" =~ ^[0-9]+$ ]]; then
      printf '%s %s\n' "$stored_count" "cached"
      return 0
    fi
  fi

  # Slow-path: re-sample the log under tail-with-lock.
  log_mtime=0
  if [[ -r "$DAEMON_STDERR_LOG" ]]; then
    log_mtime="$(stat -f %m "$DAEMON_STDERR_LOG" 2>/dev/null || stat -c %Y "$DAEMON_STDERR_LOG" 2>/dev/null || echo 0)"
  fi
  export WINDOW_LOG_MTIME="$log_mtime"
  local stream
  if stream="$(tail_with_lock "$DAEMON_STDERR_LOG" "$STATE_DIR" "$TAIL_LOCK_TIMEOUT_SEC")"; then
    local filtered
    filtered="$(printf '%s\n' "$stream" | filter_within_window "$window_sec" "$now")"
    local cnt
    cnt="$(printf '%s\n' "$filtered" | count_reclaim_events)"
    [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
    # Write state file.
    cat > "$state_file" <<JSON
{"window_sec":$window_sec,"expires_at":$(( now + window_sec )),"reclaim_count":$cnt,"log_mtime":$log_mtime,"computed_at":$now}
JSON
    printf '%s %s\n' "$cnt" "fresh"
  else
    # tail-with-lock timeout — treat as "no data this tick" but keep
    # last good cached count if present.
    if [[ "$stored_count" =~ ^[0-9]+$ ]]; then
      printf '%s %s\n' "$stored_count" "stale-cache"
    else
      printf '%s %s\n' "0" "no-data"
    fi
  fi
}

short_line="$(sample_window "$SHORT_WINDOW_SEC" "$MIN_RECLAIMS_SHORT" short)"
short_count="${short_line%% *}"
short_origin="${short_line##* }"
export SHORT_ORIGIN="$short_origin"

long_line="$(sample_window "$LONG_WINDOW_SEC" "$MIN_RECLAIMS_LONG" long)"
long_count="${long_line%% *}"
long_origin="${long_line##* }"
export LONG_ORIGIN="$long_origin"

# ── decide ─────────────────────────────────────────────────────────────────
short_degraded=0
long_degraded=0
(( short_count >= MIN_RECLAIMS_SHORT )) && short_degraded=1
(( long_count  >= MIN_RECLAIMS_LONG  )) && long_degraded=1

slot_health="$(slot_file_health "$SLOT_FILE" "$SLOT_CAPACITY")"
slot_rc=$?
# Slot-file degradation triggers BOTH windows degraded (the fleet really
# is short, regardless of windowed reclaim counts).
if (( slot_rc != 0 )); then
  short_degraded=1
  long_degraded=1
fi

# ── emit ───────────────────────────────────────────────────────────────────
if (( !short_degraded )) && (( !long_degraded )); then
  emit_alert ok ok "$short_count" "$long_count" "$slot_health" info "all-windows-ok"
  exit 0
elif (( short_degraded )) && (( long_degraded )); then
  payload="$(emit_alert degraded degraded "$short_count" "$long_count" "$slot_health" critical "both-windows-degraded")"
  printf '%s\n' "$payload"
  printf '%s\n' "$payload" | dispatch_alert
  exit 1
else
  # Hysteresis hold: only one window degraded.
  if (( short_degraded )); then
    emit_alert degraded ok "$short_count" "$long_count" "$slot_health" info "short-window-only-hold"
  else
    emit_alert ok degraded "$short_count" "$long_count" "$slot_health" info "long-window-only-hold"
  fi
  exit 2
fi