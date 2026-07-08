#!/usr/bin/env bash
# install.sh — install ez-gh-actions (ezgha) and, optionally, its user service.
# Idempotent, no sudo. Re-run any time to upgrade the binary.
#   ./install.sh              install / upgrade ezgha
#   ./install.sh --uninstall  remove ezgha + its user service (config left in place)
set -euo pipefail

REPO_URL="https://github.com/jleechanorg/ez-gh-actions"
CRATE="ez-gh-actions"
BIN="ezgha"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

uninstall() {
  info "Uninstalling ${BIN}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now ezgha.service 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/ezgha.service"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "systemd --user service removed"
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
    launchctl unload "${plist}" 2>/dev/null || true
    rm -f "${plist}"
    ok "launchd agent removed"
  fi
  if command -v cargo >/dev/null 2>&1 && cargo uninstall "${CRATE}" 2>/dev/null; then
    ok "cargo uninstall ${CRATE}"
  else
    ok "${CRATE} not installed via cargo (nothing to remove)"
  fi
  info "Config left in place: ${XDG_CONFIG_HOME:-${HOME}/.config}/ezgha/"
  exit 0
}

DEV_MODE=0
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
  uninstall
elif [ "${1:-}" = "--dev" ] || [ "${1:-}" = "-d" ]; then
  DEV_MODE=1
fi

# ── Acquire deploy lock ───────────────────────────────────────────────────────
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/ezgha"
mkdir -p "${CONFIG_DIR}"
LOCK_FILE="${CONFIG_DIR}/deploy.lock"

exec 9>"${LOCK_FILE}"
info "Acquiring single-owner deploy lock..."
if ! flock -n 9; then
  bad "Another deploy or installation is currently in progress (unable to acquire lock on ${LOCK_FILE})."
  exit 1
fi
ok "Deploy lock acquired"

# ── Validate Git state for production ─────────────────────────────────────────
if [ "${DEV_MODE}" -eq 0 ]; then
  info "Validating repository state for production deployment"
  
  # 1. Must be on main branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "detached")
  if [ "${current_branch}" != "main" ]; then
    bad "Cannot deploy from branch '${current_branch}'. Production deploys must be from 'main'."
    bad "Use './install.sh --dev' to bypass this check for local development."
    exit 1
  fi
  ok "On branch main"

  # 2. Must not have uncommitted changes
  uncommitted=$(git status --porcelain 2>/dev/null | grep -vE 'docs/observe|docs/goals|goals/|.beads/' || true)
  if [ -n "${uncommitted}" ]; then
    bad "Cannot deploy with local uncommitted changes outside allowed directories:\n${uncommitted}"
    bad "Use './install.sh --dev' to bypass this check for local development."
    exit 1
  fi
  ok "Working directory clean"

  # 3. Must be up to date with origin/main
  info "Fetching origin main..."
  git fetch origin main >/dev/null 2>&1 || true
  local_sha=$(git rev-parse HEAD)
  remote_sha=$(git rev-parse origin/main 2>/dev/null || echo "")
  if [ -n "${remote_sha}" ] && [ "${local_sha}" != "${remote_sha}" ]; then
    bad "Local main branch is out of sync with origin/main (local: ${local_sha}, remote: ${remote_sha})."
    bad "Please pull the latest changes first."
    exit 1
  fi
  ok "Up to date with origin/main"
fi

info "Checking prerequisites"
missing=0

if command -v git >/dev/null 2>&1; then
  ok "git"
else
  bad "git not found — install it (https://git-scm.com/downloads)"
  missing=1
fi

if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
  ok "cargo / rustc ($(rustc --version 2>/dev/null | awk '{print $2}'))"
else
  bad "cargo/rustc not found — install Rust from https://rustup.rs then re-open your shell"
  missing=1
fi

if command -v docker >/dev/null 2>&1; then
  if docker version >/dev/null 2>&1; then
    ok "docker daemon reachable"
  else
    bad "docker CLI found but daemon unreachable — start it (Colima/Lima/Docker Desktop) and check 'docker context ls'"
    missing=1
  fi
