#!/usr/bin/env bash
# Regression coverage for bead jleechan-p9uq: execution-proof gates could not
# attribute a selftest run to a fleet LEG, so a parked leg satisfied proof for the
# enabled one.
#
# The defect: section 7 accepted any run whose runner_name matched `ez-*`
#   if [[ "$rn" == "${RUNNER_NAME_PREFIX}"* ]] || ... || [[ "$rn" == "ez-"* ]]; then
# so a historical success on the parked Mac leg counted as proof while the enabled
# Linux leg had no successful selftest at all. The `--prove` canary had the same
# shape and would report "fleet is handling real jobs NOW" from a disabled leg.
#
# This test extracts the REAL classifier from doctor-runner (never a
# reimplementation) and drives it with synthetic runner names:
#   1. parked leg only            -> REAL_ON_FLEET stays 0, run marked parked
#   2. enabled leg only           -> counts as proof
#   3. both legs, no opt-out      -> both count
#   4. nothing parked (default)   -> unknown ez-* still accepted
#
# Usage: bash tests/doctor_runner_exec_proof_parked_attribution_test.sh
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/doctor-runner"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -x "$D" ] || fail "doctor-runner not executable at $D"
bash -n "$D" || fail "doctor-runner has a syntax error"

# Structural: the parked-leg declaration must precede section 7's use of it.
# (The ordering itself was a defect: REMOTE_DISABLED was assigned in section 10,
# long after section 7 and the canary both read it.)
DECL_LINE=$(grep -n '^PARKED_REMOTE=0' "$D" | head -1 | cut -d: -f1)
SEC7_LINE=$(grep -n 'section "7\. real job-execution proof' "$D" | head -1 | cut -d: -f1)
[ -n "$DECL_LINE" ] || fail "PARKED_REMOTE is never declared"
[ -n "$SEC7_LINE" ] || fail "section 7 not found"
[ "$DECL_LINE" -lt "$SEC7_LINE" ] \
  || fail "PARKED_REMOTE must be declared BEFORE section 7 (decl=$DECL_LINE sec7=$SEC7_LINE)"
pass "parked-leg declaration precedes section 7"

# Structural: no unconditional ez-* acceptance left in the proof path.
grep -q 'that leg is parked — NOT execution proof' "$D" \
  || fail "section 7 has no parked-leg exclusion message"
grep -q 'cannot prove the enabled fleet is handling jobs' "$D" \
  || fail "the --prove canary has no parked-leg exclusion"
pass "structural: both proof paths carry a parked-leg exclusion"

# Behavioral: drive the real classifier body out of the script.
# Extract from the `_is_fleet=0` line through the end of the else-branch block.
extract_classifier() {
  # Body runs from `_is_fleet=0` to the closing `fi` of the fleet test, i.e. the
  # first line matching `^  fi$` AFTER the parked-leg branch. Stop there; the
  # enclosing `done < <(...)` belongs to the shell, not the classifier.
  awk '
    /^  _is_fleet=0$/  {inside=1}
    inside            {print}
    inside && /^  fi$/ {exit}
  ' "$D"
}

BODY="$(extract_classifier)"
[ -n "$BODY" ] || fail "could not extract the classifier body"
grep -q '_parked_leg=1' <<<"$BODY" || fail "extracted body lacks the parked-leg logic"

classify() { # rn conc parked_local parked_remote local_prefix remote_prefix
  local rn="$1" conc="$2" pl="$3" pr="$4" lp="$5" rp="$6"
  {
    echo 'set -euo pipefail'
    echo "rid=12345"
    echo "rn=$(printf '%q' "$rn"); conc=$(printf '%q' "$conc")"
    echo "PARKED_LOCAL=$pl; PARKED_REMOTE=$pr"
    echo "RUNNER_NAME_PREFIX=$(printf '%q' "$lp"); REMOTE_PREFIX=$(printf '%q' "$rp")"
    echo '_LP="${RUNNER_NAME_PREFIX:-}"; _RP="${REMOTE_PREFIX:-}"'
    echo 'REAL_ON_FLEET=0'
    echo 'ok()   { echo "OK:$*"; }'
    echo 'warn() { echo "WARN:$*"; }'
    echo "$BODY"
    echo 'echo "COUNT=$REAL_ON_FLEET"'
  } > "$WORK/classify.sh"
  bash "$WORK/classify.sh" 2>&1
}

WORK="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

# 1. A parked leg's success must NOT be execution proof.
OUT1="$(classify ez-mac-runner-h-4 success 0 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$OUT1" \
  || { sed -n '1,10p' <<<"$OUT1" >&2; fail "a parked leg's success must not count as execution proof"; }
grep -qi 'parked' <<<"$OUT1" || fail "the parked run must be labelled as such"
pass "parked leg success does not count as execution proof"

# 2. The enabled leg's success still counts.
OUT2="$(classify ez-runner-c-7 success 0 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=1' <<<"$OUT2" \
  || { sed -n '1,10p' <<<"$OUT2" >&2; fail "the enabled leg's success must count"; }
pass "enabled leg success still counts"

# 3. With nothing parked, a parked-looking name is accepted (no false negative).
OUT3="$(classify ez-mac-runner-h-4 success 0 0 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=1' <<<"$OUT3" \
  || { sed -n '1,10p' <<<"$OUT3" >&2; fail "an un-parked leg's success must count"; }
pass "un-parked leg success counts (no false negative)"

# 4. Both parked: neither counts.
OUT4="$(classify ez-runner-c-7 success 1 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$OUT4" \
  || { sed -n '1,10p' <<<"$OUT4" >&2; fail "a fully parked fleet contributes no proof"; }
pass "fully parked fleet contributes no proof"

# 5. A foreign runner is neither fleet nor proof.
OUT5="$(classify ubuntu-latest success 0 0 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$OUT5" || fail "a non-fleet runner must not count"
grep -qi 'NOT.*ez-\*' <<<"$OUT5" || fail "a non-fleet runner must be reported as such"
pass "non-fleet runner is rejected"

echo "ALL PASS: execution proof is attributed to a leg and excludes parked legs"
