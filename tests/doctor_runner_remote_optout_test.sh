#!/usr/bin/env bash
# regression test: a deliberately parked platform must be expressible as
# "intentionally DISABLED", distinct from "DOWN" — see jleechan-hxz0.
#
# Root cause this guards against: doctor-runner hardcodes the Mac leg of the
# fleet contract at DEFAULT_MAC_RUNNER_COUNT=4 and CLAMPS UP any lower value
# ("Overrides may raise the count or set the prefix, never lower the
# contract"). So an operator who intentionally parks the Mac fleet gets
# "4 slot(s) DOWN" plus 4 slot-proof criticals on every run, and a genuinely
# healthy 20/20 Linux fleet exits 1. Nothing reading that exit code could
# tell a deliberate suspension from a crashed host.
#
# The fix is an EXPLICIT opt-out (MAC_RUNNER_DISABLED=1 / REMOTE_LINUX_DISABLED=1)
# that zeroes the remote leg so it contributes nothing to the contract. It is
# deliberately NOT inferred from live state: a daemon that died on its own
# also reads as "not running", so inferring would silently absorb real
# outages — which is precisely what the fail-closed default exists to catch.
#
# This test extracts the ACTUAL opt-out decision block and the real
# compute_live_slot_critical() from doctor-runner (via sed, never a
# reimplementation) and asserts BOTH arms:
#   (a) opt-out set   -> remote leg is 0 slots, adds 0 criticals, 20/20 greens
#   (b) opt-out unset -> remote leg stays 4, DOWN slots stay critical, 20/20 RED
#
# Usage: bash tests/doctor_runner_remote_optout_test.sh

# Literal fixed-string assertions intentionally contain shell syntax.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"

if [ ! -f "$DOCTOR_SCRIPT" ]; then
  echo "FAIL: doctor-runner not found at $DOCTOR_SCRIPT" >&2
  exit 1
fi

# --- extract the real functions/block out of doctor-runner -------------------

