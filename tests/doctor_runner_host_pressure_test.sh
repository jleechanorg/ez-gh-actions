#!/usr/bin/env bash
# Regression coverage for doctor-runner section 6b. The test extracts and
# executes the real section so set -e/pipefail behavior and load parsing cannot
# drift from production.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_SCRIPT="$REPO_ROOT/doctor-runner"
SECTION_SRC=$(sed -n '/^# --- D2\. host resource pressure/,/^# --- E\. recent routing proof/p' "$DOCTOR_SCRIPT")

if [ -z "$SECTION_SRC" ]; then
  echo "FAIL: could not extract host resource pressure section" >&2
  exit 1
fi

section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
info() { printf '  [..]   %s\n' "$*"; }
sysctl() { printf '4\n'; }
recent_logs() {
  printf '%s\n' \
    "docker CLI timed out" \
    "settling ceiling reached" \
    "settling ceiling reached" \
    "settling ceiling reached" \
    "settling ceiling reached"
}

run_case() {
  local label="$1" uptime_line="$2"
  uptime() { printf '%s\n' "$uptime_line"; }
  PLATFORM=macos
  local output
  output=$(eval "$SECTION_SRC"; echo HOST_PRESSURE_SECTION_COMPLETED)
  printf '%s\n' "$output"
  grep -Fq 'HOST_PRESSURE_SECTION_COMPLETED' <<<"$output" || {
    echo "FAIL: $label aborted before the sentinel (pipefail/SIGPIPE regression)" >&2
    return 1
  }
  printf '%s' "$output"
}

echo "--- doctor-runner host-resource-pressure regression ---"

high_output=$(run_case "high-load" "18:14 up 2 days, load averages: 8.10 7.00 6.00")
grep -Fq '1-min load (8.10) exceeds 2x core count (4 cores, threshold 8)' <<<"$high_output"
grep -Fq "daemon logged 1 'docker CLI timed out' error(s)" <<<"$high_output"
grep -Fq "daemon logged 4 'settling ceiling reached' warning(s)" <<<"$high_output"
grep -Fq 'recent launchd log tail (up to 200 lines per stream)' <<<"$high_output"

invalid_output=$(run_case "invalid-load" "uptime output unavailable")
grep -Fq 'could not parse load average or core count' <<<"$invalid_output"
if grep -Fq '[OK]   1-min load (uptime output unavailable)' <<<"$invalid_output"; then
  echo "FAIL: invalid uptime text was reported as a healthy numeric load" >&2
  exit 1
fi

echo "REGRESSION_TEST: PASS"
