#!/usr/bin/env bash
# install.sh — install ez-gh-actions (ezgha) and, optionally, its user service.
# Idempotent, no sudo. Re-run any time to upgrade the binary.
#   ./install.sh                  install / upgrade ezgha
#   ./install.sh --uninstall      remove ezgha + its user service (config left in place)
#   ./install.sh --dev            bypass production git-state checks (local development)
# Flags compose, e.g.: ./install.sh --dev
set -euo pipefail

REPO_URL="https://github.com/jleechanorg/ez-gh-actions"
CRATE="ez-gh-actions"
BIN="ezgha"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1" >&2; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

uninstall() {
  info "Uninstalling ${BIN}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now ezgha.service 2>/dev/null || true
    # This oneshot is enabled under lima-vm@colima.service and reapplies
    # runtime QEMU limits whenever Colima starts. Remove its enablement and
    # unit on uninstall so ezgha leaves no host-control policy behind.
    systemctl --user disable --now lima-vm-cpu-ceiling.service 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/ezgha.service" \
          "${HOME}/.config/systemd/user/lima-vm-cpu-ceiling.service"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "systemd --user service removed"
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
    launchctl unload "${plist}" 2>/dev/null || true
    rm -f "${plist}"
    ok "launchd agent removed"
  fi

  # Auxiliary units (token-refresh / queue-reaper / watchdog / dashboard /
  # colima-trim) — installed
  # further below in the main flow as ezgha-<name>.timer+.service on Linux
  # and org.jleechanorg.ezgha-<name>.plist on macOS, all pointed at scripts
  # in ~/.local/libexec/ezgha. Uninstall previously disabled only the main
  # service + plist, then rm -rf'd libexec — leaving these jobs still
  # scheduled against a now-deleted script. That is exactly the dead-path-
  # scheduled-job incident class from 2026-07-09 (codex adversarial review
  # 2026-07-10, P1: recreated by an uninstall that doesn't tear these down
  # FIRST). Every removal below is best-effort (|| true) so a missing
  # unit/plist never aborts the uninstall.
  AUX_NAMES="token-refresh queue-reaper watchdog runner-dashboard colima-trim mission-output-cleanup"
  if command -v systemctl >/dev/null 2>&1; then
    for aux in ${AUX_NAMES}; do
      systemctl --user disable --now "ezgha-${aux}.timer" 2>/dev/null || true
      rm -f "${HOME}/.config/systemd/user/ezgha-${aux}.timer" \
            "${HOME}/.config/systemd/user/ezgha-${aux}.service"
      ok "systemd --user aux unit removed: ezgha-${aux}"
    done
    systemctl --user daemon-reload 2>/dev/null || true
  fi

  # Restore agent CLI entry points that were replaced by scoped wrappers.
  # Backups live under libexec so uninstall must restore them before removing
  # that directory.
  for agent in codex claude gemini cursor aider cody; do
    wrapper="${HOME}/.local/bin/${agent}"
    backup="${HOME}/.local/libexec/ezgha/wrapper-backups/${agent}"
    if [ -f "${wrapper}" ] && grep -q '^# ezgha-agent-wrapper$' "${wrapper}"; then
      rm -f "${wrapper}"
      if [ -e "${backup}" ] || [ -L "${backup}" ]; then
        mv "${backup}" "${wrapper}"
      fi
    fi
  done
  for unit in agent-scope-reaper.timer psi-oom-watcher.timer; do
    systemctl --user disable --now "${unit}" 2>/dev/null || true
  done
  rm -f "${HOME}/.config/systemd/user/agent-scope-reaper.service" \
        "${HOME}/.config/systemd/user/agent-scope-reaper.timer" \
        "${HOME}/.config/systemd/user/psi-oom-watcher.service" \
        "${HOME}/.config/systemd/user/psi-oom-watcher.timer" \
        "${HOME}/.config/systemd/user/app-lima-vm.slice" \
        "${HOME}/.config/systemd/user/agents.slice" \
        "${HOME}/.config/systemd/user/automation.slice"
  rm -f "${HOME}/.config/systemd/user/ao-daemon.service.d/20-automation-slice.conf" \
        "${HOME}/.config/systemd/user/ao-orchestrator.service.d/20-automation-slice.conf" \
        "${HOME}/.config/systemd/user/ai.dark-factory.daemon.service.d/20-automation-slice.conf" \
        "${HOME}/.config/systemd/user/lima-vm@colima.service.d/99-memory-ceiling.conf"
  rm -f "${HOME}/.local/bin/watchdog-load-repair.sh"
  # Remove only the persistent guest unit. Do not stop the active slice here:
  # existing runner containers may still be attached while uninstall drains.
  if command -v limactl >/dev/null 2>&1; then
    if limactl shell colima -- sudo -n rm -f /etc/systemd/system/actions.slice >/dev/null 2>&1; then
      limactl shell colima -- sudo -n systemctl daemon-reload >/dev/null 2>&1 || true
    else
      warn "could not remove persistent Colima guest actions.slice"
    fi
  fi
  systemctl --user daemon-reload 2>/dev/null || true
  if [ "$(uname -s)" = "Darwin" ]; then
    for aux in ${AUX_NAMES}; do
      aux_plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha-${aux}.plist"
      launchctl unload "${aux_plist}" 2>/dev/null || true
      rm -f "${aux_plist}"
      ok "launchd aux agent removed: org.jleechanorg.ezgha-${aux}"
    done
    # Legacy interim reaper (superseded by the repo-declared queue-reaper
    # unit above, see the install-time legacy-agent cleanup loop further
    # down) — clear it too so a full uninstall leaves nothing scheduled.
    stopgap_plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha-queue-reaper-stopgap.plist"
    launchctl unload "${stopgap_plist}" 2>/dev/null || true
    rm -f "${stopgap_plist}"
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
for arg in "$@"; do
  case "${arg}" in
    --uninstall|-u)
      uninstall
      ;;
    --dev|-d)
      DEV_MODE=1
      ;;
    --with-watchdog|--without-watchdog)
      : # deprecated / removed flags
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
  # Fingerprint 3: a dead PID is holding flock on the lockfile. Visible
  # as colima NOT running but lsof still reporting a `${LOCK_FILE}`
  # holder whose PID is not our own. Live repro 2026-07-26: a dead
  # `colima 97852` process held FD 9w on the lockfile, blocking every
  # install.sh invocation. Main session cleared the lock; the dead
  # colima left it behind. Recovery: kill the lockholder (TERM, then
  # KILL), drop the lockfile, then re-acquire — if any other deploy is
  # genuinely running, the second flock will still fail and we exit.
  local_lockholder_pids="$(lsof -t "${LOCK_FILE}" 2>/dev/null | grep -v "^${$}$" || true)"
  if [ -n "${local_lockholder_pids}" ]; then
    warn "Deploy lock held by dead PID(s) ${local_lockholder_pids}; clearing"
    # Use shell-agnostic kill (no `kill` builtin assumptions) — `lsof -ti`
    # leaves only PIDs, xargs -r handles the empty case. pidonly-via-lsof
    # means we don't need to parse lsof's human output.
    echo "${local_lockholder_pids}" | xargs -r kill -TERM 2>/dev/null || true
    sleep 2
    echo "${local_lockholder_pids}" | xargs -r kill -KILL 2>/dev/null || true
    rm -f "${LOCK_FILE}"
    # Re-open and retry exactly once; if a live deploy is genuinely
    # running, the second flock -n will fail and we exit cleanly.
    exec 9>"${LOCK_FILE}"
    if flock -n 9; then
      ok "Deploy lock acquired after clearing dead holder"
    else
      bad "Another deploy or installation is currently in progress (unable to acquire lock on ${LOCK_FILE} after clearing dead holder)."
      exit 1
    fi
  else
    bad "Another deploy or installation is currently in progress (unable to acquire lock on ${LOCK_FILE})."
    exit 1
  fi
