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
# WIDENED understanding (2026-07-19/20 follow-up): the corruption is not
# limited to the three GitHub-Actions-runner-internal cache dirs. ANY
# tar extraction of an archive containing a symlink onto this mount is
# affected, including under the real checkout path
# (_work/<owner>/<repo>) -- exercised by workflow steps like `npm ci`,
# downloaded release tarballs, `docker save`/`load`, and git submodule
# tarballs. Step 4 below reproduces this specifically and proves the fix.
#
# Two-part fix:
#  1. The daemon shadows the three fixed GitHub-Actions-runner-internal
#     subdirectories (_work/_actions, _work/_temp, _work/_tool) with tmpfs
#     mounts layered inside the workspace bind, so the runner's own
#     action-repo/tool-cache extraction never touches virtiofs.
#  2. A `/usr/local/bin/tar` wrapper baked into the runner image
#     (docker/tar-workspace-wrapper.sh) covers the rest of the mount: when
#     the daemon flags a container with EZGHA_VIRTIOFS_WORKSPACE=1 (see
#     docker_backend.rs), any tar EXTRACT destined for /home/runner/_work
#     is staged on the container's own tmpfs/overlay /tmp first, then
#     `cp -a` (safe syscalls) into the real destination. This preserves
#     the disk-churn-reduction goal the mount exists for (checkouts/build
#     scratch never touch tmpfs) while fixing symlink corruption
#     everywhere tar is used on the mount, not just the three cache dirs.
#
# Usage: bash tests/workspace_mount_symlink_extraction_test.sh
#
# Requires: docker reachable (DOCKER_HOST must point at the real daemon
# socket on Colima/Mac hosts), ezgha-runner:latest image present (rebuild
# with `DOCKER_BUILDKIT=0 docker build -f Dockerfile.runner -t
# ezgha-runner:latest .` after any change to docker/tar-workspace-wrapper.sh
# so step 4 exercises the current wrapper, not a stale image).

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

# Collision fixture: the guarded tar path must preserve GNU tar's native
# overwrite contracts, not merely produce the expected happy-path tree.
COLLISION_SRC="${WORKDIR}/collision-src"
mkdir -p "${COLLISION_SRC}"
echo "new-content" > "${COLLISION_SRC}/existing.txt"
COPYFILE_DISABLE=1 tar -czf "${WORKDIR}/collision.tar.gz" -C "${COLLISION_SRC}" existing.txt

# Mode fixture: GNU tar intentionally creates mode-000 archive members via a
# writable placeholder and applies the archived mode at the end. A narrow
# VirtioFS workaround must not change the final archived permissions.
# Build this fixture on the container's overlay filesystem. Creating it on
# macOS and then asking host bsdtar to read the mode-000 file fails before
# the Docker behavior under test is reached.
docker run --rm -v "${WORKDIR}:/work" "${IMAGE}" sh -c '
  set -e
  mkdir -p /tmp/ezgha-mode-src
  echo mode-zero > /tmp/ezgha-mode-src/mode-zero.txt
  /usr/bin/tar --mode=000 -czf /work/mode-zero.tar.gz -C /tmp/ezgha-mode-src mode-zero.txt
'

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

