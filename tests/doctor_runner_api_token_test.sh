#!/usr/bin/env bash
# Regression: doctor-runner must resolve ezgha's GitHub App token ONCE, before
# the parked/active host-path split, and must never let an ambient operator
# credential stand in for it.
#
# Defect history (2026-11-20), three review rounds:
#   R1  382377c: export lived in the ACTIVE-host branch; a parked host returned
#       early and its job map rode the operator's ambient token -> "0 in-progress
#       + 0 queued", verdict "queue/API evidence UNPROVEN", while the org token
#       was 10005/10400 healthy and unused.
#   R2  ced0d5f: export added to the parked block too, but the test was a grep --
#       three mutants passed (export under `if false`, export removed, gated 200).
#   R3  5803a8e: test rewritten to execute blocks; 401 abort fixed.
#   R4  1c218be: CodeRabbit found the missing-file path kept the operator token
#       live. `unset GH_TOKEN` added -- but only in the active branch, and unsetting
#       GH_TOKEN alone does not deauthenticate `gh` (GITHUB_TOKEN / stored
#       ~/.config/gh/hosts.yml still apply). Both holes found in review.
#   R5  current: ONE credential resolution before the branch split; resolves
#       EZGHA_APP_TOKEN_AVAILABLE, drops GITHUB_TOKEN/GH_ENTERPRISE_TOKEN when the
#       App token is unavailable, and never re-exports inside a branch.
#
# WHY THIS EXECUTES INSTEAD OF GREPPING: greps passed broken code twice. Every
# case below runs real extracted script text and asserts on observable results.
#
# Usage: bash tests/doctor_runner_api_token_test.sh
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/doctor-runner"
[ -x "$D" ] || { echo "FAIL: doctor-runner not executable at $D" >&2; exit 1; }
bash -n "$D" || { echo 'FAIL: doctor-runner has a syntax error' >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

FIXTURE="ghs_fixture_token_DO_NOT_USE_IN_PROD"
mkdir -p "$WORK/home_ok/.config/ezgha" "$WORK/home_missing" "$WORK/home_empty/.config/ezgha"
printf '%s\n' "$FIXTURE" > "$WORK/home_ok/.config/ezgha/gh_token"
: > "$WORK/home_empty/.config/ezgha/gh_token"

# ── Structural: exactly ONE resolution site ───────────────────────────────
# Two sites is how the parked path drifted from the active one (R1, R4).
EXPORTS="$(grep -cE '^[[:space:]]*export GH_TOKEN=' "$D" || true)"
[ "${EXPORTS:-0}" -eq 1 ] \
  || fail "expected exactly 1 'export GH_TOKEN=' site (single credential resolution), found ${EXPORTS:-0}; multiple sites let the parked and active paths diverge"
pass "structural: exactly one GH_TOKEN export site"

UNSETS="$(grep -cE '^unset GH_TOKEN$' "$D" || true)"
[ "${UNSETS:-0}" -eq 1 ] \
  || fail "expected exactly 1 bare 'unset GH_TOKEN' (in the single resolution block), found ${UNSETS:-0}"
pass "structural: exactly one 'unset GH_TOKEN'"

# The resolution block must sit BEFORE the parked-host branch, or a parked host
# returns before reaching it (the R1 defect).
EXPORT_LINE="$(grep -nE '^[[:space:]]*export GH_TOKEN=' "$D" | head -1 | cut -d: -f1)"
PARKED_LINE="$(grep -n 'host lifecycle (parked host)' "$D" | head -1 | cut -d: -f1)"
[ -n "$EXPORT_LINE" ] && [ -n "$PARKED_LINE" ] || fail "cannot locate export or parked-branch line"
[ "$EXPORT_LINE" -lt "$PARKED_LINE" ] \
  || fail "credential resolution (line $EXPORT_LINE) comes after the parked-host branch (line $PARKED_LINE); a parked host returns early and never reaches it"
pass "structural: credential resolution precedes the parked-host branch ($EXPORT_LINE < $PARKED_LINE)"

# ── Extract the real resolution block and execute it ─────────────────────
BLOCK_START="$(grep -n 'Credential resolution: ONE place' "$D" | head -1 | cut -d: -f1)"
[ -n "$BLOCK_START" ] || fail "cannot locate the credential-resolution block"
# Block runs from EZGHA_APP_TOKEN_PATH= to the closing fi of the GITHUB_TOKEN guard.
BLOCK_END="$(awk -v s="$BLOCK_START" 'NR>=s && /^fi$/ {n++; if (n==2) {print NR; exit}}' "$D")"
[ -n "$BLOCK_END" ] || fail "cannot locate the end of the credential-resolution block"
awk -v s="$BLOCK_START" -v e="$BLOCK_END" 'NR>=s && NR<=e' "$D" > "$WORK/resolve.body"
grep -q 'export GH_TOKEN' "$WORK/resolve.body" \
  || fail "extracted resolution block contains no 'export GH_TOKEN'"

run_resolve() { # $1=home  -> prints AVAIL= and HAS_GH= and HAS_GITHUB=
  local home="$1"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    cat "$WORK/resolve.body"
    echo 'printf "AVAIL=%s HAS_GH=%s HAS_GITHUB=%s\n" "$EZGHA_APP_TOKEN_AVAILABLE" "${GH_TOKEN:+set}" "${GITHUB_TOKEN:+set}"'
  } > "$WORK/resolve.sh"
  env -u GH_TOKEN HOME="$home" ${2:+GITHUB_TOKEN="$2"} bash "$WORK/resolve.sh" 2>/dev/null | tail -1
}

