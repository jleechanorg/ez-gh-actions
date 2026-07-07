# ez-gh-actions — Claude Code Agent Instructions

## Project overview
`ezgha` is a Rust CLI that manages ephemeral self-hosted GitHub Actions runners using Docker JIT registration. One binary; installs as a user systemd service.

## Key files
- `src/docker_backend.rs` — core runner lifecycle (slot allocation, container management)
- `src/github.rs` — GitHub API calls (JIT config, runner registration, conflict resolution)
- `src/main.rs` — CLI entry point
- `~/.config/ezgha/config.toml` — runtime config (do NOT commit this)
- `doctor.sh` — fleet health check script
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
3. **Before `systemctl --user restart ezgha.service`, check `uptime` (1-min load average) and `docker ps --filter label=ezgha=managed | wc -l` (running container count). If load_1min > 12 or containers < 12, DO NOT restart — wait for reconciliation and recheck.** Mass cold respawns of many runners at once have tripped the host watchdog (`/etc/watchdog.conf` `max-load-1 = 24` on this 32-thread box) and rebooted the box twice on 2026-07-07, once killing an in-progress agent session outright. This check protects the fleet regardless of which agent/session is running Gate 0 — see bead `ez-gh-actions-po2` for the durable fix (load-aware respawn pacing inside the daemon itself) that will make this manual check unnecessary once it lands.
   **EXCEPTION**: if containers are actively draining (dropping over consecutive checks) due to a stuck/slow serve loop — confirmed by low load plus a shrinking container count with a live in-flight `gh api` process as the daemon's child — restart IS the remediation, not the risk. Low load + a draining fleet means the loop is stuck, not busy; waiting only makes it worse. This exact scenario happened 2026-07-07 (an expensive per-tick GitHub API fetch starved `ensure_count`, draining the fleet to 0 containers) — see `queue_monitor::SERVE_LOOP_TIME_BUDGET` for the structural fix that should prevent recurrence.
4. `systemctl --user restart ezgha.service` — restart daemon
5. `./docs/verify-exit-criteria.sh` — verify all gates pass

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

## /doctor command
Running `/doctor` in this repo executes:
1. `./doctor.sh` — fleet health check
2. `./docs/verify-exit-criteria.sh` — ironclad exit criteria (Gates 0–10)

Self-heal any failures found before reporting.

## /harness command  
Running `/harness` executes `./docs/verify-exit-criteria.sh` and audits all gates. Report PASS/FAIL per gate.

## Safety rails
- Never run `git add -A` — stage only files you changed
- Always push after finishing any unit of work
- Never modify `~/.config/ezgha/config.toml` without also restarting the service
