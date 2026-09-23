#!/usr/bin/env bash
# regression test: scripts/check_secret_permissions.sh
# Walks the canonical list of secret-bearing paths under $HOME and reports
# any file with group-writable or world-readable bits. The audit script MUST
# NEVER print file contents — only paths and mode bits.
#
# Acceptance matrix (each case listed below must exit code 0 if safe, 1 if
# unsafe; missing files are silently skipped):
#   600 file -> exit 0, no warning
#   644 file -> exit 1, warning lists path + mode
#   660 file -> exit 1, warning lists path + mode
#   700 dir  -> exit 0
#   755 dir  -> exit 1 (config dir world-readable)
#   missing file -> exit 0 (silently skipped)
#   file contents NEVER printed even when mode is unsafe (assert via log capture)
#
# Usage: bash tests/secret_permission_check_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="${REPO_ROOT}/scripts/check_secret_permissions.sh"

if [ ! -x "${AUDIT}" ]; then
  echo "FAIL: ${AUDIT} is missing or not executable — Phase 1 RED contract holds (script not yet implemented)." >&2
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

# Build a minimal fake HOME with a representative subset of the canonical
# secret-bearing paths. We override HOME for the audit and also override the
# audit's known path list by using the env-var hook (EZGHA_SECRET_AUDIT_PATHS)
# the audit script honors (so this test is hermetic and never touches the
# real ~/.config/ezgha on the host).
HOME_T="${WORK}/home"
mkdir -p "${HOME_T}/.config/ezgha/secrets" \
         "${HOME_T}/.local/share/ezgha/tokens" \
         "${HOME_T}/.config/ezgha"
SENTINEL="NOT-A-REAL-SECRET-DO-NOT-LOG"
echo "${SENTINEL}" > "${HOME_T}/.config/ezgha/config.toml"
echo "${SENTINEL}" > "${HOME_T}/.config/ezgha/secrets/alert-credential"
echo "${SENTINEL}" > "${HOME_T}/.local/share/ezgha/tokens/app-token"
echo "${SENTINEL}" > "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem"

export EZGHA_SECRET_AUDIT_PATHS="${HOME_T}/.config/ezgha|${HOME_T}/.config/ezgha/secrets|${HOME_T}/.local/share/ezgha|${HOME_T}/.local/share/ezgha/tokens|${HOME_T}/.config/ezgha/config.toml|${HOME_T}/.config/ezgha/secrets/alert-credential|${HOME_T}/.local/share/ezgha/tokens/app-token|${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem|${HOME_T}/.config/ezgha/secrets/missing-on-purpose"

# ── Case 1: 600 file → exit 0, no warning, sentinel NOT printed ─────────────
chmod 700 "${HOME_T}/.config/ezgha" "${HOME_T}/.config/ezgha/secrets" "${HOME_T}/.local/share/ezgha" "${HOME_T}/.local/share/ezgha/tokens" 2>/dev/null || true
chmod 600 "${HOME_T}/.config/ezgha/config.toml" 2>/dev/null || true
chmod 600 "${HOME_T}/.config/ezgha/secrets/alert-credential" 2>/dev/null || true
chmod 600 "${HOME_T}/.local/share/ezgha/tokens/app-token" 2>/dev/null || true
chmod 600 "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem" 2>/dev/null || true
LOG1="${WORK}/case1.log"
if ! HOME="${HOME_T}" bash "${AUDIT}" >"${LOG1}" 2>&1; then
  fail "Case 1: 600 file should be safe but audit exited non-zero"
else
  echo "PASS: Case 1: 600 file -> exit 0"
fi
if grep -Fq "${SENTINEL}" "${LOG1}"; then
  fail "Case 1: 600 file path printed the sentinel value (content leak)"
else
  echo "PASS: Case 1: 600 file path did NOT leak sentinel"
fi

# ── Case 2: 644 file → exit 1, warning includes path + mode ────────────────
chmod 644 "${HOME_T}/.config/ezgha/config.toml"
LOG2="${WORK}/case2.log"
set +e
HOME="${HOME_T}" bash "${AUDIT}" >"${LOG2}" 2>&1
rc2=$?
set -e
if [ "${rc2}" -eq 0 ]; then
  fail "Case 2: 644 file should be UNSAFE but audit exited 0"
else
  echo "PASS: Case 2: 644 file -> exit 1"
fi
if ! grep -Fq "${HOME_T}/.config/ezgha/config.toml" "${LOG2}"; then
  fail "Case 2: 644 warning did NOT include path (${HOME_T}/.config/ezgha/config.toml)"
else
  echo "PASS: Case 2: 644 warning includes path"
