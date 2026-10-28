#!/usr/bin/env bash
# bootstrap-cloud-vm-host.sh — turn a fresh cloud microVM (Ubuntu 24.04, native
# Docker, passwordless sudo, systemd) into an ezgha runner host.
#
# Why this exists: `install.sh` targets the two established host shapes — macOS
# (launchd + Colima) and bare-metal Linux (HostDocker containment under
# `actions.slice` with a fixed 10/14/20-runner profile). A cloud microVM is a
# third shape: its Docker shares the VM's own kernel, so there is no bare-metal
# host to bound with a cgroup slice, and 10/14/20 runners do not fit an 8-16 GiB
# VM. `policy.host_containment = "vm"` declares the VM as the boundary; that
# declaration is fail-closed (see src/docker_backend.rs::require_host_containment).
#
# Prerequisites the caller must arrange first (never bake them into this repo):
#   ~/.config/ezgha/app_private_key.pem  (mode 600) GitHub App private key
#   a GitHub token at ~/.config/ezgha/gh_token (or GH_TOKEN in the environment)
#   ~330 MB of free disk before the runner image builds
#
# Usage:
#   HOST_TAG=a RUNNER_COUNT=4 NAME_PREFIX=ez-cloud-runner-a \
#     ./scripts/cloud/bootstrap-cloud-vm-host.sh
#
# Idempotent: re-running skips the clone/image when present, rebuilds the binary,
# and restarts the service.
set -euo pipefail

HOST_TAG="${HOST_TAG:?set HOST_TAG (a short label used for logs)}"
RUNNER_COUNT="${RUNNER_COUNT:-4}"
NAME_PREFIX="${NAME_PREFIX:?set NAME_PREFIX (e.g. ez-cloud-runner-a)}"
REPO_DIR="${REPO_DIR:-$HOME/ez-gh-actions}"
REPO_URL="${REPO_URL:-https://github.com/jleechanorg/ez-gh-actions}"
REF="${REF:-main}"
KEY_PATH="${KEY_PATH:-$HOME/.config/ezgha/app_private_key.pem}"
GH_TOKEN="${GH_TOKEN:-$(cat "$HOME/.config/ezgha/gh_token" 2>/dev/null || true)}"
LOG="${LOG:-$HOME/ezgha-bootstrap-$HOST_TAG.log}"

exec > >(tee -a "$LOG") 2>&1
step() { printf '\n[%s] ==== %s\n' "$(date -u +%H:%M:%S)" "$*"; }

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"

step "1. systemd user manager + linger (needed for --user units over SSH/exec)"
sudo -n loginctl enable-linger "$(id -un)"
sudo -n systemctl start "user@$(id -u).service" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  systemctl --user is-system-running >/dev/null 2>&1 && break
  sleep 2
done
systemctl --user is-system-running || true

step "2. rust toolchain"
if ! command -v cargo >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
. "$HOME/.cargo/env"
cargo --version
rustc --version

step "3. clone $REPO_URL"
[ -n "$GH_TOKEN" ] || { echo "MISSING GitHub token at ~/.config/ezgha/gh_token (or GH_TOKEN)"; exit 1; }
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "https://x-access-token:${GH_TOKEN}@github.com/jleechanorg/ez-gh-actions" "$REPO_DIR"
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
fi
git -C "$REPO_DIR" fetch -q origin "$REF"
git -C "$REPO_DIR" checkout -q FETCH_HEAD
git -C "$REPO_DIR" log --oneline -1

step "4. build + install ezgha"
cd "$REPO_DIR"
cargo install --path . --locked --force
ezgha --version 2>&1 | head -2 || true

step "5. runner image (ezgha-runner:latest from Dockerfile.runner)"
if ! docker image inspect ezgha-runner:latest >/dev/null 2>&1; then
  # Legacy builder: BuildKit's context network path fails apt in nested virt
  # (bead jleechan-bl0n).
  DOCKER_BUILDKIT=0 docker build -f "$REPO_DIR/Dockerfile.runner" -t ezgha-runner:latest "$REPO_DIR"
fi
docker image inspect ezgha-runner:latest --format '{{.Id}} {{.Size}}'

step "6. config (policy.host_containment = vm) + credentials"
mkdir -p "$HOME/.config/ezgha"
chmod 700 "$HOME/.config/ezgha"
[ -f "$KEY_PATH" ] || { echo "MISSING GitHub App private key at $KEY_PATH"; exit 1; }
chmod 600 "$KEY_PATH"
cp "$REPO_DIR/config/config.toml.cloud-vm.example" "$HOME/.config/ezgha/config.toml"
python3 - "$HOME/.config/ezgha/config.toml" "$RUNNER_COUNT" "$NAME_PREFIX" <<'PY'
import sys
path, count, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path):
    if line.startswith("count = "):
        out.append(f"count = {count}\n")
    elif line.startswith("name_prefix = "):
        out.append(f'name_prefix = "{prefix}"\n')
    else:
        out.append(line)
open(path, "w").writelines(out)
PY
grep -E '^(count|name_prefix) =|host_containment' "$HOME/.config/ezgha/config.toml"

step "7. GitHub App installation token (mint + 45-minute refresh timer)"
# On its own this is NOT enough: the installation token expires after 1 hour, and
# a stale token makes every `gh` call fail with 401 "Bad credentials" so no slot
# can register. The timer below re-mints it every 45 minutes and the daemon
# re-reads the file on every gh call, so no restart is needed.
SCRIPTS_DIR="$HOME/.local/libexec/ezgha"
mkdir -p "$SCRIPTS_DIR" "$HOME/.config/systemd/user"
install -m 0755 "$REPO_DIR/scripts/refresh_gh_app_token.sh" \
  "$REPO_DIR/scripts/mint_gh_app_token.py" "$SCRIPTS_DIR/"
sed "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" "$REPO_DIR/systemd/ezgha-token-refresh.service" \
  > "$HOME/.config/systemd/user/ezgha-token-refresh.service"
sed "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" "$REPO_DIR/systemd/ezgha-token-refresh.timer" \
  > "$HOME/.config/systemd/user/ezgha-token-refresh.timer"
if grep -q '@SCRIPTS_DIR@' "$HOME/.config/systemd/user/ezgha-token-refresh.service"; then
  echo "unrendered @SCRIPTS_DIR@ placeholder in the token-refresh unit"; exit 1
fi
systemctl --user daemon-reload
systemctl --user enable --now ezgha-token-refresh.timer
systemctl --user start ezgha-token-refresh.service
sleep 3
systemctl --user is-active ezgha-token-refresh.timer
ls -l "$HOME/.config/ezgha/gh_token"
GH_TOKEN="$(cat "$HOME/.config/ezgha/gh_token")" gh api /orgs/jleechanorg/actions/runners?per_page=1 \
  --jq '"gh app token ok, org runners: \(.total_count)"'

step "8. install + start the user service"
ezgha install-service
sleep 5
systemctl --user is-active ezgha.service || true
systemctl --user status ezgha.service --no-pager | head -12 || true

step "9. verify (slot containers, then a real job is the operator's acceptance test)"
docker ps --filter label=ezgha=managed --format '{{.Names}} {{.Status}}' | head -"$((RUNNER_COUNT + 1))" || true
echo "BOOTSTRAP-COMPLETE host=$HOST_TAG count=$RUNNER_COUNT prefix=$NAME_PREFIX"
