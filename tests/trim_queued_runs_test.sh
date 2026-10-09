#!/usr/bin/env bash
# tests/trim_queued_runs_test.sh — unit & regression tests for trim-queued-runs.sh
#
# Tests coverage:
#   1. Dry-run by default: identifies candidates but never invokes POST .../cancel.
#   2. Apply mode: cancels eligible queued runs.
#   3. Deploy workflow safety: NEVER cancels runs for deploy-production.yml or auto-deploy-dev.yml.
#   4. Branch safety: NEVER cancels runs on main or master branches.
#   5. Draft PR trimming: cancels queued runs on draft PRs.
#   6. Superseded commit: cancels queued runs when remote branch HEAD has advanced past run SHA.
#   7. PR age filtering: cancels runs on PRs untouched for >= MIN_PR_AGE_HOURS, protects younger PRs.
#   8. Race-condition skip: skips run if status transitions from 'queued' to 'in_progress' before cancel.
#
# Usage: bash tests/trim_queued_runs_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"
GH_LOG="${WORK}/gh.log"
GIT_LOG="${WORK}/git.log"
: > "${GH_LOG}"
: > "${GIT_LOG}"

# Create stub git
cat > "${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GIT_LOG}"
if [[ "$*" == *"ls-remote"* ]]; then
  # If checking branch 'feature/superseded', return commit SHA 'newhead123'
  if [[ "$*" == *"refs/heads/feature/superseded"* ]]; then
    printf 'newhead123\trefs/heads/feature/superseded\n'
    exit 0
  fi
  # For other branches, return head matching the run
  if [[ "$*" == *"refs/heads/feature/draft"* ]]; then
    printf 'draftsha111\trefs/heads/feature/draft\n'
    exit 0
  fi
  if [[ "$*" == *"refs/heads/feature/old"* ]]; then
    printf 'oldsha222\trefs/heads/feature/old\n'
    exit 0
  fi
  if [[ "$*" == *"refs/heads/feature/young"* ]]; then
    printf 'youngsha333\trefs/heads/feature/young\n'
    exit 0
  fi
  if [[ "$*" == *"refs/heads/feature/deploy"* ]]; then
    printf 'deploysha444\trefs/heads/feature/deploy\n'
    exit 0
  fi
  if [[ "$*" == *"refs/heads/feature/race"* ]]; then
    printf 'racesha555\trefs/heads/feature/race\n'
    exit 0
  fi
fi
exit 0
EOF
chmod +x "${STUB_BIN}/git"

# Generate timestamps
NOW_TS="$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat())")"
OLD_TS="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=5)).isoformat())")"
YOUNG_TS="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=30)).isoformat())")"

# Create stub gh
cat > "${STUB_BIN}/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "${GH_LOG}"

# List queued runs
if [[ "\$1" == "api" && "\$*" == *"status=queued"* ]]; then
  if [[ "\$*" == *"page=1"* ]]; then
    cat <<JSON
{
  "workflow_runs": [
    {
      "id": 101,
      "name": "CI Deploy Prod",
      "path": ".github/workflows/deploy-production.yml",
      "head_branch": "feature/deploy",
      "head_sha": "deploysha444",
      "status": "queued",
      "html_url": "https://github.com/mock/repo/actions/runs/101"
    },
    {
      "id": 102,
      "name": "CI Main Branch",
      "path": ".github/workflows/ci.yml",
      "head_branch": "main",
      "head_sha": "mainsha000",
      "status": "queued",
      "html_url": "https://github.com/mock/repo/actions/runs/102"
    },
    {
      "id": 103,
      "name": "CI Superseded Commit",
      "path": ".github/workflows/ci.yml",
      "head_branch": "feature/superseded",
      "head_sha": "oldrunsha000",
      "status": "queued",
      "html_url": "https://github.com/mock/repo/actions/runs/103"
    },
    {
      "id": 104,
      "name": "CI Draft PR",
      "path": ".github/workflows/ci.yml",
      "head_branch": "feature/draft",
      "head_sha": "draftsha111",
      "status": "queued",
      "html_url": "https://github.com/mock/repo/actions/runs/104"
    },
    {
      "id": 105,
      "name": "CI Old Unmodified PR",
      "path": ".github/workflows/ci.yml",
      "head_branch": "feature/old",
      "head_sha": "oldsha222",
      "status": "queued",
      "html_url": "https://github.com/mock/repo/actions/runs/105"
    },
    {
      "id": 106,
      "name": "CI Young Fresh PR",
      "path": ".github/workflows/ci.yml",
      "head_branch": "feature/young",
      "head_sha": "youngsha333",
      "status": "queued",
      "html_url": "https://github.com/mock/repo/actions/runs/106"
    },
    {
      "id": 107,
      "name": "CI Raced Run",
      "path": ".github/workflows/ci.yml",
      "head_branch": "feature/race",
      "head_sha": "racesha555",
      "status": "queued",
      "html_url": "https://github.com/mock/repo/actions/runs/107"
    }
  ]
}
JSON
  else
    printf '{"workflow_runs":[]}\n'
  fi
  exit 0
