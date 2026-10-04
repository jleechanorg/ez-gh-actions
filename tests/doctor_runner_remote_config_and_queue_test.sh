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
  *count*) [ "${FAKE_SSH_CFG:-fail}" = ok ] && { echo "${FAKE_SSH_COUNT:-6}"; exit 0; }; exit 255 ;;
esac
exit 255
SH
chmod +x "$TMP/bin/ssh"

BLOCK=$(sed -n '/^REMOTE_UNREACHABLE=0/,/^export REMOTE_UNREACHABLE/p' "$ROOT/doctor-runner" | sed '$d')
[ -n "$BLOCK" ] || { echo "FAIL: remote block not found"; exit 1; }

run_remote() {  # env assignments passed through the environment
  (
    PATH="$TMP/bin:$PATH"
    PLATFORM="${T_PLATFORM:-linux}"; REMOTE_HOST=macbook; REMOTE_LABEL="macos (macbook)"
    REMOTE_PREFIX="${T_PREFIX:-}"; REMOTE_COUNT="${T_COUNT:-}"
    DEFAULT_LINUX_RUNNER_COUNT=14; DEFAULT_MAC_RUNNER_COUNT=6
    SLOT_PROOF_CRITICAL=0; STARVED_PRESENT=0; REMOTE_DOWN_SLOTS=(); REMOTE_EXECUTING_SLOTS=(); REMOTE_IDLE_SLOTS=(); REMOTE_CYCLING_SLOTS=()
    info() { :; }; bad() { echo "BAD $*"; }; ok() { echo "OK $*"; }; warn() { :; }
    list_slot_work() { echo "LIST $1 $2"; LAST_EXECUTING_SLOTS=(); LAST_IDLE_SLOTS=(); LAST_CYCLING_SLOTS=(); LAST_DOWN_SLOTS=(); }
    eval "$BLOCK"
    echo "CRITICAL=$SLOT_PROOF_CRITICAL DOWN=${#REMOTE_DOWN_SLOTS[@]} UNPROVEN=$REMOTE_CONFIG_UNPROVEN NAMES=${REMOTE_DOWN_SLOTS[*]:-}"
  ) 2>&1
}

out=$(FAKE_SSH_CFG=fail run_remote)
check "unreadable config -> UNPROVEN [BAD] line" "grep -q 'BAD .*remote fleet UNPROVEN' <<<\"\$out\""
check "no fabricated ez-mac-runner-e slots" "! grep -q 'ez-mac-runner-e' <<<\"\$out\""
check "no slot listing attempted" "! grep -q '^LIST' <<<\"\$out\""
check "unproven remote: contract (6) slots counted DOWN + critical, headline reflects gap" "grep -q 'CRITICAL=6 DOWN=6 UNPROVEN=1' <<<\"\$out\" && grep -q '<unknown-prefix>-6 (unproven)' <<<\"\$out\""
check "stale hardcoded prefix defaults removed" "! grep -q 'ez-mac-runner-e' '$ROOT/doctor-runner'"

out=$(FAKE_SSH_CFG=ok run_remote)
check "readable config at contract -> real prefix/count used" "grep -q 'LIST ez-mac-runner-g 6' <<<\"\$out\" && ! grep -q '^BAD' <<<\"\$out\""

# Finding A: a remote Mac count of 5 below the six-slot contract must not pass.
out=$(FAKE_SSH_CFG=ok FAKE_SSH_COUNT=5 run_remote)
check "config count 5 < contract 6 -> [BAD] underprovisioned" "grep -q 'BAD .*remote config count 5 is below the fleet contract 6 — underprovisioned' <<<\"\$out\""
check "underprovisioned inspects contract (6) slots, not 5" "grep -q 'LIST ez-mac-runner-g 6' <<<\"\$out\" && ! grep -q 'LIST ez-mac-runner-g 5' <<<\"\$out\""
check "underprovisioned counts a slot-proof critical" "grep -q 'CRITICAL=1 ' <<<\"\$out\""

out=$(FAKE_SSH_CFG=fail T_PREFIX=ez-mac-runner-g T_COUNT=6 run_remote)
check "env overrides (prefix+count at contract) bypass lookup" "grep -q 'LIST ez-mac-runner-g 6' <<<\"\$out\" && grep -q 'UNPROVEN=0' <<<\"\$out\""

