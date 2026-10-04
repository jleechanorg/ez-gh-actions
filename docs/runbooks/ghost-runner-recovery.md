# Operator Runbook: Ghost Runner Recovery via Prefix Bump

## Overview
When an ungraceful host crash or VM restart (such as a macOS hypervisor crash or sudden power loss) occurs while GitHub Actions runners are executing jobs, the GitHub Actions control plane retains those runners in an offline/busy state:
```json
{
  "name": "ez-mac-runner-g-1",
  "status": "offline",
  "busy": true
}
```
Attempting to delete these runners via the GitHub API returns `HTTP 422: Runner is currently running a job and cannot be deleted` until GitHub's internal job lease timeout decays. When `ezgha` restarts, JIT config generation for that runner name returns `HTTP 409: Already exists` (name collision), pausing admission.

Because GitHub Actions workflows bind strictly to labels (`runs-on: [self-hosted, self-hosted-macos, ezgha]`), runner names can be changed arbitrarily without breaking any workflow jobs.

---

## Recovery Procedure (OPERATOR-ONLY)

### Step 1: Verify Ghost Runner Contention
OPERATOR-ONLY: Run:
```bash
GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER="" timeout 15s gh api /orgs/jleechanorg/actions/runners | jq '.runners[] | select(.status == "offline" and .busy == true)'
```
If one or more runners are locked in `offline` + `busy: true`, note their prefix (e.g. `ez-mac-runner-g`) and their runner IDs. For a complete
corroborating response when more than one page may exist, use:
```bash
GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER="" timeout 15s \
  gh api --paginate --slurp '/orgs/jleechanorg/actions/runners?per_page=100' \
  | jq '.[].runners[] | select(.status == "offline" and .busy == true)'
```
The GitHub response only corroborates the suspected registrations; local
`docker ps`/`docker top` evidence remains the capacity and execution source of
truth.

### Step 2: Resolve the Active Configuration and State Paths
OPERATOR-ONLY: Read the `--config` argument from the loaded supervisor plist or
systemd unit. Do not assume that `~/.config/ezgha/config.toml` is active on
macOS; the installed launchd configuration may select:
`$HOME/Library/Application Support/org.jleechanorg.ezgha/config.toml`.

Resolve `state_dir` from that configuration. If it is absent, the daemon's
default is `${XDG_CONFIG_HOME:-$HOME/.config}/ezgha`. The state directory
contains daemon-owned `slot_assignments.toml` and `quarantined_slots.toml`.

Before editing anything, create a recoverable backup of the exact active
configuration and any existing state files. This is a read-only copy of the
daemon inputs:
```bash
# Example only: set CONFIG_PATH and STATE_DIR from the active service first.
CONFIG_PATH="$HOME/Library/Application Support/org.jleechanorg.ezgha/config.toml"
STATE_DIR="$HOME/.config/ezgha"
BACKUP_DIR="$HOME/.local/state/ezgha/recovery-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
CONTROLLER_STATE="$BACKUP_DIR/controller-state.txt"
: > "$CONTROLLER_STATE"
cp -p "$CONFIG_PATH" "$BACKUP_DIR/config.toml"
for state_file in slot_assignments.toml quarantined_slots.toml; do
  if [ -e "$STATE_DIR/$state_file" ]; then
    cp -p "$STATE_DIR/$state_file" "$BACKUP_DIR/$state_file"
  fi
done
```
Do not edit the configuration or clear either state file until the supervisor
has been quiesced in Step 3. For a partial ghost incident, the daemon's
per-slot quarantine and reconciliation are the supported recovery path.

