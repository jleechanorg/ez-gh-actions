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

W="$(mktemp -d)"
cleanup() { touch "$W/stop" 2>/dev/null; rm -rf "${W:?}"; }
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

# ---- 5. a TERM-ignoring forker leaves no survivors -----------------------
cat > "$W/forker.sh" <<F
#!/usr/bin/env bash
trap '' TERM
mkdir -p "$W/spawned"
while [ ! -f "$W/stop" ]; do
  ( sleep 5 ) &
  : > "$W/spawned/\$\$-\$RANDOM"
  sleep 0.02
done
F
chmod +x "$W/forker.sh"

"$W/forker.sh" &
FPID=$!
sleep 1
spawns_before="$(ls "$W/spawned" 2>/dev/null | wc -l | tr -d ' ')"
descendants_checked "$FPID"
[ -n "$DESCENDANTS_OUT" ] && pass "5 forker has live children before teardown" \
                          || fail "5 forker had no children; race not exercised"

teardown_rc=0
teardown_tree "$FPID" || teardown_rc=$?
[ "$teardown_rc" -ne 5 ] && pass "5b teardown completed with discovery available" \
                         || fail "5b teardown reported a discovery failure"

spawns_after="$(ls "$W/spawned" 2>/dev/null | wc -l | tr -d ' ')"
[ "${spawns_after:-0}" -gt "${spawns_before:-0}" ] \
  && pass "5c forker kept spawning DURING teardown (race was live)" \
  || fail "5c forker stopped spawning before teardown — race not exercised"

sleep 0.5
descendants_checked "$FPID"
survivors=0
for k in $DESCENDANTS_OUT; do kill -0 "$k" 2>/dev/null && survivors=$((survivors+1)); done
orphans="$(orphan_sleeps || true)"
[ "$survivors" -eq 0 ] && pass "5d no descendant survived a respawning teardown" \
                       || fail "5d descendant(s) survived: $(printf '%s ' $DESCENDANTS_OUT)"
[ -z "$orphans" ] && pass "5e no reparented orphans left behind" \
                  || fail "5e orphaned process(es) reparented to init: $(printf '%s ' $orphans)"

# ---- 6. RED control -----------------------------------------------------
# The OLD snapshot-then-kill logic must FAIL under the same workload, otherwise
# this test would pass for a teardown that does not actually fix the race.
cat > "$W/forker2.sh" <<F
#!/usr/bin/env bash
trap '' TERM
mkdir -p "$W/spawned2"
while [ ! -f "$W/stop2" ]; do
  ( sleep 5 ) &
  : > "$W/spawned2/\$RANDOM"
  sleep 0.02
done
F
chmod +x "$W/forker2.sh"

old_teardown() {  # the ORIGINAL racy implementation
  local pid="$1" kids found
  kids="$(descendants "$pid" || true)"
  for k in $(printf '%s\n' "$kids" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'); do
    kill -TERM "$k" 2>/dev/null || true
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  for k in $kids; do kill -KILL "$k" 2>/dev/null || true; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

orphans_before="$(orphan_sleeps | wc -l | tr -d ' ')"
"$W/forker2.sh" &
F2=$!
sleep 1
old_teardown "$F2"
touch "$W/stop2"
sleep 0.4
orphans_after="$(orphan_sleeps | wc -l | tr -d ' ')"
leaked=$(( ${orphans_after:-0} - ${orphans_before:-0} ))
[ "$leaked" -gt 0 ] && pass "6 RED control: the OLD snapshot teardown leaks ($leaked orphan(s)), so this test discriminates" \
                    || fail "6 RED control did not leak — the test may not be exercising the race"

# tidy any orphans the RED control created
for o in $(orphan_sleeps); do kill -KILL "$o" 2>/dev/null || true; done

touch "$W/stop"
echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
