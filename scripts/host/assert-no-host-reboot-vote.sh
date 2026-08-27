#!/usr/bin/env bash
# Fail closed if watchdog repair can still vote for a host reboot.
# Repo copies are always checked. Installed and /etc copies are checked when present.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REPAIR_REPO="${REPO_ROOT}/scripts/host/watchdog-load-repair.sh"
CONF_REPO="${REPO_ROOT}/config/watchdog.conf"
# This remains /etc/watchdog.conf for the real host. Fixture tests inject a
# separate readable file while exercising the same live-check branch.
WATCHDOG_CONF_PATH="${WATCHDOG_CONF_PATH:-/etc/watchdog.conf}"
fail() { echo "FAIL: $*" >&2; exit 1; }

# watchdog(8) treats every active repair-maximum assignment as a daemon
# setting. A duplicate is ambiguous configuration and a missing setting falls
# back to the daemon's reboot-capable default. Accept exactly one active zero
# (with an optional trailing comment) and reject every other shape.
check_repair_maximum_zero() {
  local path="$1" active_count invalid_count
  read -r active_count invalid_count < <(
    awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*repair-maximum[[:space:]]*=/ {
        active++
        if ($0 !~ /^[[:space:]]*repair-maximum[[:space:]]*=[[:space:]]*0[[:space:]]*(#[^#]*)?$/) {
          invalid++
        }
      }
      END { print active + 0, invalid + 0 }
    ' "$path"
  )
  [ "$active_count" -eq 1 ] || fail "$path must contain exactly one active repair-maximum = 0 (found $active_count)"
  [ "$invalid_count" -eq 0 ] || fail "$path repair-maximum must be exactly 0 (watchdog can still reboot after a successful shed)"
}

# Parse the active repair-binary assignment exactly as watchdog(8) does.  The
# configured executable is the binary watchdog actually invokes; checking only
# the repository copy leaves a stale or unsafe installed path invisible.
read_repair_binary() {
  local path="$1" value count=0
  while IFS= read -r value; do
    count=$((count + 1))
    # watchdog.conf accepts a plain path.  Permit an inline comment and a
    # quoted value in fixtures, but reject an empty assignment below.
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == '"'*'"' && "$value" == *'"' ]]; then
      value="${value:1:${#value}-2}"
    fi
    REPAIR_BINARY_CONFIG_VALUE="$value"
  done < <(
    awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*repair-binary[[:space:]]*=/ {
        value=$0
        sub(/^[^=]*=/, "", value)
        print value
      }
    ' "$path"
  )
  [ "$count" -eq 1 ] || fail "$path must contain exactly one active repair-binary assignment (found $count)"
  [ -n "${REPAIR_BINARY_CONFIG_VALUE:-}" ] || fail "$path repair-binary assignment is empty"
  [[ "$REPAIR_BINARY_CONFIG_VALUE" = /* ]] \
    || fail "$path repair-binary must be an absolute path (got $REPAIR_BINARY_CONFIG_VALUE)"
}

check_repair_binary_script() {
  local configured="$1" resolved canonical_digest configured_digest
  [ -r "$configured" ] || fail "configured repair-binary is unreadable: $configured"
  [ -f "$configured" ] || fail "configured repair-binary is not a regular file: $configured"
  [ -x "$configured" ] || fail "configured repair-binary is not executable: $configured"
  resolved="$(readlink -f -- "$configured" 2>/dev/null || true)"
  [ -n "$resolved" ] || fail "configured repair-binary path cannot be resolved: $configured"
  [ -f "$resolved" ] || fail "resolved repair-binary is not a regular file: $resolved"
  [ -r "$resolved" ] || fail "resolved repair-binary is unreadable: $resolved"
  [ -x "$resolved" ] || fail "resolved repair-binary is not executable: $resolved"

  # The configured path is the executable watchdog will invoke.  Text scans
  # are insufficient here: a stale wrapper can contain shed-complete while
  # exiting early, enabling set -e, or delegating to an unsafe payload.  Bind
  # it byte-for-byte to the canonical artifact checked into this revision.
  command -v sha256sum >/dev/null 2>&1 \
    || fail "sha256sum is required to verify configured repair-binary provenance"
  if ! canonical_digest="$(sha256sum -- "$REPAIR_REPO" 2>/dev/null)"; then
    fail "cannot compute canonical repair-binary digest: $REPAIR_REPO"
  fi
  if ! configured_digest="$(sha256sum -- "$resolved" 2>/dev/null)"; then
    fail "cannot compute configured repair-binary digest: $resolved"
  fi
  canonical_digest="${canonical_digest%% *}"
  configured_digest="${configured_digest%% *}"
  [[ "$canonical_digest" =~ ^[[:xdigit:]]{64}$ ]] \
    || fail "cannot compute canonical repair-binary digest: $REPAIR_REPO"
  [[ "$configured_digest" =~ ^[[:xdigit:]]{64}$ ]] \
    || fail "cannot compute configured repair-binary digest: $resolved"
  [ "$configured_digest" = "$canonical_digest" ] \
    || fail "$configured repair-binary digest mismatch (expected canonical $canonical_digest, got $configured_digest)"
}

[ -f "$REPAIR_REPO" ] || fail "missing $REPAIR_REPO"
[ -r "$REPAIR_REPO" ] || fail "canonical repair-binary is unreadable: $REPAIR_REPO"
[ -x "$REPAIR_REPO" ] || fail "canonical repair-binary is not executable: $REPAIR_REPO"
if grep -q 'log result reboot-eligible' "$REPAIR_REPO"; then
  fail "$REPAIR_REPO still logs reboot-eligible"
fi
if grep -q '^exit 1$' "$REPAIR_REPO"; then
  fail "$REPAIR_REPO still exits 1"
fi
if ! grep -q 'log result shed-complete' "$REPAIR_REPO"; then
  fail "$REPAIR_REPO missing shed-complete"
fi
if ! grep -q '^exit 0$' "$REPAIR_REPO"; then
  fail "$REPAIR_REPO missing exit 0"
fi
check_repair_maximum_zero "$CONF_REPO"

check_installed() {
  local path="$1"
  [ -f "$path" ] || return 0
  if grep -q 'log result reboot-eligible' "$path"; then
    fail "$path still logs reboot-eligible"
  fi
  if grep -q '^exit 1$' "$path"; then
    fail "$path still exits 1"
  fi
}

check_installed "${HOME}/.local/bin/watchdog-load-repair.sh"
check_installed "${HOME}/.local/libexec/ezgha/watchdog-load-repair.sh"

# /etc/watchdog.conf is the reboot voter watchdog(8) actually reads. Only
# check it when ASSERT_LIVE_WATCHDOG=1 so CI images are not graded as this
# host. Goal completion REQUIRES this live, read-only check.
if [ "${ASSERT_LIVE_WATCHDOG:-0}" = "1" ]; then
  [ -r "$WATCHDOG_CONF_PATH" ] || fail "live watchdog config is unreadable: $WATCHDOG_CONF_PATH"
  check_repair_maximum_zero "$WATCHDOG_CONF_PATH"
  read_repair_binary "$WATCHDOG_CONF_PATH"
  check_repair_binary_script "$REPAIR_BINARY_CONFIG_VALUE"
fi

echo "PASS: no-host-reboot-vote contract holds for checked copies"
