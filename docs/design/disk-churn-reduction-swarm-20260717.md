# Disk-churn reduction beyond the fstrim fix — 2026-07-17

**Context:** the immediate crisis (Colima's sparse disk growing 33.2→43.4 GiB in a 90-minute window from ephemeral CI-runner churn, with a broken host-side trim guard) was root-caused and fixed in `install.sh` commit [`688a798`](https://github.com/jleechanorg/ez-gh-actions/commit/688a798d3edf608f9ec0c11b3d2f51df90d6b15): the guest's own `fstrim.timer`/`fstrim.service` are overridden to run every 5 minutes with `--all` scope (the stock config runs weekly and silently skips the docker data-root since it's not listed in `/etc/fstab`). Verified live: Data volume 837.0 → 791.7 GiB, Colima 49.53 → 4.19 GiB.

This doc covers the follow-up: a `/swarm` investigation (5 parallel miners + synthesis, Workflow tool) into *further* architectural disk-reduction opportunities beyond trimming faster — i.e. reducing churn at the source.

## Convergent finding

The swarm's top recommendation converged almost exactly with an already-open, independently-filed bead (`jleechan-93cf` (no GitHub issue — see `br show jleechan-93cf` from this repo's directory; "Move high-churn runner workspaces and caches out of ephemeral Docker writable layers")), created by a concurrent investigation around the same time. Both arrived at the same root mechanism: all runner containers currently have **zero mounts**, so every job's git checkout, pip installs, and build scratch write into the container's ephemeral overlay writable layer, which is never returned to the host until an explicit trim. `jleechan-93cf`'s own live measurement: one 60-second churn window showed 1.05 GiB of aggregate container-writable-layer growth correlating to ~503-518 MiB of *immediate* host-visible growth in the same window.

## Ranked opportunities (full detail: swarm miner reports, not reproduced here)

1. **Shared read-only cache volumes** (git mirror + pip wheelhouse) — HIGH impact, MEDIUM risk. Targets the largest identified per-job line item: full-history checkouts (`fetch-depth: 0`) on 7 gating job configs in the highest-frequency workflows.
2. **tmpfs mounts for `_work`/`/tmp` scratch** — MEDIUM-HIGH impact (unquantified), MEDIUM risk (needs careful memory-budget sizing to avoid OOM).
3. **`--no-install-recommends` on the apt install in `Dockerfile.runner`** — LOW-MEDIUM impact (~250-290 MB, one-time image size, not per-job churn), LOW risk.
4. **Docker `log-opts` (`max-size`/`max-file`)** — LOW impact today, but a prerequisite guardrail before any move toward longer-lived containers.
5. **Drop `webkit` from Playwright's `install-deps`** — unverified ~80-150 MB, needs a downstream-repo usage check first.
6. ~~Container count/consolidation~~ — **not a meaningful lever**; the 3.6 GB runner image is shared/deduped across all 6 containers already, marginal per-container cost is ~100-200 KB.
7. `free_disk_gb()` host-vs-VM-overlay measurement bug (`jleechan-mdi`) — **verified already fixed** by commit `46dd073` (2026-07-14); closed as stale housekeeping.

**Explicitly rejected:** a "warm pool" of pre-created, reused-via-`docker exec` containers. This would silently reintroduce the exact cross-job state-leak risk GitHub's ephemeral-runner model exists to prevent (job N's leftover env/creds/files visible to job N+1), and doesn't even reduce CREATE/DESTROY count since one fresh container per job is still required for isolation. Correctly excluded from the ranking; not implemented.

## What shipped (Phase 1, commit `092ed40`)

The **pip wheelhouse** half of opportunity #1 — the self-contained piece that doesn't require resolving how `actions/checkout` would consume a shared git mirror (that wiring mechanism was not confirmed by any miner and needs its own design pass):

- `RunnerConfig.wheelhouse_host_path: Option<String>` — opt-in, `None` by default.
- `start_one_with_generate_at_slot` mounts it read-only at `/opt/wheelhouse` with `PIP_FIND_LINKS` set, **only if the path exists on the host at container-start time** (fail-open — a missing cache directory must never block a runner from starting).
- Two new tests (`wheelhouse_mount_added_when_configured_path_exists`, `wheelhouse_mount_skipped_fail_open_when_configured_path_missing`); full suite 314/314 passes.
- Documented in `config/config.toml.mac.example`.

## Live verification of the mount mechanism

Ran a standalone throwaway container against the real Colima docker daemon (not the production `org.jleechanorg.ezgha` daemon or its 6 real containers):

```
docker run --rm -v /tmp/wheelhouse_live_test:/opt/wheelhouse:ro -e PIP_FIND_LINKS=/opt/wheelhouse alpine:3.19 \
  sh -c "ls -la /opt/wheelhouse && echo PIP_FIND_LINKS=\$PIP_FIND_LINKS && touch /opt/wheelhouse/should-fail"
```

Confirmed: the mounted file is visible, `PIP_FIND_LINKS` resolves correctly, and the write attempt is rejected with `Read-only file system` (isolation confirmed) — the exact mechanism `start_one_with_generate_at_slot` now uses, verified live without touching the production fleet.

## What did NOT ship (deliberately)

- **Not deployed to the live host.** `org.jleechanorg.ezgha` was actively managing 6 real runner containers at the time of this work; rebuilding the binary and restarting the daemon to pick up this change would have disrupted live CI jobs. Deployment (rebuild, restart, populate a real wheelhouse directory, exercise real jobs) is a deliberate follow-up, not bundled into this pass.
- **The git-mirror half of opportunity #1** — deferred pending a design pass on the `actions/checkout`-consumes-local-mirror wiring mechanism.
- **tmpfs scratch mounts (#2)** — a good follow-up once the wheelhouse mount mechanism is proven live, since it reuses the same `docker run` argument-construction code path.
- **`jleechan-93cf`'s full acceptance criteria** are NOT met by this pass: no before/after measurement captured, no wheelhouse directory populated with real wheels, no 6-concurrent-job proof, no 30-minute live churn evidence. The bead stays open with these gaps explicitly noted.

## Provenance

- Workflow run `wf_c1521122-3da`, 6 agents (5 miners + 1 synthesis), 513,776 subagent tokens, 111 tool calls, ~7 min wall-clock.
- Verified all bead citations directly via `br show` from inside this repo directory (a prior pass in a sibling investigation falsely declared several of these same bead IDs "fabricated" by checking from a different repo's directory — `br` beads are scoped by `source_repo_path`/cwd, not globally visible; see memory `feedback_2026-07-17_br_beads_scoped_by_cwd_not_global.md` in the disk_magician project).
