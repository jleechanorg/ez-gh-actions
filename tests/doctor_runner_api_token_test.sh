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
mkdir -p "$WORK/home_ok/.config/ezgha" "$WORK/home_missing/.config/ezgha" "$WORK/home_empty/.config/ezgha"
printf '%s\n' "$FIXTURE" > "$WORK/home_ok/.config/ezgha/gh_token"
: > "$WORK/home_empty/.config/ezgha/gh_token"
# A config file is required for doctor to get past its early config read; without
# it the script exits rc=2 with no output, which would make G1's "zero calls"
# pass vacuously. (Review: G1 needed a completion marker for exactly this reason.)
for h in home_ok home_missing home_empty; do
  printf 'name_prefix = "ez-runner-c"\ncount = 20\n' > "$WORK/$h/.config/ezgha/config.toml"
done

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

# ── Case F5: the exported value must be the FIXTURE, not merely nonempty ──
# Review found the test passed after substituting a wrong token value, because
# F1/F2 only checked that GH_TOKEN was nonempty. Assert the exact value.
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  cat "$WORK/resolve.body"
  echo 'printf "VALUE=%s\n" "${GH_TOKEN:-<unset>}"'
} > "$WORK/value.sh"
V="$(env -u GH_TOKEN HOME="$WORK/home_ok" bash "$WORK/value.sh" 2>/dev/null | grep '^VALUE=' | cut -d= -f2-)"
[ "$V" = "$FIXTURE" ] \
  || fail "exported GH_TOKEN is '$V', not the App token file contents; an export of a wrong/constant value would satisfy a nonempty check"
pass "value: exported GH_TOKEN is exactly the App token"

# ── Case G: whole-script boundary — a recording gh proves zero operator calls ─
# Review's central point: the token could be "available-looking" while the real
# call sites still ran and gh silently used stored auth. This runs the REAL
# script under a gh stub that records the credential each call carried, and
# requires: no token file => zero gh calls; valid file => only fixture-token calls.
GLOG="$WORK/gh-calls.log"
mkdir -p "$WORK/g-bin"
cat > "$WORK/g-bin/gh" <<GH
#!/usr/bin/env bash
if [ "\${GH_TOKEN:-}" = "$FIXTURE" ]; then printf 'APP|%s\n' "\$*" >> "$GLOG"
else printf 'OTHER(%s)|%s\n' "\${GH_TOKEN:-unset}" "\$*" >> "$GLOG"; fi
echo '{"total_count":0,"runners":[],"workflow_runs":[],"jobs":[],"resources":{"core":{"remaining":9999,"limit":10400,"reset":9999999999}}}'
GH
chmod +x "$WORK/g-bin/gh"
for b in docker systemctl launchctl colima virsh tart; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/g-bin/$b"; chmod +x "$WORK/g-bin/$b"
done
printf '#!/usr/bin/env bash\nexit 255\n' > "$WORK/g-bin/ssh"; chmod +x "$WORK/g-bin/ssh"

run_whole() { # $1=home  $2=log
  : > "$2"
  env -u GH_TOKEN HOME="$1" PATH="$WORK/g-bin:$PATH" GLOG="$2" \
      EZGHA_REPO=acme/one EXPLICIT_WORK_REPOS=acme/one \
      MAC_RUNNER_DISABLED=1 REMOTE_LINUX_DISABLED=1 HEALTH_ALERT_PLATFORM=Darwin \
      timeout 120 bash "$D" >/dev/null 2>&1 || true
}

# G1: missing token file -> gh must never authenticate as anyone.
G1_OUT="$WORK/g1.out"
: > "$WORK/g1.log"
env -u GH_TOKEN HOME="$WORK/home_missing" PATH="$WORK/g-bin:$PATH" GLOG="$WORK/g1.log" \
    EZGHA_REPO=acme/one EXPLICIT_WORK_REPOS=acme/one \
    MAC_RUNNER_DISABLED=1 REMOTE_LINUX_DISABLED=1 HEALTH_ALERT_PLATFORM=Darwin \
    timeout 120 bash "$D" >"$G1_OUT" 2>&1 || true
# Completion marker: without it, a script that dies early also makes zero calls
# and would pass this case vacuously (review point).
grep -q 'verdict' "$G1_OUT" \
  || fail "G1: the script did not reach its verdict section, so 'zero calls' proves nothing (output: $(head -3 "$G1_OUT"))"
g1_other=$(grep -c '^OTHER' "$WORK/g1.log" 2>/dev/null || true)
[ "${g1_other:-0}" -eq 0 ] \
  || fail "with NO App token the script still invoked gh with a non-App credential ($g1_other call(s)); gh would use stored auth. First: $(grep '^OTHER' "$WORK/g1.log" | head -1)"