# compute_live_slot_critical() (same extraction idiom as
# doctor_runner_live_slot_gate_test.sh) so the verdict math under test is the
# shipped math.
FUNC_START=$(grep -n '^compute_live_slot_critical() {' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
if [ -z "$FUNC_START" ]; then
  echo "FAIL: could not locate compute_live_slot_critical() in $DOCTOR_SCRIPT" >&2
  exit 1
fi
FUNC_END_REL=$(tail -n +"$FUNC_START" "$DOCTOR_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_START + FUNC_END_REL - 1))
FUNC_SRC=$(sed -n "${FUNC_START},${FUNC_END}p" "$DOCTOR_SCRIPT")

# The opt-out decision block, bounded by its REMOTE_DISABLED=0 marker and the
# `elif timeout ...` line that begins the real SSH branch. Extracting it keeps
# this test honest: if the production block changes shape, the test notices.
OPTOUT_START=$(grep -n '^REMOTE_DISABLED=0$' "$DOCTOR_SCRIPT" | head -1 | cut -d: -f1 || true)
if [ -z "$OPTOUT_START" ]; then
  echo "FAIL: could not locate 'REMOTE_DISABLED=0' opt-out block in $DOCTOR_SCRIPT" >&2
  exit 1
fi
OPTOUT_END=$(awk -v s="$OPTOUT_START" 'NR>s && /^elif timeout 5 ssh /{print NR; exit}' "$DOCTOR_SCRIPT")
if [ -z "$OPTOUT_END" ]; then
  echo "FAIL: could not locate the SSH branch that follows the opt-out block" >&2
  exit 1
fi
OPTOUT_SRC=$(sed -n "${OPTOUT_START},$((OPTOUT_END - 1))p" "$DOCTOR_SCRIPT")
# The block ends at the `elif` that opens the real SSH branch, so its trailing
# `if ... then` case has no closer; supply one so the extracted fragment is a
# complete statement. (The opt-out arm itself is what we then exercise.)
OPTOUT_SRC="${OPTOUT_SRC}"$'\nfi'

# The LOCAL opt-out decision block. A remote-only opt-out left a real gap
# (codex P0 on PR #214): a doctor run ON the parked host still enumerated and
# probed its own slots, so the parked host stayed "4 DOWN" and exited
# unhealthy even with the opt-out set. Whichever leg the opt-out names must be
# zeroed, and that includes the leg the script is running on.
LOCAL_START=$(grep -n '^if \[ "\$LOCAL_DISABLED" -eq 1 \]; then$' "$DOCTOR_SCRIPT" | tail -1 | cut -d: -f1 || true)
if [ -z "$LOCAL_START" ]; then
  echo "FAIL: could not locate the LOCAL_DISABLED zeroing block in $DOCTOR_SCRIPT" >&2
  echo "      (PR #214 codex P0: the parked host's OWN leg must be zeroed too)" >&2
  exit 1
fi
LOCAL_END=$(awk -v s="$LOCAL_START" 'NR>s && /^HOST_LABEL=/{print NR; exit}' "$DOCTOR_SCRIPT")
if [ -z "$LOCAL_END" ]; then
  echo "FAIL: could not locate HOST_LABEL= after the local opt-out block" >&2
  exit 1
fi
LOCAL_SRC=$(sed -n "${LOCAL_START},$((LOCAL_END - 1))p" "$DOCTOR_SCRIPT")

# --- structural guards: the opt-out must exist and stay explicit ------------

if ! grep -Fq 'MAC_RUNNER_DISABLED' "$DOCTOR_SCRIPT"; then
  echo "FAIL: doctor-runner has no MAC_RUNNER_DISABLED opt-out (jleechan-hxz0 regressed)" >&2
  exit 1
fi
# The opt-out must NOT be inferred from live launchd/docker state; that would
# make a crashed daemon indistinguishable from an intentional suspension.
if sed -n "${OPTOUT_START},$((OPTOUT_END - 1))p" "$DOCTOR_SCRIPT" | grep -Eq 'launchctl|docker ps'; then
  echo "FAIL: opt-out block infers disabled state from live launchd/docker state;" >&2
  echo "      an intentional suspension must be declared, never detected (jleechan-hxz0)" >&2
  exit 1
fi
# The contract clamp must still be present for the non-opted-out path: a config
# count below the contract is underprovisioning, not a suspension.
if ! grep -Fq 'is below the fleet contract' "$DOCTOR_SCRIPT"; then
  echo "FAIL: the underprovisioning guard was removed; a low count must still fail closed" >&2
  exit 1
fi

# --- harness ----------------------------------------------------------------

ok() { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [BAD]  %s\n' "$*"; }

# Replays the production opt-out block, then the production verdict gate, for
# one (platform, optout-env) pair, with a fixture remote leg of remote_count
# slots and remote_down of them DOWN.
run_case() {
  local label="$1" platform="$2" env_name="$3" env_val="$4"
  local remote_count="$5" remote_down="$6" expected_criticals="$7"

  local REMOTE_LABEL="macos (macbook)" REMOTE_PREFIX="ez-mac-runner-h"
  [ "$platform" = "macos" ] && REMOTE_LABEL="linux (jeff-ubuntu)"
  local PLATFORM="$platform"
  local REMOTE_COUNT="$remote_count"
  local SLOT_PROOF_CRITICAL=0
  local REMOTE_EXECUTING_SLOTS=() REMOTE_IDLE_SLOTS=()
  local REMOTE_CYCLING_SLOTS=() REMOTE_DOWN_SLOTS=()

  # Only the arm under test is set; the other leg's opt-out stays unset so a
  # cross-wired opt-out fails here.
  if [ "$env_name" = "MAC_RUNNER_DISABLED" ]; then unset REMOTE_LINUX_DISABLED; else unset MAC_RUNNER_DISABLED; fi
  export "${env_name}=${env_val}"

  eval "$OPTOUT_SRC"

  # If the opt-out did NOT engage, emulate the production inventory for the
  # remote leg: the DOWN slots are found and charged to SLOT_PROOF_CRITICAL by
  # the real `if [ "${#REMOTE_DOWN_SLOTS[@]}" -gt 0 ]` branch below. When the
  # opt-out DID engage there is no remote host to inventory at all, so the leg
  # contributes nothing — that is the whole point of the fix.
  if [ "${REMOTE_DISABLED:-0}" -eq 0 ]; then
    local i=1
    while [ "$i" -le "$remote_down" ]; do
      REMOTE_DOWN_SLOTS+=("${REMOTE_PREFIX}-${i}")
      i=$((i + 1))
    done
  fi
  if [ "${#REMOTE_DOWN_SLOTS[@]}" -gt 0 ]; then
    SLOT_PROOF_CRITICAL=$((SLOT_PROOF_CRITICAL + ${#REMOTE_DOWN_SLOTS[@]}))
  fi

  # Production verdict math, replayed with a healthy local leg (20 executing).
  eval "$FUNC_SRC"
  local LOCAL_COUNT=20
  local FLEET_CONFIGURED_COUNT=$((LOCAL_COUNT + REMOTE_COUNT))
  local FLEET_LIVE_SLOTS LIVE_SLOT_CRITICAL
  read -r FLEET_LIVE_SLOTS LIVE_SLOT_CRITICAL < <(
    compute_live_slot_critical 20 0 0 \
      "${#REMOTE_EXECUTING_SLOTS[@]}" "${#REMOTE_IDLE_SLOTS[@]}" "${#REMOTE_CYCLING_SLOTS[@]}" \
      "$FLEET_CONFIGURED_COUNT"
  )
  local CRITICAL=0
  if [ "$LIVE_SLOT_CRITICAL" -eq 1 ]; then CRITICAL=$((CRITICAL + 1)); fi
  CRITICAL=$((CRITICAL + SLOT_PROOF_CRITICAL))

  local PASS=true
  if [ "$CRITICAL" -ne "$expected_criticals" ]; then
    echo "  [$label] expected CRITICAL=$expected_criticals got $CRITICAL (remote_count=$REMOTE_COUNT expected_total=$FLEET_CONFIGURED_COUNT) -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    printf '  [%s] remote_count=%s expected_total=%s CRITICAL=%s -- PASS\n' \
      "$label" "$REMOTE_COUNT" "$FLEET_CONFIGURED_COUNT" "$CRITICAL"
    echo "OK: $label" >> "${CASELOG:-/dev/null}"
    return 0
  fi
  return 1
}

echo "--- doctor-runner intentional-remote-opt-out regression ---"
OVERALL_PASS=true

# (a) OPT-OUT ENGAGED: Mac parked from a Linux doctor.
#     Remote leg must collapse to 0 and contribute 0 criticals even with all
#     4 Mac slots absent, so a healthy 20/20 Linux fleet exits clean (0).
run_case "mac-parked-mac-os-off" "linux" "MAC_RUNNER_DISABLED" "1" 4 4 0 || OVERALL_PASS=false

# (b) OPT-OUT ENGAGED on the macOS side, parking the Linux leg.
run_case "linux-parked-from-macos" "macos" "REMOTE_LINUX_DISABLED" "1" 20 20 0 || OVERALL_PASS=false

# (c) DEFAULT (no opt-out): a dark Mac leg must STILL fail closed. 4 Mac slots
#     DOWN => 4 slot-proof criticals + 1 live-slot critical = 5, unchanged
#     from today's behavior. This is the arm that proves the opt-out is opt-in.
run_case "mac-down-without-optout" "linux" "MAC_RUNNER_DISABLED" "0" 4 4 5 || OVERALL_PASS=false

# (d) A non-"1" value must not activate the opt-out (no truthiness accidents).
run_case "mac-down-optout-yes-is-not-enabled" "linux" "MAC_RUNNER_DISABLED" "yes" 4 4 5 || OVERALL_PASS=false

# --- local leg: the parked host's OWN fleet ---------------------------------
# PR #214 codex P0: a remote-only opt-out left a doctor run ON the parked host
# still enumerating and probing its own slots, so the parked host itself stayed
# "4 DOWN" and exited unhealthy. These cases replay the real local decision
# block and assert the local expected count collapses to 0 when, and only
# when, this host is the platform the opt-out names.
run_local_case() {
  local label="$1" platform="$2" env_name="$3" env_val="$4"
  local configured="$5" expect_local_count="$6"

  local PLATFORM="$platform"
  local CONFIGURED_COUNT="$configured"
  if [ "$env_name" = "MAC_RUNNER_DISABLED" ]; then unset REMOTE_LINUX_DISABLED; else unset MAC_RUNNER_DISABLED; fi
  export "${env_name}=${env_val}"
  # LOCAL_DISABLED is the single shared decision (declared at the top of
  # doctor-runner, before the host-lifecycle sections). Recompute it here the
  # same way production does, so the local block under test reads it exactly as
  # the real script would.
  local LOCAL_DISABLED=0
  case "$PLATFORM" in
    macos) [ "${MAC_RUNNER_DISABLED:-0}" = "1" ] && LOCAL_DISABLED=1 ;;
    linux) [ "${REMOTE_LINUX_DISABLED:-0}" = "1" ] && LOCAL_DISABLED=1 ;;
  esac

  eval "$LOCAL_SRC"

  local PASS=true
  if [ "$CONFIGURED_COUNT" -ne "$expect_local_count" ]; then
    echo "  [$label] expected local CONFIGURED_COUNT=$expect_local_count got $CONFIGURED_COUNT -- FAIL"
    PASS=false
  fi
  if [ "$PASS" = "true" ]; then
    printf '  [%s] local configured=%s (expected %s) -- PASS\n' \
      "$label" "$CONFIGURED_COUNT" "$expect_local_count"
    return 0
  fi
  return 1
}

# Doctor ON the parked Mac, opt-out set -> this host expects 0 slots.
run_local_case "mac-host-parked-local" "macos" "MAC_RUNNER_DISABLED" "1" 4 0 || OVERALL_PASS=false

# Doctor on Linux with MAC_RUNNER_DISABLED set -> Linux is NOT parked; keep 20.
# (Guards against one env var zeroing the wrong platform's local leg.)
run_local_case "linux-host-mac-parked-local-untouched" "linux" "MAC_RUNNER_DISABLED" "1" 20 20 || OVERALL_PASS=false

# Doctor ON Linux with the Linux leg parked -> 0 slots locally.
run_local_case "linux-host-parked-local" "linux" "REMOTE_LINUX_DISABLED" "1" 20 0 || OVERALL_PASS=false

# Default (no opt-out): the local leg keeps its configured count.
run_local_case "mac-host-default-local" "macos" "MAC_RUNNER_DISABLED" "0" 4 4 || OVERALL_PASS=false

# --- verdict exit-contract: zero-slot contract must never be "healthy" -------
# cs review P0 on PR #214: with both legs opted out, FLEET_CONFIGURED_COUNT=0,
# compute_live_slot_critical sees `0 < 0` as false, and the script printed
# "fleet healthy: 0/0" and exited 0 with ZERO capacity -- a two-env-var path
# from red to green. Assert the shipped guard exists and is bound to the
# configured count, plus that the success line carries the parked-leg note.
VERDICT_SRC=$(sed -n '/^# A zero-slot contract can never be/,/^exit 0$/p' "$DOCTOR_SCRIPT")
if [ -z "$VERDICT_SRC" ]; then
  echo "  [zero-slot-guard] FAIL: could not locate the zero-slot guard block" >&2
  OVERALL_PASS=false
else
  if grep -q 'VERDICT_CONFIGURED" -eq 0' <<<"$VERDICT_SRC" && grep -q 'exit 3' <<<"$VERDICT_SRC"; then
    echo "  [zero-slot-guard] guarded: 0-slot contract -> exit 3, not healthy -- PASS"
  else
    echo "  [zero-slot-guard] FAIL: zero-slot contract is not diverted to exit 3" >&2
    OVERALL_PASS=false
  fi
  if grep -q 'PARKED_NOTE' <<<"$VERDICT_SRC" && grep -q 'ok "fleet healthy:.*REMOTE_LEG_NOTE.*PARKED_NOTE' <<<"$VERDICT_SRC"; then
    echo "  [success-names-parked-leg] success line carries the parked-leg note -- PASS"
  else
    echo "  [success-names-parked-leg] FAIL: success line does not name the parked leg" >&2
    OVERALL_PASS=false
  fi
fi

# The INCONCLUSIVE exit code must be documented where the exit contract lives,
# so an agent reading only the docs cannot treat "not 1" as "fine".
for _doc in "$REPO_ROOT/.claude/commands/doctor-ezactions.md" "$REPO_ROOT/.claude/skills/ezgha-doctor/SKILL.md"; do
  if [ -f "$_doc" ] && grep -q 'INCONCLUSIVE' "$_doc"; then
    echo "  [exit-3-documented:$(basename "$_doc")] PASS"
  else
    echo "  [exit-3-documented] FAIL: $_doc does not document the INCONCLUSIVE exit code" >&2
    OVERALL_PASS=false
  fi
done

echo "--- summary ---"
if [ "$OVERALL_PASS" = "true" ]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
