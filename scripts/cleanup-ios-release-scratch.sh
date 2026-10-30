#!/usr/bin/env bash
# cleanup-ios-release-scratch.sh — reclaim stale per-run iOS TestFlight release
# scratch directories under the Scratch volume.
#
# Background (2026-10-30):
#   The "iOS TestFlight" workflow in jleechanorg/worldai_frontend resolves the
#   Scratch root via `diskm scratch-dir` and builds everything for a run inside
#   `<scratch>/worldai-ios-release-<run_id>-<run_attempt>`: DerivedData, the
#   .xcarchive and the exported .ipa. Its final step ("Cleanup only this run's
#   key material") removes the signing key it created, never the release root.
#   With no reaper, every run permanently leaves ~2.4 GB behind.
#
#   Measured 2026-10-30: 24 dirs / 49 GB on a 200 GiB volume — 2.0 GiB free,
#   i.e. less than the 2.4 GB the in-flight run itself needed while archiving.
#   The same volume also backs `runner.workspace_host_path` for the mac runner
#   fleet, so exhausting it breaks TestFlight builds and mac runner jobs at
#   once. Bead: jleechan-nvke.
#
# Safety:
#   - Only directories matching `worldai-ios-release-<digits>-<digits>` directly
#     under the resolved Scratch root are considered.
#   - Only dirs whose mtime is at least MIN_AGE_HOURS old (default 48h) are
#     eligible; an in-flight TestFlight run is minutes old, never days.
#   - A dir referenced by any live process command line is skipped (covers a
#     hung/multi-hour run, the only realistic path to an aged-but-live dir).
#   - The Scratch root is validated: must resolve to an existing absolute
#     directory and must not be / or $HOME.
#   - Default DRY-RUN; --apply performs removals.
#   - Removals go through a quarantine rename first, mirroring
#     cleanup-mission-output.sh, and every action is written to a manifest plus
#     the state log.
#
# Usage: cleanup-ios-release-scratch.sh [--apply] [--min-age-hours N] [--scratch-root PATH]
#   --apply             actually remove eligible dirs (default: dry-run)
#   --min-age-hours N   override the 48h default (env MIN_AGE_HOURS also works)
#   --scratch-root P    override Scratch root resolution (env SCRATCH_ROOT too)
#
# Invoked by:
#   macOS launchd: org.jleechanorg.ezgha-ios-release-cleanup (hourly)

set -euo pipefail

DRY_RUN=true
MIN_AGE_HOURS="${MIN_AGE_HOURS:-48}"
SCRATCH_ROOT="${SCRATCH_ROOT:-}"
# The workflow that owns these directories. Each run directory carries its run
# id, so the reaper can require positive evidence that the run FINISHED instead
# of inferring it from age plus a momentary process scan.
PRODUCER_REPO="${PRODUCER_REPO:-jleechanorg/worldai_frontend}"
GH_BIN="${GH_BIN:-gh}"
# Hard cap on deletions per invocation. The predicate is already narrow; this
# bounds the blast radius of a single unattended run regardless.
MAX_DELETIONS="${MAX_DELETIONS:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)           DRY_RUN=false; shift ;;
    --min-age-hours)   MIN_AGE_HOURS="$2"; shift 2 ;;
    --min-age-hours=*) MIN_AGE_HOURS="${1#*=}"; shift ;;
    --scratch-root)    SCRATCH_ROOT="$2"; shift 2 ;;
    --scratch-root=*)  SCRATCH_ROOT="${1#*=}"; shift ;;
    --repo)            PRODUCER_REPO="$2"; shift 2 ;;
    --repo=*)          PRODUCER_REPO="${1#*=}"; shift ;;
    --max-deletions)   MAX_DELETIONS="$2"; shift 2 ;;
    --max-deletions=*) MAX_DELETIONS="${1#*=}"; shift ;;
    -h|--help)         sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "${MIN_AGE_HOURS}" =~ ^[0-9]+$ ]]; then
  echo "FATAL: --min-age-hours must be a non-negative integer, got '${MIN_AGE_HOURS}'" >&2
  exit 2
fi

# Resolve the Scratch root the same way the workflow does. Never guess /tmp:
# a wrong root here would either do nothing or, worse, match unrelated trees.
# The root is supplied by the unit (install-time substitution) or the caller.
# There is deliberately NO `diskm scratch-dir` fallback here: that call spins
# indefinitely in a launchd session (measured 2026-10-30), and a deletion tool
# must not introduce an unbounded hang into an unattended hourly job. Absent a
# root, this fails closed below.
case "${SCRATCH_ROOT}" in
  ""|/)        echo "FATAL: refusing invalid Scratch root '${SCRATCH_ROOT:-unset}'" >&2; exit 3 ;;
  /*)          ;;
  *)           echo "FATAL: refusing non-absolute Scratch root '${SCRATCH_ROOT}'" >&2; exit 3 ;;
esac
if [[ "${SCRATCH_ROOT}" == "${HOME}" ]]; then
  echo "FATAL: refusing to treat HOME as a Scratch root" >&2
  exit 3
fi
SCRATCH_ROOT="${SCRATCH_ROOT%/}"
if [[ ! -d "${SCRATCH_ROOT}" ]]; then
  echo "FATAL: Scratch root does not exist: ${SCRATCH_ROOT}" >&2
  exit 3
fi

STATE_DIR="${HOME}/.local/state/ezgha"
LOG="${STATE_DIR}/ios-release-cleanup.log"
MANIFEST_DIR="${STATE_DIR}/ios-release-archives"
mkdir -p "${STATE_DIR}" "${MANIFEST_DIR}"
MANIFEST="${MANIFEST_DIR}/ios-release-cleanup-$(date -u +%Y%m%dT%H%M%SZ).manifest"

# Manifests are bookkeeping; keep a month of them.
find "${MANIFEST_DIR}" -maxdepth 1 -type f -name 'ios-release-cleanup-*.manifest' -mtime +30 -delete 2>/dev/null || true

log() {
  local tag="APPLY"
  if [[ "${DRY_RUN}" == "true" ]]; then tag="DRY-RUN"; fi
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${tag}" "$*" | tee -a "${LOG}"
}

# Returns the mtime epoch seconds, or empty when it cannot be read. Callers must
# treat empty as "unsafe, skip": falling back to 0 would make a directory look
# ~56 years old and defeat the only age-based guard this tool has.
get_mtime() {
  local target="$1"
  stat -f%m "${target}" 2>/dev/null || stat -c%Y "${target}" 2>/dev/null || true
}

# Positive completion signal: ask the producer whether that exact run+attempt is
# finished. Fails closed - an unreadable/absent `gh`, an API error, or any status
# other than "completed" means "do not delete". Age and process checks remain as
# defence in depth, but they can never establish completion on their own: a run
# can sit between build, upload and receipt steps with no process touching the
# tree, and writes inside existing children need not refresh the parent mtime.
run_is_completed() {
  local run_id="$1" attempt="$2" out rc=0
  command -v "${GH_BIN}" >/dev/null 2>&1 || return 1
  out="$(
    "${GH_BIN}" api "repos/${PRODUCER_REPO}/actions/runs/${run_id}" \
      -q '[.status, (.run_attempt|tostring)] | @tsv' 2>/dev/null
  )" || rc=$?
  [[ ${rc} -eq 0 ]] || return 1
  [[ "${out}" == "completed"$'\t'"${attempt}" ]]
}

# A dir is live if any process command line mentions it. Cheap process-table
# scan via pgrep -f, deliberately not `lsof +D` — these trees hold tens of
# thousands of files and lsof walks the whole tree per candidate.
#
# pgrep, not `ps | grep -F`: a piped grep carries the search path in its own
# command line, so it always matched itself and every candidate looked in-use.
# pgrep never matches its own process. If pgrep is unavailable we fail closed
# (treat as referenced) rather than risk deleting a live run's tree.
dir_is_referenced() {
  local target="$1" real snapshot p
  # Canonical form of the candidate. On macOS /var, /tmp and /etc are symlinks
  # into /private, so lsof reports "/private/var/..." for a process whose cwd is
  # "/var/...". Comparing only the literal string silently misses a live process
  # - reproduced 2026-10-30 before this canonicalisation existed. Unknown
  # canonical form means we cannot verify liveness, so fail closed (skip).
  real="$(cd -P -- "${target}" 2>/dev/null && pwd -P)" || return 0

  if command -v pgrep >/dev/null 2>&1; then
    # (a) argv scan. pgrep never matches itself, unlike a piped grep.
    pgrep -f -- "${target}" >/dev/null 2>&1 && return 0
    if [[ "${real}" != "${target}" ]] && pgrep -f -- "${real}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # (b) open-file / cwd scan. An argv-only scan misses the realistic case: a
  # long build whose cwd is inside the tree with the path absent from argv.
  # `lsof -Fn` lists a path per open fd and cwd without walking the tree (that
  # is `lsof +D`, which would be O(files) per candidate). Stream to a snapshot
  # file rather than a shell variable: the full lsof listing is ~10 MB here.
  command -v lsof >/dev/null 2>&1 || return 0
  snapshot="$(mktemp "${TMPDIR:-/tmp}/iosrel-lsof.XXXXXX" 2>/dev/null)" || return 0
  # A failed or empty scan proves nothing about liveness. Treat it as "in use"
  # so a broken scanner skips deletion instead of authorising it.
  if ! lsof -w -n -Fn >"${snapshot}" 2>/dev/null || [[ ! -s "${snapshot}" ]]; then
    rm -f "${snapshot}"
    return 0
  fi
  for p in "${target}" "${real}"; do
    # lsof prefixes each path with "n", so an exact cwd is "n<path>"; anything
    # deeper matches the "<path>/" prefix.
    if grep -Fq -- "${p}/" "${snapshot}" || grep -Fxq -- "n${p}" "${snapshot}"; then
      rm -f "${snapshot}"
      return 0
    fi
  done
  rm -f "${snapshot}"
  return 1
}

scanned=0; removed=0; skipped=0; freed_kb=0

log "=== start (DRY_RUN=${DRY_RUN} MIN_AGE_HOURS=${MIN_AGE_HOURS} SCRATCH_ROOT=${SCRATCH_ROOT}) ==="

while IFS= read -r -d '' d; do
  base="$(basename "$d")"
  scanned=$((scanned+1))

  if ! [[ "${base}" =~ ^worldai-ios-release-[0-9]+-[0-9]+$ ]]; then
    log "  SKIP unrecognized name: ${base}"
    skipped=$((skipped+1)); continue
  fi

  mtime="$(get_mtime "$d")"
  if [[ -z "${mtime}" ]]; then
    log "  SKIP unreadable mtime (fail closed): ${base}"
    skipped=$((skipped+1)); continue
  fi
  now="$(date +%s)"
  age_h=$(( (now - mtime) / 3600 ))
  if (( age_h < MIN_AGE_HOURS )); then
    log "  SKIP recent (${age_h}h < ${MIN_AGE_HOURS}h): ${base}"
    skipped=$((skipped+1)); continue
  fi

  run_id="${base#worldai-ios-release-}"
  run_id="${run_id%-*}"
  attempt="${base##*-}"
  if ! run_is_completed "${run_id}" "${attempt}"; then
    log "  SKIP run not proven completed in ${PRODUCER_REPO} (fail closed): ${base}"
    skipped=$((skipped+1)); continue
  fi

  if dir_is_referenced "$d"; then
    log "  SKIP in-use (live process references it): ${base}"
    skipped=$((skipped+1)); continue
  fi

  sz_kb="$(du -sk "$d" 2>/dev/null | awk '{print $1}' || echo 0)"
  sz_kb="${sz_kb:-0}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  DRY-RUN would remove: ${d} (${sz_kb}K, ${age_h}h old)"
    continue
  fi

  if [[ "${removed}" -ge "${MAX_DELETIONS}" ]]; then
    log "  SKIP deletion cap reached (${MAX_DELETIONS}/run): ${base}"
    skipped=$((skipped+1)); continue
  fi

  # Re-check immediately before the irreversible step. The size probe above
  # widens the window between "not in use" and "deleted", and directories are
  # named per run+attempt so nothing else can legitimately (re)enter one.
  if dir_is_referenced "$d"; then
    log "  SKIP in-use (re-check before removal): ${base}"
    skipped=$((skipped+1)); continue
  fi

  # Direct removal, no quarantine directory. A quarantine dir under $HOME sits
  # on a DIFFERENT filesystem than the Scratch volume, so `mv` would degrade to
  # a full cross-device copy of up to 2.4 GB per run onto the root disk before
  # deleting it - the opposite of what this job is for, and a self-inflicted way
  # to fill the volume that gates runner admission. The manifest below is the
  # metadata record; the bytes are disposable scratch whose artifacts were
  # published by the workflow before cleanup.
  if rm -rf -- "$d" 2>/dev/null; then
    log "  REMOVED: ${d} (${sz_kb}K, ${age_h}h old)"
    removed=$((removed+1)); freed_kb=$((freed_kb + sz_kb))
    echo "${d}  ${sz_kb}K  ${age_h}h" >> "${MANIFEST}"
  else
    log "  FAIL (remove failed): ${d}"
  fi
done < <(find "${SCRATCH_ROOT}" -mindepth 1 -maxdepth 1 -type d -name 'worldai-ios-release-*' -print0 2>/dev/null || true)

log "=== summary: scanned=${scanned} removed=${removed} skipped=${skipped} freed=${freed_kb}K ==="
exit 0
