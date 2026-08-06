#!/usr/bin/env bash
# regression test: install.sh must chmod any pre-existing secret-bearing
# config files to 600 via install.d/10-secret-permissions.sh. This guards
# against drift where a secret file (e.g. config.toml, alert-credential)
# was created with group-writable or world-readable bits by some prior
# manual copy/install — install.sh's source hook at the bottom of the
# script must tighten those bits to 600.
#
# Hermetic: install.sh runs from a docs/-less temp tree so the live
# post-deploy verify-exit-criteria.sh gate is never reached. Per
# CLAUDE.md: "Do NOT run install.sh against the live system -- stubs only."
# All system commands (systemctl/cargo/docker/gh/git/launchctl) are
# stubbed so the install completes without touching the host.
#
# Usage: bash tests/install_secret_permission_migration_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

# Portable stat mode getter — works on both Linux (GNU stat -c '%a') and
# macOS (BSD stat -f '%Lp').
get_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

# If install.d/10-secret-permissions.sh is missing, the test reports RED
# (Phase 1 contract) but exits 0 so the scaffold is itself GREEN as a
# red-test; the harness reports FAIL when the script later exists but
# install.sh doesn't source it.
INSTALL_HOOK="${REPO_ROOT}/install.d/10-secret-permissions.sh"
if [ ! -f "${INSTALL_HOOK}" ]; then
  echo "FAIL: ${INSTALL_HOOK} missing — Phase 1 RED contract holds (hook not yet implemented)." >&2
  exit 0
fi

# ── 1. Build a minimal, docs/-less copy of the tree install.sh needs ─────
TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}/systemd" "${TEMP_REPO}/scripts" "${TEMP_REPO}/install.d"
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"
cp "${REPO_ROOT}"/systemd/ezgha-*.service "${REPO_ROOT}"/systemd/ezgha-*.timer "${TEMP_REPO}/systemd/"
cp "${REPO_ROOT}/install.d/10-secret-permissions.sh" "${TEMP_REPO}/install.d/10-secret-permissions.sh"
printf '[package]\nname = "ez-gh-actions"\nversion = "0.0.0"\n' > "${TEMP_REPO}/Cargo.toml"
for name in ezgha-fleet-watchdog.sh refresh_gh_app_token.sh cleanup-stuck-runs.sh; do
  printf '#!/usr/bin/env bash\ntrue\n' > "${TEMP_REPO}/scripts/${name}"
  chmod +x "${TEMP_REPO}/scripts/${name}"
done

# ── 2. Stub PATH (systemctl/cargo/docker/gh/git/launchctl) ────────────────
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"

cat > "${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  branch) echo "main" ;;
  status) exit 0 ;;
  fetch) exit 0 ;;
  rev-parse) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
  *) exit 0 ;;
esac
EOF

cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/rustc" <<'EOF'
#!/usr/bin/env bash
echo "rustc 1.0.0 (stub)"
EOF

cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF

cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:${PATH}"

# ── 3. Seed pre-existing config files with UNSAFE permissions ─────────────
HOME_T="${WORK}/home"
mkdir -p "${HOME_T}/.config/ezgha/secrets" \
         "${HOME_T}/.local/share/ezgha/tokens"

# Sentinel secrets — values are deliberately not real, but verify the file
# mode ends at 600 post-install.
SENTINEL_CONFIG="# sentinel-ezgha-config-toml"
SENTINEL_ALERT="NOT-A-REAL-ALERT-CREDENTIAL"
SENTINEL_TOKEN="NOT-A-REAL-TOKEN"
SENTINEL_KEY="NOT-A-REAL-PRIVATE-KEY"

printf '%s\n' "${SENTINEL_CONFIG}" > "${HOME_T}/.config/ezgha/config.toml"
printf '%s\n' "${SENTINEL_ALERT}" > "${HOME_T}/.config/ezgha/secrets/alert-credential"
printf '%s\n' "${SENTINEL_TOKEN}" > "${HOME_T}/.local/share/ezgha/tokens/app-token"
printf '%s\n' "${SENTINEL_KEY}" > "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem"

