#!/usr/bin/env bash
# tests/trim_queued_runs_ghost_classification_test.sh
#
# The trimmer used to treat every failed cancel as a hard failure. Zero-job ghost
# runs return 409 "Cannot cancel a workflow run that has not been queued yet" from
# cancel AND force-cancel, and 403 from DELETE, so ~81 ghosts per pass made the job
# exit 1 forever while moving nothing (measured 2026-11-16: candidates=81
# cancelled=0 failed=81, exit=1, five days running).
#
# Contract asserted here:
#   1. a zero-job queued run is classified `ghost`, is NOT cancelled, and does NOT
#      make the pass fail;
#   2. a 409 "has not been queued yet" on cancel is ALSO classified ghost (the
#      fallback when the job-count probe could not run);
#   3. a real failure still fails the pass (exit 1) -- ghosts must not mask it;
#   4. ghosts are classified in dry-run too, so the queue number is readable.
#
# Usage: bash tests/trim_queued_runs_ghost_classification_test.sh
set -uo pipefail
unset BASH_ENV || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"
GH_LOG="${WORK}/gh.log"
: > "${GH_LOG}"

# Stub git: report a stable branch head so runs do not look superseded.
cat > "${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"ls-remote"* ]]; then
  printf 'aabbccdd\trefs/heads/feature/x\n'
  exit 0
fi
if [[ "$*" == *"log"* ]]; then
  printf '2026-11-11T00:00:00+00:00\n'
  exit 0
fi
exit 0
EOF
chmod +x "${STUB_BIN}/git"

# Stub gh. Behaviour is driven by GH_MODE:
#   ghost     -> jobs total_count 0
#   notqueued -> cancel returns the 409 ghost signature
#   realfail  -> cancel returns a genuine 403
cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"

mode="${GH_MODE:-ghost}"

case "$*" in
  *"/jobs"*)
    case "$mode" in
      ghost) printf '0\n' ;;
      *)     printf '5\n' ;;  # real work: must reach the cancel path
    esac
    exit 0
    ;;
esac

if [[ "$*" == *"status=queued"* ]]; then
  cat <<'JSON'
{"workflow_runs":[{"id":900001,"name":"Visual Findings Gate","head_branch":"feature/x",
"html_url":"https://github.com/org/repo/actions/runs/900001","path":".github/workflows/vfg.yml",
"head_sha":"11112222","created_at":"2026-11-11T00:00:00Z","pull_requests":[]}]}
JSON
  exit 0
fi

if [[ "$*" == *"actions/runs/900001"* ]] && [[ "$*" != *"cancel"* ]] && [[ "$*" != *"/jobs"* ]]; then
  printf 'queued\n'
  exit 0
fi

if [[ "$*" == *"cancel"* ]]; then
  case "$mode" in
    notqueued)
      printf '{"message":"Cannot cancel a workflow run that has not been queued yet."}\n' >&2
      exit 1
      ;;
    realfail)
      printf '{"message":"Resource not accessible by integration"}\n' >&2
      exit 1
      ;;
    *)
      exit 0
      ;;
  esac
fi

if [[ "$*" == *"pulls"* ]]; then
  printf '[]\n'
  exit 0
fi
exit 0
EOF
chmod +x "${STUB_BIN}/gh"

export PATH="${STUB_BIN}:${PATH}"
export GH_LOG
export QUEUE_REPOS="org/repo"
export CANCEL_VERIFY_WAIT_S=0
export EZGHA_SKIP_LOCK=1

pass=0
fail=0
check() {
  local label="$1" expect="$2" output="$3"
  if grep -qE "$expect" <<< "$output"; then
    printf '  [PASS] %s\n' "$label"; pass=$((pass+1))
  else
    printf '  [FAIL] %s\n        expected /%s/\n        got: %s\n' \
      "$label" "$expect" "$(tr '\n' '|' <<< "$output" | cut -c1-300)"
    fail=$((fail+1))
  fi
}

echo "=== 1. zero-job run is classified ghost, not a failure (apply mode) ==="
: > "${GH_LOG}"
out="$(GH_MODE=ghost bash scripts/trim-queued-runs.sh --apply 2>&1)"
check "reports ghost count" "ghost=1" "$out"
fail_lines="$(grep -c 'FAIL' <<< "$out" || true)"
if [[ "${fail_lines:-0}" -eq 0 ]]; then
  printf '  [PASS] no FAIL lines for a ghost\n'; pass=$((pass+1))
else
  printf '  [FAIL] ghost produced %s FAIL line(s)\n' "$fail_lines"; fail=$((fail+1))
fi
cancel_calls="$(grep -c -- '-X POST.*cancel' "${GH_LOG}" || true)"
if [[ "${cancel_calls:-0}" -eq 0 ]]; then
  printf '  [PASS] no cancel attempted for a ghost\n'; pass=$((pass+1))
else
  printf '  [FAIL] ghost must not be cancelled (saw %s cancel call(s))\n' "$cancel_calls"; fail=$((fail+1))
fi
if GH_MODE=ghost bash scripts/trim-queued-runs.sh --apply >/dev/null 2>&1; then
  printf '  [PASS] ghost-only pass exits 0\n'; pass=$((pass+1))
else
  printf '  [FAIL] ghost-only pass must exit 0\n'; fail=$((fail+1))
fi

echo "=== 2. 409 not-queued on cancel is classified ghost ==="
out="$(GH_MODE=notqueued bash scripts/trim-queued-runs.sh --apply 2>&1)"
check "reports 409 ghost" "ghost=1" "$out"
check "no hard failure" "failed=0" "$out"

echo "=== 3. a real cancel failure still fails the pass ==="
if GH_MODE=realfail bash scripts/trim-queued-runs.sh --apply >"${WORK}/real.out" 2>&1; then
  printf '  [FAIL] real failure must exit non-zero\n'; fail=$((fail+1))
else
  printf '  [PASS] real failure exits non-zero\n'; pass=$((pass+1))
fi
check "counts a real failure" "failed=1" "$(cat "${WORK}/real.out")"

echo "=== 4. ghosts are classified in dry-run too ==="
out="$(GH_MODE=ghost bash scripts/trim-queued-runs.sh 2>&1)"
check "dry-run reports ghost" "ghost=1" "$out"
check "dry-run marked" "dry_run=True" "$out"

echo
echo "passed=${pass} failed=${fail}"
[[ "$fail" -eq 0 ]]