# Finding A (Linux side): a remote Linux count below 14 is underprovisioned too.
out=$(FAKE_SSH_CFG=ok FAKE_SSH_COUNT=13 T_PLATFORM=macos run_remote)
check "linux config count 13 < contract 14 -> [BAD] underprovisioned" "grep -q 'BAD .*remote config count 13 is below the fleet contract 14 — underprovisioned' <<<\"\$out\" && grep -q 'LIST ez-mac-runner-g 14' <<<\"\$out\""

# Item 2: an explicit override below the contract is flagged too (it may raise the count, never lower it).
out=$(FAKE_SSH_CFG=fail T_PREFIX=ez-mac-runner-g T_COUNT=5 run_remote)
check "override count 5 < contract 6 -> underprovisioned, contract slots inspected, critical" "grep -q 'underprovisioned' <<<\"\$out\" && grep -q 'LIST ez-mac-runner-g 6' <<<\"\$out\" && grep -q 'CRITICAL=1 ' <<<\"\$out\""
out=$(FAKE_SSH_CFG=fail T_PREFIX=ez-mac-runner-g T_COUNT=8 run_remote)
check "override count 8 > contract raises capacity, not flagged" "! grep -q underprovisioned <<<\"\$out\" && grep -q 'LIST ez-mac-runner-g 8' <<<\"\$out\" && grep -q 'CRITICAL=0 ' <<<\"\$out\""

# Finding B: unreachable remote with empty prefix/count never greens, never builds "-1" names.
cat > "$TMP/bin/ssh_down" <<'SH'
#!/usr/bin/env bash
exit 255
SH
chmod +x "$TMP/bin/ssh_down"; cp "$TMP/bin/ssh" "$TMP/bin/ssh_real"; cp "$TMP/bin/ssh_down" "$TMP/bin/ssh"
out=$(run_remote)
check "unreachable + no override -> critical >= contract count" "grep -q 'CRITICAL=6 DOWN=6 ' <<<\"\$out\""
check "unreachable + no override -> no empty-prefix slot names" "! grep -qE 'NAMES=(-| )|[ =]-[0-9]+ \\(unreachable' <<<\"\$out\""
out=$(T_COUNT=8 run_remote)
check "unreachable, count but no prefix -> placeholder prefix, critical 8" "grep -q 'CRITICAL=8 DOWN=8 ' <<<\"\$out\" && grep -q 'NAMES=<unknown-prefix>-1 ' <<<\"\$out\" && ! grep -qE '[ =]-[0-9]+ \\(unreachable' <<<\"\$out\""
# Item 3: explicit count 0 with unreachable remote still adds criticals.
out=$(T_PREFIX=ez-mac-runner-g T_COUNT=0 run_remote)
check "unreachable + count 0 -> critical >= 1 (contract floor)" "grep -qE 'CRITICAL=([1-9][0-9]*) ' <<<\"\$out\""
cp "$TMP/bin/ssh_real" "$TMP/bin/ssh"

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

# Item 1: `gh api` failing inside queue-health.sh must not kill the caller
# under `set -u` (unset QUEUE_* after a failed python eval) -- sections 9/10 must run.
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: simulated API failure" >&2
exit 1
SH
chmod +x "$TMP/bin/gh"
set +e
qout=$(
  set -euo pipefail
  PATH="$TMP/bin:$PATH"
  SCRIPT_DIR="$ROOT"
  JOBLEVEL_QUEUED_COUNT=3 JOBLEVEL_OLDEST_QUEUED_MIN=45 JOBLEVEL_FETCH_ERRORS=0
  export JOBLEVEL_QUEUED_COUNT JOBLEVEL_OLDEST_QUEUED_MIN JOBLEVEL_FETCH_ERRORS
  eval "$QSNIP"
  echo "REACHED_NEXT_SECTION QUEUE_RC=$QUEUE_RC QUEUE_TAIL_BAD=$QUEUE_TAIL_BAD"
) 2>&1
rc=$?
set -e
check "failing gh: doctor continues past queue block (rc=0)" "[ $rc -eq 0 ]"
check "failing gh: next section reached, queue block non-green (QUEUE_RC=2)" "grep -q 'REACHED_NEXT_SECTION QUEUE_RC=2 QUEUE_TAIL_BAD=1' <<<\"\$qout\""
check "failing gh: no unbound-variable abort" "! grep -q 'unbound variable' <<<\"\$qout\""

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
