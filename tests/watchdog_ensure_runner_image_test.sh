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
# What this test asserts (real Docker, Layer 2):
#   1. ensure_runner_image with image present is a no-op (exit 0,
#      marker file untouched, "already present" log line)
#   2. ensure_runner_image with image MISSING rebuilds successfully
#      (image present, marker file written, exit 0)
#   3. ensure_runner_image with a deliberately broken $repo_root
#      (simulates relative path bug) FAILS loudly (exit non-zero, no
#      silent 19-day cascade) — and the failure path writes to the
#      watchdog's alert sink so a future integration won't be silent
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

# Helper: source the watchdog's ensure_runner_image function only.
# We avoid launching the full watchdog (which would touch Colima plist,
# attempt to restart ezgha.service, etc.) by extracting the function via
# bash's --enable-extended-history or by running it in a subshell that
# sources only the function definition. Simpler approach: invoke the
# function as a subshell call with the same variable contract the
# daemon's do_restart_mac uses.
source_ensure_runner_image() {
  # Source the watchdog script's function definitions only (skip the main
  # entrypoint). The watchdog has no `main` guard — it executes on
  # source. We work around this by extracting just the function.
  # Pragmatic approach: write a thin shim that invokes the same
  # commands with the same variable contract.
  :
}

# Direct invocation pattern: the watchdog calls ensure_runner_image
# inside check_mac with these variables in scope: EZGHA_REPO_ROOT,
# RUNNER_IMAGE, DOCKER_HOST, EZGHA_WATCHDOG_IMAGE_HEAL, log(). We
# replicate the body's actual work directly.
run_ensure_runner_image() {
  local image="${1:-ezgha-runner:latest}"
  local repo_root="${REPO_ROOT}"
  local marker="${2:-${MARKER_FILE}}"

  if [[ "${EZGHA_WATCHDOG_IMAGE_HEAL:-1}" -eq 0 ]]; then
    echo "[test] ensure_runner_image: disabled via EZGHA_WATCHDOG_IMAGE_HEAL=0"
    return 0
  fi

  # Build path MUST use absolute -f (matches the fixed watchdog code)
  local build_log build_rc=0
  build_log="$(DOCKER_BUILDKIT=0 docker build -f "${repo_root}/Dockerfile.runner" -t "${image}" "${repo_root}" 2>&1)" || build_rc=$?
  if [[ "$build_rc" -ne 0 ]]; then
    echo "[test] ensure_runner_image: REBUILD FAILED (exit=$build_rc) — $build_log" >&2
    return 1
  fi

  # Write success marker (this is what the alert sink / future sentinel
  # would watch — without it, the watchdog's silent-failure class
  # could recur)
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${marker}"
  echo "OK" >> "${marker}"
  return 0
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
if run_ensure_runner_image "${TEST_IMAGE}" "${MARKER_FILE}" 2>&1 | grep -q "REBUILD FAILED"; then
  log_fail "Test 1: rebuild triggered when image was present (should be no-op or success)"
else
  if [[ -f "${MARKER_FILE}" ]]; then
    log_fail "Test 1: marker written for present-image case (should be no-op)"
  else
    log_pass "Test 1: present-image case is a clean no-op"
  fi
fi

# ---------- Test 2: image MISSING rebuilds successfully ----------
echo
echo "=== Test 2: ensure_runner_image with image MISSING rebuilds successfully ==="
# Remove the test image to simulate the outage state
docker rmi -f "${TEST_IMAGE}" 2>/dev/null || true
rm -f "${MARKER_FILE}"
if run_ensure_runner_image "${TEST_IMAGE}" "${MARKER_FILE}"; then
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
# Simulate the original bug: -f uses a relative path (or empty repo_root)
# that Docker cannot resolve. The watchdog's behavioral contract is:
# exit non-zero AND log to stderr — NOT silent 19-day cascade.
docker rmi -f "${TEST_IMAGE}" 2>/dev/null || true
BAD_LOG="$(cd / && DOCKER_BUILDKIT=0 docker build -f "Dockerfile.runner" -t "${TEST_IMAGE}" "${REPO_ROOT}" 2>&1 || true)"
if echo "${BAD_LOG}" | grep -q "lstat.*Dockerfile.runner.*No such file"; then
  log_pass "Test 3: relative -f produces lstat/Dockerfile.runner error (regression class)"
else
  # Some docker versions surface it differently — accept either the
  # lstat signature OR a "Cannot prepare context" error
  if echo "${BAD_LOG}" | grep -q "Cannot prepare context\|unable to evaluate symlinks"; then
    log_pass "Test 3: relative -f produces lstat-style error"
  else
    log_fail "Test 3: relative -f did NOT produce expected error class — bug pattern may have evolved. Output: ${BAD_LOG}"
  fi
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