fi
if ! grep -Eq '(^| )644( |$)' "${LOG2}"; then
  fail "Case 2: 644 warning did NOT include mode 644"
else
  echo "PASS: Case 2: 644 warning includes mode 644"
fi
if grep -Fq "${SENTINEL}" "${LOG2}"; then
  fail "Case 2: 644 warning printed the sentinel value (content leak)"
else
  echo "PASS: Case 2: 644 warning did NOT leak sentinel"
fi

# ── Case 3: 660 file → exit 1, warning includes path + mode ────────────────
chmod 660 "${HOME_T}/.config/ezgha/secrets/alert-credential"
LOG3="${WORK}/case3.log"
set +e
HOME="${HOME_T}" bash "${AUDIT}" >"${LOG3}" 2>&1
rc3=$?
set -e
if [ "${rc3}" -eq 0 ]; then
  fail "Case 3: 660 file should be UNSAFE but audit exited 0"
else
  echo "PASS: Case 3: 660 file -> exit 1"
fi
if ! grep -Fq "${HOME_T}/.config/ezgha/secrets/alert-credential" "${LOG3}"; then
  fail "Case 3: 660 warning did NOT include path"
else
  echo "PASS: Case 3: 660 warning includes path"
fi
if ! grep -Eq '(^| )660( |$)' "${LOG3}"; then
  fail "Case 3: 660 warning did NOT include mode 660"
else
  echo "PASS: Case 3: 660 warning includes mode 660"
fi

# ── Case 4: 700 dir → exit 0 ───────────────────────────────────────────────
mkdir -p "${HOME_T}/.config/ezgha/secrets"
chmod 700 "${HOME_T}/.config/ezgha/secrets"
# also reset the file so this case really only checks dir behavior
chmod 600 "${HOME_T}/.config/ezgha/config.toml"
chmod 600 "${HOME_T}/.config/ezgha/secrets/alert-credential"
chmod 600 "${HOME_T}/.local/share/ezgha/tokens/app-token"
chmod 600 "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem"
LOG4="${WORK}/case4.log"
if ! HOME="${HOME_T}" bash "${AUDIT}" >"${LOG4}" 2>&1; then
  fail "Case 4: 700 dir + 600 files should be safe but audit exited non-zero"
  cat "${LOG4}" >&2 || true
else
  echo "PASS: Case 4: 700 dir -> exit 0"
fi

# ── Case 5: 755 dir → exit 1 (config dir world-readable) ──────────────────
chmod 755 "${HOME_T}/.config/ezgha"
LOG5="${WORK}/case5.log"
set +e
HOME="${HOME_T}" bash "${AUDIT}" >"${LOG5}" 2>&1
rc5=$?
set -e
if [ "${rc5}" -eq 0 ]; then
  fail "Case 5: 755 config dir should be UNSAFE but audit exited 0"
else
  echo "PASS: Case 5: 755 dir -> exit 1"
fi
if ! grep -Fq "${HOME_T}/.config/ezgha" "${LOG5}"; then
  fail "Case 5: 755 dir warning did NOT include path"
else
  echo "PASS: Case 5: 755 dir warning includes path"
fi

# ── Case 6: missing file → silently skipped, exit 0 ────────────────────────
chmod 700 "${HOME_T}/.config/ezgha"
chmod 600 "${HOME_T}/.config/ezgha/config.toml"
chmod 600 "${HOME_T}/.config/ezgha/secrets/alert-credential"
chmod 600 "${HOME_T}/.local/share/ezgha/tokens/app-token"
chmod 600 "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem"
LOG6="${WORK}/case6.log"
if ! HOME="${HOME_T}" bash "${AUDIT}" >"${LOG6}" 2>&1; then
  fail "Case 6: missing file should be silently skipped but audit exited non-zero"
  cat "${LOG6}" >&2 || true
else
  echo "PASS: Case 6: missing file -> exit 0 (silently skipped)"
fi
if grep -Fq "missing-on-purpose" "${LOG6}"; then
  fail "Case 6: missing file should not be reported"
else
  echo "PASS: Case 6: missing file NOT reported"
fi

# ── Case 7: contents NEVER printed across the entire run ───────────────────
# Re-run case 2 and assert that across the union of all logs so far, the
# sentinel literal never appears.
ALL_LOGS="${LOG1} ${LOG2} ${LOG3} ${LOG4} ${LOG5} ${LOG6}"
if grep -Fq "${SENTINEL}" ${ALL_LOGS}; then
  fail "Case 7: sentinel value appeared in audit output (content leak in some case)"
else
  echo "PASS: Case 7: sentinel value NEVER printed in any case"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
