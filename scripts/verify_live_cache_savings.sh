#!/usr/bin/env bash
# Verify end-to-end live runner cache savings (git mirror + wheelhouse + baked browsers)
# inside a disposable runner container by measuring eth0 RX bytes.
# Portable across Linux (bash + GNU) and macOS (bash 3.2+ + BSD).
set -euo pipefail

if [ "${EZGHA_STRICT_PATH:-0}" != "1" ]; then
  for _dir in /opt/homebrew/bin /usr/local/bin "${HOME}/.local/bin"; do
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_MODE=""
CFG_OVERRIDE=""
REPO_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      [ $# -ge 2 ] || { echo "FAIL: --host requires an argument (local|mac)" >&2; exit 1; }
      HOST_MODE="$2"
      shift 2
      ;;
    --config)
      [ $# -ge 2 ] || { echo "FAIL: --config requires a path" >&2; exit 1; }
      CFG_OVERRIDE="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || { echo "FAIL: --repo requires owner/repo" >&2; exit 1; }
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--host local|mac] [--config <path>] [--repo <owner/repo>]"
      exit 0
      ;;
    *)
      echo "FAIL: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "${HOST_MODE}" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    HOST_MODE="mac"
  else
    HOST_MODE="local"
  fi
fi

case "${HOST_MODE}" in
  mac)   PLATFORM="macos" ;;
  local) PLATFORM="linux" ;;
  *)
    echo "FAIL: unsupported --host '${HOST_MODE}' (expected local or mac)" >&2
    exit 1
    ;;
esac

VERIFY_REPO="${REPO_OVERRIDE:-${EZGHA_VERIFY_REPO:-jleechanorg/worldarchitect.ai}}"
if [[ ! "${VERIFY_REPO}" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] \
   || [ "${BASH_REMATCH[1]}" = "." ] || [ "${BASH_REMATCH[1]}" = ".." ] \
   || [ "${BASH_REMATCH[2]}" = "." ] || [ "${BASH_REMATCH[2]}" = ".." ]; then
  echo "FAIL: invalid target repository '${VERIFY_REPO}' (expected owner/repo)" >&2
  exit 1
fi
REPO_SLUG="${VERIFY_REPO/\//__}"

MIN_WHEELS="${EZGHA_VERIFY_MIN_WHEELS:-10}"
if [[ ! "${MIN_WHEELS}" =~ ^[0-9]+$ ]]; then
  echo "FAIL: EZGHA_VERIFY_MIN_WHEELS must be a non-negative integer (got '${MIN_WHEELS}')" >&2
  exit 1
fi

REQUIRE_TOKEN="${EZGHA_VERIFY_REQUIRE_TOKEN:-1}"
if [ "${REQUIRE_TOKEN}" != "0" ] && [ "${REQUIRE_TOKEN}" != "1" ]; then
  echo "FAIL: EZGHA_VERIFY_REQUIRE_TOKEN must be 0 or 1 (got '${REQUIRE_TOKEN}')" >&2
  exit 1
fi

if [ -n "${CFG_OVERRIDE}" ]; then
  CONFIG_PATH="${CFG_OVERRIDE}"
elif [ -n "${EZGHA_CONFIG:-}" ]; then
  CONFIG_PATH="${EZGHA_CONFIG}"
elif [ "${HOST_MODE}" = "mac" ] && [ -f "${HOME}/Library/Application Support/org.jleechanorg.ezgha/config.toml" ]; then
  CONFIG_PATH="${HOME}/Library/Application Support/org.jleechanorg.ezgha/config.toml"
else
  CONFIG_PATH="${HOME}/.config/ezgha/config.toml"
fi

[ -f "${CONFIG_PATH}" ] || { echo "FAIL: config.toml not found at ${CONFIG_PATH}" >&2; exit 1; }

PARSED_INFO="$("${PYTHON_BIN}" - "${CONFIG_PATH}" <<'PY'
import os
import sys
import tomllib

path = sys.argv[1]
with open(path, "rb") as fh:
    data = tomllib.load(fh)

runner = data.get("runner", {})
if not isinstance(runner, dict):
    raise SystemExit(f"FAIL: [runner] must be a TOML table in {path}")

for field in ("wheelhouse_host_path", "git_mirror_host_path"):
    val = runner.get(field)
    if val is None:
        raise SystemExit(f"FAIL: runner.{field} is not configured in {path}")
    if not isinstance(val, str) or not val.strip():
        raise SystemExit(f"FAIL: runner.{field} must not be empty in {path}")
    if val != val.strip() or val.startswith("~") or not os.path.isabs(val):
        raise SystemExit(
            f"FAIL: runner.{field} must be an absolute path without leading '~' (got {val!r})"
        )

print(runner["wheelhouse_host_path"])
print(runner["git_mirror_host_path"])
print(str(runner.get("image") or "ezgha-runner:latest").strip() or "ezgha-runner:latest")
PY
)"

WHEELHOUSE_PATH="$(printf '%s\n' "${PARSED_INFO}" | sed -n '1p')"
GIT_MIRROR_PATH="$(printf '%s\n' "${PARSED_INFO}" | sed -n '2p')"
RUNNER_IMAGE="$(printf '%s\n' "${PARSED_INFO}" | sed -n '3p')"
[ -n "${RUNNER_IMAGE}" ] || RUNNER_IMAGE="ezgha-runner:latest"

