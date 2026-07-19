#!/bin/bash
# ezgha tar wrapper (bead jleechan-93cf follow-up, 2026-07-19/20).
#
# (comment-only touch to trigger the mac-virtiofs-canary.yml path filter for
# a real dispatch verification -- see PR description; no behavior change.)
#
# Baked into the runner image at /usr/local/bin/tar, which resolves ahead of
# the real GNU tar at /usr/bin/tar in this image's PATH -- so any workflow
# step that invokes the bare `tar` CLI (e.g. `curl ... | tar xzf -`, a
# manual `tar xzf release.tar.gz`, or the actions-runner's own action/
# tool-cache download-and-extract logic) goes through here first. The real
# binary is never moved or modified.
#
# SCOPE, confirmed by a real adversarial probe (2026-07-19/20): this wrapper
# only helps callers that actually shell out to the `tar` binary. npm,
# pip/wheel, and Docker's own save/load all use in-process, library-based
# archive handling (npm's bundled JS tar package, Python's zipfile/tarfile,
# Docker's Go archive/tar) -- they never touch /usr/local/bin/tar, so this
# wrapper does not and cannot intercept them. A real npm-install probe on
# this exact image also showed npm's own symlink creation succeeding fine on
# the virtiofs mount (it isn't exposed to the tar-specific bug at all), so
# the earlier assumption that this wrapper was needed for npm/pip/docker was
# simply wrong -- do not re-add that claim without a fresh repro proving it.
#
# ALSO out of scope, TWO DISTINCT known limitations (confirmed 2026-07-19/20,
# do not conflate with the symlink bug this wrapper fixes or with each
# other):
#  1. A regular file archived with mode 000 (or any mode lacking owner-read)
#     fails to extract DIRECTLY onto this virtiofs mount ("Cannot open:
#     Permission denied") even with no wrapper involved at all, and even as
#     root. This is a pre-existing virtiofs/FUSE limitation unrelated to
#     this fix.
#  2. Separately, THIS wrapper's own two-phase design (extract to stage,
#     then `cp -a` stage to the real destination) has a structural gap for
#     the exact same kind of file: GNU tar's first phase writes the file's
#     content, then applies the archived mode as its last step for that
#     member -- so tar itself never needs to re-read the file afterward. But
#     `cp -a`'s copy phase DOES need to open the stage copy for reading, and
#     if a member's archived mode already blocks owner-read (e.g. 000), `cp`
#     -- like any non-root process -- genuinely cannot read it, on ANY
#     filesystem. This is not virtiofs-specific; it is an inherent cost of
#     splitting extraction into two phases. Real-world CI archives (symlinks
#     included, which this wrapper does fix) essentially always keep files
#     owner-readable, so this is treated as an accepted, narrow, documented
#     gap rather than something worth the complexity of solving (e.g.
#     temporarily forcing owner-read during staging, then re-deriving and
#     re-applying the true archived mode after the copy -- a real but much
#     more complex design, revisit if this shows up in production).
#
# Why this exists: when the daemon's workspace_host_path bind mount is in
# use (see docker_backend.rs), /home/runner/_work is a virtiofs-backed host
# mount on Colima/Mac. Tar-extracting an archive containing a symlink member
# directly onto that mount corrupts the symlink into a 0-byte, mode-000,
# unreadable file ("Permission denied") -- confirmed with actions/
# setup-python's own tarball and a synthetic archive. A plain `ln -s` (direct
# syscall) on the same mount works fine, and tar extraction into the
# container's own overlay filesystem (e.g. /tmp) also works fine -- only
# tar-extracting a real archive onto the virtiofs mount is broken. The daemon
# already tmpfs-shadows the three fixed runner-internal cache dirs (_actions,
# _temp, _tool), but real job checkouts under _work/<owner>/<repo> -- the
# dominant disk-churn win this mount exists for -- are NOT shadowed and
# remain exposed whenever a workflow step tar-extracts something there,
# AFTER actions/checkout has already populated the directory (the realistic
# production shape -- a fresh/empty destination is the exception, not the
# rule, since checkout runs first in virtually every real job).
#
# Fix, twice-revised after adversarial review found real regressions in
# earlier versions of this script:
#  v1 (rejected): stage into a fresh empty temp dir, then unconditionally
#     `cp -a` over the real destination. This defeats GNU tar's own
#     overwrite-protection flags (--keep-old-files, --skip-old-files, etc.)
#     whenever the destination already has content -- confirmed live:
#     `tar --keep-old-files` returned rc=2 and preserved existing content
#     when run directly, but rc=0 and silently overwrote when routed through
#     this naive staging approach.
#  v2 (rejected): only stage when the destination is missing or empty,
#     falling through to native tar otherwise. This avoids the v1 regression
#     but doesn't fix anything in the realistic case: after actions/checkout
#     populates _work/<owner>/<repo>, EVERY subsequent tar call in the job
#     sees a non-empty destination, so v2 never engages and the symlink
#     corruption bug remains fully exposed for real jobs -- confirmed live
#     with a populated-checkout fixture.
#  v3 (current): MIRROR the existing destination content into the stage
#     dir first (cheap -- tmpfs/overlay to tmpfs/overlay, or a no-op for a
#     fresh/empty destination), run the real tar extraction in the stage,
#     then sync the stage back onto the real destination with `cp -a`
#     (lstat/symlink-preserving syscalls, confirmed safe on this mount).
#     Because the stage starts as a faithful copy of the real destination,
#     GNU tar's own collision/overwrite-protection logic sees the exact same
#     pre-existing files it would see extracting in place, so
#     --keep-old-files (and default silent-overwrite) behave identically to
#     unwrapped tar -- and because the stage lives on tmpfs/overlay, the
#     actual member writes (including symlinks) never touch virtiofs until
#     the final `cp -a` sync, which is confirmed safe. Tar's real exit code
#     is always propagated, and the sync always runs (even on a tar error),
#     matching native tar's own partial-extraction-then-stop behavior.
#
# Known cost of v3: mirroring copies the ENTIRE existing destination tree
# into the stage before every guarded extraction, and syncs it all back
# after. For a large already-populated checkout (e.g. a monorepo with many
# workflow steps each doing their own `tar` call), this is O(destination
# size) per call, not free. Correctness was prioritized over this
# performance cost given the alternative was a real, evidenced symlink-
# corruption bug in the dominant real-world call shape. Revisit if this
# shows up as a measurable latency regression in production job timings.
#
# ponytail: this only detects the common tar invocation shapes actually seen
# in CI workflows (`tar -xzf ...[-C dir]`, `tar xzf ...[-C dir]` old-style
# bundling, `--extract`/`--directory[=]`). It does not attempt to parse every
# GNU tar option combination, or `..`-normalization of the destination path.
# Ceiling: if extraction ever silently misdetects, the fallback is the
# ORIGINAL bug (status quo), never a NEW regression -- see
# tests/workspace_mount_symlink_extraction_test.sh for the covered shapes.
# Upgrade path: replace with a real tar-option parser if a missed shape
# shows up in production job logs.
#
# EXPLICIT CARVE-OUT, found by adversarial review (2026-07-20): GNU tar
# supports MULTIPLE `-C`/`--directory` occurrences in one invocation, each
# scoping only the members listed AFTER it (per-member directory targeting,
# e.g. `tar -C dirA -xf a.tar sub1/f -C dirB sub2/f`), rare but real (some
# release-packaging scripts use this). Collapsing every `-C` into a single
# trailing `-C "${stage}"` (placed after ALL member names) is unsafe here:
# GNU tar ignores a `-C` that has no member names following it, so it
# silently extracts relative to whatever cwd it inherited instead -- rc=0,
# looking successful, while the real destinations end up empty and files
# land somewhere unrelated. That is NOT the disclosed "falls back to the
# original bug" ceiling above -- it is a distinct, WORSE failure mode
# (silent success with misplaced output) that this wrapper must not permit.
# Confirmed via live repro: unwrapped tar correctly splits members across
# both directories; the naive single-trailing-`-C` rewrite left both empty.
# Mitigation: detect 2+ `-C`/`--directory` occurrences up front and bail
# out to the real tar unmodified BEFORE doing any staging -- this correctly
# re-exposes the known, disclosed symlink-corruption gap for this narrow
# shape (matching the documented fallback contract) rather than silently
# misplacing files.

