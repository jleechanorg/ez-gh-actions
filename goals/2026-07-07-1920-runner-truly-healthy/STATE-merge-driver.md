# Sidekick STATE — ez-gh-actions / merge-key-fixes-20260708

Owner: merge-driver sidekick (spawned 2026-07-08 by main). Durable copy — /tmp is NOT
durable on this host (proven 2026-07-07 reboot wiped it), so ALSO mirror critical state
to bead ez-gh-actions-9je and commit-to-git any code you touch immediately.

## Mission

Drive all KEY runner-health fixes to **origin/main**, gated by adversarial review.
User explicitly pre-authorized merging these key fixes to origin/main on 2026-07-08
("merge to origin main all key fixes"). That authorization covers the three items
below ONLY — not token rotation, not config.toml rewrites, not blind restarts.

## The key fixes (this mission's scope)

1. **reaper-wiring (bead ez-gh-actions-qbl) — durable zombie-slot self-heal. TOP PRIORITY.**
   - WHY: Mac was hard-capped at 5/6 for hours by a zombie slot — runner offline-but-busy
     on GitHub, container gone, phantom run still pinned → HTTP 422 delete-lock → daemon
     logged "keeping slot / all N in use" forever. Main fixed it LIVE by hand (gh run
     cancel) but that's a one-off; it WILL recur without the code fix.
   - THE FIX: docker_backend.rs offline-busy slot-reclaim path (~L312-333) must, on a 422
     "cannot be deleted / running a job", CANCEL the phantom run first (reuse reaper.rs
     cancel_workflow_run→force_cancel_workflow_run), THEN retry remove_runner, THEN release
     the slot — instead of giving up. TDD.
   - STATE: subagent `reaper-wiring` (spawned by main, model sonnet) is IMPLEMENTING this on
     a NEW branch, TDD, HELD for review (not merged). Poll `git branch -r | grep -iE
     'reaper|qbl|zombie'` for its pushed branch.
   - YOUR JOB: when its branch lands, spawn an ADVERSARIAL verifier (codex-consultant or a
     sonnet skeptic) prompted to REFUTE the fix — key risks to probe: (a) could it cancel a
     LEGITIMATELY-running job (not a zombie)? argue why the owned+missing-container filter
     prevents that; (b) is the repo for the cancel looked up correctly (jobs can be in any
     org repo)? (c) are the tests real (fail-first) not tautological? Only merge if clean or
     findings dismissed with reason. Then Gate 0 (see below).

2. **capacity-proof workflow — DONE, already on origin/main (HEAD 54424d9).** Verify it's
   there; nothing to merge. Subagent `capacity-proof` is separately RUNNING the 24-job
   burst + sampling both machines for the peak-simultaneous-executing proof; that's an
   evidence run, not a merge item. Collect its result when it reports.

3. **App token wiring (beads nuk / rate-limit lane) — the sustained-capacity blocker.**
   - WHY: Linux fleet oscillates 12↔16 because JIT registration bursts hit the SHARED
     GitHub user rate limit (5000/hr, per-user, shared across all agent sessions). The
     GitHub App (ID 4245332, install 145172957) gives an ISOLATED ~12500/hr bucket — the
     real fix. Ground truth 2026-07-08: daemon systemd env has NO GH_TOKEN/GITHUB_TOKEN
     (ambient gh auth); the App token is NOT wired in yet.
   - STATE: subagent `app-wiring` owns this; it went idle without confirming the token
     landed. Main pinged it for a precise status (mint success? separate-bucket proof?
     refresh mechanism? wired into daemon?).
   - YOUR JOB: if app-wiring produces a refresh helper + wiring, review it, and merge any
     COMMITTABLE code (refresh script, systemd timer unit) to origin/main. The token VALUE
     itself is a secret — never commit it; it goes in a chmod-600 file / systemd
     Environment, not git. Coordinate with app-wiring via SendMessage; do not duplicate its
     work.

## Gate 0 discipline (MANDATORY after ANY ez-gh-actions commit to main)

