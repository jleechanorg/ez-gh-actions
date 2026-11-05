#!/usr/bin/env bash
# Regression test: a deliberately parked runner leg must be reported DISABLED at
# INFO, never DOWN/CRITICAL, by the host-health pager (bead jleechan-hxz0).
#
# Root cause this guards: on 2026-11-05 the Mac's ezgha launchd job was disabled
# on purpose (operator opt-out), so the pager saw launchd-disabled + 0 managed
# containers + count=4 in config and paged
#   "[CRITICAL] ezgha: GitHub Actions Runners Down Alert"
# every ~30 minutes indefinitely. doctor-runner had already learned to express
# "intentionally DISABLED"; the pager had not, so parking a platform forever
# meant false "runners down" pages.
#
# The opt-out must be DECLARED, never inferred: a crashed daemon also reads as
# "not running", so inferring would silently absorb real outages. Unset keeps
# today's fail-closed behaviour -- that arm is asserted here too.
#
# Usage: bash tests/ezgha_host_health_parked_optout_test.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/ezgha-host-health-alert.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }

FAILED=0
ok()  { printf '  [%s] PASS\n' "$1"; }
no()  { printf '  [%s] FAIL: %s\n' "$1" "$2"; FAILED=1; }

# run_case <label> <expect: DISABLED|DOWN> <platform> <env assignments...>
run_case() {
  local label="$1" expect="$2" platform="$3"; shift 3
  local out rc
  out=$(env HEALTH_ALERT_PLATFORM="$platform" "$@" \
        timeout 90 bash "$SCRIPT" --dry-run 2>&1)
  rc=$?

  if [ "$expect" = "DISABLED" ]; then
    if grep -q 'DISABLED' <<<"$out" && ! grep -q 'FLEET DOWN' <<<"$out"; then
      ok "$label"
    else
      no "$label" "expected DISABLED/exit-0, got rc=$rc: $(grep -oE 'DISABLED|FLEET DOWN' <<<"$out" | head -1)"
    fi
    # The emitted entry must be INFO, never ERROR/CRITICAL: the SMS policy
    # matches severity>=ERROR, so severity is the actual page/no-page switch.
    if grep -q 'would dispatch INFO' <<<"$out" && ! grep -q 'would dispatch ERROR' <<<"$out"; then
      ok "$label severity=INFO (policy cannot page)"
    else
      no "$label severity" "an ERROR/CRITICAL entry was emitted while parked -- would page"
    fi
  else
    # Exit status is NOT the signal: main changed the contract so a *verdict* is
    # a successful probe and exits 0. The page/no-page switch is severity
    # (the SMS policy matches severity>=ERROR) plus status=DOWN.
    if grep -q 'FLEET DOWN' <<<"$out" && grep -q '"status":"DOWN"' <<<"$out" \
       && ! grep -q '"status":"DISABLED"' <<<"$out"; then
      ok "$label"
    else
      no "$label" "expected FLEET DOWN + status=DOWN, got rc=$rc"
    fi
  fi
}

echo "--- host-health pager: intentionally parked leg ---"

# macOS leg parked: launchd disabled + 0 containers is the DECISION, not an outage.
run_case "mac parked -> DISABLED" DISABLED Darwin \
  HEALTH_ALERT_SERVICE_OK=0 HEALTH_ALERT_CONTAINER_COUNT=0 HEALTH_ALERT_FREE_GB=100 \
  MAC_RUNNER_DISABLED=1 REMOTE_LINUX_DISABLED=1

# Linux leg parked, with an unreachable parked peer (the Mac is off too).
run_case "linux parked + peer parked -> DISABLED" DISABLED Linux \
  HEALTH_ALERT_SERVICE_OK=0 HEALTH_ALERT_CONTAINER_COUNT=0 HEALTH_ALERT_FREE_GB=100 \
  REMOTE_LINUX_DISABLED=1 MAC_RUNNER_DISABLED=1

# FAIL-CLOSED DEFAULT: same dead-daemon state with NO opt-out must still page.
run_case "mac dead, no opt-out -> DOWN (fail closed)" DOWN Darwin \
  HEALTH_ALERT_SERVICE_OK=0 HEALTH_ALERT_CONTAINER_COUNT=0 HEALTH_ALERT_FREE_GB=100

# Healthy host keeps working normally (guard against over-gating): a healthy
# host emits NO entry at all and exits 0.
healthy_out=$(env HEALTH_ALERT_PLATFORM=Linux HEALTH_ALERT_SERVICE_OK=1 \
  HEALTH_ALERT_CONTAINER_COUNT=20 HEALTH_ALERT_FREE_GB=100 HEALTH_ALERT_PEER_OK=1 \
  HEALTH_ALERT_PEER_CONTAINERS=4 HEALTH_ALERT_PEER_FREE_GB=100 \
  timeout 90 bash "$SCRIPT" --dry-run 2>&1)
healthy_rc=$?
if [ "$healthy_rc" -eq 0 ] && ! grep -qE 'FLEET DOWN|would dispatch ERROR' <<<"$healthy_out"; then
  ok "linux healthy, no opt-out -> no page"
else
  no "linux healthy" "healthy host paged or exited $healthy_rc"
fi

echo "--- summary ---"
if [ "$FAILED" -eq 0 ]; then echo "REGRESSION_TEST: PASS"; exit 0; else echo "REGRESSION_TEST: FAIL"; exit 1; fi
