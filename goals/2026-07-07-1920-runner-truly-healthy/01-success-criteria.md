# Success Criteria — runner-truly-healthy (2026-07-07)

Each criterion needs concrete evidence (command output, run URL, Slack message link,
alerts.jsonl entry) — no assertion-only PASS.

## SC1 — Slack alerting works end-to-end (P1, bead ez-gh-actions-zmk)
- [ ] `slack_webhook_url` configured in ~/.config/ezgha/config.toml [alert]
- [ ] Service restarted after config change (repo rule)
- [ ] A REAL alert delivered to Slack (test alert AND at least one organic
      queue-saturation alert), message visible in channel
- Evidence: Slack message timestamp/permalink + matching alerts.jsonl entry

## SC2 — Email alerting works end-to-end (P1, bead ez-gh-actions-zmk)
- [ ] A working email path exists on this box (msmtp/sendmail shim or alert.rs
      extension), `email_to` configured
- [ ] A real test alert email received at jleechan@gmail.com
- Evidence: delivery confirmation (message-id / inbox check via gmail tooling)

## SC3 — Saturation invariant monitored + alerted
- [ ] Monitor implements user invariant #1: queued pending self-hosted work while
      any of the 22 (16 linux + 6 mac) runners idle/offline → alert
- [ ] Monitor implements invariant #2: any current JOB (not run object) in target
      repos in_progress or queued > 20 min → alert (already partially in
      queue_monitor; verify thresholds + delivery)
- Evidence: code/config + a forced or organic alert proving each path

## SC4 — Queue actually drained below 20-min tail
- [ ] Superseded queued runs cancelled (queue-backlog-drain.sh --superseded --apply)
- [ ] Stale zombies >8h deleted (cleanup-stuck-runs.sh --zombies --apply)
- [ ] Fresh queue wait max < 20m sustained across 3 consecutive doctor samples
      ≥30 min apart, OR a documented capacity finding showing steady-state demand
      > capacity with numbers (jobs/hour vs runner-hours available)
- Evidence: doctor.sh Gate 8 output before/after with timestamps

## SC5 — Production pool proves real job execution
- [ ] Doctor Gate 7 shows selftest/real jobs succeeding on ez-runner-c-* (not only
      canary) — at least 1 fresh proof
- Evidence: run URL + runner name

## SC6 — Fleet integrity holds under churn
- [ ] 16/16 + 6/6 + 1/1 across 3 consecutive verifier passes ≥30 min apart
- [ ] ez-gh-actions-ed8 (transient 14-15/16 dip) root-caused or reproduced with a
      fix or a documented mechanism
- Evidence: verify-exit-criteria.sh outputs + ed8 bead update

## SC7 — Tracking hygiene
- [ ] beads db/JSONL sync fixed (br show ez-gh-actions-ed8 works)
- [ ] All work committed to origin/main with provenance-tagged subjects, Gate 0
      rebuild loop honored after every commit
- [ ] evidence/612cd6ddb205/ dispositioned (commit or delete with reason)

## SC8 — Long-term root-cause fixes for >20-min runs (added 2026-07-07 19:35, user directive)
- [ ] /harness-style root cause for every recurring >20-min run class; fix the
      workflow/harness, not just the symptom. Workflow fixes in OTHER repos
      (worldarchitect.ai etc.) are IN scope now.
- [ ] Green Gate "Verdict Poll (Gate 7)" redesign or timeout fix — 4 runs found
      polling 30–65 min on GitHub-hosted runners after self-hosted work succeeded
      (cancelled 28887689977, 28888036779, 28888061518, 28888258715 at 19:34)
- [ ] CI-check value audit: identify checks that don't add value (e.g. always-pass,
      redundant, or trivially cheap jobs burning runner slots like CodeRabbit ping,
      limit-pr-runs as separate jobs) — propose/execute removal or consolidation
- [ ] JIT re-registration gap quantified and mitigated (live evidence: registered
      ez-runner-c count oscillated 12→14/16 while all 16 containers were up+busy —
      churn latency is real capacity loss under saturation; feeds ed8)
- Evidence: workflow diffs/PRs in target repos, before/after run-duration data

## Explicitly out of scope
- Mac-side bugs (jleechan-0q9, -5rv) unless they block SC6
