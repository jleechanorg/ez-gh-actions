#!/usr/bin/env bash
# Parser integration test for the 2026-10-03 live-Mac regression:
# toml_get_limits was printing Python's 'True'/'False' from tomllib's
# bool repr, while gate3_burst_preflight + Gate 3 arithmetic compare
# against TOML-spec lowercase 'true'/'false'. Live Mac verifier failed
# Gate 3 with expected=1.33, actual=4 because LIMIT_CPU_BURST came out
# as 'True' and the burst branch never engaged (silent default-false
# equal-share path returned the raw cfg.cpus). Drive the ACTUAL
# toml_get_limits via a temp TOML (no hand-supplied booleans) so the
# integration is exercised end-to-end. Default-false + missing must
# also print lowercase 'false' (the prior code would have printed
# Python's 'False' even for the default).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/docs/verify-exit-criteria.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build a temp config matching the actual schema (limits.cpu_burst set).
write_toml() {
    cat > "$TMP/config.toml" <<EOF
[runner]
count = 6
name_prefix = "ez-org-runner"

[limits]
cpu_burst = $1
cpus = 4.0
memory_mb = 3000
pids = 1024
min_free_disk_gb = 10
EOF
}

# Extract helpers (is_uint, daemon_in_vm, gate3_burst_preflight,
# expected_effective_cpus, toml_get_limits) from the verifier. We need
# toml_get_limits intact because the active bug is inside it.
HELPER="$TMP/helpers.sh"
{
    awk '/^is_uint\(\) \{$/ { capturing=1 } capturing { print; if (/^}$/) { capturing=0; exit } }' "$VERIFY"
    awk '/^daemon_in_vm\(\) \{$/ { capturing=1 } capturing { print; if (/^}$/) { capturing=0; exit } }' "$VERIFY"
    awk '/^gate3_burst_preflight\(\) \{$/ { capturing=1 } capturing { print; if (/^}$/) { capturing=0; exit } }' "$VERIFY"
    awk '/^expected_effective_cpus\(\) \{$/ { capturing=1 } capturing { print; if (/^}$/) { capturing=0; exit } }' "$VERIFY"
    awk '/^toml_get_limits\(\) \{$/ { capturing=1 } capturing { print; if (/^}$/) { capturing=0; exit } }' "$VERIFY"
} > "$HELPER"
grep -q 'toml_get_limits() {' "$HELPER" || fail "could not extract toml_get_limits"
grep -q 'gate3_burst_preflight() {' "$HELPER" || fail "could not extract gate3_burst_preflight"
grep -q 'expected_effective_cpus() {' "$HELPER" || fail "could not extract expected_effective_cpus"
grep -q 'isinstance(value, bool)' "$HELPER" \
  || fail "toml_get_limits must render booleans as TOML-spec lowercase 'true'/'false' (regression 2026-10-03; live Mac printed Python's 'True')"

# Set CONFIG_FILE for the helpers and source them.
export CONFIG_FILE="$TMP/config.toml"
# shellcheck disable=SC1090
source "$HELPER"

# --- Case 1: cpu_burst = true (literal TOML bool) → 'true' ------------------
write_toml "true"
val=$(toml_get_limits cpu_burst false)
[ "$val" = "true" ] || fail "toml_get_limits(TOML true) must print 'true', got '$val' (regression: live Mac printed 'True')"
# Drive the real preflight using the value toml_get_limits produced.
LIMIT_CPU_BURST="$val"
# We can't actually exercise daemon_in_vm here (it depends on real
# docker/uname), but we can confirm gate3_burst_preflight's string
# compare against the value toml_get_limits returned. Stub daemon_in_vm
# to true via a subshell so we land at the NCPU branch and then drop
# out without exercising docker.
(
    LIMIT_CPU_BURST="$val"
    daemon_in_vm() { return 1; }   # intentionally false to test the VM refusal branch
    set +e
    out=$(gate3_burst_preflight 2>/tmp/case1_err)
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "case1: preflight must refuse (LIMIT_CPU_BURST='$val' + non-VM); got rc=$rc"
    grep -q 'not verified VM-contained' /tmp/case1_err \
      || fail "case1 stderr missing 'not verified VM-contained' (got: $(cat /tmp/case1_err))"
    # CRITICAL: the prior bug caused 'True' to flow into the comparison,
    # which would NOT match `[ \"\$LIMIT_CPU_BURST\" = \"true\" ]` and
    # would silently fall through to the equal-share arithmetic instead
    # of refusing. The fact that we reach the VM-refusal branch with
    # LIMIT_CPU_BURST='$val' proves the lowercase-render fix is live.
)

