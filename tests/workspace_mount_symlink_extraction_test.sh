#!/usr/bin/env bash
# regression test: tar extraction of an archive containing a relative
# symlink must succeed when the destination is the daemon's
# workspace_host_path bind mount (bead jleechan-93cf), exactly as GitHub's
# own actions-runner does when it downloads and extracts a cached action
# repository into `_work/_actions/<owner>-<repo>-<ref>`.
#
# Root cause this guards against (2026-07-19, live incident): 93cf moved
# /home/runner/_work from the container's ephemeral overlay writable layer
# to a host-mounted virtiofs bind (Colima/vz). A plain `ln -s` on that mount
# works fine, and extracting a real-world archive (verified live with
# actions/setup-python's own tarball) into the container's native overlay
# filesystem (/tmp) also works fine -- but extracting that SAME archive
# into the virtiofs-backed workspace mount corrupts any member that is a
# symlink into a 0-byte, mode-000, unreadable file, producing
# `tar: ...: Cannot open: Permission denied`. This broke real CI jobs
# using actions/setup-python, actions/setup-node, and actions/setup-gcloud
# (all of which have symlinks somewhere in their extracted tree) at a 41%
# (13/32) Mac job failure rate before this test existed.
#
# Fix: the daemon shadows the three fixed GitHub-Actions-runner-internal
# subdirectories (_work/_actions, _work/_temp, _work/_tool) with tmpfs
# mounts layered inside the workspace bind, so the runner's own
# action-repo/tool-cache extraction never touches virtiofs, while the
# actual disk-churn win (job checkouts + build scratch, which live directly
# under _work/<owner>/<repo>, not under the three shadowed dirs) is
# unaffected.
#
# Usage: bash tests/workspace_mount_symlink_extraction_test.sh
#
# Requires: docker reachable (DOCKER_HOST must point at the real daemon
# socket on Colima/Mac hosts), ezgha-runner:latest image present.

set -u

PASS=0
FAIL=0

info()  { printf '  [..] %s\n' "$1"; }
ok()    { printf '  [OK] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

if ! docker version >/dev/null 2>&1; then
  echo "SKIP: docker daemon unreachable (set DOCKER_HOST if using Colima) -- cannot run this integration test"
  exit 0
fi

IMAGE="${EZGHA_TEST_IMAGE:-ezgha-runner:latest}"
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "SKIP: ${IMAGE} not present locally -- build it first (docker build -f Dockerfile.runner -t ezgha-runner:latest .)"
  exit 0
fi

# Must live under a Colima virtiofs-allowlisted path (`colima ssh -- mount |
# grep virtiofs`) -- a host dir outside that allowlist silently bind-mounts
# as an empty phantom directory instead of erroring (see
# config/config.toml.mac.example), which would make this test fail with a
# misleading "Is a directory" error instead of testing the real bug.
ALLOWLISTED_TMP_BASE="${EZGHA_TEST_TMP_BASE:-$HOME/.cache}"
mkdir -p "${ALLOWLISTED_TMP_BASE}"
WORKDIR=$(mktemp -d "${ALLOWLISTED_TMP_BASE}/ezgha-symlink-test.XXXXXX")
trap 'rm -rf "${WORKDIR}"' EXIT

# ── Build a minimal synthetic archive mirroring the real failure shape:
# a directory containing a relative symlink to a sibling file, exactly like
# actions/setup-python's __tests__/data/inner/poetry.lock -> ../poetry.lock.
ARCHIVE_SRC="${WORKDIR}/archive-src"
mkdir -p "${ARCHIVE_SRC}/pkg/data/inner"
echo "real content" > "${ARCHIVE_SRC}/pkg/data/target.txt"
ln -s ../target.txt "${ARCHIVE_SRC}/pkg/data/inner/target.txt"
# COPYFILE_DISABLE avoids macOS bsdtar embedding com.apple.provenance xattr
# extended headers, which the container's GNU tar otherwise warns about
# (harmless noise, but keeps output clean for the asserts below).
COPYFILE_DISABLE=1 tar -czf "${WORKDIR}/repro.tar.gz" -C "${ARCHIVE_SRC}" pkg

echo "=== 1. Baseline: extraction into the container's own overlay filesystem (/tmp) ==="
BASELINE_OUT=$(docker run --rm -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  "${IMAGE}" sh -c '
    cd /tmp && tar -xzf repro.tar.gz && cat pkg/data/inner/target.txt
  ' 2>&1)
if printf '%s' "${BASELINE_OUT}" | grep -q "real content" && ! printf '%s' "${BASELINE_OUT}" | grep -q "Permission denied"; then
  ok "baseline (overlay fs) extraction + symlink read succeeded, as expected"
else
  bad "baseline (overlay fs) extraction unexpectedly failed -- test fixture itself is broken: ${BASELINE_OUT}"
fi

echo "=== 2. Diagnostic: raw virtiofs bind mount ROOT still corrupts symlinks (informational, NOT a pass/fail gate) ==="
# This is the underlying Colima/vz virtiofs limitation itself, at the mount
# root -- the fix below does not (and does not need to) touch this, since
# job checkouts are git-based, not tar-with-symlinks, and only the three
# fixed runner-internal cache dirs are shadowed. Kept here purely so a
# future reader can see the raw bug still exists upstream, unfixed at the
# platform level, and confirm the fix works by SCOPE (shadowed subdirs
# only), not by accident (bug silently going away everywhere).
HOST_WORKSPACE="${WORKDIR}/host-workspace"
mkdir -p "${HOST_WORKSPACE}"
MOUNT_OUT=$(docker run --rm \
  -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  -v "${HOST_WORKSPACE}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    cd /home/runner/_work && tar -xzf /tmp/repro.tar.gz 2>&1
    echo "---read---"
    cat pkg/data/inner/target.txt 2>&1
  ' 2>&1)
echo "${MOUNT_OUT}" | sed 's/^/    /'
if printf '%s' "${MOUNT_OUT}" | grep -q "Permission denied"; then
  info "confirmed: raw virtiofs bind mount root still corrupts symlink extraction (expected -- unfixed, out of scope; the fix shadows only _actions/_temp/_tool, tested in step 3)"
elif printf '%s' "${MOUNT_OUT}" | grep -q "real content"; then
  info "raw mount root extraction succeeded -- underlying virtiofs bug may have been fixed upstream (Colima/vz update?); re-evaluate whether the tmpfs shadow is still needed"
else
  bad "unexpected output extracting into the workspace bind mount root: ${MOUNT_OUT}"
fi

echo "=== 3. Fix verification: _actions is tmpfs-shadowed, so extraction there succeeds regardless ==="
FIXED_OUT=$(docker run --rm \
  -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  -v "${HOST_WORKSPACE}:/home/runner/_work" \
  --tmpfs /home/runner/_work/_actions \
  "${IMAGE}" sh -c '
    mkdir -p /home/runner/_work/_actions/cache-test && cd /home/runner/_work/_actions/cache-test
    tar -xzf /tmp/repro.tar.gz 2>&1
    echo "---read---"
    cat pkg/data/inner/target.txt 2>&1
  ' 2>&1)
echo "${FIXED_OUT}" | sed 's/^/    /'
if printf '%s' "${FIXED_OUT}" | grep -q "real content"; then
  ok "tmpfs-shadowed _actions subdir: extraction + symlink read succeeded (this is the fix's mechanism)"
else
  bad "tmpfs-shadowed _actions subdir extraction unexpectedly failed: ${FIXED_OUT}"
fi

echo
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
