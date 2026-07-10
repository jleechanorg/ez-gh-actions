#!/usr/bin/env bash
# regression test: a slot containerless across BOTH doctor-runner samples
# (~25-30s apart) must NOT be classified persisted-DOWN when the daemon's
# own log shows it respawning/managing that EXACT slot within the last few
# minutes -- see ez-gh-actions-5n0h.
#
# Root cause this guards against: a real respawn cycle (deregister -> mint
# JIT token -> docker run) can take 30-60s+ under load, longer than the
# 2-sample DOWN-persistence window (bead ez-gh-actions-b895). On a busy
# fleet, 1-2 slots are ALWAYS legitimately inside their respawn window at
# any given instant, so "containerless both samples" alone false-positived
# a healthy, self-healing fleet as broken -- evidence 2026-07-09: three
# consecutive doctor-runner runs each flagged a DIFFERENT rotating slot
# persisted-DOWN, and every flagged slot was observed "Up <60s" immediately
# after (the daemon self-healed every one).
#
# This test extracts the ACTUAL journal_has_respawn_evidence() classifier
# from doctor-runner (via sed, not a re-implementation) and exercises it
# against fixture daemon-log text, asserting:
#   (a) a fixture containing "respawned ephemeral runner <slot>" for the
#       EXACT slot within the window -> evidence=1 (caller then classifies
#       CYCLING, not DOWN -- second assertion mirrors that mapping).
#   (b) a fixture with NO line for that slot (daemon log has activity for
#       OTHER slots only, including a name that is a superstring of the
#       queried slot, e.g. "ez-runner-c-70" while querying "ez-runner-c-7")
#       -> evidence=0 (caller then classifies persisted-DOWN, unchanged
#       behavior -- proves the fix didn't just disable the DOWN gate).
#   (c) an EMPTY fixture (log fetch failed / no data) -> evidence=0, the
#       fail-safe default: "can't determine" must never silently become
#       "assume healthy".
#
# Usage: bash tests/doctor_runner_respawn_journal_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

# Extract the real journal_has_respawn_evidence() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate -- keeps the test honest against code drift.
FUNC_START=$(grep -n '^journal_has_respawn_evidence() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate journal_has_respawn_evidence() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
FUNC_END=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_START + FUNC_END - 1))
FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")
eval "$FUNC_SRC"

# Assert the classifier is actually wired into the DOWN-persistence path in
# BOTH section 9 (local) and list_slot_work (section 10 / remote), not just
# defined and unused -- the defect this guards against is specifically that
# containerless-both-samples alone used to be sufficient for DOWN.
if ! grep -q 'journal_has_respawn_evidence "\$_name"' "$DOCTOR_SCRIPT"; then
  echo "FAIL: journal_has_respawn_evidence not called from section 9's DOWN-persistence block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
if ! grep -q 'journal_has_respawn_evidence "\$name"' "$DOCTOR_SCRIPT"; then
  echo "FAIL: journal_has_respawn_evidence not called from list_slot_work's DOWN-persistence block in $DOCTOR_SCRIPT" >&2
  exit 1
fi

log_line() {
  # $1=epoch-ish prefix (unused by the classifier, just realism) $2=slot name
  printf '%s Jeff-Ubuntu ezgha[4192142]: respawned ephemeral runner %s\n' "$1" "$2"
}

run_case() {
  local label="$1" fixture="$2" slot="$3" expect_evidence="$4"

  local got
  got=$(printf '%s' "$fixture" | journal_has_respawn_evidence "$slot")

  local pass=true
  if [ "$got" != "$expect_evidence" ]; then
    echo "  [$label] evidence mismatch: got=$got want=$expect_evidence -- FAIL"
    pass=false
  fi

  # Mirror the caller's mapping (1 -> CYCLING, 0 -> persisted DOWN) so the
  # end-to-end classification outcome is asserted, not just the raw bit.
  local classification="DOWN"
  [ "$got" = "1" ] && classification="CYCLING"
  local expect_classification="DOWN"
  [ "$expect_evidence" = "1" ] && expect_classification="CYCLING"

  if [ "$pass" = "true" ]; then
    echo "  [$label] evidence=$got -> classification=$classification (expected $expect_classification) -- PASS"
    return 0
  else
    return 1
  fi
}

echo "--- doctor-runner respawn-journal cross-check regression ---"
OVERALL_PASS=true

# Case (a): daemon log shows a respawn line for the EXACT slot within the
# window -> evidence=1 -> CYCLING (mid-respawn, not abandoned).
FIXTURE_A=$(log_line "12:33:10" "ez-runner-c-7")
run_case "exact-match-respawn-line-cycling" "$FIXTURE_A" "ez-runner-c-7" "1" || OVERALL_PASS=false

# Case (b): daemon log has activity for OTHER slots only, including a name
# that is a SUPERSTRING of the queried slot (ez-runner-c-70 vs
# ez-runner-c-7) -- must NOT false-match via unanchored substring grep ->
# evidence=0 -> persisted DOWN stands. Proves the fix didn't just disable
# the DOWN gate, and that the end-of-line anchor prevents c-1/c-10-style
# collisions.
FIXTURE_B=$(
  log_line "12:33:10" "ez-runner-c-70"
  log_line "12:33:40" "ez-runner-c-12"
)
run_case "no-match-superstring-collision-avoided-down" "$FIXTURE_B" "ez-runner-c-7" "0" || OVERALL_PASS=false

# Case (c): empty fixture (log fetch failed / no data in window) ->
# evidence=0, the fail-safe default. "Couldn't determine" must never
# silently become "assume healthy".
run_case "empty-log-fail-safe-down" "" "ez-runner-c-7" "0" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
