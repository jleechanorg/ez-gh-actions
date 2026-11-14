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
# Strip comments and docstrings, then look for ANY quoting style of a mutating
# verb. An earlier version matched only double-quoted literals, so a
# single-quoted or PATCH/PUT call would have slipped through (review P2).
python3 - "$SCRIPT" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# remove triple-quoted blocks, then comment lines, then inline comments
src = re.sub(r'""".*?"""', "", src, flags=re.S)
lines = []
for ln in src.splitlines():
    s = ln.split("#", 1)[0]
    if s.strip():
        lines.append(s)
code = "\n".join(lines)
# mutating HTTP verbs in any quote style, plus the destructive endpoints
pat = re.compile(
    r"""(?:['"])\s*(?:POST|PUT|PATCH|DELETE)\s*(?:['"])
      | /cancel\b | /force-cancel\b
    """,
    re.X,
)
hits = [m.group(0).strip() for m in pat.finditer(code)]
if hits:
    print(f"FAIL 1 destructive call(s) in executable code: {sorted(set(hits))}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
[ "$?" -eq 0 ] && pass "1 no destructive method/endpoint in executable code (any quote style)" \
              || fail "1 destructive method/endpoint found in executable code"

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

check("confirmed zero-job ghost is classified only", "queued", 0, "ghost_zero_jobs")
check("run that gained jobs is classified, never acted on", "queued", 5, "now_has_jobs_real_work")
check("unreadable jobs fails closed", "queued", None, "unverified_jobs_unknown")
check("unreadable status fails closed", None, 0, "unverified_status_unknown")
check("run that left the queue is not touched", "in_progress", 0, "unverified_left_queued")
sys.exit(1 if fails else 0)
PY
[ "$?" -eq 0 ] && pass "2/3 no mutation for any classification path" \
              || fail "2/3 a classification path still mutated"

# ---- 4. CLI level: main() reports mutates:false and never mutates ----------
# The dynamic cases above exercise reap_one directly; the review noted that
# leaves CLI parsing, main(), and the mutates flag untested (P2).
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"--paginate"*)
    printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":9001,"name":"P","path":".github/workflows/p.yml","head_branch":"b","created_at":"2020-01-01T00:00:00Z","status":"queued","run_attempt":1,"updated_at":"2020-01-01T00:00:00Z","head_sha":"a"}]}'
    exit 0 ;;
  *"/jobs"*)      printf '{"total_count":0}'; exit 0 ;;
  *"actions/runs/9001"*) printf '{"status":"queued"}'; exit 0 ;;
  *) printf '{}'; exit 0 ;;
esac
SH
chmod +x "$W/bin/gh"
set +e
CLIOUT="$(env -u BASH_ENV PATH="$W/bin:$PATH" python3 "$SCRIPT" --repo acme/one --apply --json 2>&1)"
CLIRC=$?
set -e
if [ "$CLIRC" -eq 0 ] || [ "$CLIRC" -eq 3 ]; then
  pass "4 CLI runs end to end (rc=$CLIRC)"
else
  fail "4 CLI exited $CLIRC unexpectedly"
fi
printf '%s' "$CLIOUT" > "$W/cli.json"
python3 - "$W/cli.json" <<'PYCLI' && pass "4b --apply reports mutates:false" || fail "4b --apply does not report mutates:false"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("mutates") is False, d.get("mutates")
assert d.get("apply") is True, d.get("apply")
PYCLI
set +e
HUMAN="$(env -u BASH_ENV PATH="$W/bin:$PATH" python3 "$SCRIPT" --repo acme/one 2>&1)"
set -e
grep -q "CLASSIFY ONLY" <<<"$HUMAN" && pass "4c human output says CLASSIFY ONLY" \
  || fail "4c human output does not say CLASSIFY ONLY"

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
