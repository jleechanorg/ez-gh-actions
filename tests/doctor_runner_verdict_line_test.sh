#!/usr/bin/env bash
# regression test: the verdict headline line must derive its counts from the
# per-slot LOCAL+REMOTE truth (section 9 EXECUTING_SLOTS/IDLE_SLOTS/
# DOWN_SLOTS/CYCLING_SLOTS + section 10 REMOTE_*_SLOTS, both already
# 2-sample/ssh-verified ground truth), never the GitHub API's
# online/total/busy counts or the Mac-LOCAL-ONLY container count --
# ez-gh-actions-5u3s.
#
# Root cause this guards against: the prior verdict line was
#   ok "fleet healthy: $ONLINE/$TOTAL runners online, $BUSY busy, \
#       $CONTAINER_COUNT containers up, $LOOP_FAILS loop errors"
# which mixed a GitHub-API-sourced $ONLINE/$TOTAL/$BUSY (untrustworthy under
# the secondary rate limit -- the SAME fleet was reported as 7/11/16/19/22
# across calls minutes apart, see repo CLAUDE.md "Fleet capacity standard")
# with a Mac-LOCAL-ONLY $CONTAINER_COUNT (blind to the other host's half of
# the two-host fleet), and never consulted the per-slot arrays that are the
# actual ground truth.
#
# This test extracts the ACTUAL compute_verdict_summary() function from
# doctor-runner (via sed, not a re-implementation) so it can't silently
# drift from the real logic, then exercises it against fixture per-slot
# counts covering:
#   (a) local+remote executing/idle-ok, no starvation, no down -> totals
#       aggregate both hosts correctly.
#   (b) starvation present -> idle slots reclassify from idle-ok to
#       idle-starved (not silently dropped).
#   (c) down slots (local + remote) counted in the down bucket, and the
#       cycling slots (mid-respawn, journal-confirmed) get their own
#       cycling bucket -- NOT folded into executing. The prior code
#       conflated cycling into executing, which inflated the executing
#       bucket with slots that have no Runner.Worker pid (a cycling slot
#       is containerless by definition).
#   (d) unreachable-remote case (regression test for PR #64 follow-up):
#       when the remote host is unreachable, its slots are not proven
#       EXECUTING/IDLE; they must appear in the headline `down` bucket so
#       `configured` stays at the full expected fleet size (not local-only)
#       and the verdict cannot silently green.
#
# Usage: bash tests/doctor_runner_verdict_line_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

# Extract the real compute_verdict_summary() function definition from
# doctor-runner (lines bounded by its def/close-brace markers) rather than
# hardcoding a duplicate -- keeps the test honest against code drift.
FUNC_START=$(grep -n '^compute_verdict_summary() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate compute_verdict_summary() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
FUNC_END=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_START + FUNC_END - 1))
FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")

# Assert the old API-count-mixed verdict line is actually gone (not just
# supplemented) -- the defect this fix targets was a headline verdict line
# that named $ONLINE/$TOTAL/$BUSY/$CONTAINER_COUNT together as if they were
# one consistent measurement; if that exact combination is still the
# headline ok() call, the scope-mixing defect is still reachable regardless
# of what else we added.
if grep -q 'ok "fleet healthy: \$ONLINE/\$TOTAL runners online' "$DOCTOR_SCRIPT"; then
  echo "FAIL: old API-count/container-count mixed verdict line still present in $DOCTOR_SCRIPT (should be replaced, not just supplemented)" >&2
  exit 1
fi

# Assert the new verdict line consults the per-slot arrays (not a fresh
# docker/API sample) by checking the call site passes the section-9/10
# arrays as arguments.
if ! grep -q 'compute_verdict_summary \\' "$DOCTOR_SCRIPT"; then
  echo "FAIL: compute_verdict_summary call site not found in $DOCTOR_SCRIPT" >&2
  exit 1
fi

# Assert P1 #1: cycling is NOT folded into executing. The pre-fix code had
# `executing=$((l_exec + r_exec + l_cyc + r_cyc))` -- a cycling slot
# (containerless, mid-respawn) was silently counted as executing. The
# fix renames the buckets so cycling is its own count and only true
# EXECUTING slots contribute to executing.
if grep -q 'local executing=$((l_exec + r_exec + l_cyc + r_cyc))' "$DOCTOR_SCRIPT" \
   || grep -q 'executing=$((l_exec + r_exec + l_cyc + r_cyc))' "$DOCTOR_SCRIPT"; then
  echo "FAIL: cycling is still folded into executing in compute_verdict_summary -- P1 #1 regression" >&2
  exit 1
