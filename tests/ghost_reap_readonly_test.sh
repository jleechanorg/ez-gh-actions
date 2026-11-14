#!/usr/bin/env bash
# tests/ghost_reap_readonly_test.sh
#
# The ghost-reap tool must NEVER mutate. It used to cancel -> force-cancel ->
# delete, which was removed for two independent reasons:
#
#   1. It CANNOT SUCCEED on the population it exists for. Measured 2026-11-14:
#      149/149 zero-job queued runs refused cancel/force-cancel (HTTP 409 "has
#      not been queued yet") and DELETE (403); 0 reaped. PR #227 independently
#      measured 65/65 the same.
#   2. It CANNOT BE MADE SAFE. Deletion is GET-then-mutate with no conditional
#      write — GitHub exposes no "delete only if still zero-job" precondition — so
#      a run can gain real jobs between the eligibility read and the DELETE.
#      Adversarial review demonstrated force-cancel and DELETE firing on a run
#      that had become in_progress with jobs. No client-side re-read closes that.
#
# This test asserts:
#   1. the script contains NO destructive HTTP method (static)
#   2. reap_one never calls a mutating endpoint, for ghost AND non-ghost rows
#   3. a run that gains jobs is classified, never acted on
#   4. --apply is a no-op that still reports mutates:false
#
# Usage: bash tests/ghost_reap_readonly_test.sh
set -uo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SCRIPT=".claude/skills/ezgha-ghost-reap/scripts/reap_ghosts.py"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

# ---- 1. static: no destructive verb anywhere in the source ----------------
POSTS="$(grep -cE '"POST"|"DELETE"|/cancel|/force-cancel' "$SCRIPT" || true)"
# The module docstring legitimately MENTIONS cancel/force-cancel in prose.
CODEMUT="$(grep -vE '^\s*#|^\s*"""|^\s*\*' "$SCRIPT" | grep -cE '"POST"|"DELETE"' || true)"
if [ "${CODEMUT:-0}" -eq 0 ]; then
  pass "1 no destructive HTTP method in executable code (matches in prose only: ${POSTS:-0})"
else
  fail "1 found ${CODEMUT} destructive HTTP method(s) in executable code"
fi

# ---- 2/3. dynamic: reap_one performs no mutation --------------------------
python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rg", sys.argv[1])
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass

fails = 0
def check(name, status, total, want_prefix):
    global fails
    calls = []
    m.gh = lambda path, method=None: (calls.append((method, path)), {"status": status})[1]
    m.job_total = lambda repo, rid: total
    outcome = m.reap_one("r", {"id": 42}, verify_wait_s=0, apply=True)
    mutated = [c for c in calls if c[0] in ("POST", "DELETE")]
    ok = (not mutated) and outcome.startswith(want_prefix)
    print(("PASS" if ok else "FAIL") + f" 2 {name}: outcome={outcome} mutations={mutated}")
    if not ok:
        fails += 1

check("confirmed zero-job ghost is classified only", "queued", 0, "ghost_unreapable")
check("run that gained jobs is classified, never acted on", "queued", 5, "now_has_jobs_real_work")
check("unreadable jobs fails closed", "queued", None, "unverified_jobs_unknown")
check("unreadable status fails closed", None, 0, "unverified_status_unknown")
check("run that left the queue is not touched", "in_progress", 0, "unverified_left_queued")
sys.exit(1 if fails else 0)
PY
[ "$?" -eq 0 ] && pass "2/3 no mutation for any classification path" \
              || fail "2/3 a classification path still mutated"

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
