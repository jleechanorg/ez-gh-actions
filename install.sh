#!/usr/bin/env bash
# install.sh — install ez-gh-actions (ezgha) and, optionally, its user service.
# Idempotent, no sudo. Re-run any time to upgrade the binary.
#   ./install.sh                  install / upgrade ezgha. The fleet watchdog
#                                  (ezgha-watchdog.timer on Linux, the launchd
#                                  watchdog agent on macOS) is NOT armed by
#                                  default — arming is gated on beads
#                                  ez-gh-actions-30p (P0: no SIGTERM handling
#                                  — watchdog restarts orphan in-flight
#                                  registrations), uh2, lxn. The watchdog unit
#                                  file is still rendered/copied on Linux;
#                                  only enabling/loading is skipped, and any
#                                  drifted-enabled Linux timer is disabled.
#   ./install.sh --with-watchdog  same as above, but ALSO arms the watchdog
#                                  (systemctl enable --now on Linux, launchd
#                                  load on macOS). Only pass this once the
#                                  30p/uh2/lxn gate has cleared.
#   ./install.sh --uninstall      remove ezgha + its user service (config left in place)
#   ./install.sh --dev            bypass production git-state checks (local development)
# Flags compose, e.g.: ./install.sh --dev --with-watchdog
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
  rm -rf "${HOME}/.local/libexec/ezgha"
  ok "stable script install dir removed: ${HOME}/.local/libexec/ezgha"
  info "Config left in place: ${XDG_CONFIG_HOME:-${HOME}/.config}/ezgha/"
  exit 0
}

DEV_MODE=0
WITH_WATCHDOG=0
for arg in "$@"; do
  case "${arg}" in
    --uninstall|-u)
      uninstall
      ;;
    --dev|-d)
      DEV_MODE=1
      ;;
    --with-watchdog)
      WITH_WATCHDOG=1
      ;;
    *)
      : # ignore unrecognized args (back-compat with prior permissive parsing)
      ;;
  esac
done

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
  # org.jleechanorg.ezgha-queue-reaper-stopgap: 15-min interim reaper from the
  # 2026-07-07 queue-zombie incident, superseded by the repo-declared 6h
  # ezgha-queue-reaper unit installed below (bead jleechan-1aq — the drift
  # between the live 900s stopgap and the declared 21600s job).
  for label in \
    com.worldarchitect.org-runners \
    com.worldarchitect.mac-runner-disk-cleanup \
    com.worldarchitect.mac-runner-health \
    com.worldarchitect.ubuntu-runner-health \
    com.worldarchitect.runner-capacity-failover \
    com.worldarchitect.cache-integrity \
    org.jleechanorg.ezgha-queue-reaper-stopgap; do
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

