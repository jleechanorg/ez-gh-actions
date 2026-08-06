#!/usr/bin/env bash
# regression test: sections 9 and 10 of doctor-runner must share ONE DOWN
# re-sample pass for the LOCAL host -- not one sleep per section. The local
# fleet's DOWN classification must come from a single observation shared
# between the verdict gate (section 9) and the printed inventory table
# (section 10 / list_slot_work for the localhost branch) so the two
# sections cannot disagree on DOWN state for the same local slot -- see
# GH#41 / bead ez-gh-actions-xv1t (originally filed against the
# pre-consolidation state where section 10 re-probed docker a SECOND time
# with its own SECTION10_DOWN_RESAMPLE_SECONDS sleep and observed the
# local fleet at a different instant than section 9; the fix landed in
# commit 06e4299 which made section 10's localhost branch reuse
# LOCAL_SLOT_STATE_TABLE built once by section 9; this test pins that
# consolidation in place against any future regression).
#
# Defect this guards against: any future refactor that re-introduces a
# second DOWN re-sample on the local-host path. With the prior code the
# printed inventory table and the verdict gate could report DIFFERENT
# local DOWN counts on the SAME doctor-runner run, because each took its
# own docker samples at different instants (bead evidence: "totals said
# 0 down while gates said 1-3 down"). Reintroducing a second sleep on
# the local-host path is exactly how that defect class comes back.
#
# Three assertions, each isolating a different facet of the
# consolidation:
#   (a) static: the local-host branch of list_slot_work contains NO
#       `sleep` and NO `classify_local_slot` call -- it must read from
#       LOCAL_SLOT_STATE_TABLE which section 9 builds once.
#   (b) static: the script contains EXACTLY ONE
#       `sleep "$DOWN_PERSISTENCE_WAIT_SECONDS"` (the section-9 sleep).
#       Two such sleeps anywhere = the pre-fix duplication has come
#       back.
#   (c) behavioral: running section 9's classification + journal cross
#       check + section 10's local-host branch against a fixture fleet
#       with one persisted-DOWN slot produces IDENTICAL local DOWN
#       counts from both sections, and only ONE sleep fires total.
#
# Usage: bash tests/doctor_runner_down_resample_consolidation_test.sh

# Literal fixed-string assertions intentionally contain shell syntax.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

echo "--- doctor-runner DOWN re-sample consolidation regression (GH#41 / ez-gh-actions-xv1t) ---"
OVERALL_PASS=true

