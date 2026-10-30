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
#   - Only runs whose producer reports `completed`/`success` are reaped. Failed
#     and cancelled runs are retained on purpose: their scratch is the cheapest
#     debugging evidence for a broken build, and their count is small.
#   - Default DRY-RUN; --apply performs removals.
#   - Removal is a direct rm of the validated path. There is deliberately no
#     quarantine directory: $HOME and the Scratch volume are different
#     filesystems, so a "quarantine" move would copy up to 2.4 GB per run onto
#     the root disk before deleting it. A metadata manifest plus the state log
#     record every action.
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
# Collapse repeated leading/trailing slashes so "//" cannot masquerade as a valid
# absolute root and then canonicalise to "/".
SCRATCH_ROOT="$(printf '%s' "${SCRATCH_ROOT}" | sed 's#//*#/#g')"
case "${SCRATCH_ROOT}" in
  ""|/)        echo "FATAL: refusing invalid Scratch root '${SCRATCH_ROOT:-unset}'" >&2; exit 3 ;;
  /*)          ;;
  *)           echo "FATAL: refusing non-absolute Scratch root '${SCRATCH_ROOT}'" >&2; exit 3 ;;
esac
# Strip the trailing slash BEFORE the HOME comparison: "${HOME}/" slipped past a
# literal test and then canonicalised to HOME itself.
SCRATCH_ROOT="${SCRATCH_ROOT%/}"
HOME_CANON="$(cd -P -- "${HOME}" 2>/dev/null && pwd -P)" || HOME_CANON="${HOME}"
ROOT_CANON_CHECK="$(cd -P -- "${SCRATCH_ROOT}" 2>/dev/null && pwd -P)" || ROOT_CANON_CHECK="${SCRATCH_ROOT}"
if [[ "${SCRATCH_ROOT}" == "${HOME}" || "${ROOT_CANON_CHECK}" == "${HOME_CANON}" ]]; then
  echo "FATAL: refusing to treat HOME (or an alias of it) as a Scratch root" >&2
  exit 3
fi
if [[ ! -d "${SCRATCH_ROOT}" ]]; then
  echo "FATAL: Scratch root does not exist: ${SCRATCH_ROOT}" >&2
  exit 3
fi
# Canonicalise. BSD `find "$root" -maxdepth 1` does not traverse a root that is
# itself a symlink without a trailing slash, and comparing lsof's canonical
# paths against a non-canonical root would never match.
SCRATCH_ROOT_INPUT="${SCRATCH_ROOT}"
CANONICAL_ROOT="$(cd -P -- "${SCRATCH_ROOT}" 2>/dev/null && pwd -P)" || {
  echo "FATAL: could not canonicalise Scratch root: ${SCRATCH_ROOT}" >&2
  exit 3
}
SCRATCH_ROOT="${CANONICAL_ROOT}"

# Resolve rm explicitly. A PATH `rm` is frequently a guard/wrapper script that
# resolves its own helpers through $HOME; invoked with HOME overridden (tests,
# launchd, sudo, a container) that wrapper exits 127, which would abort the run
# immediately after a successful summary and report a healthy cleanup as failed.
# The system binary is deterministic in every one of those contexts.
RM_BIN=""
for candidate in /bin/rm /usr/bin/rm; do
  [[ -x "${candidate}" ]] && { RM_BIN="${candidate}"; break; }
done
[[ -n "${RM_BIN}" ]] || RM_BIN="$(command -v rm 2>/dev/null || echo rm)"

STATE_DIR="${HOME}/.local/state/ezgha"
LOG="${STATE_DIR}/ios-release-cleanup.log"
MANIFEST_DIR="${STATE_DIR}/ios-release-archives"
mkdir -p "${STATE_DIR}" "${MANIFEST_DIR}"
MANIFEST="${MANIFEST_DIR}/ios-release-cleanup-$(date -u +%Y%m%dT%H%M%SZ).manifest"

# Manifests are bookkeeping; keep a month of them.
find "${MANIFEST_DIR}" -maxdepth 1 -type f -name 'ios-release-cleanup-*.manifest' -mtime +30 -delete 2>/dev/null || true

# Liveness scanning costs a full process-table walk (~3.3 s on this host), so a
# snapshot is taken once per run and only refreshed immediately before each
# removal - not once per candidate, which would be O(candidates) walks per hour.
LIVENESS_SNAPSHOT=""
GH_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/iosrel-gh.XXXXXX" 2>/dev/null)" || GH_OUT_FILE=""
snapshot_cleanup() {
  [[ -n "${LIVENESS_SNAPSHOT}" ]] && "${RM_BIN}" -f "${LIVENESS_SNAPSHOT}" 2>/dev/null
  [[ -n "${ENV_SNAPSHOT}" ]] && "${RM_BIN}" -f "${ENV_SNAPSHOT}" 2>/dev/null
  [[ -n "${GH_OUT_FILE}" ]] && "${RM_BIN}" -f "${GH_OUT_FILE}" 2>/dev/null
  return 0
}
trap snapshot_cleanup EXIT
# Separate handlers: `trap ... TERM` that only cleans up lets the script carry on
# after SIGTERM, so `launchctl stop` would not interrupt an in-flight --apply run
# until launchd escalates to SIGKILL.
trap 'snapshot_cleanup; exit 143' TERM
trap 'snapshot_cleanup; exit 130' INT

ENV_SNAPSHOT=""
take_env_snapshot() {
  [[ -n "${ENV_SNAPSHOT}" ]] && "${RM_BIN}" -f "${ENV_SNAPSHOT}" 2>/dev/null
  ENV_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/iosrel-env.XXXXXX" 2>/dev/null)" || { ENV_SNAPSHOT=""; return 1; }
  # Correlate a deferred consumer that holds the path in an EXPORTED VARIABLE: no
  # argv entry, no open fd, foreign cwd, so argv and lsof scans both miss it.
  # The mechanism is platform-specific:
  #   macOS - `ps -Eww` appends each process's environment to its args line.
  #   Linux - `ps -E` is a BSD-only option that errors out ("unsupported SysV
  #           option") and yields nothing, so read /proc/<pid>/environ instead.
  # A silently empty snapshot must be a SCAN ERROR (skip the candidate), never
  # "no match" - otherwise every candidate looks unreferenced.
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin)
      ps -Eww -A -o args= >"${ENV_SNAPSHOT}" 2>/dev/null || return 1
      ;;
    *)
      : >"${ENV_SNAPSHOT}" || return 1
      for envfile in /proc/[0-9]*/environ; do
        [[ -r "${envfile}" ]] || continue
        # Non-dumpable / other-user processes report 0400 and still refuse the
        # read; run the read in a subshell so the shell's own redirect error is
        # suppressed instead of flooding the hourly job's log.
        { tr '\0' '\n' <"${envfile}" >>"${ENV_SNAPSHOT}"; } 2>/dev/null || true
      done
      ;;
  esac
  # Self-check: the snapshot must exist, be non-empty, and actually contain
  # environment entries (KEY=VALUE). Anything else is a failed scan.
  [[ -s "${ENV_SNAPSHOT}" ]] || return 1
  grep -q '=' "${ENV_SNAPSHOT}" 2>/dev/null || return 1
  return 0
}

take_liveness_snapshot() {
  command -v lsof >/dev/null 2>&1 || return 1
  [[ -n "${LIVENESS_SNAPSHOT}" ]] && "${RM_BIN}" -f "${LIVENESS_SNAPSHOT}" 2>/dev/null
  LIVENESS_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/iosrel-lsof.XXXXXX" 2>/dev/null)" || { LIVENESS_SNAPSHOT=""; return 1; }
  if ! lsof -w -n -Fn >"${LIVENESS_SNAPSHOT}" 2>/dev/null || [[ ! -s "${LIVENESS_SNAPSHOT}" ]]; then
    return 1
  fi
  return 0
}

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
  local run_id="$1" dir_attempt="$2" out rc=0 status conclusion
  command -v "${GH_BIN}" >/dev/null 2>&1 || return 1
  [[ -n "${GH_OUT_FILE}" ]] || return 1
  # Bounded wait: `gh` has no per-call timeout and this host can be extremely
  # loaded. macOS has no `timeout(1)`, so poll the child and kill it on expiry;
  # an expired call is "cannot verify", i.e. skip.
  local deadline=$(( SECONDS + 25 ))
  "${GH_BIN}" api "repos/${PRODUCER_REPO}/actions/runs/${run_id}" \
      -q '[.status, (.conclusion // ""), (.run_attempt|tostring)] | @tsv' 2>/dev/null > "${GH_OUT_FILE}" &
  local gh_pid=$!
  while kill -0 "${gh_pid}" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
  if kill -0 "${gh_pid}" 2>/dev/null; then
    kill "${gh_pid}" 2>/dev/null || true
    return 1
  fi
  wait "${gh_pid}" || rc=$?
  [[ ${rc} -eq 0 ]] || return 1
  out="$(cat "${GH_OUT_FILE}" 2>/dev/null || true)"
  IFS=$'\t' read -r status conclusion _attempt <<<"${out}"
  # Only a SUCCESSFUL run is reaped. "completed" alone also covers failed and
  # cancelled runs, whose scratch may still be wanted for diagnosis - those are
  # retained deliberately (documented retention rule; see header).
  # Only the LATEST attempt of a successful run is reaped. A re-run's earlier
  # attempt directory is retained: it holds that attempt's failure evidence, and
  # it falls under the same "failed runs are retained" rule. The cost is that
  # re-run attempt-1 dirs are not reclaimed; re-runs are rare.
  [[ "${status}" == "completed" && "${conclusion}" == "success" && "${dir_attempt}" == "${_attempt}" ]]
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
  local target="$1" refresh="${2:-0}" real base alias p
  # Canonical form. On macOS /var, /tmp and /etc are symlinks into /private, so
  # lsof reports "/private/var/..." for a process whose cwd is "/var/...", while
  # a process may carry either spelling in its argv. Unknown canonical form
  # means liveness cannot be verified: fail closed.
  real="$(cd -P -- "${target}" 2>/dev/null && pwd -P)" || return 0
  base="$(basename "${target}")"

  # (a) argv scan. Match the unique directory basename, not a full path: the
  # basename ("worldai-ios-release-<run>-<attempt>") is identical in every alias
  # spelling, and it is globally unique per run+attempt, so a match here can only
  # be this tree. Matching a full path missed the /var form and deleted a live
  # tree during development of this check.
  # A missing pgrep means argv cannot be inspected at all - "cannot verify", so
  # treat as in use. A pgrep that EXISTS but errors (rc >= 2) is also
  # unverifiable; only rc 1 ("no process matched") means "no argv reference".
  command -v pgrep >/dev/null 2>&1 || return 0
  local pgrep_rc=0
  pgrep -f -- "${base}" >/dev/null 2>&1 || pgrep_rc=$?
  if [[ ${pgrep_rc} -eq 0 ]]; then
    return 0
  elif [[ ${pgrep_rc} -ne 1 ]]; then
    return 0
  fi

  # (b) open-file / cwd scan. An argv scan alone misses a long build whose cwd is
  # inside the tree. `lsof -Fn` lists a path per open fd and cwd without walking
  # the tree (`lsof +D` would be O(files) per candidate).
  if [[ "${refresh}" == "1" || -z "${LIVENESS_SNAPSHOT}" || ! -s "${LIVENESS_SNAPSHOT}" ]]; then
    # A failed or empty scan proves nothing about liveness: treat it as in use so
    # a broken scanner skips deletion instead of authorising it.
    take_liveness_snapshot || return 0
  fi
  alias=""
  if [[ -n "${SCRATCH_ROOT_INPUT:-}" && "${SCRATCH_ROOT_INPUT}" != "${SCRATCH_ROOT}" ]]; then
    alias="${SCRATCH_ROOT_INPUT}${real#"${SCRATCH_ROOT}"}"
  fi
  for p in "${target}" "${real}" "${alias}"; do
    [[ -n "${p}" ]] || continue
    # lsof prefixes each path with "n", so an exact cwd is "n<path>"; anything
    # deeper matches the "<path>/" prefix.
    if grep -Fq -- "${p}/" "${LIVENESS_SNAPSHOT}" || grep -Fxq -- "n${p}" "${LIVENESS_SNAPSHOT}"; then
      return 0
    fi
  done
  # Form-independent backstop: any listed path containing this unique basename.
  if grep -Fq -- "/${base}" "${LIVENESS_SNAPSHOT}"; then
    return 0
  fi

  # (c) environment scan. A deferred consumer (an uploader waiting to publish the
  # .ipa, say) can hold the path in an exported variable: no argv, no open fd,
  # foreign cwd. Reproduced by review before this check existed.
  if [[ "${refresh}" == "1" || -z "${ENV_SNAPSHOT}" || ! -s "${ENV_SNAPSHOT}" ]]; then
    take_env_snapshot || return 0
  fi
  if grep -Fq -- "${base}" "${ENV_SNAPSHOT}"; then
    return 0
  fi
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

  # `awk` sums every line into ONE number: with pipefail a `du` that exits 1 on
  # an unreadable file still emitted partial output, and an `|| echo 0` fallback
  # appended a second line that crashed the later arithmetic AFTER the rm.
  sz_kb="$( { du -sk "$d" 2>/dev/null || true; } | awk '{s+=$1} END{print s+0}' )"
  [[ "${sz_kb}" =~ ^[0-9]+$ ]] || sz_kb=0
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
  if dir_is_referenced "$d" 1; then
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
  if "${RM_BIN}" -rf -- "$d" 2>/dev/null; then
    log "  REMOVED: ${d} (${sz_kb}K, ${age_h}h old)"
    removed=$((removed+1)); freed_kb=$((freed_kb + sz_kb))
    echo "${d}  ${sz_kb}K  ${age_h}h" >> "${MANIFEST}"
  else
    log "  FAIL (remove failed): ${d}"
  fi
done < <(find "${SCRATCH_ROOT}" -mindepth 1 -maxdepth 1 -type d -name 'worldai-ios-release-*' -print0 2>/dev/null || true)

log "=== summary: scanned=${scanned} removed=${removed} skipped=${skipped} freed=${freed_kb}K ==="
exit 0
