#!/usr/bin/env bash
# Regression test (codex adversarial review 2026-07-10, finding 3, P1): the
# queued-run list is built ONCE per repo scan, but actual cancellation
# happens later -- the multi-repo QUEUE_REPOS loop plus per-cancel
# CANCEL_VERIFY_WAIT_S sleeps can stretch this to minutes. A run picked up
# by a runner in that window is no longer "queued" by the time the script
# acts on it; force-cancelling it anyway kills an in-progress job, not a
# stuck one. cleanup-stuck-runs.sh must recheck run_status(rid) immediately
# before every cancel decision (tail, superseded, and the zombie/delete_run
# path) and SKIP -- never cancel -- a run that has left "queued".
#
# This test exercises the tail path: a run queued past FRESH_TAIL_MIN, but
# by the time the script gets to it, the run has transitioned to
# "in_progress" (a runner picked it up in the race window). Asserts:
#   (a) the plain cancel endpoint (.../cancel) is NEVER called for this run.
#   (b) a "skipped tail <rid>: no longer queued (now in_progress)" line is
#       printed.
#   (c) the skipped_no_longer_queued stat is incremented.
#   (d) this is NOT treated as a failure (exit code 0, tail_failed stays 0)
#       -- correctly skipping a run that left the danger zone is success,
#       not an error.
#
# Usage: bash tests/cleanup_stuck_runs_race_skip_test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# A run well past FRESH_TAIL_MIN (below), still under the 8h zombie threshold.
CREATED_AT="$(date -u -d '-60 minutes' +%Y-%m-%dT%H:%M:%SZ)"

cat >"$tmpdir/gh" <<SH
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$*" >>"\$GH_LOG"

if [[ "\$1" == "api" && "\$*" == *"status=queued"* ]]; then
  if [[ "\$*" == *"page=1"* ]]; then
    cat <<'JSON'
{
  "workflow_runs": [
    {
      "id": 777,
      "status": "queued",
      "name": "Presubmit",
      "workflow_id": 55,
      "head_branch": "feature/race",
      "run_number": 1,
      "created_at": "${CREATED_AT}",
      "html_url": "https://github.com/acme/repoX/actions/runs/777"
    }
  ]
}
JSON
  else
    printf '{"workflow_runs":[]}\n'
  fi
  exit 0
fi

# The recheck-before-cancel status query: report the run has LEFT queued
# (picked up by a runner in the race window) -- must short-circuit BEFORE
# any cancel call.
if [[ "\$1" == "api" && "\$*" == *"--jq"* && "\$*" == *".status"* ]]; then
  printf 'in_progress\n'
  exit 0
fi

# Any cancel/force-cancel call here is the bug this test guards against --
# fail loudly so the test catches it instead of silently succeeding.
if [[ "\$1" == "api" && "\$2" == "-X" && "\$3" == "POST" && ( "\$4" == *"/cancel" || "\$4" == *"/force-cancel" ) ]]; then
  echo "BUG: cancel endpoint called for a run that left queued: \$*" >&2
  exit 1
fi

echo "unexpected gh invocation: \$*" >&2
exit 1
SH
chmod +x "$tmpdir/gh"

export PATH="$tmpdir:$PATH"
export GH_LOG="$tmpdir/gh.log"
export QUEUE_REPOS="acme/repoX"
export CANCEL_VERIFY_WAIT_S=0
export FRESH_TAIL_MIN=1

rc=0
output="$(./scripts/cleanup-stuck-runs.sh --tail --apply)" || rc=$?

# Skipping a raced-out run must not be treated as a failure.
[[ "$rc" -eq 0 ]]

grep -q "skipped tail 777: no longer queued (now in_progress)" <<<"$output"
grep -q "'skipped_no_longer_queued': 1" <<<"$output"
grep -q "'tail_cancelled': 0" <<<"$output"
grep -q "'tail_failed': 0" <<<"$output"

if grep -q "cancelled tail 777" <<<"$output"; then
  echo "FAIL: bug regressed -- run 777 was cancelled despite leaving queued" >&2
  exit 1
fi
if grep -q "runs/777/cancel" "$GH_LOG"; then
  echo "FAIL: bug regressed -- cancel endpoint hit for run 777" >&2
  exit 1
fi
if grep -q "runs/777/force-cancel" "$GH_LOG"; then
  echo "FAIL: bug regressed -- force-cancel endpoint hit for run 777" >&2
  exit 1
fi

echo "cleanup-stuck-runs listing->cancel race-skip test passed"
