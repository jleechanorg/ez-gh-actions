#!/usr/bin/env bash
# tests/trim_queued_runs_teardown_race_test.sh
#
# Exercises the REAL teardown implementation used by the progress test
# (tests/lib/descendants.sh) — not a copy. A previous version duplicated the
# logic here, so a green result proved nothing about the shipped code.
#
# Cases (each maps to a finding reproduced in review):
#   1. normal leaf with no children is NOT a discovery error
#      (`if ! got=$(pgrep ...); then rc=$?` captures `!`'s status, 0, not pgrep's 1)
#   2. discovery failure is observable in the CALLER
#      (a flag set inside $( ) mutates a subshell copy and is lost)
#   3. missing pgrep is a discovery failure, not an empty tree
#   4. erroring pgrep is a discovery failure, not an empty tree
#   5. a TERM-triggered child fork after the first snapshot is found and
#      removed by repeated identity-checked tree walks
#   6. controlled snapshot-only teardown leaves its exact late child alive
#      case 5's workload, so this test genuinely discriminates
#
# Usage: bash tests/trim_queued_runs_teardown_race_test.sh
set -uo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=tests/lib/descendants.sh
. "$ROOT/tests/lib/descendants.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

SCRATCH_HELPER="$HOME/.claude/skills/scratch-space/scripts/scratch-dir.sh"
if [ -x "$SCRATCH_HELPER" ]; then
  SCRATCH="$("$SCRATCH_HELPER" ezgha-tests)" || exit 1
else
  SCRATCH="${TMPDIR:-/tmp}"
