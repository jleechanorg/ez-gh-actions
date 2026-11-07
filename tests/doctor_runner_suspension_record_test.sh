#!/usr/bin/env bash
# Regression coverage: a parked leg must DECLARE where its suspension record lives.
#
# AGENTS.md already required every suspension to carry a start date and a restore
# condition "so the opt-out cannot quietly become a permanent capacity
# reduction". Nothing surfaced a MISSING record, and the consequence was real:
# the Mac leg sat parked from 2026-10-29 with no written owner record anywhere,
# discovered by the 2026-11-07 fleet audit.
#
# doctor-runner now prints a pointer when a leg is parked, and warns when no
# record is declared. Both arms are asserted here from the real script output
# (no reimplementation).
#
# Usage: bash tests/doctor_runner_suspension_record_test.sh
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/doctor-runner"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -x "$D" ] || fail "doctor-runner not executable at $D"
bash -n "$D" || fail "doctor-runner has a syntax error"

# Structural: the knob exists and the parked block references it.
grep -q 'EZGHA_SUSPENSION_RECORD' "$D" \
  || fail "doctor-runner does not read EZGHA_SUSPENSION_RECORD"
pass "structural: EZGHA_SUSPENSION_RECORD is read"

# Extract just the parked-host block (lines 285-300: `if [ "$LOCAL_DISABLED" -eq 1 ]`
# through its closing `fi`) so the assertion is about that code path, not about a
# coincidence elsewhere in a 2000-line script.
BLOCK="$(sed -n '285,300p' "$D")"
[ -n "$BLOCK" ] || fail "could not isolate the parked-host block"
grep -q 'suspension record' <<<"$BLOCK" \
  || fail "the parked-host block does not report the suspension record"
grep -q 'no suspension record declared' <<<"$BLOCK" \
  || fail "the parked-host block has no undeclared-record warning"
pass "structural: parked block reports and warns on the suspension record"

# Behavioral: the two arms must be distinguishable. Drive the real block with a
# minimal harness (set -u semantics preserved) rather than running a full doctor
# against the live host.
harness() { # value | "unset"
  local val="$1"
  {
    echo 'PLATFORM=macos'
    if [ "$val" = 'unset' ]; then echo 'unset EZGHA_SUSPENSION_RECORD'; else
      printf 'EZGHA_SUSPENSION_RECORD=%s\n' "$val"
    fi
    echo 'ok() { echo "OK:$*"; }'
    echo 'info() { echo "INFO:$*"; }'
    echo 'warn() { echo "WARN:$*"; }'
    echo 'section() { :; }'
    echo 'LOCAL_DISABLED=1'
    sed -n '285,300p' "$D" | sed '$d'
    echo 'fi'
  } > "$WORK/block.sh"
  bash "$WORK/block.sh"
}

WORK="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

# Arm 1: declared -> prints a pointer, no warning.
OUT1="$(harness 'jleechan-hxz0')"
grep -q 'INFO:.*suspension record: jleechan-hxz0' <<<"$OUT1" \
  || { sed -n '1,10p' <<<"$OUT1" >&2; fail "a declared record must be printed as a pointer"; }
if grep -q 'WARN:' <<<"$OUT1"; then
  fail "a declared record must not also warn"
fi
pass "behavioral: declared record prints the pointer and does not warn"

# Arm 2: explicitly undeclared -> warns, and names what is missing.
OUT2="$(harness 'none')"
grep -q 'WARN:.*no suspension record declared' <<<"$OUT2" \
  || { sed -n '1,10p' <<<"$OUT2" >&2; fail "an undeclared record must warn"; }
grep -qi 'restore condition' <<<"$OUT2" \
  || fail "the warning must name the restore condition requirement"
pass "behavioral: undeclared record warns and names the requirement"

# Arm 3: default is the owning bead, so an ordinary parked run still points at
# the record rather than warning spuriously.
OUT3="$(harness 'unset')"
grep -q 'INFO:.*suspension record: jleechan-hxz0' <<<"$OUT3" \
  || { sed -n '1,10p' <<<"$OUT3" >&2; fail "unset must default to the owning bead, not warn"; }
pass "behavioral: unset defaults to the owning bead"

echo "ALL PASS: a parked leg declares its suspension record or says it is missing"
