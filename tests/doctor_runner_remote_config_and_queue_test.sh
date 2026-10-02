#!/usr/bin/env bash
# Regression coverage (bead ez-gh-actions-4tbi):
#  1. Remote config unreadable over SSH -> UNPROVEN [BAD] line, NO fabricated
#     hardcoded-prefix slots (the 2026-10-02 ez-mac-runner-e-* phantom DOWN slots).
#  2. Explicit env overrides still bypass the lookup.
#  3. A failing queue-tail block (sourced scripts/queue-health.sh returning 1)
#     must not abort doctor-runner before section 10.
# Usage: bash tests/doctor_runner_remote_config_and_queue_test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }

# --- fake ssh: `true` succeeds; config greps fail (slow/unreadable) or answer ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
cmd="${*: -1}"
case "$cmd" in
  true) exit 0 ;;
  *name_prefix*) [ "${FAKE_SSH_CFG:-fail}" = ok ] && { echo "ez-mac-runner-g"; exit 0; }; exit 255 ;;
  *count*) [ "${FAKE_SSH_CFG:-fail}" = ok ] && { echo 5; exit 0; }; exit 255 ;;
esac
exit 255
SH
chmod +x "$TMP/bin/ssh"

BLOCK=$(sed -n '/^REMOTE_UNREACHABLE=0/,/^export REMOTE_UNREACHABLE/p' "$ROOT/doctor-runner" | sed '$d')
[ -n "$BLOCK" ] || { echo "FAIL: remote block not found"; exit 1; }

run_remote() {  # env assignments passed through the environment
  (
    PATH="$TMP/bin:$PATH"
    PLATFORM=linux; REMOTE_HOST=macbook; REMOTE_LABEL="macos (macbook)"
    REMOTE_PREFIX="${T_PREFIX:-}"; REMOTE_COUNT="${T_COUNT:-}"
    DEFAULT_LINUX_RUNNER_COUNT=10; DEFAULT_MAC_RUNNER_COUNT=6
    SLOT_PROOF_CRITICAL=0; STARVED_PRESENT=0; REMOTE_DOWN_SLOTS=(); REMOTE_EXECUTING_SLOTS=(); REMOTE_IDLE_SLOTS=(); REMOTE_CYCLING_SLOTS=()
    info() { :; }; bad() { echo "BAD $*"; }; ok() { echo "OK $*"; }; warn() { :; }
    list_slot_work() { echo "LIST $1 $2"; LAST_EXECUTING_SLOTS=(); LAST_IDLE_SLOTS=(); LAST_CYCLING_SLOTS=(); LAST_DOWN_SLOTS=(); }
    eval "$BLOCK"
    echo "CRITICAL=$SLOT_PROOF_CRITICAL DOWN=${#REMOTE_DOWN_SLOTS[@]} UNPROVEN=$REMOTE_CONFIG_UNPROVEN"
  ) 2>&1
}

out=$(FAKE_SSH_CFG=fail run_remote)
check "unreadable config -> UNPROVEN [BAD] line" "grep -q 'BAD .*remote fleet UNPROVEN' <<<\"\$out\""
check "no fabricated ez-mac-runner-e slots" "! grep -q 'ez-mac-runner-e' <<<\"\$out\""
check "no slot listing attempted" "! grep -q '^LIST' <<<\"\$out\""
check "verdict stays non-green (critical>0), no DOWN slots" "grep -q 'CRITICAL=1 DOWN=0 UNPROVEN=1' <<<\"\$out\""
check "stale hardcoded prefix defaults removed" "! grep -q 'ez-mac-runner-e' '$ROOT/doctor-runner'"

out=$(FAKE_SSH_CFG=ok run_remote)
check "readable config -> real prefix/count used" "grep -q 'LIST ez-mac-runner-g 5' <<<\"\$out\""

out=$(FAKE_SSH_CFG=fail T_PREFIX=ez-mac-runner-g T_COUNT=5 run_remote)
check "env overrides bypass lookup" "grep -q 'LIST ez-mac-runner-g 5' <<<\"\$out\" && grep -q 'UNPROVEN=0' <<<\"\$out\""

# --- queue block must not abort the caller ---
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo '{"workflow_runs": [], "total_count": 0}'
SH
chmod +x "$TMP/bin/gh"
QSNIP=$(sed -n '/^QUEUE_TAIL_BAD=0$/,/^# --- F3\./p' "$ROOT/doctor-runner" | sed '$d')
[ -n "$QSNIP" ] || { echo "FAIL: queue block not found"; exit 1; }
set +e
qout=$(
  set -euo pipefail
  PATH="$TMP/bin:$PATH"
  SCRIPT_DIR="$ROOT"
  JOBLEVEL_QUEUED_COUNT=3 JOBLEVEL_OLDEST_QUEUED_MIN=45 JOBLEVEL_FETCH_ERRORS=0
  export JOBLEVEL_QUEUED_COUNT JOBLEVEL_OLDEST_QUEUED_MIN JOBLEVEL_FETCH_ERRORS
  eval "$QSNIP"
  echo "REACHED_NEXT_SECTION QUEUE_TAIL_BAD=$QUEUE_TAIL_BAD"
) 2>&1
rc=$?
set -e
check "queue tail BAD line printed" "grep -q 'queue tail (job-level)' <<<\"\$qout\""
check "doctor continues past failing queue block (rc=0)" "[ $rc -eq 0 ]"
check "next section reached with QUEUE_TAIL_BAD=1" "grep -q 'REACHED_NEXT_SECTION QUEUE_TAIL_BAD=1' <<<\"\$qout\""

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
