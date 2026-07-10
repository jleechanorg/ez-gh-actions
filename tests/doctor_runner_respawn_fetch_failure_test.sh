#!/usr/bin/env bash
# regression test: a fetch_respawn_log_window() failure (ssh hiccup, missing
# log file) must NOT abort the whole doctor-runner run mid-classification --
# see codex adversarial review 2026-07-10, finding 2 (P1).
#
# Root cause this guards against: doctor-runner runs under
# `set -euo pipefail`. The DOWN-persistence journal-cross-check block did a
# bare `_RESPAWN_LOG=$(fetch_respawn_log_window ...)`. Under set -e, ANY
# nonzero return from that command substitution kills the entire script on
# the spot -- one flaky ssh call to a remote host wipes out every other
# slot's classification for the whole run, not just the one candidate being
# checked.
#
# This test extracts the ACTUAL local-fleet DOWN-persistence classification
# block from doctor-runner (via sed line markers, not a re-implementation)
# and the ACTUAL journal_has_respawn_evidence() classifier, then execs the
# block under `set -euo pipefail` (matching doctor-runner's own mode) with a
# stub fetch_respawn_log_window() that fails, asserting:
#   (a) the block does NOT abort the test process (a trailing echo after the
#       eval executes -- proof control returned, not "test happened to still
#       pass because bash swallowed the error").
#   (b) fetch failure = "no evidence" = the candidate is classified DOWN,
#       never masked as CYCLING (fail-safe direction).
#   (c) the failure is recorded (RESPAWN_FETCH_FAILED_LOCAL=1) so the caller
#       can annotate the evidence text with "(respawn-log fetch failed)".
#   (d) a SUCCESSFUL fetch with real respawn evidence still classifies
#       CYCLING and does NOT set the failure flag -- proves the fix didn't
#       just make everything fail open to DOWN unconditionally.
#
# Usage: bash tests/doctor_runner_respawn_fetch_failure_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

