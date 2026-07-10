#!/usr/bin/env bash
# Regression test (codex adversarial review 2026-07-10, finding 5, P2): in
# verify_and_force_cancel(), a run_status() API failure during the
# post-cancel verification step printed a WARN and returned False --
# indistinguishable from a verified-success return (status left "queued" ==
# False too). The script could therefore exit 0 with zero proof the cancel
# actually worked. cleanup-stuck-runs.sh must count this case separately
# (verify_inconclusive) and mirror the existing *_failed nonzero-exit
# policy so an unproven cancel can never look like a clean run.
#
# This test exercises the tail path: the pre-cancel race-recheck (finding
# 3) succeeds and reports "queued", the plain cancel call succeeds, but the
# POST-cancel verification status check fails (simulated transient gh api
# error). Asserts:
#   (a) a "WARN verify status inconclusive for tail <rid>" line is printed.
#   (b) the verify_inconclusive stat is incremented.
#   (c) NO force-cancel call is made (the function can't confirm the run is
#       still stuck, so it must not act further).
#   (d) the script exits non-zero -- verify_inconclusive alone must trip the
#       same failure-exit policy as tail_failed/zombie_failed/superseded_failed.
#
# Usage: bash tests/cleanup_stuck_runs_verify_inconclusive_test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

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
      "id": 888,
      "status": "queued",
      "name": "Presubmit",
      "workflow_id": 55,
      "head_branch": "feature/inconclusive",
      "run_number": 1,
      "created_at": "${CREATED_AT}",
      "html_url": "https://github.com/acme/repoY/actions/runs/888"
    }
  ]
}
JSON
  else
    printf '{"workflow_runs":[]}\n'
  fi
  exit 0
fi

# Plain cancel succeeds.
if [[ "\$1" == "api" && "\$2" == "-X" && "\$3" == "POST" && "\$4" == *"/cancel" ]]; then
  printf '{"ok":true}\n'
  exit 0
fi

# force-cancel must NEVER be called -- an inconclusive verify must not
# escalate to force-cancel (we have no proof the run is still stuck).
if [[ "\$1" == "api" && "\$2" == "-X" && "\$3" == "POST" && "\$4" == *"/force-cancel" ]]; then
  echo "BUG: force-cancel called after an inconclusive verify: \$*" >&2
  exit 1
fi

# Status check: 1st call is the pre-cancel race-recheck (finding 3) -- must
# report "queued" so processing proceeds to the cancel call. 2nd call is
# the POST-cancel verify -- simulate a transient API failure (this is the
# case under test).
if [[ "\$1" == "api" && "\$*" == *"--jq"* && "\$*" == *".status"* ]]; then
  COUNT_FILE="\$STATUS_COUNT_FILE"
  n=0
  [ -f "\$COUNT_FILE" ] && n=\$(cat "\$COUNT_FILE")
  n=\$((n + 1))
  echo "\$n" > "\$COUNT_FILE"
  if [ "\$n" -eq 1 ]; then
    printf 'queued\n'
    exit 0
  fi
  echo "simulated transient gh api error during verify" >&2
  exit 1
fi

echo "unexpected gh invocation: \$*" >&2
exit 1
SH
chmod +x "$tmpdir/gh"

export PATH="$tmpdir:$PATH"
export GH_LOG="$tmpdir/gh.log"
export STATUS_COUNT_FILE="$tmpdir/status_count"
export QUEUE_REPOS="acme/repoY"
export CANCEL_VERIFY_WAIT_S=0
export FRESH_TAIL_MIN=1

rc=0
output="$(./scripts/cleanup-stuck-runs.sh --tail --apply)" || rc=$?

# An inconclusive verify must trip the same nonzero-exit policy as a
# confirmed failure -- the script cannot exit 0 with an unproven cancel.
[[ "$rc" -ne 0 ]]

grep -q "cancelled tail 888" <<<"$output"
grep -q "WARN verify status inconclusive for tail 888" <<<"$output"
grep -q "'verify_inconclusive': 1" <<<"$output"
grep -q "'tail_force_cancelled': 0" <<<"$output"

if grep -q "runs/888/force-cancel" "$GH_LOG"; then
  echo "FAIL: bug regressed -- force-cancel endpoint hit after an inconclusive verify" >&2
  exit 1
fi

echo "cleanup-stuck-runs verify-inconclusive exit-policy test passed"