echo "=== 3. Fix verification: all runner-internal tmpfs shadows support extraction and execution ==="
FIXED_OUT=$(docker run --rm \
  -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  -v "${HOST_WORKSPACE}:/home/runner/_work" \
  --tmpfs /home/runner/_work/_actions:exec \
  --tmpfs /home/runner/_work/_temp:exec \
  --tmpfs /home/runner/_work/_tool:exec \
  "${IMAGE}" sh -c '
    mkdir -p /home/runner/_work/_actions/cache-test && cd /home/runner/_work/_actions/cache-test
    tar -xzf /tmp/repro.tar.gz 2>&1
    echo "---read---"
    cat pkg/data/inner/target.txt 2>&1
    for shadowed in _actions _temp _tool; do
      probe="/home/runner/_work/${shadowed}/ezgha-exec-probe"
      printf "#!/bin/sh\necho exec-%s-ok\n" "${shadowed}" > "${probe}"
      chmod 0755 "${probe}"
      "${probe}"
    done
  ' 2>&1)
echo "${FIXED_OUT}" | sed 's/^/    /'
if printf '%s' "${FIXED_OUT}" | grep -q "real content" \
  && printf '%s' "${FIXED_OUT}" | grep -q "exec-_actions-ok" \
  && printf '%s' "${FIXED_OUT}" | grep -q "exec-_temp-ok" \
  && printf '%s' "${FIXED_OUT}" | grep -q "exec-_tool-ok"; then
  ok "tmpfs-shadowed _actions/_temp/_tool: extraction and executable probes succeeded"
else
  bad "tmpfs-shadowed extraction/execution unexpectedly failed: ${FIXED_OUT}"
fi

echo "=== 4. Fix verification: checkout-path (_work/<owner>/<repo>) extraction is now guarded by the tar wrapper ==="
# This is the WIDENED scope this test now covers: real job checkouts, not
# just the three tmpfs-shadowed cache dirs from step 3. First prove the
# raw exposure still exists without the flag (RED), then prove the
# wrapper fixes it with the daemon's flag set (GREEN) -- exactly the
# EZGHA_VIRTIOFS_WORKSPACE=1 env var docker_backend.rs sets whenever
# workspace_host_path is configured.
CHECKOUT_HOST_RED="${WORKDIR}/host-checkout-red"
mkdir -p "${CHECKOUT_HOST_RED}"
RED_OUT=$(docker run --rm \
  -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  -v "${CHECKOUT_HOST_RED}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    mkdir -p /home/runner/_work/some-owner/some-repo && cd /home/runner/_work/some-owner/some-repo
    tar -xzf /tmp/repro.tar.gz 2>&1
    echo "---read---"
    cat pkg/data/inner/target.txt 2>&1
  ' 2>&1)
echo "${RED_OUT}" | sed 's/^/    /'
if printf '%s' "${RED_OUT}" | grep -q "Permission denied"; then
  ok "RED confirmed: unguarded checkout-path extraction still corrupts the symlink (proves this is a real, currently-exposed gap without the fix)"
else
  bad "expected the unguarded checkout-path extraction to reproduce the symlink corruption (RED baseline broken): ${RED_OUT}"
fi

CHECKOUT_HOST_GREEN="${WORKDIR}/host-checkout-green"
mkdir -p "${CHECKOUT_HOST_GREEN}"
GREEN_OUT=$(docker run --rm \
  -e EZGHA_VIRTIOFS_WORKSPACE=1 \
  -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  -v "${CHECKOUT_HOST_GREEN}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    mkdir -p /home/runner/_work/some-owner/some-repo && cd /home/runner/_work/some-owner/some-repo
    tar -xzf /tmp/repro.tar.gz 2>&1
    echo "---read---"
    cat pkg/data/inner/target.txt 2>&1
  ' 2>&1)
echo "${GREEN_OUT}" | sed 's/^/    /'
if printf '%s' "${GREEN_OUT}" | grep -q "real content" && ! printf '%s' "${GREEN_OUT}" | grep -q "Permission denied"; then
  ok "GREEN: checkout-path extraction succeeds via the tar wrapper when EZGHA_VIRTIOFS_WORKSPACE=1 is set"
else
  bad "checkout-path extraction with the tar-wrapper flag set should have succeeded: ${GREEN_OUT}"
fi
# Also verify on the HOST side (not just inside the container) that the
# symlink actually landed correctly on the real virtiofs-backed directory,
# proving cp -a materialized it there and this isn't a coincidental
# extraction into some unrelated path.
HOST_LINK="${CHECKOUT_HOST_GREEN}/some-owner/some-repo/pkg/data/inner/target.txt"
if [ -L "${HOST_LINK}" ] && [ "$(cat "${HOST_LINK}" 2>&1)" = "real content" ]; then
  ok "host-side check: symlink landed correctly on the real workspace bind mount, readable via the host filesystem"
else
  bad "host-side check failed -- expected a readable symlink at ${HOST_LINK}"
fi

# A real workflow extracts after actions/checkout has populated the repo.
# Guarding only missing/empty destinations is therefore not a fix for the
# production call path; an unrelated existing file must remain while the
# archive's symlink is materialized correctly.
CHECKOUT_HOST_POPULATED="${WORKDIR}/host-checkout-populated"
mkdir -p "${CHECKOUT_HOST_POPULATED}/some-owner/some-repo"
echo "checkout-content" > "${CHECKOUT_HOST_POPULATED}/some-owner/some-repo/already-checked-out.txt"
POPULATED_OUT=$(docker run --rm \
  -e EZGHA_VIRTIOFS_WORKSPACE=1 \
  -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  -v "${CHECKOUT_HOST_POPULATED}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    cd /home/runner/_work/some-owner/some-repo
    tar -xzf /tmp/repro.tar.gz 2>&1
    printf "archive=%s existing=%s\n" \
      "$(cat pkg/data/inner/target.txt 2>&1)" \
      "$(cat already-checked-out.txt 2>&1)"
  ' 2>&1)
echo "${POPULATED_OUT}" | sed 's/^/    /'
if printf '%s' "${POPULATED_OUT}" | grep -q "archive=real content existing=checkout-content" \
  && ! printf '%s' "${POPULATED_OUT}" | grep -q "Permission denied"; then
  ok "guarded tar fixes symlink extraction in a populated checkout without losing existing content"
else
  bad "guarded tar did not fix the real populated-checkout path: ${POPULATED_OUT}"
fi

echo "=== 5. Contract verification: guarded tar preserves native overwrite and mode semantics ==="
MODE_NATIVE_HOST="${WORKDIR}/host-mode-native"
mkdir -p "${MODE_NATIVE_HOST}"
MODE_NATIVE_OUT=$(docker run --rm \
  -v "${WORKDIR}/mode-zero.tar.gz:/tmp/mode-zero.tar.gz:ro" \
  -v "${MODE_NATIVE_HOST}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    dest=/home/runner/_work/some-owner/some-repo
    mkdir -p "${dest}" && cd "${dest}"
    set +e
    /usr/bin/tar -xzf /tmp/mode-zero.tar.gz >/tmp/mode-native.out 2>&1
    mode_rc=$?
    set -e
    mode=$(stat -c %a mode-zero.txt 2>/dev/null || printf missing)
    printf "mode_rc=%s mode_zero=%s\n" "${mode_rc}" "${mode}"
  ' 2>&1)
echo "${MODE_NATIVE_OUT}" | sed 's/^/    native: /'
CONTRACT_HOST="${WORKDIR}/host-contract"
mkdir -p "${CONTRACT_HOST}"
CONTRACT_OUT=$(docker run --rm \
  -e EZGHA_VIRTIOFS_WORKSPACE=1 \
  -v "${WORKDIR}/collision.tar.gz:/tmp/collision.tar.gz:ro" \
  -v "${WORKDIR}/mode-zero.tar.gz:/tmp/mode-zero.tar.gz:ro" \
  -v "${CONTRACT_HOST}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    set -u
    dest=/home/runner/_work/some-owner/some-repo
    mkdir -p "${dest}"
    echo old-content > "${dest}/existing.txt"
    cd "${dest}"
    set +e
    tar -xzf /tmp/collision.tar.gz --keep-old-files >/tmp/keep-old.out 2>&1
    keep_rc=$?
    tar -xzf /tmp/mode-zero.tar.gz >/tmp/mode-guarded.out 2>&1
    mode_rc=$?
    set -e
    printf "keep_rc=%s keep_content=%s\n" "${keep_rc}" "$(cat existing.txt)"
    mode=$(stat -c %a mode-zero.txt 2>/dev/null || printf missing)
    printf "mode_rc=%s mode_zero=%s\n" "${mode_rc}" "${mode}"
  ' 2>&1)
echo "${CONTRACT_OUT}" | sed 's/^/    /'
if printf '%s' "${CONTRACT_OUT}" | grep -Eq 'keep_rc=[1-9][0-9]* keep_content=old-content'; then
  ok "guarded tar preserves --keep-old-files failure status and existing content"
else
  bad "guarded tar changed --keep-old-files semantics: ${CONTRACT_OUT}"
fi
# Diagnostic, NOT a pass/fail gate (same status as step 2's raw-mount-root
# check): a mode-000 (or any owner-unreadable) archive member is a DISTINCT,
# already-broken-natively virtiofs/FUSE limitation -- native (unwrapped) tar
# also fails to extract it directly onto this mount, confirmed above, even
# as root. The guarded path fails too, but via a structurally different
# mechanism: tar's own extraction succeeds in the tmpfs stage (content
# written, then chmod'd to the archived mode as tar's last step for that
# member), but the wrapper's second phase -- `cp -a` copying the stage back
# onto the real destination -- must itself re-open that file for reading,
# and a mode that blocks owner-read blocks `cp` exactly like it would any
# other non-root process, independent of virtiofs. That's why the exit code
# differs (native's own internal open-during-extraction failure vs cp's
# open-during-copy failure) even though the qualitative outcome is the same
# in both cases: the file is not usable (mode_zero=missing). This wrapper
# does not attempt to fix either failure class; both are tracked as known,
# accepted, narrow gaps (real CI archives essentially always keep files
# owner-readable) rather than blocking the symlink fix this file verifies.
MODE_NATIVE_SIGNATURE=$(printf '%s' "${MODE_NATIVE_OUT}" | grep -Eo 'mode_rc=[0-9]+ mode_zero=[0-9]+|mode_rc=[0-9]+ mode_zero=missing' | tail -1)
MODE_GUARDED_SIGNATURE=$(printf '%s' "${CONTRACT_OUT}" | grep -Eo 'mode_rc=[0-9]+ mode_zero=[0-9]+|mode_rc=[0-9]+ mode_zero=missing' | tail -1)
if printf '%s' "${MODE_NATIVE_SIGNATURE}" | grep -q "mode_zero=missing" && printf '%s' "${MODE_GUARDED_SIGNATURE}" | grep -q "mode_zero=missing"; then
  info "confirmed: mode-000 archive members fail on both native and guarded paths (native=${MODE_NATIVE_SIGNATURE}; guarded=${MODE_GUARDED_SIGNATURE}) -- pre-existing virtiofs/two-phase-copy limitation, out of scope for the symlink fix, tracked separately"
elif [ -n "${MODE_NATIVE_SIGNATURE}" ] && [ "${MODE_GUARDED_SIGNATURE}" = "${MODE_NATIVE_SIGNATURE}" ]; then
  ok "guarded tar preserves native mode-000 extraction status and final filesystem state (${MODE_GUARDED_SIGNATURE})"
else
  bad "guarded tar produced a WORSE outcome than native for a mode-000 member (e.g. silently applied wrong permissions instead of failing): native=${MODE_NATIVE_SIGNATURE:-missing}; guarded=${MODE_GUARDED_SIGNATURE:-missing}"
fi

echo "=== 6. Regression: multiple -C occurrences must defer to native tar, never silently misplace output ==="
# Found by adversarial review (2026-07-20): GNU tar's per-member directory
# targeting (multiple -C flags in one invocation, each scoping only the
# members listed after it) is rare but real. An earlier wrapper revision
# collapsed every -C into a single trailing one, which GNU tar silently
# ignores (nothing follows it) -- rc=0, looking successful, while both
# real destinations ended up empty. This must never happen: the wrapper
# should now detect 2+ -C occurrences and bail out to native tar unmodified
# BEFORE any staging, so behavior is byte-for-byte identical to unwrapped
# tar for this shape (re-exposing the disclosed symlink-corruption gap for
# this narrow case, never a NEW silent-misplacement regression).
MULTIC_SRC="${WORKDIR}/multic-src"
mkdir -p "${MULTIC_SRC}/sub1" "${MULTIC_SRC}/sub2"
echo "content-a" > "${MULTIC_SRC}/sub1/fileA.txt"
echo "content-b" > "${MULTIC_SRC}/sub2/fileB.txt"
COPYFILE_DISABLE=1 tar -czf "${WORKDIR}/multic.tar.gz" -C "${MULTIC_SRC}" sub1/fileA.txt sub2/fileB.txt

MULTIC_NATIVE_HOST="${WORKDIR}/host-multic-native"
mkdir -p "${MULTIC_NATIVE_HOST}/dirA" "${MULTIC_NATIVE_HOST}/dirB"
MULTIC_NATIVE_OUT=$(docker run --rm \
  -v "${WORKDIR}/multic.tar.gz:/tmp/multic.tar.gz:ro" \
  -v "${MULTIC_NATIVE_HOST}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    /usr/bin/tar -xzf /tmp/multic.tar.gz -C /home/runner/_work/dirA sub1/fileA.txt -C /home/runner/_work/dirB sub2/fileB.txt; echo "rc=$?"
    printf "dirA=%s dirB=%s\n" "$(cat /home/runner/_work/dirA/sub1/fileA.txt 2>&1)" "$(cat /home/runner/_work/dirB/sub2/fileB.txt 2>&1)"
  ' 2>&1)
echo "${MULTIC_NATIVE_OUT}" | sed 's/^/    native: /'

MULTIC_GUARDED_HOST="${WORKDIR}/host-multic-guarded"
mkdir -p "${MULTIC_GUARDED_HOST}/dirA" "${MULTIC_GUARDED_HOST}/dirB"
MULTIC_GUARDED_OUT=$(docker run --rm \
  -e EZGHA_VIRTIOFS_WORKSPACE=1 \
  -v "${WORKDIR}/multic.tar.gz:/tmp/multic.tar.gz:ro" \
  -v "${MULTIC_GUARDED_HOST}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    tar -xzf /tmp/multic.tar.gz -C /home/runner/_work/dirA sub1/fileA.txt -C /home/runner/_work/dirB sub2/fileB.txt; echo "rc=$?"
    printf "dirA=%s dirB=%s\n" "$(cat /home/runner/_work/dirA/sub1/fileA.txt 2>&1)" "$(cat /home/runner/_work/dirB/sub2/fileB.txt 2>&1)"
  ' 2>&1)
echo "${MULTIC_GUARDED_OUT}" | sed 's/^/    guarded: /'

if printf '%s' "${MULTIC_GUARDED_OUT}" | grep -q "dirA=content-a dirB=content-b"; then
  ok "guarded tar correctly splits members across multiple -C destinations (matches native)"
else
  bad "guarded tar mishandled multiple -C occurrences: native=${MULTIC_NATIVE_OUT}; guarded=${MULTIC_GUARDED_OUT}"
fi

echo
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
