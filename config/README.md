# Fleet config templates

Reference `config.toml` files for the two production ezgha hosts. These are **not**
auto-installed — copy to `~/.config/ezgha/config.toml` after editing limits for your
machine.

```bash
# MacBook (6× ez-mac-runner-b-*)
cp config/config.toml.mac.example ~/.config/ezgha/config.toml

# jeff-ubuntu (10× ez-runner-c-*)
cp config/config.toml.linux.example ~/.config/ezgha/config.toml

# jeff-ubuntu canary reserved capacity (1× ez-canary-runner-b-*)
cp config/config.toml.linux-canary.example ~/.config/ezgha/canary.toml
```

Then restart the supervisor:

```bash
# macOS
launchctl kickstart -k gui/$(id -u)/org.jleechanorg.ezgha

# Linux
systemctl --user restart ezgha.service
```

## Jeff-Ubuntu restore boundary

The production contract is 10 Linux runners. A temporary live count of 5 is
an incident state, not a second supported template.

For a count-only restoration window, do **not** run `install.sh`: it also
rebuilds the Docker image, installs units, and restarts the service. Inspect
the runtime config and `failure_ladder.toml` first, deploy the already-reviewed
binary separately, change only `runner.count`, and then restart `ezgha.service`
under explicit operator authorization. An open failure-ladder cooldown is a
diagnostic signal; do not delete its ledger merely to force ten starts.

After restart, the exit criterion is ten named Linux slots proven locally with
`Runner.Worker` via `docker top`, not GitHub API counts. Those deployment and
verification actions change live machine state and are intentionally outside a
repository-only preflight.

## `minimum_isolation` policy

| Host | Value | Why |
|------|-------|-----|
| Mac (Colima) | `container` | Colima runs docker inside a VM, but ezgha's backend isolation level is still `container`. `minimum_isolation = "vm"` causes serve to **fail-closed** when the daemon blips to container-only. |
| Linux (native docker) | `container` | Bare-metal docker on the host kernel; strongest available backend is `container`. Use `vm` only if you have a VM-contained daemon **and** want fail-closed enforcement. |

**Image:** always `ezgha-runner:latest` (built from `Dockerfile.runner`), not the bare upstream `actions-runner` image.

## Canary verifier config

`docs/verify-exit-criteria.sh` uses the main config for all gates by default,
including Gate 4. Set `CANARY_CONFIG_FILE` when Gate 4 should run against
separate repo-scoped reserved canary capacity:

```bash
CANARY_CONFIG_FILE=~/.config/ezgha/canary.toml ./docs/verify-exit-criteria.sh
```

The Linux canary example intentionally uses distinct `state_dir`,
`runner.name_prefix`, and `runner.labels` from the main Linux fleet so the
canary capacity is isolated from general org-scoped work.

Run the canary config as a separate repo-scoped daemon; for a manual proof run:

```bash
systemd-run --user --unit ezgha-canary ~/.cargo/bin/ezgha --config ~/.config/ezgha/canary.toml serve
```
