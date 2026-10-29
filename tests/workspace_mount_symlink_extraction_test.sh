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
# Follow-up understanding (2026-07-19/20): the corruption is not
# limited to the three GitHub-Actions-runner-internal cache dirs. ANY
# tar extraction of an archive containing a symlink onto this mount is
# affected, including under the real checkout path
# (_work/<owner>/<repo>) -- exercised by workflow steps like `npm ci`,
# downloaded release tarballs, `docker save`/`load`, and git submodule
# tarballs. Step 4 below reproduces this specifically and proves the fix.
#
# Workspace fix: a `/usr/local/bin/tar` wrapper baked into the runner image
# (docker/tar-workspace-wrapper.sh) stages every extraction under _work on
# the container overlay before copying it to virtiofs. The daemon flags the
# workspace mount with EZGHA_VIRTIOFS_WORKSPACE=1. Keep _actions and _tool
# ordinary: the runner deletes _actions at job setup, and this image configures
# RUNNER_TOOL_CACHE outside _work. The daemon mounts only _temp as executable
# tmpfs for setup-gcloud's SDK extraction.
#
# Usage: bash tests/workspace_mount_symlink_extraction_test.sh
# SDK peak canary (separate explicit mode; requires a pinned version and URL):
#   EZGHA_RUN_SDK_TMPFS_CANARY=1 EZGHA_SDK_VERSION=<version> \
#   EZGHA_SDK_ARCHIVE_URL=https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-<version>-linux-x86_64.tar.gz \
#   EZGHA_SDK_SHA256=<official-sha256> \
#   bash tests/workspace_mount_symlink_extraction_test.sh
# This mode requires the official archive SHA-256, skips the default virtiofs
# suite, and uses one named, auto-removed Docker container.
#
# Requires: docker reachable (DOCKER_HOST must point at the real daemon
# socket on Colima/Mac hosts), ezgha-runner:latest image present (rebuild
# with `DOCKER_BUILDKIT=0 docker build --file="$repo_root/Dockerfile.runner" -t
# ezgha-runner:latest "$repo_root"` after any change to docker/tar-workspace-wrapper.sh
# so step 4 exercises the current wrapper, not a stale image).

set -u
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

