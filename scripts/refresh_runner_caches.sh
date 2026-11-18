#!/usr/bin/env bash
# Refresh host-side git mirrors and pip wheelhouse caches for ezgha runners.
set -euo pipefail

umask 0022

for _dir in /opt/homebrew/bin /usr/local/bin "${HOME}/.local/bin" "${HOME}/.cargo/bin"; do
  if [ -d "${_dir}" ] && [[ ":${PATH}:" != *":${_dir}:"* ]]; then
    PATH="${_dir}:${PATH}"
  fi
done
export PATH

case "${BASH_SOURCE[0]}" in
  */*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
  *)   SCRIPT_DIR="$(pwd)" ;;
esac
exec python3 "${SCRIPT_DIR}/refresh_runner_caches.py" "$@"
