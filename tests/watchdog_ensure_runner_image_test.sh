#!/usr/bin/env bash
# regression test: ezgha-fleet-watchdog.sh's ensure_runner_image() MUST
# actually rebuild a missing ezgha-runner:latest image (not just exit 0
# after grep-finding the function name).
#
# Root cause this guards against (2026-08-20, live incident): commit
# c35bb36 (2026-07-26) added ensure_runner_image() to the watchdog but
# used a RELATIVE '-f Dockerfile.runner' in the docker build command. Under
# launchd's cwd-of-/, every rebuild failed with:
#   "unable to prepare context: unable to evaluate symlinks in Dockerfile path:
#    lstat /Dockerfile.runner: no such file or directory"
#
# install.sh:619's sentinel ONLY checked for the *presence* of
# 'ensure_runner_image' (grep -q). The function existed, the sentinel
# passed, the underlying build command was silently broken. The bug
# produced 311+ silent REBUILD FAILED events over 19 days (every 120s of
# watchdog tick) before triggering the 2026-08-20 Mac fleet outage.
#
# Companion test to: install-gate-checks skill, CLAUDE.md "Sentinel
# checks at install time" section, bead jleechan-zgvz.
#
# What this test asserts (real Docker for image lifecycle, hermetic helper
# stub for path-resolution failure):
#   1. ensure_runner_image with image present is a no-op (exit 0,
#      marker file untouched, "already present" log line)
#   2. ensure_runner_image with image MISSING rebuilds successfully
#      (image present, marker file written, exit 0)
#   3. ensure_runner_image with a deliberately broken $repo_root
#      from a non-repository CWD FAILS loudly (exit non-zero with the
#      helper's observable cannot-locate-Dockerfile log, no silent
#      19-day cascade)
#
# Run: bash tests/watchdog_ensure_runner_image_test.sh [--keep-image]
# (default removes the test image at the end; --keep-image leaves it
# tagged ezgha-runner:test for manual inspection)

set -euo pipefail

# Resolve repo root (this script lives at tests/, repo root is ../)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WATCHDOG="${REPO_ROOT}/scripts/ezgha-fleet-watchdog.sh"
TEST_IMAGE="ezgha-runner:watchdog-test"
KEEP_IMAGE=0
[[ "${1:-}" == "--keep-image" ]] && KEEP_IMAGE=1

MARKER_DIR="$(mktemp -d -t ezgha-watchdog-test-XXXXXX)"
MARKER_FILE="${MARKER_DIR}/ensure_runner_image_ran"
trap 'rm -rf "${MARKER_DIR}"' EXIT

# Sanity: prerequisites
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker not on PATH" >&2; exit 2; }
[[ -f "${WATCHDOG}" ]] || { echo "FATAL: watchdog not at ${WATCHDOG}" >&2; exit 2; }

# Source the watchdog script directly so we test the REAL ensure_runner_image function.
# shellcheck source=scripts/ezgha-fleet-watchdog.sh
source "${WATCHDOG}"

