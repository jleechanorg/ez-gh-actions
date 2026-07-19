# ez-gh-actions — Claude Code Agent Instructions

## Project overview
`ezgha` is a Rust CLI that manages ephemeral self-hosted GitHub Actions runners using Docker JIT registration. One binary; installs as a user systemd service.

## Fleet capacity standard — no excuses, prove per-slot execution
The fleet MUST run its full configured capacity: **16 Linux** (ez-runner-c-1..16 on jeff-ubuntu) + **6 Mac** (ez-mac-runner-b-1..6) = **22 runners**, and **EVERY one must be proven EXECUTING a real GitHub Actions job** — a `Runner.Worker` process, verified via `docker top <container>`. Anything less than 22/22 executing is **BROKEN**: root-cause and fix it. Do NOT explain a shortfall away as "churn", "normal ephemeral cycling", "counting artifacts", or "the API is just lying". Assume the capacity SHOULD be full and PROVE it per-slot.
- **The GitHub API CANNOT be trusted for fleet state.** Under the secondary rate limit it returns TRUNCATED/partial data — the same fleet was reported as 7 / 11 / 16 / 19 / 22 across calls minutes apart. Use LOCAL `docker top` / `docker ps` for `Runner.Worker`-per-slot as the source of truth, never API counts.
- **`./doctor-runner` is authoritative** (`./doctor.sh` is LEGACY/BROKEN on docker 27+ — see bead ez-gh-actions-91r — kept only as a back-reference). It enforces per-slot activity truth with a 4-state model: EXECUTING (job+repo+run URL+elapsed evidence) / IDLE-OK (nothing queued, or queued for less than `IDLE_STARVED_THRESHOLD_MIN`=5min — healthy) / IDLE-STARVED (queued >=5min — defect) / DOWN (no container — defect). A busy fleet must never measure as dead — the motivating defect this replaced was a tail-grep on "Listening for Jobs" that read a fully-busy fleet as 0/22 healthy. Run it; fix any DOWN or IDLE-STARVED slot before declaring the fleet healthy.
- Known failure mode: a rate-limited monitor in the single-threaded serve loop can starve `ensure_count` so runners aren't respawned (fleet silently drops below 16). See beads ez-gh-actions-yrt (backoff/circuit-breaker), zai (dedup), nuk (GitHub App).

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

**Fix:** the daemon tmpfs-shadows the three fixed runner-internal cache dirs (`_actions`, `_temp`, `_tool`) inside the workspace mount, so the runner's own action/tool-cache extraction never touches virtiofs, while checkouts/build scratch (which live directly under `_work/<owner>/<repo>`, the actual disk-churn win) are unaffected.

**Regression coverage:** `tests/workspace_mount_symlink_extraction_test.sh` (Layer 2, real Docker — reproduces the bug against a synthetic archive with the same symlink shape, then proves the tmpfs shadow fixes it) + `docker_backend::tests::workspace_mount_shadows_actions_temp_tool_with_tmpfs` (Layer 1, unit — asserts the `--tmpfs` args are emitted). Run the integration test after any change to the workspace-mount code path: `DOCKER_HOST=... bash tests/workspace_mount_symlink_extraction_test.sh`.

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

> **WHO RUNS THE DEPLOY STEPS (2–5) — single-writer rule (MANDATORY).** Steps 2–5 (`cargo install`, `systemctl restart`, `verify-exit-criteria.sh`) mutate the LIVE production fleet and are the responsibility of the **single deploy-owner** for the current session ONLY. If you are a dispatched sub-agent, a `codex exec` job, a `/sidekick` worker, or any session that is NOT the designated deploy-owner: **`cargo test` + commit + push ONLY. Do NOT run `cargo install --path .`, do NOT run `systemctl --user restart ezgha.service`, do NOT run `./docs/verify-exit-criteria.sh` (it dispatches a live canary and can auto-start units).** Hand the deploy to the deploy-owner and stop. Rationale: uncoordinated restarts stack respawn waves and have caused two host-watchdog near-misses and two self-inflicted double-restarts (2026-07-07/08); a `codex` job that ran these steps literally as "Gate 0 self-verification" restarted the prod daemon out from under the single-writer owner. When you dispatch a `codex`/sub-agent that commits in this repo, its prompt MUST include "commit + push only; do NOT cargo install / restart / run verify-exit-criteria.sh."

