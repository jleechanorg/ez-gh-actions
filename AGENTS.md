# ez-gh-actions — Agent Instructions

## Project overview
`ezgha` is a Rust CLI that manages ephemeral self-hosted GitHub Actions runners using Docker JIT registration. One binary; installs as a user systemd service.

## Fleet capacity standard — no excuses, prove per-slot execution
The fleet MUST run its full configured capacity: **20 Linux** (ez-runner-c-1..20 on jeff-ubuntu) + **4 Mac** (ez-mac-runner-h-1..4) = **24 runners**, and **EVERY one must be proven EXECUTING a real GitHub Actions job** — a `Runner.Worker` process, verified via `docker top <container>`. Anything less than 24/24 executing is **BROKEN**: root-cause and fix it. Do NOT explain a shortfall away as "churn", "normal ephemeral cycling", "counting artifacts", or "the API is just lying". Assume the capacity SHOULD be full and PROVE it per-slot.
- **The GitHub API CANNOT be trusted for fleet state.** Under the secondary rate limit it returned TRUNCATED/partial data — during the prior 22-runner contract, the same fleet was reported as 7 / 11 / 16 / 19 / 22 across calls minutes apart. Use LOCAL `docker top` / `docker ps` for `Runner.Worker`-per-slot as the source of truth, never API counts.
- **`./doctor-runner` is authoritative** (`./doctor.sh` is LEGACY/BROKEN on docker 27+ — see bead ez-gh-actions-91r — kept only as a back-reference). It enforces per-slot activity truth with a 4-state model: EXECUTING (job+repo+run URL+elapsed evidence) / IDLE-OK (nothing queued, or queued for less than `IDLE_STARVED_THRESHOLD_MIN`=5min — healthy) / IDLE-STARVED (queued >=5min — defect) / DOWN (no container — defect). A busy fleet must never measure as dead — the motivating defect this replaced was a tail-grep on "Listening for Jobs" that read a fully-busy fleet as 0/16 healthy. Run it; fix any DOWN or IDLE-STARVED slot before declaring the fleet healthy.
- **A deliberately parked platform is DISABLED, not DOWN** (bead jleechan-hxz0). One leg can be intentionally suspended (e.g. the Mac fleet is off while work runs on Linux + cmux Cloud). That is a decision, not an outage, and the two must never render the same way — otherwise a healthy 20/20 Linux fleet reads RED forever and nothing can tell a deliberate suspension from a crashed host. Declare it explicitly: `MAC_RUNNER_DISABLED=1 ./doctor-runner` (from a Linux/macOS doctor) or `REMOTE_LINUX_DISABLED=1` (from a macOS doctor). The opted-out leg prints `intentionally DISABLED (operator opt-out)`, contributes 0 slots to the contract, and adds 0 criticals. It is **never** inferred from live launchd/docker state — a daemon that died on its own also reads as "not running" — so an unset opt-out keeps today's fail-closed behavior. Record each suspension with its start date and restore condition in the bead or roadmap note that owns it, so the opt-out cannot quietly become a permanent capacity reduction. Name that record when you declare the opt-out (`EZGHA_SUSPENSION_RECORD=<bead-id>`); `./doctor-runner` prints the pointer on every parked run and **warns when it is missing** (`EZGHA_SUSPENSION_RECORD=none`), because the Mac leg sat parked from 2026-10-29 with no written record anywhere until a 2026-11-07 audit found it.
- Known failure mode: a rate-limited monitor in the single-threaded serve loop can starve `ensure_count` so runners aren't respawned (fleet silently drops below 20). See beads ez-gh-actions-yrt (backoff/circuit-breaker), zai (dedup), nuk (GitHub App).

## Key files
- `src/docker_backend.rs` — core runner lifecycle (slot allocation, container management)
- `src/github.rs` — GitHub API calls (JIT config, runner registration, conflict resolution)
- `src/main.rs` — CLI entry point
- `~/.config/ezgha/config.toml` — runtime config (do NOT commit this)
- `doctor-runner` — authoritative fleet health check script (`doctor.sh` is a deprecated back-reference, broken on docker 27+)
- `docs/verify-exit-criteria.sh` — ironclad exit criteria checker (Gates 0–10)
- `Dockerfile.runner` — custom runner image with `gh` + `jq` pre-installed
- `.claude/skills/ezgha-doctor/SKILL.md` — diagnostic + self-healing recipes
- `.claude/commands/doctor-ezactions.md` — `/doctor-ezactions` slash command (`.claude/commands/doctor.md` is a deprecation stub pointing here)

## Workspace mount + virtiofs symlink extraction bug (Mac, bead jleechan-93cf)

`runner.workspace_host_path` bind-mounts a host directory at `/home/runner/_work` (disk-churn fix). On Colima/Mac, `tar` extracting an archive containing a symlink onto that virtiofs-backed mount corrupts the symlink into an unreadable 0-byte mode-000 file (`tar: ...: Cannot open: Permission denied`) — confirmed live with `actions/setup-python`'s own tarball, which the GitHub Actions runner extracts into `_work/_actions` when downloading the action. A plain `ln -s` on the mount works fine; extraction into the container's own overlay filesystem works fine; only tar-extracting a real archive onto virtiofs corrupts symlink members. This broke `setup-python`/`setup-node`/`setup-gcloud` on the Mac fleet at a 41% job failure rate for ~1-2 days before being caught (2026-07-19).