# --- Case 2: cpu_burst = false (literal TOML bool) → 'false' ----------------
write_toml "false"
val=$(toml_get_limits cpu_burst true)
[ "$val" = "false" ] || fail "toml_get_limits(TOML false) must print 'false', got '$val'"
# Drive the preflight — must short-circuit (default-false path).
LIMIT_CPU_BURST="$val" out=$(gate3_burst_preflight) \
  || fail "case2: preflight must accept (LIMIT_CPU_BURST='$val' default-false); rc=$?"
[ -z "$out" ] || fail "case2: preflight stdout must be empty on default-false (got '$out')"

# --- Case 3: cpu_burst missing → default 'true' (TOML bool) → 'true' --------
write_toml "false"
# Remove cpu_burst from the [limits] section entirely to exercise the
# default-value path. Default is a TOML bool 'true' (the literal Python
# source — but the helper now renders that as 'true' lowercase too).
sed -i '/^cpu_burst/d' "$TMP/config.toml"
val=$(toml_get_limits cpu_burst true)
[ "$val" = "true" ] || fail "toml_get_limits(missing, default='true') must print 'true', got '$val' (regression: prior code printed 'True')"

# --- Case 4: non-boolean values unchanged (cpus, memory_mb, pids) ------------
write_toml "true"
cpus_val=$(toml_get_limits cpus 0.50)
mem_val=$(toml_get_limits memory_mb 0)
pids_val=$(toml_get_limits pids 1024)
# toml_get_limits doesn't trim; that's fine. Just print correctness.
case "$cpus_val" in
    4.0|4) ;;  # either form is acceptable
    *) fail "toml_get_limits(cpus) must preserve numeric output, got '$cpus_val'" ;;
esac
# memory_mb and pids are integers; tomllib prints them as '3000' / '1024'.
[ "$mem_val" = "3000" ] || fail "toml_get_limits(memory_mb) must preserve int output, got '$mem_val'"
[ "$pids_val" = "1024" ] || fail "toml_get_limits(pids) must preserve int output, got '$pids_val'"

# --- Case 5: end-to-end — LIMIT_CPU_BURST from toml_get_limits flows into ---
# expected_effective_cpus with the burst branch (was the live Mac failure:
# expected=1.33 actual=4). On a CPU share calc: burst+VM+ncpu=8 → 4.00; the
# pre-fix bug returned 4 because LIMIT_CPU_BURST became 'True', but the
# expected branch became 1.33 (default-false). After the fix both agree.
write_toml "true"
LIMIT_CPU_BURST=$(toml_get_limits cpu_burst false)
expected=$(expected_effective_cpus "$LIMIT_CPU_BURST" "4.0" "8" "6")
[ "$expected" = "4.00" ] \
  || fail "case5: end-to-end expected_effective_cpus(\$LIMIT_CPU_BURST from toml_get_limits='$LIMIT_CPU_BURST', 4.0, 8, 6) must return '4.00', got '$expected' (regression: pre-fix returned 1.33 because LIMIT_CPU_BURST was 'True')"

echo "VERIFY_EXIT_TOML_PARSER_INTEGRATION_TEST: PASS"