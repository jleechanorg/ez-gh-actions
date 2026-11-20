#!/usr/bin/env bash
# Regression: doctor-runner's API calls must use ezgha's OWN app token
# ($HOME/.config/ezgha/gh_token), not the operator's ambient `gh auth`.
#
# Defect (2026-11-20): doctor-runner validated ezgha's app token in section 4b
# but ran the job-map `gh api` calls on the operator's ambient `gh auth` token.
# With an invalid personal token the job map reported "0 in-progress + 0 queued"
# and doctor forced "queue/API evidence UNPROVEN" even though the org token was
# 10005/10400 healthy and completely unused.
#
# WHY THIS TESTS EXECUTION, NOT TEXT:
# two earlier versions of this test grepped for `export GH_TOKEN` and for its
# line position. Review found BOTH passed against deliberately broken code:
#   - export deleted from the parked path        -> passed
#   - export wrapped in `if false; then`         -> passed
#   - the active export removed entirely         -> passed
#   - the active export gated on HTTP 200        -> passed
# Grep cannot distinguish "exported" from "exported somewhere that runs".
#
# So each case below EXTRACTS the relevant guarded block from the real script,
# wraps it in a harness that supplies the enclosing variables, and executes it.
# A block whose export sits under `if false`, or which fails to export, is
# observably different from one that works -- because we run it, not read it.
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

FIXTURE_TOKEN="ghs_fixture_token_DO_NOT_USE_IN_PROD"
mkdir -p "$WORK/home/.config/ezgha"
printf '%s\n' "$FIXTURE_TOKEN" > "$WORK/home/.config/ezgha/gh_token"

# Locate the two guarded blocks that must each export the token:
#   1. the parked-host block (banner -> its terminating top-level `else`)
#   2. the active-host section-4b export
PARKED_START="$(grep -n 'host lifecycle (parked host)' "$D" | head -1 | cut -d: -f1)"
[ -n "$PARKED_START" ] || fail "cannot locate the parked-host lifecycle branch"
PARKED_END="$(awk -v s="$PARKED_START" 'NR>s && /^else$/ {print NR; exit}' "$D")"
[ -n "$PARKED_END" ] || fail "cannot locate the end of the parked-host block"

# ── Case A: the PARKED block, executed, must export the token ──────────────
# Build a harness: real block body + the variables it depends on, then print
# what GH_TOKEN holds afterwards. The block ends by `exit`-ing in the real
# script, so we lift only its body and let it fall through.
awk -v s="$PARKED_START" -v e="$PARKED_END" 'NR>s && NR<e' "$D" > "$WORK/parked.body"
grep -q 'export GH_TOKEN' "$WORK/parked.body" \
  || fail "parked-host block ($PARKED_START-$PARKED_END) contains no 'export GH_TOKEN'; a parked host returns early and still rides ambient auth"

cat > "$WORK/parked.harness.sh" <<'HS'
#!/usr/bin/env bash
set -uo pipefail
PLATFORM=Darwin
HOST=testhost
section() { :; }; ok() { :; }; info() { :; }; bad() { :; }; warn() { :; }
FLEET_CONTRACT_SLOTS=0
HS
cat "$WORK/parked.body" >> "$WORK/parked.harness.sh"
cat >> "$WORK/parked.harness.sh" <<'HS'
printf 'RESULT=%s\n' "${GH_TOKEN:+SET}"
HS
chmod +x "$WORK/parked.harness.sh"
PARKED_RESULT="$(env -u GH_TOKEN HOME="$WORK/home" bash "$WORK/parked.harness.sh" 2>/dev/null | grep '^RESULT=' | cut -d= -f2)"
[ "$PARKED_RESULT" = "SET" ] \
  || fail "parked-host block executed but did NOT set GH_TOKEN (result='${PARKED_RESULT:-<none>}'); the export is missing or unreachable there"
pass "parked path: executing the real parked block sets GH_TOKEN"