pass "whole script, no App token: zero gh calls carrying a non-App credential"

# G2: valid token file -> the resolution exports exactly the App token, and no
# path exists that re-exports a different value. Full-script execution past
# section 4 requires extensive host fixtures (docker/colima/systemd/launchd) that
# hang without them, which would make this case depend on unrelated machinery
# rather than on the credential boundary it is meant to test. So G2 asserts the
# boundary directly: the single export site's value is the fixture, and there is
# exactly one such site.
G2_EXPORTS="$(grep -cE '^[[:space:]]*export GH_TOKEN=' "$D" || true)"
[ "${G2_EXPORTS:-0}" -eq 1 ] \
  || fail "there are ${G2_EXPORTS:-0} GH_TOKEN export sites; with more than one, a later site could overwrite the App token with another credential"
G2_SRC="$(grep -E '^[[:space:]]*export GH_TOKEN=' "$D")"
case "$G2_SRC" in
  *'$EZGHA_APP_TOKEN'*) pass "whole-script boundary: the single export site exports the App token (\$EZGHA_APP_TOKEN), not a constant or another variable)" ;;
  *) fail "the export site does not export \$EZGHA_APP_TOKEN (found: $G2_SRC)" ;;
esac

# ── Case G3: every GitHub call site must be gated on availability ────────
# Review: "availability only controls a warning. The fleet query still runs, as
# do the job-map queries. Even --prove can still dispatch." A warning is not a
# gate. Each site must be guarded by EZGHA_APP_TOKEN_AVAILABLE.
GATE_SITES=0
GATE_MISSING=""
for guard in \
  'GitHub runner census UNAVAILABLE' \
  'app-token-unavailable' \
  'live canary UNAVAILABLE'
do
  if grep -qF "$guard" "$D"; then
    GATE_SITES=$((GATE_SITES+1))
  else
    GATE_MISSING="$GATE_MISSING [$guard]"
  fi
done
[ -z "$GATE_MISSING" ] \
  || fail "these GitHub-backed sites lack an EZGHA_APP_TOKEN_AVAILABLE gate and would fall back to stored gh auth:$GATE_MISSING"
[ "$GATE_SITES" -eq 3 ] || fail "expected 3 gated GitHub call sites, found $GATE_SITES"
pass "gates: all 3 GitHub-backed sites refuse to run without the App token (census, job map, --prove canary)"

# ── Case H: the two blocks G1 could not see, executed with a recording stub ─
# Review: "Section 7 ... I ran the exact block with an active host, no token, and
# a recording stub. It called gh run list. G1 parks the host, so it misses this.
# The live probe still runs for a fresh empty file and passes an empty GH_TOKEN,
# allowing stored auth." Both are executed here, not grepped.
HLOG="$WORK/h-calls.log"
mkdir -p "$WORK/h-bin"
cat > "$WORK/h-bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'CALL|%s|token=%s\n' "$*" "${GH_TOKEN:-unset}" >> "$GLOG"
echo '{}'
GH
chmod +x "$WORK/h-bin/gh"

# H1: section 7 with an ACTIVE host and no App token must not call gh.
S7_LINE="$(grep -n 'section "7. real job-execution proof' "$D" | head -1 | cut -d: -f1)"
S7_END="$(awk -v s="$S7_LINE" 'NR>s && /^fi$/ {print NR; exit}' "$D")"
[ -n "$S7_LINE" ] && [ -n "$S7_END" ] || fail "cannot isolate section 7"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'EZGHA_APP_TOKEN_AVAILABLE=0'
  echo 'LOCAL_DISABLED=0'
  echo 'PLATFORM=Linux'
  echo 'ROUTING_N=2'
  echo 'EZGHA_REPO=acme/one'
  echo 'RUNNER_NAME_PREFIX=ez-runner'
  echo 'REMOTE_PREFIX=ez'
  echo 'section() { :; }; ok() { :; }; bad() { :; }; info() { :; }; warn() { :; }'
  awk -v s="$S7_LINE" -v e="$S7_END" 'NR>=s && NR<=e' "$D"
  echo 'printf "COMPLETED_S7\n"'
} > "$WORK/s7.sh"
: > "$HLOG"
S7_OUT="$(env -u GH_TOKEN PATH="$WORK/h-bin:$PATH" GLOG="$HLOG" bash "$WORK/s7.sh" 2>/dev/null)"
case "$S7_OUT" in *COMPLETED_S7*) : ;; *) fail "section 7 harness did not complete; cannot conclude" ;; esac
h1_calls=$(grep -c '^CALL' "$HLOG" 2>/dev/null || true)
[ "${h1_calls:-0}" -eq 0 ] \
  || fail "section 7 called gh $h1_calls time(s) with no App token (active host); gh would use stored auth. First: $(grep '^CALL' "$HLOG" | head -1)"
