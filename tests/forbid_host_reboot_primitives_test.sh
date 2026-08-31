#!/usr/bin/env bash
# Fail-closed test forbidding physical-host reboot/shutdown primitives and watchdog-driven forced restarts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  echo "OK: $*"
}

# 1. Assert forbidden files do not exist in the repository
FORBIDDEN_FILES=(
  "scripts/ezgha-fleet-watchdog.sh"
  "scripts/host/apply-cfs-nohz-panic-stop.sh"
  "scripts/host/apply-watchdog-no-reboot-vote.sh"
  "scripts/host/assert-no-host-reboot-vote.sh"
  "scripts/host/configure-grub-kdump.sh"
  "scripts/host/crash-capture-verify.sh"
  "scripts/host/kdump-remediation.sh"
  "scripts/host/watchdog-load-repair.sh"
  "config/watchdog.conf"
  "config/sysctl.d/99-ezgha-oops-reboot.conf"
  "config/grub.d/zz-ezgha-nohz-panic.cfg"
  "systemd/ezgha-watchdog.service"
  "systemd/ezgha-watchdog.timer"
  "docs/watchdog.md"
  "scripts/host/host-pressure-proof.sh"
  "tests/apply_cfs_nohz_panic_stop_test.sh"
  "tests/apply_watchdog_no_reboot_vote_test.sh"
  "tests/assert_no_host_reboot_vote_test.sh"
  "tests/configure_grub_kdump_retired_test.sh"
  "tests/watchdog_reboot_stale_state_test.sh"
)

for rel in "${FORBIDDEN_FILES[@]}"; do
  if [ -e "${REPO_ROOT}/${rel}" ]; then
    fail "Forbidden file exists in repo: ${rel}"
  fi
done

if [ "$FAILURES" -eq 0 ]; then
  ok "No forbidden files exist in repo"
fi

# 2. Assert active operational documents and verifiers do not point operators
# at retired host-lifecycle automation. Historical incident records may retain
# names for provenance, so keep this list deliberately bounded.
FORBIDDEN_ACTIVE_REFERENCES=(
  "scripts/host/kdump-remediation.sh"
  "scripts/host/apply-watchdog-no-reboot-vote.sh"
  "scripts/host/assert-no-host-reboot-vote.sh"
  "scripts/host/watchdog-load-repair.sh"
  "systemd/ezgha-watchdog.service"
  "systemd/ezgha-watchdog.timer"
  "scripts/host/host-pressure-proof.sh"
)
ACTIVE_DOCUMENTS=(
  "README.md"
  "DESIGN.md"
  "docs/verify-exit-criteria.sh"
  "docs/superpowers/plans/2026-08-26-borg-failure-ladder.md"
  ".claude/skills/ezgha-doctor/SKILL.md"
  ".claude/commands/doctor-ezactions.md"
)

for rel in "${FORBIDDEN_ACTIVE_REFERENCES[@]}"; do
  if grep -Fn -- "$rel" "${ACTIVE_DOCUMENTS[@]/#/${REPO_ROOT}/}" 2>/dev/null; then
    fail "Active operational guidance references retired host automation: ${rel}"
  fi
done

# 3. Scan active code (src/, scripts/, systemd/, install.sh) for forbidden host reboot / forced-panic primitives
# Forbidden patterns in executable / configuration files:
# - sysrq trigger (echo c > /proc/sysrq-trigger, etc.)
# - host reboot/shutdown commands (systemctl reboot, /sbin/reboot, shutdown -r, poweroff, etc.)
# - panic configuration (kernel.panic = 10, etc.)

TARGETS=(
  "${REPO_ROOT}/src"
  "${REPO_ROOT}/scripts"
  "${REPO_ROOT}/systemd"
  "${REPO_ROOT}/install.sh"
)

# Read-only diagnostics in doctor-runner may name these settings, but the
# doctor must never mutate them or invoke a physical-host lifecycle action.
MUTATION_TARGETS=(
  "${TARGETS[@]}"
  "${REPO_ROOT}/doctor-runner"
  "${REPO_ROOT}/doctor.sh"
)

# Search for /proc/sysrq-trigger
if grep -rnw "${TARGETS[@]}" -e 'sysrq-trigger' 2>/dev/null; then
  fail "Found forbidden sysrq-trigger reference in active codebase"
else
  ok "No sysrq-trigger references in active codebase"
fi

# Search for kernel.panic sysctl or forced panic settings
if grep -rnw "${TARGETS[@]}" -e 'kernel.panic' -e 'panic_on_oops' 2>/dev/null; then
  fail "Found forbidden kernel.panic / panic_on_oops reference in active codebase"
else
  ok "No kernel.panic / panic_on_oops references in active codebase"
fi

# Search for host shutdown/reboot invocations
# Note: we exclude comments or legitimate string names like 'reboot' in error logs if any, but grep for direct executions
if grep -rnE '(systemctl[[:space:]]+(reboot|poweroff|halt)|/sbin/reboot|/sbin/shutdown|/sbin/poweroff|/sbin/halt)' "${MUTATION_TARGETS[@]}" 2>/dev/null; then
  fail "Found forbidden systemctl reboot/shutdown/poweroff/halt invocation"
else
  ok "No host reboot/shutdown invocations in active codebase"
fi

if grep -rnE '(sysctl[[:space:]]+(-w[[:space:]]+)?kernel\.panic(_on_oops)?=|/proc/sys/(kernel/)?(panic|panic_on_oops)|sysrq-trigger)' "${MUTATION_TARGETS[@]}" 2>/dev/null; then
  fail "Found forbidden host panic mutation in active codebase or doctor-runner"
else
  ok "No host panic mutations in active codebase or doctor-runner"
fi

# Search for active ezgha-watchdog service/timer references in systemd / install
if grep -rnE 'systemctl[[:space:]]+--user[[:space:]]+(enable|start)[[:space:]]+.*ezgha-watchdog' "${TARGETS[@]}" 2>/dev/null; then
  fail "Found active enablement of ezgha-watchdog in systemd/install"
else
  ok "No active enablement of ezgha-watchdog in systemd/install"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "FORBID_HOST_REBOOT_PRIMITIVES_TEST: FAILED ($FAILURES failures)" >&2
  exit 1
fi

echo "FORBID_HOST_REBOOT_PRIMITIVES_TEST: PASS"
