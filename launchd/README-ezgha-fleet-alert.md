# ezgha-fleet-alert launchd plist (bead jleechan-vg1d)

## Purpose

`launchd/org.jleechanorg.ezgha-fleet-alert.plist.template` runs
`scripts/ezgha-fleet-alert.sh` every 5 minutes on macOS. The script
performs deterministic fleet-health alerting with multi-window
hysteresis — it does NOT call any AI/LLM service and does NOT call the
GitHub API for fleet state. See `scripts/ezgha-fleet-alert.sh` header
for the full contract.

## Install

```bash
bash launchd/install-launchagents.sh install org.jleechanorg.ezgha-fleet-alert
```

This will:

1. Copy `scripts/ezgha-fleet-alert.sh` into `~/.local/libexec/ezgha/`
   (stable path; NEVER a repo/worktree checkout path — see bead
   ez-gh-actions-sa1t for the failure class this avoids).
2. Render the template with `@HOME@` and `@SCRIPTS_DIR@` placeholders.
3. Load the plist with `launchctl load`.

## Activate (manual)

```bash
launchctl load -w ~/Library/LaunchAgents/org.jleechanorg.ezgha-fleet-alert.plist
```

The `-w` flag persists the load across reboots (mirrors the project
convention for one-shot activation).

## Disable

```bash
launchctl unload ~/Library/LaunchAgents/org.jleechanorg.ezgha-fleet-alert.plist
```

## Remove (also removes the installed script)

```bash
bash launchd/install-launchagents.sh remove
```

## Status check

```bash
launchctl list | grep org.jleechanorg.ezgha-fleet-alert
```

## Logs

- `~/Library/Logs/ezgha-fleet-alert-launchd.log` — stdout/stderr of the
  alerting script (one JSON line per invocation; alerts printed when
  fired).

## Operational notes

- **Idle fleet false-positive:** the alerting script does NOT fire on
  an idle healthy fleet (memory
  `feedback_2026-08-01_daemon_settling_check_false_positive_idle.md`).
  Multi-window hysteresis means a single transient blip will exit 2
  (hold), not 1 (alert).
- **Daemon-hot-path isolation:** the alerting script reads the daemon
  stderr log via `tail-with-lock` (POSIX `mkdir`-based lockfile) — it
  does NOT share stderr pipes with `ezgha.service` and does NOT keep
  the daemon's stderr fd open.
- **Alert sinks:** by default, macOS notifications via `osascript`. To
  route to Slack, set `SLACK_WEBHOOK_URL` in the plist's
  `EnvironmentVariables` dict (or via `launchctl setenv`) and switch
  `ALERT_SINK` to `slack`.
- **No live deploy from this PR.** Per CLAUDE.md Gate 0 caveats, the
  operator activates the plist after the PR is merged; this lane ships
  the template + script + systemd unit only.
- **NO live deploy from this lane.** Operator activates.