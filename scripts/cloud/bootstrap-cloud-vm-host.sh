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
# Idempotent: re-running skips the clone/image when present (set REBUILD_IMAGE=1
# to force image rebuild), rebuilds the binary, and restarts the service.
set -euo pipefail

HOST_TAG="${HOST_TAG:?set HOST_TAG (a short label used for logs)}"
RUNNER_COUNT="${RUNNER_COUNT:-4}"
NAME_PREFIX="${NAME_PREFIX:?set NAME_PREFIX (e.g. ez-cloud-runner-a)}"
REPO_DIR="${REPO_DIR:-$HOME/ez-gh-actions}"
REPO_URL="${REPO_URL:-https://github.com/jleechanorg/ez-gh-actions}"
REF="${REF:-main}"
KEY_PATH="${KEY_PATH:-$HOME/.config/ezgha/app_private_key.pem}"
GH_TOKEN="${GH_TOKEN:-$(cat "$HOME/.config/ezgha/gh_token" 2>/dev/null || true)}"
REBUILD_IMAGE="${REBUILD_IMAGE:-0}"
ENABLE_GIT_MIRROR="${ENABLE_GIT_MIRROR:-1}"
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
# Two fallbacks plus a relaxed timeout. This step is an idempotent assert-healthy-then-
# repair: it verifies the full healthy shape (>=3 nameservers, both public fallbacks,
# `options timeout:2 attempts:3`, immutable bit) and only rewrites when any part is
# missing, so a re-run against an already-repaired file is a no-op. The ONE existing
# forwarder is preserved as the first nameserver — it is the only entry that can answer
# for VM-local names — and the public resolvers follow purely as fallbacks. They are
# reachable on TCP/53 from these VMs and are consulted only when the forwarder fails.
#
# The pin matters: freestyle-vms-agent rewrites /etc/resolv.conf back within ~10s, so a
# plain rewrite silently reverts. `chattr +i` is what makes the value stick, and a failed
# `chattr +i` is now a hard bootstrap failure (it used to be `|| true`, which reported
# success on a fix that had already reverted). Consequence of pinning: the agent can no
# longer manage this file, so treat the value as deliberately maintained and use
# `chattr -i` if the host's networking must take the file back.
RESOLV=/etc/resolv.conf
RESOLV_BACKUP="$RESOLV.bak-ezgha-bootstrap"

# A resolver config is HEALTHY only when every one of these holds. Anything else
# is repaired below; "mostly right" is not good enough because the failure mode
# (a dropped UDP response with no fallback) is invisible until a job hits it.
resolver_is_healthy() {
  [ -e "$RESOLV" ] || return 1
  local ns_count opts_line attrs
  ns_count="$(grep -c '^nameserver ' "$RESOLV" 2>/dev/null || true)"
  [ "${ns_count:-0}" -ge 3 ] || return 1
  grep -qE '^nameserver 1\.1\.1\.1$' "$RESOLV" || return 1
  grep -qE '^nameserver 8\.8\.8\.8$' "$RESOLV" || return 1
  opts_line="$(grep -E '^options ' "$RESOLV" 2>/dev/null | tail -n 1 || true)"
  [ "$opts_line" = "options timeout:2 attempts:3" ] || return 1
  attrs="$(lsattr "$RESOLV" 2>/dev/null || true)"
  case "$attrs" in
    *----i*) return 0 ;;
    *) return 1 ;;
  esac
}

# Detect the host's own (private) resolver. NEVER invent one: a guessed address
# would be pinned here AND handed to runner containers as `--dns`, so VM-local
# lookups would break while the pin holds the wrong value. Search the live file
# first, then systemd-resolved's upstream file, and fail when neither has one.
detect_resolv_forwarder() {
  local f addr
  for f in "$RESOLV" /run/systemd/resolve/resolv.conf; do
    [ -r "$f" ] || continue
    addr="$(awk '/^nameserver[[:space:]]+/ {
        a = $2
        if (a != "1.1.1.1" && a != "8.8.8.8" && a != "9.9.9.9" && a !~ /^127\./) { print a; exit }
      }' "$f" 2>/dev/null || true)"
    if [ -n "$addr" ]; then
      printf '%s' "$addr"
      return 0
    fi
  done
  return 1
}

