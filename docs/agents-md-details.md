# AGENTS.md details

Detail moved verbatim from [AGENTS.md](../AGENTS.md) to keep it under 200 lines. These rules remain in force.

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
`MAX_APP_API_CALLS=60`) prioritizes org repos by `pushed` without excluding stale-push repos, includes `in_progress` and recently updated runs (`>= YESTERDAY_UTC`), paginates `/jobs?filter=all&per_page=100` within budget, splits/clips each job's `[started_at, completed_at]` interval across `[YESTERDAY_UTC, TODAY_UTC]` UTC midnight boundaries (capping apportioned day minutes per job at `ceil(total_job_sec / 60)`), and prices standard `macos-latest`/`macos-13..15*`/`macos-26*` (`$0.062/min`), `ubuntu-latest`/`ubuntu-20.04..24.04` (`$0.006/min`), and `windows-latest`/`windows-2019..2025` (`$0.010/min`) runners at baseline rates while larger/custom hosted labels (including `xcode-*`) are marked unpriced (`partial`) and any non-self-hosted `macos-*`/`xcode-*` label still counts toward `DAILY_MACOS_MIN_WARN`. Daily `NET_SPEND_BREACH` ranks `top_net_repo` by `.netAmount` separately from gross `top_repo`. It collects all due breaches per run into one combined `ERROR` notification (`breach_keys`, using `MULTI_BREACH` when queued breach status names differ—whereas two breaches with the same status name, e.g. yesterday+today `COST_SPIKE`, retain `COST_SPIKE`—and folding any simultaneous `BLIND` condition into that single alert so the 300s policy rate limit cannot drop simultaneous breaches or `BLIND`, with Cloud Monitoring `labelExtractors` exposing `${log.extracted_label.status}` and `${log.extracted_label.detail}` in Slack documentation) and marks `.sent` keys atomically only after `gcloud logging write` succeeds. Only a full authoritative `/organizations/.../settings/billing/usage`
read + parse resets `api_failures=0`; any skip, partial rollover, or failure persists `api_failures` before alert writes and emits `WARNING BLIND`
at `MAX_API_FAILURES=3` even if partial App fallback ran.
- **Recovery / setup (OPERATOR-ONLY):**
  - Provision `~/.config/ezgha/gh_token` beforehand via the GitHub App token refresher (see `docs/gh-app-token.md`) so the App-token fallback is available if primary billing auth returns 403; the targeted `install org.jleechanorg.ezgha-gh-actions-cost-alert` step does not create `~/.config/ezgha/gh_token`.
  - Bulk `launchd/install-launchagents.sh install` skips `org.jleechanorg.ezgha-gh-actions-cost-alert` on hosts where its plist is not yet installed (it is an org-singleton monitor, not a per-Mac daemon; pass `install org.jleechanorg.ezgha-gh-actions-cost-alert` explicitly or `EZGHA_INSTALL_COST_ALERT_BULK=1`, while existing plists upgrade in place); `install` and `remove` serialize via kernel `fcntl.flock` on `~/.local/state/ezgha/install-launchagents.flock` (`INSTALL_LOCK_TIMEOUT_SEC=30`), closing FD 9 inside `launchctl`.
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
execute from the fork's head commit and are NOT a security boundary against modified fork workflows, and GitHub's `fork-pr-contributor-approval` setting does NOT gate `pull_request_target` workflows or private-repo fork workflows when `run_workflows_from_fork_pull_requests=true`; therefore `setup-native-macos-runner.sh` enforces fail-closed (exit `5` before minting a registration token or completing setup/verify unless `--allow-public-fork-exposure` is explicitly passed after operator workflow review): in `--repo` mode, `.private == true` AND `repos/<owner>/<repo>/actions/permissions/fork-pr-workflows-private-repos` `.run_workflows_from_fork_pull_requests == false`; in org runner-group mode, `allows_public_repositories == false` AND `restricted_to_workflows == true` AND non-empty `@`-pinned `selected_workflows` (queried via `orgs/<org>/actions/runner-groups/<id>`) AND `orgs/<org>/actions/permissions/fork-pr-workflows-private-repos` `.run_workflows_from_fork_pull_requests == false`. Live runner state (`verify_live_runner_state`) requires both `.runner` and `.credentials`, binds positive numeric `.runner` `agentId` (no name-only fallback), exact `RUNNER_NAME`, exact `RUNNER_LABELS`, org runner-group membership (`orgs/${ORG}/actions/runner-groups/${group_id}/runners`), and (in `--verify` without `--offline`) live `status == "online"`. Normal setup reconfigures only on missing/drifted local metadata, `agentId`/label/group drift, or `--reconfigure`, and when an already-configured runner is unchanged it checks live `status == "online"` via `verify_runner_online` and **fails closed without reconfiguring** if `offline` (requiring `--reconfigure`); after `config.sh`, `post_config` retries full `verify_live_runner_state` and post-launch `verify_runner_online` retries up to `POST_CONFIG_VERIFY_ATTEMPTS=15` (`POST_CONFIG_VERIFY_SLEEP_SEC=2`, with `gh api` calls bounded by `GH_CALL_TIMEOUT_SEC=30`) and requires an exact positive live match before discarding `.backup-pre-reconfigure.<pid>` (and any prior `.backup-pre-reconfigure.*` dirs) or keeping the LaunchAgent loaded (exiting `4` fail-closed otherwise, or exiting `7` explicitly if `stop_launchagent` fails to unload an unverified LaunchAgent). Before staging binaries or calling `stop_launchagent` (and again immediately after minting the registration token before stopping launchd or modifying `.runner`/`.credentials`), setup queries live runners for `.name == RUNNER_NAME` when configuration is needed: it never passes `--replace` to `./config.sh`; instead `resolve_replace_collision_policy` derives `prev_agent_id` from `${RUNNER_DIR}/.runner` (or from `.backup-pre-reconfigure.*/.runner` across a failed `--reconfigure` retry when all preserved backups share one unique positive `agentId`), verifies `.busy != true` and `colliding_id == prev_agent_id` (or `--force-replace-name`), records `VERIFIED_DELETE_AGENT_ID`, exits `6` fail-closed on any foreign/busy/multi-match collision without stopping the incumbent LaunchAgent, and after `stop_launchagent` + binary promotion + credential backup deletes ONLY that verified numeric ID via `gh api --method DELETE .../${VERIFIED_DELETE_AGENT_ID}` (treating HTTP 404 / Not Found as already absent and failing closed with exit `4` on any other API error) before invoking `./config.sh --unattended ...` without `--replace` so a concurrent foreign runner can never be revoked. Registration passes the token via `ACTIONS_RUNNER_INPUT_TOKEN` in the child environment (never `--token` in process argv). Binary provisioning and `--verify` enforce `os.path.realpath` containment inside `RUNNER_DIR` across `Runner.Listener`/`config.sh`/`run.sh`/`runsvc.sh`/`run-helper.sh.template`/`env.sh`/`externals*`, plist `ProgramArguments`, and all nested symlinks under `bin*`/`externals*`, rewriting both top-level and nested `EXISTING_RUNNER_DIR`-scoped symlinks to relative symlinks inside `STAGE_DIR`/`RUNNER_DIR` (copying external targets) so cloned binaries never share `~/actions-runner`, sets `chmod 600` on `.credentials*`, and preserves an existing `${RUNNER_DIR}/.env` rather than truncating it; reconfiguration confirms launchd
unload (`rc=113` or service-not-found, failing closed on lookup/permission errors) before removing
credentials, preserves `.backup-pre-reconfigure.<pid>` on failure, and exits non-zero (`4`) fail-closed
without restoring old credentials or restarting the service; no-change reruns leave an already-loaded
LaunchAgent untouched; and `--uninstall` executes before Scratch resolution while confirming the
GUI-domain job is unloaded before removing the plist.
- **Recovery / setup (OPERATOR-ONLY):**
  - `OPERATOR-ONLY: ./scripts/setup-native-macos-runner.sh` (install/re-register + load LaunchAgent; pass `--reconfigure` to force unload and re-registration, or `--runner-group GROUP` to target a restricted runner group)
  - `OPERATOR-ONLY: ./scripts/setup-native-macos-runner.sh --verify` (check binaries including `run-helper.sh.template`, `env.sh`, and `externals*`, `WORK_DIR`, `.runner` numeric `agentId`, `.credentials`, `.ezgha-labels`, `.ezgha-group`, server-side private-repo/private-runner-group fork-protection policy, and `GH_BIN` live GitHub runner `online` status/group/labels unless `--offline`, `SessionCreate=true`, plist `WorkingDirectory`/`ProgramArguments`, and launchd state)