### Step 3: Inspect Targets, Then Quiesce the Supervisor
Prefix rotation changes admission for the whole current prefix, so inspect all
configured containers under that prefix before stopping anything. A target
with a `Runner.Worker` is an active job; defer prefix rotation and container
removal until the host/prefix has drained. An idle `Runner.Listener` is also
left in place because it can claim a job between inspection and removal. A
`docker top` failure for a running container is an inspection failure, not
proof that the target is safe. A read-only prefix inventory is allowed; it is
never a removal selector:
```bash
CURRENT_PREFIX="ez-mac-runner-g"  # set from the active config
docker ps -a --filter "name=^/${CURRENT_PREFIX}-" --format '{{.Names}} {{.Status}}'
```
Use `doctor-runner` and per-slot `docker top` checks to prove the entire
current prefix is drained before editing `CONFIG_PATH`. If any current-prefix
container is still running, defer the rotation.

Also identify any watchdog or timer that can restart the daemon while it is
quiesced (`launchctl list` plus the loaded plist on macOS, or the user unit
and timers on Linux). Record its prior loaded/active state, then quiesce every
known restart controller before quiescing the primary daemon. If an unknown
controller can still restart it, defer the procedure.
Run only the block for the host being recovered. Continue in the same shell,
or set `CONTROLLER_STATE` from the backup directory created in Step 2.

On macOS, record and quiesce the exact launchd jobs:
```bash
set -e
WATCHDOG_PLIST="$HOME/Library/LaunchAgents/org.jleechanorg.ezgha-watchdog.plist"
if launchctl print "gui/$(id -u)/org.jleechanorg.ezgha" >/dev/null 2>&1; then
  echo 'mac_primary=loaded' >> "$CONTROLLER_STATE"
else
  echo 'mac_primary=not-loaded' >> "$CONTROLLER_STATE"
fi
if launchctl print "gui/$(id -u)/org.jleechanorg.ezgha-watchdog" >/dev/null 2>&1; then
  echo 'mac_watchdog=loaded' >> "$CONTROLLER_STATE"
  launchctl bootout "gui/$(id -u)/org.jleechanorg.ezgha-watchdog"
else
  echo 'mac_watchdog=not-loaded' >> "$CONTROLLER_STATE"
fi
if grep -q '^mac_primary=loaded$' "$CONTROLLER_STATE"; then
  launchctl bootout "gui/$(id -u)/org.jleechanorg.ezgha"
fi
if launchctl print "gui/$(id -u)/org.jleechanorg.ezgha-watchdog" >/dev/null 2>&1 ||
   launchctl print "gui/$(id -u)/org.jleechanorg.ezgha" >/dev/null 2>&1; then
  echo "REFUSING: launchd controller is still loaded" >&2
  exit 1
fi
```

On Linux, record and stop both watchdog units plus the primary service. Stopping
the timer alone is unsafe:
```bash
set -e
for unit in ezgha-watchdog.timer ezgha-watchdog.service; do
  active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  printf 'linux_%s active=%s\n' "$unit" "$active" >> "$CONTROLLER_STATE"
done
primary_active=$(systemctl --user is-active ezgha.service 2>/dev/null || true)
printf 'linux_ezgha.service active=%s\n' "$primary_active" >> "$CONTROLLER_STATE"
systemctl --user stop ezgha-watchdog.timer ezgha-watchdog.service ezgha.service
if systemctl --user is-active --quiet ezgha-watchdog.timer ||
   systemctl --user is-active --quiet ezgha-watchdog.service ||
   systemctl --user is-active --quiet ezgha.service; then
  echo "REFUSING: a Linux ezgha controller is still active" >&2
  exit 1
fi
```

