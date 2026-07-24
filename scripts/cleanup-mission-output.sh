#!/usr/bin/env bash
# cleanup-mission-output.sh — Clean stale ezgha/AO mission worktree outputs that
# accumulate in /private/tmp/worldarchitect.ai/ and /private/tmp/wa-missions/.
#
# Background:
#   Each `ez-mac-runner-b-*` self-hosted GitHub Actions runner spawns a fresh
#   worktree + writes app.log / llm_forensics.jsonl / per-task scratch under
#   /private/tmp/<project-name>/. The runner image does not clean up after
#   itself; with `count = 6` configured runners, ~25 GB accumulates in days.
#
# Safety:
#   - Only targets the two paths above (no recursion, no user dirs touched)
#   - Only removes subdirs whose mtime is >= MIN_AGE_HOURS (default 24h)
#   - Skips subdirs whose name matches an active ezgha-runner marker
#     (ez-mac-runner-b-*, wf_*, wa-*)
#   - Skips subdirs that have open file handles (lsof)
#   - Default DRY-RUN, --apply to actually remove
#   - Logs every action to ~/.local/state/ezgha/mission-output-cleanup.log
#
# Usage: cleanup-mission-output.sh [options]
#   --apply            perform deletions (default is dry-run)
#   --min-age-hours N  override the 24h default
#
# Invoked by launchd: org.jleechanorg.ezgha-mission-output-cleanup
set -euo pipefail

DRY_RUN=true
MIN_AGE_HOURS=24
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)           DRY_RUN=false; shift ;;
    --min-age-hours)   MIN_AGE_HOURS="$2"; shift 2 ;;
    --min-age-hours=*) MIN_AGE_HOURS="${1#*=}"; shift ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Roots to clean — these are the only paths ezgha-runner-b-* writes
# worktree outputs to (per the ez-gh-actions source). Adding new roots is a
# one-line edit here, NOT a config flag — these names are not user-controlled.
TARGETS=(
  "/private/tmp/worldarchitect.ai"
  "/private/tmp/wa-missions"
)

# Subdirs whose basename starts with one of these are considered in-flight
# (an active runner's worktree) and NEVER removed. Adjust here if you add
# new runner name patterns.
ACTIVE_PREFIXES=(
  "ez-mac-runner-b"
  "wf_"
  "wa-"
)

STATE_DIR="${HOME}/.local/state/ezgha"
LOG="${STATE_DIR}/mission-output-cleanup.log"
MANIFEST_DIR="${STATE_DIR}/mission-output-archives"
mkdir -p "$STATE_DIR" "$MANIFEST_DIR"
MANIFEST="${MANIFEST_DIR}/mission-output-cleanup-$(date -u +%Y%m%dT%H%M%SZ).manifest"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${DRY_RUN:+DRY-RUN}" "$*" | tee -a "$LOG" ; }

scanned=0; removed=0; skipped=0; freed_kb=0

log "=== start (DRY_RUN=$DRY_RUN MIN_AGE_HOURS=$MIN_AGE_HOURS) ==="

for root in "${TARGETS[@]}"; do
  [[ -d "$root" ]] || { log "skip (not a dir): $root"; continue; }
  log "scanning $root"
  while IFS= read -r -d '' d; do
    [[ -d "$d" ]] || continue
    base=$(basename "$d")
    scanned=$((scanned+1))

    # skip in-flight markers
    is_active=false
    for p in "${ACTIVE_PREFIXES[@]}"; do
      if [[ "$base" == $p* ]]; then is_active=true; break; fi
    done
    if $is_active; then
      log "  SKIP active-marker: $d"; skipped=$((skipped+1)); continue
    fi

    # skip too-recent
    mtime=$(stat -f%m "$d" 2>/dev/null || echo 0)
    age_h=$(( ( $(date +%s) - mtime ) / 3600 ))
    if (( age_h < MIN_AGE_HOURS )); then
      log "  SKIP recent (${age_h}h < ${MIN_AGE_HOURS}h): $d"
      skipped=$((skipped+1))
      continue
    fi

    # skip in-use (lsof on the dir)
    if command -v lsof >/dev/null 2>&1; then
      # lsof +D has the header line; filter out header
      nopen=$(lsof +D "$d" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
      if [[ "${nopen:-0}" -gt 0 ]]; then
        log "  SKIP in-use (lsof $nopen open): $d"
        skipped=$((skipped+1))
        continue
      fi
    fi

    # record + (maybe) delete
    sz_kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    if $DRY_RUN; then
      log "  DRY-RUN would remove: $d (${sz_kb}K, ${age_h}h old)"
    else
      # safety net: try to mv to a tmp quarantine, then rm -rf (so a kill -9 leaves recoverable copy)
      qdir=$(mktemp -d "${MANIFEST_DIR}/quarantine-XXXXXX")
      if mv "$d" "$qdir/" 2>/dev/null; then
        log "  QUARANTINED: $d -> $qdir (${sz_kb}K, ${age_h}h old)"
        removed=$((removed+1)); freed_kb=$((freed_kb + sz_kb))
        echo "$d  ${sz_kb}K  $qdir/$(basename $d)  ${age_h}h" >> "$MANIFEST"
      else
        log "  FAIL (move failed): $d"
      fi
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
done

log "=== summary: scanned=$scanned removed=$removed skipped=$skipped freed=${freed_kb}K ==="
exit 0
