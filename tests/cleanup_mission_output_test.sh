#!/usr/bin/env bash
# regression test for scripts/cleanup-mission-output.sh
# Verifies dry-run behavior, --apply deletion, min-age filtering, active marker protection,
# and manifest logging without touching live system paths.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/cleanup-mission-output.sh"

WORK=$(mktemp -d)
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

HOME_MOCK="${WORK}/home"
TMP_MOCK="${WORK}/tmp_root/worldarchitect.ai"
mkdir -p "${HOME_MOCK}" "${TMP_MOCK}"

# Create test subdirectories in mock root:
# 1. Old stale mission directory (>10 hours old)
OLD_DIR="${TMP_MOCK}/worktree-old-stale-mission"
mkdir -p "${OLD_DIR}"
touch "${OLD_DIR}/app.log"
touch -t 202501011200.00 "${OLD_DIR}"

# 2. Recent mission directory (fresh mtime)
RECENT_DIR="${TMP_MOCK}/worktree-recent-mission"
mkdir -p "${RECENT_DIR}"
touch "${RECENT_DIR}/app.log"

# 3. Active marker directory (starts with active prefix wf_)
ACTIVE_DIR="${TMP_MOCK}/wf_active_runner_job"
mkdir -p "${ACTIVE_DIR}"
touch "${ACTIVE_DIR}/app.log"
touch -t 202501011200.00 "${ACTIVE_DIR}"

# Resolve canonical paths (resolving any /tmp or /var/folders symlinks)
OLD_DIR=$(cd -P "${OLD_DIR}" && pwd -P)
RECENT_DIR=$(cd -P "${RECENT_DIR}" && pwd -P)
ACTIVE_DIR=$(cd -P "${ACTIVE_DIR}" && pwd -P)
TMP_MOCK_CANONICAL=$(cd -P "${TMP_MOCK}" && pwd -P)

# Create mocked script pointing CANDIDATE_ROOTS exclusively to TMP_MOCK_CANONICAL
cat > "${WORK}/script_mock.sh" <<EOF
#!/usr/bin/env bash
CANDIDATE_ROOTS=("${TMP_MOCK_CANONICAL}")
EOF
sed -e 's/CANDIDATE_ROOTS=(/DISABLED_ROOTS=(/' "${SCRIPT}" >> "${WORK}/script_mock.sh"
chmod +x "${WORK}/script_mock.sh"

# Test 1: DRY-RUN mode
echo "=== Test 1: DRY-RUN ==="
HOME="${HOME_MOCK}" bash "${WORK}/script_mock.sh" --min-age-hours 4 > "${WORK}/dry_run.out" 2>&1 || fail "dry-run script failed"

if [ -d "${OLD_DIR}" ] && [ -d "${RECENT_DIR}" ] && [ -d "${ACTIVE_DIR}" ]; then
  echo "PASS: dry-run preserved all directories"
else
  fail "dry-run deleted directories"
fi

if grep -q "DRY-RUN would remove: ${OLD_DIR}" "${HOME_MOCK}/.local/state/ezgha/mission-output-cleanup.log"; then
  echo "PASS: dry-run correctly logged candidate for removal"
else
  fail "dry-run did not log old directory for removal"
fi

# Test 2: --apply mode
echo "=== Test 2: --apply ==="
HOME="${HOME_MOCK}" bash "${WORK}/script_mock.sh" --apply --min-age-hours 4 > "${WORK}/apply.out" 2>&1 || fail "apply script failed"

if [ ! -d "${OLD_DIR}" ]; then
  echo "PASS: --apply removed old stale directory"
else
  fail "--apply failed to remove old stale directory"
fi

if [ -d "${RECENT_DIR}" ]; then
  echo "PASS: --apply preserved recent directory"
else
  fail "--apply deleted recent directory"
fi

if [ -d "${ACTIVE_DIR}" ]; then
  echo "PASS: --apply preserved active marker directory"
else
  fail "--apply deleted active marker directory"
fi

manifest_count=$(find "${HOME_MOCK}/.local/state/ezgha/mission-output-archives" -type f -name "*.manifest" | wc -l | tr -d ' ')
if [ "${manifest_count}" -gt 0 ]; then
  echo "PASS: manifest file generated successfully (${manifest_count} manifest)"
else
  fail "manifest file was not generated"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  cat "${WORK}/dry_run.out" >&2
  cat "${WORK}/apply.out" >&2
  exit 1
fi
