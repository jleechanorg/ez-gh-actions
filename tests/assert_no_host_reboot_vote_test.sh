#!/usr/bin/env bash
# Repo-side contract: watchdog repair must not vote for a host reboot.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

out="$(bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh")"
echo "$out" | grep -q 'PASS: no-host-reboot-vote contract holds' \
  || { echo "FAIL: expected PASS line, got: $out" >&2; exit 1; }

# Negative: a copy that still votes reboot must fail closed (and print FAIL, not silent set -e).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/host" "$tmp/config"
cp "${REPO_ROOT}/scripts/host/watchdog-load-repair.sh" "$tmp/scripts/host/"
cp "${REPO_ROOT}/config/watchdog.conf" "$tmp/config/"
FIXTURE_REPAIR="$tmp/repair.sh"
cp "${REPO_ROOT}/scripts/host/watchdog-load-repair.sh" "$FIXTURE_REPAIR"
chmod +x "$FIXTURE_REPAIR"
printf '\nlog result reboot-eligible "test fixture"\nexit 1\n' >> "$tmp/scripts/host/watchdog-load-repair.sh"
neg_rc=0
neg_out="$(REPO_ROOT="$tmp" bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh" 2>&1)" || neg_rc=$?
[ "$neg_rc" -ne 0 ] || { echo "FAIL: fixture with reboot-eligible should fail" >&2; exit 1; }
echo "$neg_out" | grep -q 'FAIL: .* still logs reboot-eligible' \
  || { echo "FAIL: expected explicit FAIL line, got: $neg_out" >&2; exit 1; }

# Exercise the live-check branch against fixtures only. The assertion defaults
# to /etc/watchdog.conf in production; WATCHDOG_CONF_PATH is the test seam.
assert_live_fixture() {
  local contents="$1" expected="$2" label="$3" rc=0 fixture_out
  printf '%s\nrepair-binary = %s\n' "$contents" "$FIXTURE_REPAIR" > "$tmp/watchdog.conf"
  fixture_out="$(ASSERT_LIVE_WATCHDOG=1 WATCHDOG_CONF_PATH="$tmp/watchdog.conf" \
    REPO_ROOT="$REPO_ROOT" bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh" 2>&1)" || rc=$?
  if [ "$expected" = pass ]; then
    [ "$rc" -eq 0 ] || { echo "FAIL: $label should pass: $fixture_out" >&2; exit 1; }
  else
    [ "$rc" -ne 0 ] || { echo "FAIL: $label should fail closed" >&2; exit 1; }
    echo "$fixture_out" | grep -q 'FAIL:' \
      || { echo "FAIL: $label did not emit explicit FAIL: $fixture_out" >&2; exit 1; }
  fi
}

assert_live_fixture $'# comment\nrepair-maximum = 0\n' pass 'one active zero'
assert_live_fixture '# no active repair maximum' fail 'missing repair-maximum'
assert_live_fixture 'repair-maximum = 1' fail 'nonzero repair-maximum'
assert_live_fixture $'repair-maximum = 0\nrepair-maximum = 0' fail 'duplicate repair-maximum'

# The live parser must also fail closed for absent, duplicate, unreadable, or
# unsafe repair-binary paths.  All fixtures are temporary files; no /etc or
# watchdog service state is touched.
printf 'repair-maximum = 0\n' > "$tmp/missing-binary.conf"
rc=0
WATCHDOG_CONF_PATH="$tmp/missing-binary.conf" ASSERT_LIVE_WATCHDOG=1 REPO_ROOT="$REPO_ROOT" \
  bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: missing repair-binary should fail" >&2; exit 1; }

printf 'repair-maximum = 0\nrepair-binary = %s\nrepair-binary = %s\n' "$FIXTURE_REPAIR" "$FIXTURE_REPAIR" > "$tmp/duplicate-binary.conf"
rc=0
WATCHDOG_CONF_PATH="$tmp/duplicate-binary.conf" ASSERT_LIVE_WATCHDOG=1 REPO_ROOT="$REPO_ROOT" \
  bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: duplicate repair-binary should fail" >&2; exit 1; }

printf 'repair-maximum = 0\nrepair-binary = %s\n' "$tmp/unreadable-repair.sh" > "$tmp/unreadable-binary.conf"
rc=0
WATCHDOG_CONF_PATH="$tmp/unreadable-binary.conf" ASSERT_LIVE_WATCHDOG=1 REPO_ROOT="$REPO_ROOT" \
  bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: unreadable repair-binary should fail" >&2; exit 1; }

BAD_REPAIR="$tmp/unsafe-repair.sh"
cp "$FIXTURE_REPAIR" "$BAD_REPAIR"
printf '\nlog result reboot-eligible "fixture"\n' >> "$BAD_REPAIR"
chmod +x "$BAD_REPAIR"
printf 'repair-maximum = 0\nrepair-binary = %s\n' "$BAD_REPAIR" > "$tmp/mismatched-binary.conf"
rc=0
WATCHDOG_CONF_PATH="$tmp/mismatched-binary.conf" ASSERT_LIVE_WATCHDOG=1 REPO_ROOT="$REPO_ROOT" \
  bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: unsafe configured repair-binary should fail" >&2; exit 1; }

# Rehearse the actual watchdog contract against a configured fixture binary.
# Every external operation is a failing stub and all paths point into $tmp;
# watchdog must still see a zero status when shedding cannot proceed.  This
# exercises the root-invoked failure branches without touching a live unit.
STUB="$tmp/invocation-stub"
mkdir -p "$STUB"
for cmd in systemctl docker limactl timeout; do
  cat > "$STUB/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB/$cmd"
done
invocation_log="$tmp/invocation.log"
printf 'MemAvailable: 1 kB\n' > "$tmp/low-meminfo"
printf 'some avg10=99 avg60=99 avg300=99 total=1\n' > "$tmp/high-psi"
invocation_rc=0
REPAIR_ALLOW_NONROOT=1 REPAIR_LOG_FILE="$invocation_log" \
  REPAIR_MEMINFO_FILE="$tmp/low-meminfo" REPAIR_PSI_FILE="$tmp/high-psi" \
  REPAIR_MANAGED_CONTAINERS='runner-fixture' REPAIR_QEMU_PID=999999 \
  REPAIR_USER="$USER" REPAIR_USER_HOME="$HOME" REPAIR_VERIFY_WINDOW_SECONDS=0 \
  REPAIR_VERIFY_INTERVAL_SECONDS=0 REPAIR_LIMA_STOP_TIMEOUT_SECONDS=1 \
  PATH="$STUB:$PATH" "$FIXTURE_REPAIR" >/dev/null 2>&1 || invocation_rc=$?
[ "$invocation_rc" -eq 0 ] || { echo "FAIL: configured watchdog invocation returned nonzero ($invocation_rc)" >&2; exit 1; }
grep -q '"stage":"result"' "$invocation_log" \
  || { echo "FAIL: configured invocation did not reach a terminal result" >&2; exit 1; }

echo "ASSERT_NO_HOST_REBOOT_VOTE_TEST: PASS"