# Exercise the real ensure_runner_image function from scripts/ezgha-fleet-watchdog.sh
run_ensure_runner_image() {
  local image="${1:-ezgha-runner:latest}"
  local repo_root="${REPO_ROOT}"
  local marker="${2:-${MARKER_FILE}}"

  export RUNNER_IMAGE="${image}"
  export EZGHA_REPO_ROOT="${repo_root}"
  export DRY_RUN=0
  export EZGHA_WATCHDOG_IMAGE_HEAL=1

  local had_image=0
  docker image inspect "${image}" >/dev/null 2>&1 && had_image=1

  # Call the REAL ensure_runner_image function!
  ensure_runner_image
  local rc=$?
  if [[ "$rc" -eq 0 && "$had_image" -eq 0 ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${marker}"
    echo "OK" >> "${marker}"
  fi
  return "$rc"
}

pass=0
fail=0
log_pass() { echo "PASS: $*"; pass=$((pass + 1)); }
log_fail() { echo "FAIL: $*"; fail=$((fail + 1)); }

# ---------- Test 1: image present is a no-op ----------
echo
echo "=== Test 1: ensure_runner_image with image present is a no-op ==="
# Pre-tag a throwaway image
docker tag "${TEST_IMAGE%-*}:latest" "${TEST_IMAGE}" 2>/dev/null || \
  docker pull alpine:3.19 >/dev/null 2>&1 && \
  docker tag alpine:3.19 "${TEST_IMAGE}"
rm -f "${MARKER_FILE}"
test1_output=""
test1_rc=0
if test1_output="$(run_ensure_runner_image "${TEST_IMAGE}" "${MARKER_FILE}" 2>&1)"; then
  :
else
  test1_rc=$?
fi
if [[ "${test1_rc}" -ne 0 ]]; then
  log_fail "Test 1: helper returned non-zero for present image (exit=${test1_rc}) — ${test1_output}"
elif ! grep -q "already present" <<<"${test1_output}"; then
  log_fail "Test 1: helper did not report the present image as a no-op — ${test1_output}"
elif [[ -f "${MARKER_FILE}" ]]; then
  log_fail "Test 1: marker written for present-image case (should be no-op)"
else
  log_pass "Test 1: present-image case is a clean no-op"
fi

# ---------- Test 2: image MISSING rebuilds successfully ----------
echo
echo "=== Test 2: ensure_runner_image with image MISSING rebuilds successfully ==="
# Remove the test image to simulate the outage state
docker rmi -f "${TEST_IMAGE}" 2>/dev/null || true
rm -f "${MARKER_FILE}"
# Run from / to prove the helper uses the absolute EZGHA_REPO_ROOT path rather
# than relying on the caller's working directory for Dockerfile.runner.
if (cd / && run_ensure_runner_image "${TEST_IMAGE}" "${MARKER_FILE}"); then
  if docker image inspect "${TEST_IMAGE}" >/dev/null 2>&1; then
    if [[ -f "${MARKER_FILE}" ]]; then
      log_pass "Test 2: missing image was rebuilt AND marker file written"
    else
      log_fail "Test 2: image rebuilt but marker file NOT written (silent failure class would recur)"
    fi
  else
    log_fail "Test 2: rebuild returned 0 but image is not present"
  fi
else
  log_fail "Test 2: rebuild failed for missing image"
fi

# ---------- Test 3: deliberately broken $repo_root fails LOUDLY ----------
echo
echo "=== Test 3: broken repo_root fails loudly (regression guard for line 366) ==="
# Invoke the REAL helper from an unrelated CWD with an invalid repo root.
# Stub only `docker image inspect` so the helper reaches its Dockerfile path
# resolution without changing any real container or service.
BAD_REPO="${MARKER_DIR}/missing-repo"
BAD_LOG=""
BAD_RC=0
if BAD_LOG="$(
  cd /
  EZGHA_REPO_ROOT="${BAD_REPO}" \
  RUNNER_IMAGE="${TEST_IMAGE}" \
  DRY_RUN=0 \
  EZGHA_WATCHDOG_IMAGE_HEAL=1 \
  bash -c '
    unset SCRIPTS_DIR SCRIPT_DIR
    source "$1"
    docker() { return 1; }
    ensure_runner_image
  ' /tmp/ezgha-watchdog-test "${WATCHDOG}"
)"; then
  :
else
  BAD_RC=$?
fi
if [[ "${BAD_RC}" -ne 0 ]] && grep -q "cannot locate Dockerfile.runner" <<<"${BAD_LOG}"; then
  log_pass "Test 3: helper fails loudly when Dockerfile.runner cannot be resolved from a non-repo CWD"
else
  log_fail "Test 3: helper did not fail loudly on an invalid repo root (exit=${BAD_RC}). Output: ${BAD_LOG}"
fi

# Cleanup
if [[ "${KEEP_IMAGE}" -ne 1 ]]; then
  docker rmi -f "${TEST_IMAGE}" 2>/dev/null || true
fi

echo
echo "=== Summary ==="
echo "PASS: ${pass}"
echo "FAIL: ${fail}"
if (( fail > 0 )); then
  exit 1
fi
echo "All watchdog ensure_runner_image behavioral checks passed."
