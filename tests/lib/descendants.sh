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

# process_identity PID
#   Returns the locale-stable process start time for a currently live PID.
process_identity() {
  local pid="$1" identity rc
  kill -0 "$pid" 2>/dev/null || return 1
  identity="$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  identity="$(printf '%s' "$identity" | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

# identity_matches PID EXPECTED_IDENTITY
identity_matches() {
  local expected="$2" actual
  [ -n "$expected" ] || return 1
  actual="$(process_identity "$1")" || return 1
  [ "$actual" = "$expected" ]
}

# identity_status PID EXPECTED_IDENTITY
#   0 = same process, 1 = gone or known different identity, 2 = identity unknown
identity_status() {
  local pid="$1" expected="$2" actual
  [ -n "$expected" ] || return 2
  actual="$(process_identity "$pid")" || {
    kill -0 "$pid" 2>/dev/null && return 2
    return 1
  }
  [ "$actual" = "$expected" ] && return 0
  return 1
}

# signal_owned_pid SIGNAL PID EXPECTED_IDENTITY
#   Fail closed when the identity is missing, expired, or mismatched.
signal_owned_pid() {
  local signal="$1" pid="$2" expected="$3"
  [ -n "$expected" ] || return 1
  identity_matches "$pid" "$expected" || return 1
  pid_is_running "$pid" || return 1
  kill "-$signal" "$pid" 2>/dev/null
}

# owned_pid_is_running PID EXPECTED_IDENTITY
#   Unknown process state fails closed; a gone or replaced PID is not the
#   recorded fixture process, and an explicit zombie state is already exited.
owned_pid_is_running() {
  local pid="$1" expected="$2" state
  identity_status "$pid" "$expected"
  state=$?
  case "$state" in
    0) pid_is_running "$pid" ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

# teardown_tree PID EXPECTED_IDENTITY
#   Race-free: STOP the leader so it cannot fork, then repeatedly sweep and TERM
#   the whole CURRENT tree, requiring two consecutive empty sweeps; SIGKILL
#   backstop; final re-walk only while the expected leader identity still holds.
#   Returns 0 on success, 5 if discovery failed, 6 if leader identity is absent
#   or no longer matches. Never signal a PID without a verified identity.
teardown_tree() {
  local pid="$1" leader_identity="$2" discovery_ok=1 empty_streak=0 found k i child_identity leader_state
  [ -n "$leader_identity" ] || return 6
  identity_status "$pid" "$leader_identity"
  case "$?" in 0) ;; 1) return 0 ;; *) return 6 ;; esac
  for i in $(seq 1 40); do
    if ! signal_owned_pid STOP "$pid" "$leader_identity"; then
      identity_status "$pid" "$leader_identity"
      leader_state=$?
      [ "$leader_state" -eq 2 ] && discovery_ok=0
      break
    fi
    identity_status "$pid" "$leader_identity"
    leader_state=$?
    [ "$leader_state" -eq 0 ] || { [ "$leader_state" -eq 2 ] && discovery_ok=0; break; }
    descendants_checked "$pid"
    if [ "$DESCENDANTS_RC" -ne 0 ]; then discovery_ok=0; break; fi
    found="$DESCENDANTS_OUT"
    for k in $(printf '%s\n' "$found" | awk '{a[NR]=$0} END{for(j=NR;j>=1;j--) print a[j]}'); do
      child_identity="$(process_identity "$k")" || continue
      signal_owned_pid TERM "$k" "$child_identity" || true
    done
    signal_owned_pid TERM "$pid" "$leader_identity" || true

    identity_status "$pid" "$leader_identity"
    leader_state=$?
    [ "$leader_state" -eq 0 ] || { [ "$leader_state" -eq 2 ] && discovery_ok=0; break; }
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

  identity_status "$pid" "$leader_identity"
  leader_state=$?
  if [ "$leader_state" -eq 0 ]; then
    descendants_checked "$pid"
    [ "$DESCENDANTS_RC" -eq 0 ] || discovery_ok=0
    identity_status "$pid" "$leader_identity"
    leader_state=$?
    if [ "$leader_state" -eq 0 ] && [ "$DESCENDANTS_RC" -eq 0 ]; then
      for k in $DESCENDANTS_OUT; do
        child_identity="$(process_identity "$k")" || continue
        signal_owned_pid KILL "$k" "$child_identity" || true
      done
    elif [ "$leader_state" -eq 2 ]; then
      discovery_ok=0
    fi
  elif [ "$leader_state" -eq 2 ]; then
    discovery_ok=0
  fi
  signal_owned_pid KILL "$pid" "$leader_identity" || true
  wait "$pid" 2>/dev/null || true

  [ "$discovery_ok" -eq 1 ] || return 5
  return 0
}

# pid_is_running PID
#   kill -0 detects an existing process; ps can exclude an exited zombie, which
#   otherwise remains visible to kill -0 until its parent reaps it. An unknown
#   ps result is treated as running unless a second kill -0 sees it gone.
pid_is_running() {
  local state ps_rc
  kill -0 "$1" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$1" 2>/dev/null)"
  ps_rc=$?
  state="$(printf '%s' "$state" | tr -d ' ')"
  if [ "$ps_rc" -eq 0 ] && [ -n "$state" ]; then
    [ "${state#Z}" = "$state" ]
    return $?
  fi
  kill -0 "$1" 2>/dev/null
}
