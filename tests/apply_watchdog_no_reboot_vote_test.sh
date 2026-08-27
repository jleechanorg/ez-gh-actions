#!/usr/bin/env bash
# Fixture integration coverage for the transactional watchdog repair.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/host/apply-watchdog-no-reboot-vote.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

make_case() {
  local name="$1" repair_binary="$2"
  CASE="$TMP/$name"
  ROOT="$CASE/root"
  BIN="$CASE/bin"
  TRACE="$CASE/trace"
  mkdir -p "$ROOT/etc" "$ROOT/tmp" "$BIN"
  : > "$TRACE"
  cat > "$ROOT/etc/watchdog.conf" <<EOF
# repair-maximum = 9
repair-maximum = 4
repair-maximum-extra = 88
# repair-timeout = 9
repair-timeout = 12
repair-timeout-extra = 77
repair-binary = $repair_binary
EOF
  chmod 640 "$ROOT/etc/watchdog.conf"

  cat > "$BIN/root-cmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$WATCHDOG_TEST_TRACE"
printf '\n' >> "$WATCHDOG_TEST_TRACE"
for argument in "$@"; do
  case "$argument" in
    /etc|/etc/*|sudo|systemctl) echo "tripwire: live/service command" >&2; exit 97 ;;
  esac
done
if [ "${1:-}" = "sha256sum" ] && [ "${WATCHDOG_TEST_MUTATE_BEFORE_INSTALL:-0}" = "1" ]; then
  digest_count=0
  [ ! -f "$WATCHDOG_TEST_STATE" ] || digest_count="$(cat "$WATCHDOG_TEST_STATE")"
  digest_count=$((digest_count + 1))
  printf '%s' "$digest_count" > "$WATCHDOG_TEST_STATE"
  if [ "$digest_count" -eq 3 ]; then
    printf 'foreign writer before install\n' > "$WATCHDOG_TEST_TARGET"
    chmod 600 "$WATCHDOG_TEST_TARGET"
  fi
fi
if [ "${1:-}" = "mv" ] && [ "${WATCHDOG_TEST_COOPERATIVE_LOCK:-0}" = "1" ]; then
  if mkdir "${WATCHDOG_TEST_TARGET}.ezgha.lock" 2>/dev/null; then
    rmdir "${WATCHDOG_TEST_TARGET}.ezgha.lock"
    echo "cooperative writer acquired transaction lock" >&2
    exit 94
  fi
  lock_count=0
  [ ! -f "$WATCHDOG_TEST_COOPERATIVE_STATE" ] || lock_count="$(cat "$WATCHDOG_TEST_COOPERATIVE_STATE")"
  printf '%s' "$((lock_count + 1))" > "$WATCHDOG_TEST_COOPERATIVE_STATE"
fi
if [ "${1:-}" = "killall" ]; then
  [ "${2:-}" = "-HUP" ] && [ "${3:-}" = "watchdog" ] \
    || { echo "tripwire: non-HUP signal" >&2; exit 98; }
  if [ "${WATCHDOG_TEST_MUTATE_POST_INSTALL:-0}" = "1" ]; then
    printf 'foreign writer after install\n' > "$WATCHDOG_TEST_TARGET"
    chmod 600 "$WATCHDOG_TEST_TARGET"
  fi
  [ "${WATCHDOG_TEST_FAIL_SIGNAL:-0}" != "1" ] || exit 23
  exit 0
fi
exec "$@"
EOF
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo 'tripwire: sudo invoked' >&2
exit 96
EOF
  cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo 'tripwire: systemctl invoked' >&2
exit 95
EOF
  chmod +x "$BIN/root-cmd" "$BIN/sudo" "$BIN/systemctl"
}

run_case() {
  local expect="$1"
  shift
  local output="$CASE/output" rc=0
  env WATCHDOG_TEST_TRACE="$TRACE" WATCHDOG_TEST_STATE="$CASE/state" \
    WATCHDOG_TEST_COOPERATIVE_STATE="$CASE/cooperative-state" \
    WATCHDOG_TEST_TARGET="$ROOT/etc/watchdog.conf" HOME="$ROOT/tmp" PATH="$BIN:/usr/bin:/bin" \
    APPLY_WATCHDOG_TEST_MODE=1 APPLY_WATCHDOG_ROOT="$ROOT" APPLY_WATCHDOG_ROOT_CMD="$BIN/root-cmd" \
    "$@" bash "$SCRIPT" >"$output" 2>&1 || rc=$?
  case "$expect" in
    success) [ "$rc" -eq 0 ] || { cat "$output" >&2; fail "$CASE expected success (rc=$rc)"; } ;;
    failure) [ "$rc" -ne 0 ] || fail "$CASE expected failure" ;;
    *) fail "unknown expected result: $expect" ;;
  esac
}

assert_output_contains() {
  local needle="$1"
  grep -Fq "$needle" "$CASE/output" || { cat "$CASE/output" >&2; fail "$CASE output missing: $needle"; }
}

set_fixture_xattr() {
  python3 - "$1" <<'PY'
import errno
import os
import sys

try:
    os.setxattr(sys.argv[1], "user.ezgha-fixture", b"preserve-me")
except OSError as error:
    if error.errno in (errno.ENOTSUP, errno.EPERM):
        print("unsupported")
        raise SystemExit(0)
    raise
print("supported")
PY
}

assert_fixture_xattr() {
  python3 - "$1" <<'PY'
import os
import sys
actual = os.getxattr(sys.argv[1], "user.ezgha-fixture")
if actual != b"preserve-me":
    raise SystemExit("xattr value changed")
PY
}

count_active() {
  local key="$1" path="$2"
  awk -v key="$key" '
    /^[[:space:]]*#/ { next }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { count++ }
    END { print count + 0 }
  ' "$path"
}

# Changing the upsert implementation to match prefixes, or to uncomment
# defaults, must fail this case while unrelated configuration remains intact.
make_case success "$REPO_ROOT/scripts/host/watchdog-load-repair.sh"
success_meta="$(stat -c '%a:%u:%g' "$ROOT/etc/watchdog.conf")"
xattr_support="$(set_fixture_xattr "$ROOT/etc/watchdog.conf")"
run_case success env WATCHDOG_TEST_COOPERATIVE_LOCK=1
CONFIG="$ROOT/etc/watchdog.conf"
[ "$(count_active repair-maximum "$CONFIG")" -eq 1 ] || fail "success left duplicate repair-maximum"
[ "$(count_active repair-timeout "$CONFIG")" -eq 1 ] || fail "success left duplicate repair-timeout"
grep -qx '# repair-maximum = 9' "$CONFIG" || fail "success changed commented repair-maximum"
grep -qx '# repair-timeout = 9' "$CONFIG" || fail "success changed commented repair-timeout"
grep -qx 'repair-maximum = 0' "$CONFIG" || fail "success did not install repair-maximum = 0"
grep -qx 'repair-timeout = 60' "$CONFIG" || fail "success did not install repair-timeout = 60"
grep -qx 'repair-maximum-extra = 88' "$CONFIG" || fail "success changed repair-maximum prefix lookalike"
grep -qx 'repair-timeout-extra = 77' "$CONFIG" || fail "success changed repair-timeout prefix lookalike"
[ "$(stat -c '%a:%u:%g' "$CONFIG")" = "$success_meta" ] || fail "success did not preserve target metadata"
[ "$xattr_support" = unsupported ] || assert_fixture_xattr "$CONFIG"
[ "$(cat "$CASE/cooperative-state")" = 1 ] || fail "success did not block cooperative writer before install rename"
grep -Fqx 'killall -HUP watchdog ' "$TRACE" || fail "success did not send a watchdog HUP"
if grep -Eq '(^|[[:space:]])(sudo|systemctl|/etc)([[:space:]/]|$)' "$TRACE"; then
  cat "$TRACE" >&2
  fail "success bypassed the test-mode root/command seams"
fi

# The existing digest-bound assertion is a preflight: an unsafe staged repair
# binary must leave the target byte-for-byte and metadata-identical.
make_case digest_mismatch "$REPO_ROOT/scripts/host/watchdog-load-repair.sh"
printf '#!/usr/bin/env bash\nexit 99\n' > "$ROOT/bad-repair"
chmod +x "$ROOT/bad-repair"
sed -i "s|^repair-binary = .*|repair-binary = $ROOT/bad-repair|" "$ROOT/etc/watchdog.conf"
cp "$ROOT/etc/watchdog.conf" "$CASE/original"
original_meta="$(stat -c '%a:%u:%g' "$ROOT/etc/watchdog.conf")"
run_case failure env
assert_output_contains 'digest mismatch'
cmp -s "$CASE/original" "$ROOT/etc/watchdog.conf" || fail "digest mismatch mutated target bytes"
[ "$(stat -c '%a:%u:%g' "$ROOT/etc/watchdog.conf")" = "$original_meta" ] \
  || fail "digest mismatch mutated target metadata"
if grep -Eq '^mv |^chmod |^chown ' "$TRACE"; then
  fail "digest mismatch reached target mutation"
fi

# A symlink target is not a configuration file transaction target. It must
# fail closed without following or replacing the link.
make_case symlink_refusal "$REPO_ROOT/scripts/host/watchdog-load-repair.sh"
mv "$ROOT/etc/watchdog.conf" "$ROOT/etc/watchdog.real"
ln -s watchdog.real "$ROOT/etc/watchdog.conf"
cp "$ROOT/etc/watchdog.real" "$CASE/original"
run_case failure env
assert_output_contains 'regular file'
[ -L "$ROOT/etc/watchdog.conf" ] || fail "symlink target was replaced"
cmp -s "$CASE/original" "$ROOT/etc/watchdog.real" || fail "symlink referent was changed"

# Diagnostic for an unsupported writer that ignores the mandatory transaction
# lock: the pre-install fingerprint still detects its changed bytes.
make_case preinstall_concurrent "$REPO_ROOT/scripts/host/watchdog-load-repair.sh"
run_case failure env WATCHDOG_TEST_MUTATE_BEFORE_INSTALL=1
assert_output_contains 'changed since staging'
grep -qx 'foreign writer before install' "$ROOT/etc/watchdog.conf" \
  || fail "pre-install concurrent writer was overwritten"

# A failed HUP happens after installation, so the full original snapshot must
# be atomically restored and no reload/restart fallback may be attempted.
make_case signal_failure "$REPO_ROOT/scripts/host/watchdog-load-repair.sh"
cp "$ROOT/etc/watchdog.conf" "$CASE/original"
original_meta="$(stat -c '%a:%u:%g' "$ROOT/etc/watchdog.conf")"
rollback_xattr_support="$(set_fixture_xattr "$ROOT/etc/watchdog.conf")"
run_case failure env WATCHDOG_TEST_FAIL_SIGNAL=1 WATCHDOG_TEST_COOPERATIVE_LOCK=1
cmp -s "$CASE/original" "$ROOT/etc/watchdog.conf" || fail "signal failure did not restore exact target bytes"
[ "$(stat -c '%a:%u:%g' "$ROOT/etc/watchdog.conf")" = "$original_meta" ] \
  || fail "signal failure did not restore target metadata"
[ "$rollback_xattr_support" = unsupported ] || assert_fixture_xattr "$ROOT/etc/watchdog.conf"
[ "$(grep -Fc 'killall -HUP watchdog ' "$TRACE")" -eq 2 ] \
  || fail "signal failure did not HUP the restored config"
[ "$(cat "$CASE/cooperative-state")" = 2 ] \
  || fail "signal failure did not block cooperative writers before install and rollback renames"
if grep -Eq '(^|[[:space:]])(sudo|systemctl|reload|restart|/etc)([[:space:]/]|$)' "$TRACE"; then
  cat "$TRACE" >&2
  fail "signal failure attempted a reload/restart or bypassed test seams"
fi

# Diagnostic for an unsupported writer that ignores the mandatory transaction
# lock after installation: retain its bytes rather than overwrite it blindly.
make_case postinstall_concurrent "$REPO_ROOT/scripts/host/watchdog-load-repair.sh"
run_case failure env WATCHDOG_TEST_FAIL_SIGNAL=1 WATCHDOG_TEST_MUTATE_POST_INSTALL=1
assert_output_contains 'concurrent writer changed target after installation'
grep -qx 'foreign writer after install' "$ROOT/etc/watchdog.conf" \
  || fail "post-install concurrent writer was overwritten by rollback"
[ "$(grep -Fc 'killall -HUP watchdog ' "$TRACE")" -eq 1 ] \
  || fail "concurrent post-install change unexpectedly signaled a rollback"

echo "APPLY_WATCHDOG_NO_REBOOT_VOTE_TEST: PASS"
