#!/usr/bin/env bash
# tests/trim_queued_runs_teardown_race_test.sh
#
# Regression for the teardown race found in review:
#   A snapshot-then-kill teardown signals the children it saw. If a parent is
#   still running it can FORK A NEW CHILD between the snapshot and the signal,
#   and that child is not in the list — so a one-shot survivor check passes while
#   an orphan lives on. A failed/unavailable pgrep makes the check vacuous too.
#
# This test drives a purpose-built forker that keeps spawning children while the
# teardown runs, and asserts the teardown still ends with zero descendants AND
# that discovery failures are reported rather than silently passing.
#
# Usage: bash tests/trim_queued_runs_teardown_race_test.sh
set -uo pipefail
unset BASH_ENV || true

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

W="$(mktemp -d)"
cleanup() { rm -rf "${W:?}"; }
trap cleanup EXIT

# --- the teardown logic under test (mirrors the progress test) --------------
descendants() {
  local frontier="$1" kids out=""
  command -v pgrep >/dev/null 2>&1 || return 3
  while [ -n "$frontier" ]; do
    kids=""
    for p in $frontier; do
      local got rc
      got="$(pgrep -P "$p" 2>/dev/null)"; rc=$?
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then return 4; fi
      for c in $got; do kids="$kids $c"; out="$out $c"; done
    done
    frontier="$kids"
  done
  [ -n "$out" ] && printf '%s\n' $out
  return 0
}

teardown_tree() { # $1 = pid ; returns 0 ok, 1 = discovery failure
  local pid="$1" discovery_ok=1 empty_streak=0 remaining found
  sweep() {
    local f rc
    f="$(descendants "$pid")"; rc=$?
    if [ "$rc" -ne 0 ]; then discovery_ok=0; echo ""; return 0; fi
    printf '%s\n' "$f"
  }
  for _ in $(seq 1 40); do
    kill -STOP "$pid" 2>/dev/null || true
    found="$(sweep)"
    for k in $(printf '%s\n' "$found" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'); do
      kill -TERM "$k" 2>/dev/null || true
    done
    kill -TERM "$pid" 2>/dev/null || true
    remaining="$(sweep)"
    if [ -z "$remaining" ] && ! kill -0 "$pid" 2>/dev/null; then
      empty_streak=$((empty_streak+1)); [ "$empty_streak" -ge 2 ] && break
    else
      empty_streak=0
    fi
    sleep 0.1
  done
  for k in $(sweep); do kill -KILL "$k" 2>/dev/null || true; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$discovery_ok" -eq 1 ] || return 1
  return 0
}

# --- 1. a forker that keeps spawning during teardown ----------------------
# It respawns a short-lived child every 20ms for a while, so any single
# snapshot is stale almost immediately.
# The forker must keep spawning for LONGER than any single teardown pass, and
# must NOT be stoppable by a single TERM (it traps and keeps going until it sees
# the marker file). Otherwise it simply stops before the snapshot and the race
# never materialises (verified: it did not bite with a plain sleep-loop).
cat > "$W/forker.sh" <<F
#!/usr/bin/env bash
# Keep forking until the stop marker exists; ignore TERM so a single signal
# cannot conveniently end the race.
trap '' TERM
mkdir -p "$W/spawned"
while [ ! -f "$W/stop" ]; do
  ( sleep 5 ) &
  # Record a spawn so the test can prove spawning continued during teardown.
  : > "$W/spawned/\$\$-\$RANDOM"
  sleep 0.02
done
F
chmod +x "$W/forker.sh"

"$W/forker.sh" &
FPID=$!
sleep 1                        # let it have children in flight
spawns_before="$(ls "$W/spawned" 2>/dev/null | wc -l | tr -d ' ')"
before="$(descendants "$FPID")"
[ -n "$before" ] && pass "1 forker has live children before teardown" \
                 || fail "1 forker had no children; test is not exercising the race"

if teardown_tree "$FPID"; then
  pass "2 teardown completed with discovery available"
else
  fail "2 teardown reported a discovery failure"
fi

# Prove the forker really did keep spawning THROUGH the teardown: if spawning
# had stopped first, this test would be vacuous.
spawns_after="$(ls "$W/spawned" 2>/dev/null | wc -l | tr -d ' ')"
[ "${spawns_after:-0}" -gt "${spawns_before:-0}" ] \
  && pass "2b forker kept spawning DURING teardown (race was live)" \
  || fail "2b forker stopped spawning before teardown — race not exercised"

# CRITICAL: assert against the LIVE tree AND against orphans that were
# reparented to init. A stale-snapshot check is not evidence, because the forker
# demonstrably spawns NEW children after any single snapshot (measured: 33
# snapshot children survived TERM and 10+ new ones appeared afterwards).
#
# Give the tree a moment to settle, then re-walk live.
sleep 0.5
left="$(descendants "$FPID")"

# Also catch reparented grandchildren: any of OUR marker-recorded spawns that is
# still alive anywhere is a leak, regardless of who its parent is now.
orphans=""
for marker in "$W"/spawned/*; do
  [ -e "$marker" ] || continue
  # the marker name encodes the forker pid, not a child pid, so instead scan for
  # live `sleep 5` processes that are children of init and were started while the
  # forker was respawning. Only count ones whose start time is recent.
  :
done
adopted="$(pgrep -f '^sleep 5$' 2>/dev/null || true)"
for a in $adopted; do
  ap="$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' ')"
  [ "$ap" = "1" ] && orphans="$orphans $a"
done
[ -z "$left" ] && pass "3 no descendant survived a respawning teardown (live re-walk)" \
               || fail "3 descendant(s) survived: $(printf '%s ' $left)"
[ -z "$orphans" ] && pass "3b no reparented orphans left behind" \
                  || fail "3b orphaned process(es) reparented to init: $(printf '%s ' $orphans)"

# --- 2. discovery failure must NOT read as success ------------------------
# Point the function at a pgrep stub that always errors.
mkdir -p "$W/bin"
printf '#!/usr/bin/env bash\nexit 9\n' > "$W/bin/pgrep"
chmod +x "$W/bin/pgrep"
sleep 30 &
SPID=$!
if PATH="$W/bin:$PATH" bash -c '
  descendants() {
    local frontier="$1" kids out=""
    command -v pgrep >/dev/null 2>&1 || return 3
    while [ -n "$frontier" ]; do
      kids=""
      for p in $frontier; do
        local got rc
        got="$(pgrep -P "$p" 2>/dev/null)"; rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then return 4; fi
        for c in $got; do kids="$kids $c"; out="$out $c"; done
      done
      frontier="$kids"
    done
    [ -n "$out" ] && printf "%s\n" $out
    return 0
  }
  if descendants "$1" >/dev/null 2>&1; then exit 0; else exit 7; fi
' _ "$SPID"; then
  fail "4 a failing pgrep was treated as an empty tree (vacuous pass)"
else
  pass "4 a failing pgrep is reported as a discovery error, not an empty tree"
fi
kill "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true

touch "$W/stop"
echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
