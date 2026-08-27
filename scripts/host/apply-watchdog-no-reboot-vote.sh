#!/usr/bin/env bash
# Transactionally patch watchdog.conf so repair cannot vote for a host reboot.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="${REPO_ROOT}/config/watchdog.conf"
ASSERT_SCRIPT="${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
need_sudo() { echo "NEED_SUDO: $*" >&2; exit 2; }

# Alternate roots and command wrappers are fixture-only seams. Production
# always has one unambiguous target and privilege path.
if [ "${APPLY_WATCHDOG_TEST_MODE:-0}" = "1" ]; then
  [ -n "${APPLY_WATCHDOG_ROOT:-}" ] || fail "test mode requires APPLY_WATCHDOG_ROOT"
  [ -n "${APPLY_WATCHDOG_ROOT_CMD:-}" ] || fail "test mode requires APPLY_WATCHDOG_ROOT_CMD"
  case "$APPLY_WATCHDOG_ROOT" in
    /*) TARGET="${APPLY_WATCHDOG_ROOT%/}/etc/watchdog.conf" ;;
    *) fail "APPLY_WATCHDOG_ROOT must be an absolute path" ;;
  esac
  ROOT_CMD=("$APPLY_WATCHDOG_ROOT_CMD")
else
  [ -z "${APPLY_WATCHDOG_ROOT:-}" ] || fail "APPLY_WATCHDOG_ROOT is test-mode only"
  [ -z "${APPLY_WATCHDOG_ROOT_CMD:-}" ] || fail "APPLY_WATCHDOG_ROOT_CMD is test-mode only"
  TARGET="/etc/watchdog.conf"
  ROOT_CMD=(sudo -n)
fi
as_root() { "${ROOT_CMD[@]}" "$@"; }

# Writer contract: every supported watchdog-config writer must acquire the
# target-adjacent ${TARGET}.ezgha.lock directory for its full transaction.
# Filesystem rename is not compare-and-swap; writers that ignore this lock are
# unsupported. The fingerprints below are defense-in-depth diagnostics only.

[ -f "$SRC" ] || fail "missing $SRC"
[ -f "$ASSERT_SCRIPT" ] || fail "missing $ASSERT_SCRIPT"
grep -qE '^repair-maximum = 0$' "$SRC" || fail "$SRC missing repair-maximum = 0"
grep -qE '^repair-timeout = 60$' "$SRC" || fail "$SRC missing repair-timeout = 60"

if [ "${APPLY_WATCHDOG_DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would transactionally set $TARGET repair-maximum=0 repair-timeout=60 then SIGHUP watchdog"
  exit 0
fi

if ! as_root true 2>/dev/null; then
  if [ "${APPLY_WATCHDOG_TEST_MODE:-0}" != "1" ]; then
    need_sudo "sudo -n is required to patch $TARGET (repair-maximum=0)"
  fi
  fail "privileged command cannot patch $TARGET"
fi

workdir="$(mktemp -d)"
staged="$workdir/staged-watchdog.conf"
snapshot="$workdir/original-watchdog.conf"
lock_dir="${TARGET}.ezgha.lock"
lock_held=0
remote_tmp=""
cleanup() {
  [ -z "$remote_tmp" ] || as_root rm -f -- "$remote_tmp" >/dev/null 2>&1 || true
  [ "$lock_held" -eq 0 ] || as_root rmdir -- "$lock_dir" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT

# mkdir is atomic, so supported writers serialize their full transactions. A
# pre-existing lock is deliberately fail-closed rather than stale-cleaned.
if ! as_root mkdir -- "$lock_dir"; then
  fail "another watchdog transaction holds lock: $lock_dir"
fi
lock_held=1

# Never follow a symlink or fabricate a missing target: that changes the
# transaction from a repair of a known config into a replacement of a path.
if as_root test -L "$TARGET"; then
  fail "target must be a regular file, not a symlink: $TARGET"
fi
if ! as_root test -e "$TARGET"; then
  fail "target is missing: $TARGET"
fi
if ! as_root test -f "$TARGET"; then
  fail "target must be a regular file: $TARGET"
fi

fingerprint_target() {
  local digest metadata
  digest="$(as_root sha256sum -- "$TARGET")" || return 1
  digest="${digest%% *}"
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  metadata="$(as_root stat -c '%d:%i:%s:%y:%z:%a:%u:%g' -- "$TARGET")" || return 1
  printf '%s:%s\n' "$digest" "$metadata"
}

# Snapshot and stage are accepted only if they bracket the same initial file.
# The local snapshot has preserve=all metadata; its target-adjacent rollback
# copy below retains ACLs and xattrs in addition to ordinary stat metadata.
initial_fingerprint="$(fingerprint_target)" || fail "cannot fingerprint target: $TARGET"
as_root cp --preserve=all -- "$TARGET" "$snapshot" || fail "cannot snapshot target config: $TARGET"
as_root cat -- "$TARGET" > "$staged" || fail "cannot stage target config: $TARGET"
staging_fingerprint="$(fingerprint_target)" || fail "cannot re-fingerprint target: $TARGET"
[ "$staging_fingerprint" = "$initial_fingerprint" ] \
  || fail "target changed while staging; target was not changed"

# Only active, exact key assignments are replaced. Commented defaults and
# prefix lookalikes are ordinary unrelated configuration and remain verbatim.
python3 - "$staged" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)

def normalize(key, value):
    exact_assignment = re.compile(r"^[ \t]*" + re.escape(key) + r"[ \t]*=")
    result = []
    inserted = False
    for line in lines:
        if line.lstrip().startswith("#") or not exact_assignment.match(line):
            result.append(line)
            continue
        if not inserted:
            result.append(f"{key} = {value}\n")
            inserted = True
    if not inserted:
        if result and not result[-1].endswith("\n"):
            result[-1] += "\n"
        result.append(f"{key} = {value}\n")
    return result

lines = normalize("repair-maximum", "0")
lines = normalize("repair-timeout", "60")
path.write_text("".join(lines))
PY

# Bind the staged settings and repair-binary to the canonical digest before
# changing the target.
if ! REPO_ROOT="$REPO_ROOT" ASSERT_LIVE_WATCHDOG=1 WATCHDOG_CONF_PATH="$staged" \
  bash "$ASSERT_SCRIPT"; then
  fail "staged watchdog config failed no-host-reboot-vote preflight; target was not changed"
fi

# This is deliberately immediately before the replacement sequence. It is a
# defense-in-depth check for unsupported writers; only the mandatory lock
# provides the supported serialization contract.
preinstall_fingerprint="$(fingerprint_target)" || fail "cannot fingerprint target before install: $TARGET"
[ "$preinstall_fingerprint" = "$initial_fingerprint" ] \
  || fail "target changed since staging; target was not changed"

remote_tmp="$(as_root mktemp "${TARGET}.ezgha.XXXXXX")" \
  || fail "cannot create target-adjacent temporary config"
# Preserve ACLs, xattrs, ownership, mode, and timestamps from the live target.
as_root cp --preserve=all -- "$TARGET" "$remote_tmp" \
  || fail "cannot preserve target metadata in temporary config"
# The destination already has the preserved metadata; this changes only bytes.
as_root cp -- "$staged" "$remote_tmp" || fail "cannot write staged watchdog config"

# Recheck after building the replacement, immediately before atomic rename.
# It narrows exposure to unsupported writers but cannot make rename CAS-safe.
pre_rename_fingerprint="$(fingerprint_target)" || fail "cannot fingerprint target before rename: $TARGET"
[ "$pre_rename_fingerprint" = "$initial_fingerprint" ] \
  || fail "target changed since staging; target was not changed"
as_root mv -f -- "$remote_tmp" "$TARGET" || fail "could not atomically install staged watchdog config"
remote_tmp=""

installed_fingerprint="$(fingerprint_target)" \
  || fail "cannot fingerprint installed config; refusing an unsafe rollback"

restore_original() {
  local reason="$1" live_fingerprint rollback_tmp=""
  live_fingerprint="$(fingerprint_target)" \
    || fail "$reason; cannot fingerprint live target, refusing an unsafe rollback"
  [ "$live_fingerprint" = "$installed_fingerprint" ] \
    || fail "$reason; concurrent writer changed target after installation; retaining newer bytes (writer ignored mandatory lock contract)"

  rollback_tmp="$(as_root mktemp "${TARGET}.ezgha.rollback.XXXXXX")" \
    || fail "$reason; cannot create rollback temporary config"
  if ! as_root cp --preserve=all -- "$snapshot" "$rollback_tmp"; then
    as_root rm -f -- "$rollback_tmp" >/dev/null 2>&1 || true
    fail "$reason; cannot preserve original metadata for rollback"
  fi
  if ! as_root mv -f -- "$rollback_tmp" "$TARGET"; then
    as_root rm -f -- "$rollback_tmp" >/dev/null 2>&1 || true
    fail "$reason; FAILED to restore original config"
  fi
  as_root cmp -s -- "$snapshot" "$TARGET" \
    || fail "$reason; restored config bytes do not match original snapshot"
  if ! as_root killall -HUP watchdog; then
    echo "WARN: restored $TARGET but could not SIGHUP watchdog" >&2
  fi
  fail "$reason; original config restored"
}

if ! as_root env REPO_ROOT="$REPO_ROOT" ASSERT_LIVE_WATCHDOG=1 \
  WATCHDOG_CONF_PATH="$TARGET" bash "$ASSERT_SCRIPT"; then
  restore_original "installed watchdog config failed verification"
fi

if ! as_root killall -HUP watchdog; then
  restore_original "could not SIGHUP watchdog after installation"
fi

echo "SIGHUP watchdog"