set -euo pipefail

REAL_TAR=/usr/bin/tar
WORKSPACE_ROOT=/home/runner/_work

# Fast path: no virtiofs-backed workspace mount in this container (or the
# daemon didn't opt into it) -- nothing to guard against, run the real tar.
if [ -z "${EZGHA_VIRTIOFS_WORKSPACE:-}" ]; then
  exec "${REAL_TAR}" "$@"
fi

# Bail out up front if this invocation uses multiple -C/--directory
# occurrences -- see the "EXPLICIT CARVE-OUT" header comment above. Must be
# checked before any staging decision, and does not need extract/-C-value
# parsing since a single grep-style pass over the raw args is sufficient
# and cannot itself misfire (worst case: an archive filename that happens
# to literally equal "-C" -- vanishingly rare, and even then the fallback
# is just the disclosed status quo, never a new regression).
c_flag_count=0
for arg in "$@"; do
  case "${arg}" in
    -C|--directory|--directory=*)
      c_flag_count=$((c_flag_count + 1))
      ;;
  esac
done
if [ "${c_flag_count}" -ge 2 ]; then
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

# Path-boundary check: must be an exact match on WORKSPACE_ROOT or have it
# as a genuine "/"-terminated prefix -- a raw string-prefix test would wrongly
# treat a sibling directory like /home/runner/_workevil as "under"
# /home/runner/_work.
under_workspace=0
if [ "${abs_dest}" = "${WORKSPACE_ROOT}" ] || [ "${abs_dest#"${WORKSPACE_ROOT}"/}" != "${abs_dest}" ]; then
  under_workspace=1
fi

if [ "${extract}" = "1" ] && [ "${under_workspace}" = "1" ]; then
  stage="$(mktemp -d /tmp/ezgha-tar-stage.XXXXXX)"
  trap 'rm -rf "${stage}"' EXIT
  # Mirror any pre-existing destination content into the stage first, so
  # tar's own collision/overwrite-protection semantics see the same state
  # they would extracting in place. A no-op when the destination is fresh.
  if [ -e "${abs_dest}" ]; then
    cp -a "${abs_dest}/." "${stage}/" 2>/dev/null || true
  fi
  set +e
  "${REAL_TAR}" "${filtered[@]}" -C "${stage}"
  tar_rc=$?
  # Always sync back, even on a tar error -- matches native tar's own
  # partial-extraction-then-stop behavior (whatever succeeded before the
  # failure should still land; the mirror above ensures anything that
  # correctly failed to overwrite is also correctly still the old content).
  mkdir -p "${abs_dest}"
  cp -a "${stage}/." "${abs_dest}/"
  sync_rc=$?
  set -e
  # Prefer tar's own exit code (it reflects the actual extraction outcome);
  # if tar succeeded but the sync itself failed (e.g. an archived member's
  # mode blocks even the owner from reading it back out of the stage -- see
  # the header comment), surface the sync failure instead of falsely
  # reporting success.
  if [ "${tar_rc}" != "0" ]; then
    exit "${tar_rc}"
  fi
  exit "${sync_rc}"
fi

exec "${REAL_TAR}" "$@"
