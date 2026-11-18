#!/usr/bin/env bash
# Verify end-to-end live runner cache savings (git mirror + wheelhouse + baked browsers)
# inside a disposable runner container by measuring eth0 RX bytes.
# Portable across Linux (bash + GNU) and macOS (bash 3.2+ + BSD).
set -euo pipefail

for _dir in /opt/homebrew/bin /usr/local/bin "${HOME}/.local/bin"; do
  if [ -d "${_dir}" ] && [[ ":${PATH}:" != *":${_dir}:"* ]]; then
    PATH="${_dir}:${PATH}"
  fi
done
export PATH

HOST_MODE=""
CFG_OVERRIDE=""

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
    -h|--help)
      echo "Usage: $0 [--host local|mac] [--config <path>]"
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

if [ "${HOST_MODE}" = "mac" ]; then
  if [ -z "${DOCKER_HOST:-}" ]; then
    LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
    if [ -f "${LAUNCHD_PLIST}" ] && command -v plutil >/dev/null 2>&1; then
      PLIST_DOCKER_HOST="$(plutil -extract EnvironmentVariables.DOCKER_HOST raw -o - "${LAUNCHD_PLIST}" 2>/dev/null || true)"
      if [ -n "${PLIST_DOCKER_HOST}" ]; then
        export DOCKER_HOST="${PLIST_DOCKER_HOST}"
        unset DOCKER_CONTEXT || true
      fi
    fi
  fi
  if [ -z "${DOCKER_HOST:-}" ] && [ ! -S /var/run/docker.sock ] && [ -S "${HOME}/.colima/default/docker.sock" ]; then
    export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
    unset DOCKER_CONTEXT || true
  fi
elif [ "${HOST_MODE}" != "local" ]; then
  echo "FAIL: unsupported --host '${HOST_MODE}' (expected local or mac)" >&2
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

PARSED_INFO="$(python3 - "${CONFIG_PATH}" <<'PY'
import os, re, sys

path = sys.argv[1]
try:
    import tomllib
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
except ImportError:
    data = {}
    sec = None
    for raw in open(path, "r", encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            sec = data.setdefault(line[1:-1].strip(), {})
        elif "=" in line:
            k, v = [x.strip() for x in line.split("=", 1)]
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                v = v[1:-1]
            (sec if sec is not None else data)[k] = v

runner = data.get("runner", {})
wh = os.path.expanduser(str(runner.get("wheelhouse_host_path", "") or ""))
gm = os.path.expanduser(str(runner.get("git_mirror_host_path", "") or ""))
img = str(runner.get("image", "") or "ezgha-runner:latest")
print(wh)
print(gm)
print(img)
PY
)"

WHEELHOUSE_PATH="$(printf '%s\n' "${PARSED_INFO}" | sed -n '1p')"
GIT_MIRROR_PATH="$(printf '%s\n' "${PARSED_INFO}" | sed -n '2p')"
RUNNER_IMAGE="$(printf '%s\n' "${PARSED_INFO}" | sed -n '3p')"
[ -n "${RUNNER_IMAGE}" ] || RUNNER_IMAGE="ezgha-runner:latest"

[ -n "${WHEELHOUSE_PATH}" ] && [ -d "${WHEELHOUSE_PATH}" ] \
  || { echo "FAIL: wheelhouse_host_path missing or not a directory: ${WHEELHOUSE_PATH:-<unset>}" >&2; exit 1; }
WHL_COUNT="$(find "${WHEELHOUSE_PATH}" -maxdepth 1 -name '*.whl' 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "${WHL_COUNT}" -ge 10 ] \
  || { echo "FAIL: expected >= 10 .whl files in ${WHEELHOUSE_PATH}, found ${WHL_COUNT}" >&2; exit 1; }

SEED_FILE="${GIT_MIRROR_PATH}/active/jleechanorg__worldarchitect.ai/SEED_SHA"
[ -n "${GIT_MIRROR_PATH}" ] && [ -f "${SEED_FILE}" ] \
  || { echo "FAIL: missing mirror SEED_SHA at ${SEED_FILE}" >&2; exit 1; }

if [ -z "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
[ -n "${GH_TOKEN:-}" ] || { echo "FAIL: unable to obtain transient GH_TOKEN from gh auth token" >&2; exit 1; }
export GH_TOKEN

CONTAINER_OUTPUT="$(
  docker run --rm \
    -v "${WHEELHOUSE_PATH}:/opt/wheelhouse:ro" \
    -v "${GIT_MIRROR_PATH}:/opt/ezgha-git-mirrors:ro" \
    -e PIP_FIND_LINKS=/opt/wheelhouse \
    -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
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
      RX_BEFORE="$(read_rx)"
      git init -q /tmp/wa
      git -C /tmp/wa remote add origin "https://github.com/jleechanorg/worldarchitect.ai.git"
      git -C /tmp/wa -c "credential.helper=!f() { echo username=x-access-token; echo password=\${GH_TOKEN}; }; f" fetch --depth=1 origin main
      python3 -m venv /tmp/v
      /tmp/v/bin/pip install --quiet pytest pydantic coverage "playwright==${PW_VER}"
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