else
  ok "Deploy lock acquired"
fi

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
  ok "docker CLI"
else
  bad "docker not found — install Docker, or Colima/Lima for a VM-backed daemon (https://docs.docker.com/get-docker)"
  missing=1
fi

# ── Self-contained docker socket detection ──────────────────────────────────
# /var/run/docker.sock may be a stale symlink to a non-existent path
# (typical after switching from Docker Desktop to Colima on macOS, or
# when a fresh machine has only Colima installed and never had Docker
# Desktop). ezgha queries the docker daemon via DOCKER_HOST; if the
# socket is not at /var/run/docker.sock, the launchd service / systemd
# unit must include the real socket path as DOCKER_HOST.
# See session 2026-07-13 investigation: c-runner registration was
# briefly thought broken when the symlink target didn't exist; the
# actual cause was that the colima socket had been substituted but the
# plist/unit still pointed at /var/run/docker.sock.
#
# Idempotent Colima start + stale-VZ recovery (added 2026-07-26, root
# cause: when a prior `colima stop --force` aborts or the host reboots
# while the VZ disk was attached, subsequent `colima start` fails with
# "failed to run attach disk colima, in use by instance colima" because
# the basedisk/diffdisk files are still on disk under
# ~/.colima/_lima/colima/ but no live limactl instance record exists.
# The clean fix is to remove the stale _lima/ directory, recreate via
# `colima start`, and re-install the fstrim override below. A plain
# `colima restart` does NOT clear this state. Idempotent: a healthy VM
# is left untouched, only the stale-disk error path triggers cleanup.
#
# The fingerprint check covers two failure shapes observed in the wild:
#   1. ha.stderr.log literally contains "in use by instance" (the
#      post-aborted-boot case)
#   2. colima list says Stopped AND ~/.colima/_lima/colima/ is missing
#      or has no ha.sock — same root cause, the _lima dir was wiped
#      by hand or by another tool, but a stale 'colima' instance record
#      is still registered with limactl.
ensure_colima_docker_daemon() {
  # Only relevant on macOS where Colima is the docker host.
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v colima >/dev/null 2>&1 || return 0
  command -v limactl >/dev/null 2>&1 || return 0

  # If the docker socket is already healthy, do nothing.
  local colima_sock="${HOME}/.colima/default/docker.sock"
  if is_socket_alive "$colima_sock" 2>/dev/null; then
    return 0
  fi

  # Cheap path: try a plain colima start first.
  if colima start 2>/dev/null && is_socket_alive "$colima_sock"; then
    return 0
  fi

  # Stale-VZ recovery — fingerprint 1: literal "in use by instance" in
  # the prior boot log.
  local lima_dir="${HOME}/.colima/_lima/colima"
  local ha_log="${lima_dir}/ha.stderr.log"
  local stale_vz=0
  if [ -f "$ha_log" ] && grep -q "in use by instance" "$ha_log" 2>/dev/null; then
    stale_vz=1
  fi
  # Fingerprint 2: colima list says Stopped AND the _lima/ dir is gone
  # or the hostagent socket is missing (same root cause: the
  # limactl-side state is desynced from the on-disk profile).
  if [ "$stale_vz" -eq 0 ]; then
    if colima list 2>/dev/null | grep -q "Stopped" && [ ! -S "${lima_dir}/ha.sock" ]; then
      stale_vz=1
    fi
  fi

  if [ "$stale_vz" -eq 1 ]; then
    warn "Colima VM in stale VZ state; clearing ${lima_dir} and recreating"
    # Use limactl first (safer — only removes the instance record if it
    # somehow exists), then rm the _lima/ profile dir for the clean fix.
    limactl delete --force colima >/dev/null 2>&1 || true
    rm -rf "${lima_dir}"
    if colima start && is_socket_alive "$colima_sock"; then
      ok "Colima VM recreated after stale-VZ recovery"
      return 0
    fi
    # If we hit the stale-VZ branch but the recreate still failed, fall
    # through to the generic error path below (no nested bad-message).
  fi

  return 1
}
ensure_colima_docker_daemon || true
DOCKER_HOST_OVERRIDE=""
# Strategy 1: trust the active docker context
DOCKER_CTX_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
# Strategy 2: probe colima's default location
DOCKER_COLIMA_SOCK="${HOME}/.colima/default/docker.sock"
# Strategy 3: probe docker desktop's socket
DOCKER_DESKTOP_SOCK="${HOME}/.docker/run/docker.sock"
DOCKER_DEFAULT_SOCK="/var/run/docker.sock"