**Fix (part 1 — runner-internal cache dirs):** the daemon tmpfs-shadows the three fixed runner-internal cache dirs (`_actions`, `_temp`, `_tool`) inside the workspace mount, so the runner's own action/tool-cache extraction never touches virtiofs, while checkouts/build scratch (which live directly under `_work/<owner>/<repo>`, the actual disk-churn win) are unaffected.

**WIDENED understanding (2026-07-19/20 follow-up):** the corruption is NOT limited to the three runner-internal cache dirs — any tar extraction of an archive containing a symlink anywhere on this mount is affected, including the real checkout path `_work/<owner>/<repo>` (exposed by workflow steps like `npm ci`, downloaded release tarballs, `docker save`/`load`, git submodule tarballs). Shadowing that path with tmpfs too was considered and rejected — it's the highest-volume directory and the actual reason this mount exists (checkout/build-scratch disk churn), so tmpfs-shadowing it would reintroduce the original problem.

**Fix (part 2 — checkout path, everywhere else on the mount):** the runner image (`Dockerfile.runner`) bakes a `tar` wrapper at `/usr/local/bin/tar` (`docker/tar-workspace-wrapper.sh`, resolves ahead of the real `/usr/bin/tar` in PATH). The daemon sets `EZGHA_VIRTIOFS_WORKSPACE=1` on every container that has the workspace mount (`docker_backend.rs`); when that flag is set, any tar **extract** whose destination resolves under `/home/runner/_work` is handled via a mirror-then-sync design: any pre-existing destination content is copied into a tmpfs/overlay stage dir first (a no-op for a fresh destination), the real tar runs in the stage, then the stage is `cp -a`'d back onto the real destination (safe lstat/symlink-preserving syscalls) and tar's real exit code is propagated. Mirroring first means GNU tar's own collision/overwrite-protection flags (`--keep-old-files`, etc.) see the same pre-existing files they'd see extracting in place — this was revised twice after adversarial review: an earlier "stage into an empty dir" design defeated `--keep-old-files`, and an earlier "only stage when the destination is empty" design never engaged for the realistic case (real jobs run `actions/checkout` first, so the destination is essentially always already populated by the time any other workflow step tar-extracts something). Every other invocation (archive creation, listing, extraction outside the mount, or any container without the flag) passes straight through to the real tar untouched — zero behavior change for installs that don't opt into `workspace_host_path`. Known cost: this mirrors the *entire* pre-existing destination tree on every guarded extraction, so it's O(destination size), not free — accepted given the alternative was a real, evidenced production bug. Known accepted gap: an archive member whose stored mode blocks even owner-read (e.g. mode 000) fails to sync from stage to the real destination, since `cp` can no longer re-read what tar already restricted — this is a distinct, narrow, two-phase-design limitation (not virtiofs-specific — true on any filesystem), separate from a *second*, already-broken-natively virtiofs limitation where mode-000 files fail even on direct, unwrapped extraction. Neither is fixed here (rare in real CI archives, unlike symlinks); see `docker/tar-workspace-wrapper.sh`'s header comment for the full detail.

