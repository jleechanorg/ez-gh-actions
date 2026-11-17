#!/usr/bin/env bash
# tests/lib/descendants.sh — SINGLE shared implementation of descendant
# discovery + race-free teardown, sourced by both the progress test and its
# regression. Having one copy is the point: an earlier version duplicated the
# logic in the test, so the regression's green result did not prove anything
# about the code actually used (review finding).
#
# Bug classes this encodes (all reproduced in review):
#   1. `if ! got=$(pgrep -P "$p"); then rc=$?` captures the status of `!`, i.e.
#      0, not pgrep's 1. A normal leaf would then look like a discovery ERROR.
#      Fix: assign first, then inspect rc.
#   2. A function that sets a flag and is invoked inside $( ) mutates a SUBSHELL
#      copy, so the parent's flag never changes and a failure is reported as
#      success. Fix: discovery status is returned via the function's EXIT CODE
#      and consumed by the caller without command substitution swallowing it.
#   3. A one-shot snapshot misses children a parent forks afterwards. Fix:
#      repeated sweeps with the leader STOPped, requiring consecutive empty
#      sweeps.

# descendants PID
#   stdout: one pid per line, parents before children
#   return: 0 ok (empty output is legitimate), 3 pgrep unavailable, 4 pgrep error
descendants() {
  local frontier="$1" kids out="" p c got rc
  command -v pgrep >/dev/null 2>&1 || return 3
  while [ -n "$frontier" ]; do
    kids=""
    for p in $frontier; do
      got="$(pgrep -P "$p" 2>/dev/null)"
      rc=$?                          # status of pgrep itself (NOT of a `!` test)
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        return 4                     # 1 = no children (fine); anything else = error
      fi
      for c in $got; do
        kids="$kids $c"
        out="$out $c"
      done
    done
    frontier="$kids"
  done
  [ -n "$out" ] && printf '%s\n' $out
  return 0
}

# descendants_checked PID
#   Sets DESCENDANTS_OUT and DESCENDANTS_RC in the CALLER (no subshell), so a
#   discovery failure is observable. Never invoke this inside $( ... ).
descendants_checked() {
  DESCENDANTS_OUT="$(descendants "$1")"
  DESCENDANTS_RC=$?
  return 0
}

# teardown_tree PID
#   Race-free: STOP the leader so it cannot fork, then repeatedly sweep and TERM
#   the whole CURRENT tree, requiring two consecutive empty sweeps; SIGKILL
#   backstop; final re-walk after the leader is gone.
#   Returns 0 on success, 5 if process discovery was unavailable/erroring.
teardown_tree() {
  local pid="$1" discovery_ok=1 empty_streak=0 found k i
  for i in $(seq 1 40); do
    kill -STOP "$pid" 2>/dev/null || true
    descendants_checked "$pid"
    if [ "$DESCENDANTS_RC" -ne 0 ]; then discovery_ok=0; break; fi
    found="$DESCENDANTS_OUT"
    for k in $(printf '%s\n' "$found" | awk '{a[NR]=$0} END{for(j=NR;j>=1;j--) print a[j]}'); do
      kill -TERM "$k" 2>/dev/null || true
    done
    kill -TERM "$pid" 2>/dev/null || true

    descendants_checked "$pid"
    [ "$DESCENDANTS_RC" -ne 0 ] && { discovery_ok=0; break; }
    if [ -z "$DESCENDANTS_OUT" ] && ! kill -0 "$pid" 2>/dev/null; then
      empty_streak=$((empty_streak+1))
      [ "$empty_streak" -ge 2 ] && break
    else
      empty_streak=0
    fi
    sleep 0.1
  done

  descendants_checked "$pid"
  [ "$DESCENDANTS_RC" -eq 0 ] || discovery_ok=0
  for k in $DESCENDANTS_OUT; do kill -KILL "$k" 2>/dev/null || true; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ "$discovery_ok" -eq 1 ] || return 5
  return 0
}

# pid_is_running PID
#   kill -0 detects an existing process; ps excludes an exited zombie, which
#   otherwise remains visible to kill -0 until its parent reaps it.
pid_is_running() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$state" ] && [ "${state#Z}" = "$state" ]
}