[ -n "${WHEELHOUSE_PATH}" ] && [ -d "${WHEELHOUSE_PATH}" ] \
  || { echo "FAIL: wheelhouse_host_path missing or not a directory: ${WHEELHOUSE_PATH:-<unset>}" >&2; exit 1; }
WHL_COUNT="$(find "${WHEELHOUSE_PATH}" -maxdepth 1 -type f -name '*.whl' 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "${WHL_COUNT}" -ge "${MIN_WHEELS}" ] \
  || { echo "FAIL: expected >= ${MIN_WHEELS} .whl files in ${WHEELHOUSE_PATH}, found ${WHL_COUNT}" >&2; exit 1; }

SEED_FILE="${GIT_MIRROR_PATH}/active/${REPO_SLUG}/SEED_SHA"
[ -n "${GIT_MIRROR_PATH}" ] && [ -f "${SEED_FILE}" ] \
  || { echo "FAIL: missing mirror SEED_SHA at ${SEED_FILE}" >&2; exit 1; }

if [ "${REQUIRE_TOKEN}" = "1" ]; then
  if [ -z "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
  fi
  [ -n "${GH_TOKEN:-}" ] || { echo "FAIL: unable to obtain transient GH_TOKEN from gh auth token" >&2; exit 1; }
  export GH_TOKEN
else
  export GH_TOKEN="${GH_TOKEN:-}"
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/launchd-service-docker-endpoint.sh"
use_launchd_service_docker_endpoint "$PLATFORM"
if [ "${PLATFORM}" = "macos" ] && [ -z "${DOCKER_HOST:-}" ] && [ ! -S /var/run/docker.sock ] && [ -S "${HOME}/.colima/default/docker.sock" ]; then
  export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
  unset DOCKER_CONTEXT || true
fi
docker info --format '{{.ServerVersion}}' >/dev/null || { echo "FAIL: docker daemon unreachable" >&2; exit 1; }

CONTAINER_OUTPUT="$(
  docker run --rm \
    -v "${WHEELHOUSE_PATH}:/opt/wheelhouse:ro" \
    -v "${GIT_MIRROR_PATH}:/opt/ezgha-git-mirrors:ro" \
    -e PIP_FIND_LINKS=/opt/wheelhouse \
    -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
    -e VERIFY_REPO="${VERIFY_REPO}" \
    -e EZGHA_VERIFY_PACKAGES="${EZGHA_VERIFY_PACKAGES:-}" \
    -e GH_TOKEN \
    "${RUNNER_IMAGE}" \
    bash -lc '
      set -euo pipefail
      read_rx() {
        python3 -c "
for line in open(\"/proc/net/dev\"):
    if \":\" in line:
        iface, rest = line.split(\":\", 1)
        if iface.strip() == \"eth0\":
            print(int(rest.split()[0]))
            break
"
      }
      PW_VER="$(cat /ms-playwright/PLAYWRIGHT_VERSION 2>/dev/null || echo 1.65.2)"
      if [ -n "${EZGHA_VERIFY_PACKAGES:-}" ]; then
        read -r -a PKGS <<< "${EZGHA_VERIFY_PACKAGES}"
      else
        PKGS=(pytest pydantic coverage "playwright==${PW_VER}")
      fi
      RX_BEFORE="$(read_rx)"
      git init -q /tmp/wa
      git -C /tmp/wa remote add origin "https://github.com/${VERIFY_REPO}.git"
      if [ -n "${GH_TOKEN:-}" ]; then
        git -C /tmp/wa -c "credential.helper=!f() { echo username=x-access-token; echo password=\${GH_TOKEN}; }; f" fetch --depth=1 origin main
      else
        GIT_TERMINAL_PROMPT=0 git -C /tmp/wa fetch --depth=1 origin main
      fi
      python3 -m venv /tmp/v
      /tmp/v/bin/pip install --quiet "${PKGS[@]}"
      /tmp/v/bin/python -m playwright install chromium
      RX_AFTER="$(read_rx)"
      echo "RX_BEFORE=${RX_BEFORE}"
      echo "RX_AFTER=${RX_AFTER}"
    '
)"

RX_BEFORE="$(printf '%s\n' "${CONTAINER_OUTPUT}" | awk -F= '/^RX_BEFORE=/{print $2}' | tail -n 1)"
RX_AFTER="$(printf '%s\n' "${CONTAINER_OUTPUT}" | awk -F= '/^RX_AFTER=/{print $2}' | tail -n 1)"

if [ -z "${RX_BEFORE}" ] || [ -z "${RX_AFTER}" ]; then
  echo "FAIL: could not parse eth0 RX bytes from container output" >&2
  exit 1
fi

DELTA_BYTES=$((RX_AFTER - RX_BEFORE))
echo "LIVE_CACHE_RX_BYTES=${DELTA_BYTES}"

if [ "${DELTA_BYTES}" -lt 26214400 ]; then
  exit 0
else
  echo "FAIL: LIVE_CACHE_RX_BYTES=${DELTA_BYTES} >= 26214400 (25 MiB)" >&2
  exit 1
fi