**Regression coverage:** `tests/workspace_mount_symlink_extraction_test.sh` (Layer 2, real Docker — baseline overlay-fs extraction works; raw mount root is diagnostically still broken; tmpfs-shadowed `_actions`/`_temp`/`_tool` extraction and execution succeed; RED→GREEN proof that unguarded checkout-path extraction corrupts while the tar wrapper fixes it, verified on both a fresh and a realistic already-populated destination and on both the container and host side; `--keep-old-files` collision protection is preserved; mode-000 members are diagnosed as an out-of-scope, already-broken-natively limitation, not a regression) + `docker_backend::tests::workspace_mount_shadows_actions_temp_tool_with_tmpfs` and `docker_backend::tests::workspace_mount_sets_virtiofs_env_for_tar_wrapper` (Layer 1, unit — assert the `--tmpfs ...:exec` args and the `-e EZGHA_VIRTIOFS_WORKSPACE=1` flag are emitted exactly when `workspace_host_path` is configured, and absent when it's not). Run the integration test after any change to the workspace-mount code path or the wrapper script: rebuild the image first (`DOCKER_BUILDKIT=0 docker build -f Dockerfile.runner -t ezgha-runner:latest .`), then `DOCKER_HOST=... bash tests/workspace_mount_symlink_extraction_test.sh`.

**Why this took 1-2 days to catch (see `/harness` 2026-07-19):** pre-deploy validation for this feature was a synthetic single-file write test, not a real job — the bead's own acceptance criteria required real-job validation before shipping and it was skipped. There is also no job-success-rate monitor in this repo's health tooling (`doctor-runner` measures container *activity*, EXECUTING/IDLE/DOWN, never job *outcome*) — a fleet failing 75% of jobs it picks up reads as perfectly healthy. Any future change to `docker_backend.rs`'s container-start/mount path is a **production runtime change**: validate with a real job (or the integration test above) before/immediately after deploying, not unit tests alone.

## Custom runner image (IMPORTANT)
The config must use `ezgha-runner:latest` (built from `Dockerfile.runner`), NOT the bare `ghcr.io/actions/actions-runner:latest` image.
The bare upstream image lacks `gh` and `jq`, causing workflows to fail with exit code 127.

**`./install.sh` now builds this image automatically** (added 2026-07-16) whenever `Dockerfile.runner` is present and the docker daemon is reachable — this is the fix for a recurring outage class where VM recreation (disk pressure, `colima delete`, a fresh machine) silently drops the image and the daemon refuses to spawn runners with "could not measure daemon free disk … image missing?".

To rebuild manually after changes to `Dockerfile.runner`:
```bash
DOCKER_BUILDKIT=0 docker build -f Dockerfile.runner -t ezgha-runner:latest .
```
Use `DOCKER_BUILDKIT=0` (legacy builder), not the BuildKit default — BuildKit's build-context network path hit a reproducible `python3-venv has no installation candidate` apt failure on this colima/vz setup even with `--no-cache`, while the legacy builder and a plain `docker run ... apt-get install` both succeeded immediately (bead jleechan-bl0n, 2026-07-16). Root cause not fully isolated; `DOCKER_BUILDKIT=0` is the proven-reliable path and is what `install.sh` uses.

Then update `~/.config/ezgha/config.toml`:
```toml
[runner]
image = "ezgha-runner:latest"
```

## Reproducibility discipline — no orphaned one-off fixes
Every fix applied during an incident must land in a **git-tracked** file (`install.sh`, `Dockerfile.runner`, `config/*.toml.example`, this file, README, a `.claude/skills/*` doc, or at minimum a `br` bead with the exact remediation) before the session ends. A fix that exists only as local host state (a manually rebuilt Docker image, a hand-edited `~/Library/LaunchAgents/*.plist`, a one-off `docker build`/`sysctl`/`launchctl` invocation) is **not done** — if this machine were wiped and `./install.sh` re-run on a fresh Mac, every fix from every past incident must reappear automatically. When you fix something live on the host, ask "does `install.sh` (or the daemon/config) reproduce this on a fresh machine?" — if not, encode it there before moving on, not just in a memory file or a bead comment.

## After any commit (IMPORTANT — Gate 0)
Gate 0 checks that the installed binary's embedded SHA matches the current `HEAD` commit.
**Every commit — even docs-only — advances HEAD**, so you must always rebuild after committing:

> **WHO RUNS THE DEPLOY STEPS (2–5) — single-writer rule (MANDATORY).** Steps 2–5 (`cargo install`, `systemctl restart`, `verify-exit-criteria.sh`) mutate the LIVE production fleet and are the responsibility of the **single deploy-owner** for the current session ONLY. If you are a dispatched sub-agent, a `codex exec` job, a `/sidekick` worker, or any session that is NOT the designated deploy-owner: **`cargo test` + commit + push ONLY. Do NOT run `cargo install --path .`, do NOT run `systemctl --user restart ezgha.service`, do NOT run `./docs/verify-exit-criteria.sh` (it dispatches a live canary and can auto-start units).** Hand the deploy to the deploy-owner and stop. Rationale: uncoordinated service restarts stack respawn waves and can interrupt in-flight runner registrations and operator sessions. When you dispatch a `codex`/sub-agent that commits in this repo, its prompt MUST include "commit + push only; do NOT cargo install / restart / run verify-exit-criteria.sh."

1. `cargo test` — verify all tests pass
2. `cargo install --path .` — install updated binary (embeds new HEAD SHA)
3. **Before `systemctl --user restart ezgha.service`, check `uptime` (1-min load average) and `docker ps --filter label=ezgha=managed | wc -l` (running container count). If load_1min > 12 or live containers are below 75% of configured capacity (fewer than 15 on the default 20-runner Linux host; use fewer than 11 when explicitly running rollback-14, or fewer than 8 on rollback-10), DO NOT restart — wait for reconciliation and recheck.** Mass cold respawns increase host pressure and interrupt in-flight runner registrations. This check protects the fleet regardless of which agent/session is running Gate 0 — see bead `ez-gh-actions-po2` for the durable load-aware respawn pacing fix.
   **EXCEPTION**: if containers are actively draining (dropping over consecutive checks) due to a stuck/slow serve loop — confirmed by low load plus a shrinking container count with a live in-flight `gh api` process as the daemon's child — restart IS the remediation, not the risk. Low load + a draining fleet means the loop is stuck, not busy; waiting only makes it worse. This exact scenario happened 2026-07-07 (an expensive per-tick GitHub API fetch starved `ensure_count`, draining the fleet to 0 containers) — see `queue_monitor::SERVE_LOOP_TIME_BUDGET` for the structural fix that should prevent recurrence.
4. `systemctl --user restart ezgha.service` — restart daemon
5. `./docs/verify-exit-criteria.sh` — verify all gates pass

If daemon logs show `could not measure daemon free disk … image missing?` after the restart, the VM lost `ezgha-runner:latest` (common after disk-pressure recreation) — run `./install.sh` (which rebuilds it automatically) or the manual command in "Custom runner image" above, rather than restart-looping.

## Commit conventions
Every commit subject must be prefixed with the runtime that produced it:
- `gemini/<model-id>: <subject>`
- `claude/<model-id>: <subject>`
- `human: <subject>`

**Enforced server-side for same-repository squash candidates** by the
self-hosted CI workflow, which validates each PR title (GitHub's default squash
subject) with `.githooks/commit-msg` from the trusted base SHA and reruns when
the title is edited. Fork heads are skipped before a self-hosted runner is
allocated. A merge-dialog title override remains outside this repository
workflow; preventing that requires a GitHub repository ruleset. **Enforced
locally for ordinary commits** by the same hook (bead `ez-gh-actions-jcie`).
Recognized prefixes: `claude/`, `claudem/`, `claudew/`, `gemini/`, `codex/`,
`cursor/`, `ao/`, `human` (each terminated by `:`). Opt in per-developer
with `git config core.hooksPath .githooks` — see `.githooks/README.md`.
Merge commits and `git commit --no-verify` bypass the gate.

## Common self-healing recipes

### Gate 3 FAIL: container count low
1. Check for stale containers: `docker ps --filter label=ezgha=managed --format '{{.Names}} {{.Image}}'`
2. Check journal: `journalctl --user -n 40 -u ezgha.service`
3. If you see `docker run failed: Conflict. The container name ... is already in use`:
   - Run: `docker rm -f <container-name>` to unblock the slot
   - Daemon has built-in failsafe since commit `c6defc7` that runs `docker rm -f` before each `docker run`
4. If slot file is wedged: `rm ~/.config/ezgha/slot_assignments.toml` then `systemctl --user restart ezgha.service`

### Service down
```bash
systemctl --user restart ezgha.service
systemctl --user status ezgha.service
```

### Colima VM down
```bash
limactl start colima
```

### `colima start` fails: `failed to run attach disk "colima", in use by instance "colima"`

Symptom: the daemon exits with `no usable backend found — docker daemon is not
reachable`, the launchd job disappears from `launchctl list`, and every later
`colima start` fails within a second with the attach-disk fatal above. 0/N mac
runners, indefinitely.

Root cause: a `colima start`/`restart` killed mid-flight leaves the Lima data
disk locked (`~/.colima/_lima/_disks/colima/in_use_by`), so no subsequent start
can attach it. The daemon's own restart path can create this state: its
`BACKEND_RESTART_COMMAND_TIMEOUT` (45s) is shorter than a cold vz boot plus
provisioning, so on a host that has just rebooted the daemon kills its own
recovery attempt and wedges the VM. Observed 2026-10-29: reboot at 16:12, disk
locked at 18:42, fleet at 0/4 mac runners until 18:53.

OPERATOR-ONLY remediation (verify the instance really is stopped first with
`LIMA_HOME=~/.colima/_lima limactl list`):
```bash
LIMA_HOME=~/.colima/_lima limactl disk unlock colima
colima start            # ~30s when the lock is the only problem
ezgha install-service    # relaunch the daemon once docker is reachable
```
Never kill a `colima start` on a short timeout — that is what creates this
lock. Tracked by bead jleechan-9p0g.

### Runner dashboard publisher recovery
- **launchd load failure:** a failed first install removes its candidate; a
  failed upgrade restores and attempts to reload the prior plist. Fix the
  printed cause, confirm the prior job is still loaded, then retry only the
  dashboard agent with
  `bash launchd/install-launchagents.sh install org.jleechanorg.ezgha-runner-dashboard`;
  do not hand-load a candidate or partial plist.
- **Stale dashboard output:** inspect
  `~/.local/state/ezgha/runner-dashboard.stderr.log` and fix the reported probe,
  auth, or push failure. For transient failures, launchd retries automatically
  every 600 seconds; run `~/.local/libexec/ezgha/publish_runner_dashboard.sh --publish`
  only when an immediate post-fix check is needed.
- **Ownership-marker refusal:** keep the failure closed. Manually inspect who
  owns the configured Pages branch and resolve that ownership before retrying;
  never auto-create the marker, delete existing content, or overwrite the branch.

### Runner cache warmer & read-only mirror/wheelhouse recovery
- **Low-disk `reap_only` pruning:** when free disk drops below
  `limits.min_free_disk_gb + 5` GiB, the scheduled warmer
  (`ezgha-cache-warm.timer` on Linux / `org.jleechanorg.ezgha-cache-warm` on
  macOS) automatically skips new git mirror clones and wheel downloads while
  still reaping expired retired mirror generations and pruning older `.whl`
  versions (`EZGHA_WHEELHOUSE_KEEP_VERSIONS`, default `2`).
- **Stale or missing warmer unit:** inspect
  `~/.local/state/ezgha/cache-warm-launchd.log` (macOS) or the
  `ezgha-cache-warm.service` user journal (Linux). Reinstall or trigger a warm
  pass via `OPERATOR-ONLY: bash launchd/install-launchagents.sh install org.jleechanorg.ezgha-cache-warm`
  on macOS or `OPERATOR-ONLY: systemctl --user restart ezgha-cache-warm.service`
  on Linux. Containers mount both caches read-only and fail open when absent.

## /doctor-ezactions command
Running `/doctor-ezactions` in this repo executes (bare `/doctor` is a deprecated alias):
1. `./doctor-runner` — fleet health check (4-state per-slot activity truth)
2. `./docs/verify-exit-criteria.sh` — ironclad exit criteria (Gates 0–10)

Self-heal any failures found before reporting.

## /harness command  
Running `/harness` executes `./docs/verify-exit-criteria.sh` and audits all gates. Report PASS/FAIL per gate.

## Scratch, not /tmp, for agent workspaces (bead jleechan-0yic)

`/tmp` lives on the root filesystem that the runner-admission floor protects: on 2026-10-28
jeff-ubuntu hit 14 GB free with 232 GB of stale agent scratch in `/tmp`, ezgha correctly paused
admission, and the fleet drained from 20 to 3 runners. The Disk Magician scratch volume is a
separate, sparse, quota-bounded filesystem (`/Volumes/diskm-scratch` on macOS, `~/Scratch` on
Linux), so scratch growth there cannot starve CI admission.

Every workspace- and capture-scale producer must therefore resolve its root:

```bash
SCRATCH="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh <purpose> 2>/dev/null || echo /tmp)"
```

`scripts/install_scratch_migration.py` is the git-tracked encoding of that migration: it applies
the pattern set to a host's `~/.claude`, idempotently, and refuses to guess when a file has drifted
or a pattern is ambiguous.

```bash
./scripts/install_scratch_migration.py                    # dry-run, prints the plan
./scripts/install_scratch_migration.py --apply            # migrate this host
./scripts/install_scratch_migration.py --root <dir> --json report.json
```

KB-scale temp files (export exclusion lists, status markers, watchdog logs) intentionally stay in
`/tmp`; only workspace and capture producers are migrated. Never relocate an existing live
workspace — moving a checkout invalidates absolute git worktree/config paths.

**Linux caveat (bead jleechan-tshq).** The Linux scratch volume is mounted with `fuse2fs`, which
rejects `open(O_CREAT|O_EXCL|O_RDWR, 0444)` — exactly how git creates a loose object — so
`git clone`/`add`/`commit` fail there with `EACCES` while plain writes succeed. macOS is unaffected
(`/Volumes/diskm-scratch` is APFS). Everything git-based therefore probes the root before trusting
it and falls back to `${TMPDIR:-/tmp}` until the mount defect is fixed.
## Host-health Slack notifications and SMS scope (bead jleechan-v8ms)
`scripts/ezgha-host-health-alert.sh` runs every 2 minutes on jeff-ubuntu (crontab, installed by
`scripts/install-host-health-alert-cron.sh`) and via the launchd agent
`org.jleechanorg.ezgha-host-health-alert` on the Mac. It writes to the Cloud Logging log
`ezgha-runner-alerts`, which feeds two cause-scoped Cloud Monitoring policies routed to Slack only:

- `cause=fleet` → `[CRITICAL] ezgha: GitHub Actions Runners Down Alert` to Slack (service down, Docker
  unreachable, or 0 local runner containers). This is a per-host capacity signal, not proof of a
  global product P0; peer-only problems are separate warnings.
- `cause=disk` → logged at WARNING while the breach is inside the self-heal window
  (`HEALTH_ALERT_DISK_PAGE_AFTER_MIN`, 15 min) because ezgha's disk admission pause plus the
  scratch reclaimer normally clear it; escalates to ERROR and pages
  `[CRITICAL] ezgha: host disk below safety floor` to Slack only when the breach persists past that
  window or free space drops under `HEALTH_ALERT_DISK_EMERGENCY_GB` (15 GB).

Consequence of the 2026-10-28 incident this classifies: a disk verdict used to be written as
`status=DOWN`/`severity=ERROR`, so the single "Runners Down" policy matched it and paged the
operator every ~10 minutes for three hours while 16-19/20 runners were online and executing jobs.
The 30-minute throttle never engaged because the state file lived in `/tmp` and the scratch
reclaimer archived it; state now lives under `$HOME/.local/state/ezgha/`.

The offline-runner-with-queued-work policy is also Slack-only; its legacy JSON filename is retained
for installer compatibility. SMS remains restricted to the separately governed stable P0 route and
the TestFlight monitor's three-consecutive-automatic-push-failure exception. Do not add an SMS
channel to fleet, disk, queue, TEST, or API-blind operational diagnostics.

Apply the policies (idempotent) with `OPERATOR-ONLY: ./scripts/ezgha-host-health-alert.sh --ensure-policies`.
Audit a verdict without touching GCP using `--dry-run` plus the `HEALTH_ALERT_*` env overrides
documented in the script header.

### GitHub Actions cost & hosted-macOS alert (`org.jleechanorg.ezgha-gh-actions-cost-alert`)
`scripts/gh-actions-cost-alert.sh` runs hourly (`StartInterval=3600`) via
`launchd/org.jleechanorg.ezgha-gh-actions-cost-alert.plist.template`, querying
`/organizations/${ALERT_ORG}/settings/billing/usage?year=YYYY&month=MM` (plus `year=YEST_YEAR&month=YEST_MONTH&day=YEST_DAY` on day-1 month rollover so `YESTERDAY_UTC` is never dropped; if the rollover lookup fails, today/MTD current-month data is still evaluated in `billing_api_partial` mode with `api_failures` incremented) across both yesterday UTC and
today UTC for `product=="actions"`. It evaluates gross spend (`DAILY_GROSS_WARN_USD=25`,
`MTD_GROSS_WARN_USD=250`), hosted macOS minutes (`DAILY_MACOS_MIN_WARN=60`), and net billed spend
(`DAILY_NET_WARN_USD=10`, `MTD_NET_WARN_USD=40`), routing `jsonPayload.source="gh-actions-cost-alert"`
to the dedicated Slack-only policy `[CRITICAL] GitHub Actions cost or hosted macOS spike` (never
`cause=fleet`). Primary billing calls use `GH_BILLING_TOKEN` or user `gh` keyring auth (never passing
`~/.config/ezgha/gh_token` to `/settings/billing/usage`, because GitHub App `4245332` lacks
`organization_administration=read`). All `gh`/`gcloud` calls are bounded by wall-clock timeouts (`GH_CALL_TIMEOUT_SEC=30`, `GCLOUD_CALL_TIMEOUT_SEC=30`), and `STATE_FILE` updates are serialized via kernel `fcntl.flock` on `${STATE_FILE}.flock` (auto-released on crash/`SIGKILL`, emitting `WARNING BLIND` on `LOCK_TIMEOUT` before exiting `4`). If `STATE_FILE` is empty (`0`-byte), multi-object, corrupt JSON, non-object JSON, or contains non-integer/fractional/negative/boolean `.sent` or counter values, the script resets it to `{"sent":{},"last_sent":0,"api_failures":0,"last_blind":0}`, schedules `BLIND` (`corrupt_state_file_reset`), and continues monitoring—reporting `STATE_FILE was corrupt and reset` separately from consecutive billing failures (`; ALSO STATE_FILE was corrupt and reset` when combined with a simultaneous `ERROR` breach notification, or a single `WARNING BLIND` if no breach fires). When personal `core.remaining < 50` or `/settings/billing/usage`
fails/403, a bounded gross-only App-token fallback (`APP_TOKEN_FILE=~/.config/ezgha/gh_token`,
`MAX_APP_API_CALLS=60`) prioritizes org repos by `pushed` without excluding stale-push repos, includes `in_progress` and recently updated runs (`>= YESTERDAY_UTC`), paginates `/jobs?filter=all&per_page=100` within budget, splits/clips each job's `[started_at, completed_at]` interval across `[YESTERDAY_UTC, TODAY_UTC]` UTC midnight boundaries (capping apportioned day minutes per job at `ceil(total_job_sec / 60)`), and prices standard `macos-latest`/`macos-13..15*`/`macos-26*` (`$0.062/min`), `ubuntu-latest`/`ubuntu-20.04..24.04` (`$0.006/min`), and `windows-latest`/`windows-2019..2025` (`$0.010/min`) runners at baseline rates while larger/custom hosted labels are marked unpriced (`partial`) and any non-self-hosted `macos-*` label still counts toward `DAILY_MACOS_MIN_WARN`. Daily `NET_SPEND_BREACH` ranks `top_net_repo` by `.netAmount` separately from gross `top_repo`. It collects all due breaches per run into one combined `ERROR` notification (`breach_keys`, using `MULTI_BREACH` when multiple breach statuses fire together and folding any simultaneous `BLIND` condition into that single alert so the 300s policy rate limit cannot drop simultaneous breaches or `BLIND`) and marks `.sent` keys atomically only after `gcloud logging write` succeeds. Only a full authoritative `/organizations/.../settings/billing/usage`
read + parse resets `api_failures=0`; any skip, partial rollover, or failure persists `api_failures` before alert writes and emits `WARNING BLIND`
at `MAX_API_FAILURES=3` even if partial App fallback ran.
- **Recovery / setup (OPERATOR-ONLY):**
  - Provision `~/.config/ezgha/gh_token` beforehand via the GitHub App token refresher (see `docs/gh-app-token.md`) so the App-token fallback is available if primary billing auth returns 403; the targeted `install org.jleechanorg.ezgha-gh-actions-cost-alert` step does not create `~/.config/ezgha/gh_token`.
  - `OPERATOR-ONLY: ./scripts/gh-actions-cost-alert.sh --ensure-gcp-policy` (creates/updates the dedicated Slack policy)
  - `OPERATOR-ONLY: ./launchd/install-launchagents.sh install org.jleechanorg.ezgha-gh-actions-cost-alert`
  - Inspect `/tmp/ezgha-gh-actions-cost-alert.log` and `~/.local/state/ezgha/gh-actions-cost-alert.json` if `BLIND` fires (check `gh auth status` and `gh api rate_limit`).

### Native macOS CI runner (`mac-native-ci-1`, label `self-hosted-native-macos`)
`scripts/setup-native-macos-runner.sh` idempotently provisions an org- or repo-scoped native Darwin ARM64
runner (`mac-native-ci-1`) at `/Users/jleechan/actions-runner-macos-ci` with work directory on
Scratch (`native-macos-ci-work`, failing closed if Scratch is unavailable or resolves under `/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`, or `$TMPDIR`), `--no-default-labels --labels self-hosted-native-macos` (requiring `self-hosted-native-macos`, forbidding
bare `self-hosted` and `worldai-testflight-native-mac`, and canonically refusing `$HOME`, `/`, and filesystem-identical/case-alias/ancestor/descendant paths of `~/actions-runner` and `~/actions-runner-smtp-egress` for both `--runner-dir` and `--work-dir`, failing closed on any reservation-check error), optional `--runner-group GROUP` (mutually exclusive with `--repo`, exiting `2`; conflicting action flags among `--verify`/`--uninstall`/`--reconfigure`/`--dry-run` also exit `2`, with `--offline` valid only with `--verify`), and LaunchAgent
`org.jleechanorg.ezgha-native-macos-runner.plist` (with `<key>SessionCreate</key><true/>`). Mutating lifecycle actions serialize via kernel `fcntl.flock` on `~/.local/state/ezgha/setup-native-macos-runner.<label>.flock` (`SETUP_LOCK_TIMEOUT_SEC=30`). This
uses separate runner/Scratch `_work` paths and `--no-default-labels --labels self-hosted-native-macos`
(`SessionCreate=true`) from `worldai-testflight-native-mac`'s `SessionCreate=false` GUI signing session at
`/Users/jleechan/actions-runner` and from Linux `self-hosted` jobs, while sharing the operator's
macOS UID/`$HOME` (not a user-account sandbox). **Security boundary:** `pull_request` YAML `if:` guards
execute from the fork's head commit and are NOT a security boundary against modified fork workflows, and GitHub's `fork-pr-contributor-approval` setting does NOT gate `pull_request_target` workflows; therefore `allows_public_repositories=false` on the target runner group (or `private=true` with `--repo`) is required and enforced fail-closed by `setup-native-macos-runner.sh` (exit `5` before minting a registration token or completing setup/verify whenever `allows_public_repositories != false` or `--repo` is non-private, unless `--allow-public-fork-exposure` is explicitly passed after operator workflow review). Live runner state (`verify_live_runner_state`) requires both `.runner` and `.credentials`, binds positive numeric `.runner` `agentId` (no name-only fallback), exact `RUNNER_NAME`, exact `RUNNER_LABELS`, org runner-group membership (`orgs/${ORG}/actions/runner-groups/${group_id}/runners`), and (in `--verify` without `--offline`) live `status == "online"`. Normal setup reconfigures only on missing/drifted local metadata, `agentId`/label/group drift, or `--reconfigure`, and when an already-configured runner is unchanged it checks live `status == "online"` via `verify_runner_online` and **fails closed without reconfiguring** if `offline` (requiring `--reconfigure`); after `config.sh`, `post_config` retries full `verify_live_runner_state` and post-launch `verify_runner_online` retries up to `POST_CONFIG_VERIFY_ATTEMPTS=15` (`POST_CONFIG_VERIFY_SLEEP_SEC=2`, with `gh api` calls bounded by `GH_CALL_TIMEOUT_SEC=30`) and requires an exact positive live match before discarding `.backup-pre-reconfigure.<pid>` (and any prior `.backup-pre-reconfigure.*` dirs) or keeping the LaunchAgent loaded (exiting `4` fail-closed otherwise). Before staging binaries or calling `stop_launchagent` (and again immediately after minting the registration token before removing credentials or invoking `./config.sh`), setup queries live runners for `.name == RUNNER_NAME` when configuration is needed: it omits `--replace` when absent, derives `prev_agent_id` from `${RUNNER_DIR}/.runner` (or from `.backup-pre-reconfigure.*/.runner` across a failed `--reconfigure` retry when all preserved backups share one unique positive `agentId`), passes `--replace` only when `prev_agent_id` matches the live runner `.id` (or `--force-replace-name`), and exits `6` fail-closed on a colliding foreign runner ID without stopping the incumbent LaunchAgent. Registration passes the token via `ACTIONS_RUNNER_INPUT_TOKEN` in the child environment (never `--token` in process argv). Binary provisioning and `--verify` enforce `os.path.realpath` containment inside `RUNNER_DIR` across `Runner.Listener`/`config.sh`/`run.sh`/`runsvc.sh`/`run-helper.sh.template`/`env.sh`/`externals*`, plist `ProgramArguments`, and all nested symlinks under `bin*`/`externals*`, rewriting both top-level and nested `EXISTING_RUNNER_DIR`-scoped symlinks to relative symlinks inside `STAGE_DIR`/`RUNNER_DIR` (copying external targets) so cloned binaries never share `~/actions-runner`, sets `chmod 600` on `.credentials*`, and preserves an existing `${RUNNER_DIR}/.env` rather than truncating it; reconfiguration confirms launchd
unload (`rc=113` or service-not-found, failing closed on lookup/permission errors) before removing
credentials, preserves `.backup-pre-reconfigure.<pid>` on failure, and exits non-zero (`4`) fail-closed
without restoring old credentials or restarting the service; no-change reruns leave an already-loaded
LaunchAgent untouched; and `--uninstall` executes before Scratch resolution while confirming the
GUI-domain job is unloaded before removing the plist.
- **Recovery / setup (OPERATOR-ONLY):**
  - `OPERATOR-ONLY: ./scripts/setup-native-macos-runner.sh` (install/re-register + load LaunchAgent; pass `--reconfigure` to force unload and re-registration, or `--runner-group GROUP` to target a restricted runner group)
  - `OPERATOR-ONLY: ./scripts/setup-native-macos-runner.sh --verify` (check binaries including `run-helper.sh.template`, `env.sh`, and `externals*`, `WORK_DIR`, `.runner` numeric `agentId`, `.credentials`, `.ezgha-labels`, `.ezgha-group`, server-side private-repo/private-runner-group fork-protection policy, and `GH_BIN` live GitHub runner `online` status/group/labels unless `--offline`, `SessionCreate=true`, plist `WorkingDirectory`/`ProgramArguments`, and launchd state)

## Safety & Monitoring Principles
- **Canonical Prohibition on Physical-Host Reboot Primitives & Watchdog-Driven Restarts**:
  - No script, daemon, test, or automation in this repo may invoke or instruct physical-host reboot, shutdown, or forced panic primitives (`reboot`, `shutdown`, `poweroff`, `halt`, `init 0/6`, `/proc/sysrq-trigger`, `kernel.panic=10`, etc.).
  - No external watchdog timer or external watchdog daemon may be configured or deployed to force host reboots or service restart loops.
  - Recovery authority belongs strictly to the child layer (ordinary container replenishment, process `Restart=on-failure`, graceful shutdown handling, and manual operator recovery), never host reboot authority.
- **Self-Outage Prevention Principle**: A safety, health, or monitoring mechanism must not be able to cause the outage or failure it is designed to guard against.
- **Blast-Radius & Interaction Review**: Any change to a threshold, health-check, watchdog configuration, restart policy, resource limit, or monitor cadence must be accompanied by an evaluation of its blast radius and interaction with other components. The change description must state the normal peak of the bounded metric and verify a safe remaining margin.
- **VM/backend lifecycle is deploy-owner-only**: `colima stop/delete`, `limactl stop/delete/factory-reset`, `docker system/image prune`, and `docker context rm/use` are covered by the same single-writer rule as deploy steps 2–5. Two 2026-07-14 incidents: a read-only verifier subagent ran `colima stop --force` and killed the prod VM mid-recovery (bead jleechan-rvv1); a prune-class action deleted `ezgha-runner:latest` while the fleet was down (in-use images survive a prune, the idle runner image does not — bead jleechan-kobt). A short-timeout `colima start` killed mid-flight also CREATES the "vz driver is running but host agent is not" stale state.
- **Never quote executable remediation commands in agent-consumed text**: Log messages, error strings, subagent prompts, and verifier claims must describe remediation ("force-stop then restart the VM"), not embed the runnable command — agents execute quoted commands with collateral damage. When a runnable command is genuinely needed in docs, prefix it `OPERATOR-ONLY:`. Applies to daemon log strings too (a `docker system prune` suggestion in an ensure_count error is an image-deletion instruction to any agent chasing disk pressure).

## Safety rails
- Never run `git add -A` — stage only files you changed
- Always push after finishing any unit of work
- Never modify `~/.config/ezgha/config.toml` without also restarting the service

## Standards & reviews
- **Repo-local `/code-standards`** lives at `.claude/commands/code-standards.md` and layers ten repo-specific gates (fleet capacity 24/24, single-writer, layered-design, self-outage prevention, blast-radius, self-healing recipes, honest gates, automation-callers, no-silent-underprovisioning, test isolation) on top of the user-scope `~/.claude/commands/code-standards.md` (ZFC + ponytail). New code must pass repo-local /code-standards before merge.
- **Blast radius required** for any change to a threshold, health-check, watchdog configuration, restart policy, resource limit, or monitor cadence: PR description must state the normal peak of the bounded metric and verify a safe remaining margin (per "Safety & Monitoring Principles" above). Cold reviewers REJECT otherwise — proven pattern (PR #53 drain deadline was checked between slots but not inside in-flight gh DELETE; caught 2026-07-10).