fi

# PR list queries
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  if [[ "\$*" == *"feature/draft"* ]]; then
    cat <<JSON
[{"number": 401, "title": "Draft feature", "isDraft": true, "updatedAt": "${OLD_TS}", "headRefOid": "draftsha111"}]
JSON
    exit 0
  fi
  if [[ "\$*" == *"feature/old"* ]]; then
    cat <<JSON
[{"number": 402, "title": "Old feature", "isDraft": false, "updatedAt": "${OLD_TS}", "headRefOid": "oldsha222"}]
JSON
    exit 0
  fi
  if [[ "\$*" == *"feature/young"* ]]; then
    cat <<JSON
[{"number": 403, "title": "Young feature", "isDraft": false, "updatedAt": "${YOUNG_TS}", "headRefOid": "youngsha333"}]
JSON
    exit 0
  fi
  if [[ "\$*" == *"feature/race"* ]]; then
    cat <<JSON
[{"number": 404, "title": "Race feature", "isDraft": false, "updatedAt": "${OLD_TS}", "headRefOid": "racesha555"}]
JSON
    exit 0
  fi
  if [[ "\$*" == *"feature/superseded"* ]]; then
    cat <<JSON
[{"number": 405, "title": "Superseded feature", "isDraft": false, "updatedAt": "${YOUNG_TS}", "headRefOid": "newhead123"}]
JSON
    exit 0
  fi
  printf '[]\n'
  exit 0
fi

# Commit date queries
if [[ "\$1" == "api" && "\$*" == *"commits/oldsha222"* ]]; then
  printf '${OLD_TS}\n'
  exit 0
fi
if [[ "\$1" == "api" && "\$*" == *"commits/youngsha333"* ]]; then
  printf '${YOUNG_TS}\n'
  exit 0
fi
if [[ "\$1" == "api" && "\$*" == *"commits/racesha555"* ]]; then
  printf '${OLD_TS}\n'
  exit 0
fi
if [[ "\$1" == "api" && "\$*" == *"commits/"* ]]; then
  printf '${OLD_TS}\n'
  exit 0
fi

# Run status queries
if [[ "\$1" == "api" && "\$*" == *"--jq .status"* ]]; then
  if [[ "\$*" == *"runs/107"* ]]; then
    # Raced run became in_progress!
    printf 'in_progress\n'
  else
    printf 'queued\n'
  fi
  exit 0
fi

# Cancel and force-cancel endpoints
if [[ "\$1" == "api" && "\$2" == "-X" && "\$3" == "POST" && ( "\$4" == *"/cancel" || "\$4" == *"/force-cancel" ) ]]; then
  printf '{"message": "cancelled"}\n'
  exit 0
fi

echo "mock gh: unrecognized command: \$*" >&2
exit 1
EOF
chmod +x "${STUB_BIN}/gh"

export PATH="${STUB_BIN}:${PATH}"
export GH_LOG GIT_LOG
export QUEUE_REPOS="mock/repo"
export CANCEL_VERIFY_WAIT_S=0

