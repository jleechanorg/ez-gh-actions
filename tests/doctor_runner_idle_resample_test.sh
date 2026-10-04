#!/usr/bin/env bash
# Regression coverage (bead ez-gh-actions-9m8z): a first-pass IDLE slot (a
# container 1-2s old still waiting for GitHub to assign a job) must be
# re-sampled once before it can count as IDLE-STARVED critical, on both the
# local (docker top) and remote (ssh sample) halves.
#  idle->executing clears; idle->idle with a starved queue stays critical;
#  idle->absent follows the existing DOWN path.
# Usage: bash tests/doctor_runner_idle_resample_test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }

# --- fake docker / ssh: per-container sample sequence in $TMP/seq/<name>,
# one state per line (EXEC|IDLE|ABSENT); each `docker inspect` consumes a
# line (the last one repeats) and `docker top` reads the current state. ---
mkdir -p "$TMP/bin" "$TMP/seq" "$TMP/cur"
cat > "$TMP/bin/fake_docker" <<'SH'
#!/usr/bin/env bash
# usage: fake_docker <inspect|top> <name>
verb="$1"; name="$2"
f="$TMP_SEQ/$name"
if [ "$verb" = inspect ]; then
  st=$(head -n1 "$f"); [ "$(wc -l < "$f")" -gt 1 ] && sed -i 1d "$f"
  echo "$st" > "$TMP_CUR/$name"
  [ "$st" = ABSENT ] && echo false || echo true
else
  [ "$(cat "$TMP_CUR/$name")" = EXEC ] && printf 'PID COMMAND\n1 Runner.Worker\n' || printf 'PID COMMAND\n1 Runner.Listener\n'
fi
SH
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  inspect) exec "$TMP_BIN/fake_docker" inspect "${@: -1}" ;;
  top)     exec "$TMP_BIN/fake_docker" top "$2" ;;
esac
SH
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
cmd="${*: -1}"
name=$(grep -o "'[^']*'" <<<"$cmd" | tail -n1 | tr -d "'")
case "$cmd" in
  *"docker inspect"*) "$TMP_BIN/fake_docker" inspect "$name" ;;
  *"docker top"*)     "$TMP_BIN/fake_docker" top "$name" | grep -qw Worker ;;
esac
SH
chmod +x "$TMP/bin/"*
export TMP_SEQ="$TMP/seq" TMP_CUR="$TMP/cur" TMP_BIN="$TMP/bin"

setseq() { rm -f "$TMP/seq/$1"; shift_name="$1"; shift; for s in "$@"; do echo "$s" >> "$TMP/seq/$shift_name"; done; }

# --- extract the real blocks ---
LOCAL_SAMPLE=$(sed -n '/^classify_local_slot() {/,/^info "\$HOST_LABEL slots (local proof)/p' "$ROOT/doctor-runner")
LOCAL_VERDICT=$(sed -n '/^STARVED_PRESENT=0$/,/^\[ "\${#EXECUTING_SLOTS\[@\]}" -gt 0 \] && ok "EXECUTING right now/p' "$ROOT/doctor-runner")
REMOTE_FUNCS=$(sed -n '/^probe_slot_state() {/,/^# Local fleet — whichever/p' "$ROOT/doctor-runner" | sed '$d')
REMOTE_VERDICT=$(sed -n '/^  list_slot_work "\$REMOTE_PREFIX"/,/REMOTE_IDLE_SLOTS\[@\]}))$/p' "$ROOT/doctor-runner"; echo "  fi")
for v in LOCAL_SAMPLE LOCAL_VERDICT REMOTE_FUNCS REMOTE_VERDICT; do
  [ -n "${!v}" ] || { echo "FAIL: $v block not found"; exit 1; }
done

run_local() {  # $1 = queued count, $2 = oldest queued minutes; slot seqs preset
  (
    PATH="$TMP/bin:$PATH"
    PLATFORM=linux; RUNNER_NAME_PREFIX=slot; CONFIGURED_COUNT=1
    DOWN_PERSISTENCE_WAIT_SECONDS=0; RESPAWN_EVIDENCE_WINDOW_MIN=10
    IDLE_STARVED_THRESHOLD_MIN=5; STARVE_QUEUED_COUNT="$1"; STARVE_OLDEST_MIN="$2"
    info() { :; }; bad() { echo "BAD $*"; }; ok() { echo "OK $*"; }; warn() { :; }
    fetch_respawn_log_window() { echo ""; }
    journal_has_respawn_evidence() { echo 0; }
    HOST_LABEL=test
    sleep() { echo SLEEP; }
    eval "$LOCAL_SAMPLE"
    eval "$LOCAL_VERDICT"
    echo "CRITICAL=$SLOT_PROOF_CRITICAL EXEC=${#EXECUTING_SLOTS[@]} IDLE=${#IDLE_SLOTS[@]} DOWN=${#DOWN_SLOTS[@]}"
  ) 2>&1
}

