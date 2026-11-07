#!/usr/bin/env bash
# Regression coverage for bead jleechan-user-scope-arm64-dead-label.
#
# Measured failure (2026-11-07): jleechanorg/user_scope held 8 queued
# `policy-installer-tests` runs, oldest 18.6h, whose job required
# [self-hosted, self-hosted-mikey, self-hosted-macos]. Zero online org runners
# advertised `self-hosted-macos` (the Mac leg is intentionally parked), so those
# jobs could never be picked up. Every existing lever was blind to it:
#   - not a "zombie"  (that lever only counts >STALE_HOURS *artifacts*)
#   - not "superseded" for the newest run on each branch
#   - repo was not even in DEFAULT_QUEUE_REPOS
# so the reaper reported a clean scan while 18h of CI sat dead.
#
# This test asserts the new report-only UNSCHEDULABLE lever:
#   1. A queued run needing a label no ONLINE runner carries is reported.
#   2. A run whose labels ARE all advertised is not reported.
#   3. The lever never cancels, whatever the age.
#   4. An unavailable label pool degrades to "not asserted", not a false verdict.
#
# Usage: bash tests/cleanup_stuck_runs_unschedulable_test.sh
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

W="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${W:?}"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export AGE_30M="$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# gh stub. LABEL_POOL=fail simulates a rate-limited runner list.
cat > "$W/gh" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"\$GH_LOG"

case "\$*" in
  *"orgs/acme/actions/runners"*)
    if [[ "\${LABEL_POOL:-ok}" == "fail" ]]; then
      echo "gh: API rate limit exceeded (HTTP 403)" >&2
      exit 1
    fi
    cat <<'JSON'
{"total_count":2,"runners":[
 {"id":1,"name":"linux-1","status":"online","labels":[{"name":"self-hosted"},{"name":"self-hosted-mikey"},{"name":"ez-runner-c"}]},
 {"id":2,"name":"linux-offline","status":"offline","labels":[{"name":"self-hosted"},{"name":"self-hosted-mikey"},{"name":"self-hosted-macos"}]}
]}
JSON
    exit 0 ;;
  *"actions/runs?status=queued"*)
    cat <<JSON
{"workflow_runs":[
 {"id":900,"status":"queued","name":"Presubmit","workflow_id":1,"head_branch":"feature/needs-macos","run_number":2,"created_at":"${AGE_30M}","html_url":"https://github.com/acme/repoX/actions/runs/900"},
 {"id":901,"status":"queued","name":"Presubmit","workflow_id":1,"head_branch":"feature/needs-linux","run_number":1,"created_at":"${AGE_30M}","html_url":"https://github.com/acme/repoX/actions/runs/901"}
]}
JSON
    exit 0 ;;
  *"actions/runs/900/jobs"*)
    printf '{"jobs":[{"status":"queued","labels":["self-hosted","self-hosted-mikey","self-hosted-macos"]}]}\n'
    exit 0 ;;
  *"actions/runs/901/jobs"*)
    printf '{"jobs":[{"status":"queued","labels":["self-hosted","self-hosted-mikey","ez-runner-c"]}]}\n'
    exit 0 ;;
  *"cancel"*|*"force-cancel"*)
    echo "CANCELED" >>"\$GH_LOG"
    exit 0 ;;
esac
exit 0
SH
chmod +x "$W/gh"

GH_LOG="$W/gh.log"; : > "$GH_LOG"; export GH_LOG

run_script() { # [extra env...]
  env -u BASH_ENV PATH="$W:/usr/bin:/bin:/usr/sbin:/sbin" \
    QUEUE_REPOS="acme/repoX" ORG="acme" \
    DRY_RUN=1 CANCEL_VERIFY_WAIT_S=0 STALE_HOURS=8 \
    "$@" bash "$ROOT/scripts/cleanup-stuck-runs.sh" 2>&1
}

OUT="$(run_script)"

# ── 1. The dead-label run is reported ────────────────────────────────────────
grep -q 'UNSCHEDULABLE 900' <<<"$OUT" \
  || { sed -n '1,40p' <<<"$OUT" >&2; fail "a run needing a label no ONLINE runner carries must be reported"; }
grep -q 'self-hosted-macos' <<<"$OUT" || fail "the missing label must be named"
pass "queued run requiring an unadvertised label is reported UNSCHEDULABLE"

# ── 2. A satisfiable run is NOT reported ────────────────────────────────────
if grep -q 'UNSCHEDULABLE 901' <<<"$OUT"; then
  sed -n '1,40p' <<<"$OUT" >&2
  fail "a run whose labels are all advertised must not be reported"
fi
pass "satisfiable run is not reported"

# ── 3. An OFFLINE runner's label does not count ─────────────────────────────
# linux-offline advertises self-hosted-macos but status=offline; it must not
# make the label look available.
grep -q 'no ONLINE org runner advertises' <<<"$OUT" \
  || fail "only ONLINE runners may satisfy a label requirement"
pass "offline runner labels do not satisfy a requirement"

