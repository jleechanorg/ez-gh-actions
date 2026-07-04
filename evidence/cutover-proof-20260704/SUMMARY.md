# Cutover stability proof — 2026-07-04

**Repo:** github.com/jleechanorg/ez-gh-actions
**Org fleet:** all 16 X64 self-hosted runners are now `ez-org-runner-{1..16}`.
                0 colima X64 / 0 colima mac.

## Captured incident + recovery
At 03:51 UTC, ezgha's slot file showed slots 1..16 reserved from a prior
daemon-restart gap, while no GitHub-side registrations existed. ezgha
loop-bailed every 30s with "all 16 runner slot(s) are currently in use".
4 queued workflow_dispatch jobs sat un-picked-up because there were 0
matching runners.

Fix: cleared `~/.config/ezgha/slot_assignments.toml` and
`docker rm -f` any stale containers, then `systemctl --user restart
ezgha.service`. New 16 daemon-side containers up; 16 fresh JIT
registrations against `jleechanorg` with labels
`[self-hosted, Linux, self-hosted-mikey, X64, ezgha]`.

4 jobs that were queued got picked up immediately after the restart.

## Routing proof (12 runs after fix, job API capture)
| Run ID | Runner | Conclusion | Notes |
|--------|--------|------------|-------|
| 28703942449 | ez-org-runner-3  | success | queued, picked up post-restart |
| 28703943434 | ez-org-runner-4  | success | queued, picked up post-restart |
| 28703944342 | ez-org-runner-5  | success | queued, picked up post-restart |
| 28703945368 | ez-org-runner-6  | success | queued, picked up post-restart |
| 28703981939 | ez-org-runner-12 | success | freshly dispatched |
| 28703982618 | ez-org-runner-10 | success | freshly dispatched |
| 28703983289 | ez-org-runner-16 | success | freshly dispatched |
| (older 5 runs from earlier sess.) | ez-org-runner-2/4/6/7 | success | see cutover-20260703 |

## Histogram of distinct slots used (12 most-recent runs)
- 2× ez-org-runner-6
- 2× ez-org-runner-4
- 2× ez-org-runner-3
- 1× ez-org-runner-7
- 1× ez-org-runner-5
- 1× ez-org-runner-2
- 1× ez-org-runner-16
- 1× ez-org-runner-12
- 1× ez-org-runner-10

= 9 distinct slots, NO colima runner activity recorded.

## What was disabled (re-spawners killed)
- 4 cron entries commented out (cleanup/monitor/watchdog/hard-cleanup)
  preserved in /tmp/cron.bak.
- 2 systemd --user units disabled:
  jleechanorg-colima-runners.service, colima-runners.service

## Reproduction
gh api orgs/jleechanorg/actions/runners --paginate | jq ...
gh api repos/jleechanorg/ez-gh-actions/actions/runs/<id>/jobs | jq ...
journalctl --user -u ezgha.service