is_socket_alive() {
  # Returns 0 if $1 is a unix socket that responds to docker ping; non-zero otherwise.
  local sock="$1"
  [ -S "$sock" ] || return 1
  DOCKER_HOST="unix://$sock" docker version >/dev/null 2>&1
}

if [ -n "$DOCKER_CTX_HOST" ] && [ "$DOCKER_CTX_HOST" != "unix://$DOCKER_DEFAULT_SOCK" ]; then
  # Active docker context already points at a non-default socket — export it
  # so launchd plist / systemd unit can persist it.
  DOCKER_HOST_OVERRIDE="$DOCKER_CTX_HOST"
  info "docker context already overrides default socket: ${DOCKER_CTX_HOST}"
elif is_socket_alive "$DOCKER_COLIMA_SOCK" && [ ! -e "$DOCKER_DEFAULT_SOCK" ]; then
  # Colima is reachable, default symlink is broken/missing — surface the colima
  # socket to ezgha so the service can find docker.
  DOCKER_HOST_OVERRIDE="unix://$DOCKER_COLIMA_SOCK"
  info "colima socket detected at ${DOCKER_COLIMA_SOCK}; setting DOCKER_HOST so launchd/systemd can find the daemon"
elif is_socket_alive "$DOCKER_DESKTOP_SOCK" && [ ! -e "$DOCKER_DEFAULT_SOCK" ]; then
  DOCKER_HOST_OVERRIDE="unix://$DOCKER_DESKTOP_SOCK"
  info "docker-desktop socket detected at ${DOCKER_DESKTOP_SOCK}; setting DOCKER_HOST"
