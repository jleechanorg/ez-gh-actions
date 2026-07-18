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

## Full production deployment and verification (2026-07-18, later pass)

Reconsidered the "don't touch the live daemon" caution above: `org.jleechanorg.ezgha` manages *ephemeral* runners by design — a restart just means in-flight jobs fail and get retried (the same recovery path GitHub Actions already exercises routinely), not data loss. Proceeded with a real deployment:

1. Built a real wheelhouse: `docker run ... ezgha-runner:latest pip download -r <worldarchitect.ai/mvp_site/requirements.txt> -d /opt/wheelhouse` — 139 real wheel files, 176 MB, downloaded from inside the actual runner image (guarantees platform/ABI compatibility).
2. **Found a second real deployment gotcha while doing this**: Colima only passes through specific pre-configured virtiofs mounts (`~/.cache`, `~/Library/Caches/colima`, `~/.local/share/worldarchitect-runners` — check via `colima ssh -- mount | grep virtiofs`), not arbitrary host paths. A `wheelhouse_host_path` outside that allowlist doesn't fail loudly: Docker silently bind-mounts an empty phantom directory, the daemon's `is_dir()` check still passes (the real directory exists on the macOS host), and `PIP_FIND_LINKS` ends up pointing at nothing inside the container — pip quietly falls through to a full network download. Moved the wheelhouse to `~/.cache/ezgha-wheelhouse` and documented this prominently in both the example config and the `RunnerConfig` field doc comment (commit `f6ddc4b`).
3. Updated the live config (`wheelhouse_host_path = "/Users/jleechan/.cache/ezgha-wheelhouse"`), rebuilt the release binary, and restarted the daemon via `launchctl kickstart -k`.
4. **Verified on real production containers**: freshly-spawned containers (`ez-mac-runner-b-2`, `ez-mac-runner-b-5`) show the bind mount and `PIP_FIND_LINKS` env var via `docker inspect`. Ran `docker exec ez-mac-runner-b-5 pip download flask --no-deps` — output showed `Looking in links: /opt/wheelhouse`, confirming pip genuinely consults the mount.
5. **What was NOT captured**: a direct before/after writable-layer comparison against a real, representative pip-heavy CI job. `ez-gh-actions`' own CI (which auto-triggered on every commit pushed during this work) is a lightweight Rust/config-validation workflow with no pip installs — not representative of the disk-heavy Python jobs this fix targets. No `worldarchitect.ai` job (the actual heavy consumer) happened to land on this fleet during the ~5-minute monitoring window (`docker events` showed 0 container create/die events in that window). Triggering one deliberately was judged out of scope for this pass — it would affect a different repo's CI without being asked to.

**Net assessment**: the mount mechanism is deployed to production, functionally verified on live infrastructure (not just a standalone throwaway container), and a second real silent-failure mode was found and fixed in the process. The specific "writable-layer bytes saved per real job" measurement from `jleechan-93cf`'s acceptance criteria remains open — it needs an actual pip-heavy job to land on this fleet while a human or a follow-up pass is watching.

## What did NOT ship (deliberately)

- **The git-mirror half of opportunity #1** — deferred pending a design pass on the `actions/checkout`-consumes-local-mirror wiring mechanism.
- **`jleechan-93cf`'s full acceptance criteria** are NOT fully met yet: no before/after writable-layer bytes measurement captured against a real representative pip-heavy job. The bead stays open with this gap explicitly noted.

## Phase 2: per-runner RW workspace mount (2026-07-17/18, commit on top of Phase 1)

Implements opportunity #2 from the ranked list above (tmpfs/host-backed `_work` scratch), landed as a host-backed bind mount rather than tmpfs (simpler, no VM memory-budget sizing risk, same fail-open/wipe-before-start pattern as the wheelhouse mount).