else
  bad "docker not found — install Docker, or Colima/Lima for a VM-backed daemon (https://docs.docker.com/get-docker)"
  missing=1
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh CLI authenticated"
  else
    bad "gh CLI found but not authenticated — run 'gh auth login'"
    missing=1
  fi
else
  bad "gh CLI not found — install from https://cli.github.com then run 'gh auth login'"
  missing=1
fi

if [ "${missing}" -ne 0 ]; then
  bad "Fix the items above, then re-run ./install.sh"
  exit 1
fi

# ── Run pre-deployment tests ───────────────────────────────────────────────
info "Running unit tests"
if ! cargo test >/dev/null 2>&1; then
  bad "Cargo tests failed. Deploy aborted."
  exit 1
fi
ok "All tests passed"

info "Installing ${BIN}"
if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/Cargo.toml" ]; then
  cargo install --path "${SCRIPT_DIR}"
  ok "installed from local clone: ${SCRIPT_DIR}"
else
  cargo install --git "${REPO_URL}"
  ok "installed from ${REPO_URL}"
fi

CARGO_BIN="${CARGO_HOME:-${HOME}/.cargo}/bin"
case ":${PATH}:" in
  *":${CARGO_BIN}:"*) : ;;
  *)
    info "Add cargo's bin dir to your PATH:"
    printf '  export PATH="%s:$PATH"   # add to ~/.bashrc or ~/.zshrc\n' "${CARGO_BIN}"
    ;;
esac

# ── Clean up legacy com.worldarchitect.* launchd agents ───────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
  info "Cleaning up legacy worldarchitect.ai launchd agents..."
  for label in \
    com.worldarchitect.org-runners \
    com.worldarchitect.mac-runner-disk-cleanup \
    com.worldarchitect.mac-runner-health \
    com.worldarchitect.ubuntu-runner-health \
    com.worldarchitect.runner-capacity-failover \
    com.worldarchitect.cache-integrity; do
    plist="${HOME}/Library/LaunchAgents/${label}.plist"
    if launchctl list 2>/dev/null | grep -q "${label}"; then
      launchctl unload "${plist}" 2>/dev/null || true
    fi
    if [ -f "${plist}" ]; then
      rm -f "${plist}"
      ok "Removed legacy agent plist: ${label}"
    fi
  done
fi

# ── Auto-install or restart ezgha service if config exists ────────────────────
CONFIG_PATH="${XDG_CONFIG_HOME:-${HOME}/.config}/ezgha/config.toml"
if [ -f "${CONFIG_PATH}" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
    if [ -f "${plist}" ] && launchctl list 2>/dev/null | grep -q "org.jleechanorg.ezgha"; then
      info "Restarting launchd agent..."
      launchctl unload "${plist}" 2>/dev/null || true
      launchctl load "${plist}"
      ok "ezgha service restarted via launchd"
    else
      info "Installing ezgha service..."
      "${CARGO_BIN}/${BIN}" install-service
      ok "ezgha service installed and started via launchd"
    fi
  elif command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active ezgha.service >/dev/null 2>&1; then
      info "Restarting systemd service..."
      systemctl --user restart ezgha.service
      ok "ezgha service restarted via systemd"
    else
      info "Installing ezgha service..."
      "${CARGO_BIN}/${BIN}" install-service
      ok "ezgha service installed and started via systemd"
    fi
  fi
fi

# ── Run post-deployment exit criteria checks ─────────────────────────────────
if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/docs/verify-exit-criteria.sh" ]; then
  info "Running post-deployment exit criteria checks"
  if ! "${SCRIPT_DIR}/docs/verify-exit-criteria.sh"; then
    bad "Post-deployment exit criteria checks failed! Please review doctor.sh and logs."
    exit 1
  fi
  ok "Post-deployment checks passed"
fi

info "Next steps"
cat <<'EOF'
  cp config/config.toml.{mac,linux}.example ~/.config/ezgha/config.toml  # fleet templates (see config/README.md)
  ezgha init --target <owner/repo>   # or auto-detect host and write starter config
  ezgha doctor                       # verify backends, limits, gh auth
  ezgha start                        # launch one ephemeral runner now
  ezgha install-service              # keep runners supervised at login (if not auto-installed)
EOF

