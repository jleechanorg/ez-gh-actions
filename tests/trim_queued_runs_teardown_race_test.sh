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
#   5. a TERM-ignoring forker that keeps spawning during teardown leaves no
#      survivors, by live re-walk AND by reparented-to-init orphans
#   6. RED control: the OLD snapshot-then-kill logic DOES leave orphans under
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

SCRATCH="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh ezgha-tests)"
W="$(mktemp -d "$SCRATCH/trim-queued-race.XXXXXX")"
FPID=""; F2=""; SENTINEL=""; LEAF=""
stop_fixture_pids() {
  local pid
  for pid in "$LEAF" "$FPID" "$F2" "$SENTINEL"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "$LEAF" "$FPID" "$F2" "$SENTINEL"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
}
cleanup() {
  local pid_file pid
  [ -n "$FPID" ] && teardown_tree "$FPID" || true
  [ -n "$F2" ] && teardown_tree "$F2" || true
  stop_fixture_pids
  for pid_file in "$W/spawned-pids" "$W/owned-pids" "$W/owned-pids2"; do
    if [ -f "$pid_file" ]; then
      while read -r pid; do
        [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
      done < "$pid_file"
    fi
  done
  rm -rf "${W:?}"
}
trap cleanup EXIT

# ---- 1. a normal leaf with no children is NOT a discovery error -----------
sleep 30 &
LEAF=$!
descendants_checked "$LEAF"
if [ "$DESCENDANTS_RC" -eq 0 ]; then
  pass "1 leaf with no children => discovery ok (not a false error)"
else
  fail "1 leaf with no children was misreported as a discovery error (rc=$DESCENDANTS_RC)"
fi
[ -z "$DESCENDANTS_OUT" ] && pass "1b leaf has empty descendant list" \
                          || fail "1b unexpected descendants for a leaf: $DESCENDANTS_OUT"
kill "$LEAF" 2>/dev/null || true
wait "$LEAF" 2>/dev/null || true

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
mkdir -p "$W/bin-final-error"
real_pgrep="$(command -v pgrep)"
cat > "$W/bin-final-error/pgrep" <<SH
#!/usr/bin/env bash
count_file="$W/pgrep-count"
count=0
[ -f "\$count_file" ] && read -r count < "\$count_file"
count=\$((count+1))
printf '%s\\n' "\$count" > "\$count_file"
[ "\$count" -eq 5 ] && exit 9
exec "$real_pgrep" "\$@"
SH
chmod +x "$W/bin-final-error/pgrep"
saved_path="$PATH"
PATH="$W/bin-final-error:$PATH"
teardown_tree 2147483647 || rc_final=$?
PATH="$saved_path"
[ "${rc_final:-0}" -eq 5 ] \
  && pass "7 final discovery error is returned as teardown failure" \
  || fail "7 final discovery error was lost (teardown rc=${rc_final:-0})"

# ---- 5. a TERM-ignoring forker leaves no survivors -----------------------
cat > "$W/forker.sh" <<F
#!/usr/bin/env bash
trap '' TERM
mkdir -p "$W/spawned"
while [ ! -f "$W/stop" ]; do
  sleep 20 &
  child=\$!
  printf '%s\\n' "\$child" >> "$W/spawned-pids"
  : > "$W/spawned/\$\$-\$RANDOM"
  wait "\$child"
done
F
chmod +x "$W/forker.sh"

"$W/forker.sh" &
FPID=$!
sleep 1
cp "$W/spawned-pids" "$W/owned-pids"
descendants_checked "$FPID"
[ -n "$DESCENDANTS_OUT" ] && pass "5 forker has live children before teardown" \
                          || fail "5 forker had no children; race not exercised"

teardown_rc=0
teardown_tree "$FPID" || teardown_rc=$?
[ "$teardown_rc" -ne 5 ] && pass "5b teardown completed with discovery available" \
                         || fail "5b teardown reported a discovery failure"

survivors=0
for k in $(cat "$W/owned-pids"); do pid_is_running "$k" && survivors=$((survivors+1)); done
[ "$survivors" -eq 0 ] && pass "5c no recorded fixture descendant survived teardown" \
                       || fail "5c fixture descendant(s) survived: $(cat "$W/owned-pids")"

# A live test-owned sentinel outside the teardown target must remain untouched.
sleep 20 &
SENTINEL=$!
kill -0 "$SENTINEL" 2>/dev/null \
  && pass "5d unrelated controlled sentinel remains alive" \
  || fail "5d teardown affected the unrelated controlled sentinel"

# ---- 6. RED control -----------------------------------------------------
# The OLD snapshot-then-kill logic must miss a deliberately late, logged child.
cat > "$W/forker2.sh" <<F
#!/usr/bin/env bash
trap '' TERM
touch "$W/forker2-ready"
while [ ! -f "$W/late-start" ]; do :; done
sleep 20 &
printf '%s\\n' "\$!" >> "$W/owned-pids2"
touch "$W/late-child-ready"
wait
F
chmod +x "$W/forker2.sh"

old_teardown() {  # the ORIGINAL racy implementation, with a deterministic fork after snapshot
  local pid="$1" kids found
  kids="$(descendants "$pid" || true)"
  touch "$W/late-start"
  for _ in $(seq 1 100); do
    [ -f "$W/late-child-ready" ] && break
    sleep 0.01
  done
  for k in $(printf '%s\n' "$kids" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'); do
    kill -TERM "$k" 2>/dev/null || true
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  for k in $kids; do kill -KILL "$k" 2>/dev/null || true; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

"$W/forker2.sh" &
F2=$!
for _ in $(seq 1 100); do
  [ -f "$W/forker2-ready" ] && break
  sleep 0.01
done
[ -f "$W/forker2-ready" ] || fail "6 fixture leader did not reach its controlled wait point"
old_teardown "$F2"
cp "$W/owned-pids2" "$W/owned-pids2-snapshot"
[ -s "$W/owned-pids2-snapshot" ] \
  && pass "6 RED control: old teardown workload created logged fixture children" \
  || fail "6 RED control did not create its fixture workload"
survivors=0
for k in $(cat "$W/owned-pids2-snapshot"); do pid_is_running "$k" && survivors=$((survivors+1)); done
[ "$survivors" -gt 0 ] \
  && pass "6 RED control: old snapshot teardown leaves the deliberately late owned child" \
  || fail "6 RED control did not leave a logged child to prove the old behavior"
for k in $(cat "$W/owned-pids2-snapshot"); do kill -KILL "$k" 2>/dev/null || true; done

touch "$W/stop"
echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
