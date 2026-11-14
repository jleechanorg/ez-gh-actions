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

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
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
case "$*" in *ls-remote*) sleep 20; printf 'bbb\trefs/heads/feature/x\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$STUB_BIN/git"

RUN=( env -u BASH_ENV PATH="$STUB_BIN:$PATH" QUEUE_REPOS="acme/one"
      bash "$REPO_ROOT/scripts/trim-queued-runs.sh" --dry-run )
( "${RUN[@]}" </dev/null >"$LOG" 2>&1 ) &
pid=$!

seen=0; alive=0
for _ in $(seq 1 20); do
  if grep -q "\[acme/one\] scan:" "$LOG" 2>/dev/null; then
    seen=1
    kill -0 "$pid" 2>/dev/null && alive=1
    break
  fi
  sleep 1
done

# We terminate the worker deliberately, so `wait` returns non-zero; an unguarded
# `wait` under `set -e` would abort BEFORE the assertions below.
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null || true

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
