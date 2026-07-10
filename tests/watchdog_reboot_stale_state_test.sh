#!/usr/bin/env bash
# regression test: scripts/ezgha-fleet-watchdog.sh must ignore per-host
# miss_count / last_restart state that predates the current host boot --
# the reboot-stale-state guard required before the ezgha-watchdog.timer is
# re-enabled (bead ez-gh-actions-xfw).
#
# Root cause this guards against: the state files
# ($STATE_DIR/$host.miss_count, .last_restart) are plain files under
# ~/.local/state (not tmpfs), so they SURVIVE a host reboot. The systemd
# timer fires 30s after boot (OnBootSec=30s). A pre-reboot miss_count>=
# threshold could otherwise restart a daemon that hasn't finished starting
# (0 containers is legitimate mid-boot), reproducing the exact orphan-
# registration harm the watchdog PR exists to prevent; a pre-reboot
# last_restart could wrongly block a genuinely-needed post-reboot restart
# for the full cooldown window.
#
# The pre-existing STATE_STALE_SECONDS mtime-AGE check does NOT cover this:
# a FAST reboot can leave pre-reboot state YOUNGER than the staleness
# window (default 480s) yet still belonging to a dead boot session. Only a
# boot-time comparison catches it. This test proves the boot-time check
# exists AND that the age check alone would have missed the fast-reboot
# case.
#
# It extracts the REAL boot_time() and read_fresh_state() functions from
# the watchdog script (via sed, not a re-implementation) and drives them
# against fixture state files with controlled mtimes, asserting:
#   (a) fixture whose mtime PREDATES boot but is YOUNG (fast reboot,
#       age < STATE_STALE_SECONDS) -> read_fresh_state returns 0 (guard
#       holds). This is the case the age check alone would MISS.
#   (b) fixture whose mtime is AFTER boot and within the staleness window
#       (normal, boot long ago) -> returns the stored value (guard does
#       NOT fire; live counters are preserved).
#   (c) boot time UNKNOWN (BOOT_TIME empty) -> reboot check is skipped and
#       behavior falls back to the age check alone: a fresh file returns
#       its value, an old file returns 0. Proves the fail-safe degrade
#       introduces no new failure mode.
#   (d) missing file -> 0 (unchanged base case).
#
# Usage: bash tests/watchdog_reboot_stale_state_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/ezgha-fleet-watchdog.sh"

# Extract a `name() { ... }` function body (bounded by its def line and the
# next line that is a bare `}`) from the watchdog script rather than
# hardcoding a duplicate -- keeps the test honest against code drift.
extract_fn() {
  local name="$1" start end
  start=$(grep -n "^${name}() {" "$WATCHDOG" | head -1 | cut -d: -f1)
  if [ -z "$start" ]; then
    echo "FAIL: could not locate ${name}() in $WATCHDOG" >&2
    exit 1
  fi
  end=$(tail -n +"$start" "$WATCHDOG" | grep -n '^}' | head -1 | cut -d: -f1)
  end=$((start + end - 1))
  sed -n "${start},${end}p" "$WATCHDOG"
}

eval "$(extract_fn boot_time)"
eval "$(extract_fn read_fresh_state)"

# Assert the reboot guard is actually wired into read_fresh_state (a
# BOOT_TIME mtime comparison), not merely defined -- the defect this guards
# against is specifically that mtime-age was once the ONLY staleness check.
if ! grep -q 'mtime < BOOT_TIME' "$WATCHDOG"; then
  echo "FAIL: read_fresh_state has no 'mtime < BOOT_TIME' reboot guard in $WATCHDOG" >&2
  exit 1
fi

# shellcheck disable=SC2034  # consumed by the eval'd read_fresh_state() (age backstop)
STATE_STALE_SECONDS=480   # match the script default
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

NOW=$(date +%s)
OVERALL_PASS=true

# write_state $file $value $mtime_epoch
write_state() {
  echo "$2" > "$1"
  touch -d "@$3" "$1"
}

run_case() {
  local label="$1" boot="$2" file="$3" expect="$4"
  local got
  # shellcheck disable=SC2034  # BOOT_TIME is read by the eval'd read_fresh_state()
  BOOT_TIME="$boot" got=$(read_fresh_state "$file")
  if [ "$got" = "$expect" ]; then
    echo "  [$label] read_fresh_state=$got (expected $expect) -- PASS"
  else
    echo "  [$label] read_fresh_state=$got (expected $expect) -- FAIL"
    OVERALL_PASS=false
  fi
}

echo "--- watchdog reboot-stale-state guard (ez-gh-actions-xfw) ---"

# Sanity: boot_time() on this host must yield a plausible epoch (Linux CI
# has /proc/stat btime). If it can't be read here the guard would silently
# no-op in production, so surface that rather than passing vacuously.
LIVE_BOOT=$(boot_time)
if [[ "$LIVE_BOOT" =~ ^[0-9]+$ ]] && [ "$LIVE_BOOT" -gt 0 ] && [ "$LIVE_BOOT" -le "$NOW" ]; then
  echo "  [boot_time-live] boot_time()=$LIVE_BOOT (plausible epoch <= now) -- PASS"
else
  echo "  [boot_time-live] boot_time()='$LIVE_BOOT' not a plausible past epoch -- FAIL"
  OVERALL_PASS=false
fi

# Case (a): FAST reboot -- state predates boot but is only 120s old, well
# inside STATE_STALE_SECONDS=480. Boot was 60s ago. The age check alone
# (120 < 480 -> "fresh") would wrongly return the stale count of 3; the
# reboot guard (120s-old mtime < 60s-ago boot) must return 0.
FA="$WORK/a.miss_count"
write_state "$FA" 3 $((NOW - 120))
run_case "fast-reboot-young-predates-boot-guard-holds" $((NOW - 60)) "$FA" "0"

# Case (b): normal operation -- boot was long ago, file written 60s ago
# (after boot) and inside the window -> live value preserved.
FB="$WORK/b.miss_count"
write_state "$FB" 3 $((NOW - 60))
run_case "boot-old-fresh-state-preserved" $((NOW - 100000)) "$FB" "3"

# Case (c): boot time UNKNOWN -> reboot check skipped, age check governs.
FC1="$WORK/c1.last_restart"
write_state "$FC1" 5 $((NOW - 60))
run_case "boot-unknown-fresh-falls-back-to-value" "" "$FC1" "5"

FC2="$WORK/c2.last_restart"
write_state "$FC2" 5 $((NOW - 600))   # older than 480s staleness window
run_case "boot-unknown-old-age-backstop-still-fires" "" "$FC2" "0"

# Case (d): missing file -> 0 base case (boot known, irrelevant).
run_case "missing-file-base-case" $((NOW - 60)) "$WORK/nope.miss_count" "0"

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
