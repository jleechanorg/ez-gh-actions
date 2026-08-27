#!/usr/bin/env bash
# Hermetic regression coverage for doctor-runner physical-host lifecycle checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_SRC=$(sed -n '/^# --- D3\. forbidden host lifecycle authority/,/^# --- E\. recent routing proof/p' "$ROOT/doctor-runner" | sed '$d')
[ -n "$SECTION_SRC" ] || { echo "FAIL: host lifecycle section missing" >&2; exit 1; }

section() { :; }
ok() { printf 'OK %s\n' "$*"; }
bad() { printf 'BAD %s\n' "$*"; }

run_case() {
  local enabled="$1" active="$2" panic_timeout="$3" oops="$4"
  systemctl() {
    case "$*" in
      *is-enabled*) [ "$enabled" = yes ] ;;
      *is-active*) [ "$active" = yes ] ;;
      *) return 1 ;;
    esac
  }
  sysctl() {
    case "$*" in
      *kernel.panic_on_oops*) printf '%s\n' "$oops" ;;
      *kernel.panic*) printf '%s\n' "$panic_timeout" ;;
    esac
  }
  PLATFORM=linux
  eval "$SECTION_SRC"
  printf 'CRITICAL=%s\n' "$HOST_LIFECYCLE_CRITICAL"
}

clean=$(run_case no no 0 0)
grep -Fq 'OK system watchdog.service is inactive and not boot-enabled' <<<"$clean"
grep -Fq 'OK kernel panic and oops auto-recovery are disabled' <<<"$clean"
grep -Fq 'CRITICAL=0' <<<"$clean"

armed=$(run_case yes no 10 1)
grep -Fq 'BAD system watchdog.service is active or boot-enabled' <<<"$armed"
grep -Fq 'BAD kernel auto-recovery is armed' <<<"$armed"
grep -Fq 'CRITICAL=2' <<<"$armed"

echo "DOCTOR_RUNNER_HOST_LIFECYCLE_TEST: PASS"
