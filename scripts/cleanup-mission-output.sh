#!/usr/bin/env bash
# cleanup-mission-output.sh — Clean stale ezgha/AO mission worktree outputs that
# accumulate in /private/tmp/worldarchitect.ai/ and /private/tmp/wa-missions/ (or /tmp equivalents).
#
# Background:
#   Each `ez-mac-runner-b-*` self-hosted GitHub Actions runner spawns a fresh
#   worktree + writes app.log / llm_forensics.jsonl / per-task scratch under
#   /private/tmp/<project-name>/. The runner image does not clean up after
#   itself; with `count = 6` configured runners, ~25 GB accumulates in days.
#
# Safety:
#   - Only targets known mission output directories and prefixes (no user dirs touched)
#   - Only removes subdirs whose mtime is >= MIN_AGE_HOURS (default 4h)
#   - Skips subdirs whose name matches an active ezgha-runner marker
#     (ez-mac-runner-b-*, wf_*, wa-*)
#   - Skips subdirs that have open file handles (lsof)
#   - Default DRY-RUN, --apply to actually remove
#   - Logs every action to ~/.local/state/ezgha/mission-output-cleanup.log
#   - Cross-platform: works on macOS (launchd) and Linux (systemd)
#
# Usage: cleanup-mission-output.sh [options]
#   --apply            perform deletions (default is dry-run)
#   --min-age-hours N  override the 4h default
#
# Invoked by launchd (macOS) or systemd timer (Linux):
#   macOS: org.jleechanorg.ezgha-mission-output-cleanup
#   Linux: ezgha-mission-output-cleanup.service / .timer

set -euo pipefail

DRY_RUN=true
MIN_AGE_HOURS=4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)           DRY_RUN=false; shift ;;
    --min-age-hours)   MIN_AGE_HOURS="$2"; shift 2 ;;
    --min-age-hours=*) MIN_AGE_HOURS="${1#*=}"; shift ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Roots to clean — known mission output locations on macOS (/private/tmp or /tmp) and Linux (/tmp)
CANDIDATE_ROOTS=(
  "/tmp/worldarchitect.ai"
  "/tmp/worldarchitect-ai"
  "/tmp/worldarchitectai"
  "/tmp/wa-missions"
  "/private/tmp/worldarchitect.ai"
  "/private/tmp/worldarchitect-ai"
  "/private/tmp/worldarchitectai"
  "/private/tmp/wa-missions"
)

TARGETS=()
for cand in "${CANDIDATE_ROOTS[@]}"; do
  if [[ -d "$cand" ]]; then
    real_path=$(cd -P "$cand" 2>/dev/null && pwd -P || echo "$cand")
    # avoid duplicates
    if [[ " ${TARGETS[*]:-} " != *" ${real_path} "* ]]; then
      TARGETS+=("${real_path}")
    fi
  fi
done

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

# Clean up manifests older than 30 days
find "$MANIFEST_DIR" -type f -name "mission-output-cleanup-*.manifest" -mtime +30 -delete 2>/dev/null || true

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${DRY_RUN:+DRY-RUN}" "$*" | tee -a "$LOG" ; }

get_mtime() {
  local target="$1"
  stat -f%m "$target" 2>/dev/null || stat -c%Y "$target" 2>/dev/null || echo 0
}

scanned=0; removed=0; skipped=0; freed_kb=0

log "=== start (DRY_RUN=$DRY_RUN MIN_AGE_HOURS=$MIN_AGE_HOURS) ==="

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  log "no target mission output roots currently exist (checked CANDIDATE_ROOTS)"
fi

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
    mtime=$(get_mtime "$d")
    now=$(date +%s)
    age_h=$(( (now - mtime) / 3600 ))
    if (( age_h < MIN_AGE_HOURS )); then
      log "  SKIP recent (${age_h}h < ${MIN_AGE_HOURS}h): $d"
      skipped=$((skipped+1))
      continue
    fi

    # skip in-use (lsof on the dir with timeout)
    if command -v lsof >/dev/null 2>&1; then
      # lsof +D has the header line; filter out header
      nopen=$(timeout 2 lsof +D "$d" 2>/dev/null | tail -n +2 | grep -c . || echo 0)
      if (( ${nopen:-0} > 0 )); then
        log "  SKIP in-use (lsof $nopen open): $d"
        skipped=$((skipped+1))
        continue
      fi
    fi

    # record + (maybe) delete
    sz_kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}' || echo 0)
    sz_kb=${sz_kb:-0}
    if $DRY_RUN; then
      log "  DRY-RUN would remove: $d (${sz_kb}K, ${age_h}h old)"
    else
      # Move to tmp quarantine then purge so disk space is actually reclaimed
      qdir=$(mktemp -d "${MANIFEST_DIR}/quarantine-XXXXXX")
      if mv "$d" "$qdir/" 2>/dev/null; then
        log "  REMOVED: $d (${sz_kb}K, ${age_h}h old)"
        removed=$((removed+1)); freed_kb=$((freed_kb + sz_kb))
        echo "$d  ${sz_kb}K  $qdir/$(basename "$d")  ${age_h}h" >> "$MANIFEST"
        rm -rf "$qdir" 2>/dev/null || true
      else
        if rm -rf "$d" 2>/dev/null; then
          log "  REMOVED (direct): $d (${sz_kb}K, ${age_h}h old)"
          removed=$((removed+1)); freed_kb=$((freed_kb + sz_kb))
          echo "$d  ${sz_kb}K  direct_rm  ${age_h}h" >> "$MANIFEST"
        else
          log "  FAIL (remove failed): $d"
        fi
      fi
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
done

log "=== summary: scanned=$scanned removed=$removed skipped=$skipped freed=${freed_kb}K ==="
exit 0
