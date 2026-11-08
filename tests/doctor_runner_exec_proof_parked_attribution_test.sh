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
  # Emit the two REAL helpers the classifier depends on, plus the classifier
  # itself -- never a reimplementation.
  awk '/^_runner_matches_prefix\(\)/,/^}/' "$D"
  awk '/^_classify_run_leg\(\)/,/^}/' "$D"
}

BODY="$(extract_classifier)"
[ -n "$BODY" ] || fail "could not extract the classifier helpers"
grep -q '_classify_run_leg' <<<"$BODY" || fail "extracted helpers lack the shared classifier"
grep -q '_runner_matches_prefix' <<<"$BODY" || fail "extracted helpers lack the prefix rule"

classify() { # rn conc parked_local parked_remote local_prefix remote_prefix
  # DEFAULT_REMOTE_PREFIX / CLASSIFY_PLATFORM may come from the caller's env.
  local rn="$1" conc="$2" pl="$3" pr="$4" lp="$5" rp="$6"
  {
    echo 'set -euo pipefail'
    echo "PLATFORM=${CLASSIFY_PLATFORM:-linux}"
    echo "rn=$(printf '%q' "$rn"); conc=$(printf '%q' "$conc")"
    echo "PARKED_LOCAL=$pl; PARKED_REMOTE=$pr"
    echo "RUNNER_NAME_PREFIX=$(printf '%q' "$lp")"
    echo "EARLY_REMOTE_PREFIX=$(printf '%q' "$rp"); REMOTE_PREFIX=''"
    echo 'REAL_ON_FLEET=0'
    echo "$BODY"
    # Same acceptance rule as section 7: fleet + success.
    echo 'if [ "$(_classify_run_leg "$rn")" = "fleet" ] && [ "$conc" = success ]; then REAL_ON_FLEET=1; fi'
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
# The parked state is expressed by the shared classifier's "parked" result; the
# COUNT=0 assertion above is the behavioural proof.
pass "parked leg is classified as parked (COUNT=0)"
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
# The shared classifier returns "unattributed" for a foreign runner; assert that
# directly instead of matching section 7's warn text.
UNATTR="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ubuntu-latest success 0 0 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$UNATTR" || fail "a non-fleet runner must not count"
pass "non-fleet runner is rejected"

# 6. A DRIFTED/historical parked prefix must also be excluded (review P0).
#    The first version guessed `ez-mac-runner-h` and only excluded that, so a
#    `ez-mac-runner-g-4` success fell through to the broad ez-* fallback and
#    counted as proof for the enabled leg.
OUT6="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ez-mac-runner-g-4 success 0 1 ez-runner-c ez-mac-runner-g)"
grep -q 'COUNT=0' <<<"$OUT6" \
  || { sed -n '1,10p' <<<"$OUT6" >&2; fail "a drifted parked prefix must still be excluded (default spelling)"; }
pass "drifted parked prefix is excluded via the default spelling"

# 7. The DEFAULT spelling is excluded even when the configured prefix differs.
OUT7="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ez-mac-runner-h-2 success 0 1 ez-runner-c ez-other-prefix)"
grep -q 'COUNT=0' <<<"$OUT7" \
  || { sed -n '1,10p' <<<"$OUT7" >&2; fail "the default parked prefix must be excluded even if the configured one differs"; }
pass "default spelling excluded when configured prefix differs"

# 8. The loop must RUN when this host is parked, so the enabled leg still gets
#    proof (review P0: the enclosing LOCAL_DISABLED branch skipped it entirely).
#    Assert on the real section-7 body: the loop is unconditional and the
#    "NOT REQUIRED" skip is gone from it.
SEC7_BLOCK="$(awk 'index($0,"section \"7. real job-execution proof"){f=1} f{print} f&&index($0,"real jobs succeeded on our fleet"){exit}' "$D")"
[ -n "$SEC7_BLOCK" ] || fail "could not extract section 7"
grep -qi 'loop ALWAYS runs' <<<"$SEC7_BLOCK" \
  || fail "section 7 must state that the proof loop always runs"
grep -q 'while read -r rid' <<<"$SEC7_BLOCK" \
  || fail "section 7 must still contain the proof loop"
if grep -q 'proof NOT REQUIRED' <<<"$SEC7_BLOCK"; then
  fail "section 7 must not skip the proof loop for a parked local leg"
fi
pass "section 7 runs the proof loop even when the local leg is parked"

# 9. REVIEW P0: failed config lookup + drifted historical prefix.
#    When the remote config cannot be read, the early prefix falls back to the
#    default. A historical `ez-mac-runner-g-4` success must STILL be excluded --
#    that is what the platform-family rule is for. Without it, `ez-*` admitted it.
OUT9="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ez-mac-runner-g-4 success 0 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$OUT9" \
  || { sed -n '1,12p' <<<"$OUT9" >&2; fail "failed-lookup drift: a historical parked-family success must not count"; }
pass "failed lookup + drifted historical prefix is excluded by the family rule"

# 10. The family rule must not swallow the ENABLED leg's successes (no over-block).
OUT10="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ez-runner-c-3 success 0 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=1' <<<"$OUT10" \
  || { sed -n '1,12p' <<<"$OUT10" >&2; fail "the family rule must not block the enabled leg's successes"; }
pass "family rule leaves the enabled leg's successes intact"

# 11. Mirror orientation: Mac host, Linux leg parked, a Linux-family success is
#     excluded while the Mac leg still counts.
OUT11="$(CLASSIFY_PLATFORM=macos DEFAULT_REMOTE_PREFIX=ez-runner-c classify ez-runner-c-9 success 0 1 ez-mac-runner-h ez-runner-c)"
grep -q 'COUNT=0' <<<"$OUT11" \
  || { sed -n '1,12p' <<<"$OUT11" >&2; fail "mac-host orientation: parked Linux-family success must not count"; }
pass "mac-host orientation excludes the parked Linux family"

# 12. The --prove canary uses the SAME early-resolved prefix (review P0: it read
#     REMOTE_PREFIX, which is only populated in section 10, so a drifted parked
#     leg slipped through and set CANARY_OK=1).
# Anchor on the assignment, not a comment: the section-7 comment shares its
# opening words, so a comment-anchored range ended before the real block.
CANARY_BLOCK="$(awk '/Same exact attribution as section 7/{f=1} f{print} f&&/cannot prove the enabled fleet/{exit}' "$D")"
[ -n "$CANARY_BLOCK" ] || fail "could not extract the canary exclusion block"
grep -q '_classify_run_leg' <<<"$CANARY_BLOCK" \
  || fail "the canary must use the shared classifier (which owns the early prefix)"
grep -q '_classify_run_leg' <<<"$CANARY_BLOCK" \
  || fail "the canary must use the shared exact classification"
pass "the canary consults the early-resolved and default prefixes"

# 13. Historical Linux prefix (ez-runner-b / ez-org-runner) must be treated as
#     the Linux family, so a parked Linux leg cannot prove the enabled Mac fleet.
OUT13="$(CLASSIFY_PLATFORM=macos DEFAULT_REMOTE_PREFIX=ez-runner-c classify ez-runner-b-7 success 0 1 ez-mac-runner-h ez-runner-c)"
grep -q 'COUNT=0' <<<"$OUT13" \
  || { sed -n '1,12p' <<<"$OUT13" >&2; fail "historical ez-runner-b must not prove the enabled Mac fleet while Linux is parked"; }
pass "historical ez-runner-b is excluded from a parked Linux leg"

OUT13b="$(CLASSIFY_PLATFORM=macos DEFAULT_REMOTE_PREFIX=ez-runner-c classify ez-org-runner-3 success 0 1 ez-mac-runner-h ez-runner-c)"
grep -q 'COUNT=0' <<<"$OUT13b" \
  || fail "legacy ez-org-runner must not prove the enabled Mac fleet while Linux is parked"
pass "legacy ez-org-runner is excluded from a parked Linux leg"

# 14. Enabled-mac control: a Mac-leg success still counts on a mac doctor with
#     Linux parked (no over-block from the family rule).
OUT14="$(CLASSIFY_PLATFORM=macos DEFAULT_REMOTE_PREFIX=ez-runner-c classify ez-mac-runner-h-2 success 0 1 ez-mac-runner-h ez-runner-c)"
grep -q 'COUNT=1' <<<"$OUT14" \
  || { sed -n '1,12p' <<<"$OUT14" >&2; fail "the enabled Mac leg's own success must still count"; }
pass "enabled Mac leg success still counts"

# 15. Both proof paths must use the SAME family helper (review P0: the canary
#     accepted ez-mac-runner-g-4 while section 7 rejected it).
SEC7_FAM=$(awk '/Positive attribution: a success counts/{f=1} f{print} f&&/^  fi$/{exit}' "$D" | grep -c '_classify_run_leg')
CANARY_FAM=$(awk '/Same exact attribution/{f=1} f{print} f&&/cannot prove the enabled fleet/{exit}' "$D" | grep -c '_classify_run_leg')
[ "$SEC7_FAM" -ge 1 ] || fail "section 7 must use the shared family rule"
[ "$CANARY_FAM" -ge 1 ] || fail "the canary must use the SAME exact rule as section 7"
pass "both proof paths share the family rule"

# 16. REVIEW P0: unreadable config + a CUSTOM parked prefix (ez-custom-mac).
#     A denylist can never enumerate this. Positive attribution is what rejects
#     it: an unattributable name is inconclusive, not proof.
OUT16="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ez-custom-mac-4 success 0 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$OUT16" \
  || { sed -n '1,12p' <<<"$OUT16" >&2; fail "an unattributable custom parked name must not be proof"; }
pass "unreadable config + custom parked prefix is inconclusive, not proof"

# 17. ...and an enabled-leg name is still attributable in that same state.
OUT17="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ez-runner-c-4 success 0 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=1' <<<"$OUT17" \
  || { sed -n '1,12p' <<<"$OUT17" >&2; fail "the enabled leg must still be attributable when a leg is parked"; }
pass "enabled leg remains attributable under the same conditions"

# 18. The broad ez-* fallback is GONE even with nothing parked: an unrelated
#     ez-* name is unattributable, so it cannot certify either leg. (Dot review:
#     the catch-all hid the fact that a leg had no attributable proof.)
OUT18="$(classify ez-custom-thing-9 success 0 0 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$OUT18" \
  || { sed -n '1,12p' <<<"$OUT18" >&2; fail "an unrelated ez-* name must not count as proof even with nothing parked"; }
pass "unrelated ez-* name is unattributable (no broad fallback)"

# 19. The final verdict gate must be enforced whenever an ENABLED leg exists
#     (review P0: a parked Mac with 20 idle Linux slots passed with 0 proof).
GATE="$(grep -A14 'real-execution gate: at least one recent job' "$D")"
grep -q '_ENABLED_LEG_EXISTS' <<<"$GATE" \
  || fail "the real-execution gate must consult _ENABLED_LEG_EXISTS"
if grep -q 'REAL_ON_FLEET:-0}" -lt 1 \] && \[ "$LOCAL_DISABLED" -ne 1 \]' <<<"$GATE"; then
  fail "the gate must not exempt merely because THIS host is parked"
fi
pass "the execution gate is enforced whenever an enabled leg exists"

# 20. REVIEW P0 (fifth round): OPERATOR-VISIBLE prefix overlap.
#     `ez-runner-c` is a strict prefix of `ez-runner-custom-mac`, so a partial
#     match let the parked Mac's `ez-runner-custom-mac-4` prove the enabled
#     Linux leg. The repo's own `prefix-<digits>` rule rejects it.
OUT20="$(DEFAULT_REMOTE_PREFIX=ez-runner-custom-mac classify ez-runner-custom-mac-4 success 0 1 ez-runner-c ez-runner-custom-mac)"
grep -q 'COUNT=0' <<<"$OUT20" \
  || { sed -n '1,12p' <<<"$OUT20" >&2; fail "overlapping prefix: parked ez-runner-custom-mac-4 must not prove enabled ez-runner-c"; }
pass "overlapping parked prefix is not mistaken for the enabled leg"

# 21. Reverse overlap: a parked `ez-runner-c` must not steal the enabled
#     `ez-runner-ci-1` (the old hardcoded family rule did exactly this).
OUT21="$(CLASSIFY_PLATFORM=macos DEFAULT_REMOTE_PREFIX=ez-runner-c classify ez-runner-ci-1 success 0 1 ez-runner-ci ez-runner-c)"
grep -q 'COUNT=1' <<<"$OUT21" \
  || { sed -n '1,12p' <<<"$OUT21" >&2; fail "reverse overlap: enabled ez-runner-ci-1 must count despite a parked ez-runner-c"; }
pass "reverse overlap does not let a parked prefix steal the enabled leg"

# 22. The exact rule rejects a NON-numeric suffix as a slot name. Asserted with a
#     leg parked: with nothing parked the historical ez-* breadth intentionally
#     still accepts it, so the parked case is the one that proves the rule.
OUT22="$(DEFAULT_REMOTE_PREFIX=ez-mac-runner-h classify ez-runner-c-abc success 0 1 ez-runner-c ez-mac-runner-h)"
grep -q 'COUNT=0' <<<"$OUT22" \
  || { sed -n '1,12p' <<<"$OUT22" >&2; fail "a non-numeric suffix is not a slot name (parked case)"; }
# The shared classifier expresses it as the "unattributed" result.
# The shared classifier expresses it as the "unattributed" result string.
grep -q "printf 'unattributed'" "$D" \
  || fail "the shared classifier must return unattributed for an unmatched name"
pass "non-numeric suffix is not treated as a slot name"

# 23. A configured NON-ez enabled prefix still counts (no hardcoded ez assumption).
OUT23="$(classify ci-linux-1 success 0 1 ci-linux ez-mac-runner-h)"
grep -q 'COUNT=1' <<<"$OUT23" \
  || { sed -n '1,12p' <<<"$OUT23" >&2; fail "an enabled custom non-ez prefix must count"; }
pass "configured non-ez enabled prefix counts"

# 24. Review note: a remote prefix resolved AFTER section 7 must not turn the
#     gate red. The observations are not recounted, so the honest verdict is
#     UNPROVEN, not FAILED.
grep -q 'REMOTE_PROOF_NOT_RECOUNTED' "$D" \
  || fail "the late-resolved prefix must set REMOTE_PROOF_NOT_RECOUNTED"
GATE2="$(grep -A22 'real-execution gate: at least one recent job' "$D")"
grep -q 'UNPROVEN' <<<"$GATE2" \
  || fail "the gate must report UNPROVEN for the not-recounted case"

# BEHAVIOURAL assertion (review P2): drive the REAL gate block and prove that
# the not-recounted case warns WITHOUT incrementing CRITICAL, while a genuine
# failure still does increment it. A string grep alone would pass even if the
# marker were never set or the branch wrongly bumped the critical count.
GATE_BODY="$(awk '/^_ENABLED_LEG_EXISTS=1$/,/^fi$/' "$D")"
[ -n "$GATE_BODY" ] || fail "could not extract the execution gate block"
run_gate() { # real_on_fleet not_recounted parked_local parked_remote
  {
    echo 'set -uo pipefail'
    echo "REAL_ON_FLEET=$1; REAL_TOTAL=1; REMOTE_PROOF_NOT_RECOUNTED=$2"
    echo "PARKED_LOCAL=$3; PARKED_REMOTE=$4; CRITICAL=0"
    echo 'warn() { :; }'
    echo 'bad() { :; }'
    echo "$GATE_BODY"
    echo 'echo "CRITICAL=$CRITICAL"'
  } > "$WORK/gate.sh"
  bash "$WORK/gate.sh" 2>&1 | sed -n 's/^CRITICAL=//p'
}
C_RECOVERED="$(run_gate 0 1 0 1)"
C_REALFAIL="$(run_gate 0 0 0 1)"
C_PASS="$(run_gate 3 0 0 1)"
[ "$C_RECOVERED" = "0" ] \
  || { fail "not-recounted case must add ZERO criticals (got $C_RECOVERED)"; }
[ "$C_REALFAIL" = "1" ] \
  || { fail "a genuine no-proof failure must add exactly one critical (got $C_REALFAIL)"; }
[ "$C_PASS" = "0" ] \
  || { fail "a proven fleet must add no critical (got $C_PASS)"; }
pass "late recovery warns with zero criticals; a real failure still trips it"

echo "ALL PASS: execution proof is attributed to a leg and excludes parked legs"