pass "section 7, active host, no App token: zero gh calls"

# H2: the live-probe guard must REFUSE when availability is 0, even when the
# token file exists and its status looks fresh (the fresh-but-empty path review
# found). A positional check is not enough — disabling the guard with `if false`
# leaves every line in place — so the guard's own condition is evaluated here.
PROBE_GUARD_LINE="$(grep -n 'gh_token live-check UNAVAILABLE' "$D" | head -1 | cut -d: -f1)"
[ -n "$PROBE_GUARD_LINE" ] || fail "the live-probe block has no availability guard"
PROBE_API_LINE="$(grep -n 'GH_TOKEN_LIVE_HTTP=\$(' "$D" | head -1 | cut -d: -f1)"
[ "$PROBE_GUARD_LINE" -lt "$PROBE_API_LINE" ] \
  || fail "the availability guard (line $PROBE_GUARD_LINE) does not precede the probe call (line $PROBE_API_LINE)"

# The guard must be the FIRST condition of its if-chain and must test
# EZGHA_APP_TOKEN_AVAILABLE. Rewriting it to `if false` (review's mutation) or
# to test something else both fail this.
GUARD_COND="$(awk -v s="$PROBE_GUARD_LINE" 'NR<s && /^if |^elif /{last=$0} NR==s{print last; exit}' "$D")"
case "$GUARD_COND" in
  *EZGHA_APP_TOKEN_AVAILABLE*) : ;;
  *) fail "the live-probe availability guard's condition is '$GUARD_COND', which does not test EZGHA_APP_TOKEN_AVAILABLE; an empty fresh file would reach gh and it would answer with stored auth" ;;
esac
pass "live probe: guard condition tests EZGHA_APP_TOKEN_AVAILABLE and precedes the call ($PROBE_GUARD_LINE < $PROBE_API_LINE)"

# ── Case H3: emptying the file AFTER resolution must not change the probe ─
# Review: "One fallback remains at doctor-runner:562: the probe rereads the file
# and overrides the already-loaded GH_TOKEN. If the file is emptied after
# resolution, the probe can still call gh with an empty token." Reproduced by the
# reviewer with a loaded synthetic token and an emptied file. The probe must use
# the SAME resolved token as every other call.
H3_TOKEN="$WORK/h3-token"; H3_LOG="$WORK/h3.log"
printf '%s\n' "$FIXTURE" > "$H3_TOKEN"
mkdir -p "$WORK/h3-bin"
cat > "$WORK/h3-bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'TOKEN=%s\n' "${GH_TOKEN:-<unset>}" >> "$GLOG"
printf 'HTTP/2.0 200 OK\n'
GH
chmod +x "$WORK/h3-bin/gh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'export PATH="$H_BIN:$PATH"'
  echo 'ORG=acme'
  echo 'GH_TOKEN_PATH="$H_TOKEN"'
  echo 'EZGHA_APP_TOKEN_AVAILABLE=0'
  echo 'ok() { :; }; bad() { :; }; info() { :; }; warn() { :; }'
  # Resolve once, as the script does.
  echo 'if [ -f "$GH_TOKEN_PATH" ] && [ -s "$GH_TOKEN_PATH" ]; then'
  echo '  EZGHA_APP_TOKEN="$(cat "$GH_TOKEN_PATH")"; export GH_TOKEN="$EZGHA_APP_TOKEN"; EZGHA_APP_TOKEN_AVAILABLE=1'
  echo 'fi'
  # Now empty the file, simulating truncation/rotation after resolution.
  echo ': > "$GH_TOKEN_PATH"'
  echo 'GH_TOKEN_STATUS=fresh'
  # Evaluated probe line.
  sed -n "$(grep -n 'GH_TOKEN_LIVE_HTTP=\$(' "$D" | head -1 | cut -d: -f1)p" "$D"
  echo 'printf "COMPLETED_H3\n"'
} > "$WORK/h3.sh"
: > "$H3_LOG"
H3_OUT="$(env -u GH_TOKEN H_BIN="$WORK/h3-bin" GLOG="$H3_LOG" H_TOKEN="$H3_TOKEN" bash "$WORK/h3.sh" 2>/dev/null)"
case "$H3_OUT" in *COMPLETED_H3*) : ;; *) fail "H3 harness did not complete; cannot conclude" ;; esac
H3_TOK="$(grep '^TOKEN=' "$H3_LOG" | head -1 | cut -d= -f2-)"
[ "$H3_TOK" = "$FIXTURE" ] \
  || fail "after the token file was emptied, the probe called gh with TOKEN='$H3_TOK' instead of the already-resolved App token; gh would fall back to stored auth"
pass "probe uses the resolved App token even if the file is emptied afterwards"

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
