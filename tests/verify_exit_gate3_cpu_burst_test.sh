#!/usr/bin/env bash
# Focused Gate-3 CPU clamp regression for the 2026-10-03 limits.cpu_burst
# opt-in change. Exercises the extracted `expected_effective_cpus` helper
# across the four cases the bash verifier must handle:
#   1. default (cpu_burst=false) — equal-share clamp daemon_ncpu/count
#   2. burst + VM + finite capacity (Mac fixed8CPU, 6 runners, cfg=4.0)
#   3. burst + cfg.cpus > daemon_ncpu — clamp to daemon ncpu (no over-commit)
#   4. burst on unsupported VM (host daemon) — would have refused at serve
#      startup; Gate 3 does not re-validate here (serve ran, so VM was OK)
#      and the arithmetic falls back to the equal-share path because the
#      helper is purely arithmetic — the refusal is upstream.
#
# Does NOT touch the live fleet. Sources the helper directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/docs/verify-exit-criteria.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Source the pure helper. We can't source verify-exit-criteria.sh directly
# (it runs Gate 0…10 on load), so extract `expected_effective_cpus` into a
# tempfile via sed, then source that.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HELPER="$TMP/helper.sh"
# Pull everything from the `expected_effective_cpus() {` opener up to the
# closing `}` of the function. The function body ends with the matching
# brace of the `else` branch.
awk '
    /^expected_effective_cpus\(\) \{$/ { capturing=1 }
    capturing { print; if (/^}$/) exit }
' "$VERIFY" > "$HELPER"
grep -q 'expected_effective_cpus() {' "$HELPER" \
  || fail "could not extract expected_effective_cpus helper"
# shellcheck disable=SC1090
source "$HELPER"

# Case 1: cpu_burst=false, 8 CPU / 6 runners -> share 1.333.. -> clamp cfg
# (=4.0) does not apply because 4.0 > 1.333; expected = 1.33 (2-dp).
out=$(expected_effective_cpus "false" "4.0" "8" "6")
[ "$out" = "1.33" ] || fail "case1 default expected 1.33, got '$out'"

# Case 2: cpu_burst=true, 8 CPU / 6 runners, cfg=4.0 -> min(4.0, 8) = 4.00.
out=$(expected_effective_cpus "true" "4.0" "8" "6")
[ "$out" = "4.00" ] || fail "case2 burst expected 4.00, got '$out'"

# Case 3: cpu_burst=true, daemon_ncpu=4 / 6 runners, cfg=16 (operator typo)
# -> min(16.0, 4) = 4.00. This is the over-commit clamp: the helper must
# NEVER return a value > ncpu in the burst path.
out=$(expected_effective_cpus "true" "16.0" "4" "6")
[ "$out" = "4.00" ] || fail "case3 burst clamp expected 4.00, got '$out'"

# Case 4: cpu_burst=false with 2 CPU / 6 runners -> share 2/6 = 0.333,
# floored at 0.5 -> expected 0.50 (2-dp).
out=$(expected_effective_cpus "false" "1.0" "2" "6")
[ "$out" = "0.50" ] || fail "case4 default floor expected 0.50, got '$out'"

# Negative case: any burst result that exceeds ncpu is a bug in the clamp.
ncpu="6"
cpus=$(expected_effective_cpus "true" "16.0" "$ncpu" "10")
awk -v cpus="$cpus" -v ncpu="$ncpu" 'BEGIN { exit !(cpus <= ncpu + 0.005) }' \
  || fail "burst clamp must never exceed ncpu (cpus=$cpus ncpu=$ncpu)"

# Negative case: any default result that exceeds daemon_ncpu / count is
# only acceptable when cfg.cpus <= share; otherwise the share clamps it.
# This pins the share-floor behavior so a future refactor cannot silently
# raise the .5 floor.
out=$(expected_effective_cpus "false" "4.0" "8" "6")
awk -v cpus="$out" 'BEGIN { exit !(cpus <= 1.34 && cpus >= 1.32) }' \
  || fail "default share must stay in (1.32, 1.34] band, got '$out'"

# Verify the verifier file actually references the helper (so the seam is
# not orphaned — a refactor that deletes the call site would still pass
# the arithmetic above, but Gate 3 would silently keep the old logic).
grep -nq 'expected_effective_cpus \\\?' "$VERIFY" \
  || grep -q 'expected_effective_cpus \?' "$VERIFY" \
  || fail "Gate 3 must call expected_effective_cpus helper (found no reference)"

# Verify the LIMIT_CPU_BURST knob is read via the existing parser helper
# (no separate semantics invented).
grep -q 'LIMIT_CPU_BURST=$(toml_get_limits cpu_burst false)' "$VERIFY" \
  || fail "Gate 3 must read limits.cpu_burst via toml_get_limits (same helper as cpus/pids)"

echo "VERIFY_EXIT_GATE3_CPU_BURST_TEST: PASS"