# ── 4. Report-only: nothing was cancelled ───────────────────────────────────
if grep -qx 'CANCELED' "$GH_LOG"; then
  fail "the unschedulable lever must never cancel a run"
fi
pass "unschedulable lever is report-only (no cancel issued)"

# ── 5. Unavailable label pool degrades honestly ─────────────────────────────
: > "$GH_LOG"
OUT_FAIL="$(run_script LABEL_POOL=fail)"
grep -q 'label pool unavailable this tick' <<<"$OUT_FAIL" \
  || { sed -n '1,40p' <<<"$OUT_FAIL" >&2; fail "a rate-limited runner list must be reported as unasserted"; }
if grep -q 'UNSCHEDULABLE' <<<"$OUT_FAIL"; then
  fail "a rate-limited runner list must not produce an unschedulable verdict"
fi
pass "rate-limited label pool degrades to 'not asserted', not a false verdict"

# ── 6. A failed job lookup must NOT read as a definitive zero ───────────────
# P0 from review: job_labels() returned None for both "failed" and "no queued
# jobs", so an HTTP 403 produced "unschedulable: 0 ... none failed" -- the exact
# silent-clean diagnostic this lever exists to remove.
export GH_LOG="$W/failops-gh.log"; : > "$GH_LOG"
FHOME="$W/failops"; mkdir -p "$FHOME/bin"
cat > "$FHOME/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  *"orgs/acme/actions/runners"*)
    printf '{"total_count":1,"runners":[{"id":1,"name":"l1","status":"online","labels":[{"name":"self-hosted"},{"name":"ez-runner-c"}]}]}\n'
    exit 0 ;;
  *"actions/runs?status=queued"*)
    printf '{"workflow_runs":[{"id":950,"status":"queued","name":"P","workflow_id":1,"head_branch":"b","run_number":1,"created_at":"%s","html_url":"https://x/950"}]}\n' "${AGE_30M:?}"
    exit 0 ;;
  *"/jobs"*)
    echo "gh: API rate limit exceeded (HTTP 403)" >&2
    exit 1 ;;
esac
exit 0
SH
chmod +x "$FHOME/bin/gh"
FAILLOG="$W/fail.log"
set +e
env -u BASH_ENV PATH="$FHOME/bin:/usr/bin:/bin:/usr/sbin:/sbin" QUEUE_REPOS="acme/repoX" ORG="acme" \
  DRY_RUN=1 CANCEL_VERIFY_WAIT_S=0 STALE_HOURS=8 \
  bash "$ROOT/scripts/cleanup-stuck-runs.sh" >"$W/failout" 2>&1
set -e
grep -q 'UNSCHEDULABLE-UNKNOWN 950' "$W/failout" \
  || { sed -n '1,40p' "$W/failout" >&2; fail "a failed job lookup must be reported as UNKNOWN, not skipped"; }
grep -q 'INCOMPLETE' "$W/failout" \
  || { sed -n '1,40p' "$W/failout" >&2; fail "the summary must flag the scan as INCOMPLETE when lookups failed"; }
if grep -qE 'unschedulable: 0 queued run\(s\) require a label no online runner advertises; 0 unverified' "$W/failout"; then
  fail "a failed lookup must never render as a clean zero-unverified result"
fi
pass "failed job lookup is reported UNKNOWN and marks the scan INCOMPLETE"

# ── 7. Label matching is case-insensitive (GitHub routes that way) ──────────
export GH_LOG="$W/case-gh.log"; : > "$GH_LOG"
CHOME="$W/case"; mkdir -p "$CHOME/bin"
cat > "$CHOME/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"orgs/acme/actions/runners"*)
    printf '{"total_count":1,"runners":[{"id":1,"name":"l1","status":"online","labels":[{"name":"SELF-HOSTED"},{"name":"EZ-RUNNER-C"}]}]}\n'
    exit 0 ;;
  *"actions/runs?status=queued"*)
    printf '{"workflow_runs":[{"id":960,"status":"queued","name":"P","workflow_id":1,"head_branch":"b","run_number":1,"created_at":"%s","html_url":"https://x/960"}]}\n' "${AGE_30M:?}"
    exit 0 ;;
  *"/jobs"*)
    printf '{"jobs":[{"status":"queued","labels":["self-hosted","ez-runner-c"]}]}\n'
    exit 0 ;;
esac
exit 0
SH
chmod +x "$CHOME/bin/gh"
set +e
env -u BASH_ENV PATH="$CHOME/bin:/usr/bin:/bin:/usr/sbin:/sbin" QUEUE_REPOS="acme/repoX" ORG="acme" \
  DRY_RUN=1 CANCEL_VERIFY_WAIT_S=0 STALE_HOURS=8 bash "$ROOT/scripts/cleanup-stuck-runs.sh" >"$W/caseout" 2>&1
set -e
if grep -q 'UNSCHEDULABLE 960' "$W/caseout"; then
  sed -n '1,40p' "$W/caseout" >&2
  fail "label matching must be case-insensitive; a differently-cased runner satisfies the requirement"