# Extract journal_has_respawn_evidence() (real classifier, same pattern as
# tests/doctor_runner_respawn_journal_test.sh).
JFUNC_START=$(grep -n '^journal_has_respawn_evidence() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
JFUNC_END=$(tail -n +"$JFUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
JFUNC_END=$((JFUNC_START + JFUNC_END - 1))
JFUNC_SRC=$(sed -n "${JFUNC_START},${JFUNC_END}p" "$DOCTOR_SCRIPT")
if [ -z "$JFUNC_SRC" ]; then
  echo "FAIL: could not locate journal_has_respawn_evidence() in $DOCTOR_SCRIPT" >&2
  exit 1
fi

# Extract the real local-fleet DOWN-persistence journal-cross-check block
# (the `if [ "${#_PERSISTENT_DOWN[@]}" -gt 0 ]; then ... fi` block that
# guards the fetch_respawn_log_window() call site at line ~733).
BLOCK_START=$(grep -n 'if \[ "\${#_PERSISTENT_DOWN\[@\]}" -gt 0 \]; then' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$BLOCK_START" ]; then
  echo "FAIL: could not locate the _PERSISTENT_DOWN journal-cross-check block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
BLOCK_END=$(awk -v start="$BLOCK_START" 'NR==start{c=1; next} NR>start{ if($0 ~ /^  fi$/){print NR; exit} }' "$DOCTOR_SCRIPT")
if [ -z "$BLOCK_END" ]; then
  echo "FAIL: could not locate the closing 'fi' for the journal-cross-check block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
BLOCK_SRC=$(sed -n "${BLOCK_START},${BLOCK_END}p" "$DOCTOR_SCRIPT")

# Sanity: the extracted block must actually contain the guarded call-site
# pattern (proves this test is exercising the FIXED code, not a stale
# extraction that silently stopped matching after a future refactor).
if ! grep -q 'if ! _RESPAWN_LOG=\$(fetch_respawn_log_window' <<<"$BLOCK_SRC"; then
  echo "FAIL: extracted block does not contain the guarded fetch_respawn_log_window call -- extraction markers are stale" >&2
  exit 1
fi

run_case() {
  local label="$1" fetch_should_fail="$2" fetch_output="$3" expect_abort="$4" expect_true_down="$5" expect_cycling="$6" expect_fetch_failed_flag="$7"

  # Isolated subshell so each case gets fresh globals and `set -e` behaves
  # exactly as it does in the real top-level script (a subshell abort exits
  # the subshell, not this test driver -- we detect it via the exit code and
  # the missing trailing marker).
  local out rc
  out=$(
    set -euo pipefail
    eval "$JFUNC_SRC"

    # Stub doctor-runner's output helpers -- without these, an unqualified
    # `info` call falls through to the system `info` (GNU docs reader)
    # binary, which is noisy and irrelevant to this test.
    info() { :; }
    bad()  { :; }

    fetch_respawn_log_window() {
      if [ "$fetch_should_fail" = "1" ]; then
        return 1
      fi
      printf '%s' "$fetch_output"
      return 0
    }

    PLATFORM="linux"
    RESPAWN_EVIDENCE_WINDOW_MIN=3
    _PERSISTENT_DOWN=("ez-runner-c-5")
    CYCLING_SLOTS=()
    DOWN_SLOTS=()

    eval "$BLOCK_SRC"

    echo "MARKER_REACHED_END"
    echo "RESPAWN_FETCH_FAILED_LOCAL=${RESPAWN_FETCH_FAILED_LOCAL:-0}"
    echo "DOWN_SLOTS=${DOWN_SLOTS[*]:-}"
    echo "CYCLING_SLOTS=${CYCLING_SLOTS[*]:-}"
  ) && rc=0 || rc=$?

  local pass=true

  local reached_end="no"
  grep -q '^MARKER_REACHED_END$' <<<"$out" && reached_end="yes"
  if [ "$expect_abort" = "no" ] && [ "$reached_end" != "yes" ]; then
    echo "  [$label] expected the block to complete (not abort) but MARKER_REACHED_END is missing (rc=$rc) -- FAIL"
    pass=false
  fi
  if [ "$expect_abort" = "yes" ] && [ "$reached_end" = "yes" ]; then
    echo "  [$label] expected the block to ABORT (set -e) but it completed anyway -- FAIL"
    pass=false
  fi

  local got_flag got_down got_cycling
  got_flag=$(grep '^RESPAWN_FETCH_FAILED_LOCAL=' <<<"$out" | cut -d= -f2)
  got_down=$(grep '^DOWN_SLOTS=' <<<"$out" | cut -d= -f2-)
  got_cycling=$(grep '^CYCLING_SLOTS=' <<<"$out" | cut -d= -f2-)

  if [ "$expect_abort" = "no" ]; then
    if [ "${got_flag:-}" != "$expect_fetch_failed_flag" ]; then
      echo "  [$label] RESPAWN_FETCH_FAILED_LOCAL mismatch: got=${got_flag:-<unset>} want=$expect_fetch_failed_flag -- FAIL"
      pass=false
    fi
    if [ "$expect_true_down" = "yes" ] && [ -z "${got_down:-}" ]; then
      echo "  [$label] expected ez-runner-c-5 classified DOWN but DOWN_SLOTS is empty -- FAIL"
      pass=false
    fi
    if [ "$expect_true_down" = "no" ] && [ -n "${got_down:-}" ]; then
      echo "  [$label] expected NO true-DOWN slots but DOWN_SLOTS=$got_down -- FAIL"
      pass=false
    fi
    if [ "$expect_cycling" = "yes" ] && [ -z "${got_cycling:-}" ]; then
      echo "  [$label] expected ez-runner-c-5 classified CYCLING but CYCLING_SLOTS is empty -- FAIL"
      pass=false
    fi
    if [ "$expect_cycling" = "no" ] && [ -n "${got_cycling:-}" ]; then
      echo "  [$label] expected NO cycling slots but CYCLING_SLOTS=$got_cycling -- FAIL"
      pass=false
    fi
  fi

  if [ "$pass" = "true" ]; then
    echo "  [$label] reached_end=$reached_end fetch_failed_flag=${got_flag:-<unset>} down=[${got_down:-}] cycling=[${got_cycling:-}] -- PASS"
    return 0
  else
    return 1
  fi
}

echo "--- doctor-runner respawn-log fetch-failure regression ---"
OVERALL_PASS=true

# Case (a): fetch_respawn_log_window fails (ssh hiccup) -> the guarded call
# site must NOT abort the block (set -e survives), the candidate fails safe
# to DOWN (never CYCLING), and the failure is flagged for the caller's
# evidence annotation.
run_case "fetch-fails-no-abort-fail-safe-down" "1" "" "no" "yes" "no" "1" || OVERALL_PASS=false

# Case (b): fetch succeeds but returns no matching evidence for this exact
# slot -> still classified DOWN (unchanged prior behavior), and the failure
# flag is NOT set (proves the annotation only fires on an actual fetch
# failure, not on every DOWN classification).
run_case "fetch-succeeds-no-evidence-down-no-flag" "0" "respawned ephemeral runner ez-runner-c-99" "no" "yes" "no" "0" || OVERALL_PASS=false

# Case (c): fetch succeeds and DOES contain matching evidence -> classified
# CYCLING, not DOWN, and the failure flag is NOT set. Proves the fix didn't
# regress the ez-gh-actions-5n0h CYCLING detection into "everything is DOWN
# now".
run_case "fetch-succeeds-with-evidence-cycling" "0" "respawned ephemeral runner ez-runner-c-5" "no" "no" "yes" "0" || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
