#!/usr/bin/env bash
# Hermetic install/render/remove proof for the committed Colima trim LaunchAgent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
HOME_T="${WORK}/home"
STUB_BIN="${WORK}/bin"
mkdir -p "${HOME_T}/Library/LaunchAgents" "${STUB_BIN}"

cat > "${STUB_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LAUNCHCTL_LOG:?}"
EOF
cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:/usr/bin:/bin"
export LAUNCHCTL_LOG="${WORK}/launchctl.log"
: > "${LAUNCHCTL_LOG}"

HOME="${HOME_T}" bash "${REPO_ROOT}/launchd/install-launchagents.sh" install >/dev/null
PLIST="${HOME_T}/Library/LaunchAgents/org.jleechanorg.ezgha-colima-trim.plist"
[[ -f "${PLIST}" ]] || { echo "FAIL: trim plist was not rendered" >&2; exit 1; }
[[ -x "${HOME_T}/.local/libexec/ezgha/colima-trim-guard.sh" ]] || { echo "FAIL: stable guard script missing" >&2; exit 1; }
grep -Fq "${HOME_T}/.local/libexec/ezgha/colima-trim-guard.sh" "${PLIST}" || { echo "FAIL: plist does not use stable script path" >&2; exit 1; }
grep -Fq '<integer>300</integer>' "${PLIST}" || { echo "FAIL: plist interval is not five minutes" >&2; exit 1; }
! grep -Eq '@[A-Z_]+@|worktree' "${PLIST}" || { echo "FAIL: rendered plist contains unsafe placeholder/path" >&2; exit 1; }
grep -Fq "load ${PLIST}" "${LAUNCHCTL_LOG}" || { echo "FAIL: installer did not load trim plist" >&2; exit 1; }

HOME="${HOME_T}" bash "${REPO_ROOT}/launchd/install-launchagents.sh" remove >/dev/null
[[ ! -e "${PLIST}" ]] || { echo "FAIL: trim plist survived removal" >&2; exit 1; }
[[ ! -d "${HOME_T}/.local/libexec/ezgha" ]] || { echo "FAIL: stable scripts survived removal" >&2; exit 1; }

# The primary installer owns full uninstall and must include the same agent.
touch "${PLIST}"
HOME="${HOME_T}" bash "${REPO_ROOT}/install.sh" --uninstall >/dev/null 2>&1 || true
[[ ! -e "${PLIST}" ]] || { echo "FAIL: install.sh --uninstall left trim plist behind" >&2; exit 1; }

echo "ALL PASS"