run_remote() {  # $1 = queued count, $2 = oldest queued minutes
  (
    PATH="$TMP/bin:$PATH"
    SECTION10_DOWN_RESAMPLE_SECONDS=0; RESPAWN_EVIDENCE_WINDOW_MIN=10
    IDLE_STARVED_THRESHOLD_MIN=5; STARVE_QUEUED_COUNT="$1"; STARVE_OLDEST_MIN="$2"
    STARVED_PRESENT=0
    if [ "$1" -gt 0 ] && [ "$2" -ge 5 ]; then STARVED_PRESENT=1; fi
    SLOT_PROOF_CRITICAL=0
    REMOTE_PREFIX=rslot; REMOTE_COUNT=1; REMOTE_HOST=macbook; REMOTE_LABEL="macos (macbook)"
    info() { :; }; bad() { echo "BAD $*"; }; ok() { echo "OK $*"; }; warn() { :; }
    remote_docker_env() { printf ''; }
    fetch_respawn_log_window() { echo ""; }
    journal_has_respawn_evidence() { echo 0; }
    job_evidence_for_runner() { echo job; }
    sleep() { echo SLEEP; }
    eval "$REMOTE_FUNCS"
    eval "$REMOTE_VERDICT"
    echo "CRITICAL=$SLOT_PROOF_CRITICAL EXEC=${#REMOTE_EXECUTING_SLOTS[@]} IDLE=${#REMOTE_IDLE_SLOTS[@]} DOWN=${#REMOTE_DOWN_SLOTS[@]}"
  ) 2>&1
}

# ---- local half ----
setseq slot-1 IDLE EXEC
out=$(run_local 12 9)
check "local idle->executing: not critical, counted EXECUTING" "grep -q 'CRITICAL=0 EXEC=1 IDLE=0 DOWN=0' <<<\"\$out\" && ! grep -q '^BAD' <<<\"\$out\""

setseq slot-1 IDLE IDLE
out=$(run_local 12 9)
check "local idle->idle with starved queue: IDLE-STARVED critical" "grep -q 'BAD IDLE-STARVED' <<<\"\$out\" && grep -q 'CRITICAL=1 EXEC=0 IDLE=1 DOWN=0' <<<\"\$out\""

setseq slot-1 IDLE ABSENT
out=$(run_local 12 9)
check "local idle->absent: follows DOWN path (critical DOWN, not IDLE-STARVED)" "grep -q 'BAD DOWN' <<<\"\$out\" && ! grep -q 'IDLE-STARVED' <<<\"\$out\" && grep -q 'CRITICAL=1 EXEC=0 IDLE=0 DOWN=1' <<<\"\$out\""

setseq slot-1 IDLE ABSENT EXEC
out=$(run_local 12 9)
check "local idle->absent->executing (recycle blink): not critical" "grep -q 'CRITICAL=0 EXEC=1 IDLE=0 DOWN=0' <<<\"\$out\" && ! grep -q '^BAD' <<<\"\$out\""

setseq slot-1 IDLE ABSENT ABSENT
out=$(run_local 12 9)
check "local idle->absent waits a SECOND persistence delay before the DOWN re-sample (2 sleeps)" "[ \$(grep -c '^SLEEP' <<<\"\$out\") -eq 2 ]"
check "local idle->absent->absent: persistent DOWN critical" "grep -q 'CRITICAL=1 EXEC=0 IDLE=0 DOWN=1' <<<\"\$out\""

# ---- remote half ----
setseq rslot-1 IDLE EXEC
out=$(run_remote 12 9)
check "remote idle->executing: not critical" "grep -q 'CRITICAL=0 EXEC=1 IDLE=0 DOWN=0' <<<\"\$out\" && ! grep -q '^BAD' <<<\"\$out\""

setseq rslot-1 IDLE IDLE
out=$(run_remote 12 9)
check "remote idle->idle with starved queue: IDLE-STARVED critical" "grep -q 'BAD .*IDLE-STARVED' <<<\"\$out\" && grep -q 'CRITICAL=1 EXEC=0 IDLE=1 DOWN=0' <<<\"\$out\""

setseq rslot-1 IDLE ABSENT
out=$(run_remote 12 9)
check "remote idle->absent: follows DOWN path" "grep -q 'CRITICAL=1 EXEC=0 IDLE=0 DOWN=1' <<<\"\$out\" && grep -q 'BAD .*DOWN' <<<\"\$out\" && ! grep -q 'IDLE-STARVED' <<<\"\$out\""

setseq rslot-1 IDLE ABSENT EXEC
out=$(run_remote 12 9)
check "remote idle->absent->executing (recycle blink): not critical" "grep -q 'CRITICAL=0 EXEC=0 IDLE=0 DOWN=0' <<<\"\$out\" && ! grep -q '^BAD' <<<\"\$out\""

setseq rslot-1 IDLE ABSENT ABSENT
out=$(run_remote 12 9)
check "remote idle->absent waits a SECOND persistence delay before the re-probe (2 sleeps)" "[ \$(grep -c '^SLEEP' <<<\"\$out\") -eq 2 ]"
check "remote idle->absent->absent: persistent DOWN critical" "grep -q 'CRITICAL=1 EXEC=0 IDLE=0 DOWN=1' <<<\"\$out\""

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
