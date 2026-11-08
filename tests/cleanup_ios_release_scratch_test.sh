#!/usr/bin/env bash
# Hermetic coverage for scripts/cleanup-ios-release-scratch.sh.
#
# Verifies: dry-run is non-destructive; --apply removes only a dir that is aged,
# correctly named, proven COMPLETED by the producer API, and referenced by no
# live process; the 4h retention default is what an unset MIN_AGE_HOURS actually
# applies and matches the launchd unit's value; a superseded (earlier) attempt of
# a successful run is retained inside the MIN_AGE_HOURS_RERUN grace and reaped
# past it; a live process whose cwd is inside the tree is protected even
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
trap 'for p in "${LIVE_PID:-}" "${CWD_PID:-}" "${LINK_PID:-}" "${NOPGREP_PID:-}" "${ENV_PID:-}" "${FD_PID:-}"; do [ -n "$p" ] && { kill "$p" 2>/dev/null || true; }; done; "${RM_BIN}" -rf "${W:?}" || true' EXIT
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
if [ -n "${STUB_GH_FAIL:-}" ]; then
  case "$*" in
    *" auth status"*) : ;;   # auth still works; only the data call fails
    *) exit 4 ;;
  esac
fi
id=""
for a in "$@"; do case "$a" in repos/*/actions/runs/*) id="${a##*/}" ;; esac; done
case "${id}" in
  999) printf 'in_progress\t\t1' ;;
  998) printf 'completed\tfailure\t1' ;;
  992) printf 'completed\tsuccess\t2' ;;   # re-run: earlier attempt INSIDE the 7d rerun grace
  994) printf 'completed\tsuccess\t2' ;;   # re-run: earlier attempt past / near the rerun grace
  *)   printf 'completed\tsuccess\t1' ;;
esac
STUB
chmod +x "${W}/bin/gh"
GH="${W}/bin/gh"

aged() { mkdir -p "$1"; touch -t 202401010000 "$1"; }

# Age a dir to N hours before now. The retention knobs are hour-based, so the
# cases that prove which floor applied need real "now - Nh" mtimes rather than a
# fixed date that is always far past every floor. Local time on purpose: BSD/GNU
# `touch -t` parse the stamp as local, so a `date -u` stamp would land hours off.
aged_hours_ago() {
  local hours="$1" dest="$2" stamp
  mkdir -p "${dest}"
  stamp="$(date -v-"${hours}"H +%Y%m%d%H%M 2>/dev/null || date -d "${hours} hours ago" +%Y%m%d%H%M)"
  touch -t "${stamp}" "${dest}"
}

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
STUB_GH_FAIL=1 GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null 2>&1 || true
[ -d "${VICTIM}" ] || fail "a failing producer data call must delete nothing"
pass "per-candidate API failure fails closed"
# ... and an absent gh must fail LOUDLY (preflight) rather than run a no-op.
rc=0
GH_BIN="${W}/bin/does-not-exist" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "absent gh must exit non-zero so the scheduler sees a broken job"
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
pass "failed runs retained"

# 9b. A re-run's EARLIER attempt dir is retained while it is inside the
#     MIN_AGE_HOURS_RERUN grace (168h = 7d). It used to be pinned forever; the
#     measured cost was 2 dirs / ~5 GB that nothing could ever reclaim.
RERUN_YOUNG="${SCR}/worldai-ios-release-992-1"   # producer says latest attempt = 2
aged_hours_ago 48 "${RERUN_YOUNG}"
env -u MIN_AGE_HOURS_RERUN GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" \
  bash "${S}" --apply >"${W}/rerun-young.log" 2>&1
[ -d "${RERUN_YOUNG}" ] || fail "an earlier attempt inside the 7d grace must be retained"
grep -q "SKIP earlier attempt younger than 7d" "${W}/rerun-young.log" \
  || { cat "${W}/rerun-young.log" >&2; fail "the earlier-attempt skip must name the 7d grace rule"; }
pass "earlier attempt inside the 7d grace retained (rule logged)"

# 9c. ...and the same shape IS reaped once past the grace, because the run as a
#     whole succeeded: nothing will ever touch that superseded tree again.
RERUN_OLD="${SCR}/worldai-ios-release-994-1"     # producer says latest attempt = 2
aged_hours_ago 240 "${RERUN_OLD}"                # 10 days > 7-day grace
env -u MIN_AGE_HOURS_RERUN GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" \
  bash "${S}" --apply >/dev/null
[ ! -d "${RERUN_OLD}" ] || fail "an earlier attempt past the 7d grace must be reaped"
pass "earlier attempt past the 7d grace reaped"

# 9d. The grace is a knob, not a constant: raising it past a dir's age retains
#     that earlier attempt again, and the log reports the configured value.
RERUN_WIDE="${SCR}/worldai-ios-release-994-1"    # same re-run shape as 9c
aged_hours_ago 240 "${RERUN_WIDE}"
MIN_AGE_HOURS_RERUN=360 GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" \
  bash "${S}" --apply >"${W}/rerun-wide.log" 2>&1
[ -d "${RERUN_WIDE}" ] || fail "MIN_AGE_HOURS_RERUN=360 must retain a 240h earlier attempt"
grep -q "SKIP earlier attempt younger than 15d" "${W}/rerun-wide.log" \
  || { cat "${W}/rerun-wide.log" >&2; fail "the skip log must report the configured grace (360h = 15d)"; }
rmdir "${RERUN_WIDE}"
pass "MIN_AGE_HOURS_RERUN override honored and logged"