echo "=== Test 1: Dry run mode ==="
output_dry="$(./scripts/trim-queued-runs.sh --dry-run)"
echo "$output_dry"

# Candidates should include:
# - 103 (superseded commit oldrunsha000 != newhead123)
# - 104 (draft PR #401)
# - 105 (old unmodified PR #402)
# - 107 (old unmodified PR #404)
# Protected:
# - 101 (deploy-production.yml)
# - 102 (main branch)
# - 106 (young PR, age 30m < 2h)

if ! grep -q "would cancel 103 .* superseded_commit" <<<"$output_dry"; then
  echo "FAIL: candidate 103 (superseded) missing from dry-run" >&2
  exit 1
fi
if ! grep -q "would cancel 104 .* draft_pr" <<<"$output_dry"; then
  echo "FAIL: candidate 104 (draft) missing from dry-run" >&2
  exit 1
fi
if ! grep -q "would cancel 105 .* unmodified_pr" <<<"$output_dry"; then
  echo "FAIL: candidate 105 (unmodified) missing from dry-run" >&2
  exit 1
fi
if grep -q "would cancel 101" <<<"$output_dry"; then
  echo "FAIL: run 101 (deploy-production.yml) should NEVER be a candidate" >&2
  exit 1
fi
if grep -q "would cancel 102" <<<"$output_dry"; then
  echo "FAIL: run 102 (main branch) should NEVER be a candidate" >&2
  exit 1
fi
if grep -q "would cancel 106" <<<"$output_dry"; then
  echo "FAIL: run 106 (young PR) should NOT be a candidate" >&2
  exit 1
fi

# Ensure dry-run never invoked cancel endpoint
if grep -q "/cancel" "${GH_LOG}"; then
  echo "FAIL: dry run made cancel calls to gh api!" >&2
  exit 1
fi
echo "PASS: Test 1 (Dry run)"

echo "=== Test 2: Apply mode ==="
: > "${GH_LOG}"
output_apply="$(./scripts/trim-queued-runs.sh --apply)"
echo "$output_apply"

# Run 103, 104, 105 should be cancelled
if ! grep -q "cancelled 103 .* superseded_commit" <<<"$output_apply"; then
  echo "FAIL: run 103 not cancelled in apply mode" >&2
  exit 1
fi
if ! grep -q "cancelled 104 .* draft_pr" <<<"$output_apply"; then
  echo "FAIL: run 104 not cancelled in apply mode" >&2
  exit 1
fi
if ! grep -q "cancelled 105 .* unmodified_pr" <<<"$output_apply"; then
  echo "FAIL: run 105 not cancelled in apply mode" >&2
  exit 1
fi

# Run 107 transitioned to in_progress during race window -> skipped
if ! grep -q "skipped 107: no longer queued (now in_progress)" <<<"$output_apply"; then
  echo "FAIL: run 107 race-skip not observed" >&2
  exit 1
fi

# Verify gh API calls in GH_LOG
if ! grep -q "runs/103/cancel" "${GH_LOG}"; then
  echo "FAIL: gh cancel not called for 103" >&2
  exit 1
fi
if ! grep -q "runs/104/cancel" "${GH_LOG}"; then
  echo "FAIL: gh cancel not called for 104" >&2
  exit 1
fi
if ! grep -q "runs/105/cancel" "${GH_LOG}"; then
  echo "FAIL: gh cancel not called for 105" >&2
  exit 1
fi
if grep -q "runs/107/cancel" "${GH_LOG}"; then
  echo "FAIL: gh cancel was called for raced run 107!" >&2
  exit 1
fi
if grep -q "runs/101/cancel" "${GH_LOG}" || grep -q "runs/102/cancel" "${GH_LOG}" || grep -q "runs/106/cancel" "${GH_LOG}"; then
  echo "FAIL: protected runs were cancelled!" >&2
  exit 1
fi

echo "PASS: Test 2 (Apply mode & safety invariants)"
echo "ALL TESTS PASSED!"
