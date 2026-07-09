# Fleet Watchdog

`scripts/ezgha-fleet-watchdog.sh` enforces the configured mac + linux runner
count when the `ezgha` serve supervisor is alive but has fallen below target
(a known design gap: serve replaces churned slots but does not aggressively
top up to N when below count). It replaces an earlier unversioned copy at
`~/.local/bin/ezgha-fleet-watchdog.sh` (bead `ez-gh-actions-2ik`) that lacked
guardrails and was found to have restarted `ezgha.service` 15 times in 3
hours during a 2026-07-08 fleet churn incident — every one of those restarts
orphaned in-flight GitHub runner registrations, since the daemon has no
SIGTERM handling.

## Guardrails

This version adds, on top of the original mac+linux dual-host check and the
pre-existing "below target but slots still cover it → ephemeral churn, don't
restart" guard:

- **N=3 consecutive-miss threshold** — a restart only fires after 3
  consecutive ticks (about 6 minutes at the default 120s timer interval)
  have observed both `actual < configured` and `slots < configured`. State
  persists per host in `$EZGHA_WATCHDOG_STATE_DIR`
  (default `~/.local/state/ezgha/watchdog/`), since each systemd timer
  firing is a fresh, stateless process.
- **Load gate** — skips the restart (logs only) if the host's 1-minute load
  average exceeds `$EZGHA_WATCHDOG_LOAD_THRESHOLD` (default 12), mirroring
  the pre-restart check in this repo's `CLAUDE.md` Gate 0 section.
- **Cooldown** — at most 1 restart per host per
  `$EZGHA_WATCHDOG_COOLDOWN_SECONDS` (default 1800s / 30 minutes).
- **No duplicate logging** — the script no longer tees its own output to a
  log file; the shipped systemd unit's `StandardOutput=append:...` /
  `StandardError=append:...` captures it once. The old script tee'd AND the
  old systemd unit captured stdout to the same file, so every line was
  written twice.

CLI flags (`--host {mac,linux}`, `--dry-run`, `--help`) and exit codes
(`0` = at target or restarted, `1` = below target / no action this tick,
`2` = supervisor missing or state unreadable) are unchanged from the
original script.

## Linux systemd user timer

Install the templates into the user systemd directory after substituting
the repo checkout path:

```bash
repo_path="$(pwd)"
mkdir -p ~/.config/systemd/user ~/.local/state/ezgha
sed "s|@REPO_PATH@|${repo_path}|g; s|@HOME@|${HOME}|g" \
  systemd/ezgha-watchdog.service \
  > ~/.config/systemd/user/ezgha-watchdog.service
sed "s|@REPO_PATH@|${repo_path}|g; s|@HOME@|${HOME}|g" \
  systemd/ezgha-watchdog.timer \
  > ~/.config/systemd/user/ezgha-watchdog.timer

systemctl --user daemon-reload
```

This step only installs and reloads the unit definitions — it does **not**
start or enable the timer. Enabling is a separate, explicit action:

```bash
systemctl --user enable --now ezgha-watchdog.timer
```

Run that yourself (or have the deploy-owner run it) once you want the
watchdog live again. As of this writing the watchdog timer is deliberately
stopped pending a decision on when to re-enable it — do not enable it as a
side effect of installing these files.

Logs go to `~/.local/state/ezgha/watchdog.log` (rotate/prune manually or
add a logrotate rule; none is shipped yet).

## macOS launchd

Not shipped in this change. The script supports `--host mac` for manual or
future launchd-driven invocation, but no `launchd/*.plist.template` exists
for it yet — the mac restart path (`launchctl kickstart`) still needs to run
on the Mac itself. Track as follow-up if/when the mac watchdog needs to be
automated the same way.

## Testing

```bash
./scripts/ezgha-fleet-watchdog.sh --dry-run --host linux
./scripts/ezgha-fleet-watchdog.sh --dry-run --host mac
```

`--dry-run` never mutates the state files under `$EZGHA_WATCHDOG_STATE_DIR`
and never restarts anything, so it is safe to run repeatedly against a live
host. There is no existing shell-test harness in this repo (tests are
`cargo test` Rust tests); `shellcheck` is run as the lint gate for this
script instead — see the PR description for output.

## Future work

- Consider jittered/exponential backoff instead of a flat 30-minute cooldown, to avoid synchronized restart waves if the fleet ever grows beyond today's 2 hosts.
- Consider cross-host jitter (stagger mac vs linux checks) for the same reason — currently low priority with only 2 hosts.
- Consider layering StartLimitBurst/StartLimitIntervalSec directly on ezgha.service itself (the daemon's own systemd unit, NOT this watchdog's unit) as an independent second rate-limit beneath this watchdog script — note this as a separate follow-up touching a different file (systemd/ezgha.service if it exists in this repo, otherwise note it lives outside this repo) and out of scope for this PR.
