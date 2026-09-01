#!/usr/bin/env bash
# regression test: static validation of the bead ez-gh-actions-0725 and Release 1
# host-pressure-relief artifacts (agents.slice, agent-scoped-launch.sh).
# This test NEVER starts/enables anything live -- it only checks syntax and structural wiring.
#
# Checks:
#   1. systemd/agents.slice -- valid unit syntax, 18G/20G envelope, auto OOM policies.
#   2. scripts/host/agent-scoped-launch.sh -- valid bash syntax (bash -n), no AGENT_SLICE_OPT_OUT.
#   3. legacy escape hatches and watcher/exemption artifacts are strictly absent:
#      - scripts/host/psi-oom-watcher.sh
#      - systemd/psi-oom-watcher.service
#      - systemd/psi-oom-watcher.timer
#      - systemd/ezgha.service.d/10-oomd-omit.conf
#
# Usage: bash tests/host_ops_0725_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}
ok() {
  echo "PASS: $1"
}

HAVE_SYSTEMD_ANALYZE=0
command -v systemd-analyze >/dev/null 2>&1 && HAVE_SYSTEMD_ANALYZE=1

looks_like_infra_failure() {
  grep -qiE 'failed to (connect to bus|lookup .*runtimedirectory|create bus connection|get (d-)?bus connection)|no such file or directory.*(bus|runtime)|system has not been booted with systemd|failed to create.*d-bus|could not connect to bus' "$1"
}

verify_unit() {
  local label="$1" unit_path="$2" fallback_fn="$3"
  local logfile="${WORK}/verify-log-${RANDOM}-${RANDOM}"
  if [ "${HAVE_SYSTEMD_ANALYZE}" -eq 1 ]; then
    if systemd-analyze verify --user "${unit_path}" >"${logfile}" 2>&1; then
      ok "${label} passes systemd-analyze verify --user"
      return 0
    fi
    if looks_like_infra_failure "${logfile}"; then
      echo "INFO: ${label}: systemd-analyze verify --user failed due to environment (no live user systemd session -- expected in containers/CI), falling back to structural check" >&2
    else
      fail "${label} failed systemd-analyze verify --user: $(cat "${logfile}")"
      return 1
    fi
  fi
  "${fallback_fn}"
}

# ── 1. agents.slice syntax and 18G/20G envelope ──────────────────────────────
SLICE="${REPO_ROOT}/systemd/agents.slice"
if [ ! -f "${SLICE}" ]; then
  fail "systemd/agents.slice does not exist"
else
  slice_structural_check() {
    if grep -q '^\[Slice\]' "${SLICE}" && grep -q '^MemoryHigh=' "${SLICE}"; then
      ok "systemd/agents.slice structural check: has [Slice] + MemoryHigh="
    else
      fail "systemd/agents.slice missing [Slice] section or MemoryHigh= directive"
    fi
  }
  verify_unit "systemd/agents.slice" "${SLICE}" slice_structural_check
  if ! grep -q '^MemoryHigh=18G$' "${SLICE}" || ! grep -q '^MemoryMax=20G$' "${SLICE}"; then
    fail "systemd/agents.slice does not carry the documented 18G high / 20G hard envelope"
  else
    ok "systemd/agents.slice has the documented 18G high / 20G hard envelope"
  fi
  if ! grep -q '^ManagedOOMMemoryPressure=auto$' "${SLICE}" || ! grep -q '^ManagedOOMSwap=auto$' "${SLICE}"; then
    fail "systemd/agents.slice missing ManagedOOMMemoryPressure=auto or ManagedOOMSwap=auto"
  else
    ok "systemd/agents.slice sets ManagedOOMMemoryPressure=auto and ManagedOOMSwap=auto"
  fi
fi

# ── 2. agent-scoped-launch.sh syntax and opt-out absence ─────────────────────
WRAPPER="${REPO_ROOT}/scripts/host/agent-scoped-launch.sh"
if [ ! -f "${WRAPPER}" ]; then
  fail "scripts/host/agent-scoped-launch.sh does not exist"
else
  if bash -n "${WRAPPER}" 2>"${WORK}/wrapper-syntax.log"; then
    ok "scripts/host/agent-scoped-launch.sh passes bash -n"
  else
    fail "scripts/host/agent-scoped-launch.sh failed bash -n: $(cat "${WORK}/wrapper-syntax.log")"
  fi

  if grep -q 'AGENT_SLICE_OPT_OUT' "${WRAPPER}"; then
    fail "scripts/host/agent-scoped-launch.sh still contains forbidden AGENT_SLICE_OPT_OUT escape hatch"
  else
    ok "scripts/host/agent-scoped-launch.sh has no AGENT_SLICE_OPT_OUT escape hatch"
  fi
fi

# ── 3. legacy watcher and exemption artifacts must be strictly absent ────────
for forbidden in \
  "${REPO_ROOT}/scripts/host/psi-oom-watcher.sh" \
  "${REPO_ROOT}/systemd/psi-oom-watcher.service" \
  "${REPO_ROOT}/systemd/psi-oom-watcher.timer" \
  "${REPO_ROOT}/systemd/ezgha.service.d/10-oomd-omit.conf"; do
  if [ -e "${forbidden}" ]; then
    fail "forbidden legacy artifact still exists: ${forbidden}"
  else
    ok "legacy artifact correctly absent: $(basename "${forbidden}")"
  fi
done

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
