#!/usr/bin/env bash
# Verifies the heartbeat-gap parked-host exemption (codex P0 on PR #214):
# a big queue-monitor gap must add 0 criticals on a parked leg, and must still
# add 1 critical on an active host. Extracts the real block from doctor-runner.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hb_doc="$(awk '/^  if \[ "\$\{HEARTBEAT_SAMPLE_COUNT:-0\}" -eq 0 \]/{f=1} f{print} f&&/^  fi$/{exit}' "$REPO/doctor-runner")"
if [ -z "$hb_doc" ]; then
  echo "FAIL: could not extract the heartbeat block"; exit 1
fi

bad() { :; }

run_case() { # label local_disabled expect
  local label="$1" LD="$2" expect="$3"
  # Run each case in a SUBSHELL: the extracted block may set -e/exit on one
  # branch, which must not abort the remaining cases.
  local got
  got=$(
    set +e
    LOCAL_DISABLED="$LD" SERVICE_STATE=active HEARTBEAT_SAMPLE_COUNT=5     MAX_HEARTBEAT_GAP=300 STARVE_GAP_WARN_SECONDS=240 SLOT_PROOF_CRITICAL=0     bash -c 'eval "$1" >/dev/null 2>&1; printf "%s" "$SLOT_PROOF_CRITICAL"' _ "$hb_doc"
  )
  SLOT_PROOF_CRITICAL="${got:-unknown}"
  if [ "${SLOT_PROOF_CRITICAL:-x}" = "$expect" ]; then
    printf '  [%s] critical=%s (expect %s) -- PASS\n' "$label" "$SLOT_PROOF_CRITICAL" "$expect"
    return 0
  fi
  printf '  [%s] critical=%s (expect %s) -- FAIL\n' "$label" "$SLOT_PROOF_CRITICAL" "$expect"
  return 1
}

echo "--- heartbeat parked-host exemption ---"
ok=1
run_case "parked-host-big-gap-no-critical" 1 0 || ok=0
run_case "active-host-big-gap-critical" 0 1 || ok=0

if [ "$ok" -eq 1 ]; then echo "REGRESSION_TEST: PASS"; exit 0; else echo "REGRESSION_TEST: FAIL"; exit 1; fi
