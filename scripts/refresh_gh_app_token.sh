#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOKEN_DIR="${HOME}/.config/ezgha"
TOKEN_PATH="${TOKEN_DIR}/gh_token"

mkdir -p "$TOKEN_DIR"

tmp_file=""
cleanup() {
  if [[ -n "$tmp_file" && -e "$tmp_file" ]]; then
    rm -f "$tmp_file"
  fi
}
trap cleanup EXIT

if ! token="$("${SCRIPT_DIR}/mint_gh_app_token.py" "$@")"; then
  echo "failed to refresh ${TOKEN_PATH}; existing token left unchanged" >&2
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

echo "refreshed gh_token at ${TOKEN_PATH}"
