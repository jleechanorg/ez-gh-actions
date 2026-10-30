#!/usr/bin/env bash
# Hermetic coverage for scripts/cleanup-ios-release-scratch.sh.
# Verifies dry-run is non-destructive, --apply removes only aged, correctly
# named, non-live per-run TestFlight release dirs, and that unsafe Scratch
# roots are refused. Touches only a mktemp sandbox.
#
# Usage: bash tests/cleanup_ios_release_scratch_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${REPO_ROOT}/scripts/cleanup-ios-release-scratch.sh"

W="$(mktemp -d)"
trap 'rm -rf "${W:?}"; [ -n "${LIVE_PID:-}" ] && kill "${LIVE_PID}" 2>/dev/null || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export HOME="${W}/home"
mkdir -p "${HOME}"
SCR="${W}/scratch"
mkdir -p "${SCR}"

aged() { mkdir -p "$1"; touch -t 202401010000 "$1"; }

OLD_OK="${SCR}/worldai-ios-release-111-1"
mkdir -p "${OLD_OK}"
# Write content BEFORE ageing the dir: adding a directory entry bumps its mtime.
head -c 2048 /dev/zero > "${OLD_OK}/blob"
touch -t 202401010000 "${OLD_OK}"

OLD_LIVE="${SCR}/worldai-ios-release-222-1"
aged "${OLD_LIVE}"

OLD_BADNAME="${SCR}/worldai-ios-release-notanumber-1"
aged "${OLD_BADNAME}"

RECENT="${SCR}/worldai-ios-release-333-1"
mkdir -p "${RECENT}"

UNRELATED="${SCR}/unrelated-dir"
aged "${UNRELATED}"

# A live process that references OLD_LIVE by path: the hung/multi-hour-run case.
# Compound command, not `bash -c 'sleep 60'`: with a simple command bash execs
# into it and the path argument disappears from the process table.
bash -c 'while :; do sleep 1; done' "${OLD_LIVE}" &
LIVE_PID=$!
sleep 0.3

# 1. Dry-run must change nothing.
SCRATCH_ROOT="${SCR}" bash "${S}" >/dev/null
[ -d "${OLD_OK}" ] || fail "dry-run must not remove anything"
pass "dry-run is non-destructive"

# 2. --apply removes only the aged, correctly named, unreferenced dir.
SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null
[ ! -d "${OLD_OK}" ] || fail "aged completed release dir must be removed"
[ -d "${OLD_LIVE}" ] || fail "dir referenced by a live process must be kept"
[ -d "${OLD_BADNAME}" ] || fail "unrecognized dir name must be kept"
[ -d "${RECENT}" ] || fail "recent release dir must be kept"
[ -d "${UNRELATED}" ] || fail "non release-scratch dir must be kept"
pass "apply removes only eligible dirs"

# 3. Manifest records the removal.
grep -qs "worldai-ios-release-111-1" "${HOME}/.local/state/ezgha/ios-release-archives/"*.manifest \
  || fail "removal must be recorded in the manifest"
pass "removal recorded in manifest"

# 4. MIN_AGE_HOURS is honored (0 admits the recent dir, live one still protected).
SCRATCH_ROOT="${SCR}" bash "${S}" --apply --min-age-hours 0 >/dev/null
[ ! -d "${RECENT}" ] || fail "--min-age-hours 0 must admit the recent dir"
[ -d "${OLD_LIVE}" ] || fail "live-referenced dir must stay protected regardless of age"
pass "min-age override honored, live protection independent of age"

# 5. Unsafe Scratch roots are refused.
for bad in "/" "relative/path"; do
  rc=0
  SCRATCH_ROOT="${bad}" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
  [ "${rc}" -ne 0 ] || fail "must refuse Scratch root '${bad}'"
done
rc=0
SCRATCH_ROOT="${HOME}" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must refuse HOME as a Scratch root"
# Unresolvable root (no SCRATCH_ROOT, no diskm on PATH) must fail closed rather
# than fall back to a guessed path.
rc=0
env -u SCRATCH_ROOT PATH=/usr/bin:/bin bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must fail closed when the Scratch root cannot be resolved"
pass "unsafe Scratch roots refused"

echo "all cleanup-ios-release-scratch tests passed"
