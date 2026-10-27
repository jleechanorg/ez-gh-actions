#!/usr/bin/env bash
# Hermetic coverage for runner-offline-queued-alert.sh: gh and gcloud are stubbed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/runner-offline-queued-alert.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }; pass() { echo "PASS: $*"; }
cat > "$W/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *actions/runners*) [ -z "${STUB_RUNNER:-}" ] || echo "$STUB_RUNNER" ;;
  *actions/runs*) [ -z "${STUB_QUEUED_AT:-}" ] || printf '%s\n' $STUB_QUEUED_AT ;;
esac
STUB
cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
STUB
chmod +x "$W/gh" "$W/gcloud"
run() { # name; env set by caller
  STATE_FILE="$W/state-$1.json" STUB_LOG="$W/log-$1" GH_BIN="$W/gh" GCLOUD_BIN="$W/gcloud" "$S" "${@:2}" >/dev/null 2>&1 || true
}
old=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sent() { [ -f "$W/log-$1" ] && grep -c 'severity=ERROR' "$W/log-$1" || echo 0; }

STUB_RUNNER=offline STUB_QUEUED_AT=$old run a
[ "$(sent a)" = 1 ] || fail "offline + old queued run must alert"; pass "offline + old queue alerts"
STUB_RUNNER=offline STUB_QUEUED_AT=$old run a
[ "$(sent a)" = 1 ] || fail "second run inside cooldown must be throttled"; pass "throttled within cooldown"
STUB_RUNNER=online STUB_QUEUED_AT=$old run a
grep -q 'severity=INFO' "$W/log-a" || fail "recovery must write INFO"; pass "recovery logged"
STUB_RUNNER=online STUB_QUEUED_AT=$old run b; [ "$(sent b)" = 0 ] || fail "online runner must not alert"; pass "online no alert"
STUB_RUNNER=offline STUB_QUEUED_AT= run c; [ "$(sent c)" = 0 ] || fail "empty queue must not alert"; pass "offline + empty queue no alert"
STUB_RUNNER=offline STUB_QUEUED_AT=$new run d; [ "$(sent d)" = 0 ] || fail "young queue must not alert"; pass "young queue no alert"
STUB_RUNNER= STUB_QUEUED_AT=$old run e; [ "$(sent e)" = 1 ] || fail "unregistered runner (missing) must alert"; pass "missing runner alerts"
STUB_RUNNER=online run f --simulate-offline; [ "$(sent f)" = 1 ] || fail "--simulate-offline must alert"; pass "simulate-offline alerts"
run g --test-sms; grep -q TEST "$W/log-g" || fail "--test-sms must write a TEST entry"; pass "test-sms writes TEST entry"
STUB_RUNNER=offline STUB_QUEUED_AT=$old run h --dry-run; [ ! -f "$W/log-h" ] || fail "--dry-run must not call gcloud"; pass "dry-run silent"
