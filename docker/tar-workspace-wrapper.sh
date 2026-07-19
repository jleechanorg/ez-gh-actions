#!/bin/bash
# ezgha tar wrapper (bead jleechan-93cf follow-up, 2026-07-19/20).
#
# Baked into the runner image at /usr/local/bin/tar, which resolves ahead of
# the real GNU tar at /usr/bin/tar in this image's PATH -- so every `tar`
# invocation a workflow step makes (npm ci, downloaded release tarballs,
# docker save/load, actions-runner's own action/tool-cache download, etc.)
# goes through here first. The real binary is never moved or modified.
#
# Why this exists: when the daemon's workspace_host_path bind mount is in
# use (see docker_backend.rs), /home/runner/_work is a virtiofs-backed host
# mount on Colima/Mac. Tar-extracting an archive containing a symlink member
# directly onto that mount corrupts the symlink into a 0-byte, mode-000,
# unreadable file ("Permission denied") -- confirmed with actions/
# setup-python's own tarball and a synthetic npm-style archive. A plain
# `ln -s` (direct syscall) on the same mount works fine, and tar extraction
# into the container's own overlay filesystem (e.g. /tmp) also works fine --
# only tar-extracting a real archive onto the virtiofs mount is broken. The
# daemon already tmpfs-shadows the three fixed runner-internal cache dirs
# (_actions, _temp, _tool), but real job checkouts under
# _work/<owner>/<repo> -- the dominant disk-churn win this mount exists for
# -- are NOT shadowed and remain exposed whenever a workflow step tar-
# extracts something there.
#
# Fix: when this container has the mount (EZGHA_VIRTIOFS_WORKSPACE=1, set
# by the daemon only when workspace_host_path is configured -- see
# docker_backend.rs), any tar EXTRACT whose destination resolves under
# /home/runner/_work is staged into a fresh directory under /tmp (this
# container's own tmpfs/overlay filesystem, never virtiofs), then copied
# into the real destination with `cp -a`, which uses lstat/symlink-preserving
# syscalls that are confirmed safe on this mount. Every other invocation
# (archive creation, listing, or extraction outside the workspace mount)
# passes straight through to the real tar untouched -- zero behavior change
# when EZGHA_VIRTIOFS_WORKSPACE is unset (the common case for installs that
# don't opt into workspace_host_path).
#
# ponytail: this only detects the common tar invocation shapes actually seen
# in CI workflows (`tar -xzf ...[-C dir]`, `tar xzf ...[-C dir]` old-style
# bundling, `--extract`/`--directory[=]`). It does not attempt to parse
# every GNU tar option combination (e.g. multiple chained -C flags for
# multi-directory extraction from one archive). Ceiling: if extraction ever
# silently misdetects, the fallback is the ORIGINAL bug (status quo), never
# worse -- see tests/workspace_mount_symlink_extraction_test.sh step 4 for
# the covered shapes. Upgrade path: replace with a real tar-option parser if
# a missed shape shows up in production job logs.

set -euo pipefail

REAL_TAR=/usr/bin/tar
WORKSPACE_ROOT=/home/runner/_work

# Fast path: no virtiofs-backed workspace mount in this container (or the
# daemon didn't opt into it) -- nothing to guard against, run the real tar.
if [ -z "${EZGHA_VIRTIOFS_WORKSPACE:-}" ]; then
  exec "${REAL_TAR}" "$@"
fi

extract=0
dest="${PWD}"
filtered=()

# GNU tar's old System-V-style bundling: if the first argument doesn't
# start with '-', it's a cluster of short options (e.g. `tar xzf a.tar.gz`).
if [ $# -gt 0 ]; then
  first="$1"
  case "${first}" in
    -*) ;;
    *x*) extract=1 ;;
  esac
fi

skip_next=0
for arg in "$@"; do
  if [ "${skip_next}" = "1" ]; then
    dest="${arg}"
    skip_next=0
    continue
  fi
  case "${arg}" in
    -C|--directory)
      skip_next=1
      continue
      ;;
    --directory=*)
      dest="${arg#--directory=}"
      continue
      ;;
    -x|--extract|--get)
      extract=1
      ;;
    -*)
      case "${arg}" in
        *x*) extract=1 ;;
      esac
      ;;
  esac
  filtered+=("${arg}")
done

case "${dest}" in
  /*) abs_dest="${dest}" ;;
  *) abs_dest="${PWD}/${dest}" ;;
esac

if [ "${extract}" = "1" ] && [ "${abs_dest#"${WORKSPACE_ROOT}"}" != "${abs_dest}" ]; then
  stage="$(mktemp -d /tmp/ezgha-tar-stage.XXXXXX)"
  trap 'rm -rf "${stage}"' EXIT
  mkdir -p "${abs_dest}"
  "${REAL_TAR}" "${filtered[@]}" -C "${stage}"
  cp -a "${stage}/." "${abs_dest}/"
  exit 0
fi

exec "${REAL_TAR}" "$@"