fi

run_case() {
  local label="$1" l_exec="$2" l_idle="$3" l_down="$4" l_cyc="$5" \
        r_exec="$6" r_idle="$7" r_down="$8" r_cyc="$9" starved="${10}" \
        exp_total="${11}" exp_configured="${12}" exp_exec="${13}" \
        exp_idle_ok="${14}" exp_idle_starved="${15}" exp_down="${16}" \
        exp_cycling="${17}"

  eval "$FUNC_SRC"

  local out total configured executing idle_ok idle_starved down cycling
  out=$(compute_verdict_summary "$l_exec" "$l_idle" "$l_down" "$l_cyc" \
                                 "$r_exec" "$r_idle" "$r_down" "$r_cyc" "$starved")
  read -r total configured executing idle_ok idle_starved down cycling <<< "$out"

  local pass=true
  [ "$total" -eq "$exp_total" ] || pass=false
  [ "$configured" -eq "$exp_configured" ] || pass=false
  [ "$executing" -eq "$exp_exec" ] || pass=false
  [ "$idle_ok" -eq "$exp_idle_ok" ] || pass=false
  [ "$idle_starved" -eq "$exp_idle_starved" ] || pass=false
  [ "$down" -eq "$exp_down" ] || pass=false
  [ "$cycling" -eq "$exp_cycling" ] || pass=false

  if [ "$pass" = "true" ]; then
    echo "  [$label] total=$total configured=$configured executing=$executing cycling=$cycling idle_ok=$idle_ok idle_starved=$idle_starved down=$down -- PASS"
    return 0
  else
    echo "  [$label] got: total=$total configured=$configured executing=$executing cycling=$cycling idle_ok=$idle_ok idle_starved=$idle_starved down=$down" \
         "| expected: total=$exp_total configured=$exp_configured executing=$exp_exec cycling=$exp_cycling idle_ok=$exp_idle_ok idle_starved=$exp_idle_starved down=$exp_down -- FAIL"
    return 1
  fi
}

echo "--- doctor-runner verdict-line summary regression ---"
OVERALL_PASS=true

# Case (a): 16 local (14 executing + 2 idle, no starvation) + 6 remote
# (6 executing) = 22 configured, all healthy, no starvation, no down.
run_case "local14exec-2idle-remote6exec-no-starvation" \
  14 2 0 0  6 0 0 0  0 \
  22 22 20 2 0 0 0 || OVERALL_PASS=false

# Case (b): same as (a) but starvation present -- the 2 local idle slots
# must reclassify from idle-ok to idle-starved, not vanish.
run_case "local14exec-2idle-remote6exec-starved" \
  14 2 0 0  6 0 0 0  1 \
  22 22 20 0 2 0 0 || OVERALL_PASS=false

# Case (c): 2 local DOWN + 1 remote DOWN, 1 local CYCLING (mid-respawn,
# journal-confirmed). PROVES the fix: cycling is its own bucket, NOT
# silently added to executing (pre-fix would have read executing=17
# including the 1 cycling; correct reading is executing=16 and
# cycling=1).
run_case "local-2down-1cycling-remote-1down" \
  12 2 2 1  4 1 1 0  0 \
  23 23 16 3 0 3 1 || OVERALL_PASS=false

# Case (d): unreachable-remote regression (P1 #2 from PR #64 cold review).
# Remote host unreachable -> 6 remote slots are UNPROVEN, so they
# contribute as DOWN. `configured` must stay at the full 22 (NOT collapse
# to local-only 16), and `down` must include all 6 unreachable slots.
# This mirrors what doctor-runner now does at the unreachable branch:
# it synthesizes REMOTE_DOWN_SLOTS entries so the verdict gate sees
# REMOTE_COUNT down slots. Driving this through compute_verdict_summary
# directly proves the math doesn't silently lose the unreachable half
# of the fleet.
run_case "local-16exec-remote-unreachable-6down" \
  16 0 0 0  0 0 6 0  0 \
  22 22 16 0 0 6 0 || OVERALL_PASS=false

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi