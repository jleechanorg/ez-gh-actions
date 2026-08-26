#!/usr/bin/env bash
# sync_installed_scripts.sh — Sync and drift check between repo scripts and ~/.local/libexec/ezgha/
#
# Mirroring the sync_package_tree pattern:
# - Repo scripts/ directory is the source of truth.
# - ~/.local/libexec/ezgha/ is the deployed stable execution directory.
#
# Usage:
#   sync_installed_scripts.sh [--check] [--diff] [--dest <dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_ROOT="${EZGHA_DEST_DIR:-$HOME/.local/libexec/ezgha}"

CHECK_ONLY=false
SHOW_DIFF=false

usage() {
  cat <<HELP
Usage: $(basename "$0") [--check] [--diff] [--dest <dir>] [-h|--help]

Options:
  --check        Check for drift only; exit 0 if synced, 1 if drifted.
  --diff         Show unified diffs for all drifted files.
  --dest <dir>   Override target libexec destination directory.
  -h, --help     Show this help.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=true; shift ;;
    --diff) SHOW_DIFF=true; shift ;;
    --dest) DEST_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

drift=()

sync_file() {
  local src="$1"
  local rel="$2"
  local dest="$DEST_ROOT/$rel"

  if [[ ! -f "$dest" ]]; then
    drift+=("MISSING $rel")
    if [[ "$SHOW_DIFF" == true ]]; then
      echo "=== MISSING: $rel (not present in destination) ==="
    fi
    if [[ "$CHECK_ONLY" == false && "$SHOW_DIFF" == false ]]; then
      mkdir -p "$(dirname "$dest")"
      install -m 0755 "$src" "$dest"
    fi
  elif ! cmp -s "$src" "$dest"; then
    drift+=("DRIFTED $rel")
    if [[ "$SHOW_DIFF" == true ]]; then
      echo "=== DIFF: $rel ==="
      diff -u "$dest" "$src" || true
    fi
    if [[ "$CHECK_ONLY" == false && "$SHOW_DIFF" == false ]]; then
      mkdir -p "$(dirname "$dest")"
      install -m 0755 "$src" "$dest"
    fi
  fi
}

# 1. Sync / check all scripts in scripts/*.sh and scripts/*.py
for src in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/*.py; do
  [[ -f "$src" ]] || continue
  base="$(basename "$src")"
  sync_file "$src" "$base"
done

# 2. Sync / check dashboard assets if dashboard directory exists
if [[ -d "$REPO_ROOT/dashboard" ]]; then
  for src in "$REPO_ROOT"/dashboard/*; do
    [[ -f "$src" ]] || continue
    base="dashboard/$(basename "$src")"
    sync_file "$src" "$base"
  done
fi

if [[ ${#drift[@]} -eq 0 ]]; then
  echo "sync_installed_scripts: $DEST_ROOT is in sync with repo scripts (0 drifted files)"
  exit 0
fi

if [[ "$SHOW_DIFF" == true ]]; then
  exit 0
fi

if [[ "$CHECK_ONLY" == true ]]; then
  echo "sync_installed_scripts --check: ${#drift[@]} drifted file(s) between repo and $DEST_ROOT:"
  printf '  %s\n' "${drift[@]}"
  exit 1
fi

echo "sync_installed_scripts: synced ${#drift[@]} file(s) to $DEST_ROOT:"
printf '  %s\n' "${drift[@]}"
exit 0