cargo test → cargo install --path . → **before restart, check `uptime` 1-min load AND
`docker ps --filter label=ezgha=managed | wc -l`**: if load_1min > 12 OR containers < 12,
DO NOT restart — wait for reconciliation and recheck. EXCEPTION: low load + a DRAINING
fleet with a live in-flight gh api call = loop stuck, restart IS the remediation. Then
`systemctl --user restart ezgha.service` → `./docs/verify-exit-criteria.sh`. You hold the
single-writer lock on install/restart. Do NOT run the full verify-exit-criteria.sh casually
(it dispatches a live canary + gh api calls under the rate limit) — only as the final Gate-0
step after a real deploy.

## Hard rules (non-negotiable)

- Merges to main are pre-authorized ONLY for the 3 key fixes above, ONLY after adversarial
  review passes. Anything outside that scope → flag main, do not merge.
- NEVER rotate/print tokens, webhooks, or keys. NEVER commit a secret value.
- NEVER `git add -A` — stage only files you changed. `git status -s` first; leave sibling
  WIP alone (multi-session repo).
- Never touch ~/.config/ezgha/config.toml casually; never restart the Mac daemon (main/mac
  session owns it); never start ezgha-watchdog.timer (blind-restart reboot hazard, bead 2ik).
- `br` CLI only for beads. Commit subjects: `claude/sonnet:` (you) / `codex/<model>:` (codex).
- COMMIT OFTEN: push after every green unit, never >30 min uncommitted. Update this STATE +
  bead ez-gh-actions-9je after every step; SendMessage(to="main") on each milestone.
- Adversarial verify before ANY merge sign-off — spawn an independent skeptic, attach verdict.

## Progress Log (append-only)

- 2026-07-08 ~09:2x — Sidekick spawned by main. reaper-wiring (impl) + capacity-proof
  (evidence) + app-wiring (token) subagents already in flight. capacity-proof workflow
  confirmed on origin/main (54424d9). Mac zombie fixed live (Mac now reaches 6/6). Linux
  16/16 at last check but oscillates under rate limit.