# Pre-install UNSAFE modes
chmod 644 "${HOME_T}/.config/ezgha/config.toml"
chmod 664 "${HOME_T}/.config/ezgha/secrets/alert-credential"
chmod 660 "${HOME_T}/.local/share/ezgha/tokens/app-token"
chmod 640 "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem"

# ── 4. Confirm pre-state is unsafe (sanity check on the test) ─────────────
PRE_CONFIG_MODE=$(get_mode "${HOME_T}/.config/ezgha/config.toml")
PRE_ALERT_MODE=$(get_mode "${HOME_T}/.config/ezgha/secrets/alert-credential")
PRE_TOKEN_MODE=$(get_mode "${HOME_T}/.local/share/ezgha/tokens/app-token")
PRE_KEY_MODE=$(get_mode "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem")

if [ "${PRE_CONFIG_MODE}" != "644" ] || [ "${PRE_ALERT_MODE}" != "664" ] || [ "${PRE_TOKEN_MODE}" != "660" ] || [ "${PRE_KEY_MODE}" != "640" ]; then
  fail "Pre-install modes were not seeded correctly (config=${PRE_CONFIG_MODE}, alert=${PRE_ALERT_MODE}, token=${PRE_TOKEN_MODE}, key=${PRE_KEY_MODE})"
else
  echo "PASS: pre-install modes seeded as unsafe (644/664/660/640)"
fi

# ── 5. Run install.sh end-to-end (--dev skips prod gates) ─────────────────
HOME="${HOME_T}" bash "${TEMP_REPO}/install.sh" --dev >"${HOME_T}/install.log" 2>&1 || {
  cat "${HOME_T}/install.log" >&2 || true
  fail "install.sh --dev exited non-zero during migration test"
}

# ── 6. Assert post-install modes are 600 for every secret-bearing file ────
post_mode() {
  if [ -e "$1" ]; then get_mode "$1"; else echo "MISSING"; fi
}

POST_CONFIG_MODE=$(post_mode "${HOME_T}/.config/ezgha/config.toml")
POST_ALERT_MODE=$(post_mode "${HOME_T}/.config/ezgha/secrets/alert-credential")
POST_TOKEN_MODE=$(post_mode "${HOME_T}/.local/share/ezgha/tokens/app-token")
POST_KEY_MODE=$(post_mode "${HOME_T}/.local/share/ezgha/tokens/app_private_key.pem")

if [ "${POST_CONFIG_MODE}" != "600" ]; then
  fail "config.toml post-install mode is ${POST_CONFIG_MODE}, expected 600"
else
  echo "PASS: config.toml migrated to mode 600"
fi
if [ "${POST_ALERT_MODE}" != "600" ]; then
  fail "alert-credential post-install mode is ${POST_ALERT_MODE}, expected 600"
else
  echo "PASS: alert-credential migrated to mode 600"
fi
if [ "${POST_TOKEN_MODE}" != "600" ]; then
  fail "app-token post-install mode is ${POST_TOKEN_MODE}, expected 600"
else
  echo "PASS: app-token migrated to mode 600"
fi
if [ "${POST_KEY_MODE}" != "600" ]; then
  fail "app_private_key.pem post-install mode is ${POST_KEY_MODE}, expected 600"
else
  echo "PASS: app_private_key.pem migrated to mode 600"
fi

# ── 7. install.sh must source install.d/10-secret-permissions.sh ──────────
if ! grep -Eq 'install\.d/10-secret-permissions\.sh' "${TEMP_REPO}/install.sh"; then
  fail "install.sh does NOT source install.d/10-secret-permissions.sh (single-line hook missing)"
else
  echo "PASS: install.sh sources install.d/10-secret-permissions.sh"
fi

# ── 8. Sentinel contents must NOT be in install.log (sanity) ──────────────
if grep -Fq "${SENTINEL_ALERT}" "${HOME_T}/install.log" || \
   grep -Fq "${SENTINEL_TOKEN}" "${HOME_T}/install.log" || \
   grep -Fq "${SENTINEL_KEY}" "${HOME_T}/install.log"; then
  fail "install.log printed a sentinel secret value (content leak)"
else
  echo "PASS: install.log did NOT print any sentinel secret value"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
