#!/usr/bin/env bash
# tests/trim_queued_runs_ghost_test.sh — ghost-run classification for trim-queued-runs.sh
#
# A "ghost" run is a server-held queued run with ZERO jobs that refuses every
# transition (cancel => HTTP 409 "Cannot cancel a workflow run that has not been
# queued yet"; delete => 403; rerun => 403). See cli/cli#15053. Such runs cannot
# be cleared by any API, so they must be a COUNTED, non-fatal class -- never a
# hard failure that pins the agent red forever -- unless the suspension is
# undeclared (EZGHA_SUSPENSION_RECORD unset) or the set exceeds its bounds.
#
# Usage: bash tests/trim_queued_runs_ghost_test.sh
set -euo pipefail
unset BASH_ENV || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

# Fixed 2 hours ago, format-agnostic (GNU date on CI, BSD date on macOS).
CREATED_AT="$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# ---------------------------------------------------------------------------
# Stub gh/git. Behaviour is driven by env vars read at call time:
#   CANCEL_MODE  ghost | non409 | inc409 | unparse | badcreds | ok
#   JOBS_BODY    output of `/jobs --jq .total_count` (0, 1, or empty)
#   TWO_RUNS     1 => list a second run 9002 that fails with bad credentials
# ---------------------------------------------------------------------------
cat > "$STUB_BIN/gh" <<SH
#!/usr/bin/env bash
set -uo pipefail
case "\$*" in
  *"/actions/runs?status=queued"*)
    if [ "\${TWO_RUNS:-0}" = "1" ]; then
      printf '%s\n' '{"workflow_runs":[
        {"id":9001,"status":"queued","name":"P","workflow_id":7,"head_branch":"feature/x","head_sha":"aaa","created_at":"$CREATED_AT","path":".github/workflows/p.yml"},
        {"id":9002,"status":"queued","name":"Q","workflow_id":8,"head_branch":"feature/y","head_sha":"ccc","created_at":"$CREATED_AT","path":".github/workflows/q.yml"}]}'
    else
      printf '%s\n' '{"workflow_runs":[{"id":9001,"status":"queued","name":"P","workflow_id":7,"head_branch":"feature/x","head_sha":"aaa","created_at":"$CREATED_AT","path":".github/workflows/p.yml"}]}'
    fi
    exit 0 ;;
  *"/jobs"*)
    # JOBS_EMPTY=1 simulates an unparseable/empty read (must fail closed).
    if [ "\${JOBS_EMPTY:-0}" = "1" ]; then exit 0; fi
    printf '%s' "\${JOBS_BODY:-0}"; exit 0 ;;
  *"pr list"*)
    printf '[]\n'; exit 0 ;;
  *"--jq .status"*|*".status"*)
    printf 'queued\n'; exit 0 ;;
  *"runs/9002/cancel"*)
    printf 'gh: Bad credentials (HTTP 401)\n' >&2; exit 1 ;;
  *"/cancel"*)
    case "\${CANCEL_MODE:-ghost}" in
      ghost)    printf 'gh: Cannot cancel a workflow run that has not been queued yet. (HTTP 409)\n' >&2; exit 1 ;;
      non409)   printf 'gh: Cannot cancel a workflow run that has not been queued yet. (HTTP 403)\n' >&2; exit 1 ;;
      inc409)   printf 'gh: Cannot cancel a workflow run that has not been queued yet. request_id=409123 (HTTP 503)\n' >&2; exit 1 ;;
      unparse)  printf 'gh: Cannot cancel a workflow run that has not been queued yet.\n' >&2; exit 1 ;;
      badcreds) printf 'gh: Bad credentials (HTTP 401)\n' >&2; exit 1 ;;
      ok)       exit 0 ;;
    esac
    exit 0 ;;
  *) printf '{}'; exit 0 ;;
esac
SH
chmod +x "$STUB_BIN/gh"

