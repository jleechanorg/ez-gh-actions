#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runs_json="$tmpdir/runs.json"
cat >"$runs_json" <<'JSON'
{
  "workflow_runs": [
    {
      "id": 100,
      "status": "queued",
      "name": "Green Gate",
      "head_branch": "feature/a",
      "created_at": "2026-07-07T12:00:00Z",
      "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/100"
    },
    {
      "id": 101,
      "status": "queued",
      "name": "Green Gate",
      "head_branch": "feature/a",
      "created_at": "2026-07-07T12:10:00Z",
      "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/101"
    },
    {
      "id": 102,
      "status": "queued",
      "name": "Green Gate",
      "head_branch": "feature/b",
      "created_at": "2026-07-07T11:00:00Z",
      "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/102"
    },
    {
      "id": 103,
      "status": "in_progress",
      "name": "Green Gate",
      "head_branch": "feature/a",
      "created_at": "2026-07-07T11:30:00Z",
      "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/103"
    }
  ]
}
JSON

output="$(NOW=unused ./scripts/queue-backlog-drain.sh --runs-json "$runs_json" --min-age-min 0)"

grep -q "superseded_candidates=1" <<<"$output"
grep -q "tail_older_than_min=3" <<<"$output"
grep -q "tail: age=.*run=102" <<<"$output"
grep -q "run=100" <<<"$output"
grep -q "newer_run=101" <<<"$output"
grep -q "url=https://github.com/jleechanorg/worldarchitect.ai/actions/runs/100" <<<"$output"
! grep -q "run=103" <<<"$output"

if ./scripts/queue-backlog-drain.sh --runs-json "$runs_json" --cancel-superseded >/tmp/queue-backlog-drain-no-yes.out 2>&1; then
  echo "expected --cancel-superseded without --yes to fail" >&2
  exit 1
fi
grep -q -- "--cancel-superseded requires --yes" /tmp/queue-backlog-drain-no-yes.out

echo "queue-backlog-drain tests passed"
