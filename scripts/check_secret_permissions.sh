#!/usr/bin/env bash
# scripts/check_secret_permissions.sh
#
# Audit known secret-bearing ezgha config files for unsafe permissions
# (group-writable or world-readable bits). Used by:
#   - the install migration hook (install.d/10-secret-permissions.sh),
#     which chmods violations to 600,
#   - doctor-runner / doctor.sh self-healing recipes (advisory),
#   - CI / operator pre-flight.
#
# Hard rules:
#   - NEVER print file contents. Only paths and mode bits.
#   - Missing files are silently skipped (the user may not have configured
#     a particular optional credential yet).
#   - Exit 0 if every present file is 600 or 700; exit 1 if any present
#     file has group-writable or world-readable bits.
#
# Test override: EZGHA_SECRET_AUDIT_PATHS (pipe-separated) replaces the
# default path list — used by tests/secret_permission_check_test.sh so
# the audit can be exercised hermetically without touching the real
# ~/.config/ezgha on the host.
#
# Usage: bash scripts/check_secret_permissions.sh

set -euo pipefail

# ── 1. Resolve the path list ──────────────────────────────────────────────
DEFAULT_PATHS=(
  "${HOME}/.config/ezgha"
  "${HOME}/.config/ezgha/secrets"
  "${HOME}/.local/share/ezgha"
  "${HOME}/.local/share/ezgha/tokens"
  "${HOME}/.config/ezgha/config.toml"
  "${HOME}/.config/ezgha/secrets/alert-credential"
  "${HOME}/.config/ezgha/secrets/slack-webhook"
  "${HOME}/.config/ezgha/secrets/alert-credentials"
  "${HOME}/.local/share/ezgha/tokens/app-token"
  "${HOME}/.local/share/ezgha/tokens/app_private_key.pem"
  "${HOME}/.config/ezgha/app_private_key.pem"
)

if [ -n "${EZGHA_SECRET_AUDIT_PATHS:-}" ]; then
  # Pipe-separated override (test harness only).
  IFS='|' read -r -a PATHS <<<"${EZGHA_SECRET_AUDIT_PATHS}"
else
  PATHS=("${DEFAULT_PATHS[@]}")
fi

# ── 2. Pick the right stat flavor ─────────────────────────────────────────
# Mac (BSD) stat: stat -f '%Lp %N' prints "<perm-octal> <name>"
# Linux (GNU) stat: stat -c '%a %n' prints "<perm-octal> <name>"
# We only ever read the perm-octal field; names are reconstructed from $1.
if stat -f '%Lp' /dev/null >/dev/null 2>&1; then
  STAT_GET_MODE() { stat -f '%Lp' "$1"; }
elif stat -c '%a' /dev/null >/dev/null 2>&1; then
  STAT_GET_MODE() { stat -c '%a' "$1"; }
else
  echo "check_secret_permissions: no usable stat(1) found on PATH" >&2
  exit 2
fi

UNSAFE=0
for path in "${PATHS[@]}"; do
  [ -z "${path}" ] && continue
  if [ ! -e "${path}" ]; then
    # Silently skipped — optional credential may not be configured.
    continue
  fi

  mode="$(STAT_GET_MODE "${path}" 2>/dev/null || echo "000")"

  # Decode the octal perm as a 3-digit number (ignore file-type bits).
  # Examples: "600" -> 600, "755" -> 755, "0644" -> 644, "4755" -> 755.
  perm="${mode: -3}"
  group_bit=$(( (perm / 10) % 10 ))   # tens digit (group r/w/x)
  other_bit=$(( perm % 10 ))          # ones digit (other r/w/x)
  group_r=$(( group_bit / 4 ))
  group_w=$(( (group_bit / 2) % 2 ))
  other_r=$(( other_bit / 4 ))
  other_w=$(( (other_bit / 2) % 2 ))

  bad=0
  if [ "${group_r}" -ne 0 ] || [ "${group_w}" -ne 0 ] || \
     [ "${other_r}" -ne 0 ] || [ "${other_w}" -ne 0 ]; then
    bad=1
  fi

  if [ "${bad}" -ne 0 ]; then
    echo "UNSAFE ${perm} ${path}" >&2
    UNSAFE=1
  fi
done

if [ "${UNSAFE}" -ne 0 ]; then
  exit 1
fi
exit 0
