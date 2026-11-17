#!/usr/bin/env bash
# tests/trim_queued_runs_progress_test.sh — progress must be visible DURING a pass
#
# Guards the heredoc-writer deadlock (bead jleechan-queue-trimmer-heredoc-deadlock):
# a wedged pass produced ZERO output for 30+ minutes, indistinguishable from slow
# work. Two assertions:
#   A) structural — no heredoc writer may remain in either script (comments stripped,
#      because trim:107 legitimately describes the old shape in a comment).
#   B) behavioural — `scan:` is observed WHILE the worker is still running, so output
#      flushed only at exit cannot pass.
#
# Usage: bash tests/trim_queued_runs_progress_test.sh
set -euo pipefail
# REQUIRED: BASH_ENV points at ~/.bashrc on this host; the child bash would source
# it and prepend ~/.local/bin ahead of the stub dir, running the REAL gh.
unset BASH_ENV || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCRATCH="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh ezgha-tests)"
WORK="$(mktemp -d "$SCRATCH/trim-queued-progress.XXXXXX")"
export WORK
pid=""
cleanup() {
  if [ -n "$pid" ]; then teardown_tree "$pid" || true; fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT
LOG="$WORK/progress.log"
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

# ---- A) structural: no heredoc writer remains ------------------------------
for f in scripts/trim-queued-runs.sh scripts/cleanup-stuck-runs.sh; do
  if sed 's/#.*$//' "$f" | grep -qE "<<'?PY'?"; then
    fail "structural: live heredoc writer still present in $f"
  else
    pass "structural: no heredoc writer in $f"
  fi
done

# ---- B) behavioural: progress visible while running ------------------------
cat > "$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
case "$*" in
  *"/actions/runs?status=queued"*)
    printf '%s\n' '{"workflow_runs":[{"id":9001,"status":"queued","name":"P","workflow_id":7,"head_branch":"feature/x","head_sha":"aaa","created_at":"2026-01-01T00:00:00Z","path":".github/workflows/p.yml"}]}'
    exit 0 ;;
  *"pr list"*) printf '[]\n'; exit 0 ;;
  *"--jq .status"*) printf 'queued\n'; exit 0 ;;
  *) printf '{}'; exit 0 ;;
esac
SH
chmod +x "$STUB_BIN/gh"

# git blocks ~20s in ls-remote so the pass stays running while we poll.
cat > "$STUB_BIN/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *ls-remote*)
    sleep 20 &
    sleep_pid=$!
    printf '%s\n' "$sleep_pid" > "$WORK/progress-sleep-pid"
    wait "$sleep_pid"
    printf 'bbb\trefs/heads/feature/x\n'
    exit 0 ;;
esac
exit 0
SH
chmod +x "$STUB_BIN/git"

RUN=( env -u BASH_ENV PATH="$STUB_BIN:$PATH" QUEUE_REPOS="acme/one"
      bash "$REPO_ROOT/scripts/trim-queued-runs.sh" --dry-run )
# Launch WITHOUT relying on process-group semantics.
#
# macOS has no `setsid`, and a backgrounded subshell INHERITS the parent's
# PGID (verified: child pgid == parent pgid), so `kill -- -$pid` would signal
# this test's own shell rather than the pipeline. Instead: start the pipeline,
# then walk the descendant tree explicitly and terminate it leaf-first. That is
# portable and does not depend on group isolation at all (review P0).
"${RUN[@]}" </dev/null >"$LOG" 2>&1 &
pid=$!

# Single shared implementation (see tests/lib/descendants.sh for the bugs it
# encodes: `! cmd` status capture, subshell flag mutation, stale snapshots).
# shellcheck source=tests/lib/descendants.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/descendants.sh"

seen=0; alive=0
for _ in $(seq 1 20); do
  if grep -q "\[acme/one\] scan:" "$LOG" 2>/dev/null; then
    seen=1
    kill -0 "$pid" 2>/dev/null && alive=1
    break
  fi
  sleep 1
done

# Snapshot exact fixture descendants after the stub has started its blocking
# sleep. The later checks include this named process and never scan host PIDs.
for _ in $(seq 1 50); do
  [ -s "$WORK/progress-sleep-pid" ] && break
  sleep 0.1
done
[ -s "$WORK/progress-sleep-pid" ] \
  || fail "fixture: blocking sleep 20 did not start after scan output"
descendants_checked "$pid"
printf '%s\n' "$DESCENDANTS_OUT" > "$WORK/descendant-pids"
progress_sleep_pid="$(cat "$WORK/progress-sleep-pid" 2>/dev/null || true)"
if printf '%s\n' "$DESCENDANTS_OUT" | grep -Fxq "$progress_sleep_pid"; then
  pass "fixture: blocking sleep 20 is in the captured worker tree"
else
  fail "fixture: blocking sleep 20 pid=$progress_sleep_pid was not captured under worker pid=$pid (descendants=$DESCENDANTS_OUT)"
fi

# We terminate the worker deliberately, so `wait` returns non-zero; an unguarded
# `wait` under `set -e` would abort BEFORE the assertions below.
teardown_rc=0
teardown_tree "$pid" || teardown_rc=$?

# Discovery MUST have worked, otherwise the survivor check below is vacuous.
[ "$teardown_rc" -ne 5 ] \
  && pass "cleanup: process discovery available (survivor check is meaningful)" \
  || fail "cleanup: process discovery failed/unavailable — survivor check would pass vacuously"

# Final accounting AFTER the leader is gone: nothing can respawn now.
descendants_checked "$pid"
survivors=0
for k in $(cat "$WORK/descendant-pids"); do pid_is_running "$k" && survivors=$((survivors+1)); done
[ "$survivors" -eq 0 ] && pass "cleanup: no descendants survived the pass" \
                       || fail "cleanup: $survivors descendant(s) still alive after teardown"
pid_is_running "$progress_sleep_pid" \
  && fail "cleanup: fixture sleep 20 survived teardown (pid=$progress_sleep_pid)" \
  || pass "cleanup: fixture sleep 20 stopped"

[ "$seen" = 1 ]  && pass "behavioural: scan: emitted during the pass" \
                 || fail "behavioural: no progress output during the pass"
[ "$alive" = 1 ] && pass "behavioural: worker was still alive when scan: appeared" \
                 || fail "behavioural: scan: only appeared after exit (exit-flush accepted)"

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