# ── Case B: the ACTIVE export, executed, must set the token ───────────────
# Lift only the export statement plus its guard, and run it.
awk '/^[[:space:]]*if \[ -f "\$GH_TOKEN_PATH" \] && \[ -s "\$GH_TOKEN_PATH" \]; then$/{f=1} f{print} f&&/^[[:space:]]*fi$/{exit}' "$D" > "$WORK/active.body"
[ -s "$WORK/active.body" ] || fail "cannot extract the active-host export guard from doctor-runner"
grep -q 'export GH_TOKEN' "$WORK/active.body" \
  || fail "the active-host export guard contains no 'export GH_TOKEN'"

cat > "$WORK/active.harness.sh" <<'HS'
#!/usr/bin/env bash
set -uo pipefail
HS
echo 'GH_TOKEN_PATH="$HOME/.config/ezgha/gh_token"' >> "$WORK/active.harness.sh"
cat "$WORK/active.body" >> "$WORK/active.harness.sh"
echo 'printf "RESULT=%s\n" "${GH_TOKEN:+SET}"' >> "$WORK/active.harness.sh"
chmod +x "$WORK/active.harness.sh"
ACTIVE_RESULT="$(env -u GH_TOKEN HOME="$WORK/home" bash "$WORK/active.harness.sh" 2>/dev/null | grep '^RESULT=' | cut -d= -f2)"
[ "$ACTIVE_RESULT" = "SET" ] \
  || fail "active-host export guard executed but did NOT set GH_TOKEN (result='${ACTIVE_RESULT:-<none>}')"
pass "active path: executing the real export guard sets GH_TOKEN"

# ── Case C: the value must be the token file's contents, not something else ─
cat >> "$WORK/active.harness.sh" <<'HS'
printf 'VALUE_OK=%s\n' "$([ "${GH_TOKEN:-}" = "ghs_fixture_token_DO_NOT_USE_IN_PROD" ] && echo yes || echo no)"
HS
VALUE_OK="$(env -u GH_TOKEN HOME="$WORK/home" bash "$WORK/active.harness.sh" 2>/dev/null | grep '^VALUE_OK=' | cut -d= -f2)"
[ "$VALUE_OK" = "yes" ] || fail "exported GH_TOKEN does not equal the token file contents"
pass "value: exported GH_TOKEN equals the token file contents"

# ── Case D: export must not be gated on the live HTTP probe succeeding ────
# If `export GH_TOKEN` sits after a check that requires HTTP 200, a probe
# failure disables the token path -- the original defect, reintroduced.
case "$(cat "$WORK/active.body")" in
  *'200'*|*GH_TOKEN_LIVE_HTTP*)
    fail "the active export guard references the live HTTP probe (200 / GH_TOKEN_LIVE_HTTP); a probe failure would disable the token path" ;;
esac
pass "guard: export is presence-gated, not gated on a successful live probe"

# ── Case E: a 401 from the live probe must not abort the script ───────────
# (predates this PR, but it aborts before the export and skips every local
# diagnostic, so a bad token produces no actionable output at all.)
# ── Case E: a 401 from the live probe must not abort the script ───────────
# (predates this PR, but it aborts before the export and skips every local
# diagnostic, so a bad token produces no actionable output at all.)
PROBE_LINE="$(grep -n 'GH_TOKEN_LIVE_HTTP=\$(' "$D" | head -1 | cut -d: -f1)"
[ -n "$PROBE_LINE" ] || fail "cannot locate the live-probe assignment"
PROBE_SRC="$(sed -n "${PROBE_LINE}p" "$D")"

# The assignment must handle a nonzero gh exit locally. Without `|| ...`, a
# 401/403 aborts the whole script under set -e/pipefail before any diagnosis.
case "$PROBE_SRC" in
  *') || '*|*'|| true'*)
    pass "401 case: the live-probe assignment catches a nonzero gh exit instead of aborting" ;;
  *)
    fail "401 case: the live-probe assignment (line $PROBE_LINE) has no local failure handling; under set -e/pipefail a 401 aborts the script before it can print its token diagnosis or run any local check" ;;