# 10. $HOME refusals cannot be bypassed by a trailing slash or a symlink to HOME.
rc=0; GH_BIN="${GH}" SCRATCH_ROOT="${HOME}/" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must refuse HOME with a trailing slash"
ln -sfn "${HOME}" "${W}/home-link"
rc=0; GH_BIN="${GH}" SCRATCH_ROOT="${W}/home-link" bash "${S}" --apply >/dev/null 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "must refuse a symlink to HOME"
pass "HOME refusals not bypassable"

# 11. An argv-only reference must protect the tree even when pgrep is not on PATH
#     (the binary is resolved absolutely). Genuine tool absence is covered by
#     test 13's loud preflight.
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
pass "argv reference protected without pgrep on PATH"

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

# 12b. An OPEN FILE DESCRIPTOR into the tree must protect it, with argv clean, cwd
#      outside the tree and no environment reference - i.e. only the lsof fd scan
#      can catch this shape. (The reviewer flagged that "open fd" was claimed but
#      never isolated in a test.)
OPENFD="${SCR}/worldai-ios-release-993-1"
mkdir -p "${OPENFD}/deep"; echo data > "${OPENFD}/deep/f"
( cd "${OPENFD}/deep" && exec 3<f && cd / && exec bash -c 'while :; do sleep 1; done' ) &
FD_PID=$!
sleep 0.5
ps -o args= -p "${FD_PID}" | grep -Fq "worldai-ios-release-993" && fail "test setup: fd-only process must not carry the path in argv"
ps -o args= -p "${FD_PID}" | grep -Fq "OPENFD" && fail "test setup: fd-only process must not carry the path in argv"
GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >/dev/null
[ -d "${OPENFD}" ] || fail "an open file descriptor into the tree must protect it"
kill "${FD_PID}" 2>/dev/null || true
pass "open file descriptor protected"

# 13. A genuinely missing scanner must FAIL LOUDLY, not silently decline every
#     candidate. (This is the production paralysis agy found: the launchd PATH
#     omitted /usr/sbin, lsof was unresolvable, every candidate "failed closed"
#     and the hourly job still exited 0 looking healthy.) The scanner binaries are
#     resolved absolutely and overridable, so absence is simulated by pointing the
#     override at a path that does not exist.
rc=0
LSOF_BIN="${W}/bin/no-such-lsof" GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" \
  bash "${S}" --apply >"${W}/noscan.log" 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "a missing scanner must exit non-zero, not report a clean run"
grep -q "missing required tool" "${W}/noscan.log" || { cat "${W}/noscan.log" >&2; fail "missing-scanner failure must name the tool"; }
grep -q "lsof" "${W}/noscan.log" || fail "missing-scanner failure must name lsof"
# The same must hold when pgrep is the missing one.
rc=0
PGREP_BIN="${W}/bin/no-such-pgrep" GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" \
  bash "${S}" --apply >"${W}/noscan2.log" 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || fail "missing pgrep must exit non-zero"
grep -q "pgrep" "${W}/noscan2.log" || fail "missing-scanner failure must name pgrep"
pass "missing scanner fails loudly"

# 14. The launchd unit's PATH must contain the directory that provides lsof on
#     macOS (/usr/sbin); omitting it paralysed production once already.
grep -q "/usr/sbin" "${REPO_ROOT}/launchd/org.jleechanorg.ezgha-ios-release-cleanup.plist.template" \
  || fail "plist PATH must include /usr/sbin (macOS keeps lsof there)"
pass "plist PATH includes /usr/sbin"

# 14b. The unit's MIN_AGE_HOURS must equal the script's own default, so the two
#      places that define the retention floor cannot drift apart.
script_age_default="$(sed -n 's/^MIN_AGE_HOURS="\${MIN_AGE_HOURS:-\([0-9][0-9]*\)}"$/\1/p' "${S}")"
[ -n "${script_age_default}" ] || fail "could not read MIN_AGE_HOURS default from the script header"
plist_age_default="$(awk '/<key>MIN_AGE_HOURS<\/key>/{getline; gsub(/[^0-9]/, ""); print; exit}' \
  "${REPO_ROOT}/launchd/org.jleechanorg.ezgha-ios-release-cleanup.plist.template")"
[ "${plist_age_default}" = "${script_age_default}" ] \
  || fail "plist MIN_AGE_HOURS (${plist_age_default}) must match the script default (${script_age_default})"
[ "${script_age_default}" = "4" ] || fail "the retention default must be 4h, got ${script_age_default}h"
pass "plist MIN_AGE_HOURS matches the script default (4h)"

# 14c. The 4h floor must be what an unset MIN_AGE_HOURS actually applies: a 6h
#      dir is eligible, a 2h dir is not. (The unit sets the value explicitly, so
#      a drift between the padded default and real behaviour would otherwise go
#      unnoticed until an operator unset it.)
OLD_6H="${SCR}/worldai-ios-release-810-1"
aged_hours_ago 6 "${OLD_6H}"
YOUNG_2H="${SCR}/worldai-ios-release-811-1"
aged_hours_ago 2 "${YOUNG_2H}"
env -u MIN_AGE_HOURS GH_BIN="${GH}" SCRATCH_ROOT="${SCR}" bash "${S}" --apply >"${W}/default-age.log" 2>&1
[ ! -d "${OLD_6H}" ] || { cat "${W}/default-age.log" >&2; fail "a 6h dir must be reaped under the 4h default"; }
[ -d "${YOUNG_2H}" ] || fail "a 2h dir must be retained under the 4h default"
grep -q "MIN_AGE_HOURS=4 " "${W}/default-age.log" \
  || { cat "${W}/default-age.log" >&2; fail "the start line must report the effective 4h default"; }
pass "unset MIN_AGE_HOURS really applies the 4h default"

# 15. Unsafe Scratch roots are refused.
for bad in "/" "//" "/." "relative/path"; do
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