# ── Case F1: valid token file -> App token exported, available=1 ──────────
R="$(run_resolve "$WORK/home_ok")"
case "$R" in
  *"AVAIL=1"*"HAS_GH=set"*) pass "valid token file: App token exported, availability=1" ;;
  *) fail "valid token file did not produce a usable App token (got: $R)" ;;
esac

# ── Case F2: valid token file beats an inherited operator token ───────────
R="$(run_resolve "$WORK/home_ok" "inherited_operator_value")"
case "$R" in
  *"AVAIL=1"*"HAS_GH=set"*) pass "inherited operator token is overridden by the App token" ;;
  *) fail "an inherited operator credential was not overridden (got: $R)" ;;
esac

# ── Case F3: missing token file -> no App token, and GITHUB_TOKEN dropped ─
# This is the R4 finding: unsetting GH_TOKEN alone leaves GITHUB_TOKEN (and the
# stored hosts.yml credential) usable, so `gh` still authenticates as the operator.
R="$(run_resolve "$WORK/home_missing" "inherited_github_token")"
case "$R" in
  *"AVAIL=0"*) : ;;
  *) fail "missing token file still reported the App token as available (got: $R)" ;;
esac
case "$R" in
  *"HAS_GITHUB=set"*) fail "missing token file left GITHUB_TOKEN set, so gh can authenticate as the operator (got: $R)" ;;
  *) pass "missing token file: availability=0 and GITHUB_TOKEN dropped" ;;
esac

# ── Case F4: empty token file -> same, availability=0 ────────────────────
R="$(run_resolve "$WORK/home_empty" "inherited_github_token")"
case "$R" in
  *"AVAIL=0"*) pass "empty token file: availability=0" ;;
  *) fail "empty token file was treated as a usable App token (got: $R)" ;;
esac

# ── Case E: a 401 from the live probe must not abort the script ──────────
PROBE_LINE="$(grep -n 'GH_TOKEN_LIVE_HTTP=\$(' "$D" | head -1 | cut -d: -f1)"
[ -n "$PROBE_LINE" ] || fail "cannot locate the live-probe assignment"
# EXECUTE the line under `set -e` with a gh that exits nonzero. Pattern-matching
# for "||" was not enough: review found `|| exit 1` still satisfies a "||" check
# while aborting the script, which is the same defect wearing a different hat.
mkdir -p "$WORK/probe-bin"
printf '#!/usr/bin/env bash\necho "HTTP/2.0 401 Unauthorized"\nexit 1\n' > "$WORK/probe-bin/gh"
chmod +x "$WORK/probe-bin/gh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'export PATH="$PROBE_BIN:$PATH"'
  echo 'GH_TOKEN_PATH=/nonexistent'
  echo 'ORG=acme'
  sed -n "${PROBE_LINE}p" "$D"
  echo 'printf "SURVIVED=yes\n"'
} > "$WORK/probe.sh"
PROBE_RC=0
PROBE_OUT="$(env PROBE_BIN="$WORK/probe-bin" bash "$WORK/probe.sh" 2>/dev/null)" || PROBE_RC=$?
case "$PROBE_OUT" in
  *"SURVIVED=yes"*)
    [ "$PROBE_RC" -eq 0 ] \
      || fail "401 case: the live-probe line printed SURVIVED but exited $PROBE_RC" ;;
  *)
    fail "401 case: the live-probe assignment (line $PROBE_LINE) aborts the script when gh exits nonzero (rc=$PROBE_RC, output='${PROBE_OUT}'); under set -e/pipefail a 401 kills the run before it can print its token diagnosis. Pattern-matched '||' is NOT sufficient — it must route to a fallback, not exit." ;;
esac
pass "401 case: executing the real live-probe line survives a nonzero gh exit"

echo "ALL PASS: doctor-runner resolves the App token once, before the host-path split, and never falls back to an operator credential"
