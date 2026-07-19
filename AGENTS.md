# ez-gh-actions — Claude Code Agent Instructions

## Project overview
`ezgha` is a Rust CLI that manages ephemeral self-hosted GitHub Actions runners using Docker JIT registration. One binary; installs as a user systemd service.

## Fleet capacity standard — no excuses, prove per-slot execution
The fleet MUST run its full configured capacity: **10 Linux** (ez-runner-c-1..10 on jeff-ubuntu) + **6 Mac** (ez-mac-runner-b-1..6) = **16 runners**, and **EVERY one must be proven EXECUTING a real GitHub Actions job** — a `Runner.Worker` process, verified via `docker top <container>`. Anything less than 16/16 executing is **BROKEN**: root-cause and fix it. Do NOT explain a shortfall away as "churn", "normal ephemeral cycling", "counting artifacts", or "the API is just lying". Assume the capacity SHOULD be full and PROVE it per-slot.
- **The GitHub API CANNOT be trusted for fleet state.** Under the secondary rate limit it returned TRUNCATED/partial data — during the prior 22-runner contract, the same fleet was reported as 7 / 11 / 16 / 19 / 22 across calls minutes apart. Use LOCAL `docker top` / `docker ps` for `Runner.Worker`-per-slot as the source of truth, never API counts.
- **`./doctor-runner` is authoritative** (`./doctor.sh` is a legacy back-reference, broken on docker 27+). Run it; fix any DOWN (no container) or IDLE-STARVED (queued work waiting at least 5 minutes with no `Runner.Worker`) slot before declaring the fleet healthy.
- Known failure mode: a rate-limited monitor in the single-threaded serve loop can starve `ensure_count` so runners aren't respawned (fleet silently drops below 10). See beads ez-gh-actions-yrt (backoff/circuit-breaker), zai (dedup), nuk (GitHub App).

## Key files
- `src/docker_backend.rs` — core runner lifecycle (slot allocation, container management)
- `src/github.rs` — GitHub API calls (JIT config, runner registration, conflict resolution)
- `src/main.rs` — CLI entry point
- `~/.config/ezgha/config.toml` — runtime config (do NOT commit this)
- `doctor-runner` — authoritative fleet health check script (`doctor.sh` is legacy)
- `docs/verify-exit-criteria.sh` — ironclad exit criteria checker (Gates 0–10)
- `Dockerfile.runner` — custom runner image with `gh` + `jq` pre-installed
- `.claude/skills/ezgha-doctor/SKILL.md` — diagnostic + self-healing recipes
- `.claude/commands/doctor.md` — `/doctor` slash command

## Custom runner image (IMPORTANT)
The config must use `ezgha-runner:latest` (built from `Dockerfile.runner`), NOT the bare `ghcr.io/actions/actions-runner:latest` image.
The bare upstream image lacks `gh` and `jq`, causing workflows to fail with exit code 127.

To rebuild after changes to Dockerfile.runner:
```bash
docker build -f Dockerfile.runner -t ezgha-runner:latest .
```

Then update `~/.config/ezgha/config.toml`:
```toml
[runner]
image = "ezgha-runner:latest"
```

## After any commit (IMPORTANT — Gate 0)
Gate 0 checks that the installed binary's embedded SHA matches the current `HEAD` commit.
**Every commit — even docs-only — advances HEAD**, so you must always rebuild after committing:

1. `cargo test` — verify all tests pass
2. `cargo install --path .` — install updated binary (embeds new HEAD SHA)
3. `systemctl --user restart ezgha.service` — restart daemon
4. `./docs/verify-exit-criteria.sh` — verify all gates pass

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

## /doctor-ezactions command
Running `/doctor-ezactions` in this repo executes:
1. `./doctor-runner` — fleet health check
2. `./docs/verify-exit-criteria.sh` — ironclad exit criteria (Gates 0–10)

Self-heal any failures found before reporting.

## /harness command  
Running `/harness` executes `./docs/verify-exit-criteria.sh` and audits all gates. Report PASS/FAIL per gate.

## Safety rails
- Never run `git add -A` — stage only files you changed
- Always push after finishing any unit of work
- Never modify `~/.config/ezgha/config.toml` without also restarting the service
