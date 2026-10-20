#!/usr/bin/env bash
# Regression: every tracked systemd/ezgha-*.service|timer must pass the
# install.sh Linux render guard (no leftover @PLACEHOLDER@, no repo path, no
# "worktree" in non-comment lines). Pure text processing; touches nothing live.
# Usage: bash tests/systemd_units_install_guard_test.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The guard below mirrors install.sh; fail if install.sh drifts from it.
grep -q "grep -qi 'worktree' <<<\"\${unit_scanned}\"" "${REPO_ROOT}/install.sh" \
  || { echo "FAIL: install.sh worktree guard changed; update this test"; exit 1; }

SCRIPTS_DIR=/home/test/.local/libexec/ezgha
HOME_DIR=/home/test
fail=0
count=0
for unit in "${REPO_ROOT}"/systemd/ezgha-*.service "${REPO_ROOT}"/systemd/ezgha-*.timer; do
  [ -f "${unit}" ] || continue
  count=$((count + 1))
  rendered="$(sed -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" -e "s|@HOME@|${HOME_DIR}|g" "${unit}")"
  scanned="$(grep -v '^[[:space:]]*#' <<<"${rendered}")"
  if grep -q '@[A-Z_]*@' <<<"${scanned}" || grep -qF "${REPO_ROOT}" <<<"${scanned}" || grep -qi 'worktree' <<<"${scanned}"; then
    echo "FAIL: $(basename "${unit}") would be refused by install.sh guard"
    fail=1
  else
    echo "ok: $(basename "${unit}")"
  fi
done
[ "${count}" -gt 0 ] || { echo "FAIL: no units found"; exit 1; }

# The cleanup unit must not reintroduce the 4h value that deleted in-flight work.
grep -qx 'Environment=MIN_AGE_HOURS=48' "${REPO_ROOT}/systemd/ezgha-mission-output-cleanup.service" \
  || { echo "FAIL: cleanup service must set MIN_AGE_HOURS=48"; fail=1; }
exit "${fail}"
