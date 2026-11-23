#!/usr/bin/env bash
# Hermetic install/render/remove proof for the committed cache-warm LaunchAgent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
HOME_T="${WORK}/home"
STUB_BIN="${WORK}/bin"
mkdir -p "${HOME_T}/Library/LaunchAgents" "${STUB_BIN}" "${WORK}/launchctl-state"

cat > "${STUB_BIN}/launchctl" <<EOF
#!/usr/bin/env bash
state_dir="${WORK}/launchctl-state"
mkdir -p "\$state_dir"
printf '%s\n' "\$*" >> "\${LAUNCHCTL_LOG:?}"
if [[ "\$1" == load && "\$*" == *"\${FAIL_LAUNCHCTL_LABEL:-__never__}"* ]]; then exit 1; fi
if [[ "\$1" == print && "\$*" == *"\${FAIL_LAUNCHCTL_PRINT_LABEL:-__never__}"* ]]; then
  echo "Could not find service \"\${2:-}\" in domain" >&2
  exit 113
fi
case "\${1:-}" in
  load)
    lbl="\$(basename "\${2:-}" .plist)"
    : > "\$state_dir/\$lbl"
    ;;
  unload)
    lbl="\$(basename "\${2:-}" .plist)"
    rm -f "\$state_dir/\$lbl"
    ;;
  bootout)
    lbl="\${2##*/}"
    rm -f "\$state_dir/\$lbl"
    ;;
  print)
    lbl="\${2##*/}"
    if [[ -f "\$state_dir/\$lbl" ]]; then
      exit 0
    fi
    echo "Could not find service \"\${2:-}\" in domain" >&2
    exit 113
    ;;
esac
exit 0
EOF
cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "${STUB_BIN}/limactl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
exit 0
EOF
chmod +x "${STUB_BIN}"/*
export BASH_ENV=/dev/null
export PATH="${STUB_BIN}:/usr/bin:/bin"
export LAUNCHCTL_LOG="${WORK}/launchctl.log"
export SYSTEMCTL_LOG="${WORK}/systemctl.log"
: > "${LAUNCHCTL_LOG}"
: > "${SYSTEMCTL_LOG}"

HOME="${HOME_T}" bash "${REPO_ROOT}/launchd/install-launchagents.sh" install >/dev/null
PLIST="${HOME_T}/Library/LaunchAgents/org.jleechanorg.ezgha-cache-warm.plist"
[[ -f "${PLIST}" ]] || { echo "FAIL: cache-warm plist was not rendered" >&2; exit 1; }
for mod in refresh_runner_caches.sh refresh_runner_caches.py ezgha_cache_common.py ezgha_git_mirrors.py ezgha_npm_cache.py ezgha_wheelhouse.py; do
  [[ -x "${HOME_T}/.local/libexec/ezgha/${mod}" ]] || { echo "FAIL: stable cache-warm payload missing ${mod}" >&2; exit 1; }
done
[[ -d "${HOME_T}/.local/state/ezgha" ]] || { echo "FAIL: launchd log/state directory missing" >&2; exit 1; }
grep -Fq "${HOME_T}/.local/libexec/ezgha/refresh_runner_caches.sh" "${PLIST}" || { echo "FAIL: plist does not use stable script path" >&2; exit 1; }
grep -Fq '<integer>1800</integer>' "${PLIST}" || { echo "FAIL: plist interval is not 1800s" >&2; exit 1; }
! grep -Eq '@[A-Z_]+@|worktree' "${PLIST}" || { echo "FAIL: rendered plist contains unsafe placeholder/path" >&2; exit 1; }
grep -Fq "load ${PLIST}" "${LAUNCHCTL_LOG}" || { echo "FAIL: installer did not load cache-warm plist" >&2; exit 1; }
grep -Fq "print gui/$(id -u)/org.jleechanorg.ezgha-cache-warm" "${LAUNCHCTL_LOG}" || { echo "FAIL: installer did not verify launchd registration" >&2; exit 1; }

HOME="${HOME_T}" bash "${REPO_ROOT}/launchd/install-launchagents.sh" remove >/dev/null
[[ ! -e "${PLIST}" ]] || { echo "FAIL: cache-warm plist survived removal" >&2; exit 1; }
[[ ! -d "${HOME_T}/.local/libexec/ezgha" ]] || { echo "FAIL: stable scripts survived removal" >&2; exit 1; }

# Label-scoped repair must install all 6 cache-warm modules without clobbering unrelated monitors.
mkdir -p "${HOME_T}/.local/libexec/ezgha"
printf '#!/usr/bin/env bash\n# sentinel-deployed-revision\n' > "${HOME_T}/.local/libexec/ezgha/trim-queued-runs.sh"
chmod 0755 "${HOME_T}/.local/libexec/ezgha/trim-queued-runs.sh"
HOME="${HOME_T}" bash "${REPO_ROOT}/launchd/install-launchagents.sh" install org.jleechanorg.ezgha-cache-warm >/dev/null
[[ -f "${PLIST}" ]] || { echo "FAIL: label-scoped install did not render cache-warm plist" >&2; exit 1; }
for mod in refresh_runner_caches.sh refresh_runner_caches.py ezgha_cache_common.py ezgha_git_mirrors.py ezgha_npm_cache.py ezgha_wheelhouse.py; do
  [[ -x "${HOME_T}/.local/libexec/ezgha/${mod}" ]] || { echo "FAIL: label-scoped install missing ${mod}" >&2; exit 1; }
done
HOME="${HOME_T}" "${HOME_T}/.local/libexec/ezgha/refresh_runner_caches.sh" --help >/dev/null \
  || { echo "FAIL: label-scoped installed refresh_runner_caches.sh failed sibling module import check" >&2; exit 1; }
grep -Fq '# sentinel-deployed-revision' "${HOME_T}/.local/libexec/ezgha/trim-queued-runs.sh" \
  || { echo "FAIL: label-scoped install clobbered trim-queued-runs.sh sentinel" >&2; exit 1; }
HOME="${HOME_T}" bash "${REPO_ROOT}/launchd/install-launchagents.sh" remove >/dev/null

if HOME="${HOME_T}" FAIL_LAUNCHCTL_LABEL="cache-warm" bash "${REPO_ROOT}/launchd/install-launchagents.sh" install >/dev/null 2>&1; then
  echo "FAIL: launchd load failure was swallowed" >&2
  exit 1
fi
[[ ! -e "${PLIST}" ]] || { echo "FAIL: failed launch left cache-warm plist behind" >&2; exit 1; }

if HOME="${HOME_T}" FAIL_LAUNCHCTL_PRINT_LABEL="cache-warm" bash "${REPO_ROOT}/launchd/install-launchagents.sh" install >/dev/null 2>&1; then
  echo "FAIL: launchd registration verification failure was swallowed" >&2
  exit 1
fi
[[ ! -e "${PLIST}" ]] || { echo "FAIL: unverified launch left cache-warm plist behind" >&2; exit 1; }

# Primary installer --uninstall must unload and delete the cache-warm plist too.
touch "${PLIST}"
HOME="${HOME_T}" bash "${REPO_ROOT}/install.sh" --uninstall >/dev/null 2>&1 || true
[[ ! -e "${PLIST}" ]] || { echo "FAIL: install.sh --uninstall left cache-warm plist behind" >&2; exit 1; }
grep -Fq 'disable --now ezgha.service' "${SYSTEMCTL_LOG}" || { echo "FAIL: stub systemctl did not receive uninstall" >&2; exit 1; }

echo "ALL PASS"