Then inspect the explicit targets before any removal:
```bash
GHOST_CONTAINERS=(ez-mac-runner-g-2)  # replace with exact inspected names
for container in "${GHOST_CONTAINERS[@]}"; do
  status=$(docker inspect --type=container --format '{{.State.Status}}' "$container") || exit 1
  case "$status" in
    exited|dead) ;;
    running)
      top_output=$(docker top "$container" -eo pid,comm) || {
        echo "REFUSING: cannot inspect $container" >&2
        exit 1
      }
      if grep -Eq '(^|[[:space:]])Runner\.(Worker|Listener)([[:space:]]|$)' <<<"$top_output"; then
        echo "DEFERRING: $container is still running" >&2
        exit 1
      fi
      echo "DEFERRING: $container has an unknown running process state" >&2
      exit 1
      ;;
    *)
      echo "REFUSING: $container has unexpected state $status" >&2
      exit 1
      ;;
  esac
done
```
Never derive a removal list from the broad `ezgha=managed` label. If the
preflight succeeds, stop the supervisor before changing configuration or
containers so its reconciliation loop cannot refill a slot during recovery.
Running containers are preserved during the daemon's bounded shutdown drain.
After every controller and the primary daemon are stopped, re-inventory every
current-prefix container and defer if any is still running:
```bash
PREFIX_IDS=$(docker ps -aq --filter "name=^/${CURRENT_PREFIX}-")
for container in $PREFIX_IDS; do
  status=$(docker inspect --type=container --format '{{.State.Status}}' "$container") || exit 1
  case "$status" in
    exited|dead) ;;
    *) echo "DEFERRING: current-prefix container $container is $status" >&2; exit 1 ;;
  esac
done
```
Recheck each explicit target after this inventory, and proceed only if it is
still `exited` or `dead`. Then edit `CONFIG_PATH` and increment
`runner.name_prefix` (for example, from `ez-mac-runner-g` to `ez-mac-runner-h`).
Remove only the explicitly inspected, stopped targets, without `--force`:
```bash
for container in "${GHOST_CONTAINERS[@]}"; do
  status=$(docker inspect --type=container --format '{{.State.Status}}' "$container") || exit 1
  case "$status" in
    exited|dead) docker rm "$container" ;;
    *) echo "REFUSING: $container is not stopped" >&2; exit 1 ;;
  esac
done
```
An absent local container is not an error; it needs no local removal. This
procedure intentionally has no fleet-wide container selector.

### Step 4: Resume ezgha Daemon
OPERATOR-ONLY: On macOS:
```bash
set -e
if grep -q '^mac_primary=loaded$' "$CONTROLLER_STATE"; then
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
  launchctl kickstart -k "gui/$(id -u)/org.jleechanorg.ezgha"
fi
if grep -q '^mac_watchdog=loaded$' "$CONTROLLER_STATE"; then
  launchctl bootstrap "gui/$(id -u)" "$WATCHDOG_PLIST"
  launchctl kickstart -k "gui/$(id -u)/org.jleechanorg.ezgha-watchdog"
fi
```
OPERATOR-ONLY: On Linux:
```bash
set -e
if grep -q '^linux_ezgha.service active=active$' "$CONTROLLER_STATE"; then
  systemctl --user start ezgha.service
fi
if grep -q '^linux_ezgha-watchdog.service active=active' "$CONTROLLER_STATE"; then
  systemctl --user start ezgha-watchdog.service
fi
if grep -q '^linux_ezgha-watchdog.timer active=active' "$CONTROLLER_STATE"; then
  systemctl --user start ezgha-watchdog.timer
fi
```
Restore only controllers recorded as previously loaded/active; leave a
previously inactive controller inactive.

### Step 5: Verify Fresh Registrations
OPERATOR-ONLY: Check that all configured slots are running:
```bash
sleep 8 && docker ps --filter "label=ezgha=managed" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
./doctor-runner
```

### Step 6: Purge Old-Prefix Ghost Runners Once Unlocked
The daemon's orphan reaper is scoped to the active `{name_prefix}-*`, so an
old-prefix registration requires an explicit operator deletion after GitHub
releases its job lock. Confirm the exact old-prefix runner ID is now
`status=offline` and `busy=false`, then delete only that ID:
```bash
RUNNER_ID="<exact runner ID from Step 1>"
GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER="" timeout 15s gh api -X DELETE "/orgs/jleechanorg/actions/runners/$RUNNER_ID"
```
Re-query that exact ID and require a not-found response before considering the
remote cleanup complete. Do not loop over all runners matching a label or
prefix.
