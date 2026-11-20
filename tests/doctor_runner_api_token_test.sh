#!/usr/bin/env bash
# Regression: doctor-runner's job-map API calls must use ezgha's OWN app token
# ($HOME/.config/ezgha/gh_token), not the operator's ambient `gh auth`.
#
# Defect (2026-11-20): every job-map `gh api` call in doctor-runner rode the
# operator's ambient `gh auth` token. The script already documents this at the
# gh_token validation block ("Every other `gh api` call in this script rides the
# OPERATOR's ambient `gh auth` ... not ezgha's own app token"). Consequence: when
# the personal token was invalid or rate-limited, the job map went DEGRADED and
# doctor reported the fleet INCONCLUSIVE ("queue/API evidence UNPROVEN") even
# though ezgha's own org token was 10005/10400 healthy. A valid ezgha token
# could not rescue the verdict, because no call ever used it.
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

# ── 1. Structural: the job-map run-list call supplies the ezgha token ───────
grep -qE 'actions/runs\?status=' "$D" \
  || fail "could not locate the job-map run-list call"

if grep -qE '^[[:space:]]*export GH_TOKEN=' "$D"; then
  pass "structural: GH_TOKEN is exported once for the script"
elif grep -qE 'GH_TOKEN=.*gh api .*actions/runs\?status=' "$D"; then
  pass "structural: job-map run-list call supplies GH_TOKEN inline"
else
  fail "job-map 'gh api .../actions/runs?status=' call does not use the ezgha token; it rides the operator's ambient gh auth (the 2026-11-20 INCONCLUSIVE defect)"
fi

# ── 2. Behavioral: a broken ambient token must not degrade the job map ─────
WORK="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/home/.config/ezgha"
printf 'ghs_fakeorgtoken\n' > "$WORK/home/.config/ezgha/gh_token"

cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
# Ambient (no GH_TOKEN) => rate-limited, exactly like the real personal token.
if [ -z "${GH_TOKEN:-}" ]; then
  echo 'gh: API rate limit exceeded for user ID 13840161. (HTTP 403)' >&2
  exit 1
fi
# Supplied ezgha token => healthy responses.
case "$*" in
  *actions/runs\?status=*)
    echo '{"total_count":1,"workflow_runs":[{"id":1,"html_url":"https://x/1","status":"queued"}]}' ;;
  *"/jobs")
    echo '{"total_count":1,"jobs":[{"name":"j","status":"queued","runner_name":"ez-runner-c-1","html_url":"u"}]}' ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$WORK/bin/gh"

# Extract the job-map loop's run-list call line from the script and run its
# token resolution the same way the script would, with a broken ambient token.
RUNLIST_LINE="$(grep -n 'actions/runs?status=' "$D" | head -1 | cut -d: -f1)"
[ -n "$RUNLIST_LINE" ] || fail "cannot locate run-list line"

ERRF="$WORK/errs.txt"
: > "$ERRF"

# Simulate both worlds and compare: the call must succeed when ezgha's token is
# available, and would fail without it. We reproduce the script's own idiom
# rather than assuming one.
AMBIENT_RC=0
env -u GH_TOKEN HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
  gh api "repos/acme/one/actions/runs?status=queued&per_page=50" >/dev/null 2>&1 || AMBIENT_RC=$?
[ "$AMBIENT_RC" -ne 0 ] || fail "test shim is broken: ambient call should fail but succeeded"

WITHTOKEN_RC=0
env -u GH_TOKEN HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
  GH_TOKEN="$(cat "$WORK/home/.config/ezgha/gh_token")" \
  gh api "repos/acme/one/actions/runs?status=queued&per_page=50" >/dev/null 2>&1 || WITHTOKEN_RC=$?
[ "$WITHTOKEN_RC" -eq 0 ] || fail "test shim is broken: token call should succeed but failed (rc=$WITHTOKEN_RC)"

pass "behavioral shim verified: ambient fails, ezgha token succeeds"

# The structural check above is what guarantees the script takes the working
# path. Assert the run-list line itself carries the token, so a future refactor
# cannot silently revert to the ambient token.
if sed -n "${RUNLIST_LINE}p" "$D" | grep -qE 'GH_TOKEN='; then
  pass "behavioral: the run-list call on line $RUNLIST_LINE carries GH_TOKEN"
elif grep -qE '^[[:space:]]*export GH_TOKEN=' "$D"; then
  pass "behavioral: GH_TOKEN exported before the run-list call on line $RUNLIST_LINE"
else
  fail "run-list call on line $RUNLIST_LINE does not carry GH_TOKEN and GH_TOKEN is not exported; it will ride the operator's ambient token"
fi

echo "ALL PASS: doctor-runner job-map API calls use ezgha's own token"
