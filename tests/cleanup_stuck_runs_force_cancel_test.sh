#!/usr/bin/env bash
# Regression test (jleechan-uud): a plain POST .../cancel can return HTTP 202
# but silently no-op on a queued run whose only job never started
# (runner_id:0). cleanup-stuck-runs.sh must verify shortly after any cancel
# that the run actually left "queued", and force-cancel it if not --
# synchronously, per-run, at the moment of that specific cancel (not via
# same-tick batch-list membership, which previously let a wedged run survive
# every later tick).
#
# Usage: bash tests/cleanup_stuck_runs_force_cancel_test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# A run just past FRESH_TAIL_MIN (below), well under the 8h zombie threshold.
CREATED_AT="$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"

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
      "id": 500,
      "status": "queued",
      "name": "Presubmit",
      "workflow_id": 55,
      "head_branch": "feature/stuck",
      "run_number": 1,
      "created_at": "${CREATED_AT}",
      "html_url": "https://github.com/acme/repoX/actions/runs/500"
    }
  ]
}
JSON
  else
    printf '{"workflow_runs":[]}\n'
  fi
  exit 0
fi

# Plain cancel: returns 202 but the run stays queued (the jleechan-uud bug).
if [[ "\$1" == "api" && "\$2" == "-X" && "\$3" == "POST" && "\$4" == *"/force-cancel" ]]; then
  printf '{"ok":true}\n'
  exit 0
fi
if [[ "\$1" == "api" && "\$2" == "-X" && "\$3" == "POST" && "\$4" == *"/cancel" ]]; then
  printf '{"ok":true}\n'
  exit 0
fi

# verify_and_force_cancel() status check: report still "queued" so the
# fallback force-cancel fires.
if [[ "\$1" == "api" && "\$*" == *"--jq"* && "\$*" == *".status"* ]]; then
  printf 'queued\n'
  exit 0
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

output="$(./scripts/cleanup-stuck-runs.sh --tail --apply)"

grep -q "cancelled tail 500" <<<"$output"
grep -q "force-cancelled stuck tail 500 (survived plain cancel)" <<<"$output"
grep -q "'tail_force_cancelled': 1" <<<"$output"

grep -q "runs/500/cancel" "$GH_LOG"
grep -q "runs/500/force-cancel" "$GH_LOG"
grep -q "runs/500 --jq .status" "$GH_LOG"

echo "cleanup-stuck-runs force-cancel-after-verify test passed"
