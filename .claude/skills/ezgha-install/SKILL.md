---
name: ezgha-install
description: Install ez-gh-actions (ezgha) and diagnose runner problems (docker daemon, gh auth, JIT registration, service, disk floor, VM containment)
---

# Installing and Debugging ezgha

`ezgha` runs each GitHub Actions job in a fresh ephemeral JIT runner container with
hard cgroup limits. This skill gets it installed and diagnoses the common failure
modes. **`ezgha doctor` is always the first command to run** — it prints host
capabilities, backend ladder, limits, and `gh` auth in one shot.

## Install

```bash
git clone https://github.com/jleechanorg/ez-gh-actions
cd ez-gh-actions && ./install.sh
```

`install.sh` is idempotent, needs no sudo, and:

1. Checks prerequisites, printing a `✗` + remediation hint for each miss:
   - `git`
   - `cargo`/`rustc` (install from https://rustup.rs)
   - `docker` CLI **and** a reachable daemon (`docker version`)
   - `gh` CLI **and** authentication (`gh auth status`)
2. Builds and installs the `ezgha` binary (`cargo install --path .`, or
   `--git` when run outside a clone).
3. Prints a PATH hint if `~/.cargo/bin` is not on `PATH`.
4. Prints the guided next steps.

Then:

```bash
ezgha init --target <owner/repo>   # writes ~/.config/ezgha/config.toml, sizes limits to the daemon
ezgha doctor                       # verify backends, limits, gh auth
ezgha start                        # launch one ephemeral runner now
ezgha install-service              # supervise runners at login (systemd --user / launchd)
```

Uninstall (config is left in place): `./install.sh --uninstall`.

## Diagnosis playbook

Run `ezgha doctor` first, then match the symptom:

| Symptom | Check | Fix |
|---|---|---|
| `gh api generate-jitconfig failed … 403` | `gh api repos/OWNER/REPO/actions/runners --jq '.total_count'` — do you have **repo admin**? | Self-hosted runner registration needs admin on the repo (or org). Get admin, or `gh auth refresh -s admin:org` / re-`gh auth login` with the right account. |
| `gh api generate-jitconfig failed … 404` | Is `target`/`scope` in the config right? Repo scope needs `owner/repo`; org scope needs the org login. | Fix `[github] target`/`scope`; confirm the repo/org exists and the token can see it. |
| `failed to run docker` / daemon unreachable | `docker version` (does the **Server** section print?), `docker context ls` | Start the daemon (Colima/Lima/Docker Desktop). If a stale context is selected: `docker context use default` (or the right one). |
| Image pull denied from `ghcr.io` | `docker pull ghcr.io/actions/actions-runner:latest` | A stale/expired ghcr login blocks even public pulls: `docker logout ghcr.io`, retry. For private images, `gh auth token \| docker login ghcr.io -u USER --password-stdin`. |
| `clamping cpus … (docker daemon capacity)` warning | `docker info --format '{{.NCPU}} {{.MemTotal}}'` | Expected when the daemon is a small VM. ezgha derives limits from the **daemon**, not the host. Lower `[limits] cpus`/`memory_mb`, or give the VM more (e.g. `colima start --cpu N --memory G`). |
| `only N GB free on docker's filesystem (floor: X GB) — refusing to spawn` | `docker system df` | Reclaim space: `docker system prune` (add `-a --volumes` if safe). The floor is measured inside the daemon; grow the VM disk if it stays low. Tune `[limits] min_free_disk_gb`. |
| `policy requires vm isolation but best available backend is docker` | `ezgha doctor` (is the daemon in a VM?) | The daemon is bare-metal docker. Either run docker inside a VM (Colima/Lima/Docker Desktop — reclassified as VM-grade by daemon-vs-host kernel mismatch), or lower `[policy] minimum_isolation = "container"`. |
| Service not respawning runners | `journalctl --user -u ezgha.service -n 50` (Linux); `launchctl list \| grep ezgha` (macOS) | Read the log for the real error (usually gh auth or docker). Re-run `ezgha install-service`. Note `ezgha stop` does **not** stop the service, so `serve` respawns within 30s — `systemctl --user stop ezgha.service` to pause it. |
| `gh api generate-jitconfig failed … 422` (runner name) | `hostname` — runner names are `ezgha-<hostname>-<suffix>`; GitHub caps names at 64 chars | Set a shorter hostname, or run on a host whose name keeps `ezgha-<hostname>-` well under 64 chars. |
| `gh auth: ✗` in doctor | `gh auth status` | `gh auth login` (or `gh auth switch` to the account with admin on the target). |
| No backend usable | `ezgha doctor` backend list empty | Install docker (or a VM backend). ezgha needs at least one usable backend. |

## Notes

- Config lives at `~/.config/ezgha/config.toml` (XDG). `ezgha --config <path>` overrides it.
- JIT runners are single-use: one job, then the runner deregisters and the `--rm`
  container is removed. A runner that never picks up a job is deregistered on `ezgha stop`.
- Limits (cpus, memory, pids, disk floor) are enforced against the **docker daemon's**
  capacity, which may be a VM smaller than the host — that is intentional, not a bug.