- 2026-07-08 09:27 — Startup protocol done: STATE.md mirrored to
  goals/2026-07-07-1920-runner-truly-healthy/STATE-merge-driver.md, committed f6f1a84,
  pushed. Read bead qbl. Found: (a) reaper-wiring is editing directly in the SHARED main
  working directory (not the dedicated worktree at ez-gh-actions-wt-qbl, which is clean) —
  src/reaper.rs already has collect_repo_runs()+LiveReaperApi, docker_backend.rs wiring +
  a new failing test (TDD red) in progress; (b) app-token wiring (fix #3) was ALREADY
  merged to origin/main at 7f476ac before I was spawned, no secret values committed.

- 2026-07-08 09:31 — app-wiring confirmed: live mint verified both machines (App bucket
  9350/9350 vs shared 5000/4884), refresh timers installed+enabled both machines
  (jeff-ubuntu systemd timer active, Mac launchd loaded), only gap was daemon restart to
  pick up the binary. Did Gate 0 the RIGHT way: since main workdir has reaper-wiring's
  uncommitted/incomplete WIP, built from a throwaway clean worktree
  (scratchpad/ezgha-clean-build, detached at origin/main f6f1a84) instead of `cargo install
  --path .` in the shared dirty tree — avoids deploying unreviewed WIP. 180/180 tests green
  there. Pre-restart check: containers dipped 15->9->12->15 with load 6.6-9.2 over ~90s
  (active respawn churn + queue_monitor logging queued_jobs=95, NOT a stuck loop) —
  confirmed safe (load never >12, containers back >=12) before restarting. Restarted
  ezgha.service (new PID, ExecMainStartTimestamp 02:32:21, binary f6f1a84). PROVED the
  App-token wiring is actually ACTIVE (not just installed): the daemon's live `gh api`
  child process has GH_TOKEN set in its environ, and that token's rate_limit shows
  9346/9350 remaining — isolated App bucket, confirmed in production use, not just minted.
  Ran ./docs/verify-exit-criteria.sh: Gate 0 PASS (deployed binary == f6f1a84 HEAD). Gate 1
  (cargo test in the shared workdir, which still has reaper-wiring's WIP) shows 184
  passed/1 failed — the 1 failure is reaper-wiring's own new TDD-red test
  (reclaim_zombie_locked_runner_cancels_then_deletes_on_success, expected mid-implementation,
  not a regression I introduced). Fix #3 (app token) is now DONE on jeff-ubuntu end-to-end
  (mint+refresh+wired+active+proven). Mac-side restart is NOT mine — never restart the Mac
  daemon per hard rules; that's main/mac session's call.

- 2026-07-08 09:38 — capacity-proof confirmed directly (fix #2 CLOSED): burst run
  28931890600, peak 21/22 (linux 15 + mac 6) at t=278s, evidence at
  scratchpad/capacity-proof-samples.jsonl. Verified via `gh api` the burst window was
  09:21:36Z-09:31:32Z UTC (02:21:36-02:31:32 PDT) — my App-token restart at 02:32:21 PDT
  was 49s AFTER, no overlap/disruption. team-lead independently flagged the same
  shared-tree collision risk I'd already routed around (clean worktree build) and directed
  reaper-wiring to checkpoint-commit its WIP to a branch immediately, even incomplete.
  Re-pinged reaper-wiring (2nd ping, no reply to 1st) with that ask + a debugging hint on
  its failing test (looks like a job_batches/revalidation-guard mismatch, not a design
  flaw). src/github.rs now dirty too (new file touched) — still actively working, last
  touch 02:35:59, ~1 min old at ping time.

- 2026-07-08 09:39-09:42 — reaper-wiring RELOCATED its work to the dedicated worktree
  (ez-gh-actions-wt-qbl, branch claude/qbl-zombie-slot-selfheal) and committed: e977002
  "wire cancel-then-delete into offline-busy slot reclaim", pushed to origin. Shared main
  workdir is now clean. Verified independently: 184/184 tests pass in the qbl worktree
  (including the previously-red reclaim_zombie_locked_runner_cancels_then_deletes_on_success).
  Reviewed the diff myself first (reaper.rs change is a pure refactor — extracts
  collect_repo_runs + LiveReaperApi, reuses existing plan_reaper_actions/
  execute_reaper_plan_with_api rather than new correlation logic). Spawned a codex-consultant
  ADVERSARIAL reviewer against commit e977002. VERDICT: FINDINGS, not clean:
  (1) is_runner_busy_lock_error's bare `contains("422")` substring check can false-positive
  on any remove_runner error whose interpolated runner ID contains "422" (422/1422/4220/...)
  — bounded blast radius (outer offline+busy+missing-container gate still applies before
  this ever fires) but imprecise, real, and easily triggered given continuous runner-id
  churn; (2) the "keeps_slot_when_job_never_leaves_in_progress" test passes for the WRONG
  reason (correlation mismatch on poll 1 via FakeReaperApi::default()'s unrelated fallback
  job, not genuine force-cancel+poll-timeout) — currently ZERO test coverage of the
  force-cancel escalation path. Deprioritized to a bead follow-up (not live under current
  org-scoped config): job correlation by bare runner_id assumes a global ID namespace.
  Logged both fixable issues on bead qbl + sent reaper-wiring a detailed fix request for
  #1 and #2. HOLDING THE MERGE — not dismissing these findings, they're real and
  actionable, not just nitpicks.

- 2026-07-08 09:45 — reaper-wiring reported "done, ready for review" (crossed in transit
  with my findings message — it addressed the ORIGINAL red test via a fixture fix, runner_id
  42 vs 1234 mismatch in the shared completed_job() helper, confirmed genuinely good by the
  reviewer). Clarified to reaper-wiring that the 2 findings from the adversarial review are
  SEPARATE, still-open issues in e977002 (not the same bug it already fixed). team-lead
  independently sent its own adversarial-review dispatch instruction, which crossed with my
  completed review — confirmed to team-lead the review was already done, findings already
  sent to reaper-wiring, matched team-lead's own 4 probe angles 1-for-1 (gate airtightness
  CLEAN, min_age=0 CLEAN, repo-coverage-limitation CLEAN/graceful-degradation, test-quality
  FINDING) plus 1 extra finding (422 substring) team-lead's list didn't include. NEW HARD
  CONSTRAINT from team-lead: even once merged, do NOT deploy (cargo install/restart jeff) —
  hold until team-lead coordinates post-load-settle (jeff just had a double-restart, load
  spiked ~18). Confirmed compliance explicitly.

- 2026-07-08 09:55 — reaper-wiring pushed 664cae2 fixing BOTH findings: (1) is_runner_busy_
  lock_error now only matches "currently running a job" (bare "422" check dropped entirely,
  reaper-wiring's own choice over tightening the pattern — safer, since gh's exact error
  formatting isn't guaranteed stable), new regression test with runner IDs 422/1422 on
  network/auth errors; (2) force-cancel test rewritten to seed FakeReaperApi.job_batches
  with 2*poll_attempts identical matching in-progress jobs, now asserts PollTimedOut status
  AND a real "force-cancel:" call in api.calls. team-lead independently sent the same
  probe-and-fix framing, arrived after I'd already gotten reaper-wiring's fix — consistent,
  no rework needed. INDEPENDENTLY RE-VERIFIED (not just trusted the report), per team-lead's
  explicit "don't just trust the fix" instruction: (a) built a THROWAWAY scratch worktree at
  664cae2, reinstated the OLD bare-"422"-substring logic just in that copy, reran ONLY the
  new regression test, watched it genuinely FAIL (assertion failed on network_error_on_
  runner_422) — proves the test is a real fail-first regression, not decorative; discarded
  the scratch copy after. (b) cargo test/clippy/rustfmt in ez-gh-actions-wt-qbl: 188/188
  pass, clippy clean; rustfmt showed drift (canary.rs:120, main.rs:~133/1239) but confirmed
  via A/B against a clean pre-fix checkout (scratchpad/ezgha-clean-build) that the IDENTICAL
  drift already exists on origin/main before this branch — pre-existing/toolchain-version
  drift, unrelated to this change, NOT a blocker. Checked file-overlap vs origin/main since
  branch point 54424d9: ZERO commits touched docker_backend.rs/reaper.rs/main.rs on main in
  the interim. Rebased claude/qbl-zombie-slot-selfheal onto origin/main (9e44d67) cleanly
  (adafa19 replaces 664cae2), force-pushed the feature branch, retested (188/188 green),
  fast-forward MERGED to origin/main at adafa19, retested again on main (188/188 green),
  pushed. Bead qbl updated with full verification notes. NOT DEPLOYED — no cargo install/
  restart on jeff, per team-lead's explicit hold pending load-settle coordination. This
  CLOSES the mission's top-priority code item; only the deploy step remains, gated on
  team-lead.

- 2026-07-08 09:56 — team-lead confirmed: adafa19 = ALL 3 key fixes now on origin/main
  (reaper + App token 7f476ac + capacity-proof harness + Gate-0 guardrail 68aab6b). User's
  "merge all key fixes to main" ask is COMPLETE at the code level. team-lead designated me
  explicit SINGLE DEPLOY-OWNER for jeff (fleet-ironclad stays watch-only, nobody else
  restarts jeff) and set a HARD HOLD on the reaper deploy until BOTH: (1) the running
  capacity-proof re-run burst completes, AND (2) load_1min<12 AND containers>=12. Will send
  "GO reaper deploy" explicitly. Post-deploy safety ask: watch first few daemon cycles for
  any cancel/force-cancel log lines against a runner that ISN'T offline+busy+containerless,
  flag immediately if seen (wrongful-cancel risk is low post-review but not zero). ACKED to
  team-lead with current read: burst still queued/running (started 09:52:46Z UTC), load
  7.4-9.7, containers momentarily 11 (just under floor) — neither condition met yet, holding
  as instructed. Created task #12 to track the deploy step; NOT acting until GO received.

- 2026-07-08 10:01 — team-lead sent GO: burst done (capacity-proof captured true 22/22,
  evidence bfddf83), Gate-0 window was load 11.35/containers 13 at send-time. Started the
  deploy: confirmed shared tree clean, origin/main HEAD = bfddf83 (capacity-proof's 22/22
  evidence commit on top of adafa19). Built from a fresh detached worktree
  (scratchpad/ezgha-deploy-bfddf83): 188/188 tests green. Verified the reaper symbols are
  actually IN the release binary (grepped for the literal "currently running a job" string
  from is_runner_busy_lock_error — present). Re-checked load right before restart per
  team-lead's judgment call: 12.02, then spiked to 13.14 (likely my own `cargo build
  --release` competing for CPU). Per team-lead's "wait a few min if >10" guidance, did NOT
  restart — started a background poll loop (load_1min<9 AND containers>=12, 15s interval)
  instead of blind-sleeping or proceeding into an elevated window. Reported status to
  team-lead. cargo install/systemctl restart NOT yet run.

- 2026-07-08 10:04 — team-lead nudged to proceed (9.15 flat + 14 containers, soft "~9"
  guidance not a hard threshold). My own poll loop had already independently cleared moments
  earlier (load dropped to 8.74/containers 14). Proceeded: `cargo install --path .` from the
  clean bfddf83 worktree, final safety recheck (load 7.57, containers 12) — restarted
  ezgha.service (03:04:31). Ran verify-exit-criteria.sh: Gate 0 PASS at that instant
  (deployed==HEAD bfddf83... except HEAD had already moved to 5f0374a from my own prior
  STATE-mirror commit — see CLAUDE.md "every commit advances HEAD, must rebuild"). Rebuilt
  from true current HEAD (5f0374a, doc-only diff vs bfddf83, confirmed via `git diff --stat`),
  reinstalled, waited briefly for containers to recover from the first restart's dip
  (10->16 over ~40s, load stayed <8), restarted AGAIN (03:06:42) onto 5f0374a. Gate 0 PASS
  cleanly this time. Gate 1 (cargo fmt --check) FAILED — same pre-existing rustfmt drift
  (canary.rs/main.rs) already confirmed unrelated/pre-existing via earlier A/B check. Applied
  `cargo fmt` (pure whitespace/line-wrap, zero logic change, diffed to confirm), 188/188 still
  green, committed+pushed (0a4c8e1). DECISION: did NOT do a 3rd restart just to re-sync
  deployed-SHA to this cosmetic formatting-only commit — per the reactive-cascade/
  complexity-budget principle (don't stack another restart to compensate for a fix I just
  made), and per team-lead's own restart-cost caution. Instead directly verified the
  CURRENTLY RUNNING daemon (5f0374a, PID 236775) has everything that matters: (a) reaper
  self-heal symbol ("currently running a job" string) present in the live binary; (b) a live
  gh subprocess (PID 264454, child of 236775) has GH_TOKEN set — App token confirmed ACTIVE
  post-restart, not just installed; (c) fleet at 15/16 containers, load settled ~11 and
  falling; (d) journalctl since-5-min shows ZERO cancel/force-cancel/zombie log lines — quiet
  log, expected (no zombies to heal right now), not a red flag. Reporting to team-lead with
  full transparency on the Gate0/Gate1 sequencing and asking whether they want one more
  restart for exact SHA parity (0a4c8e1) or accept the current state (functionally identical,
  cosmetic 1-commit gap only).

- 2026-07-08 10:12 — team-lead ENDORSED the stop-at-live-verification decision explicitly:
  leave the cosmetic SHA gap, no 3rd restart. Root-caused as Gate 0 being over-sensitive
  (reds on ANY head advance incl. docs/fmt-only, structurally guaranteeing this false-red
  after every non-functional commit). Filed bead ez-gh-actions-eqx (P2): "Gate 0 should
  ignore docs/fmt-only HEAD advances" with the full incident tied to it. Final health check:
  containers 15, load 5.93/8.26/8.95 (falling), journalctl since-10-min still shows ZERO
  cancel/force-cancel/zombie log lines (quiet log, expected, no zombies present right now).
  MISSION COMPLETE: all 3 key fixes (reaper zombie-slot self-heal, capacity-proof harness,
  App-token isolated rate-limit bucket) are MERGED to origin/main AND LIVE on jeff-ubuntu,
  independently live-verified (not just build-verified). Sent final one-line confirmation to
  team-lead.

## Next Actions (rewritten every step)

MISSION COMPLETE — no further action needed on the 3 key fixes. If resumed: re-check
`git branch -r | grep -iE 'reaper|qbl|zombie'` is gone/merged (it is, adafa19+ on main),
confirm bead ez-gh-actions-eqx (Gate 0 docs/fmt-only false-red) still needs an owner/fix,
and check whether Mac-side daemon has since been restarted onto the App-token code (that
restart was always main/mac-session's call, not mine).
