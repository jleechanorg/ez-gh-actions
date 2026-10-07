# ez-gh-actions — Claude Code Agent Instructions

## Project overview
`ezgha` is a Rust CLI that manages ephemeral self-hosted GitHub Actions runners using Docker JIT registration. One binary; installs as a user systemd service.

## Key files
- `src/docker_backend.rs` — core runner lifecycle (slot allocation, container management)
- `src/github.rs` — GitHub API calls (JIT config, runner registration, conflict resolution)
- `src/main.rs` — CLI entry point
- `~/.config/ezgha/config.toml` — runtime config (do NOT commit this)
- `doctor-runner` — authoritative fleet health check (`doctor.sh` is a deprecated back-reference)
- `docs/verify-exit-criteria.sh` — ironclad exit criteria checker (Gates 0–10)
- `Dockerfile.runner` — custom runner image with `gh` + `jq` pre-installed
- `.claude/skills/ezgha-doctor/SKILL.md` — diagnostic + self-healing recipes
- `.claude/commands/doctor-ezactions.md` — `/doctor-ezactions` slash command (`/doctor` is a deprecated alias)

## Custom runner image (IMPORTANT)
The config must use `ezgha-runner:latest` (built from `Dockerfile.runner`), NOT the bare `ghcr.io/actions/actions-runner:latest` image.
The bare upstream image lacks `gh` and `jq`, causing workflows to fail with exit code 127.

Only the designated deploy-owner may rebuild the production image or update `~/.config/ezgha/config.toml`. Follow the canonical image-build and deployment procedure in `CLAUDE.md`; other workers commit, push, and hand off.

## After any commit

Run `cargo test`, commit scoped files, and push. Live installation, service restart, and `verify-exit-criteria.sh` belong to the **single deploy-owner** for the current session, using the canonical Gate 0 procedure in `CLAUDE.md`.

If you are not the designated deploy-owner: **commit + push only; do not deploy.** Hand the exact commit SHA and test result to the deploy-owner.

## Commit conventions
Every commit subject must be prefixed with the runtime that produced it:
- `gemini/<model-id>: <subject>`
- `claude/<model-id>: <subject>`
- `human: <subject>`

## Common self-healing recipes

The commands below mutate the live fleet and are **deploy-owner-only**. Non-owners may collect the diagnostic evidence, then hand remediation to the designated owner.

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
1. `./doctor-runner` — authoritative fleet health check
2. Deploy-owner only: `./docs/verify-exit-criteria.sh` — live exit criteria

Non-owners report the diagnostic result and hand off; they do not self-heal the live fleet.

## /harness command  
Only the designated deploy-owner runs the live `/harness` workflow. Other workers run repository-local tests and report the exact commit SHA.

## Safety & Monitoring Principles
- **Canonical Prohibition on Physical-Host Reboot Primitives & Watchdog-Driven Restarts**: See `CLAUDE.md` ("Safety & Monitoring Principles"). Physical-host reboot/shutdown commands and watchdog-driven forced restarts are strictly forbidden. Recovery authority belongs strictly to the child layer (container replenishment, process `Restart=on-failure`, graceful shutdown, and operator recovery).
- **Self-Outage Prevention Principle**: A safety, health, or monitoring mechanism must not be able to cause the outage or failure it is designed to guard against.
- **Blast-Radius & Interaction Review**: Any change to a threshold, health-check, watchdog configuration, restart policy, resource limit, or monitor cadence must be accompanied by an evaluation of its blast radius and interaction with other components. The change description must state the normal peak of the bounded metric and verify a safe remaining margin.

## Safety rails
- Never run `git add -A` — stage only files you changed
- Always push after finishing any unit of work
- Only the designated deploy-owner may modify `~/.config/ezgha/config.toml` or restart the service
