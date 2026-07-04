# Cutover evidence — colima X64 → ezgha, 2026-07-03

**Repo:** github.com/jleechanorg/ez-gh-actions
**Org fleet (jleechanorg):** all 16 X64 self-hosted runners now ez-org-runner-{1..16}; 0 colima
**Pinned commit:** `13f66db` (vm-or-refuse + install.sh + skill + ci-selfhosted) + `627be9e` (org-scope JIT routing) + `3f04937` (post-fix regression)

## Live routing proof
Six consecutive `ezgha-selftest` workflow_dispatch jobs on jleechanorg/ez-gh-actions (each `runs-on: [self-hosted, ezgha]`), all completed success in 4 s, each picked by a distinct `ez-org-runner-*` slot:

| Run ID | Runner | Conclusion | Latency |
|--------|--------|-----------|---------|
| 28692480574 | ez-org-runner-12 | success | 4 s |
| 28692497072 | ez-org-runner-3  | success | 4 s |
| 28692497625 | ez-org-runner-4  | success | 4 s |
| 28692498097 | ez-org-runner-6  | success | 4 s |
| 28692498587 | ez-org-runner-2  | success | 4 s |
| 28692499021 | ez-org-runner-7  | success | 4 s |

Captured live at https://github.com/jleechanorg/ez-gh-actions/actions via `gh api .../actions/runs/<id>/jobs`.

## Org runner roster (post-cutover)
- `ez-org-runner-1..16` — 16 X64 Linux, registered org-scope against `jleechanorg`, all `status=online`
- Labels per runner: `[self-hosted, Linux, self-hosted-mikey, X64, ezgha]`
- 0 `org-runner-*` (colima X64) registrations
- 0 `org-runner-mac-*` registrations (will require Tart M2 to replace)
- 0 `ezgha-Jeff-Ubuntu-*` stale zombies

## What was disabled (re-spawners killed)
- Cron entries (4): commented out (preserved in `/tmp/cron.bak`)
  - `cleanup.sh` (daily 3 a.m.)
  - `hard-cleanup.sh` (weekly Sun 4 a.m.)
  - `monitor.sh` (`*/15`)
  - `lima-watchdog.sh` (`*/5`)
- systemd --user units (2): stopped + disabled
  - `~/.config/systemd/user/jleechanorg-colima-runners.service` (docker compose up 16 colima containers)
  - `~/.config/systemd/user/colima-runners.service` (limactl start + start.sh)

To re-enable: `crontab /tmp/cron.bak` + `systemctl --user enable jleechanorg-colima-runners colima-runners`.

## Proof artifacts in this folder
- fleet_inventory.json — gh api before/after
- routing_runs.json — run → runner mapping for the 6 jobs above
- removed_runners.json — 16 org-runner-* deletes + 16 ez-org-runner resets
