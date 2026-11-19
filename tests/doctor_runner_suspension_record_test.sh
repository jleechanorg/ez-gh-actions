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

# ── Remote arm: a parked REMOTE leg must also declare its record ────────────
# P1 from review: the reporting was inside the LOCAL_DISABLED branch only, so a
# Linux doctor checking a parked Mac printed neither the pointer nor the warning,
# contradicting the "every parked run" promise in AGENTS.md.
# Anchor on the branch body by CONTENT, not line numbers: a hardcoded range
# silently pointed at the wrong lines as soon as upstream shifted, and a
# line-pinned test is a false green waiting to happen.
REMOTE_START=$(grep -n 'REMOTE_DISABLED" -eq 1 \]; then' "$D" | head -1 | cut -d: -f1)
[ -n "$REMOTE_START" ] || fail "could not locate the remote parked-leg branch"
REMOTE_BLOCK="$(sed -n "${REMOTE_START},$((REMOTE_START + 30))p" "$D")"
grep -q 'suspension record' <<<"$REMOTE_BLOCK" \
  || fail "the REMOTE parked-leg branch does not report the suspension record"
grep -q 'no suspension record declared for the parked' <<<"$REMOTE_BLOCK" \
  || fail "the REMOTE parked-leg branch has no missing-record warning"
pass "structural: the remote parked-leg branch reports the suspension record"

remote_harness() { # value | "unset"
  local val="$1"
  {
    echo 'PLATFORM=linux'
    if [ "$val" = 'unset' ]; then echo 'unset EZGHA_SUSPENSION_RECORD'; else
      printf 'EZGHA_SUSPENSION_RECORD=%s\n' "$val"
    fi
    echo 'ok() { echo "OK:$*"; }'
    echo 'info() { echo "INFO:$*"; }'
    echo 'warn() { echo "WARN:$*"; }'
    echo 'REMOTE_DISABLED=1'
    echo 'REMOTE_LABEL="macos(macbook)"'
    # Strip the leading `if [ "$REMOTE_DISABLED" -eq 1 ]; then` guard and the
    # trailing `fi`/elif so the branch body runs standalone.
    sed -n "${REMOTE_START},$((REMOTE_START + 30))p" "$D" | sed '1d' | sed '/^elif/,$d'
  } > "$WORK/remote.sh"
  bash "$WORK/remote.sh"
}

ROUT1="$(remote_harness 'jleechan-hxz0')"
grep -q 'INFO:.*suspension record: jleechan-hxz0' <<<"$ROUT1" \
  || { sed -n '1,10p' <<<"$ROUT1" >&2; fail "remote arm: a declared record must print a pointer"; }
ROUT2="$(remote_harness 'none')"
grep -q 'WARN:.*no suspension record declared for the parked' <<<"$ROUT2" \
  || { sed -n '1,10p' <<<"$ROUT2" >&2; fail "remote arm: an undeclared record must warn"; }
pass "behavioral: the remote parked-leg branch prints the pointer and warns when missing"

echo "ALL PASS: a parked leg declares its suspension record or says it is missing"
