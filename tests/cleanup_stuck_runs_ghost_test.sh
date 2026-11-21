#!/usr/bin/env bash
# tests/cleanup_stuck_runs_ghost_test.sh — ghost-run classification for cleanup-stuck-runs.sh
#
# A "ghost" is a server-held queued run with ZERO jobs that refuses every transition
# (cancel => HTTP 409 "Cannot cancel a workflow run that has not been queued yet";
# DELETE => generic 403; rerun => 403). See cli/cli#15053. It cannot be cleared by
# any API, so it must be counted and non-fatal -- unless the suspension is
# undeclared (EZGHA_SUSPENSION_RECORD unset) or the set exceeds its bounds.
#
# Usage: bash tests/cleanup_stuck_runs_ghost_test.sh
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

# ---------------------------------------------------------------------------
# Stub gh. All behaviour is read from the environment AT CALL TIME, so one stub
# serves every case:
#   CANCEL_MODE  ghost | non409 | inc409 | unparse | generic403 | ok
#   JOBS_BODY    0 | 1              (JOBS_EMPTY=1 -> emit nothing = unknown)
#   TWO_RUNS     1 => add a second, older run on the same branch/workflow
#   RUN_AGE_MINUTES  age of the listed run(s); default 14400 (10 days = zombie)
# ---------------------------------------------------------------------------
cat > "$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

AGE="${RUN_AGE_MINUTES:-14400}"
CREATED="$(AGE="$AGE" python3 -c 'import datetime,os
m=int(os.environ["AGE"])
print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

case "$*" in
  *"/actions/runs?status=queued"*)
    if [ "${TWO_RUNS:-0}" = "1" ]; then
      printf '%s\n' "{\"workflow_runs\":[
        {\"id\":9001,\"status\":\"queued\",\"name\":\"P\",\"workflow_id\":7,\"run_number\":1,\"head_branch\":\"feature/x\",\"head_sha\":\"aaa\",\"created_at\":\"$CREATED\",\"path\":\".github/workflows/p.yml\"},
        {\"id\":9002,\"status\":\"queued\",\"name\":\"P\",\"workflow_id\":7,\"run_number\":2,\"head_branch\":\"feature/x\",\"head_sha\":\"bbb\",\"created_at\":\"$CREATED\",\"path\":\".github/workflows/p.yml\"}]}"
    else
      printf '%s\n' "{\"workflow_runs\":[{\"id\":9001,\"status\":\"queued\",\"name\":\"P\",\"workflow_id\":7,\"run_number\":1,\"head_branch\":\"feature/x\",\"head_sha\":\"aaa\",\"created_at\":\"$CREATED\",\"path\":\".github/workflows/p.yml\"}]}"
    fi
    exit 0 ;;
  *"/jobs"*)
    if [ "${JOBS_EMPTY:-0}" = "1" ]; then exit 0; fi
    printf '%s' "${JOBS_BODY:-0}"; exit 0 ;;
  *"actions/runners"*)
    printf '{"runners":[]}'; exit 0 ;;
  *"run delete"*)
    printf 'gh: Could not delete the workflow run (HTTP 403)\n' >&2; exit 1 ;;
  *"/cancel"*|*"/force-cancel"*)
    case "${CANCEL_MODE:-ghost}" in
      ghost)      printf 'gh: Cannot cancel a workflow run that has not been queued yet. (HTTP 409)\n' >&2; exit 1 ;;
      non409)     printf 'gh: Cannot cancel a workflow run that has not been queued yet. (HTTP 403)\n' >&2; exit 1 ;;
      inc409)     printf 'gh: Cannot cancel a workflow run that has not been queued yet. request_id=409123 (HTTP 503)\n' >&2; exit 1 ;;
      unparse)    printf 'gh: Cannot cancel a workflow run that has not been queued yet.\n' >&2; exit 1 ;;
      generic403) printf 'gh: Could not delete the workflow run (HTTP 403)\n' >&2; exit 1 ;;
      ok)         exit 0 ;;
    esac
    exit 0 ;;
  *"--jq .status"*|*".status"*|*"runs/9001"*"jq"*)
    printf 'queued\n'; exit 0 ;;
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
  OUT="$(env -u BASH_ENV PATH="$STUB_BIN:$PATH" QUEUE_REPOS="acme/one" \
        ./scripts/cleanup-stuck-runs.sh "$@" 2>&1)"
  RC=$?
  set -e
}
assert_rc()  { [ "$RC" -eq "$1" ] && pass "$2" || fail "$2 (rc=$RC, want $1)"; }
assert_has() { grep -qF -- "$1" <<<"$OUT" && pass "$2" || fail "$2 (missing: $1)"; }
refute_has() { ! grep -qF -- "$1" <<<"$OUT" && pass "$2" || fail "$2 (unexpected: $1)"; }

