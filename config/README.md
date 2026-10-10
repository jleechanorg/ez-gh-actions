# Fleet config templates

Reference `config.toml` files for the two production ezgha hosts. These are **not**
auto-installed — copy to `~/.config/ezgha/config.toml` after editing limits for your
machine.

## Mac disk admission floor

The Mac template sets `limits.min_free_disk_gb = 30`. This uses ezgha's existing
disk admission guard: when either the Docker volume or outer host filesystem is
below the configured floor, the next reconciliation skips new runner starts.
The guard does not stop already-running jobs. Once a later check sees both
locations at or above the same 30 GiB floor, runner admission resumes; the guard
has no separate resume threshold or hysteresis.

Mac free-space observations ranged from 35–46 GiB; this is an observed range,
not a stable baseline. A four-job snapshot showed 9.23 GB (about 8.60 GiB) of
current writable-layer data. That point-in-time footprint is not a maximum or
cumulative write total. For scale only, a comparable additional 8.60 GiB of
growth after the 30 GiB floor is reached would leave about 21 GiB free. Actual
job growth can differ, so this is not a guarantee or a bound. Linux templates
and the Rust default remain at 10 GiB.

```bash
# MacBook (4× ez-mac-runner-h-*)
cp config/config.toml.mac.example ~/.config/ezgha/config.toml

# jeff-ubuntu (20× ez-runner-c-*)
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

The approved Linux profile is 20 runners at 1400 MiB per job. The existing
14-runner profile at 2000 MiB per job and 10-runner profile at 2500 MiB per job
remain supported for rollback; all three use the same 26 GiB `MemoryHigh` and
28 GiB `MemoryMax` aggregate cap. A temporary live count below the selected
profile is an incident state, not a supported capacity profile.

Select all profile values together when switching capacity:

| Profile | `runner.count` | `limits.memory_mb` | `runner.runner_floor_mb` | actions `TasksMax` |
|---------|----------------|--------------------|--------------------------|-------------------|
| Approved | 20 | 1400 | 1400 | 8000 |
| Rollback (14) | 14 | 2000 | 2000 | 8000 |
| Rollback (10) | 10 | 2500 | 2500 | 6000 |

For a capacity switch, inspect the runtime config and `failure_ladder.toml`,
deploy the reviewed binary and matching profile, then restart `ezgha.service`
under operator authorization. The broad `install.sh` also rebuilds the image
and installs unrelated units. Preserve running jobs during a capacity switch;
new containers inherit the selected per-job limit. An open failure-ladder
cooldown is a diagnostic signal; preserve its ledger.

After restart, prove every configured Linux slot locally with `Runner.Worker`
via `docker top`. Repository-only preflight does not establish live capacity.

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
