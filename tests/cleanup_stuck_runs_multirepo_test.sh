#!/usr/bin/env bash
# Regression test (ez-gh-actions-ssjg): cleanup-stuck-runs.sh must scan every
# repo in QUEUE_REPOS even when one repo's pass fails outright (e.g. a
# transient gh api error unrelated to the rate-limit backoff path). A
# failing repo must be logged and counted, NOT abort the loop -- the other
# repos in the list must still get their own scan/apply pass every tick.
#
# Usage: bash tests/cleanup_stuck_runs_multirepo_test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_LOG"

if [[ "$1" == "api" && "$*" == *"status=queued"* ]]; then
  # Simulate an outright (non-rate-limit) failure for repoB only, on every
  # page -- this must NOT be treated as the rate-limit backoff/skip path
  # (which only fires on "rate limit" / "403" text), so it propagates as an
  # unhandled per-repo failure that the outer bash loop must catch.
  if [[ "$*" == *"acme/repoB"* ]]; then
    echo "simulated transient non-rate-limit failure for repoB" >&2
    exit 1
  fi
  printf '{"workflow_runs":[]}\n'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
SH
chmod +x "$tmpdir/gh"

export PATH="$tmpdir:$PATH"
export GH_LOG="$tmpdir/gh.log"
export QUEUE_REPOS="acme/repoA acme/repoB acme/repoC"

rc=0
output="$(./scripts/cleanup-stuck-runs.sh --superseded)" || rc=$?

# Overall exit must be non-zero (a repo failed)...
[[ "$rc" -ne 0 ]]

# ...but repoA and repoC must STILL have been scanned (loop did not abort
# early on repoB's failure).
grep -q "\[acme/repoA\] scan: repo=acme/repoA queued_total=0" <<<"$output"
grep -q "\[acme/repoC\] scan: repo=acme/repoC queued_total=0" <<<"$output"

# repoB must never have reached its scan: line (it failed before that point).
! grep -q "repoB\] scan:" <<<"$output"

# repoB's failure must be logged and counted, not silently swallowed.
grep -q "\[acme/repoB\] cleanup pass FAILED" <<<"$output"
grep -q "3 repo(s) scanned, 1 failed: acme/repoB" <<<"$output"

echo "cleanup-stuck-runs multi-repo continuation test passed"