# ---- 1: ghost zombie, record SET => exit 0 --------------------------------
export EZGHA_SUSPENSION_RECORD=test-bead CANCEL_MODE=ghost JOBS_BODY=0 GHOST_ESCALATE_COUNT=200
run_case --zombies --apply
assert_rc 0 "1 ghost zombie (record set) => exit 0"
assert_has "ghost zombie 9001" "1 classified as ghost zombie"
assert_has "'zombie_ghost': 1" "1 zombie_ghost stat incremented"
refute_has "FAIL zombie" "1 not counted as a failure"

# ---- 1b: ghost zombie, record UNSET => exit 1 (fail closed) ---------------
unset EZGHA_SUSPENSION_RECORD || true
run_case --zombies --apply
assert_rc 1 "1b record unset => exit 1 (fail closed)"
assert_has "ghost zombie 9001" "1b still classified as a ghost"
assert_has "suspension record: UNSET" "1b reports UNSET"
assert_has "FAIL ghosts are unacknowledged" "1b explains the failure"

# ---- 2: 409 text but jobs exist => zombie_failed --------------------------
export EZGHA_SUSPENSION_RECORD=test-bead JOBS_BODY=1
run_case --zombies --apply
assert_rc 1 "2 409-with-jobs => exit 1"
assert_has "'zombie_failed': 1" "2 counted as a real failure"
refute_has "ghost zombie" "2 not classified as a ghost"

# ---- 3: generic 403 only => zombie_failed --------------------------------
export CANCEL_MODE=generic403 JOBS_BODY=0
run_case --zombies --apply
assert_rc 1 "3 generic 403 => exit 1"
refute_has "ghost zombie" "3 is not a ghost"

# ---- 3b: incidental 409 inside a 503 => not a ghost ----------------------
export CANCEL_MODE=inc409
run_case --zombies --apply
assert_rc 1 "3b incidental 409 in 503 => exit 1"
refute_has "ghost zombie" "3b is not a ghost"

# ---- 4: superseded lever emits 409 => superseded_ghost -------------------
export CANCEL_MODE=ghost JOBS_BODY=0 TWO_RUNS=1
run_case --superseded --apply
assert_rc 0 "4 ghost superseded (record set) => exit 0"
assert_has "'superseded_ghost': 1" "4 superseded_ghost stat incremented"
unset TWO_RUNS

# ---- 5: tail lever emits 409 => tail_ghost -------------------------------
# The tail lever covers runs older than FRESH_TAIL_MIN (45m) and younger than
# STALE_HOURS (8h); a 10-day-old run is a zombie, never "tail".
export RUN_AGE_MINUTES=90
run_case --tail --apply
assert_rc 0 "5 ghost tail (record set) => exit 0"
assert_has "'tail_ghost': 1" "5 tail_ghost stat incremented"
unset RUN_AGE_MINUTES

# ---- 6: escalation on the count bound ------------------------------------
export CANCEL_MODE=ghost JOBS_BODY=0 GHOST_ESCALATE_COUNT=0
run_case --zombies --apply
assert_rc 1 "6 escalation bound => exit 1"
assert_has "ESCALATION" "6 prints the escalation notice"

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
