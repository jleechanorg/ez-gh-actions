#!/usr/bin/env bash
# Refresh host-side git mirrors and pip wheelhouse caches for ezgha runners.
set -euo pipefail

umask 0022

if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${HOME:-}" ] && [ -r "${HOME}/.config/ezgha/gh_token" ]; then
  _ezgha_tok="$(tr -d '[:space:]' < "${HOME}/.config/ezgha/gh_token" 2>/dev/null || true)"
  if [ -n "${_ezgha_tok}" ]; then
    export GH_TOKEN="${_ezgha_tok}"
  fi
fi

if [ "${EZGHA_STRICT_PATH:-0}" != "1" ]; then
  for _dir in /opt/homebrew/bin /usr/local/bin "${HOME}/.local/bin" "${HOME}/.cargo/bin"; do
    if [ -d "${_dir}" ] && [[ ":${PATH:-}:" != *":${_dir}:"* ]]; then
      PATH="${PATH:+${PATH}:}${_dir}"
    fi
  done
  export PATH
fi

_py_list="python3 python3.14 python3.13 python3.12 python3.11"
if [ "${EZGHA_STRICT_PATH:-0}" != "1" ]; then
  _py_list="${_py_list} /opt/homebrew/bin/python3 /usr/local/bin/python3"
fi
PYTHON_BIN=""
for _py in ${_py_list}; do
  if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v "${_py}")"
    break
  fi
done
[ -n "${PYTHON_BIN}" ] || { echo "FAIL: Python 3.11+ with stdlib tomllib is required" >&2; exit 1; }

case "${BASH_SOURCE[0]}" in
  */*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
  *)   SCRIPT_DIR="$(pwd)" ;;
esac
exec "${PYTHON_BIN}" "${SCRIPT_DIR}/refresh_runner_caches.py" "$@"