1. `cargo test` — verify all tests pass
2. `cargo install --path .` — install updated binary (embeds new HEAD SHA)
3. **Before `systemctl --user restart ezgha.service`, check `uptime` (1-min load average) and `docker ps --filter label=ezgha=managed | wc -l` (running container count). If load_1min > 12 or containers < 12, DO NOT restart — wait for reconciliation and recheck.** Mass cold respawns of many runners at once have tripped the host watchdog (`/etc/watchdog.conf` `max-load-1 = 24` on this 32-thread box) and rebooted the box twice on 2026-07-07, once killing an in-progress agent session outright. This check protects the fleet regardless of which agent/session is running Gate 0 — see bead `ez-gh-actions-po2` for the durable fix (load-aware respawn pacing inside the daemon itself) that will make this manual check unnecessary once it lands.
   **EXCEPTION**: if containers are actively draining (dropping over consecutive checks) due to a stuck/slow serve loop — confirmed by low load plus a shrinking container count with a live in-flight `gh api` process as the daemon's child — restart IS the remediation, not the risk. Low load + a draining fleet means the loop is stuck, not busy; waiting only makes it worse. This exact scenario happened 2026-07-07 (an expensive per-tick GitHub API fetch starved `ensure_count`, draining the fleet to 0 containers) — see `queue_monitor::SERVE_LOOP_TIME_BUDGET` for the structural fix that should prevent recurrence.
4. `systemctl --user restart ezgha.service` — restart daemon
5. `./docs/verify-exit-criteria.sh` — verify all gates pass

If daemon logs show `could not measure daemon free disk … image missing?` after the restart, the VM lost `ezgha-runner:latest` (common after disk-pressure recreation) — run `./install.sh` (which rebuilds it automatically) or the manual command in "Custom runner image" above, rather than restart-looping.

## Commit conventions
Every commit subject must be prefixed with the runtime that produced it:
- `gemini/<model-id>: <subject>`
- `claude/<model-id>: <subject>`
- `human: <subject>`

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

## /doctor-ezactions command
Running `/doctor-ezactions` in this repo executes (bare `/doctor` is a deprecated alias):
1. `./doctor-runner` — fleet health check (4-state per-slot activity truth)
2. `./docs/verify-exit-criteria.sh` — ironclad exit criteria (Gates 0–10)

Self-heal any failures found before reporting.

## /harness command  
Running `/harness` executes `./docs/verify-exit-criteria.sh` and audits all gates. Report PASS/FAIL per gate.

## Safety & Monitoring Principles
- **Self-Outage Prevention Principle**: A safety, health, or monitoring mechanism must not be able to cause the outage or failure it is designed to guard against.
- **Blast-Radius & Interaction Review**: Any change to a threshold, health-check, watchdog configuration, restart policy, resource limit, or monitor cadence must be accompanied by an evaluation of its blast radius and interaction with other components. The change description must state the normal peak of the bounded metric and verify a safe remaining margin.
- **Watchdogs must act, not advise**: A monitor that detects a failure and only logs the remediation command ("manual intervention needed — try X") is a broken guardrail. Detection scripts must either execute their known remediation (with backoff, max-attempts, and a hysteresis marker) or escalate loudly to a surface a human actually watches. The deployed watchdog logging `try 'colima stop --force && colima start'` every 5 minutes for 3+ hours (2026-07-14) while the fleet sat dead is the canonical violation. Bead: jleechan-yib3.
- **VM/backend lifecycle is deploy-owner-only**: `colima stop/delete`, `limactl stop/delete/factory-reset`, `docker system/image prune`, and `docker context rm/use` are covered by the same single-writer rule as deploy steps 2–5. Enforced for sessions in this repo by `.claude/hooks/vm-lifecycle-guard.sh` (bypass: `EZGHA_DEPLOY_OWNER=1`). Two 2026-07-14 incidents: a read-only verifier subagent ran `colima stop --force` and killed the prod VM mid-recovery (bead jleechan-rvv1); a prune-class action deleted `ezgha-runner:latest` while the fleet was down (in-use images survive a prune, the idle runner image does not — bead jleechan-kobt). A short-timeout `colima start` killed mid-flight also CREATES the "vz driver is running but host agent is not" stale state.
- **Never quote executable remediation commands in agent-consumed text**: Log messages, error strings, subagent prompts, and verifier claims must describe remediation ("force-stop then restart the VM"), not embed the runnable command — agents execute quoted commands with collateral damage. When a runnable command is genuinely needed in docs, prefix it `OPERATOR-ONLY:`. Applies to daemon log strings too (a `docker system prune` suggestion in an ensure_count error is an image-deletion instruction to any agent chasing disk pressure).

## Safety rails
- Never run `git add -A` — stage only files you changed
- Always push after finishing any unit of work
- Never modify `~/.config/ezgha/config.toml` without also restarting the service

## Standards & reviews
- **Repo-local `/code-standards`** lives at `.claude/commands/code-standards.md` and layers ten repo-specific gates (fleet capacity 22/22, single-writer, layered-design, self-outage prevention, blast-radius, self-healing recipes, honest gates, automation-callers, no-silent-underprovisioning, test isolation) on top of the user-scope `~/.claude/commands/code-standards.md` (ZFC + ponytail). New code must pass repo-local /code-standards before merge.
- **Blast radius required** for any change to a threshold, health-check, watchdog configuration, restart policy, resource limit, or monitor cadence: PR description must state the normal peak of the bounded metric and verify a safe remaining margin (per "Safety & Monitoring Principles" above). Cold reviewers REJECT otherwise — proven pattern (PR #53 drain deadline was checked between slots but not inside in-flight gh DELETE; caught 2026-07-10).