# ── Install auxiliary systemd / launchd units (watchdog, token-refresh, queue-reaper) ─
# These three units keep the ezgha fleet healthy between deploys:
#   - ezgha-watchdog:        enforces configured runner count (handles po2 pacing deadlock)
#   - ezgha-token-refresh:   rotates the GitHub App installation token on a 45min timer
#                            (prevents the jleechan-wzk 401-on-key-rotation failure)
#   - ezgha-queue-reaper:    cancels stuck CI runs that exceed the 20min tail threshold
#
# Scripts are NEVER exec'd from this repo/worktree checkout: they are copied
# (install -m 0755) to the stable user-scope location ~/.local/libexec/ezgha/
# first, and every unit/plist references ONLY that stable path via
# @SCRIPTS_DIR@ — the uv-tool-install pattern (repo is source, libexec dir is
# what runs). See bead ez-gh-actions-sa1t: a plist that pointed at a deleted
# worktree ran silently dead (207 consecutive exit-78 failures, ~41h) with no
# visible symptom because the fleet happened to stay healthy anyway.
UNIT_DIR="${SCRIPT_DIR}/systemd"
if [ -d "${UNIT_DIR}" ]; then
  HOME_DIR="${HOME}"
  SCRIPTS_DIR="${HOME_DIR}/.local/libexec/ezgha"
  mkdir -p "${SCRIPTS_DIR}"
  # *.sh entry points plus *.py helpers they shell out to as siblings (e.g.
  # refresh_gh_app_token.sh -> mint_gh_app_token.py) — both must land in the
  # same flat directory so sibling-relative lookups keep working post-install.
  for script in "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/scripts/*.py; do
    [ -f "${script}" ] || continue
    install -m 0755 "${script}" "${SCRIPTS_DIR}/$(basename "${script}")"
  done
  ok "scripts installed to stable path: ${SCRIPTS_DIR}"

  if [ "$(uname -s)" = "Darwin" ]; then
    # macOS: wrap each systemd-style unit into a launchd plist
    install_macos_plist() {
      local name="$1" interval_sec="$2" exec_path="$3" exec_args="$4"
      local plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha-${name}.plist"
      if [ -f "${plist}" ]; then
        launchctl unload "${plist}" 2>/dev/null || true
      fi
      mkdir -p "${HOME_DIR}/.local/state/ezgha"
      cat > "${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.jleechanorg.ezgha-${name}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${exec_path}</string>
PLIST
      for a in ${exec_args}; do
        printf '    <string>%s</string>\n' "${a}" >> "${plist}"
      done
      cat >> "${plist}" <<PLIST
  </array>
  <key>StartInterval</key><integer>${interval_sec}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${HOME_DIR}/.local/state/ezgha/${name}.log</string>
  <key>StandardErrorPath</key><string>${HOME_DIR}/.local/state/ezgha/${name}.log</string>
</dict></plist>
PLIST
      # Strip XML comment blocks before scanning so a template's own
      # explanatory prose (which may legitimately say "worktree") can't
      # trip this guard on itself — only <string> values are checked. See
      # the equivalent fix in launchd/install-launchagents.sh.
      local plist_scanned
      plist_scanned="$(sed '/<!--/,/-->/d' "${plist}")"
      if grep -qF "${SCRIPT_DIR}" <<<"${plist_scanned}" || grep -qi 'worktree' <<<"${plist_scanned}"; then
        bad "refusing to load ${plist}: still references the repo/worktree checkout path"
        rm -f "${plist}"
        return 1
      fi
      launchctl load -w "${plist}" 2>/dev/null || true
      ok "macOS plist installed: ${name} (every ${interval_sec}s)"
    }
    install_macos_plist "token-refresh" "2700"  "${SCRIPTS_DIR}/refresh_gh_app_token.sh" ""
    install_macos_plist "queue-reaper"  "21600" "${SCRIPTS_DIR}/cleanup-stuck-runs.sh" "--apply"
    # Watchdog is gated separately: arming (writing + launchd-loading the
    # plist) is skipped by default — gated on ez-gh-actions-30p/uh2/lxn, see
    # bead ez-gh-actions-sa1t. Unlike token-refresh/queue-reaper above, we do
    # NOT call install_macos_plist for watchdog at all when the gate is
    # closed, so a default run cannot itself create/overwrite the plist.
    watchdog_plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha-watchdog.plist"
    if [ "${WITH_WATCHDOG}" -eq 1 ]; then
      install_macos_plist "watchdog" "120" "${SCRIPTS_DIR}/ezgha-fleet-watchdog.sh" "--host macos"
      ok "watchdog armed: operator asserted ez-gh-actions-30p/uh2/lxn gate cleared"
    else
      info "watchdog arming skipped — gated on beads ez-gh-actions-30p/uh2/lxn; pass --with-watchdog once the gate clears"
      if [ -f "${watchdog_plist}" ]; then
        bad "WARNING: ${watchdog_plist} exists but watchdog arming is gated OFF by default — this run did NOT write it, so it is likely an out-of-band re-arm (see ez-gh-actions-sa1t 2026-07-09 incident, recurred same day). NOT deleting it — investigate (launchctl list | grep ezgha-watchdog) before it fires."
      fi
    fi
  elif command -v systemctl >/dev/null 2>&1; then
    # Linux: copy the systemd units with @SCRIPTS_DIR@ / @HOME@ placeholders substituted
    USER_UNIT_DIR="${HOME}/.config/systemd/user"
    mkdir -p "${USER_UNIT_DIR}"
    for unit in "${UNIT_DIR}"/ezgha-*.service "${UNIT_DIR}"/ezgha-*.timer; do
      [ -f "${unit}" ] || continue
      base="$(basename "${unit}")"
      dest="${USER_UNIT_DIR}/${base}"
      sed -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" \
          -e "s|@HOME@|${HOME_DIR}|g" \
          "${unit}" > "${dest}"
      # Strip '#'-prefixed comment lines before scanning so an explanatory
      # comment in the unit file (which may legitimately say "worktree")
      # can't trip this guard on itself — only directive values are
      # checked. See the equivalent fix in launchd/install-launchagents.sh.
      unit_scanned="$(grep -v '^[[:space:]]*#' "${dest}")"
      if grep -q '@[A-Z_]*@' <<<"${unit_scanned}" || grep -qF "${SCRIPT_DIR}" <<<"${unit_scanned}" || grep -qi 'worktree' <<<"${unit_scanned}"; then
        bad "refusing to load ${dest}: unsubstituted placeholder or repo/worktree path reference"
        rm -f "${dest}"
        continue
      fi
    done
    systemctl --user daemon-reload 2>/dev/null || true
    for timer in ezgha-token-refresh.timer ezgha-queue-reaper.timer; do
      if systemctl --user enable --now "${timer}" 2>/dev/null; then
        ok "systemd --user timer enabled: ${timer}"
      else
        bad "failed to enable ${timer} (run: systemctl --user status ${timer})"
      fi
    done
    # ezgha-watchdog.timer is gated separately: the unit file was already
    # rendered above (repo is source, ~/.config/systemd/user is what
    # `systemctl` reads), but enabling/loading it is what's actually gated
    # on ez-gh-actions-30p/uh2/lxn — see bead ez-gh-actions-sa1t.
    if [ "${WITH_WATCHDOG}" -eq 1 ]; then
      if systemctl --user enable --now ezgha-watchdog.timer 2>/dev/null; then
        ok "systemd --user timer enabled: ezgha-watchdog.timer (operator asserted ez-gh-actions-30p/uh2/lxn gate cleared)"
      else
        bad "failed to enable ezgha-watchdog.timer (run: systemctl --user status ezgha-watchdog.timer)"
      fi
    else
      info "watchdog arming skipped — gated on beads ez-gh-actions-30p/uh2/lxn; pass --with-watchdog once the gate clears"
      if systemctl --user is-enabled ezgha-watchdog.timer >/dev/null 2>&1; then
        if systemctl --user disable --now ezgha-watchdog.timer 2>/dev/null; then
          ok "disabled drifted-enabled ezgha-watchdog.timer (healed out-of-band re-arm)"
        else
          bad "failed to disable ezgha-watchdog.timer (run: systemctl --user status ezgha-watchdog.timer)"
        fi
      fi
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

