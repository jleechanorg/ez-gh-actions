#!/usr/bin/env bash
# Hermetic coverage for scripts/cleanup-ios-release-scratch.sh.
#
# Verifies: dry-run is non-destructive; --apply removes only a dir that is aged,
# correctly named, proven COMPLETED by the producer API, and referenced by no
# live process; a live process whose cwd is inside the tree is protected even
# when the path is absent from argv and even through macOS's /var -> /private/var
# symlink alias; an in-progress run and any gh failure are never deleted; the
# deletion cap is honored; no quarantine copy is ever made under HOME; unsafe
# Scratch roots are refused.
#
# Touches only a mktemp sandbox. `gh` is stubbed through GH_BIN.
#
# Usage: bash tests/cleanup_ios_release_scratch_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${REPO_ROOT}/scripts/cleanup-ios-release-scratch.sh"

W="$(mktemp -d)"
# Use the real system rm: this host's PATH `rm` may be a guard wrapper that
# resolves its own helpers through $HOME, which this test deliberately overrides.
RM_BIN=/bin/rm
[ -x "${RM_BIN}" ] || RM_BIN=/usr/bin/rm
trap 'for p in "${LIVE_PID:-}" "${CWD_PID:-}" "${LINK_PID:-}" "${NOPGREP_PID:-}" "${ENV_PID:-}"; do [ -n "$p" ] && { kill "$p" 2>/dev/null || true; }; done; "${RM_BIN}" -rf "${W:?}" || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export HOME="${W}/home"
mkdir -p "${HOME}"
SCR="${W}/scratch"
mkdir -p "${SCR}"

# --- producer-API stub -------------------------------------------------------
# Prints "<status>\t<run_attempt>" for the run id embedded in the API path.
mkdir -p "${W}/bin"
cat > "${W}/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_GH_FAIL:-}" ] || exit 4
id=""
for a in "$@"; do case "$a" in repos/*/actions/runs/*) id="${a##*/}" ;; esac; done
case "${id}" in
  999) printf 'in_progress\t\t1' ;;
  998) printf 'completed\tfailure\t1' ;;
  997) printf 'completed\tsuccess\t2' ;;   # re-run: dir carries attempt 1
  *)   printf 'completed\tsuccess\t1' ;;
esac
STUB
chmod +x "${W}/bin/gh"
GH="${W}/bin/gh"

aged() { mkdir -p "$1"; touch -t 202401010000 "$1"; }

OLD_OK="${SCR}/worldai-ios-release-111-1"
mkdir -p "${OLD_OK}"
# Write content BEFORE ageing: adding a directory entry bumps the dir mtime.
head -c 2048 /dev/zero > "${OLD_OK}/blob"
touch -t 202401010000 "${OLD_OK}"

OLD_LIVE="${SCR}/worldai-ios-release-222-1"
aged "${OLD_LIVE}"

OLD_CWD="${SCR}/worldai-ios-release-444-1"
aged "${OLD_CWD}"

IN_PROGRESS="${SCR}/worldai-ios-release-999-1"
aged "${IN_PROGRESS}"

OLD_BADNAME="${SCR}/worldai-ios-release-notanumber-1"
aged "${OLD_BADNAME}"

RECENT="${SCR}/worldai-ios-release-333-1"
mkdir -p "${RECENT}"

UNRELATED="${SCR}/unrelated-dir"
aged "${UNRELATED}"

# Two live processes, two detection paths:
#  (a) the path is in argv (a build invoked with the directory as an argument);
#  (b) the path is NOT in argv - the process merely has its working directory
#      inside the tree. This is the realistic long-build case and the exact
#      false negative an argv-only scan produces. It also exercises the macOS
#      /var -> /private/var alias, because mktemp lives under /var/folders.
# Compound commands, not `bash -c 'sleep 60'`: with a simple command bash execs
# into it and the argument/cwd association is lost.
bash -c 'while :; do sleep 1; done' "${OLD_LIVE}" &
LIVE_PID=$!
( cd "${OLD_CWD}" && exec bash -c 'while :; do sleep 1; done' ) &
CWD_PID=$!
sleep 0.5
ps -o args= -p "${CWD_PID}" | grep -Fq "${OLD_CWD}" && fail "test setup: cwd-only process must not carry the path in argv"

run() { GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" PRODUCER_REPO="jleechanorg/worldai_frontend" bash "${S}" "$@"; }

# 1. Dry-run must change nothing.
run >/dev/null
[ -d "${OLD_OK}" ] || fail "dry-run must not remove anything"
pass "dry-run is non-destructive"

# 2. --apply removes only the aged, correctly named, completed, unreferenced dir.
run --apply >/dev/null
[ ! -d "${OLD_OK}" ] || fail "aged completed release dir must be removed"
[ -d "${OLD_LIVE}" ] || fail "dir referenced from a live process argv must be kept"
[ -d "${OLD_CWD}" ] || fail "dir containing a live process working directory must be kept"
[ -d "${IN_PROGRESS}" ] || fail "an unfinished run must never be removed, however old"
[ -d "${OLD_BADNAME}" ] || fail "unrecognized dir name must be kept"
[ -d "${RECENT}" ] || fail "recent release dir must be kept"
[ -d "${UNRELATED}" ] || fail "non release-scratch dir must be kept"
pass "apply removes only eligible dirs"

# 3. Manifest records the removal.
grep -qs "worldai-ios-release-111-1" "${HOME}/.local/state/ezgha/ios-release-archives/"*.manifest \
  || fail "removal must be recorded in the manifest"
pass "removal recorded in manifest"

# 4. No cross-device quarantine copy may be created under HOME (HOME and the
#    Scratch volume are different filesystems, so a "quarantine" move would copy
#    gigabytes onto the root disk before deleting them).
[ -z "$(find "${HOME}" -maxdepth 6 -name 'quarantine-*' -print -quit 2>/dev/null)" ] \
  || fail "must not create a quarantine directory under HOME"
pass "no quarantine copy under HOME"

# 5. MIN_AGE_HOURS is honored (0 admits the recent dir; live ones stay protected).
GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" PRODUCER_REPO="jleechanorg/worldai_frontend" \
  bash "${S}" --apply --min-age-hours 0 >/dev/null
[ ! -d "${RECENT}" ] || fail "--min-age-hours 0 must admit the recent dir"
[ -d "${OLD_LIVE}" ] || fail "live-referenced dir must stay protected regardless of age"
[ -d "${OLD_CWD}" ] || fail "cwd-referenced dir must stay protected regardless of age"
pass "min-age override honored, live protection independent of age"

# 6. A producer-API failure must fail closed (delete nothing).
VICTIM="${SCR}/worldai-ios-release-555-1"
aged "${VICTIM}"
STUB_GH_FAIL=1 GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null
[ -d "${VICTIM}" ] || fail "gh failure must delete nothing"
# ... and an absent gh must also fail closed.
GH_BIN="${W}/bin/does-not-exist" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null
[ -d "${VICTIM}" ] || fail "absent gh must delete nothing"
pass "producer-API failure and absent gh both fail closed"
# Retire the probe dir (empty) so the cap test below starts from a clean slate;
# otherwise this eligible dir would consume the single deletion slot.
rmdir "${VICTIM}"

# 7. Deletion cap is enforced.
CAPA="${SCR}/worldai-ios-release-666-1"; aged "${CAPA}"
CAPB="${SCR}/worldai-ios-release-667-1"; aged "${CAPB}"
run --apply --max-deletions 1 >/dev/null
remaining=0
[ -d "${CAPA}" ] && remaining=$((remaining+1))
[ -d "${CAPB}" ] && remaining=$((remaining+1))
[ "${remaining}" -eq 1 ] || fail "deletion cap must remove exactly one of the two (removed $((2-remaining)))"
pass "deletion cap enforced"

# 8. A SYMLINKED Scratch root must still be traversed and must still protect a
#    live tree. BSD `find <symlink> -maxdepth 1` does not traverse a symlink root
#    without a trailing slash, so this also guards the canonicalisation step.
LINK_ROOT="${W}/scratch-link"
ln -s "${SCR}" "${LINK_ROOT}"
LINK_TARGET="${SCR}/worldai-ios-release-777-1"
aged "${LINK_TARGET}"
GH_BIN="${GH}" SCRATCH_ROOT="${LINK_ROOT}" bash "${S}" --apply >/dev/null
[ ! -d "${LINK_TARGET}" ] || fail "a symlinked Scratch root must still be traversed (aged completed dir not removed)"
LINK_LIVE="${SCR}/worldai-ios-release-778-1"
aged "${LINK_LIVE}"
bash -c 'while :; do sleep 1; done' "${LINK_LIVE}" &
LINK_PID=$!
sleep 0.3
GH_BIN="${GH}" SCRATCH_ROOT="${LINK_ROOT}" bash "${S}" --apply >/dev/null
[ -d "${LINK_LIVE}" ] || fail "a symlinked Scratch root must still protect a live dir"
kill "${LINK_PID}" 2>/dev/null || true
pass "symlinked Scratch root traversed and still safe"

# 9. Failed and cancelled runs are RETAINED (their scratch is debugging evidence).
FAILED="${SCR}/worldai-ios-release-998-1"
aged "${FAILED}"
GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null
[ -d "${FAILED}" ] || fail "a failed run's scratch must be retained, not reaped"
# ...while a re-run whose LATEST attempt succeeded is still reapable (attempt-1
# dirs must not be orphaned forever).
RERUN="${SCR}/worldai-ios-release-997-1"
aged "${RERUN}"
GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null
[ -d "${RERUN}" ] || fail "a re-run's EARLIER attempt dir must be retained (failure evidence)"
pass "failed runs and earlier re-run attempts retained"

# 10. $HOME refusals cannot be bypassed by a trailing slash or a symlink to HOME.
rc=0; GH_BIN="${GH}" SCRATCH_ROOT="${HOME}/" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must refuse HOME with a trailing slash"
ln -sfn "${HOME}" "${W}/home-link"
rc=0; GH_BIN="${GH}" SCRATCH_ROOT="${W}/home-link" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must refuse a symlink to HOME"
pass "HOME refusals not bypassable"

# 11. Missing pgrep must fail closed: with pgrep absent from PATH and a live
#     process referencing the dir only in argv, nothing may be deleted.
SHIM="${W}/shim"; mkdir -p "${SHIM}"
# Everything the reaper may exec EXCEPT pgrep, so the missing-pgrep path is
# isolated. `ps`/`lsof` stay present: with them absent the script would fail
# closed for a different reason and the assertion would prove nothing.
# Resolve from SYSTEM directories, not `command -v`: on this host `rm` resolves to
# a guard wrapper script whose own interpreter is absent from the restricted PATH,
# which exec-fails with 127 and would make this case test the wrapper instead of
# the reaper's missing-pgrep behaviour.
for tool in bash sh stat find du awk grep date mktemp basename rm mkdir tee cat pwd sed head tr \
            env sleep uname kill ls readlink ps lsof wc cut sort; do
  for d in /bin /usr/bin /usr/sbin /sbin /opt/homebrew/bin; do
    if [ -x "${d}/${tool}" ]; then ln -sfn "${d}/${tool}" "${SHIM}/${tool}"; break; fi
  done
done
ln -sfn "${GH}" "${SHIM}/gh"
NOLIVE="${SCR}/worldai-ios-release-996-1"
mkdir -p "${NOLIVE}"; touch -t 202401010000 "${NOLIVE}"
bash -c 'while :; do sleep 1; done' "${NOLIVE}" &
NOPGREP_PID=$!
sleep 0.3
SHIM_LOG="${W}/shim-run.log"
rc=0
# `env -u BASH_ENV`: a developer shell that exports BASH_ENV would source its own
# rc file under this restricted PATH and fail with 127 for reasons unrelated to
# the reaper. The case under test must be the missing `pgrep`, nothing else.
env -u BASH_ENV PATH="${SHIM}" GH_BIN="${SHIM}/gh" SCRATCH_ROOT="${SCR}" \
  /bin/bash "${S}" --apply >"${SHIM_LOG}" 2>&1 || rc=$?
# Prove the reaper really executed under the shim (it must have produced a start
# line and a summary) rather than silently failing to start.
[ "${rc}" -eq 0 ] || { cat "${SHIM_LOG}" >&2; fail "reaper did not run cleanly under the no-pgrep shim (rc=${rc})"; }
grep -q "=== start" "${SHIM_LOG}" || { cat "${SHIM_LOG}" >&2; fail "no-pgrep shim run produced no start line"; }
[ -d "${NOLIVE}" ] || fail "missing pgrep must fail closed (dir deleted while a live process referenced it)"
grep -q "SKIP in-use" "${SHIM_LOG}" || fail "no-pgrep run must report the tree as in-use"
kill "${NOPGREP_PID}" 2>/dev/null || true
pass "missing pgrep fails closed"

# 12. A deferred consumer that holds the path ONLY in an environment variable (no
#     argv entry, no open fd, foreign cwd) must still protect the tree.
ENVHELD="${SCR}/worldai-ios-release-995-1"
mkdir -p "${ENVHELD}"; touch -t 202401010000 "${ENVHELD}"
MY_ARTIFACT="${ENVHELD}" bash -c 'export MY_ARTIFACT; while :; do sleep 1; done' &
ENV_PID=$!
sleep 0.4
# Prove the setup really has no argv reference before relying on it.
ps -o args= -p "${ENV_PID}" | grep -Fq "worldai-ios-release-995" && fail "test setup: env-held path must not appear in argv"
GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null
[ -d "${ENVHELD}" ] || fail "an env-held (deferred consumer) reference must be protected"
kill "${ENV_PID}" 2>/dev/null || true
pass "environment-held path protected"

# 13. Unsafe Scratch roots are refused.
for bad in "/" "//" "relative/path"; do
  rc=0
  GH_BIN="${GH}" SCRATCH_ROOT="${bad}" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
  [ "${rc}" -ne 0 ] || fail "must refuse Scratch root '${bad}'"
done
rc=0
GH_BIN="${GH}" SCRATCH_ROOT="${HOME}" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must refuse HOME as a Scratch root"
# No SCRATCH_ROOT at all must fail closed rather than guess a path.
rc=0
env -u SCRATCH_ROOT PATH=/usr/bin:/bin bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must fail closed when the Scratch root is absent"
pass "unsafe Scratch roots refused"

echo "all cleanup-ios-release-scratch tests passed"