info()  { printf '  [..] %s\n' "$1"; }
ok()    { printf '  [OK] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

SDK_TMPFS_CANARY="${EZGHA_RUN_SDK_TMPFS_CANARY:-0}"
if [[ "${SDK_TMPFS_CANARY}" != "0" && "${SDK_TMPFS_CANARY}" != "1" ]]; then
  echo "FAIL: EZGHA_RUN_SDK_TMPFS_CANARY must be 0 or 1" >&2
  exit 2
fi

if ! docker version >/dev/null 2>&1; then
  if [[ "${SDK_TMPFS_CANARY}" == "1" ]]; then
    echo "FAIL: SDK tmpfs canary requires a reachable Docker daemon" >&2
    exit 1
  fi
  echo "SKIP: docker daemon unreachable (set DOCKER_HOST if using Colima) -- cannot run this integration test"
  exit 0
fi

IMAGE="${EZGHA_TEST_IMAGE:-ezgha-runner:latest}"
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  if [[ "${SDK_TMPFS_CANARY}" == "1" ]]; then
    echo "FAIL: SDK tmpfs canary requires the existing image ${IMAGE}; refusing to pull or build" >&2
    exit 1
  fi
  echo "SKIP: ${IMAGE} not present locally -- build it first (docker build --file=\"${repo_root}/Dockerfile.runner\" -t ezgha-runner:latest \"${repo_root}\")"
  exit 0
fi

run_sdk_tmpfs_canary() {
  : "${EZGHA_SDK_VERSION:?set EZGHA_SDK_VERSION to the pinned Google Cloud SDK version}"
  : "${EZGHA_SDK_ARCHIVE_URL:?set EZGHA_SDK_ARCHIVE_URL to the pinned version official Linux archive}"
  : "${EZGHA_SDK_SHA256:?set EZGHA_SDK_SHA256 to the official archive SHA-256}"
  if [[ ! "${EZGHA_SDK_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "FAIL: invalid pinned SDK version: ${EZGHA_SDK_VERSION}" >&2
    return 2
  fi
  if [[ -n "${EZGHA_SDK_SHA256:-}" && ! "${EZGHA_SDK_SHA256}" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "FAIL: EZGHA_SDK_SHA256 must be 64 hexadecimal characters" >&2
    return 2
  fi

  image_arch=$(docker image inspect --format '{{.Architecture}}' "${IMAGE}")
  case "${image_arch}" in
    amd64) sdk_arch=x86_64 ;;
    arm64) sdk_arch=arm ;;
    *) echo "FAIL: unsupported runner image architecture: ${image_arch}" >&2; return 2 ;;
  esac
  expected_url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${EZGHA_SDK_VERSION}-linux-${sdk_arch}.tar.gz"
  if [[ "${EZGHA_SDK_ARCHIVE_URL}" != "${expected_url}" ]]; then
    echo "FAIL: archive URL does not match the official pinned SDK version/architecture" >&2
    echo "Expected: ${expected_url}" >&2
    return 2
  fi

  container_name="ezgha-sdk-tmpfs-canary-$$"
  if docker container inspect "${container_name}" >/dev/null 2>&1; then
    echo "FAIL: refusing to touch pre-existing container ${container_name}" >&2
    return 2
  fi
  docker_env=(
    -e "EZGHA_SDK_VERSION=${EZGHA_SDK_VERSION}"
    -e "EZGHA_SDK_ARCHIVE_URL=${EZGHA_SDK_ARCHIVE_URL}"
    -e "EZGHA_SDK_SHA256=${EZGHA_SDK_SHA256}"
  )
  cleanup_sdk_canary() {
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
  }
  trap cleanup_sdk_canary EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  echo "=== SDK tmpfs canary: version=${EZGHA_SDK_VERSION} image_arch=${image_arch} memory=3072MiB swap=0 ==="
  echo "Archive: ${EZGHA_SDK_ARCHIVE_URL}"
  docker run --pull=never --rm --name "${container_name}" \
    --memory=3072m --memory-swap=3072m \
    --tmpfs /home/runner/_work/_temp:exec \
    --entrypoint /bin/bash \
    -e EZGHA_VIRTIOFS_WORKSPACE=1 \
    -e RUNNER_TEMP=/home/runner/_work/_temp \
    "${docker_env[@]}" "${IMAGE}" -euo pipefail -c '
      temp_root=/home/runner/_work/_temp
      mkdir -p "${temp_root}"
      actions=/home/runner/_work/_actions
      mkdir -p "${actions}/canary"
      printf "removable\n" > "${actions}/canary/probe"
      rm -rf "${actions}"
      test ! -e "${actions}"
      mkdir -p "${actions}"
      echo "actions_removable=true"

      download_dir="${temp_root}/download"
      extract_dir="${temp_root}/extract"
      mkdir -p "${download_dir}" "${extract_dir}"
      archive="${download_dir}/google-cloud-sdk.tar.gz"
      curl --fail --location --silent --show-error \
        "${EZGHA_SDK_ARCHIVE_URL}" --output "${archive}"
      printf "%s  %s\n" "${EZGHA_SDK_SHA256}" "${archive}" | sha256sum --check --status
      echo "archive_sha256_verified=true"

      # Match setup-gcloud v2.1.0 extraction flags recorded in the failed job.
      tar xz --warning=no-unknown-keyword --overwrite -f "${archive}" -C "${extract_dir}"
      sdk_dir=""
      for candidate in google-cloud-sdk google-cloud-cli; do
        if [[ -x "${extract_dir}/${candidate}/bin/gcloud" ]]; then
          sdk_dir="${extract_dir}/${candidate}"
          break
        fi
      done
      test -n "${sdk_dir}"
      gcloud="${sdk_dir}/bin/gcloud"
      test -x "${gcloud}"
      actual_version=$("${gcloud}" --version | sed -n "1s/^Google Cloud SDK //p")
      test "${actual_version}" = "${EZGHA_SDK_VERSION}"
      echo "gcloud_executable=true"
      echo "gcloud_version=${actual_version}"
      echo "tmpfs_df_begin"
      df -PT -B1 "${temp_root}"
      echo "tmpfs_df_end"
      fs_type=$(df -PT "${temp_root}" | awk "NR == 2 { print \$2 }")
      test "${fs_type}" = tmpfs
      tmpfs_used_bytes=$(df -P -B1 "${temp_root}" | awk "NR == 2 { print \$3 }")
      tmpfs_du_bytes=$(du -sb "${temp_root}" | awk "{ print \$1 }")

      if [[ -r /sys/fs/cgroup/memory.peak && -r /sys/fs/cgroup/memory.max ]]; then
        cgroup_version=2
        memory_peak=$(cat /sys/fs/cgroup/memory.peak)
        memory_max=$(cat /sys/fs/cgroup/memory.max)
        memory_current=$(cat /sys/fs/cgroup/memory.current)
      elif [[ -r /sys/fs/cgroup/memory/memory.max_usage_in_bytes && -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        cgroup_version=1
        memory_peak=$(cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes)
        memory_max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        memory_current=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes)
      else
        echo "FAIL: no readable cgroup memory peak/limit counters" >&2
        exit 1
      fi
      test "${memory_max}" -eq 3221225472
      remaining_bytes=$((memory_max - memory_peak))
      echo "tmpfs_used_bytes=${tmpfs_used_bytes}"
      echo "tmpfs_du_bytes=${tmpfs_du_bytes}"
      echo "cgroup_version=${cgroup_version}"
      echo "cgroup_memory_peak_bytes=${memory_peak}"
      echo "cgroup_memory_max_bytes=${memory_max}"
      echo "cgroup_memory_current_bytes=${memory_current}"
      echo "cgroup_memory_remaining_bytes=${remaining_bytes}"
      if (( remaining_bytes < 536870912 )); then
        echo "FAIL: remaining cgroup memory margin is below 512 MiB" >&2
        exit 1
      fi
      echo "remaining_memory_margin_at_least_512MiB=true"
    '
}

if [[ "${SDK_TMPFS_CANARY}" == "1" ]]; then
  run_sdk_tmpfs_canary
  exit $?
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
# the tar wrapper only changes extraction calls when its workspace flag is
# set. Kept here purely so a
# future reader can see the raw bug still exists upstream, unfixed at the
# platform level, and confirm the fix works by the wrapper flag rather than
# by accident (bug silently going away everywhere).
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
  info "confirmed: raw virtiofs bind mount root still corrupts symlink extraction (expected without the tar-wrapper flag)"
elif printf '%s' "${MOUNT_OUT}" | grep -q "real content"; then
  info "raw mount root extraction succeeded -- underlying virtiofs bug may have been fixed upstream (Colima/vz update?)"
else
  bad "unexpected output extracting into the workspace bind mount root: ${MOUNT_OUT}"
fi

echo "=== 3. Bind-fixture check: _actions is removable; _temp/_tool fixtures remain usable ==="
for runner_dir in _actions _temp _tool; do
  mkdir -p "${HOST_WORKSPACE}/${runner_dir}"
  echo "stale runner data" > "${HOST_WORKSPACE}/${runner_dir}/runner-setup-stale"
done
FIXED_OUT=$(docker run --rm \
  -e EZGHA_VIRTIOFS_WORKSPACE=1 \
  -v "${WORKDIR}/repro.tar.gz:/tmp/repro.tar.gz:ro" \
  -v "${HOST_WORKSPACE}:/home/runner/_work" \
  "${IMAGE}" sh -c '
    set -u
    for runner_dir in _actions _temp _tool; do
      target="/home/runner/_work/${runner_dir}"
      delete_rc=0
      rm -rf "${target}" || delete_rc=$?
      echo "delete-${runner_dir}-rc=${delete_rc}"
      mkdir -p "${target}"
      probe="${target}/ezgha-exec-probe"
      printf "#!/bin/sh\necho exec-%s-ok\n" "${runner_dir}" > "${probe}"
      chmod 0755 "${probe}"
      "${probe}"
    done
    mkdir -p /home/runner/_work/_actions/cache-test
    cd /home/runner/_work/_actions/cache-test
    tar -xzf /tmp/repro.tar.gz 2>&1
    echo "---read---"
    cat pkg/data/inner/target.txt 2>&1
  ' 2>&1)
echo "${FIXED_OUT}" | sed 's/^/    /'
if printf '%s' "${FIXED_OUT}" | grep -q "delete-_actions-rc=0" \
  && printf '%s' "${FIXED_OUT}" | grep -q "delete-_temp-rc=0" \
  && printf '%s' "${FIXED_OUT}" | grep -q "delete-_tool-rc=0" \
  && printf '%s' "${FIXED_OUT}" | grep -q "real content" \
  && printf '%s' "${FIXED_OUT}" | grep -q "exec-_actions-ok" \
  && printf '%s' "${FIXED_OUT}" | grep -q "exec-_temp-ok" \
  && printf '%s' "${FIXED_OUT}" | grep -q "exec-_tool-ok"; then
  ok "bind fixtures preserve _actions removability and guarded extraction behavior"
else
  bad "runner internal directory cleanup or guarded extraction failed: ${FIXED_OUT}"
fi

echo "=== 4. Fix verification: checkout-path (_work/<owner>/<repo>) extraction is now guarded by the tar wrapper ==="
# This is the scope this test covers: real job checkouts. First prove the
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
