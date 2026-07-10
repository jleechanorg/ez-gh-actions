#!/usr/bin/env bash
# measure-churn-rate.sh — count ezgha reclaim/respawn log lines in a time
# window and report a rate/hour, so churn-related fixes (e.g. the
# REGISTRATION_GRACE_WINDOW fix, d0e814e) can be verified with a real
# before/after delta instead of manual grep/date archaeology.
#
# Usage:
#   docs/measure-churn-rate.sh [--platform mac|linux] [--since DURATION]
#                               [--log-file PATH] [--unit NAME]
#
#   --platform   mac | linux (default: auto-detect via `uname`)
#   --since      journalctl-style duration, Linux only (default: "1 hour ago")
#   --log-file   macOS launchd stderr log path
#                (default: /tmp/ezgha-launchd-stderr.log)
#   --unit       Linux systemd/journalctl unit name (default: ezgha.service)
#
# macOS note: the launchd stderr log has no per-line timestamps (it is a
# plain redirected file, not syslog/unified-log), so --since has no effect
# in mac mode — the script reports whole-file counts and the caller windows
# the measurement externally, e.g. by truncating/rotating the log file right
# before a deploy and re-running this script right after
# (`: > /tmp/ezgha-launchd-stderr.log` between runs gives a true delta).
#
# Linux mode uses journalctl's real timestamps, so --since works as a true
# time window.
set -euo pipefail

RECLAIM_PATTERN='release_stale_slots reclaimed'
RESPAWN_PATTERN='respawned ephemeral runner'

# Windows shorter than this are too short to extrapolate to an hourly rate
# with any confidence — a couple of events in a few seconds is exactly the
# kind of transient burst (daemon restart, JIT retry storm) that produces a
# wildly misleading "/hour" figure when linearly scaled up. Below this floor
# we still show the raw counts but flag the rate as low-confidence instead
# of printing a bare number that looks authoritative.
MIN_CONFIDENT_WINDOW_HOURS="0.0833" # 5 minutes

platform=""
since="1 hour ago"
log_file="/tmp/ezgha-launchd-stderr.log"
unit="ezgha.service"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) platform="$2"; shift 2 ;;
        --since) since="$2"; shift 2 ;;
        --log-file) log_file="$2"; shift 2 ;;
        --unit) unit="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$platform" ]]; then
    case "$(uname -s)" in
        Darwin) platform="mac" ;;
        Linux) platform="linux" ;;
        *) echo "unable to auto-detect platform (uname: $(uname -s)); pass --platform mac|linux" >&2; exit 1 ;;
    esac
fi

count_matches() {
    local pattern="$1"
    grep -c -- "$pattern" || true
}

report() {
    local reclaims="$1" respawns="$2" window_hours="$3" window_desc="$4"

    local reclaims_per_hour respawns_per_hour suffix=""
    if awk "BEGIN{exit !($window_hours > 0)}"; then
        reclaims_per_hour=$(awk -v c="$reclaims" -v h="$window_hours" 'BEGIN{printf "%.2f", c/h}')
        respawns_per_hour=$(awk -v c="$respawns" -v h="$window_hours" 'BEGIN{printf "%.2f", c/h}')
        if awk "BEGIN{exit !($window_hours < $MIN_CONFIDENT_WINDOW_HOURS)}"; then
            suffix=" [LOW-CONFIDENCE: window < ${MIN_CONFIDENT_WINDOW_HOURS}h, extrapolated from a short sample]"
            echo "warning: window (${window_hours}h) is below the ${MIN_CONFIDENT_WINDOW_HOURS}h confidence floor — rate is extrapolated from a short sample and may not reflect steady-state churn" >&2
        fi
    else
        reclaims_per_hour="n/a (zero-length window)"
        respawns_per_hour="n/a (zero-length window)"
    fi

    echo "=== ezgha churn rate ($platform, $window_desc) ==="
    echo "reclaims: $reclaims (${reclaims_per_hour}/hour)${suffix}"
    echo "respawns: $respawns (${respawns_per_hour}/hour)${suffix}"
}

case "$platform" in
    mac)
        if [[ ! -f "$log_file" ]]; then
            echo "log file not found: $log_file" >&2
            exit 1
        fi
        reclaims=$(count_matches "$RECLAIM_PATTERN" < "$log_file")
        respawns=$(count_matches "$RESPAWN_PATTERN" < "$log_file")

        # No per-line timestamps in this log, so the only honest "window" we
        # can report is how long the log file has been accumulating since it
        # was last created/truncated (mtime of the file's containing data is
        # not meaningful here; use the file's birth via `stat` where
        # available, falling back to "unknown" rather than guessing).
        now_epoch=$(date +%s)
        if stat -f '%B' "$log_file" >/dev/null 2>&1; then
            # BSD/macOS stat: %B is birth time (falls back to mtime on some
            # filesystems where birth time isn't tracked).
            start_epoch=$(stat -f '%B' "$log_file")
        else
            start_epoch=$(stat -c '%Y' "$log_file" 2>/dev/null || echo "$now_epoch")
        fi
        window_seconds=$(( now_epoch - start_epoch ))
        if (( window_seconds < 0 )); then
            window_seconds=0
        fi
        window_hours=$(awk -v s="$window_seconds" 'BEGIN{printf "%.4f", s/3600}')
        report "$reclaims" "$respawns" "$window_hours" "whole-file since log creation, ~${window_hours}h — rotate/truncate the log for a true before/after delta"
        ;;
    linux)
        if ! command -v journalctl >/dev/null 2>&1; then
            echo "journalctl not found on this host" >&2
            exit 1
        fi
        journal_output=$(journalctl --user -u "$unit" --since "$since" --no-pager 2>/dev/null || true)
        reclaims=$(printf '%s\n' "$journal_output" | count_matches "$RECLAIM_PATTERN")
        respawns=$(printf '%s\n' "$journal_output" | count_matches "$RESPAWN_PATTERN")

        # journalctl accepts free-form durations ("1 hour ago", "30 min
        # ago", etc.) that are non-trivial to parse back into hours
        # ourselves without depending on GNU `date -d` (not portable to
        # BSD/macOS date, though this branch only runs on Linux where GNU
        # date is standard). Use GNU date to resolve --since into an epoch
        # delta against "now" for the rate calculation.
        if ! since_epoch=$(date -d "$since" +%s 2>/dev/null); then
            echo "unable to parse --since value '$since' via 'date -d' (is GNU date available and is the value valid?)" >&2
            exit 1
        fi
        now_epoch=$(date +%s)
        window_seconds=$(( now_epoch - since_epoch ))
        if (( window_seconds < 0 )); then
            window_seconds=0
        fi
        window_hours=$(awk -v s="$window_seconds" 'BEGIN{printf "%.4f", s/3600}')
        report "$reclaims" "$respawns" "$window_hours" "journalctl --since \"$since\", unit $unit, ~${window_hours}h"
        ;;
    *)
        echo "unsupported platform: $platform (expected mac|linux)" >&2
        exit 1
        ;;
esac
