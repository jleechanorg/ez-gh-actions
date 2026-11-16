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

step "0. resolver fallback + timeout"
# These VM images ship a SINGLE nameserver with `options timeout:1 attempts:2`, so one
# dropped UDP response is an immediate EAI_AGAIN with no fallback. That surfaced as
# actions/upload-artifact@v4 burning all five of its retries (~37s) and failing a deploy
# job whose build had already succeeded:
#   getaddrinfo EAI_AGAIN results-receiver.actions.githubusercontent.com
# A 1s timeout is also tight for a cold lookup (measured 382ms cold, 11ms warm).
#
# Two fallbacks plus a relaxed timeout, applied only when the file still has the known
# single-forwarder shape. Public resolvers are reachable on TCP/53 from these VMs and are
# consulted only when the local forwarder fails.
#
# The pin matters: freestyle-vms-agent rewrites /etc/resolv.conf back within ~10s, so a
# plain sed silently reverts. `chattr +i` is what makes the value stick. Consequence: the
# agent can no longer manage this file, so treat the value as deliberately maintained and
# use `chattr -i` if the host's networking must take the file back.
RESOLV=/etc/resolv.conf
if [ "$(grep -c '^nameserver' "$RESOLV" 2>/dev/null || echo 0)" -eq 1 ] \
   && grep -q '^nameserver 10\.32\.0\.28$' "$RESOLV" 2>/dev/null; then
  sudo -n cp "$RESOLV" "$RESOLV.bak-ezgha-bootstrap"
  sudo -n sed -i "/^nameserver 10\.32\.0\.28$/a nameserver 1.1.1.1\nnameserver 8.8.8.8" "$RESOLV"
  sudo -n sed -i 's/^options timeout:1 attempts:2$/options timeout:2 attempts:3/' "$RESOLV"
  sudo -n chattr +i "$RESOLV" 2>/dev/null || true
  echo "resolvers: $(grep -c '^nameserver' "$RESOLV") pinned=$(lsattr "$RESOLV" 2>/dev/null | grep -c '^----i')"
  getent hosts results-receiver.actions.githubusercontent.com >/dev/null 2>&1 \
    || echo "WARNING: results-receiver.actions.githubusercontent.com does not resolve"
else
  echo "resolv.conf is not the known single-forwarder shape; leaving it alone"
  grep -E '^(nameserver|options)' "$RESOLV" 2>/dev/null || true
fi

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

step "6b. refuse a count the memory budget cannot hold"
# `serve` would refuse to start anyway; fail here with the arithmetic instead of a
# daemon restart loop. Mirrors derive_memory_budget in src/docker_backend.rs.
python3 - "$HOME/.config/ezgha/config.toml" <<'PYCHK'
import re, subprocess, sys
cfg = open(sys.argv[1]).read()
def val(key, default=None):
    m = re.search(rf'(?m)^{key}\s*=\s*(\S+)', cfg)
    return m.group(1) if m else default
count = int(val('count'))
floor = int(val('runner_floor_mb', '3072'))
reserve = int(val('guest_reserve_mb', '4096'))
mem = int(subprocess.run(['docker', 'info', '--format', '{{.MemTotal}}'],
                         capture_output=True, text=True, check=True).stdout.strip()) // 1048576
budget = mem - reserve
ceiling = budget // floor
print(f"budget={budget}MB (mem {mem} - reserve {reserve}), floor={floor}MB, ceiling={ceiling}")
if count > ceiling:
    sys.exit(f"count {count} exceeds the {ceiling}-runner ceiling: "
             f"{count} x {floor} = {count * floor} MB > {budget} MB budget")

# Disk ceiling. The memory check above is necessary but NOT sufficient: a 32 GB host
# with 8 GB of RAM passes the memory check at 5 runners and then flaps forever, because
# each job's workspace grows the container's writable overlay by ~2-3 GB while the runner
# image (~4 GB) and the base OS (~7 GB) are already resident. Measured 2026-11-16 on
# three 32 GB / 8 GB cmux hosts configured for 5 runners: free space oscillated 3-10 GB
# against a 10 GB floor, spawning and pausing admission continuously, and in one case
# idling at 3 of the 5 configured runners indefinitely.
#
# The fix is NOT a lower floor (that only delays the collision) and not a bind-mounted
# workspace alone (see the workspace_host_path warning: it needs PR #206's ownership
# fix). It is running the number of runners the volume can actually hold.
import os, shutil
total_gb = shutil.disk_usage('/').total // (1024**3)
free_gb = shutil.disk_usage('/').free // (1024**3)
min_floor_gb = int(val('min_free_disk_gb', '10'))
BASE_OS_GB, IMAGE_GB, PER_RUNNER_GB = 7, 4, 3
disk_ceiling = (total_gb - BASE_OS_GB - IMAGE_GB - min_floor_gb) // PER_RUNNER_GB
print(f"disk total={total_gb}G free={free_gb}G floor={min_floor_gb}G -> disk ceiling={disk_ceiling}")
if count > disk_ceiling:
    sys.exit(
        f"count {count} exceeds the {disk_ceiling}-runner DISK ceiling on a {total_gb}G volume "
        f"({total_gb}G - {BASE_OS_GB}G base OS - {IMAGE_GB}G runner image - {min_floor_gb}G floor "
        f") / {PER_RUNNER_GB}G per runner. Lower RUNNER_COUNT to {disk_ceiling} or grow the volume "
        f"with `cmux vm resize <id> --disk <N>G`. Configuring more than the volume holds makes "
        f"admission pause and resume continuously instead of running the extra runners.")
PYCHK

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
