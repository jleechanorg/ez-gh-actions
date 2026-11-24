#!/usr/bin/env bash
# Hermetic tests for scripts/cloud/bootstrap-cloud-vm-host.sh git mirror,
# REBUILD_IMAGE=1, config-patching, and systemd unit rendering support.
set -euo pipefail

export BASH_ENV=/dev/null

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/scripts/cloud/bootstrap-cloud-vm-host.sh"
EXAMPLE_CFG="${REPO_ROOT}/config/config.toml.cloud-vm.example"
CACHE_SERVICE="${REPO_ROOT}/systemd/ezgha-cache-warm.service"
CACHE_TIMER="${REPO_ROOT}/systemd/ezgha-cache-warm.timer"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

PYTHON_BIN=""
for _py in python3 python3.14 python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v "${_py}")"
    break
  fi
done
[ -n "${PYTHON_BIN}" ] || fail "Python 3.11+ with stdlib tomllib is required"

# 1. Syntax check on bootstrap-cloud-vm-host.sh
bash -n "${BOOTSTRAP}" || fail "bash -n failed on ${BOOTSTRAP}"
pass "bash -n scripts/cloud/bootstrap-cloud-vm-host.sh"

# 2. Extract and run the exact Python config-patcher block from bootstrap-cloud-vm-host.sh
PATCHER_PY="${WORK}/patch_config.py"
"${PYTHON_BIN}" - "${BOOTSTRAP}" "${PATCHER_PY}" <<'PY'
import re, sys

bootstrap_text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(
    r"python3 - \"\$HOME/\.config/ezgha/config\.toml\" \"\$RUNNER_COUNT\" \"\$NAME_PREFIX\" \"\$ENABLE_GIT_MIRROR\" \"\$GIT_MIRROR_PATH\" <<'PY'\n(.*?)\nPY\n",
    bootstrap_text,
    re.DOTALL,
)
assert m, "could not locate Python config-patcher heredoc in bootstrap-cloud-vm-host.sh"
open(sys.argv[2], "w", encoding="utf-8").write(m.group(1) + "\n")
PY

FIXTURE_RESOLV="${WORK}/resolv.conf"
printf 'nameserver 10.32.0.28\n' > "${FIXTURE_RESOLV}"

# 2a. ENABLE_GIT_MIRROR=1
CFG_ON="${WORK}/config_on.toml"
cp "${EXAMPLE_CFG}" "${CFG_ON}"
HOME_ON="${WORK}/home_on"
MIRROR_ON="${HOME_ON}/.cache/ezgha-git-mirrors"
EZGHA_BOOTSTRAP_RESOLV_PATHS="${FIXTURE_RESOLV}" \
  "${PYTHON_BIN}" "${PATCHER_PY}" "${CFG_ON}" "6" "ez-cloud-runner-test" "1" "${MIRROR_ON}" >/dev/null

"${PYTHON_BIN}" - "${CFG_ON}" "${MIRROR_ON}" <<'PY'
import sys, tomllib

cfg_path, expected_mirror = sys.argv[1], sys.argv[2]
with open(cfg_path, "rb") as fh:
    cfg = tomllib.load(fh)
runner = cfg["runner"]
assert runner["count"] == 6, runner
assert runner["name_prefix"] == "ez-cloud-runner-test", runner
assert runner["dns"] == ["10.32.0.28", "1.1.1.1", "8.8.8.8"], runner
assert runner["dns_opts"] == ["timeout:2", "attempts:3"], runner
assert runner["git_mirror_host_path"] == expected_mirror, runner
assert cfg["policy"]["host_containment"] == "vm", cfg["policy"]
PY
pass "config patcher writes count, name_prefix, dns, dns_opts, and git_mirror_host_path when ENABLE_GIT_MIRROR=1"

# 2b. ENABLE_GIT_MIRROR=0 (including stripping a previously written git_mirror_host_path)
CFG_OFF="${WORK}/config_off.toml"
cp "${CFG_ON}" "${CFG_OFF}"
EZGHA_BOOTSTRAP_RESOLV_PATHS="${FIXTURE_RESOLV}" \
  "${PYTHON_BIN}" "${PATCHER_PY}" "${CFG_OFF}" "4" "ez-cloud-runner-off" "0" "${MIRROR_ON}" >/dev/null

"${PYTHON_BIN}" - "${CFG_OFF}" <<'PY'
import sys, tomllib