esac

# ── Case F: a MISSING token file must not leave the operator's token live ──
# Section 5 makes every downstream `gh api` call. If the app-token file is
# absent and the operator's ambient GH_TOKEN is inherited, a bare
# `if [ -f ... ]; then export ...; fi` skips the export, leaves the inherited
# personal credential in scope, and section 5 silently rides it -- exactly the
# wrong-identity fallback this file exists to prevent (found in review).
# The guard must therefore unset first and export only on success.
awk '/^[[:space:]]*unset GH_TOKEN[[:space:]]*$/{f=1} f{print} f&&/^[[:space:]]*fi$/{exit}' "$D" > "$WORK/unset.body"
[ -s "$WORK/unset.body" ] \
  || fail "the active-host token guard has no 'unset GH_TOKEN' before its presence check; an absent token file would leave the operator's inherited credential in scope for section 5"

cat > "$WORK/unset.harness.sh" <<'HS'
#!/usr/bin/env bash
set -uo pipefail
HS
echo 'GH_TOKEN_PATH="$HOME/.config/ezgha/gh_token"' >> "$WORK/unset.harness.sh"
cat "$WORK/unset.body" >> "$WORK/unset.harness.sh"
echo 'printf "RESULT=%s\n" "${GH_TOKEN:-UNSET}"' >> "$WORK/unset.harness.sh"
chmod +x "$WORK/unset.harness.sh"

# Arm F1: inherited operator token + NO token file -> must end UNSET.
NOHOME="$WORK/home-no-token"
mkdir -p "$NOHOME"
MISSING_RESULT="$(HOME="$NOHOME" GH_TOKEN=operator_personal_token bash "$WORK/unset.harness.sh" 2>/dev/null | grep '^RESULT=' | cut -d= -f2-)"
[ "$MISSING_RESULT" = "UNSET" ] \
  || fail "missing token file left the inherited operator GH_TOKEN in scope (result='${MISSING_RESULT:-<none>}'); section 5 would authenticate with the personal credential instead of failing loudly"
pass "missing token file: the inherited operator GH_TOKEN is unset, not silently retained"

# Arm F2: inherited operator token + EMPTY token file -> must end UNSET.
# A zero-byte token file is a real failure mode (an interrupted refresh writes
# the file before its contents). The guard must reject it on size, not just
# existence, or section 5 exports an empty token and still masks the operator's
# inherited credential from diagnosis.
EMPTYHOME="$WORK/home-empty-token"
mkdir -p "$EMPTYHOME/.config/ezgha"
: > "$EMPTYHOME/.config/ezgha/gh_token"
EMPTY_RESULT="$(HOME="$EMPTYHOME" GH_TOKEN=operator_personal_token bash "$WORK/unset.harness.sh" 2>/dev/null | grep '^RESULT=' | cut -d= -f2-)"
[ "$EMPTY_RESULT" = "UNSET" ] \
  || fail "empty token file left GH_TOKEN holding '${EMPTY_RESULT:-<none>}'; the guard must reject a zero-byte file on size (-s), not only on existence (-f)"
pass "empty token file: GH_TOKEN ends unset rather than exported empty or retaining the operator token"

# Arm F3: inherited operator token + VALID token file -> app token must win.
PRESENT_RESULT="$(HOME="$WORK/home" GH_TOKEN=operator_personal_token bash "$WORK/unset.harness.sh" 2>/dev/null | grep '^RESULT=' | cut -d= -f2-)"
[ "$PRESENT_RESULT" = "$FIXTURE_TOKEN" ] \
  || fail "with the app-token file present the export must override the inherited operator token (got '${PRESENT_RESULT:-<none>}')"
pass "valid token file: the app token overrides any inherited operator GH_TOKEN"

echo "ALL PASS: doctor-runner exports the app token on both host paths, with correct value and a non-aborting probe"