fi
pass "label matching is case-insensitive"

# ── 8. Runner census follows pagination ────────────────────────────────────
export GH_LOG="$W/page-gh.log"; : > "$GH_LOG"
PHOME="$W/page"; mkdir -p "$PHOME/bin"
cat > "$PHOME/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  # Match the FULL query suffix: a bare *page=1* pattern also matches page=2
  # because the leading * is greedy, which silently served page 1 twice.
  *"orgs/acme/actions/runners?per_page=100&page=2"*)
    printf '{"total_count":101,"runners":[{"id":999,"name":"needs-macos","status":"online","labels":[{"name":"self-hosted"},{"name":"self-hosted-macos"}]}]}\n'
    exit 0 ;;
  *"orgs/acme/actions/runners?per_page=100&page=1"*)
    awk 'BEGIN{
      printf "{\"total_count\":101,\"runners\":["
      for(i=0;i<100;i++){ if(i>0) printf ","; printf "{\"id\":%d,\"name\":\"r%d\",\"status\":\"online\",\"labels\":[{\"name\":\"self-hosted\"}]}", i, i }
      printf "]}\n"
    }'
    exit 0 ;;
  *"actions/runs?status=queued"*)
    printf '{"workflow_runs":[{"id":970,"status":"queued","name":"P","workflow_id":1,"head_branch":"b","run_number":1,"created_at":"%s","html_url":"https://x/970"}]}\n' "${AGE_30M:?}"
    exit 0 ;;
  *"/jobs"*)
    printf '{"jobs":[{"status":"queued","labels":["self-hosted","self-hosted-macos"]}]}\n'
    exit 0 ;;
esac
exit 0
SH
chmod +x "$PHOME/bin/gh"
set +e
env -u BASH_ENV PATH="$PHOME/bin:/usr/bin:/bin:/usr/sbin:/sbin" QUEUE_REPOS="acme/repoX" ORG="acme" \
  DRY_RUN=1 CANCEL_VERIFY_WAIT_S=0 STALE_HOURS=8 bash "$ROOT/scripts/cleanup-stuck-runs.sh" >"$W/pageout" 2>&1
set -e
if grep -q 'UNSCHEDULABLE 970' "$W/pageout"; then
  sed -n '1,40p' "$W/pageout" >&2
  fail "runner census must follow pagination; a matching runner on page 2 makes the job schedulable"
fi
pass "runner census follows pagination (no false UNSCHEDULABLE)"

# ── 9. A partial runner census must not yield definitive verdicts ──────────
# P0 from review: a later-page failure returned the pages collected so far, so
# page 1 populated + page 2 HTTP 403 still produced a definitive UNSCHEDULABLE
# plus "0 unverified".
XHOME="$W/part"; mkdir -p "$XHOME/bin"
export GH_LOG="$W/part-gh.log"; : > "$GH_LOG"
cat > "$XHOME/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"actions/runners?per_page=100&page=2"*)
    echo "gh: API rate limit exceeded (HTTP 403)" >&2
    exit 1 ;;
  *"actions/runners?per_page=100&page=1"*)
    awk 'BEGIN{
      printf "{\"total_count\":150,\"runners\":["
      for(i=0;i<100;i++){ if(i>0) printf ","; printf "{\"id\":%d,\"name\":\"r%d\",\"status\":\"online\",\"labels\":[{\"name\":\"self-hosted\"}]}", i, i }
      printf "]}\n"
    }'
    exit 0 ;;
  *"actions/runs?status=queued"*)
    printf '{"workflow_runs":[{"id":980,"status":"queued","name":"P","workflow_id":1,"head_branch":"b","run_number":1,"created_at":"%s","html_url":"https://x/980"}]}\n' "${AGE_30M:?}"
    exit 0 ;;
  *"/jobs"*)
    printf '{"jobs":[{"status":"queued","labels":["self-hosted","self-hosted-macos"]}]}\n'
    exit 0 ;;
esac
exit 0
SH
chmod +x "$XHOME/bin/gh"
set +e
env -u BASH_ENV PATH="$XHOME/bin:/usr/bin:/bin:/usr/sbin:/sbin" QUEUE_REPOS="acme/repoX" ORG="acme" \
  DRY_RUN=1 CANCEL_VERIFY_WAIT_S=0 STALE_HOURS=8 bash "$ROOT/scripts/cleanup-stuck-runs.sh" >"$W/partout" 2>&1
set -e
if grep -q 'UNSCHEDULABLE 980' "$W/partout"; then
  sed -n '1,40p' "$W/partout" >&2
  fail "a partial runner census must not yield a definitive UNSCHEDULABLE verdict"
fi
grep -q 'label pool unavailable this tick' "$W/partout" \
  || { sed -n '1,40p' "$W/partout" >&2; fail "a partial census must be reported as UNKNOWN"; }
pass "a partial runner census is reported UNKNOWN, never a verdict"

echo "ALL PASS: unschedulable queued runs are detected and reported, never cancelled"
