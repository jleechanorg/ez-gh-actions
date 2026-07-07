#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_LOG"

if [[ "$1" == "api" && "$*" == *"status=queued"* ]]; then
  if [[ "$*" == *"page=1"* ]]; then
    cat <<'JSON'
{
  "workflow_runs": [
    {
      "id": 100,
      "status": "queued",
      "name": "Green Gate",
      "workflow_id": 77,
      "head_branch": "feature/a",
      "run_number": 1,
      "created_at": "2026-07-07T12:00:00Z",
      "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/100"
    },
    {
      "id": 101,
      "status": "queued",
      "name": "Green Gate",
      "workflow_id": 77,
      "head_branch": "feature/a",
      "run_number": 2,
      "created_at": "2026-07-07T12:10:00Z",
      "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/101"
    },
    {
      "id": 103,
      "status": "in_progress",
      "name": "Green Gate",
      "workflow_id": 77,
      "head_branch": "feature/a",
      "run_number": 3,
      "created_at": "2026-07-07T12:20:00Z",
      "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/103"
    }
  ]
}
JSON
  else
    printf '{"workflow_runs":[]}\n'
  fi
  exit 0
fi

if [[ "$1" == "api" && "$2" == "-X" && "$3" == "POST" && "$4" == *"/cancel" ]]; then
  printf '{"ok":true}\n'
  exit 0
fi

if [[ "$1" == "run" && "$2" == "delete" ]]; then
  printf 'deleted\n'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
SH
chmod +x "$tmpdir/gh"

export PATH="$tmpdir:$PATH"
export GH_LOG="$tmpdir/gh.log"

dry_output="$(./scripts/cleanup-stuck-runs.sh --superseded)"
grep -q "mode=dry-run" <<<"$dry_output"
grep -q "keep newest queued.*id=101" <<<"$dry_output"
grep -q "would cancel superseded queued 100" <<<"$dry_output"
! grep -q "would cancel superseded queued 101" <<<"$dry_output"
! grep -q "would cancel superseded queued 103" <<<"$dry_output"
! grep -q "/cancel" "$GH_LOG"

: >"$GH_LOG"
apply_output="$(./scripts/cleanup-stuck-runs.sh --superseded --apply)"
grep -q "mode=apply" <<<"$apply_output"
grep -q "cancelled superseded queued 100" <<<"$apply_output"
grep -q "repos/jleechanorg/worldarchitect.ai/actions/runs/100/cancel" "$GH_LOG"
! grep -q "runs/101/cancel" "$GH_LOG"
! grep -q "runs/103/cancel" "$GH_LOG"

echo "cleanup-stuck-runs tests passed"
