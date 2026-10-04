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

## GH#106 acceptance env vars (bead jleechan-vsd1)

The following env vars were added in GH#106 to close the five
acceptance gaps. All are optional with sensible defaults — see the
script header for the canonical contract.

| Var | Default | Purpose |
|---|---|---|
| `EZGHA_DOCTOR_RUNNER` | `0` | When `1`, invoke `$DOCTOR_RUNNER_PATH` and parse its 4-state verdict. Verdict `fail` elevates both windows to degraded. |
| `DOCTOR_RUNNER_PATH` | `<repo>/doctor-runner` | Path to the doctor-runner executable. |
| `CRITICAL_DEGRADED_THRESHOLD` | `2` | Number of `CRITICAL` lines in the daemon stderr log within the short window before the gate fires. Only contributes to degraded when doctor-runner OR container_count is also degraded (idleness false-positive guard). |
| `EZGHA_EXPECTED_CAPACITY` | `16` | Expected per-host container count. Compared against `docker ps --filter label=ezgha=managed`. Shortfall elevates both windows to degraded. |
| `ALERT_LOG_FILE` | `/var/log/ezgha-alerts.log` | JSONL sink. Falls back to `$STATE_DIR/alerts.log` if not writable. |

## GH#106 payload schema additions

The JSON payload on stdout now includes these fields (in addition to
the original fields):

- `doctor_verdict` (`ok` / `fail` / `n/a`) — when `EZGHA_DOCTOR_RUNNER=1`
- `doctor_executing`, `doctor_idle_ok`, `doctor_idle_starved`, `doctor_down` — 4-state counts (int)
- `critical_in_window` (int) — CRITICAL lines in the short window
- `container_count` (int) — local `docker ps --label ezgha=managed` count
- `expected_capacity` (int) — value of `EZGHA_EXPECTED_CAPACITY`

**Field rename:** `reason` → `evidence` (the free-text explanation of
the alert decision). The old `reason` field is no longer present.
Tests and downstream consumers must use `evidence`.

## Backwards compatibility

- `EZGHA_DOCTOR_RUNNER=0` (default) → all `doctor_*` fields are `"n/a"` / `0`.
- `ALERT_LOG_FILE` unset → no JSONL sink is written (only stdout).
- `EZGHA_EXPECTED_CAPACITY=0` (or unset) → `container_count >= 0` always,
  so the container-count check is effectively a no-op (useful for tests
  that don't want this gate to fire).

## Operational notes (GH#106)

- **False-positive guard for CRITICAL stderr scan:** the daemon
  routinely logs `CRITICAL runner startup settling ceiling reached:
  0/6 executing locally` on a healthy idle fleet (memory
  `feedback_2026-08-01_daemon_settling_check_false_positive_idle.md`).
  The CRITICAL scan only fires when doctor-runner (fail) OR
  container_count shortfall is also present. CRITICAL alone is gated
  off.
- **JSONL sink at `/var/log/ezgha-alerts.log`:** requires root/sudo to
  create the file. On a non-root launchd install, the script falls
  back to `$STATE_DIR/alerts.log` automatically — no operator action
  needed, but the events accumulate in the user state directory.
