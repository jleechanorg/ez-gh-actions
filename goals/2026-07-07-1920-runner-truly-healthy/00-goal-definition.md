# Goal: ezgha runner fleet truly healthy — no silent failures, no >20min runs

**Defined**: 2026-07-07 19:20 PT
**Deadline**: 2026-07-08 07:20 PT (12-hour autonomous window)
**Authorization**: work directly on origin/main of ez-gh-actions; make own decisions; use /sidekick and /swarm

## Original goal statement (user)

Iterate until ez-gh-actions runner is truly healthy and working and no GH Actions
runs take longer than 20 min. Core suspicion: "we often have poor monitoring and
think things are working and they are not."

User-stated invariants (violations = something is wrong):
1. If there is queued pending work and all 6 Mac + 16 Linux runners are NOT busy → wrong.
2. If a GH Actions run takes over 20 minutes → wrong.
3. Slack and email alerts must exist and demonstrably work.

## Ground truth at definition time (own measurements, 2026-07-07 19:15)

- Runners themselves: healthy. 16/16 Linux prod, 6/6 Mac, 1/1 canary (Gate 4 start 4s).
- **Queue: BAD.** worldarchitect.ai: 230 queued runs, fresh queue wait p50=52m p90=99m
  max=398m vs 20m threshold. 10 stale zombies >8h.
- **Alert delivery: 0%.** src/alert.rs supports Slack webhook + sendmail email, and the
  queue monitor HAS been writing correct saturation alerts — but only to
  ~/.local/state/ezgha/alerts.jsonl. `slack_webhook_url` and `email_to` are both unset
  in ~/.config/ezgha/config.toml. Detection works; nobody is told. This is the root
  cause of "we think it's working and it's not."
- SLACK_WEBHOOK_URL exists in ~/.bashrc (usable). No sendmail/msmtp/gog on this box.
- Doctor Gate 7 warns: last 6 selftest runs all landed on the canary runner, not
  ez-runner-c-* — real-job proof for the production pool is 0/6.
- Bead db drift: ez-gh-actions-ed8 exists in .beads/issues.jsonl but `br show` can't
  find it (local db out of sync with JSONL).

## Interpretation notes

- The 20-min invariant applies to *current job* age, not run-object age (run age alone
  is misleading per prior classification — many old run objects have fresh jobs).
- worldarchitect.ai demand may structurally exceed 22-runner capacity; superseded-run
  draining (scripts/queue-backlog-drain.sh) and zombie deletion are the sanctioned
  levers. If steady-state demand still exceeds capacity after drain + trimming, that
  is a capacity finding to report, not silently absorb.
- Multi-session repo: `git status -s` before builds; leave sibling WIP alone.
- Gate 0: after ANY commit → cargo test, cargo install --path ., restart service, verify.
