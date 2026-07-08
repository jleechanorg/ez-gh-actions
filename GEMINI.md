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

## /doctor command
Running `/doctor` in this repo executes:
1. `./doctor.sh` — fleet health check
2. `./docs/verify-exit-criteria.sh` — ironclad exit criteria (Gates 0–10)

Self-heal any failures found before reporting.

## /harness command  
Running `/harness` executes `./docs/verify-exit-criteria.sh` and audits all gates. Report PASS/FAIL per gate.

## Safety & Monitoring Principles
- **Self-Outage Prevention Principle**: A safety, health, or monitoring mechanism must not be able to cause the outage or failure it is designed to guard against.
- **Blast-Radius & Interaction Review**: Any change to a threshold, health-check, watchdog configuration, restart policy, resource limit, or monitor cadence must be accompanied by an evaluation of its blast radius and interaction with other components. The change description must state the normal peak of the bounded metric and verify a safe remaining margin.

## Safety rails
- Never run `git add -A` — stage only files you changed
- Always push after finishing any unit of work
- Never modify `~/.config/ezgha/config.toml` without also restarting the service
