#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOKEN_DIR="${HOME}/.config/ezgha"
TOKEN_PATH="${TOKEN_DIR}/gh_token"

mkdir -p "$TOKEN_DIR"
started_seconds=$SECONDS

tmp_file=""
cleanup() {
  if [[ -n "$tmp_file" && -e "$tmp_file" ]]; then
    rm -f "$tmp_file"
  fi
}
trap cleanup EXIT

rc=0
token=$(timeout 45s "${SCRIPT_DIR}/mint_gh_app_token.py" "$@") || rc=$?
if [[ $rc -ne 0 ]]; then
  elapsed_seconds=$((SECONDS - started_seconds))
  if [[ $rc -eq 124 ]]; then
    echo "mint script hung and was force-killed after 45s (elapsed_seconds=${elapsed_seconds}; possible network/subprocess wedge — see bead ez-gh-actions-hcu)" >&2
  else
    echo "failed to refresh ${TOKEN_PATH}; existing token left unchanged (exit code $rc; elapsed_seconds=${elapsed_seconds})" >&2
  fi
  exit 1
fi

if [[ -z "$token" ]]; then
  echo "failed to refresh ${TOKEN_PATH}; mint script returned an empty token" >&2
  exit 1
fi

tmp_file="$(mktemp "${TOKEN_DIR}/gh_token.tmp.XXXXXX")"
chmod 600 "$tmp_file"
printf '%s\n' "$token" > "$tmp_file"
mv "$tmp_file" "$TOKEN_PATH"
tmp_file=""

elapsed_seconds=$((SECONDS - started_seconds))
echo "refreshed gh_token at ${TOKEN_PATH} (elapsed_seconds=${elapsed_seconds}; token_mtime_epoch=$(date +%s))"
