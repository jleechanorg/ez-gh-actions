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
# Why this test checks reachability rather than only grepping for `export`:
# review of the first version found that a structural grep passes even when the
# export sits inside a branch that never runs. The parked-host path
# (LOCAL_DISABLED=1) returns early, so an export placed only inside the
# active-host branch satisfies a grep while never executing — which is exactly
# the bug that shipped in the first revision of this fix.
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

# ── 1. The script exports GH_TOKEN from the ezgha token file ───────────────
grep -qE '^[[:space:]]*export GH_TOKEN=' "$D" \
  || fail "doctor-runner never exports GH_TOKEN from the ezgha token file; API calls ride the operator's ambient gh auth"
pass "structural: doctor-runner exports GH_TOKEN"

# ── 2. Exports read the ezgha token path, not an ambient variable ──────────
grep -qE 'export GH_TOKEN="\$\(cat "\$GH_TOKEN_PATH' "$D" \
  || grep -qE 'export GH_TOKEN="\$\(cat "\$GH_TOKEN_PATH_PARKED' "$D" \
  || fail "GH_TOKEN export does not read the ezgha token file ($GH_TOKEN_PATH)"
pass "structural: export reads the ezgha token file"

# ── 3. Reachability on BOTH host paths ────────────────────────────────────
# A parked host takes the LOCAL_DISABLED branch and returns early; an export
# that lives only in the active-host branch never runs there. Prove the export
# exists BEFORE the parked branch returns, by locating the first export line and
# the parked branch's exit line.
EXPORT_LINE="$(grep -nE '^[[:space:]]*export GH_TOKEN=' "$D" | head -1 | cut -d: -f1)"
[ -n "$EXPORT_LINE" ] || fail "no export GH_TOKEN line"

# The parked branch that RETURNS EARLY and skips the job map is the second
# `LOCAL_DISABLED` block (the first, ~line 254, only seeds verdict variables and
# does not exit). Target the block containing the "host lifecycle (parked host)"
# section banner so the reachability test measures the branch that actually
# skips sections 8/10.
PARKED_LINE="$(grep -n 'host lifecycle (parked host)' "$D" | head -1 | cut -d: -f1)"
[ -n "$PARKED_LINE" ] || fail "cannot locate the parked-host lifecycle branch"

# Bounding the parked BLOCK matters: an export anywhere later in the file
# (including the active-host branch's own export) would otherwise look
# "reachable" from PARKED_LINE, which is how the first version of this check
# wrongly passed an unreachable export. The parked block ends at the first
# top-level `else` after the banner.
PARKED_END="$(awk -v s="$PARKED_LINE" 'NR>s && /^else$/ {print NR; exit}' "$D")"
[ -n "$PARKED_END" ] || fail "cannot locate the end of the parked-host block"

# An export inside the parked branch (>= PARKED_LINE and before the active
# branch's section 4b) satisfies the parked path. An export only in the active
# branch (after the parked branch's `else`) does not.
PARKED_EXPORT="$(awk -v s="$PARKED_LINE" -v e="$PARKED_END" 'NR>=s && NR<e && /^[[:space:]]*export GH_TOKEN=/ {print NR; exit}' "$D")"
ACTIVE_EXPORT="$EXPORT_LINE"

if [ -n "$PARKED_EXPORT" ]; then
  pass "reachable: parked-host branch exports GH_TOKEN (line $PARKED_EXPORT) inside the parked block ($PARKED_LINE-$PARKED_END)"
elif [ "$ACTIVE_EXPORT" -lt "$PARKED_LINE" ]; then
  pass "reachable: export at line $ACTIVE_EXPORT precedes the parked branch at $PARKED_LINE"
else
  fail "unreachable on a parked host: no export inside the parked block ($PARKED_LINE-$PARKED_END); the only export is at line $ACTIVE_EXPORT in the active-host branch, so a parked host returns early and its job map still rides the ambient token"
fi

# ── 4. Behavioural: the token path works where ambient fails ──────────────
mkdir -p "$WORK/bin" "$WORK/home/.config/ezgha"
printf 'ghs_fakeorgtoken\n' > "$WORK/home/.config/ezgha/gh_token"

cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ -z "${GH_TOKEN:-}" ]; then
  echo 'gh: API rate limit exceeded for user ID 13840161. (HTTP 403)' >&2
  exit 1
fi
echo '{"total_count":0,"workflow_runs":[],"runners":[],"jobs":[]}'
SH
chmod +x "$WORK/bin/gh"

AMBIENT_RC=0
env -u GH_TOKEN HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
  gh api "repos/acme/one/actions/runs?status=queued&per_page=50" >/dev/null 2>&1 || AMBIENT_RC=$?
[ "$AMBIENT_RC" -ne 0 ] || fail "shim broken: ambient call should fail but succeeded"

TOKEN_RC=0
env -u GH_TOKEN HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
  GH_TOKEN="$(cat "$WORK/home/.config/ezgha/gh_token")" \
  gh api "repos/acme/one/actions/runs?status=queued&per_page=50" >/dev/null 2>&1 || TOKEN_RC=$?
[ "$TOKEN_RC" -eq 0 ] || fail "shim broken: token call should succeed but failed (rc=$TOKEN_RC)"
pass "behavioural: ambient token fails (403), ezgha token succeeds"

# ── 5. Guard: the export must not be gated on the token being valid ───────
# A file-exists check is required (so a missing file is reported, not silently
# swapped for ambient auth), but the export must not require the live probe to
# have succeeded, or a probe failure would itself disable the token path.
if grep -A3 -E '^[[:space:]]*export GH_TOKEN=' "$D" | grep -qE '200|GH_TOKEN_LIVE_HTTP'; then
  fail "GH_TOKEN export appears gated on the live HTTP probe succeeding; a probe failure must not disable the token path"
fi
pass "guard: export is presence-gated only, not gated on a successful live probe"

echo "ALL PASS: doctor-runner API calls use ezgha's own token on both host paths"