fi
export DOCKER_HOST_OVERRIDE

if command -v docker >/dev/null 2>&1; then
  if [ -n "${DOCKER_HOST_OVERRIDE}" ] && DOCKER_HOST="${DOCKER_HOST_OVERRIDE}" docker version >/dev/null 2>&1; then
    ok "docker daemon reachable via ${DOCKER_HOST_OVERRIDE}"
  elif [ -z "${DOCKER_HOST_OVERRIDE}" ] && docker version >/dev/null 2>&1; then
    ok "docker daemon reachable"
  else
    bad "docker CLI found but daemon unreachable — start it (Colima/Lima/Docker Desktop) and check 'docker context ls'"
    missing=1
  fi
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

# ── Build the custom runner image ──────────────────────────────────────────
# Every example config ships `image = "ezgha-runner:latest"` (bare
# ghcr.io/actions/actions-runner:latest lacks gh/jq -> exit 127 in workflows).
# The image lives only in the Docker/Colima VM's local store, never in git,
# so a fresh VM (new machine, `colima delete && colima start`, disk-pressure
# recreation) has no way to get it back except this step. Idempotent: a
# no-op rebuild of an unchanged Dockerfile.runner is a fast cache hit.
if [ -f "${SCRIPT_DIR}/Dockerfile.runner" ] && DOCKER_HOST="${DOCKER_HOST_OVERRIDE:-${DOCKER_HOST:-}}" docker version >/dev/null 2>&1; then
  info "Building ezgha-runner:latest from Dockerfile.runner"
  # DOCKER_BUILDKIT=0 (legacy builder): BuildKit's build-context network path
  # hit a reproducible "python3-venv has no installation candidate" apt
  # failure on this colima/vz setup even with --no-cache, while the legacy
  # builder and a plain `docker run ... apt-get install` both succeeded
  # immediately (bead jleechan-bl0n, 2026-07-16). Root cause not fully
  # isolated; defaulting to the legacy builder here is the proven-reliable path.
  if DOCKER_HOST="${DOCKER_HOST_OVERRIDE:-${DOCKER_HOST:-}}" DOCKER_BUILDKIT=0 \
      docker build -f "${SCRIPT_DIR}/Dockerfile.runner" -t ezgha-runner:latest "${SCRIPT_DIR}" \
      >/tmp/ezgha-runner-build.log 2>&1; then
    ok "ezgha-runner:latest built"
  else
    bad "ezgha-runner:latest build failed — see /tmp/ezgha-runner-build.log (daemon will refuse to spawn runners without this image)"
    missing=1
  fi
else
  info "Docker daemon unreachable or Dockerfile.runner missing — skipping runner image build (fix docker reachability above, then re-run ./install.sh)"