# Rewrite + pin. Returns non-zero (without deciding the outcome) so the caller can
# retry a bounded number of times and then stop loudly.
repair_resolver() {
  local forwarder search_lines
  if ! forwarder="$(detect_resolv_forwarder)"; then
    echo "FATAL: no private resolver found in $RESOLV or /run/systemd/resolve/resolv.conf." >&2
    echo "       Refusing to invent one and pin it: a guessed address would also reach" >&2
    echo "       runner containers as --dns and break VM-local lookups." >&2
    return 1
  fi
  echo "repairing /etc/resolv.conf: forwarder=$forwarder fallbacks=1.1.1.1,8.8.8.8"
  # Release the pin if a previous run set it; failure just means it was not pinned.
  sudo -n chattr -i "$RESOLV" 2>/dev/null || true
  # Back up the ORIGINAL exactly once — never overwrite a good backup with an
  # already-repaired file on a later run.
  if [ ! -f "$RESOLV_BACKUP" ]; then
    sudo -n cp "$RESOLV" "$RESOLV_BACKUP"
  fi
  # Preserve any search/domain directive: dropping it silently changes how
  # VM-local short names resolve, which is a different failure mode than the
  # one this step exists to prevent.
  search_lines="$(grep -E '^(search|domain)[[:space:]]' "$RESOLV" 2>/dev/null || true)"
  {
    printf 'nameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' "$forwarder"
    if [ -n "$search_lines" ]; then
      printf '%s\n' "$search_lines"
    fi
    printf 'options timeout:2 attempts:3\n'
  } | sudo -n tee "$RESOLV" >/dev/null
  # FAIL CLOSED on the pin. Without the immutable bit the VM agent rewrites this
  # file back within ~10s and every EAI_AGAIN/stall this step exists to prevent
  # silently returns.
  if ! sudo -n chattr +i "$RESOLV"; then
    echo "could not pin $RESOLV immutable; without the bit the VM agent rewrites it" >&2
    echo "within seconds and the single-forwarder EAI_AGAIN failure mode returns." >&2
    return 1
  fi
  # Verify AFTER pinning: the agent can restore the old content between the write
  # and the chattr, and the pin would then hold the WRONG file. Never report a
  # repaired resolver that does not read back healthy.
  if ! resolver_is_healthy; then
    echo "resolver content did not read back healthy after pinning; the agent likely" >&2
    echo "rewrote it mid-repair." >&2
    return 1
  fi
  return 0
}

if resolver_is_healthy; then
  echo "resolv.conf already healthy (>=3 nameservers, public fallbacks, timeout:2 attempts:3, immutable)"
else
  attempt=1
  repaired=0
  while [ "$attempt" -le 3 ]; do
    if repair_resolver; then
      repaired=1
      break
    fi
    echo "resolver repair attempt $attempt did not verify; retrying in 2s" >&2
    sleep 2
    attempt=$((attempt + 1))
  done
  if [ "$repaired" -ne 1 ]; then
    echo "FATAL: could not put $RESOLV into the pinned fallback shape after 3 attempts;" >&2
    echo "       refusing to report a repaired resolver. Recovery is an operator action;" >&2
    echo "       see the resolver-pinning section of docs/cloud-vm-hosts.md." >&2
    exit 1
  fi
fi

echo "resolv.conf nameservers:"
grep -E '^(nameserver|options)' "$RESOLV" 2>/dev/null || true
echo "resolv.conf immutable: $(lsattr "$RESOLV" 2>/dev/null | grep -c -- '----i' || true)"
getent hosts results-receiver.actions.githubusercontent.com >/dev/null 2>&1 \
  || echo "WARNING: results-receiver.actions.githubusercontent.com does not resolve"

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
if [ "$REBUILD_IMAGE" = "1" ] || ! docker image inspect ezgha-runner:latest >/dev/null 2>&1; then
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
GIT_MIRROR_PATH="${HOME%/}/.cache/ezgha-git-mirrors"
python3 - "$HOME/.config/ezgha/config.toml" "$RUNNER_COUNT" "$NAME_PREFIX" "$ENABLE_GIT_MIRROR" "$GIT_MIRROR_PATH" <<'PY'
import json, os, re, sys
path, count, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
enable_git_mirror = (sys.argv[4] if len(sys.argv) > 4 else os.environ.get("ENABLE_GIT_MIRROR", "1")) == "1"
git_mirror_path = sys.argv[5] if len(sys.argv) > 5 else os.path.join(os.path.expanduser("~"), ".cache", "ezgha-git-mirrors")

# Issue 229: pin the container's resolver list to the host's real forwarder plus
# two public fallbacks. Detected at write time so a host whose forwarder is not
# 10.32.0.28 still gets the entry that can answer VM-local names first. If the
# host exposes no private resolver, stop here instead of writing a guessed
# address: `--dns` would then send every container lookup to the wrong server.
resolv_paths = tuple(
    p for p in os.environ.get("EZGHA_BOOTSTRAP_RESOLV_PATHS", "").split(":") if p
) or ("/etc/resolv.conf", "/run/systemd/resolve/resolv.conf")
forwarder = None
for resolv_path in resolv_paths:
    try:
        for line in open(resolv_path):
            m = re.match(r"^nameserver\s+(\S+)", line)
            if m and m.group(1) not in ("1.1.1.1", "8.8.8.8", "9.9.9.9") \
                    and not m.group(1).startswith("127."):
                forwarder = m.group(1)
                break
    except OSError:
        pass
    if forwarder:
        break
if not forwarder:
    sys.exit("FATAL: no private resolver found; refusing to write a guessed dns "
             "entry into [runner] (issue 229)")