cat > "$STUB_BIN/git" <<'SH'
#!/usr/bin/env bash
case "$*" in *ls-remote*) printf 'bbb\trefs/heads/feature/x\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$STUB_BIN/git"

run_case() {
  set +e
  OUT="$(env -u BASH_ENV PATH="$STUB_BIN:$PATH" QUEUE_REPOS="acme/one" DRY_RUN=0 \
        ./scripts/trim-queued-runs.sh --apply 2>&1)"
  RC=$?
  set -e
}
assert_rc()  { [ "$RC" -eq "$1" ] && pass "$2" || fail "$2 (rc=$RC, want $1)"; }
assert_has() { grep -qF -- "$1" <<<"$OUT" && pass "$2" || fail "$2 (missing: $1)"; }
refute_has() { ! grep -qF -- "$1" <<<"$OUT" && pass "$2" || fail "$2 (unexpected: $1)"; }

# ---- case 0: record UNSET => fail closed -----------------------------------
unset EZGHA_SUSPENSION_RECORD || true
export CANCEL_MODE=ghost JOBS_BODY=0; unset TWO_RUNS
run_case
assert_rc 1 "case0 record unset => exit 1 (fail closed)"
assert_has "ghost 9001" "case0 ghost still recognised"
assert_has "suspension record: UNSET" "case0 reports UNSET"
assert_has "FAIL ghosts are unacknowledged" "case0 explains the failure"

# ---- case 1: record SET, ghost only => exit 0 ------------------------------
export EZGHA_SUSPENSION_RECORD=test-bead
run_case
assert_rc 0 "case1 acknowledged ghost => exit 0"
assert_has "ghost 9001" "case1 names the ghost"
assert_has "suspension record: test-bead" "case1 echoes the record"
refute_has "FAIL cancel 9001" "case1 is not a cancel failure"

# ---- case 2: ghost + genuine failure => exit 1 ----------------------------
export TWO_RUNS=1
run_case
assert_rc 1 "case2 ghost + real failure => exit 1"
assert_has "ghost 9001" "case2 ghost counted"
assert_has "FAIL cancel 9002" "case2 real failure counted"
unset TWO_RUNS

# ---- case 3: 409 text but jobs exist => failure, not ghost ----------------
export JOBS_BODY=1 CANCEL_MODE=ghost
run_case
assert_rc 1 "case3 409-with-jobs => exit 1"
assert_has "WARN 409-with-jobs" "case3 flags the masking case"
refute_has "ghost 9001" "case3 is not a ghost"

# ---- case 4: unknown /jobs => fail closed ---------------------------------
export JOBS_EMPTY=1 JOBS_BODY=0 CANCEL_MODE=ghost
run_case
assert_rc 1 "case4 unknown jobs => exit 1"
refute_has "ghost 9001" "case4 unknown is not a ghost"
unset JOBS_EMPTY

# ---- case 4b: 403 with identical wording ----------------------------------
export JOBS_BODY=0 CANCEL_MODE=non409
run_case
assert_rc 1 "case4b 403 wording => exit 1"
refute_has "ghost 9001" "case4b 403 is not a ghost"

# ---- case 4c: incidental "409" inside a real 503 --------------------------
export CANCEL_MODE=inc409
run_case
assert_rc 1 "case4c 503 with incidental 409 => exit 1"
refute_has "ghost 9001" "case4c is not a ghost"

# ---- case 4d: unparseable status => fail closed ---------------------------
export CANCEL_MODE=unparse
run_case
assert_rc 1 "case4d unparseable status => exit 1"
refute_has "ghost 9001" "case4d is not a ghost"

# ---- case 5: escalation on the count bound --------------------------------
export CANCEL_MODE=ghost GHOST_ESCALATE_COUNT=0
run_case
assert_rc 1 "case5 escalation bound => exit 1"
assert_has "ESCALATION" "case5 prints the escalation notice"

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