fi

if [ "${missing}" -ne 0 ]; then
  bad "Fix the items above, then re-run ./install.sh"
  exit 1
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
      info "Regenerating launchd agent..."
    else
      info "Installing ezgha service..."
    fi
    DOCKER_HOST="${DOCKER_HOST_OVERRIDE:-${DOCKER_HOST:-}}" "${CARGO_BIN}/${BIN}" install-service
    ok "ezgha service installed and started via launchd"
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

# ── Install auxiliary systemd / launchd units (token-refresh, queue-reaper, dashboard, colima-trim) ─
# These auxiliary units keep the ezgha fleet observable and healthy between deploys:
#   - ezgha-token-refresh:   rotates the GitHub App installation token on a 45min timer
#                            (prevents the jleechan-wzk 401-on-key-rotation failure)
#   - ezgha-queue-reaper:    cancels stuck CI runs that exceed the 20min tail threshold
#   - runner-dashboard:      publishes aggregate fleet health from the Mac host
#   - colima-trim:           guards Colima VM disk trim to prevent runaway growth
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
  mkdir -p "${SCRIPTS_DIR}" "${HOME_DIR}/.local/state/ezgha"
  chmod 0700 "${HOME_DIR}/.local/state/ezgha"
  # *.sh entry points plus *.py helpers they shell out to as siblings (e.g.
  # refresh_gh_app_token.sh -> mint_gh_app_token.py) — both must land in the
  # same flat directory so sibling-relative lookups keep working post-install.
  for script in "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/scripts/*.py; do
    [ -f "${script}" ] || continue
    if [ "$(uname -s)" = "Darwin" ]; then
      case "$(basename "${script}")" in
        publish_runner_dashboard.sh|runner_dashboard_host_probe.sh|build_runner_dashboard_snapshot.py)
          continue
          ;;
      esac
    fi
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
PLIST
      # EnvironmentVariables: DOCKER_HOST when detected.
      if [ -n "${DOCKER_HOST_OVERRIDE}" ]; then
        cat >> "${plist}" <<PLIST
  <key>EnvironmentVariables</key>
  <dict>
    <key>DOCKER_HOST</key><string>${DOCKER_HOST_OVERRIDE}</string>
  </dict>
PLIST
      fi
      cat >> "${plist}" <<PLIST
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
      if ! launchctl load -w "${plist}"; then
        bad "launchctl failed to load ${plist}"
        rm -f "${plist}"
        return 1
      fi
      if ! launchctl print "gui/$(id -u)/org.jleechanorg.ezgha-${name}" >/dev/null; then
        bad "launchctl did not register org.jleechanorg.ezgha-${name}"
        launchctl unload "${plist}" 2>/dev/null || true
        rm -f "${plist}"
        return 1
      fi
      ok "macOS plist installed: ${name} (every ${interval_sec}s)"
    }
    install_macos_plist "token-refresh" "2700"  "${SCRIPTS_DIR}/refresh_gh_app_token.sh" ""
    install_macos_plist "queue-reaper"  "21600" "${SCRIPTS_DIR}/cleanup-stuck-runs.sh" "--apply"
    install_macos_plist "mission-output-cleanup" "3600" "${SCRIPTS_DIR}/cleanup-mission-output.sh" "--apply"
    info "runner dashboard activation deferred — install explicitly after enabling Pages (issue #82)"
    install_macos_plist "colima-trim"   "60"    "${SCRIPTS_DIR}/colima-trim-guard.sh" ""
    # ── Guest-native fstrim cadence — the actual root cause fix, not just the guard ──
    # colima-trim-guard.sh is a host-side EMERGENCY safety net (fires only when
    # host free space drops below 40GiB) and has twice proven unreliable (stale
    # shlock lock, then an outer-timeout hang — bead jleechan-wy3s/jleechan-zxhf).
    # The actual driver of Colima disk growth is ephemeral JIT runner churn
    # (create -> run one job -> destroy, by GitHub Actions ephemeral-runner
    # design) on an ext4 filesystem with no online discard: every churned
    # container leaves permanently-allocated sparse blocks until something
    # trims them. The guest ships its own fstrim.timer, but Ubuntu's stock
    # default is OnCalendar=weekly — useless against a churn rate of ~8 full
    # container lifecycles per 20 seconds observed live (2026-07-17). This
    # overrides the guest's own timer to run every 5 minutes, independent of
    # macOS launchd/shlock entirely — no colima-ssh subprocess from the host
    # needed for routine trimming; colima-trim-guard.sh remains only as a
    # backup for genuine host-wide emergencies.
    # Second, deeper bug found in the same investigation: stock fstrim.service
    # runs `fstrim --listed-in /etc/fstab:/proc/self/mountinfo`, which SILENTLY
    # skips /mnt/lima-colima (the actual docker data-root, on /dev/vdb1) even
    # though it fully supports discard (DISC-MAX 60G) and is live-mounted —
    # it is simply absent from /etc/fstab (mounted separately by lima at boot)
    # and --listed-in evidently does not pick it up from mountinfo either in
    # practice. Confirmed live 2026-07-17: the frequent-timer fix alone ran
    # every 5 min for 10+ minutes trimming only /, /boot, /boot/efi (a few
    # hundred MiB each) while the 50+ GiB datadisk never moved; a manual
    # `fstrim /mnt/lima-colima` then reclaimed 46.7 GiB in one shot. Overriding
    # ExecStart to `fstrim --all` (trims every currently-mounted filesystem
    # that supports discard, not just fstab-listed ones) fixes this at the
    # command level, independent of the timer-frequency fix above.
    if command -v colima >/dev/null 2>&1 && colima status --profile default >/dev/null 2>&1; then
      if colima ssh --profile default -- sudo mkdir -p /etc/systemd/system/fstrim.service.d /etc/systemd/system/fstrim.timer.d 2>/dev/null; then
        colima ssh --profile default -- sudo tee /etc/systemd/system/fstrim.service.d/override.conf >/dev/null <<'FSTRIM_SVC_EOF'
[Service]
ExecStart=
ExecStart=/sbin/fstrim --all --verbose --quiet-unsupported
FSTRIM_SVC_EOF
        colima ssh --profile default -- sudo tee /etc/systemd/system/fstrim.timer.d/override.conf >/dev/null <<'FSTRIM_EOF'
[Timer]
OnCalendar=
OnCalendar=*:0/5
AccuracySec=30s
RandomizedDelaySec=30s
FSTRIM_EOF
        colima ssh --profile default -- sudo systemctl daemon-reload 2>/dev/null
        colima ssh --profile default -- sudo systemctl restart fstrim.timer 2>/dev/null
        ok "guest fstrim.timer overridden to every 5 minutes with --all scope (was weekly + fstab-only, silently missing the docker data-root) — root-cause fix for Colima sparse-disk growth"
      else
        info "guest fstrim.timer override skipped — could not reach Colima guest via sudo (VM not running or no sudo)"
      fi
    else
      info "guest fstrim.timer override skipped — colima not installed or default profile not running"
    fi
    # Clear any legacy watchdog plist on macOS
    watchdog_plist="${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha-watchdog.plist"
    if [ -f "${watchdog_plist}" ]; then
      launchctl unload "${watchdog_plist}" 2>/dev/null || true
      rm -f "${watchdog_plist}"
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


    # Host-wide reliability controls. Keep executable paths stable and render
    # all templates from tracked source; no live service or VM is restarted.
    for script in agent-scoped-launch.sh agent-scope-reaper.sh psi-oom-watcher.sh; do
      source_script="${SCRIPT_DIR}/scripts/host/${script}"
      [ -f "${source_script}" ] || { bad "missing host control script: ${source_script}"; exit 1; }
      install -m 0755 "${source_script}" "${SCRIPTS_DIR}/${script}"
    done

    for unit in app-lima-vm.slice agents.slice automation.slice; do
      install -m 0644 "${UNIT_DIR}/${unit}" "${USER_UNIT_DIR}/${unit}"
    done
    for unit in agent-scope-reaper.service agent-scope-reaper.timer \
                psi-oom-watcher.service psi-oom-watcher.timer; do
      sed -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" \
          -e "s|@HOME@|${HOME_DIR}|g" \
          "${UNIT_DIR}/${unit}" > "${USER_UNIT_DIR}/${unit}"
    done

    for service in ao-daemon ao-orchestrator ai.dark-factory.daemon; do
      dropin_dir="${USER_UNIT_DIR}/${service}.service.d"
      mkdir -p "${dropin_dir}"
      install -m 0644 \
        "${UNIT_DIR}/${service}.service.d/20-automation-slice.conf" \
        "${dropin_dir}/20-automation-slice.conf"
    done
    mkdir -p "${USER_UNIT_DIR}/lima-vm@colima.service.d"
    install -m 0644 \
      "${UNIT_DIR}/lima-vm@colima.service.d/99-memory-ceiling.conf" \
      "${USER_UNIT_DIR}/lima-vm@colima.service.d/99-memory-ceiling.conf"
    install -m 0644 \
      "${UNIT_DIR}/lima-vm-cpu-ceiling.service" \
      "${USER_UNIT_DIR}/lima-vm-cpu-ceiling.service"

    # Docker's --cgroup-parent=actions.slice places every runner beneath one
    # guest aggregate. Install the tracked slice inside Colima so ten
    # individually bounded containers cannot consume the guest's 4G reserve.
    guest_actions_slice="${UNIT_DIR}/guest/actions.slice"
    if command -v limactl >/dev/null 2>&1 && [ -f "${guest_actions_slice}" ]; then
      if limactl shell colima -- sudo -n tee /etc/systemd/system/actions.slice \
          < "${guest_actions_slice}" >/dev/null 2>&1; then
        if limactl shell colima -- sudo -n systemctl daemon-reload >/dev/null 2>&1 &&
           limactl shell colima -- sudo -n systemctl start actions.slice >/dev/null 2>&1 &&
           limactl shell colima -- sudo -n systemctl set-property --runtime actions.slice \
             MemoryHigh=28G MemoryMax=32G MemorySwapMax=0 TasksMax=6000 >/dev/null 2>&1; then
          ok "Colima guest actions.slice installed and bounded"
        else
          warn "guest actions.slice installed but live limits could not be applied"
        fi
      else
        warn "guest actions.slice skipped — colima is unavailable or guest sudo is not passwordless"
      fi
    else
      info "guest actions.slice skipped — limactl or tracked unit unavailable"
    fi
    # Remove the superseded 20G agents.slice AO drop-in from earlier releases.
    rm -f "${USER_UNIT_DIR}/ao-daemon.service.d/memory.conf"

    install_agent_wrapper() {
      local agent="$1" dest real backup tmp real_q
      dest="${HOME_DIR}/.local/bin/${agent}"
      backup="${SCRIPTS_DIR}/wrapper-backups/${agent}"
      # `type -P` ignores shell functions named codex/claude and returns only
      # an executable path. `command -v` can return the bare function name,
      # which readlink then mis-resolves relative to the repo checkout.
      real="$(type -P "${agent}" 2>/dev/null || true)"
      [ -n "${real}" ] || return 0
      mkdir -p "${HOME_DIR}/.local/bin" "${SCRIPTS_DIR}/wrapper-backups"
      if [ -f "${dest}" ] && grep -q '^# ezgha-agent-wrapper$' "${dest}"; then
        if [ -e "${backup}" ] || [ -L "${backup}" ]; then
          real="$(readlink -f "${backup}" 2>/dev/null || true)"
        else
          real="$(sed -n 's/^# real-bin: //p' "${dest}" | head -1)"
        fi
      else
        real="$(readlink -f "${real}" 2>/dev/null || printf '%s' "${real}")"
        if [ -e "${dest}" ] || [ -L "${dest}" ]; then
          cp -a "${dest}" "${backup}"
        fi
      fi
      [ -n "${real}" ] || { bad "could not resolve real ${agent} binary"; return 1; }
      printf -v real_q '%q' "${real}"
      tmp="$(mktemp "${HOME_DIR}/.local/bin/.${agent}.ezgha.XXXXXX")"
      cat > "${tmp}" <<EOF
#!/usr/bin/env bash
# ezgha-agent-wrapper
# real-bin: ${real}
REAL_BIN=${real_q}
exec "\${HOME}/.local/libexec/ezgha/agent-scoped-launch.sh" "${agent}" "\${REAL_BIN}" "\$@"
EOF
      chmod 0755 "${tmp}"
      mv -f "${tmp}" "${dest}"
    }
    for agent in codex claude gemini cursor aider cody; do
      install_agent_wrapper "${agent}"
    done

    # Remove any historical repair script
    rm -f "${HOME_DIR}/.local/bin/watchdog-load-repair.sh"

    systemctl --user daemon-reload 2>/dev/null || true
    # Apply the direct QEMU ceiling to an already-running Colima service.
    # The tracked drop-in supplies the same values after the next boot; the
    # runtime property closes the upgrade window without restarting the VM.
    if systemctl --user set-property --runtime lima-vm@colima.service \
         MemoryHigh=34G MemoryMax=38G MemorySwapMax=2G TasksMax=4096 CPUQuota=1600% 2>/dev/null; then
      ok "live QEMU service memory+CPU ceiling applied"
    else
      warn "live QEMU ceiling not applied — it will take effect on the next Colima start"
    fi
    if systemctl --user enable --now lima-vm-cpu-ceiling.service 2>/dev/null; then
      ok "lima-vm-cpu-ceiling.service enabled (reapplies CPUQuota on Colima start)"
    else
      warn "lima-vm-cpu-ceiling.service not enabled"
    fi
    for timer in ezgha-token-refresh.timer ezgha-mission-output-cleanup.timer; do
      if systemctl --user enable --now "${timer}" 2>/dev/null; then
        ok "systemd --user timer enabled: ${timer}"
      else
        bad "failed to enable ${timer} (run: systemctl --user status ${timer})"
      fi
    done
    # Auxiliary mutation loops are opt-out by policy. Keep their tracked units
    # installed for manual diagnostics, but heal prior enabled state.
    for pair in \
      "ezgha-queue-reaper.timer ezgha-queue-reaper.service" \
      "agent-scope-reaper.timer agent-scope-reaper.service"; do
      timer="${pair%% *}"
      service="${pair#* }"
      if systemctl --user disable --now "${timer}" 2>/dev/null \
         && systemctl --user stop "${service}" 2>/dev/null; then
        ok "systemd --user auxiliary loop disabled: ${timer}"
      else
        bad "failed to disable auxiliary loop: ${timer} / ${service}"
      fi
    done
    # Retired after the 2026-08-26 incident where the user-scope PSI watcher
    # selected Warp's AppImage process as its fallback SIGTERM target. Keep the
    # tracked script/unit installed for audit and manual diagnostics, but heal
    # any previously enabled timer and stop an invocation already in flight.
    if systemctl --user disable --now psi-oom-watcher.timer 2>/dev/null \
       && systemctl --user stop psi-oom-watcher.service 2>/dev/null; then
      ok "systemd --user PSI OOM watcher disabled by policy"
    else
      bad "failed to disable psi-oom-watcher (run: systemctl --user status psi-oom-watcher.timer psi-oom-watcher.service)"
    fi

    # Clean up any drifted or legacy watchdog units
    if systemctl --user is-enabled ezgha-watchdog.timer >/dev/null 2>&1; then
      systemctl --user disable --now ezgha-watchdog.timer 2>/dev/null || true
    fi
    systemctl --user stop ezgha-watchdog.service 2>/dev/null || true
    rm -f "${USER_UNIT_DIR}/ezgha-watchdog.timer" "${USER_UNIT_DIR}/ezgha-watchdog.service"
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

# ── Tighten secret-bearing config file permissions (GH#61 / jleechan-pu5j) ─
# Sourced helper: installs/migrates all canonical secret files to mode 600
# and runs the audit script. Single-line hook to keep install.sh's
# single-writer surface minimal — logic lives in install.d/.
source "$(dirname "${BASH_SOURCE[0]}")/install.d/10-secret-permissions.sh" || true

info "Next steps"
cat <<'EOF'
  cp config/config.toml.{mac,linux}.example ~/.config/ezgha/config.toml  # fleet templates (see config/README.md)
  ezgha init --target <owner/repo>   # or auto-detect host and write starter config
  ezgha doctor                       # verify backends, limits, gh auth
  ezgha start                        # launch one ephemeral runner now
  ezgha install-service              # keep runners supervised at login (if not auto-installed)
EOF