# --- Assertion (a): local-host branch of list_slot_work must NOT sleep or
# re-classify local slots. Extract the local-host branch (the `if [ "$host"
# = "localhost" ] && [ -n "${LOCAL_SLOT_STATE_TABLE:-}" ] ...` arm) so we
# can prove it has no `sleep` or `classify_local_slot` call. The local
# branch is bounded by the `if` and the matching `else` (or, if there is
# no else, the closing `fi`). We use the `else` line as the upper bound
# because both arms are present in the production script.
LOCAL_BRANCH_LINE=$(grep -n 'if \[ "\$host" = "localhost" \] && \[ -n "\${LOCAL_SLOT_STATE_TABLE:-}" \]' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$LOCAL_BRANCH_LINE" ]; then
  echo "FAIL: could not locate local-host branch of list_slot_work in $DOCTOR_SCRIPT (consolidation pattern missing entirely)" >&2
  OVERALL_PASS=false
else
  ELSE_LINE=$(tail -n +"$LOCAL_BRANCH_LINE" "$DOCTOR_SCRIPT" | grep -n '^  else$' | head -1 | cut -d: -f1)
  if [ -z "$ELSE_LINE" ]; then
    echo "FAIL: could not locate matching 'else' for local-host branch in $DOCTOR_SCRIPT" >&2
    OVERALL_PASS=false
  else
    ELSE_LINE=$((LOCAL_BRANCH_LINE + ELSE_LINE - 1))
    LOCAL_BRANCH_SRC=$(sed -n "${LOCAL_BRANCH_LINE},$((ELSE_LINE - 1))p" "$DOCTOR_SCRIPT")
    # Sanity: the branch must actually consume LOCAL_SLOT_STATE_TABLE,
    # otherwise the test is checking a different branch than intended.
    if ! grep -q 'LOCAL_SLOT_STATE_TABLE' <<<"$LOCAL_BRANCH_SRC"; then
      echo "FAIL: extracted local-host branch does not reference LOCAL_SLOT_STATE_TABLE -- wrong branch extracted" >&2
      OVERALL_PASS=false
    fi
    if grep -Eq '(^|[^A-Za-z_])sleep($|[^A-Za-z_0-9])' <<<"$LOCAL_BRANCH_SRC"; then
      echo "FAIL: local-host branch of list_slot_work contains a 'sleep' call -- sections 9 and 10 are no longer sharing a single re-sample pass (GH#41 / ez-gh-actions-xv1t)" >&2
      OVERALL_PASS=false
    else
      echo "  [local-branch-no-sleep] section 10 localhost branch has zero 'sleep' calls -- PASS"
    fi
    if grep -q 'classify_local_slot' <<<"$LOCAL_BRANCH_SRC"; then
      echo "FAIL: local-host branch of list_slot_work calls classify_local_slot -- section 10 must reuse section 9's classification, not re-probe (GH#41 / ez-gh-actions-xv1t)" >&2
      OVERALL_PASS=false
    else
      echo "  [local-branch-no-reclassify] section 10 localhost branch has zero 'classify_local_slot' calls -- PASS"
    fi
    if grep -q 'probe_slot_state' <<<"$LOCAL_BRANCH_SRC"; then
      echo "FAIL: local-host branch of list_slot_work calls probe_slot_state -- section 10 must reuse section 9's classification, not re-probe (GH#41 / ez-gh-actions-xv1t)" >&2
      OVERALL_PASS=false
    else
      echo "  [local-branch-no-probe] section 10 localhost branch has zero 'probe_slot_state' calls -- PASS"
    fi
  fi
fi

# --- Assertion (b): exactly ONE `sleep "$DOWN_PERSISTENCE_WAIT_SECONDS"`
# call exists in the entire script. Section 9 owns it. Two such sleeps
# anywhere in the script = the pre-fix duplicate-sleep pathology has come
# back (the issue's central complaint: "each perform their own ~25-30s
# DOWN re-sample sleep").
#
# Also pin the consolidation helper itself: GH#41's intent was that the
# DOWN re-sample is performed by a single named helper called by
# section 9, not duplicated inline. If a future refactor inlines the
# helper back into section 9's body, the static "one sleep" assertion
# would still pass (no behavior change) but the structural consolidation
# would have regressed.
if ! grep -q '^_down_resample_consolidated() {' "$DOCTOR_SCRIPT"; then
  echo "FAIL: _down_resample_consolidated() helper missing from $DOCTOR_SCRIPT (GH#41 structural consolidation regressed)" >&2
  OVERALL_PASS=false
else
  echo "  [consolidation-helper-present] _down_resample_consolidated() helper present -- PASS"
fi
if ! grep -q '_down_resample_consolidated "localhost" "\$PLATFORM"' "$DOCTOR_SCRIPT"; then
  echo "FAIL: section 9 does not call _down_resample_consolidated for the local host (GH#41 structural consolidation regressed)" >&2
  OVERALL_PASS=false
else
  echo "  [consolidation-helper-called] section 9 calls _down_resample_consolidated for localhost -- PASS"
fi
DOWN_PERSISTENCE_SLEEP_COUNT=$(grep -c 'sleep "\$DOWN_PERSISTENCE_WAIT_SECONDS"' "$DOCTOR_SCRIPT" || true)
if [ "$DOWN_PERSISTENCE_SLEEP_COUNT" -ne 1 ]; then
  echo "FAIL: found $DOWN_PERSISTENCE_SLEEP_COUNT occurrences of 'sleep \"\$DOWN_PERSISTENCE_WAIT_SECONDS\"' in $DOCTOR_SCRIPT, expected exactly 1 (section 9's shared re-sample; GH#41 / ez-gh-actions-xv1t)" >&2
  OVERALL_PASS=false
else
  echo "  [single-down-persistence-sleep] exactly 1 occurrence of 'sleep \"\$DOWN_PERSISTENCE_WAIT_SECONDS\"' (section 9's shared re-sample) -- PASS"
fi

# Belt-and-suspenders: the legacy SECTION10_DOWN_RESAMPLE_SECONDS variable
# (used only on the REMOTE-host path now) must appear ONLY as:
#   (i)  its initialization line ("SECTION10_DOWN_RESAMPLE_SECONDS=...")
#   (ii) references inside the list_slot_work function body.
# Any usage outside (i)/(ii) = the consolidation is incomplete (the
# variable is no longer about section 10's local-host branch specifically,
# so referencing it elsewhere is exactly how a second local sleep sneaks
# back in).
LSW_DEF=$(grep -n '^list_slot_work() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$LSW_DEF" ]; then
  echo "FAIL: could not locate list_slot_work() definition in $DOCTOR_SCRIPT" >&2
  OVERALL_PASS=false
else
  OFFENDING=$(grep -n 'SECTION10_DOWN_RESAMPLE_SECONDS' "$DOCTOR_SCRIPT" | awk -F: -v lsw="$LSW_DEF" '
    {
      # Reconstruct the post-colon portion (the original line content).
      # $1 is the line number; everything from $2 onward is the line.
      rest = $2
      for (i = 3; i <= NF; i++) rest = rest ":" $i
      # Allow the variable initialization line (assigns the default).
      if (rest ~ /^SECTION10_DOWN_RESAMPLE_SECONDS=/) next
      # Otherwise, only allow inside the function body (LSW_DEF+).
      if ($1 < lsw) print $1 ":" rest
    }
  ')
  if [ -n "$OFFENDING" ]; then
    echo "FAIL: SECTION10_DOWN_RESAMPLE_SECONDS referenced outside list_slot_work AND outside its initialization -- local-host sleep duplication has crept back:" >&2
    echo "$OFFENDING" >&2
    OVERALL_PASS=false
  else
    echo "  [section10-resample-remote-only] SECTION10_DOWN_RESAMPLE_SECONDS only in its initialization and inside list_slot_work -- PASS"
  fi
fi

# --- Assertion (c): behavioral. Stub classify_local_slot + sleep + the
# journal cross-check to count how many times each fires when we run
# section 9's full classification+journal-cross-check block AND section
# 10's local-host branch in the same subshell. The two MUST read from
# the same classification pass: one sleep, one classify_local_slot per
# local slot for the whole consolidated run, and identical DOWN counts
# for the same fixture slots.
#
# We extract section 9's DOWN-persistence block (the lines from the
# first `if [ "${#DOWN_SLOTS[@]}" -gt 0 ]; then` after the first
# classification loop through its closing `fi`) and section 10's
# local-host branch (the `if [ "$host" = "localhost" ] && ...
# LOCAL_SLOT_STATE_TABLE ...` arm) via sed line markers, then eval
# both in a subshell with stubs.

# Section 9's DOWN-persistence block is now invoked via the
# _down_resample_consolidated helper (GH#41 consolidation). The
# helper definition itself contains the re-sample + journal
# cross-check we need to exercise end-to-end.
S9_BLOCK_START=$(grep -n '^_down_resample_consolidated() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$S9_BLOCK_START" ]; then
  echo "FAIL: could not locate _down_resample_consolidated() helper in $DOCTOR_SCRIPT (consolidation helper missing)" >&2
  OVERALL_PASS=false
else
  # Find the matching `}` that closes the helper. Walk forward counting
  # `{` / `}` brace depth (the helper uses bash function syntax with
  # `if [ ... ]` blocks nested inside, so we need to track BOTH if/fi
  # depth and {/} brace depth). The closing `}` is on its own line at
  # column 0.
  S9_BLOCK_END=$(awk -v start="$S9_BLOCK_START" '
    NR < start { next }
    BEGIN { depth = 0; brace_depth = 0 }
    {
      # Track if/fi depth (matches nested bash conditionals).
      n_if = 0
      n_fi = 0
      if ($0 ~ /^if \[/) n_if++
      if ($0 ~ /^if !/) n_if++
      if ($0 ~ /^  if \[/) n_if++
      if ($0 ~ /^  if !/) n_if++
      if ($0 ~ /^fi$/) n_fi++
      if ($0 ~ /^  fi$/) n_fi++
      depth += n_if - n_fi

      # Track function-body brace depth. The helper opens with `{` on
      # the same line as the `()` so its opening brace is captured by
      # `^_down_resample_consolidated() {` (or `}` for the closer).
      if ($0 ~ /^[A-Za-z_][A-Za-z_0-9]*\(\) \{$/) brace_depth++
      if ($0 ~ /^\}$/) brace_depth--

      if (depth == 0 && brace_depth == 0 && NR > start) { print NR; exit }
    }
  ' "$DOCTOR_SCRIPT")
  if [ -z "$S9_BLOCK_END" ]; then
    echo "FAIL: could not locate closing 'fi' for section 9's DOWN-persistence block in $DOCTOR_SCRIPT" >&2
    OVERALL_PASS=false
  else
    S9_BLOCK_SRC=$(sed -n "${S9_BLOCK_START},${S9_BLOCK_END}p" "$DOCTOR_SCRIPT")

    S10_BRANCH_START=$LOCAL_BRANCH_LINE
    S10_BRANCH_END=$((ELSE_LINE - 1))
    S10_BRANCH_SRC=$(sed -n "${S10_BRANCH_START},${S10_BRANCH_END}p" "$DOCTOR_SCRIPT")

    if [ -z "${S10_BRANCH_SRC:-}" ]; then
      echo "FAIL: could not extract section 10's local-host branch source" >&2
      OVERALL_PASS=false
    else
      # Sanity: section 10's branch must NOT contain classify_local_slot
      # (would mean the duplication has come back at the source level).
      if grep -q 'classify_local_slot' <<<"$S10_BRANCH_SRC"; then
        echo "FAIL: section 10's local-host branch source still contains 'classify_local_slot' -- the consolidation is broken at the source level (GH#41 / ez-gh-actions-xv1t)" >&2
        OVERALL_PASS=false
      fi

      run_behavioral_case() {
        local label="$1" initial_down_slots="$2" first_pass_classify="$3" second_pass_classify="$4"
        # initial_down_slots is the set of slots section 9's input
        # state should report as DOWN on first pass (the slots that
        # enter the DOWN-persistence block). first_pass_classify /
        # second_pass_classify are space-separated slot names that
        # classify_local_slot reports DOWN on the respective pass.
        # second_pass_classify is the slots STILL DOWN after the
        # re-sample (the ones that will be journal-cross-checked then
        # classified persisted-DOWN).

        # File-based counters (subshell-safe): section 9 calls
        # `classify_local_slot "$_name"` inside `case "$(...)" in`, so
        # the function body runs in a $() subshell and any in-process
        # variable increments are lost. Write to a temp file instead.
        local CC_FILE=$(mktemp)
        local SC_FILE=$(mktemp)
        local SV_FILE=$(mktemp)
        echo 0 > "$CC_FILE"
        echo 0 > "$SC_FILE"
        : > "$SV_FILE"

        local out
        out=$(
          set -euo pipefail
          CC_FILE="$CC_FILE"
          SC_FILE="$SC_FILE"
          SV_FILE="$SV_FILE"
          initial_down_slots="$initial_down_slots"
          first_pass_classify="$first_pass_classify"
          second_pass_classify="$second_pass_classify"

          # Stubs matching doctor-runner's interface. We ONLY need
          # classify_local_slot + sleep + journal_has_respawn_evidence
          # for this behavioral test.
          classify_local_slot() {
            local _cc
            _cc=$(cat "$CC_FILE")
            _cc=$((_cc + 1))
            echo "$_cc" > "$CC_FILE"
            # Decide which "pass" this invocation is on (1st or 2nd).
            # Section 9 calls classify_local_slot once per slot in the
            # initial loop, then again per slot in the DOWN-persistence
            # block. We approximate the pass by the counter: odd = first
            # pass, even = second pass (per-slot basis).
            if [ $((_cc % 2)) -eq 1 ]; then
              for _n in $first_pass_classify; do
                if [ "$1" = "$_n" ]; then echo "DOWN"; return; fi
              done
              echo "EXECUTING"
            else
              for _n in $second_pass_classify; do
                if [ "$1" = "$_n" ]; then echo "DOWN"; return; fi
              done
              # Slot that was DOWN on first pass but is not in the
              # second-pass DOWN list = it "recovered" (returned Up).
              for _n in $first_pass_classify; do
                if [ "$1" = "$_n" ]; then echo "IDLE"; return; fi
              done
              echo "EXECUTING"
            fi
          }

          sleep() {
            local _sc
            _sc=$(cat "$SC_FILE")
            _sc=$((_sc + 1))
            echo "$_sc" > "$SC_FILE"
            echo "$1" >> "$SV_FILE"
            # Real sleep replaced with a no-op (tests must not stall).
            :
          }

          # Stub journal_has_respawn_evidence: never match -> all
          # candidates fail safe to DOWN (matches "no respawn activity"
          # real-world default).
          journal_has_respawn_evidence() { echo 0; }

          # Stub fetch_respawn_log_window: return empty (no journal
          # evidence available), success exit.
          fetch_respawn_log_window() { return 0; }

          # Helpers doctor-runner expects to be defined.
          info() { :; }
          bad()  { :; }
          ok()   { :; }
          warn() { :; }
          section() { :; }
          probe_service_state() { echo "active"; }

          # Pre-populate section 9's input state.
          PLATFORM="linux"
          RESPAWN_EVIDENCE_WINDOW_MIN=3
          DOWN_PERSISTENCE_WAIT_SECONDS=30
          RUNNER_NAME_PREFIX="ez-runner-c"
          CONFIGURED_COUNT=4
          if [ -n "$initial_down_slots" ]; then
            # Initial input simulates section 9's FIRST classification pass:
            # only the slots in initial_down_slots are pre-populated as
            # DOWN (the rest were EXECUTING on the first pass). In the
            # real script, this is the result of the initial loop.
            DOWN_SLOTS=()
            for _n in $initial_down_slots; do DOWN_SLOTS+=("$_n"); done
            IDLE_SLOTS=()
            EXECUTING_SLOTS=()
            for _i in 1 2 3 4; do
              _name="ez-runner-c-$_i"
              _is_down=false
              for _n in $initial_down_slots; do
                if [ "$_name" = "$_n" ]; then _is_down=true; break; fi
              done
              if [ "$_is_down" = "false" ]; then
                EXECUTING_SLOTS+=("$_name")
              fi
            done
          else
            DOWN_SLOTS=()
            IDLE_SLOTS=()
            EXECUTING_SLOTS=(ez-runner-c-1 ez-runner-c-2 ez-runner-c-3 ez-runner-c-4)
          fi
          CYCLING_SLOTS=()
          RESPAWN_FETCH_FAILED_LOCAL=0

          # Define the helper, then call it the same way section 9 does.
          eval "$S9_BLOCK_SRC"
          _down_resample_consolidated "localhost" "$PLATFORM" "${DOWN_SLOTS[@]}"

          # Capture section 9's final per-slot arrays.
          S9_DOWN="${DOWN_SLOTS[*]:-}"
          S9_CYCLING="${CYCLING_SLOTS[*]:-}"

          # Section 9's verdict-build: populate LOCAL_SLOT_STATE_TABLE
          # the same way the real script does (after DOWN-persistence).
          LOCAL_SLOT_STATE_TABLE=""
          for _name in "${EXECUTING_SLOTS[@]}"; do LOCAL_SLOT_STATE_TABLE+="$_name EXECUTING"$'\n'; done
          for _name in "${IDLE_SLOTS[@]}"; do LOCAL_SLOT_STATE_TABLE+="$_name IDLE"$'\n'; done
          for _name in "${CYCLING_SLOTS[@]}"; do LOCAL_SLOT_STATE_TABLE+="$_name CYCLING"$'\n'; done
          for _name in "${DOWN_SLOTS[@]}"; do LOCAL_SLOT_STATE_TABLE+="$_name DOWN"$'\n'; done

          # Snapshot counters BEFORE section 10 runs. If the
          # consolidation holds, these MUST NOT increment again.
          CLASSIFY_AFTER_S9=$(cat "$CC_FILE")
          SLEEP_AFTER_S9=$(cat "$SC_FILE")
          SLEEP_AFTER_S9_VALUES=$(cat "$SV_FILE")

          # Run section 10's local-host branch (eval'd standalone, as a
          # fragment of list_slot_work). We feed it the same prefix /
          # count / host / label that the real call site does.
          prefix="$RUNNER_NAME_PREFIX"
          count="$CONFIGURED_COUNT"
          host="localhost"
          label="linux (test)"
          # Minimal subset of list_slot_work's body for the local branch.
          # The extracted local branch is bounded by the line BEFORE the
          # matching `else` (i.e. it ends with `done`, no `fi`), so append
          # the closing `fi` for the standalone eval.
          eval "$S10_BRANCH_SRC
fi"

          # Extract the slot_state array section 10 populated. We
          # echoed it as SLOTS_DUMP for inspection.
          SLOTS_DUMP=""
          for _i in $(seq 1 "$count"); do
            SLOTS_DUMP+="${prefix}-${_i}=${slot_state[_i]:-DOWN} "
          done

          echo "MARKER_END"
          echo "S9_DOWN=$S9_DOWN"
          echo "S9_CYCLING=$S9_CYCLING"
          echo "CLASSIFY_TOTAL=$(cat "$CC_FILE")"
          echo "CLASSIFY_AFTER_S9=$CLASSIFY_AFTER_S9"
          echo "SLEEP_TOTAL=$(cat "$SC_FILE")"
          echo "SLEEP_AFTER_S9=$SLEEP_AFTER_S9"
          echo "SLEEP_VALUES=$(tr '\n' ' ' < "$SV_FILE")"
          echo "SLOTS_DUMP=$SLOTS_DUMP"
        )
        rm -f "$CC_FILE" "$SC_FILE" "$SV_FILE"

        local pass=true
        local s9_down s9_cycling classify_total classify_after_s9 sleep_total sleep_after_s9 sleep_values slots_dump
        s9_down=$(grep '^S9_DOWN=' <<<"$out" | cut -d= -f2-)
        s9_cycling=$(grep '^S9_CYCLING=' <<<"$out" | cut -d= -f2-)
        classify_total=$(grep '^CLASSIFY_TOTAL=' <<<"$out" | cut -d= -f2-)
        classify_after_s9=$(grep '^CLASSIFY_AFTER_S9=' <<<"$out" | cut -d= -f2-)
        sleep_total=$(grep '^SLEEP_TOTAL=' <<<"$out" | cut -d= -f2-)
        sleep_after_s9=$(grep '^SLEEP_AFTER_S9=' <<<"$out" | cut -d= -f2-)
        sleep_values=$(grep '^SLEEP_VALUES=' <<<"$out" | cut -d= -f2-)
        slots_dump=$(grep '^SLOTS_DUMP=' <<<"$out" | cut -d= -f2-)

        # Section 9's DOWN set must contain exactly the persisted-DOWN
        # slot the stub classified DOWN on BOTH passes. The other
        # first-pass DOWN slot recovered -> it should be in CYCLING
        # (because no journal evidence, but recovered in second pass =
        # back to IDLE per the recovery branch).
        # For simplicity, our stub returns IDLE on second pass for
        # recovered slots, which section 9's case statement moves from
        # DOWN to IDLE (not CYCLING -- CYCLING is journal-evidenced).
        # So S9_DOWN should equal "ez-runner-c-1" (the slot that
        # stayed DOWN across both passes).

        # (c.1) Sleep count: zero if no DOWN candidates were pre-populated
        # (section 9's DOWN block is a no-op then), exactly one if there
        # WERE DOWN candidates (section 9's shared re-sample pass). The
        # whole point of the consolidation: ZERO OR ONE, never two.
        local expected_sleeps=0
        if [ -n "$initial_down_slots" ]; then expected_sleeps=1; fi
        if [ "$sleep_total" != "$expected_sleeps" ]; then
          echo "  [$label] expected exactly $expected_sleeps sleep(s) total but SLEEP_TOTAL=$sleep_total (single-pass invariant violated; GH#41 / ez-gh-actions-xv1t) -- FAIL"
          pass=false
        fi

        # (c.2) Section 10's local-host branch must NOT have slept or
        # re-classified. If it did, the consolidation has regressed.
        if [ "$sleep_after_s9" != "$sleep_total" ]; then
          echo "  [$label] section 10's local-host branch should not sleep but sleep count grew from $sleep_after_s9 (after s9) to $sleep_total -- FAIL"
          pass=false
        fi
        if [ "$classify_after_s9" != "$classify_total" ]; then
          echo "  [$label] section 10's local-host branch should not re-classify local slots but classify count grew from $classify_after_s9 to $classify_total -- FAIL"
          pass=false
        fi

        # (c.3) The DOWN state must agree between section 9 and section
        # 10's local-host branch for the SAME slot. For every slot in
        # second_pass_classify (the slots still DOWN after the re-sample),
        # both sections must report it DOWN; for every slot NOT in
        # second_pass_classify, neither section must report it DOWN. This
        # is the strongest possible "no drift" assertion.
        for _n in ez-runner-c-1 ez-runner-c-2 ez-runner-c-3 ez-runner-c-4; do
          _s10_state=$(echo "$slots_dump" | tr ' ' '\n' | grep -E "^${_n}=" | head -1 | cut -d= -f2)
          _expect_down=false
          for _d in $second_pass_classify; do
            if [ "$_n" = "$_d" ]; then _expect_down=true; break; fi
          done
          _s9_has_down=false
          for _d in $s9_down; do
            if [ "$_n" = "$_d" ]; then _s9_has_down=true; break; fi
          done
          if [ "$_expect_down" = "true" ]; then
            if [ "$_s10_state" != "DOWN" ] || [ "$_s9_has_down" != "true" ]; then
              echo "  [$label] slot $_n expected DOWN in BOTH sections (persisted) but section9=$_s9_has_down section10=$_s10_state -- sections disagree on DOWN state (GH#41 / ez-gh-actions-xv1t)" >&2
              pass=false
            fi
          else
            if [ "$_s10_state" = "DOWN" ] || [ "$_s9_has_down" = "true" ]; then
              echo "  [$label] slot $_n expected NOT DOWN in either section but section9=$_s9_has_down section10=$_s10_state -- sections disagree on DOWN state (GH#41 / ez-gh-actions-xv1t)" >&2
              pass=false
            fi
          fi
        done

        if [ "$pass" = "true" ]; then
          echo "  [$label] s9_down='$s9_down' s9_cycling='$s9_cycling' classify_total=$classify_total sleep_total=$sleep_total sleep_values='$sleep_values' slots='$slots_dump' -- PASS"
          return 0
        else
          return 1
        fi
      }

      # Case (c.1): one persisted-DOWN slot, one recovered slot. The
      # shared re-sample (one sleep) determines the final state.
      run_behavioral_case "shared-pass-1-down-1-recovered" "ez-runner-c-1 ez-runner-c-2" "ez-runner-c-1 ez-runner-c-2" "ez-runner-c-1" || OVERALL_PASS=false

      # Case (c.2): both first-pass DOWN slots persisted. Section 9
      # reports BOTH as DOWN; section 10's local branch must agree on
      # BOTH (no re-classification, no second sleep).
      run_behavioral_case "shared-pass-2-down-both-persist" "ez-runner-c-1 ez-runner-c-2" "ez-runner-c-1 ez-runner-c-2" "ez-runner-c-1 ez-runner-c-2" || OVERALL_PASS=false

      # Case (c.3): no first-pass DOWN at all. Section 9's DOWN block
      # is a no-op (no sleep at all), section 10 reads from the
      # populated table, no disagreement possible.
      run_behavioral_case "no-first-pass-down-no-sleep-at-all" "" "" "" || OVERALL_PASS=false
    fi
  fi
fi

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi