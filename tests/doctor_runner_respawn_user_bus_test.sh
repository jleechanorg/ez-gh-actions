#!/usr/bin/env bash
# Executed regression: fetch_respawn_log_window()'s remote `journalctl --user`
# query must establish the systemd user bus before asking for the daemon log.
#
# Bead: jleechan-edzc (follow-up to PR #241 / d683733, which fixed the same
# class in remote_docker_env).
#
# The defect this pins:
#
#   ssh jeff-ubuntu 'journalctl --user -u ezgha.service --since "3 minutes ago"'
#     -> Failed to connect to bus: No medium found        (rc=1)
#
# A non-interactive ssh command inherits no login session, so neither
# XDG_RUNTIME_DIR nor DBUS_SESSION_BUS_ADDRESS is set. The fetch therefore
# failed for EVERY remote slot, `_respawn_fetch_failed` was always 1, and a
# genuinely churning remote slot could never be told apart from an abandoned
# one: it was finalized DOWN with only the honest-but-useless
# "(respawn-log fetch failed)" annotation. The class fix was partial — the
# identical transport was fixed in remote_docker_env (PR #241) and left broken
# here.
#
# This test EXECUTES the real functions and the real remote-fleet journal
# cross-check block extracted from doctor-runner (sed markers, no
# re-implementation) against an ssh/journalctl shim that refuses exactly as
# systemd's user manager does until BOTH variables are exported for the
# VERIFIED uid. It fails on the pre-fix blob and passes with the fix:
#
#   1. the remote fetch returns the daemon log (bus established, uid-correct)
#   2. a churning remote slot classifies CYCLING, not DOWN
#   3. fail-closed is preserved: an ssh/journald outage still yields DOWN with
#      the fetch-failed annotation, never a fabricated CYCLING
#   4. `${VAR:-default}` is honoured: an exported value wins over the default
#
# Usage: bash tests/doctor_runner_respawn_user_bus_test.sh
#   DOCTOR_RUNNER_UNDER_TEST=/path/to/doctor-runner  to point at another blob
#   (e.g. `git show <base>:doctor-runner` to reproduce the RED).
set -euo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="${DOCTOR_RUNNER_UNDER_TEST:-$ROOT/doctor-runner}"
[ -f "$D" ] || { echo "FAIL: doctor-runner not found at $D" >&2; exit 1; }
bash -n "$D" || { echo "FAIL: doctor-runner has a syntax error" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/bin"

fail() {
  echo "FAIL: $*" >&2
  echo '      (the remote journalctl query must export XDG_RUNTIME_DIR and' >&2
  echo '       DBUS_SESSION_BUS_ADDRESS for the verified uid INSIDE the ssh' >&2
  echo '       command — bead jleechan-edzc)' >&2
  exit 1
}

# --- shims ---------------------------------------------------------------
# timeout: none of these shims can hang, and a missing/odd `timeout` (macOS)
# must not turn this into a different test.
cat > "$TMP/bin/timeout" <<'SH'
#!/usr/bin/env bash
shift            # drop the duration
exec "$@"
SH

# ssh: run the remote command with no user bus, exactly like a non-interactive
# ssh invocation. SSH_PRESET_BUS_ROOT simulates a login session that DID inherit
# a bus; SSH_FORCE_FAIL simulates an ssh/journald outage.
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
[ -n "${SSH_FORCE_FAIL:-}" ] && exit 1
cmd="${*: -1}"
if [ -n "${SSH_PRESET_BUS_ROOT:-}" ]; then
  env HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" \
      XDG_RUNTIME_DIR="$SSH_PRESET_BUS_ROOT" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$SSH_PRESET_BUS_ROOT/bus" \
      bash -c "$cmd"
else
  env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS HOME="$TMP_HOME" \
      PATH="$TMP_BIN:$PATH" bash -c "$cmd"
fi
SH

# journalctl: refuse like the real user manager when the bus is absent, and
# refuse values that are not THIS user's runtime dir (a hardcoded guess must
# not pass).
cat > "$TMP/bin/journalctl" <<'SH'
#!/usr/bin/env bash
printf 'XDG_RUNTIME_DIR=%s\nDBUS_SESSION_BUS_ADDRESS=%s\n' \
  "${XDG_RUNTIME_DIR-<unset>}" "${DBUS_SESSION_BUS_ADDRESS-<unset>}" >> "$JOURNALCTL_LOG"
want_root="${EXPECT_BUS_ROOT:-/run/user/$(id -u)}"
if [ "${XDG_RUNTIME_DIR:-}" != "$want_root" ] \
   || [ "${DBUS_SESSION_BUS_ADDRESS:-}" != "unix:path=${want_root}/bus" ]; then
  echo 'Failed to connect to bus: No medium found' >&2
  exit 1
fi
case "$*" in
  '--user -u ezgha.service --since '*)
    printf '%s\n' \
      'Nov 20 10:00:00 jeff-ubuntu ezgha[1]: respawned ephemeral runner ez-runner-c-1' \
      'Nov 20 10:00:01 jeff-ubuntu ezgha[1]: respawned ephemeral runner ez-runner-c-9'
    ;;
  *)
    echo "unexpected journalctl arguments: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$TMP/bin/"*

export TMP_BIN="$TMP/bin" TMP_HOME="$TMP/home" JOURNALCTL_LOG="$TMP/journalctl-calls"
mkdir -p "$TMP_HOME"
: > "$JOURNALCTL_LOG"
export PATH="$TMP/bin:$PATH"

# --- extract the real code under test ------------------------------------
FUNC_SRC=$(sed -n '/^journal_has_respawn_evidence() {/,/^# Resolve the local config path and runner prefix BEFORE/p' "$D" | sed '$d')
grep -q '^fetch_respawn_log_window() {' <<<"$FUNC_SRC" \
  || { echo 'FAIL: could not locate fetch_respawn_log_window() in doctor-runner' >&2; exit 1; }
grep -q '^journal_has_respawn_evidence() {' <<<"$FUNC_SRC" \
  || { echo 'FAIL: could not locate journal_has_respawn_evidence() in doctor-runner' >&2; exit 1; }

# The remote-fleet journal cross-check block (the DOWN -> CYCLING promotion).
BLOCK_SRC=$(sed -n '/# Journal cross-check (ez-gh-actions-5n0h)/,/^      done$/p' "$D")
grep -q 'if ! _log=$(fetch_respawn_log_window "$host" "$_remote_platform"' <<<"$BLOCK_SRC" \
  || { echo 'FAIL: extracted remote journal cross-check block is stale (no guarded fetch call)' >&2; exit 1; }

run_block_body() {
  # These are consumed by the eval'd doctor-runner block, not here.
  # shellcheck disable=SC2034
  local -a slot_state=('' 'DOWN')
  # shellcheck disable=SC2034
  local count=1 prefix='ez-runner-c' host='linux-host' label='LINUX' name
  info() { :; }
  bad() { :; }
  # shellcheck disable=SC2034  # read by fetch_respawn_log_window's default arg
  RESPAWN_EVIDENCE_WINDOW_MIN=3
  eval "$BLOCK_SRC"
  printf 'STATE=%s\n' "${slot_state[1]:-}"
  printf 'FETCH_FAILED=%s\n' "${_respawn_fetch_failed:-unset}"
}

block_state() {
  ( set -euo pipefail
    eval "$FUNC_SRC"
    run_block_body
  )
}

echo '--- doctor-runner respawn-log user-bus regression (bead jleechan-edzc) ---'

# 1. The remote fetch must succeed over a non-interactive ssh transport.
set +e
fetch_out=$( ( set -euo pipefail
               eval "$FUNC_SRC"
               fetch_respawn_log_window 'linux-host' linux 3 ) 2>/dev/null )
fetch_rc=$?
set -e
[ "$fetch_rc" -eq 0 ] || fail "fetch_respawn_log_window returned $fetch_rc over a non-interactive ssh"
grep -q 'respawned ephemeral runner ez-runner-c-1' <<<"$fetch_out" \
  || fail 'fetch_respawn_log_window returned no daemon log lines'
echo 'PASS: remote journalctl query establishes the user bus and returns the log'

# 1b. ...and it used THIS user's runtime dir, not a hardcoded guess.
grep -Fxq "XDG_RUNTIME_DIR=/run/user/$(id -u)" "$JOURNALCTL_LOG" \
  || { echo "FAIL: journalctl did not receive this user's XDG_RUNTIME_DIR" >&2; cat "$JOURNALCTL_LOG" >&2; exit 1; }
grep -Fxq "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus" "$JOURNALCTL_LOG" \
  || { echo 'FAIL: journalctl did not receive the matching DBUS_SESSION_BUS_ADDRESS' >&2; cat "$JOURNALCTL_LOG" >&2; exit 1; }
echo 'PASS: the bus points at the verified uid (no hardcoded runtime dir)'

# 2. A churning remote slot must classify CYCLING, not DOWN.
result=$(block_state) || fail 'the remote journal cross-check block aborted'
[ "$(sed -n 's/^STATE=//p' <<<"$result")" = 'CYCLING' ] \
  || fail "a churning remote slot classified $(sed -n 's/^STATE=//p' <<<"$result") instead of CYCLING"
[ "$(sed -n 's/^FETCH_FAILED=//p' <<<"$result")" = '0' ] \
  || fail 'the churning slot was annotated as a respawn-log fetch failure'
echo 'PASS: containerless remote slot with respawn evidence classifies CYCLING'

# 3. Fail-closed: an ssh outage is still "no evidence" -> DOWN, flagged.
: > "$JOURNALCTL_LOG"
export SSH_FORCE_FAIL=1
result=$(block_state) || fail 'the remote journal cross-check block aborted on an ssh failure'
unset SSH_FORCE_FAIL
[ "$(sed -n 's/^STATE=//p' <<<"$result")" = 'DOWN' ] \
  || fail "an unreadable daemon log classified $(sed -n 's/^STATE=//p' <<<"$result") instead of DOWN"
[ "$(sed -n 's/^FETCH_FAILED=//p' <<<"$result")" = '1' ] \
  || fail 'the fetch failure was not recorded for the DOWN evidence annotation'
[ ! -s "$JOURNALCTL_LOG" ] || { echo 'FAIL: journalctl was reached despite the ssh failure' >&2; exit 1; }
echo 'PASS: fail-closed preserved — an unreadable log stays DOWN and is flagged'

# 4. `${VAR:-default}`: an inherited bus value must win over the default.
: > "$JOURNALCTL_LOG"
preset_root="$TMP/preset-runtime"
export SSH_PRESET_BUS_ROOT="$preset_root" EXPECT_BUS_ROOT="$preset_root"
set +e
fetch_out=$( ( set -euo pipefail
               eval "$FUNC_SRC"
               fetch_respawn_log_window 'linux-host' linux 3 ) 2>/dev/null )
preset_rc=$?
set -e
unset SSH_PRESET_BUS_ROOT EXPECT_BUS_ROOT
[ "$preset_rc" -eq 0 ] || fail 'fetch_respawn_log_window failed when the transport already had a bus'
grep -Fxq "XDG_RUNTIME_DIR=$preset_root" "$JOURNALCTL_LOG" \
  || { echo 'FAIL: an inherited XDG_RUNTIME_DIR was overwritten by the default' >&2; cat "$JOURNALCTL_LOG" >&2; exit 1; }
echo 'PASS: an inherited bus value wins over the default (${VAR:-default})'

echo 'ALL PASS: the remote respawn-log query establishes the systemd user bus without weakening fail-closed'