fi
[ -n "$SCRATCH" ] && [ "$SCRATCH" != / ] || {
  echo "FAIL: unsafe or empty scratch directory" >&2
  exit 1
}
W="$(mktemp -d "$SCRATCH/trim-queued-race.XXXXXX")" || exit 1
[ -n "$W" ] && [ -d "$W" ] && [ "$W" != / ] || {
  echo "FAIL: unable to create safe teardown fixture directory" >&2
  exit 1
}
export W
export ROOT
FPID=""; FPID_ID=""; F2=""; F2_ID=""; SENTINEL=""; SENTINEL_ID=""
LEAF=""; LEAF_ID=""; PS_PROBE_PID=""; PS_PROBE_PID_ID=""
FINAL_PID=""; FINAL_PID_ID=""
stop_fixture_markers() {
  touch "$W/final-stop" "$W/branch-stop" "$W/late-start" 2>/dev/null || true
}
stop_fixture_pids() {
  local pid_file pid identity
  stop_fixture_markers
  [ -n "$LEAF" ] && signal_owned_pid TERM "$LEAF" "$LEAF_ID" || true
  [ -n "$FPID" ] && signal_owned_pid KILL "$FPID" "$FPID_ID" || true
  [ -n "$F2" ] && signal_owned_pid KILL "$F2" "$F2_ID" || true
  [ -n "$SENTINEL" ] && signal_owned_pid TERM "$SENTINEL" "$SENTINEL_ID" || true
  [ -n "$PS_PROBE_PID" ] && signal_owned_pid TERM "$PS_PROBE_PID" "$PS_PROBE_PID_ID" || true
  [ -n "$FINAL_PID" ] && signal_owned_pid KILL "$FINAL_PID" "$FINAL_PID_ID" || true
  for pid_file in "$W/spawned-pids" "$W/owned-pids2" "$W/final-child-identities"; do
    if [ -f "$pid_file" ]; then
      while IFS='|' read -r pid identity; do
        [ -n "$pid" ] && [ -n "$identity" ] \
          && signal_owned_pid KILL "$pid" "$identity" || true
      done < "$pid_file"
    fi
  done
  for pid in "$LEAF" "$FPID" "$F2" "$SENTINEL" "$PS_PROBE_PID" "$FINAL_PID"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
cleanup() {
  stop_fixture_markers
  [ -n "$FINAL_PID" ] && [ -n "$FINAL_PID_ID" ] \
    && { teardown_tree "$FINAL_PID" "$FINAL_PID_ID" || true; wait "$FINAL_PID" 2>/dev/null || true; } \
    || true
  FINAL_PID=""; FINAL_PID_ID=""
  [ -n "$FPID" ] && [ -n "$FPID_ID" ] \
    && { teardown_tree "$FPID" "$FPID_ID" || true; wait "$FPID" 2>/dev/null || true; } \
    || true
  FPID=""; FPID_ID=""
  [ -n "$F2" ] && [ -n "$F2_ID" ] \
    && { teardown_tree "$F2" "$F2_ID" || true; wait "$F2" 2>/dev/null || true; } \
    || true
  F2=""; F2_ID=""
  stop_fixture_pids
  rm -rf "${W:?}"
}
trap cleanup EXIT

# ---- 1. a normal leaf with no children is NOT a discovery error -----------
sleep 30 &
LEAF=$!
LEAF_ID="$(process_identity "$LEAF")" || fail "1 leaf identity could not be captured"
descendants_checked "$LEAF"
if [ "$DESCENDANTS_RC" -eq 0 ]; then
  pass "1 leaf with no children => discovery ok (not a false error)"
else
  fail "1 leaf with no children was misreported as a discovery error (rc=$DESCENDANTS_RC)"
fi
[ -z "$DESCENDANTS_OUT" ] && pass "1b leaf has empty descendant list" \
                          || fail "1b unexpected descendants for a leaf: $DESCENDANTS_OUT"
signal_owned_pid TERM "$LEAF" "$LEAF_ID" || true
wait "$LEAF" 2>/dev/null || true
LEAF=""; LEAF_ID=""

# ---- 2/3/4. discovery failures must be observable in the CALLER ----------
mkdir -p "$W/bin-missing" "$W/bin-error"
printf '#!/usr/bin/env bash\nexit 9\n' > "$W/bin-error/pgrep"
chmod +x "$W/bin-error/pgrep"

# 3: pgrep absent entirely. Use /bin/bash explicitly because an empty PATH also
#    hides bash itself, and BASH_ENV may otherwise re-add the real PATH.
( PATH="$W/bin-missing" /bin/bash --noprofile --norc -c '
  unset BASH_ENV
  . "$1"
  descendants_checked 1
  echo "$DESCENDANTS_RC"' _ "$ROOT/tests/lib/descendants.sh" ) > "$W/rc_missing" 2>/dev/null
rc_missing="$(tail -1 "$W/rc_missing" 2>/dev/null | tr -dc '0-9')"
[ -n "$rc_missing" ] && [ "$rc_missing" -ne 0 ] \
  && pass "3 missing pgrep reported via caller rc=$rc_missing" \
  || fail "3 missing pgrep was NOT reported (rc='${rc_missing:-empty}' => vacuous pass)"

# 4: pgrep present but erroring
( PATH="$W/bin-error:$PATH" /bin/bash --noprofile --norc -c '
  unset BASH_ENV
  . "$1"
  descendants_checked 1
  echo "$DESCENDANTS_RC"' _ "$ROOT/tests/lib/descendants.sh" ) > "$W/rc_error" 2>/dev/null
rc_error="$(tail -1 "$W/rc_error" 2>/dev/null | tr -dc '0-9')"
[ -n "$rc_error" ] && [ "$rc_error" -ne 0 ] \
  && pass "4 erroring pgrep reported via caller rc=$rc_error" \
  || fail "4 erroring pgrep was NOT reported (rc='${rc_error:-empty}' => vacuous pass)"

# 2: the flag must reach the caller (no subshell loss)
# 2: the status must reach the CALLER of descendants_checked. Run it directly in
# this shell (no command substitution around the call) against a pgrep stub that
# errors, and confirm DESCENDANTS_RC is non-zero in THIS shell.
saved_path="$PATH"
PATH="$W/bin-error:$PATH"
unset BASH_ENV
descendants_checked 1
rc_direct="$DESCENDANTS_RC"
PATH="$saved_path"
[ "${rc_direct:-0}" -ne 0 ] \
  && pass "2 discovery status reaches the caller (rc=$rc_direct, no subshell loss)" \
  || fail "2 discovery status was lost in a subshell (rc=$rc_direct)"

# 7: an error on the final post-loop discovery must still reach the caller.
cat > "$W/final-discovery-leader.sh" <<'F'
#!/usr/bin/env bash
trap '' TERM
touch "$W/final-leader-ready"
while [ ! -f "$W/final-stop" ]; do
  sleep 0.05 &
  child=$!
  printf '%s\n' "$child" >> "$W/final-child-pids"
  LC_ALL=C ps -o lstart= -p "$child" | tr -s ' ' > "$W/final-child-identity"
  IFS= read -r child_identity < "$W/final-child-identity"
  printf '%s|%s\n' "$child" "$child_identity" >> "$W/final-child-identities"
  wait "$child"
done
F
chmod +x "$W/final-discovery-leader.sh"
"$W/final-discovery-leader.sh" &
FINAL_PID=$!
FINAL_PID_ID="$(process_identity "$FINAL_PID")" || fail "7 leader identity could not be captured"
for _ in $(seq 1 100); do
  [ -f "$W/final-leader-ready" ] && break
  sleep 0.01
done
[ -f "$W/final-leader-ready" ] || fail "7 leader did not install its TERM handler"
final_descendant_checks=0
descendants_checked() {
  final_descendant_checks=$((final_descendant_checks+1))
  if [ "$final_descendant_checks" -eq 81 ]; then
    DESCENDANTS_OUT=""
    DESCENDANTS_RC=4
    return 0
  fi
  DESCENDANTS_OUT="$(descendants "$1")"
  DESCENDANTS_RC=$?
  return 0
}
teardown_tree "$FINAL_PID" "$FINAL_PID_ID" || rc_final=$?
touch "$W/final-stop" 2>/dev/null || true
wait "$FINAL_PID" 2>/dev/null || true
FINAL_PID=""; FINAL_PID_ID=""
descendants_checked() {
  DESCENDANTS_OUT="$(descendants "$1")"
  DESCENDANTS_RC=$?
  return 0
}
[ "${rc_final:-0}" -eq 5 ] \
  && pass "7 final discovery error is returned as teardown failure" \
  || fail "7 final discovery error was lost (teardown rc=${rc_final:-0})"

# 8: unknown ps output must fail closed for a live owned PID; a confirmed Z
#    state is treated as exited even while kill -0 still sees the zombie.
mkdir -p "$W/bin-ps-error" "$W/bin-ps-zombie"
printf '#!/usr/bin/env bash\nexit 9\n' > "$W/bin-ps-error/ps"
printf '#!/usr/bin/env bash\nprintf Z\\n\n' > "$W/bin-ps-zombie/ps"
chmod +x "$W/bin-ps-error/ps" "$W/bin-ps-zombie/ps"
sleep 30 &
PS_PROBE_PID=$!
PS_PROBE_PID_ID="$(process_identity "$PS_PROBE_PID")" || fail "8 ps probe identity could not be captured"
saved_path="$PATH"
PATH="$W/bin-ps-error:$PATH"
if pid_is_running "$PS_PROBE_PID"; then
  pass "8 failed ps keeps a live fixture PID classified as running"
else
  fail "8 failed ps misclassified a live fixture PID as stopped"
fi
PATH="$W/bin-ps-zombie:$PATH"
if pid_is_running "$PS_PROBE_PID"; then
  fail "8 explicit Z state was classified as running"
else
  pass "8 explicit Z state is classified as exited"
fi
PATH="$saved_path"
signal_owned_pid TERM "$PS_PROBE_PID" "$PS_PROBE_PID_ID" || true
wait "$PS_PROBE_PID" 2>/dev/null || true
PS_PROBE_PID=""; PS_PROBE_PID_ID=""

# ---- 5. candidate teardown captures a controlled late child --------------
cat > "$W/branch.sh" <<'F'
#!/usr/bin/env bash
on_term() {
  sleep 20 &
  child=$!
  printf '%s\n' "$child" > "$W/late-child-pid"
  LC_ALL=C ps -o lstart= -p "$child" | tr -s ' ' > "$W/late-child-identity"
  touch "$W/late-child-ready"
  trap '' TERM
  wait "$child"
}
trap on_term TERM
touch "$W/branch-ready"
while [ ! -f "$W/branch-stop" ]; do sleep 0.05; done
F
cat > "$W/forker.sh" <<'F'
#!/usr/bin/env bash
trap ':' TERM
"$W/branch.sh" &
branch=$!
printf '%s\n' "$branch" > "$W/branch-pid"
while [ ! -f "$W/branch-ready" ]; do sleep 0.01; done
touch "$W/leader-ready"
wait "$branch"
F
chmod +x "$W/forker.sh" "$W/branch.sh"

"$W/forker.sh" &
FPID=$!
FPID_ID="$(process_identity "$FPID")" || fail "5 leader identity could not be captured"
for _ in $(seq 1 100); do
  [ -f "$W/leader-ready" ] && break
  sleep 0.01
done
[ -f "$W/leader-ready" ] || fail "5 branch fixture did not reach its idle wait point"
branch_pid="$(cat "$W/branch-pid" 2>/dev/null || true)"
branch_identity="$(process_identity "$branch_pid")" || fail "5 branch identity could not be captured (pid=$branch_pid, live=$(kill -0 "$branch_pid" 2>/dev/null && echo yes || echo no), ps=$(LC_ALL=C ps -o lstart= -p "$branch_pid" 2>/dev/null))"
printf '%s|%s\n' "$branch_pid" "$branch_identity" > "$W/spawned-pids"
descendants_checked "$FPID"
[ -n "$DESCENDANTS_OUT" ] && pass "5 forker has live children before teardown" \
                          || fail "5 forker had no children; race not exercised"
[ ! -f "$W/late-child-ready" ] && pass "5 controlled child has not forked before teardown" \
                               || fail "5 late child was created before teardown began"

teardown_rc=0
teardown_tree "$FPID" "$FPID_ID" || teardown_rc=$?
wait "$FPID" 2>/dev/null || true
FPID=""; FPID_ID=""
[ "$teardown_rc" -eq 0 ] && pass "5b teardown completed with discovery available" \
                         || fail "5b teardown failed (rc=$teardown_rc)"
for _ in $(seq 1 100); do
  [ -f "$W/late-child-ready" ] && break
  sleep 0.01
done
[ -f "$W/late-child-ready" ] \
  && pass "5c candidate workload forked a child after the initial snapshot" \
  || fail "5c candidate workload did not produce its controlled late child"
late_child_pid="$(cat "$W/late-child-pid" 2>/dev/null || true)"
late_child_identity=""
if [ -f "$W/late-child-identity" ]; then
  late_child_identity="$(tr -s ' ' < "$W/late-child-identity" | sed 's/^ *//;s/ *$//')"
fi
[ -n "$late_child_pid" ] && [ -n "$late_child_identity" ] \
  && printf '%s|%s\n' "$late_child_pid" "$late_child_identity" >> "$W/spawned-pids"
cp "$W/spawned-pids" "$W/finished-pids"
[ -s "$W/finished-pids" ] \
  && pass "5d teardown assertions use the complete finished PID log" \
  || fail "5d complete fixture PID log is empty"
survivors=0
while IFS='|' read -r k identity; do
  [ -n "$k" ] && [ -n "$identity" ] && owned_pid_is_running "$k" "$identity" \
    && survivors=$((survivors+1))
done < "$W/finished-pids"
[ "$survivors" -eq 0 ] && pass "5e no identity-recorded fixture process survived teardown" \
                       || fail "5e $survivors recorded fixture process(es) survived teardown"

# A live test-owned sentinel outside the teardown target tests identity gates.
sleep 20 &
SENTINEL=$!
SENTINEL_ID="$(process_identity "$SENTINEL")" || fail "5 sentinel identity could not be captured"
teardown_tree "$SENTINEL" "${SENTINEL_ID}-mismatch" || rc_mismatch=$?
[ "${rc_mismatch:-0}" -eq 0 ] && identity_matches "$SENTINEL" "$SENTINEL_ID" \
  && pass "5f mismatched teardown leader identity skipped the unrelated sentinel" \
  || fail "5f mismatched teardown identity did not fail closed"
if signal_owned_pid TERM "$SENTINEL" "${SENTINEL_ID}-mismatch"; then
  fail "5g mismatched identity signaled the unrelated controlled sentinel"
else
  pass "5g mismatched identity refused to signal the sentinel"
fi
if signal_owned_pid TERM "$SENTINEL" ""; then
  fail "5h missing identity signaled the unrelated controlled sentinel"
else
  pass "5h missing identity refused to signal the sentinel"
fi
identity_matches "$SENTINEL" "$SENTINEL_ID" && pid_is_running "$SENTINEL" \
  && pass "5i unrelated controlled sentinel remains alive after rejected signals" \
  || fail "5i identity rejection did not preserve the unrelated sentinel"

# ---- 6. RED control -----------------------------------------------------
# The OLD snapshot-then-kill logic must miss a deliberately late, logged child.
cat > "$W/forker2.sh" <<'F'
#!/usr/bin/env bash
trap '' TERM
touch "$W/forker2-ready"
while [ ! -f "$W/late-start" ]; do sleep 0.05; done
sleep 20 &
child=$!
printf '%s\n' "$child" > "$W/old-child-pid"
LC_ALL=C ps -o lstart= -p "$child" | tr -s ' ' > "$W/old-child-identity"
touch "$W/late-child-ready"
wait
F
chmod +x "$W/forker2.sh"

old_teardown() {  # original snapshot logic with a deterministic late-child release
  local pid="$1" leader_identity="$2" kids k identity
  kids="$(descendants "$pid" || true)"
  : > "$W/snapshot-identities"
  for k in $kids; do
    identity="$(process_identity "$k")" || continue
    printf '%s|%s\n' "$k" "$identity" >> "$W/snapshot-identities"
  done
  touch "$W/late-start"
  for _ in $(seq 1 100); do
    [ -f "$W/late-child-ready" ] && break
    sleep 0.01
  done
  while IFS='|' read -r k identity; do
    [ -n "$k" ] && [ -n "$identity" ] && signal_owned_pid TERM "$k" "$identity" || true
  done < "$W/snapshot-identities"
  signal_owned_pid TERM "$pid" "$leader_identity" || true
  sleep 0.2
  while IFS='|' read -r k identity; do
    [ -n "$k" ] && [ -n "$identity" ] && signal_owned_pid KILL "$k" "$identity" || true
  done < "$W/snapshot-identities"
  signal_owned_pid KILL "$pid" "$leader_identity" || true
  wait "$pid" 2>/dev/null || true
}

"$W/forker2.sh" &
F2=$!
F2_ID="$(process_identity "$F2")" || fail "6 fixture leader identity could not be captured"
for _ in $(seq 1 100); do
  [ -f "$W/forker2-ready" ] && break
  sleep 0.01
done
[ -f "$W/forker2-ready" ] || fail "6 fixture leader did not reach its controlled wait point"
old_teardown "$F2" "$F2_ID"
wait "$F2" 2>/dev/null || true
F2=""; F2_ID=""
old_child_pid="$(cat "$W/old-child-pid" 2>/dev/null || true)"
old_child_identity="$(tr -s ' ' < "$W/old-child-identity" 2>/dev/null | sed 's/^ *//;s/ *$//')"
[ -n "$old_child_pid" ] && [ -n "$old_child_identity" ] \
  && printf '%s|%s\n' "$old_child_pid" "$old_child_identity" > "$W/owned-pids2"
cp "$W/owned-pids2" "$W/owned-pids2-finished"
[ -s "$W/owned-pids2-finished" ] \
  && pass "6 snapshot-only control created a logged late child" \
  || fail "6 snapshot-only control did not create its fixture child"
survivors=0
while IFS='|' read -r k identity; do
  [ -n "$k" ] && [ -n "$identity" ] && owned_pid_is_running "$k" "$identity" \
    && survivors=$((survivors+1))
done < "$W/owned-pids2-finished"
[ "$survivors" -gt 0 ] \
  && pass "6 snapshot-only regression leaves the exact late child alive" \
  || fail "6 snapshot-only regression did not leave the recorded child alive"

stop_fixture_pids
SENTINEL=""; SENTINEL_ID=""
LEAF=""; LEAF_ID=""; PS_PROBE_PID=""; PS_PROBE_PID_ID=""
echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