cfg_path = sys.argv[1]
with open(cfg_path, "rb") as fh:
    cfg = tomllib.load(fh)
runner = cfg["runner"]
assert runner["count"] == 4, runner
assert runner["name_prefix"] == "ez-cloud-runner-off", runner
assert runner["dns"] == ["10.32.0.28", "1.1.1.1", "8.8.8.8"], runner
assert runner["dns_opts"] == ["timeout:2", "attempts:3"], runner
assert "git_mirror_host_path" not in runner, runner
PY
if grep -q '^git_mirror_host_path =' "${CFG_OFF}"; then
  fail "git_mirror_host_path line remained in config when ENABLE_GIT_MIRROR=0"
fi
pass "config patcher writes count, name_prefix, dns, dns_opts, and omits git_mirror_host_path when ENABLE_GIT_MIRROR=0"

# 3. Verify systemd/ezgha-cache-warm.service and .timer render with zero @...@ placeholders
#    using the exact sed substitutions in bootstrap-cloud-vm-host.sh
HOME_UNIT="${WORK}/home_unit"
SCRIPTS_DIR="${HOME_UNIT}/.local/libexec/ezgha"
UNIT_DIR="${WORK}/systemd_user"
mkdir -p "${UNIT_DIR}"

grep -q 's|@SCRIPTS_DIR@|' "${BOOTSTRAP}" || fail "bootstrap missing @SCRIPTS_DIR@ substitution"
grep -q 's|@HOME@|' "${BOOTSTRAP}" || fail "bootstrap missing @HOME@ substitution"

sed -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" \
    -e "s|@HOME@|${HOME_UNIT}|g" \
    "${CACHE_SERVICE}" > "${UNIT_DIR}/ezgha-cache-warm.service"
sed -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" \
    -e "s|@HOME@|${HOME_UNIT}|g" \
    "${CACHE_TIMER}" > "${UNIT_DIR}/ezgha-cache-warm.timer"

for rendered in "${UNIT_DIR}/ezgha-cache-warm.service" "${UNIT_DIR}/ezgha-cache-warm.timer"; do
  if grep -q '@[A-Z_]*@' "${rendered}"; then
    fail "unrendered @...@ placeholder in ${rendered}: $(cat "${rendered}")"
  fi
done
grep -Fxq "ExecStart=${SCRIPTS_DIR}/refresh_runner_caches.sh" "${UNIT_DIR}/ezgha-cache-warm.service" \
  || fail "rendered service ExecStart mismatch"
grep -Fxq "Environment=HOME=${HOME_UNIT}" "${UNIT_DIR}/ezgha-cache-warm.service" \
  || fail "rendered service Environment=HOME mismatch"
grep -Fq ":${HOME_UNIT}/.cargo/bin:${HOME_UNIT}/.local/bin" "${UNIT_DIR}/ezgha-cache-warm.service" \
  || fail "rendered service PATH @HOME@ substitution mismatch"
pass "systemd/ezgha-cache-warm.service and .timer render with zero @...@ placeholders"

# 4. Verify REBUILD_IMAGE=1 and required cache-warm script installs are wired in bootstrap-cloud-vm-host.sh
grep -q 'REBUILD_IMAGE="${REBUILD_IMAGE:-0}"' "${BOOTSTRAP}" || fail "REBUILD_IMAGE default missing"
grep -q '\[ "\$REBUILD_IMAGE" = "1" \] || ! docker image inspect ezgha-runner:latest' "${BOOTSTRAP}" \
  || fail "Step 5 REBUILD_IMAGE=1 gate missing"
grep -q 'DOCKER_BUILDKIT=0 docker build' "${BOOTSTRAP}" || fail "DOCKER_BUILDKIT=0 build missing"
for mod in refresh_runner_caches.sh refresh_runner_caches.py ezgha_cache_common.py ezgha_git_mirrors.py ezgha_wheelhouse.py ezgha_npm_cache.py; do
  grep -Fq "${mod}" "${BOOTSTRAP}" || fail "bootstrap missing install of ${mod}"
done
grep -q 'systemctl --user enable --now ezgha-cache-warm.timer' "${BOOTSTRAP}" \
  || fail "bootstrap missing ezgha-cache-warm.timer enable"
pass "REBUILD_IMAGE=1, cache script installs, and ezgha-cache-warm.timer enable verified"