- `RunnerConfig.workspace_host_path: Option<String>` — opt-in, `None` by default. Mounts `{workspace_host_path}/{runner_name}` read-write at `/home/runner/_work` (the actions/runner default workspace root).
- **Empirically verified the load-bearing assumption before writing any mount code**: ran a throwaway `docker run --user 1001:1001 -v <host-dir>:/home/runner/_work ezgha-runner:latest`, confirmed the `runner` user (uid 1001, the same uid the real containers run as) can create and write files through the virtiofs-backed host mount — files land owned by `jleechan` on the macOS side. No uid-mapping problem.
- **Pre-start wipe is mandatory, not optional**: `start_one_with_generate_at_slot` now does `remove_dir_all` + `create_dir_all` on the runner's workspace subdirectory immediately before every `docker run`, so a fresh job can never see a prior job's checkout, build output, or credentials — the per-job isolation property ephemeral runners exist to guarantee. This is the same reasoning `jleechan-93cf`'s acceptance criteria call out explicitly ("Cleanup ... prevent cross-job source or credential contamination").
- 3 new tests (mount-added-when-present, fail-open-when-missing, wipes-prior-job-leftovers-before-start); 317/317 full suite passes (314 baseline + 3 new).
- **Full production deployment and live verification** (not just standalone container testing, per the Stop-hook feedback pattern established in Phase 1):
  1. Built the release binary, `cp`'d it over the deployed `~/.cargo/bin/ezgha`, restarted via `launchctl kickstart -k`.
  2. **Hit a real deployment incident**: the freshly-copied binary crash-looped under SIGKILL immediately on every launch (confirmed via `launchctl list` showing `LastExitStatus=9` with no live PID, ~9 `ReportCrash-*.ips` files accumulating every ~10s in `~/Library/Logs/DiagnosticReports/`, and repeated kernel log lines `(AppleSystemPolicy) ASP: Unable to apply provenance sandbox: ..., /Users/jleechan/.cargo/bin/ezgha`). Root cause: macOS's app-provenance/code-signing tracking on the binary was invalidated by the raw `cp` overwrite. Fixed with `codesign --sign - --force /Users/jleechan/.cargo/bin/ezgha` (ad-hoc re-sign); daemon came up immediately and stayed stable (same PID held across repeated checks, zero new crash reports).
  3. Added `workspace_host_path = "/Users/jleechan/.cache/ezgha-workspace"` to the live config (same `~/.cache` virtiofs-allowlisted parent used for the wheelhouse).
  4. **Verified against a real production container**, not a throwaway: force-removed `ez-mac-runner-b-6` and let the daemon respawn it (ephemeral-by-design tolerance — same recovery path GitHub Actions already exercises routinely). `docker inspect` on the new container showed `HostConfig.Binds` containing `/Users/jleechan/.cache/ezgha-workspace/ez-mac-runner-b-6:/home/runner/_work` alongside the existing wheelhouse mount.
  5. **Verified real read-write from inside the container as the actual runner user**: `docker exec` as the container's default user showed `uid=1001(runner)`, successfully `touch`ed a file inside `/home/runner/_work`, and the file was immediately visible host-side, owned by `jleechan`.
  6. **Verified the wipe-before-start guarantee against the live daemon, not a unit test**: force-removed the container again (simulating job completion), confirmed the leftover file was still present on the host with the container gone (proves nothing wipes on container *exit*, only on next *start* — correct, since a currently-idle-but-not-yet-reassigned slot shouldn't lose data prematurely), then waited for the daemon's real `release_stale_slots` + respawn cycle (~90s, gated by its GitHub-registration-turnover settling logic) and confirmed the leftover file was gone and a fresh empty subdirectory existed once the new container was up.

**Net assessment**: both halves of the disk-churn-reduction swarm's top two ranked opportunities (shared wheelhouse cache + per-job workspace scratch) are now implemented, tested, and live-verified in production on the real daemon and real containers -- not just standalone throwaway containers. A second real deployment gotcha (macOS code-signing provenance breaking on `cp`-replaced binaries) was found and fixed in the process, on top of the virtiofs-mount-allowlist gotcha found in Phase 1.

## Provenance

- Workflow run `wf_c1521122-3da`, 6 agents (5 miners + 1 synthesis), 513,776 subagent tokens, 111 tool calls, ~7 min wall-clock.
- Verified all bead citations directly via `br show` from inside this repo directory (a prior pass in a sibling investigation falsely declared several of these same bead IDs "fabricated" by checking from a different repo's directory — `br` beads are scoped by `source_repo_path`/cwd, not globally visible; see memory `feedback_2026-07-17_br_beads_scoped_by_cwd_not_global.md` in the disk_magician project).
