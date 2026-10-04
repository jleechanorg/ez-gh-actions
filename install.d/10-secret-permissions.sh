# install.d/10-secret-permissions.sh
#
# Source-only migration hook for install.sh (GH#61 / bead jleechan-sq4b /
# jleechan-pu5j). After every other install.sh unit is in place, this
# hook tightens the canonical set of secret-bearing ezgha files to
# mode 600 (owner read/write only). It is sourced by install.sh via a
# single line near the bottom of the script:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/install.d/10-secret-permissions.sh" || true
#
# Design notes:
#   - The canonical path list deliberately matches
#     scripts/check_secret_permissions.sh so audit and migration
#     converge on the same surface. Update both together.
#   - `chmod 600` is used (not `chmod go-rwx`) so the result is
#     unambiguous regardless of the prior mode.
#   - Missing files are silently skipped — a fresh install may not yet
#     have a key file.
#   - The audit script is invoked once at the end so the install log
#     prints a summary (UNSAFE paths are listed, no file contents are
#     ever logged).
#   - The hook is sourced, not executed, so install.sh's ok()/bad()/info()
#     helpers are in scope.
#
# Public entry point: _ezgha_chmod_secret_paths
#   - Returns 0 always; per-file failures are reported via ok()/bad().

# Resolve repo root from the location of this file (handles both
# source-paths-from-repo and tests-copying-into-temp-repo layouts).
_EZGHA_INSTALL_D_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-install.d/10-secret-permissions.sh}")" && pwd 2>/dev/null || echo "")"
_EZGHA_REPO_ROOT_FROM_HOOK=""
if [ -n "${_EZGHA_INSTALL_D_DIR}" ] && [ -d "${_EZGHA_INSTALL_D_DIR}/scripts" ]; then
  _EZGHA_REPO_ROOT_FROM_HOOK="$(cd "${_EZGHA_INSTALL_D_DIR}/.." && pwd)"
fi

# Canonical secret-bearing paths. Mirrors the default list in
# scripts/check_secret_permissions.sh.
_ezgha_secret_paths() {
  printf '%s\n' \
    "${HOME}/.config/ezgha/config.toml" \
    "${HOME}/.config/ezgha/secrets/alert-credential" \
    "${HOME}/.config/ezgha/secrets/slack-webhook" \
    "${HOME}/.config/ezgha/secrets/alert-credentials" \
    "${HOME}/.local/share/ezgha/tokens/app-token" \
    "${HOME}/.local/share/ezgha/tokens/app_private_key.pem" \
    "${HOME}/.config/ezgha/app_private_key.pem"
}

_ezgha_chmod_secret_paths() {
  local tightened=0
  local already_safe=0
  local missing=0
  local failed=0
  local path

  while IFS= read -r path; do
    [ -z "${path}" ] && continue
    if [ ! -e "${path}" ]; then
      missing=$((missing + 1))
      continue
    fi
    # Skip directories — chmod 600 on a dir strips execute and breaks
    # traversal. The audit script flags directory modes separately.
    if [ -d "${path}" ]; then
      continue
    fi
    if chmod 600 "${path}" 2>/dev/null; then
      tightened=$((tightened + 1))
    else
      failed=$((failed + 1))
      if command -v bad >/dev/null 2>&1; then
        bad "failed to tighten secret mode to 600: ${path}"
      fi
    fi
  done < <(_ezgha_secret_paths)

  if [ "${tightened}" -gt 0 ]; then
    if command -v ok >/dev/null 2>&1; then
      ok "tightened ${tightened} secret-bearing config file(s) to mode 600"
    fi
  fi
  if [ "${failed}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ── Auto-run on source ────────────────────────────────────────────────────
# install.sh sources this file near the bottom, AFTER every other install
# unit has rendered. Run the migration, then run the audit script so the
# install log prints a final summary (UNSAFE paths only — file contents
# are never logged).
if command -v info >/dev/null 2>&1; then
  info "Tightening secret-bearing config file permissions to 600"
fi
_ezgha_chmod_secret_paths || true

# Run the audit at the end so the install log carries a final pass/fail
# line. Prefer the in-repo copy if we can resolve it; otherwise fall back
# to PATH lookup (covers the production install path where scripts are
# copied to ~/.local/libexec/ezgha — that dir also gets the audit script).
_AUDIT_BIN=""
if [ -n "${_EZGHA_REPO_ROOT_FROM_HOOK}" ] && [ -x "${_EZGHA_REPO_ROOT_FROM_HOOK}/scripts/check_secret_permissions.sh" ]; then
  _AUDIT_BIN="${_EZGHA_REPO_ROOT_FROM_HOOK}/scripts/check_secret_permissions.sh"
elif command -v check_secret_permissions.sh >/dev/null 2>&1; then
  _AUDIT_BIN="$(command -v check_secret_permissions.sh)"
elif [ -x "${HOME}/.local/libexec/ezgha/check_secret_permissions.sh" ]; then
  _AUDIT_BIN="${HOME}/.local/libexec/ezgha/check_secret_permissions.sh"
fi

if [ -n "${_AUDIT_BIN}" ]; then
  if bash "${_AUDIT_BIN}" >/dev/null 2>&1; then
    if command -v ok >/dev/null 2>&1; then
      ok "secret-permission audit: all present secret files are 600"
    fi
  else
    # Audit failures list UNSAFE paths on stderr — that's the
    # intended signal. Never echo file contents.
    audit_log="$(bash "${_AUDIT_BIN}" 2>&1 || true)"
    if command -v bad >/dev/null 2>&1; then
      bad "secret-permission audit: some secret-bearing files have unsafe modes — run 'bash scripts/check_secret_permissions.sh' for details"
    fi
    # Echo only the structured UNSAFE lines (mode + path), no contents.
    if [ -n "${audit_log}" ]; then
      printf '%s\n' "${audit_log}" | grep -E '^UNSAFE ' >&2 || true
    fi
  fi
fi
