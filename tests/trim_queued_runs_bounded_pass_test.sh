#!/usr/bin/env bash
# tests/trim_queued_runs_bounded_pass_test.sh
#
# Regression coverage for bead jleechan-queue-trimmer-heredoc-deadlock.
#
# Measured failure (2026-11-07): the org.jleechanorg.ezgha-queue-trimmer launchd
# job sat wedged for 15h48m. `sample` showed 900/900 samples in
# heredoc_write() -> write(), `pgrep -P` showed the python3 heredoc reader gone,
# and `sed` still held the pipe's read end so bash blocked forever writing the
# heredoc. launchctl reported `state = running, last exit code = 0` throughout,
# so nothing surfaced the stall.
#
# Two properties are asserted here:
#   1. STRUCTURAL: the script hands python a real file, so there is no heredoc
#      writer and therefore no heredoc_write() to block in.
#   2. BEHAVIORAL: a repo whose pass wedges is bounded by REPO_TIMEOUT_S and
#      does not prevent later repos from being scanned.
#
# Everything is stubbed: no network, no gh, no real repos.
#
# Usage: bash tests/trim_queued_runs_bounded_pass_test.sh
set -euo pipefail
unset BASH_ENV || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO_ROOT/scripts/trim-queued-runs.sh"
WORK="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "$S" ]] || fail "script not found at $S"

# ── 1. Structural: no heredoc writer into a pipeline ─────────────────────────
# The deadlock required a heredoc whose write end went into a pipeline. Assert
# python is invoked against a file variable instead.
grep -q 'python3 -u "\$PY_BODY"' "$S" \
  || fail "python must be invoked against a file (\$PY_BODY), not a heredoc"
if grep -vE '^[[:space:]]*#' "$S" | grep -E 'python3[^|]*<<' >/dev/null 2>&1; then
  fail "a python heredoc form is still present; that is the shape that deadlocked"
fi
grep -q 'REPO_TIMEOUT_S' "$S" || fail "per-repo timeout knob is missing"
pass "structural: python runs from a file and a per-repo timeout exists"

# ── 2. Behavioral: a wedged repo is bounded and does not block later repos ───
STUB="$WORK/bin"
mkdir -p "$STUB"

# python3 stub: wedge forever for the repo named in WEDGE_REPO, succeed otherwise.
cat > "$STUB/python3" <<'SH'
#!/usr/bin/env bash
# The script always passes `-u <file>`; ignore both and act on the repo.
if [[ "${QUEUE_REPO:-}" == "${WEDGE_REPO:-__none__}" ]]; then
  # Emit one line FIRST (as the real body does), then hang without ever closing
  # stdout. This reproduces "reader stops draining while the writer waits".
  echo "scan: repo=${QUEUE_REPO} queued_total=0 wedging"
  exec sleep 600
fi
echo "scan: repo=${QUEUE_REPO:-?} queued_total=0"
echo "summary: candidates=0 cancelled=0 failed=0 skipped_non_queued=0 dry_run=True"
exit 0
SH

cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$STUB/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "$STUB/python3" "$STUB/gh" "$STUB/git"

LOG="$WORK/run.log"
START=$(date +%s)
set +e
PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" \
  QUEUE_REPOS="acme/wedges acme/healthy-after" \
  WEDGE_REPO="acme/wedges" \
  REPO_TIMEOUT_S=3 \
  DRY_RUN=1 \
  bash "$S" >"$LOG" 2>&1
RC=$?
set -e
ELAPSED=$(( $(date +%s) - START ))

# Bound: 3s timeout + up to 30s kill-after grace. Anything near the 600s sleep
# means the timeout did not engage.
[ "$ELAPSED" -lt 60 ] || fail "script took ${ELAPSED}s; the per-repo timeout did not bound the wedge"

grep -q 'TIMED OUT after 3s' "$LOG" \
  || { sed -n '1,40p' "$LOG" >&2; fail "a wedged repo must be reported as TIMED OUT, not silently awaited"; }
pass "behavioral: wedged repo is bounded (${ELAPSED}s) and reported as TIMED OUT"

# The second repo must still have been scanned despite the first one wedging.
grep -q 'acme/healthy-after' "$LOG" \
  || { sed -n '1,40p' "$LOG" >&2; fail "a wedged repo must not prevent later repos from being scanned"; }
pass "behavioral: later repos are still scanned after a wedged repo"

# The run must be non-zero so launchd/log aggregation sees it as a failure.
[ "$RC" -ne 0 ] || fail "a timed-out repo pass must exit non-zero (got $RC)"
grep -q 'failed: acme/wedges' "$LOG" \
  || { sed -n '1,40p' "$LOG" >&2; fail "summary must name the failed repo"; }
pass "exit status and summary name the timed-out repo"

echo "ALL PASS: trim-queued-runs per-repo pass is bounded and cannot deadlock on a heredoc"
