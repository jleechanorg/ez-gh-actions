# ez-gh-actions — Design (v1)

Easy isolated self-hosted GitHub Actions runners: VM-preferred, container fallback with
hard resource limits.

This design is the **adjusted** version of the original `gha-isolated` proposal
([gist](https://gist.github.com/jleechan2015/f487a9773f650719680d27d0f8ad6c07)), rewritten
after a 32-agent adversarial review (4 independent reviewers — facts/web, architecture,
Rust, existing-infra fit — with every critical/major finding adversarially verified:
26 confirmed, 2 refuted).

## What changed from the original proposal, and why

| # | Original proposal | Adjusted design | Verified reason |
|---|---|---|---|
| 1 | Wrap `gha-outrunner` | **Self-contained** — drive Docker/GitHub directly | `gha-outrunner` exists (NetwindHQ/gha-outrunner) but has 3 stars, 0 forks, 1 maintainer: a bus-factor-1 load-bearing dependency. Its real interface also doesn't match the proposal (config.yml not outrunner.yml, no start/stop/status subcommands, no pids_limit). |
| 2 | "GitHub Scale Sets + ephemeral" | **JIT runners** (`generate-jitconfig` API) | JIT registration is the standalone-correct primitive: one job per runner, auto-deregister, no token to store. (Scale sets outside k8s are now legitimate via GitHub's `actions/scaleset` Go client, but JIT is simpler and sufficient at this scale.) |
| 3 | No registration/auth story | All GitHub API access via the **`gh` CLI** (inherits its auth) | Confirmed critical gap: the original config could never produce a working runner. v1 requirement: `gh auth login`. |
| 4 | YAML config via `serde_yaml`, written to cwd, format!-templated | **TOML** typed serde structs, versioned (`version = 1`), in the XDG config dir | `serde_yaml` is archived/deprecated; cwd writes silently clobber; string templating is unvalidatable. |
| 5 | Silent fallback to weakest backend | **Fail-closed isolation policy**: `policy.minimum_isolation = "vm" \| "container"` | Confirmed major: isolation downgrades must be explicit, never silent. |
| 6 | Hardcoded 4G/2cpu/count:2 | Limits **derived from host capacity** (½ RAM clamped to [2 GiB, 16 GiB], ½ cores), overridable in config | Confirmed major: fixed limits contradict the tool's own resource-protection principle. |
| 7 | No disk story | **Disk floor guard**: refuse to spawn runners when free disk < `min_free_disk_gb` (default 10) | Confirmed critical (infra-fit): disk exhaustion is the dominant incident class in the existing runner fleet. Ephemeral `--rm` containers also make workspace debris die with the job. |
| 8 | `/dev/kvm` existence check | Open `/dev/kvm` read-write to verify **permissions**, and require `virsh` | Confirmed major: existence without kvm-group membership selects a backend that fails at runtime. |
| 9 | "Assume Sysbox is installed" | Detect `sysbox-runc` in `docker info` runtimes; only use it when actually present | Confirmed major landmine. Sysbox-CE is alive (v0.7.0, Docker-sponsored). |
| 10 | `sysinfo` crate (init discarded) + `duct` + `colored` | `std::process` + `/proc/meminfo` + `available_parallelism` — 7 small deps total | Confirmed major: heavyweight deps for discarded data. |
| 11 | Service management "not yet implemented" | **Implemented v1**: systemd `--user` unit / launchd plist generated from the running binary path, enabled immediately | Confirmed major: unattended operation is a prerequisite, not a stretch goal. |
| 12 | "GCE has no strong KVM" | GCE **supports nested virtualization** on Intel x86 machine types (not E2/AMD/Arm) — libvirt is a valid future backend on GCE | Confirmed factual error in the original. |

Refuted findings (kept for the record): the "no ephemeral lifecycle" architecture claim
was refuted as written (the original delegated lifecycle to the wrapper) — moot here since
v1 owns the lifecycle; a duplicate module-table finding was folded into #11.

## Core loop

```
ezgha serve
  └── every 30s: ensure N managed runner containers are alive
        ├── disk floor check (fail loudly, spawn nothing when low)
        ├── POST …/actions/runners/generate-jitconfig   (via gh api)
        └── docker run -d --rm
              --memory/--memory-swap/--cpus/--pids-limit   (hard cgroup limits)
              --security-opt no-new-privileges
              [--runtime sysbox-runc when available]
              ghcr.io/actions/actions-runner ./run.sh --jitconfig <jit>
```

A JIT runner accepts **exactly one job**, then deregisters and exits; `--rm` removes the
container; `serve` spawns a fresh one. Every job gets a pristine filesystem — the
workspace-pollution / zombie-runner / cache-corruption class of incidents is eliminated
by construction rather than by cleanup scripts.

## Backend ladder (strongest first)

| Backend | Isolation | v1 status |
|---|---|---|
| Tart (macOS Apple Silicon) | VM | detected, reported by `doctor`; drive in M2 |
| libvirt/KVM (Linux) | VM | detected (incl. permission check), drive in M2 |
| Docker + sysbox-runc | container+ | **implemented** |
| Docker | container | **implemented** |

`select()` picks the strongest *implemented* backend that satisfies
`policy.minimum_isolation`; anything stronger-but-unimplemented produces a warning, and a
policy violation is a hard error (fail closed).

## Module map

| File | Responsibility |
|---|---|
| `src/main.rs` | clap CLI: `init`, `doctor`, `start`, `serve`, `stop`, `status`, `install-service` |
| `src/platform.rs` | capability detection (KVM rw-open, tart, virsh, docker daemon, sysbox runtime, RAM/CPU) |
| `src/backend.rs` | backend ladder, fail-closed selection (unit-tested) |
| `src/config.rs` | versioned TOML config, capacity-derived defaults (unit-tested) |
| `src/github.rs` | JIT config, runner list/remove via `gh api` |
| `src/docker_backend.rs` | container lifecycle, hard limits, disk floor guard |
| `src/service.rs` | systemd `--user` / launchd install |

## Security posture (v1)

- No docker.sock mounted into runners; no privileged containers; `no-new-privileges`.
- Hard cgroup ceilings (memory+swap, cpus, pids) so a runaway job dies in its cgroup.
- JIT config is passed as a container argument (visible to local `docker inspect`;
  acceptable single-user-host tradeoff — it is single-use and expires).
- Public-repo caution: keep default workflow triggers to `workflow_dispatch`/protected
  branches; do not enable fork-PR jobs on self-hosted runners.

## Milestones

- **M1 (this repo, done)**: docker backend end-to-end, JIT ephemeral, limits, disk floor,
  service install, doctor.
- **M2**: drive libvirt (cloud-image + cloud-init) and Tart; per-job VMs.
- **M3**: health/queue-depth monitoring + alerting hooks (port the battle-tested
  heal/monitor semantics from `worldarchitect.ai/self-hosted-oss`).
- **M4**: org-scope fleet config, multiple runner pools/labels.

## Known limitations (v1)

From the post-implementation adversarial /er + code review (15-agent workflow; two
confirmed criticals were fixed immediately — daemon-side disk measurement, host-scoped
runner deregistration). Confirmed-major items deferred, in priority order:

- **Crash-looping runner containers leak JIT registrations**: a container that starts
  then dies (`--rm`) is invisible to `managed_containers()`, so `serve` respawns with a
  new JIT config each cycle and never cleans the orphaned registration; no backoff.
  Mitigation planned: reconcile GitHub's runner list (host-scoped prefix) each serve
  cycle + exponential backoff on repeated immediate exits.
- **`ezgha stop` does not stop the installed service**: with `install-service` active,
  `serve` respawns runners within 30s of `stop`. Stop should also `systemctl --user stop`
  / `launchctl unload` (or take a run lock shared with serve/start).
- **`docker ps --format json` requires Docker CLI ≥ 23**: older CLIs (Ubuntu 22.04
  `docker.io`) print the literal template. Needs a version probe or `--format '{{json .}}'`.
- **Managed label is not target-scoped**: two configs on one host sharing the daemon
  would miscount each other's capacity; label should include the target.
- **Container hardening gaps**: no `--cap-drop ALL`, no egress restriction, no read-only
  rootfs. `no-new-privileges` + cgroup limits + no docker.sock are accurate but partial.
- **JIT config visible in argv/docker inspect** on the runner host (single-use,
  short-lived; treat the host as single-tenant until delivered via file/env).
- Requires the `gh` CLI to be authenticated; no GitHub App auth yet.
- Tart/libvirt are detect-only; VM isolation is not yet delivered (the ladder and policy
  are wired so it lands without config changes).
- No per-job disk quota (docker storage-opt needs specific storage drivers); the floor
  guard bounds daemon-level damage instead.
- `serve` is a foreground loop under systemd/launchd; no HTTP health endpoint yet.