runner_extra_lines = [
    f'dns = ["{forwarder}", "1.1.1.1", "8.8.8.8"]\n',
    'dns_opts = ["timeout:2", "attempts:3"]\n',
]
if enable_git_mirror:
    runner_extra_lines.append(f"git_mirror_host_path = {json.dumps(git_mirror_path)}\n")

out = []
for line in open(path):
    if line.startswith("count = "):
        out.append(f"count = {count}\n")
    elif line.startswith("name_prefix = "):
        out.append(f'name_prefix = "{prefix}"\n')
    elif line.startswith("dns =") or line.startswith("dns_opts =") or line.startswith("git_mirror_host_path ="):
        continue  # re-inserted right after `image =` below
    else:
        out.append(line)
        if line.startswith("image = "):
            out.extend(runner_extra_lines)

# If the example ever drops its `image =` line the entries must still land in
# [runner], so insert after [runner] (or append) rather than silently omitting them.
if not any(l.startswith("dns = ") for l in out):
    inserted = False
    new_out = []
    for line in out:
        new_out.append(line)
        if not inserted and line.strip() == "[runner]":
            new_out.extend(runner_extra_lines)
            inserted = True
    if not inserted:
        new_out.extend(runner_extra_lines)
    out = new_out

open(path, "w").writelines(out)
print(f"runner dns forwarder={forwarder} git_mirror={git_mirror_path if enable_git_mirror else 'disabled'}")
PY
grep -E '^(count|name_prefix|dns|dns_opts|git_mirror_host_path) =|host_containment' "$HOME/.config/ezgha/config.toml"

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

step "7b. host-side bare git mirror cache warmer (ENABLE_GIT_MIRROR=${ENABLE_GIT_MIRROR})"
if [ "$ENABLE_GIT_MIRROR" = "1" ]; then
  mkdir -p "$HOME/.local/state/ezgha"
  chmod 0700 "$HOME/.local/state/ezgha"
  install -m 0755 \
    "$REPO_DIR/scripts/refresh_runner_caches.sh" \
    "$REPO_DIR/scripts/refresh_runner_caches.py" \
    "$REPO_DIR/scripts/ezgha_cache_common.py" \
    "$REPO_DIR/scripts/ezgha_git_mirrors.py" \
    "$REPO_DIR/scripts/ezgha_wheelhouse.py" \
    "$REPO_DIR/scripts/ezgha_npm_cache.py" \
    "$SCRIPTS_DIR/"
  sed -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" \
      -e "s|@HOME@|${HOME}|g" \
      "$REPO_DIR/systemd/ezgha-cache-warm.service" \
    > "$HOME/.config/systemd/user/ezgha-cache-warm.service"
  sed -e "s|@SCRIPTS_DIR@|${SCRIPTS_DIR}|g" \
      -e "s|@HOME@|${HOME}|g" \
      "$REPO_DIR/systemd/ezgha-cache-warm.timer" \
    > "$HOME/.config/systemd/user/ezgha-cache-warm.timer"
  if grep -q '@[A-Z_]*@' "$HOME/.config/systemd/user/ezgha-cache-warm.service" \
     || grep -q '@[A-Z_]*@' "$HOME/.config/systemd/user/ezgha-cache-warm.timer"; then
    echo "unrendered @...@ placeholder in the cache-warm unit"; exit 1
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now ezgha-cache-warm.timer
  systemctl --user is-active ezgha-cache-warm.timer
  # Initial best-effort mirror warm pass (bounded timeout; fail-open on low disk
  # just like refresh_runner_caches.py so bootstrap never hangs or aborts).
  GH_TOKEN="$(cat "$HOME/.config/ezgha/gh_token" 2>/dev/null || printf '%s' "$GH_TOKEN")" \
    timeout "${CACHE_WARM_TIMEOUT_SEC:-300}s" \
    "$SCRIPTS_DIR/refresh_runner_caches.sh" --skip-wheels --skip-npm \
    || echo "WARNING: initial git mirror warm pass did not complete cleanly (continuing; runners fail open and timer will retry)"
else
  if systemctl --user is-enabled ezgha-cache-warm.timer >/dev/null 2>&1; then
    systemctl --user disable --now ezgha-cache-warm.timer 2>/dev/null || true
  fi
  echo "git mirror cache warmer disabled (ENABLE_GIT_MIRROR=${ENABLE_GIT_MIRROR})"
fi

step "8. install + start the user service"
ezgha install-service
sleep 5
systemctl --user is-active ezgha.service || true
systemctl --user status ezgha.service --no-pager | head -12 || true

step "9. verify (slot containers, then a real job is the operator's acceptance test)"
docker ps --filter label=ezgha=managed --format '{{.Names}} {{.Status}}' | head -"$((RUNNER_COUNT + 1))" || true
echo "BOOTSTRAP-COMPLETE host=$HOST_TAG count=$RUNNER_COUNT prefix=$NAME_PREFIX"
