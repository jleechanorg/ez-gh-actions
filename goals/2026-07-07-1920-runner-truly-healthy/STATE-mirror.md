# Sidekick STATE — ez-gh-actions / runner-truly-healthy

Owner: sidekick2 (respawned 2026-07-07 ~13:05 PT after predecessor crash when /tmp was
wiped ~12:50 PT). This file is the DURABLE copy — mirrored to
/tmp/ez-gh-actions/sidekick/runner-truly-healthy/STATE.md but this repo copy is the
source of truth (commit it every update; /tmp is NOT durable on this host, proven
2026-07-07).

Mission: goals/2026-07-07-1920-runner-truly-healthy/{00-goal-definition,01-success-criteria,
02-exit-criteria-ironclad}.md. Ironclad E1-E5 = definition of done. Deadline 2026-07-08 07:20 PT.
Bead ez-gh-actions-9je is the resume pointer; keep it updated at same cadence as this file.

## Recovery findings (2026-07-07 13:00-13:15 PT)

- TaskList (#1-#8) was EMPTY on respawn — the task-tracker state did not survive the
  crash either (not just /tmp). Recreating tasks now; see "Tasks" section below.
- ezgha.service: healthy. Restarted intentionally by predecessor at 13:00-13:02 PT as
  part of its normal Gate 0 loop after committing ed5ae9a (mission docs) — NOT a crash
  (NRestarts=0, deliberate "Stopping ezgha.service" in journal). Fleet was mid-respawn
  when I first sampled (2/16 containers) but reached 13/16 within ~2 min — normal
  post-restart recovery, not a stuck failure. Colima healthy (16 CPU/32GiB/120GiB).
- Binary at HEAD ed5ae9a (Gate 0 current).
- Live doctor.sh snapshot at recovery: fleet 11 online/6 offline/17 busy (labels
  inconsistent right after restart — resampling needed once fleet settles); real-job
  proof on our fleet 2/6 (still below target); queue: **520 queued** (up from 456 at
  wipe time, up from 267 at mission start) — fresh queue tail p50=16.6m p90=25.3m
  **max=178.2m** (way over 20m threshold); 1 stale zombie >8h (id 28807865661, Green
  Gate, branch loadtest/fake-latency-harness, age 1.1d).
- **Queue is still climbing, not draining.** This is the top operational problem.

## Lane status (the 4 codex lanes predecessor dispatched ~12:xx PT)

- **lane-cg** (invariant monitor + doctor gate): branch `sidekick/lane-cg` — SURVIVED
  (branch object, not the /tmp worktree checkout). Real work: 560-line diff to
  `src/queue_monitor.rs` implementing a "queued-job idle-runner mismatch monitor" —
  this is directly the E1 automated-sampler deliverable. Last commit 2026-07-07
  12:51:28 PT (right at wipe time — process died mid/just-after commit). NOT YET
  MERGED to main. Action: recreate worktree, build+test, review diff, merge, Gate 0,
  push. HIGH PRIORITY — this is critical-path for E1.
- **lane-d** (ed8 churn root-cause): branch `sidekick/lane-d` — SURVIVED (branch only).
  Real work: `docs/ed8-fleet-churn-root-cause-20260707.md` (174 lines) + a 1-line
  `src/docker_backend.rs` change. Last commit 2026-07-07 12:50:59 PT. NOT YET MERGED.
  Action: recreate worktree, review the docker_backend.rs line change carefully
  (verify it's not a partial/broken edit), merge, Gate 0, push. Feeds E4's ed8
  root-cause requirement.
- **lane-f** (worldai Verdict Poll redesign + CI-check value audit): NO surviving
  process (was in a worldarchitect.ai worktree, not found among the ~50+ unrelated
  worktree_* dirs on this box — not worth the search cost, the PRs are the ground
  truth). CONFIRMED PROGRESS via merged PRs:
  - jleechanorg/worldarchitect.ai#8217 "remove Gate 7 Skeptic VERDICT poll from Green
    Gate" — MERGED 19:25:20Z. This is the E4 Verdict Poll fix.
  - jleechanorg/worldarchitect.ai#8218 "finish self-hosted-mikey codemod + confirm
    bead-id dedup guard" — MERGED 19:32:24Z.
  - jleechanorg/worldarchitect.ai#8214 "CI check value audit — 30-day census,
    real-catch vs noise classification, KEEP/TUNE/CUT verdicts" — OPEN, MERGEABLE,
    most checks still "None" (pending — queue backlog of 520 is why). This is the
    SC8 CI-value-audit deliverable. Action: no process needed, just needs the queue
    to drain enough for its checks to run, then merge. Monitor, don't respawn.
- **lane-h** (gitleaks across repos): NO evidence of any output anywhere (no branch,
  no worktree, no open/recent PR — the only gitleaks-tagged PRs found are from
  2026-06-19, unrelated). This lane's work was LOST — never got far enough to leave
  a durable artifact before the process died. Action: RESPAWN FROM SCRATCH.

## Unrelated but relevant discoveries (do not touch, or handle separately)

- `codex/hardening-bxy-fl0` branch in ez-gh-actions (worktree survived at
  ~/.config/superpowers/worktrees/ez-gh-actions/hardening-bxy-fl0, NOT under /tmp):
  5 unmerged commits from **2026-07-06 22:23 PT (yesterday)**, predates this mission.
  Maps to bead ez-gh-actions-jyb "execute ezgha hardening queue" (in_progress).
  Content: docker backend slot/timeout hardening, selftest evidence requirement,
  doctor queue-health evidence-awareness, faster refill under churn, independent
  systemd watchdog heartbeat. Valuable and orthogonal to the 4 lanes — flagged for
  merge but on a separate track (owner: whichever session owns ez-gh-actions-jyb;
  verify no conflict before touching).
- PR jleechanorg/ez-gh-actions#16 (open, human-authored jleechan2015, not a bot):
  Playwright Chromium+WebKit deps baked into Dockerfile.runner. NOT part of this
  mission — multi-session repo rule applies, leave it alone unless it blocks Gate 0.
- codex process pid 15572/25048 running in ~/projects/worktree_fix_ci (worldarchitect.ai
  worktree) is on branch fix/7887-cc-finish-level-commit / PR #7888 (character-creation
  modal fix, "antig" tagged) — CONFIRMED UNRELATED to this mission, a different
  AO/antig worker sharing the box. Do not adopt or interrupt.
- Dozens of other worktree_* dirs under ~/projects belong to the general AO/antig
  worker fleet, not this mission. Ignore unless named explicitly for a lane.

## Standing rules (unchanged from predecessor's brief — repeating for durability)

COMMIT OFTEN: push after every green unit, never >30 min uncommitted. Gate 0 loop
after any ez-gh-actions commit: cargo test → cargo install --path . → systemctl
--user restart ezgha.service → ./docs/verify-exit-criteria.sh. Sidekick holds the
single-writer lock on install/restart/config.toml; sub-agents implement in worktrees,
sidekick deploys. Commit subjects: claude/sonnet: (sidekick) / codex/<model>: (codex
lanes). Never `git add -A`. `git status -s` first, leave sibling WIP alone. `br` CLI
only. Slack posts prefixed [AI Terminal: ez-gh-actions]. GitHub run mutations only via
sanctioned scripts (dry-run→--apply) or individually-logged stuck-run cancels.
Adversarial verify (codex skeptic, evidence-only) before any SC sign-off. No token/
webhook rotation. Never touch ~/.bashrc or ~/.config/ezgha/config.toml casually.
Deadline 2026-07-08 07:20 PT.

## Progress update (2026-07-07 13:17 PT)

1. [DONE] TaskList recreated (tasks #1-#8, tracker was empty on respawn).
2. [DONE] lane-cg salvaged: worktree at ~/projects/ez-gh-actions-wt-lane-cg (now
   removed after merge), cargo test 154 passed, merged to main (540b715), Gate 0
   loop run, pushed.
3. [DONE] lane-d salvaged: worktree at ~/projects/ez-gh-actions-wt-lane-d (now
   removed after merge), docker_backend.rs line confirmed unchanged relative to
   merge-base (main's --cpus .2 fix preserved), merged to main (655d645), pushed.
4. [DONE] Sibling gemini/gemini-3.5-flash session pushed 3 commits concurrently
   (a8bd3df: docker_backend reaper fix for mismatched runner names) while I was
   merging — caught via `git push` rejection, merged cleanly (docker_backend.rs
   auto-merged, only .beads binary conflicts, resolved via --ours + br sync
   --import-only --force, the established pattern from c0cc81d). 155 tests pass
   post-merge. Pushed as 73e275d.
5. [DONE] lane-h respawned: fresh codex exec background worker launched in a
   STABLE worktree (~/projects/ez-gh-actions-wt-lane-h, NOT /tmp this time) via
   Bash run_in_background — first two attempts using manual nohup/disown died
   when the parent tool call completed (exit 144), tool-native backgrounding is
   what actually survives. PID 161628 confirmed alive after launch. Scope: gitleaks
   sweep of ez-gh-actions + worldarchitect.ai, tracked-file secret cleanup only (no
   history rewrite), add .gitleaks.toml + CI wiring to both repos. Full prompt with
   standing rules at /tmp/.../scratchpad/lane-h-prompt.txt (also worth copying into
   the repo if this needs to survive another /tmp wipe — TODO for next update).
6. [DONE] Queue-growth root cause (task #5): NOT a runaway loop. 503/507 queued
   runs are in distinct branch+workflow groups (only 4 superseded-dupes). 53
   concurrent worktree_* AI-agent dirs on this box explain the organic demand.
   Estimated 3-10x gap between arrival rate (~16-32 self-hosted jobs/min) and fleet
   completion capacity (~2.3-4.6 jobs/min). Written up as a capacity finding, NOT a
   fixable bug, per E5 failure-honesty clause: goals/.../03-capacity-finding-queue-
   growth.md, commit 25c9c97, pushed.
7. [NOT STARTED] E1 daemon-native sampler (task #6) — lane-cg's queue_monitor.rs
   changes need review to determine if they already implement E1's automatic-
   caller requirement, or if that's still outstanding. THIS IS NOW THE TOP PRIORITY
   — E2's 3hr window can't start counting without it.
8. [NOT STARTED] PR #8214 (lane-f) monitoring — still open, still pending CI, not
   re-checked since initial recovery scan.
9. [NOT STARTED] codex/hardening-bxy-fl0 merge (separate track, ez-gh-actions-jyb)
   — flagged, not yet actioned.

## URGENT SECURITY FINDING (2026-07-07 13:20 PT, flagged to main immediately)

lane-h's gitleaks sweep found a REAL, live-looking GCP service-account private key
checked into jleechanorg/worldarchitect.ai:roadmap/agent_001_command_frequency.json
(50 occurrences, first committed 2025-09-22 commit 6e4aa9a #1711 — exposed ~10
months). project_id=worldarchitecture-ai, key ID prefix `052f6b1a94...` (full PEM
private key NOT reproduced anywhere in this log). Verified independently (grep,
not just trusting the sub-agent), NOT reproduced, NOT rotated, NOT history-
rewritten. lane-h redacted the tracked-file occurrences in a new commit (verified:
0 remaining occurrences of the key material in the working tree, replaced with
`[REDACTED: captured service account credential removed 2026-07-07]`).

Main independently verified the key is live: service account
dev-runner@worldarchitecture-ai.iam.gserviceaccount.com, roles include
resourcemanager.projectIamAdmin, firebase.admin, run.admin, storage.admin
(takeover-class). 30-day admin-activity logs show ZERO use of this specific key
(serviceAccountKeyName filter) — no misuse evidence, disable is low-risk. User
notified (terminal + mobile push) with a one-command disable option; the
disable/rotate decision correctly stays with the user, not any agent.

**Follow-up sweep (2026-07-07, this session, per main's instruction) — scope now
closed:** grepped the exact key-ID prefix across all ~50+ local repo clones under
~/projects: every hit besides the one already-fixed tracked file is either (a) the
SAME tracked file in another worktree checkout of the identical worldarchitect.ai
repo (resolves automatically once those worktrees sync with the fixed main), or
(b) 6 UNTRACKED local files under docs/genesis/processing/... (final_analysis.json,
progress_020/023.json, extraction_progress_008/010.json, chunk_001.json) —
confirmed via `git ls-files --error-unmatch` NOT tracked by git, so out of the
"tracked-file secret cleanup" scope and not a repo-hygiene issue (though still
plaintext-on-disk locally; moot once the key is rotated). Also ran a broader
`private_key_id`/`BEGIN PRIVATE KEY` sweep across all OTHER distinct (non-
worldarchitect.ai-duplicate) local repos (ez-gh-actions, beads-rs, dark-factory,
mcp_mail, orch_cmux_ubuntu, orch_llm-wiki, orch_worldai_claw, user_scope,
worldarchitect-2step-wizard) — three hits, all confirmed FALSE POSITIVES on
inspection: dark-factory's collect_repro.py (redaction-scrubbing code itself, a
pattern tuple used to detect/scrub secrets, not an embedded key), orch_llm-wiki's
service_account_loader.py (legitimate app code reading GOOGLE_PRIVATE_KEY from an
env var, with truncated example text in comments), and worldarchitect-2step-
wizard's .env.example (a template with `YOUR_PRIVATE_KEY_CONTENT_HERE` placeholder
and a truncated example value). **No additional distinct secret exposure found.**

## CRITICAL: host reboots caused by ezgha's own restart discipline (2026-07-07 13:35 PT)

A sibling Jeff-Ubuntu crash-investigation sidekick left a coordination note
(goals/.../04-coordination-crash-mission.md, committed bf7b90d) with a major
finding: the box rebooted twice today (00:48, 12:51 PT) via a clean watchdog(8)
self-shutdown (/etc/watchdog.conf max-load-1=24 on this 32-thread box).
**Simultaneous respawn of many ezgha runners is what trips it** (00:47 hit
loadavg 71 on a full cold respawn of all 16; 12:50 trip was loadavg 25-28).
**The 12:51 PT reboot is the exact moment the predecessor sidekick died** --
what was assumed to be an independent "/tmp wipe" was very likely this host
reboot. Root cause of root cause: Gate 0's "restart after every commit"
discipline is what's been tripping this watchdog.

Mitigation adopted for the rest of this session: check `docker ps` container
count + `uptime` load average BEFORE every `systemctl --user restart
ezgha.service`; avoid restarting when it looks like a mass cold respawn would
be needed (that's the 71-loadavg failure mode) -- a reconciliation restart
against an already-mostly-healthy fleet is much lower risk. Verified safe
during the E1 sampler deploy below (load stayed ~4-5 throughout, nowhere near
24). Cannot fully avoid restarting the ezgha process itself for code deploys
(Gate 0 requires the new binary loaded) -- this is a structural tension between
Gate 0 and host stability that should get a durable fix (e.g. a staggered-
respawn mode in docker_backend.rs) if the mission continues past this window.
Escalated to main immediately via SendMessage.

## E1 sampler: IMPLEMENTED DIRECTLY (not via codex), merged, deployed

Per main's explicit instruction ("Codex quota being down does NOT block E1 --
implement the daemon-native sampler YOURSELF now"), built this directly in
Rust rather than waiting for the Codex usage-limit reset:
- `InvariantSamplerConfig` in config.rs: new `[invariant_sampler]` section,
  `enabled` default true, `check_interval_seconds` default 240s (safety margin
  under the 5min ceiling), `validate()` enforces 1..=300s bound so the E1
  cadence requirement can't be misconfigured away.
- `InvariantSamplerState`/`InvariantSample`/`combine_invariant_sample`/
  `classify_inv1_failure`/`append_invariant_sample` in queue_monitor.rs:
  evaluates INV-1 (busy>=22 fleet-wide OR queued_jobs==0) and INV-2 (oldest
  queued/running job <=20.0min, inclusive boundary) across
  `MONITORED_INVARIANT_REPOS` (worldarchitect.ai + ez-gh-actions, hardcoded --
  a fixed mission requirement, not a per-deployment config knob). Reused
  lane-cg's FleetRunnerStats/QueueStats infra rather than duplicating GitHub
  API calls; fleet stats fetched once per tick and shared across both
  monitored repos for API-rate-limit hygiene (a live concern -- Gate 4 is
  currently hitting a secondary GitHub API rate limit, separate from the
  earlier saturation-based failure).
- Judgment call: a stale (>8h) queued zombie still counts toward
  `oldest_queued_job_min` for E1's strict duration invariant, even though
  `queue_stats()` deliberately excludes it from the unrelated starvation-alert
  metric. `inv1_fail_class` priority when INV-1 fails: missing-registration
  (not even registered) > offline-respawning (registered but not online, the
  ed8 churn pattern) > genuinely-idle (registered+online but not picking up
  work).
- Wired into main.rs's daemon serve loop tick alongside the existing
  queue_monitor/canary ticks -- automatic caller, satisfies E1's "not
  manual-invocation-only" requirement.
- 15 new unit tests (inv1/inv2 boundary conditions including the exact-20.0min
  inclusive edge, cross-repo max combination with stale-zombie ages,
  classifier priority ordering, exact 9-field JSONL schema, alert body
  content). 166/166 total tests pass.
- Merged to main (646edb7, after a cargo-fmt fixup caught by Gate 1), Gates
  0-3 verified PASS after deploy (Gate 3: 16/16 containers, full capacity).
  Gate 4 fails on the GitHub API secondary rate limit noted earlier, not a
  regression from this change.
- Daemon restarted at 13:42:58 PT with check_interval_seconds=240 -- first
  tick fired ~13:46:58 PT but the sample never landed (checked directly);
  journal showed the tick was mid gh-API-transient-failure retries at that
  moment, most likely the same secondary rate limit affecting Gate 4.
  Confirmed by design (and now also unit-tested,
  `invariant_sampler_tick_errors_are_non_fatal_and_write_no_sample`) that a
  failed tick writes NO line at all -- UNKNOWN, not a violation -- per main's
  explicit design requirement (burst rate limits must never poison E2's
  3-hour zero-violation count). Added a code comment explaining this
  property at the `?` in `maybe_sample`. 167/167 tests pass; merged
  (37700d6), redeployed with load/container check before each restart
  (stayed 3.5-5.5 throughout, no watchdog risk). Also created P1 bead
  ez-gh-actions-po2 (durable respawn-pacing fix in docker_backend.rs, per
  main's directive) so this doesn't rely on session-level operator
  discipline.
- Daemon restarted again at 13:47:49 PT for the above fix -- next tick
  expected ~13:51:49 PT. Verification in progress (Monitor task bd7pfq3zj).

**TASK #6 COMPLETE (2026-07-07 13:56 PT).** First real sample confirmed landed
and verified directly (not just via main's relay):
`{"ts":1783457458,"busy":19,"registered":19,"queued_jobs":1290,"oldest_queued_job_min":72.05,"oldest_running_job_min":0.0,"inv1":false,"inv2":false,"inv1_fail_class":"missing-registration"}`.
Classifier correctly identified missing-registration (19/22 registered) as the
INV-1 failure mode -- matches the ed8 churn pattern this mission already
root-caused. Updated goals/.../03-capacity-finding-queue-growth.md with the
corrected JOB-level demand number (1290 queued self-hosted jobs, not the
~509-520 run-level figure used in the original analysis) -- this is now the
authoritative demand metric going forward, superseding run counts per the
goal doc's own original warning about run-object counts being misleading.

**E2 window status**: cannot start accumulating a green streak yet -- this
first sample already violates both INV-1 and INV-2. E2 requires 3 CONTINUOUS
hours with ZERO violated samples; the window start timestamp will be logged
here the moment a qualifying all-clear run begins, not before. Given the
capacity finding (task #5) already established organic demand structurally
exceeds fleet capacity much of the time, a clean 3-hour window may only be
achievable during a genuine demand lull -- this is expected, not a bug in the
sampler.

**Ongoing per main's direction**: watching samples over the coming hour for
cadence (~240s), confirming UNKNOWN handling holds on any further rate-limit
hits (no spurious pass/fail rows), and Slack alert delivery + cooldown
behavior now that essentially every sample is currently a violation (cooldown
must prevent alert spam on the same event_key). Codex quota returns ~14:52 PT
-- dispatch ez-gh-actions-po2 (respawn-pacing) then, it's the biggest lever
for closing the missing-registration/offline-respawning share of INV-1
failures.

**Design finding flagged to main (13:59 PT)**: a single invariant-sampler tick
can take minutes (observed: alert fired 263s after the sample's own `ts`)
because `fetch_queue_snapshot_with_fleet` makes one `gh api` call per queued
run to fetch job-level data -- with queued_jobs=1290 this is expensive and
likely contributes to the ongoing GitHub secondary rate limit. Real-world
cadence may run closer to back-to-back than the nominal 240s during
high-queue periods. Not fixing preemptively; flagged for main's call on
priority. Also: ezgha.service restarted again 13:56:51-52 PT, not initiated
by this session (no new commits, no systemctl call from here) -- reset the
sampler's tick timer, next sample now expected ~14:00:52 PT. Persistent
Monitor (task b0cjx61fg) watching for new lines in invariant_history.jsonl.

**Main's decisions on both flags (2026-07-07 14:01 PT):**
1. Sampler cost — approved as a targeted (not speculative) fix: cap job
   enumeration to the oldest ~50 queued runs per repo (INV-2 stays exact since
   the oldest job lives among the oldest runs; add `queued_jobs_capped` to the
   schema), and share one snapshot per repo per tick between queue_monitor and
   the invariant sampler instead of independent fetches. Bead created:
   ez-gh-actions-wms. Dispatch to codex at quota return (~14:52 PT) alongside
   ez-gh-actions-po2 -- both attack the same GitHub-API-rate-limit pressure
   from different angles (this one: sampler-induced load; po2: JIT-registration
   burst that trips the watchdog). Not hand-optimizing before then.
2. 13:56 restart root-caused: clean deliberate systemd stop/start by ANOTHER
   agent session (Gate 0 habit after a pull; HEAD was unchanged so it wasn't
   commit-triggered) -- not watchdog, not a crash. Durable fix landed NOW
   (docs-only): added a load/container check before `systemctl --user restart
   ezgha.service` to CLAUDE.md's Gate 0 section (step 3, new) and one line to
   `.claude/skills/ezgha-doctor/SKILL.md` -- "if load_1min > 12 or containers
   < 12, DO NOT restart, wait for reconciliation." This protects every
   session, not just this one, until po2 lands.

**Dogfooding the new rule while deploying it (14:01-14:0x PT)**: container
count was at 4 (well below the new 12 threshold) when I went to deploy this
very docs commit -- correctly did NOT restart, waited instead. Investigated
whether this was a new problem: doctor.sh shows `ensure_count failed
occurrences in last 3 min: 0` (not failing/retry-looping) and 5/6 recent
selftest runs succeeded on our fleet, consistent with known slot-reconciliation
churn under heavy queue load (offline/busy slots that can't be safely
released yet) rather than a new crisis -- matches this repo's own documented
Gate-3-low recipe. Waiting for reconciliation in the background before
completing this deploy's Gate 0 loop.

## Other task check-ins (2026-07-07 13:45 PT, PR #8214 re-checked 14:00 PT: 14 SUCCESS / 5 PENDING, nearly green)

- Task #4 (PR #8214): incremental progress, 7 checks SUCCESS now (was 3),
  11 still PENDING (was 15) -- queue slowly processing it. Still not
  mergeable-green; continue monitoring.
- Task #7 (codex/hardening-bxy-fl0): re-checked, still has active uncommitted
  sibling WIP (build.rs modified, systemd/ untracked dir) -- still correctly
  left untouched.

**lane-h task #3: COMPLETE.** Final state: ez-gh-actions branch `sidekick/lane-h`
merged to main (commit 91d9289) and pushed — adds `.gitleaks.toml` (extends default
rules) + `.github/workflows/gitleaks.yml` (current-tree scan on every PR + push to
main, self-hosted runner, 10min timeout), 0 findings on this repo's current tree and
full history. worldarchitect.ai side: branch `sidekick/lane-h-gitleaks` pushed, PR
jleechanorg/worldarchitect.ai#8226 opened (not merged — human merges PRs in other
repos per standing rules) with the tracked-file redaction + `.gitleaks.toml` +
gitleaks wired into the existing `bead-jsonl-sort-check.yml` (renamed
`repository-hygiene`) workflow so it runs on every PR without adding a new job.
lane-h's own report: `docs/gitleaks-sweep-20260707.md` (merged into ez-gh-actions
main). Ambiguous item lane-h flagged for human review: Firebase web API keys in
worldarchitect.ai were allowlisted as public client config rather than redacted
(standard/correct treatment, but a human may want to double check GCP/Firebase key
restrictions). Worktrees cleaned up post-merge.

## E1 sampler status (2026-07-07 13:19 PT)

Confirmed via code review lane-cg's merged queue_monitor.rs work does NOT satisfy
E1: it writes to the existing alerts.jsonl mechanism (idle-runner mismatch alert),
not the required ~/.local/state/ezgha/invariant_history.jsonl with the
{ts,busy,queued_jobs,oldest_queued_job_min,oldest_running_job_min,inv1,inv2} schema.
Real gap remains. Dispatched a codex background worker in worktree
~/projects/ez-gh-actions-wt-e1 (branch sidekick/e1-sampler) with a detailed brief
reusing existing QueueStats/FleetRunnerStats infra -- FAILED IMMEDIATELY on launch:
Codex CLI usage limit exhausted ("try again at 2:52 PM PT", ~90 min from now as of
this writing). No partial commits landed (clean worktree). RETRY after 2:52 PM PT —
worktree + prompt file preserved at /tmp/.../scratchpad/e1-sampler-prompt.txt (also
worth copying that prompt into the repo/STATE so it survives another /tmp wipe).

## Next actions (in order)

1. WAIT for Codex usage limit reset (~2:52 PM PT) then relaunch the E1 sampler
   worker in ~/projects/ez-gh-actions-wt-e1 (branch already created, prompt file
   preserved).
2. Continue monitoring lane-h in the background (still has quota, actively
   redacting the GCP key exposure + building gitleaks config/CI wiring); check
   its output file periodically, review its branch/PR before merging.
3. Re-check PR #8214 CI status (task #4, not yet re-checked since initial recovery
   scan).
4. Re-run doctor.sh / verify-exit-criteria.sh for a clean baseline sample once
   fleet settles.
5. Given Codex quota is now a scarce/limited resource until 2:52 PM, avoid
   launching further codex background workers in the meantime unless truly
   necessary; use direct investigation/scripting instead where possible.

## INCIDENT: E1 sampler starved ensure_count, fleet drained to 0 -- fixed live (2026-07-07 14:05-14:18 PT)

**What happened**: while dogfooding the new restart-safety rule (containers at
4, correctly did not restart), containers kept draining 4->1->0 with a live
`gh api .../actions/runs/.../jobs` call actively in-flight (not hung). Root
cause: the daemon's serve loop is single-threaded and sequential (ensure_count
-> queue_monitor tick -> invariant_sampler tick -> canary tick -> sleep). Both
the E1 sampler AND the pre-existing (lane-cg) queue_monitor tick made one gh
api call per queued run to fetch job-level data; at queued_jobs~1290 this took
long enough that ensure_count never got back to the top of the loop to refill
missing runner slots. Ephemeral runners exit after one job by design, so with
no refill, the fleet silently drained toward zero. This was a REAL production
incident, not a theoretical concern -- confirmed via `registered` dropping
19->8 between consecutive samples.

**Immediate response** (not waiting for codex quota return at ~14:52 PT, since
this was active harm, not speculative optimization):
1. Restarted the service (load was low, 1.5-2.3, safe exception to the new
   load-check rule -- that rule's intent is "don't trigger unnecessary mass
   respawns when things are fine," not "let the fleet decay to zero while
   something is actively broken").
2. Added `[invariant_sampler] enabled = false` to the live config.toml as an
   immediate stopgap, restarted again (load still safe) -- fleet recovered to
   14-15/16.
3. Discovered the SAME starvation recurred with only queue_monitor's
   pre-existing (unmodified by my earlier work) tick active -- confirmed via
   `ps` showing the gh api call's parent PID was the ezgha daemon. Added
   `[queue_monitor] enabled = false` too as a second stopgap, restarted,
   fleet recovered to 15/16.
4. Implemented the real fix myself (not codex, given the urgency) in worktree
   `sidekick/sampler-cap`: new `fetch_capped_queue_snapshot(repo, fleet, cap)`
   reads page 1 for `total_count`, and only walks backward from the LAST page
   (GitHub's default order is newest-first, so oldest runs are on the last
   page) when total exceeds `INVARIANT_JOB_ENUMERATION_CAP=50`, instead of
   fetching every page from the front. INV-2 stays exact since the oldest job
   necessarily lives among the oldest runs. Added `queued_jobs_capped: bool`
   to the schema so a capped `queued_jobs` reads honestly as a lower bound.
   **Extended the same fix to queue_monitor.maybe_check()** once the second
   starvation was confirmed -- removed the now-fully-dead uncapped
   `fetch_queue_snapshot`/`fetch_queue_snapshot_with_fleet` (0 remaining
   callers, 0 warnings). 168 tests pass (1 new: capped-flag propagation).
5. Merged to main (commits 1a97b28, ec8127c -> merge b0a29ae, pushed), Gates
   0-3 verified PASS, re-enabled both monitors in config.toml, redeployed.

**Verified fixed, live**: samples now land ~166s apart (vs the single-tick
263s+ delay observed before the fix, on TOP of the 240s interval) with
`queued_jobs_capped: true` and a correctly-preserved `oldest_queued_job_min`
(93-95min, matching the real oldest outlier). Fleet recovered to 18-21/22
registered across the post-fix samples -- healthier than any pre-incident
reading. Background Monitor (task bdo79oji3) watching for containers<10 or
load>15 as an ongoing safety net.

**Scope note for bead ez-gh-actions-wms**: originally scoped by main to "the
E1 sampler," but the SAME mechanism in the pre-existing queue_monitor tick was
independently causing the identical failure at the current queue size --
already fixed for both in this pass; the bead's remaining scope (sharing one
snapshot per repo per tick between the two monitors, to avoid double-fetching
worldarchitect.ai) is now a pure efficiency follow-up, not an urgency item,
since both paths are already individually capped and safe. Can still go to
codex at quota return as originally planned.

**5 Whys** (why did this reach production before being caught): (1) the E1
sampler was designed and unit-tested against small hand-built fixtures, never
against the live queue's actual size: (2) because the queue size (1290 jobs)
grew organically during the same session the sampler was built in, so there
was no "before" baseline at that scale to test against; (3) because the
capacity finding (task #5, ~13:14 PT) that first measured a large queue
predates the sampler (~13:50 PT) but its implication for a NEW per-tick
fetch's cost wasn't cross-referenced during design; (4) because the design
brief (mine, to codex, then adapted for direct implementation) focused on
INV-1/INV-2 correctness and didn't ask "what does this cost at the queue
sizes we already know exist"; (5) root fix beyond the immediate cap: any
future per-tick GitHub API work in this daemon should be sized against the
CURRENT live queue depth (`doctor.sh` section 8 / the capacity finding doc)
before merging, not just unit-tested in isolation -- worth adding as a
CLAUDE.md reminder if this pattern recurs.

## Follow-up: structural time-budget fix (per main's directive, 2026-07-07 14:2x-14:33 PT)

Main correctly flagged that the job-enumeration cap only bounds TODAY's known
queue size (1290 jobs) -- it doesn't stop the failure CLASS: any future
expensive per-tick monitor work (a new checker, a bigger queue, a slower API
day) could reintroduce the identical starvation silently. Implemented the
requested structural fix: `queue_monitor::SERVE_LOOP_TIME_BUDGET` (75s),
computed from a `loop_start: Instant` captured once at the top of main.rs's
serve loop and threaded down to both `QueueMonitorState::maybe_check` and
`InvariantSamplerState::maybe_sample` (sharing ONE budget across both ticks
in the same iteration, not 75s each). `enumerate_jobs_within_budget` -- a new
generic, network-agnostic helper -- bails out of per-run job enumeration
(queued AND in-progress) the moment `Instant::now() >= deadline`, marking the
result `capped=true` (reusing the existing lower-bound signal rather than
inventing a separate "unknown" state, since budget-triggered partial
enumeration has identical semantics to size-triggered capping). Guarantees
`ensure_count` is reachable at least once per serve-loop iteration regardless
of queue depth or API latency.

4 new regression tests: (1) deadline already in the past -> zero fetches,
zero real time; (2) **the literal "fake a slow fetch" test main asked for**
-- 1000 synthetic items at 5ms each (5s total) against a 30ms budget, asserts
it does NOT process all 1000 (this is the actual regression guard: if
someone removes the deadline check, this test starts taking ~5s instead of
~30ms and failing the "must not process all" assertion); (3) normal
completion when the deadline is far off. 171/171 tests pass total. Merged
(051a7a2 -> merge 3429819), pushed. Also added the EXCEPTION language main
requested to CLAUDE.md's Gate 0 rule: "low load + a draining fleet with a
live in-flight gh api call means the loop is stuck, restart IS the
remediation."

**Confirmed both of main's checks**: (1) config.toml stopgaps
(`invariant_sampler.enabled`/`queue_monitor.enabled`) were both restored to
`true` when the cap fix redeployed earlier -- verified directly, no stale
disable flags left behind. (2) `invariant_history.jsonl` captures the full
drain-and-recovery arc in E1's own data, worth keeping as a case study:
```
ts=1783457458 busy=19 registered=19 queued_jobs=1290                  (healthy, pre-incident)
ts=1783458054 busy=8  registered=8  queued_jobs=1246                  (DRAIN CAUGHT LIVE)
ts=1783459044 busy=21 registered=21 queued_jobs=78  capped=true       (recovering, cap fix live)
ts=1783459210 busy=18 registered=18 queued_jobs=87  capped=true
ts=1783459328 busy=16 registered=16 queued_jobs=88  capped=true
ts=1783459606 busy=19 registered=19 queued_jobs=97  capped=true
ts=1783459902 busy=16 registered=16 queued_jobs=83  capped=true       (stable, time-budget fix live)
```
`inv1_fail_class="missing-registration"` throughout (correctly classified --
demand exceeds the 22-runner capacity per the earlier finding, independent of
the incident). This is E1 catching and characterizing a real production
incident in its own designed-for-this-purpose data, which is itself a form
of validation that the sampler works as intended.

## E2/SC4 status readout (2026-07-07 14:35-14:40 PT) -- baseline for the final validator

Per main's request, a full readout of `~/.local/state/ezgha/invariant_history.jsonl`
as it stands right now (9 samples, spanning the incident + both fixes):

**Sample count**: 9 total.

**Cadence (delta between consecutive samples, seconds)**: 596, 990, 166, 118,
278, 296, 262, 172. The first two large gaps (596s, 990s) are NOT missed
ticks -- they correspond exactly to the incident window (drain + the several
deliberate restarts while isolating/fixing it via config stopgaps). Excluding
those two, the remaining 6 deltas (118-296s, avg ~215s) are consistent with
the nominal 240s `check_interval_seconds`, with variance explained by
external restarts (from other concurrent sessions running their own Gate 0
loops) resetting the in-process tick timer, not by the sampler itself being
slow post-fix. **Verdict: cadence is healthy post-fix.**

**INV-1/INV-2 pass/fail/UNKNOWN breakdown**: INV-1 fail=9/9, INV-2 fail=9/9,
0 samples with both passing (no all-clear sample yet -- expected, since the
mission's own capacity finding (task #5) already established organic demand
structurally exceeds the 22-runner fleet much of the time). UNKNOWN (API
error, no line written) count cannot be directly measured from the JSONL by
definition -- absence of a row IS the unknown state -- but the two large
inter-sample gaps above are the observable proxy, and both are attributable
to known restarts, not silent API failures. `queued_jobs_capped=true` on 7/9
samples (the two `false` samples are the two pre-cap-fix incident samples,
where the queue was small enough at THAT queue depth reading to not need
capping, or predate the cap existing at all).

**inv1_fail_class histogram**: `missing-registration`: 9/9, 0 other classes
observed. This tracks the mission's ed8 finding (JIT deregister/respawn
churn keeps a few runners perpetually unregistered) plus, for the incident
window specifically, the fleet-drain itself.

**Slack delivery verification** (per main's ask, "like you did for SC1"):
- alerts.jsonl: 8 of 9 violated samples produced an `invariant.violation`
  CRITICAL entry (one, ts=1783459606, was correctly cooldown-suppressed --
  see below). journalctl shows ZERO `slack alert send failed` errors across
  the entire window (45+ min, 8 send attempts) -- the delivery ATTEMPT is
  clean.
- Cooldown mechanism verified working correctly in the one case where a
  no-restart window existed: sample ts=1783459606 (14:26:46 PT) got no
  alert because the prior successful alert was at 14:22:49 PT, only 237s
  earlier -- well inside the 900s `alert_cooldown_secs` default, and
  journalctl confirms no service restart happened in that window (so the
  in-memory cooldown tracker was intact). All the OTHER cases where alerts
  fired despite short gaps are explained by intervening restarts resetting
  the in-memory `alert_state()` HashMap (a `OnceLock` inside the process --
  does not persist across restarts). **Finding, not a bug**: cooldown works
  correctly within a continuous process lifetime; a restart-heavy session
  (like today's) will see more alerts than the configured cooldown alone
  would suggest, since each restart forgets the last-sent timestamp for
  every event_key. Worth knowing for interpreting alert volume during any
  future incident response, not necessarily worth "fixing" (persisting
  cooldown state to disk trades simplicity for surviving restarts that are
  themselves supposed to be rare).
- **Pending user confirmation (not "unresolved")**: could NOT independently
  verify the message actually rendered in the Slack channel via the
  `mcp__slack__conversations_history` tool. Checked all 5 channels this
  session has membership in (#all-jleechan-ai, #worldai, #ai-general,
  #ai-slack-test, #hermes-pc) plus a channel-list search for
  ezgha/gate/runner/alert-named channels -- none show any ezgha-originated
  message (they're all hermes/agento/AO gateway traffic, unrelated). This
  means either the webhook posts to a channel this MCP session isn't a
  member of (most likely, since incoming webhooks bind to a fixed channel
  chosen at creation time, independent of app/bot channel membership), or
  delivery is silently failing despite no error being logged. Given zero
  logged send errors and a previously-established SC1 proof (per main's
  earlier context, "DONE and proven... visible in channel"), the balance of
  evidence favors successful delivery to a channel outside this session's
  visibility. **Per main: the user has been asked to glance at the webhook
  channel for `[ez-gh-actions:*]` messages** -- one human glance closes this
  evidence gap; status is pending-user-confirmation, not an open unresolved
  finding.

## 30-min doctor.sh resample (2026-07-07 14:41 PT) -- healthiest reading this session

- Fleet: 16/16 containers running, 20/20 registered runners ONLINE (0 offline)
  -- best SC6 fleet-integrity reading of the entire mission so far.
- Real job-execution proof (Gate 7): **6/6** last selftest runs succeeded on
  our own fleet (ez-runner-c-*) -- first perfect 6/6 reading; earlier samples
  this session ranged 2/6-5/6 with some landing on canary/mac runners instead.
- `ensure_count failed occurrences in last 3 min: 0` -- confirms the
  time-budget + cap fixes are not interfering with normal refill.
- Queue (SC4): 412 queued total (down from ~500+ earlier, still far above
  healthy), 0 stale zombies currently flagged, fresh queue tail
  p50=116.3m p90=116.9m **max=278.2m** -- still badly exceeds the 20m
  threshold. Oldest offender unchanged from earlier samples: run
  28884233335 "Green Gate" on branch integrate-after-runnner-hardening-
  2026-07-05, now 278.2m old -- this looks like a genuinely stuck/abandoned
  branch run rather than fresh organic queue pressure, worth a
  targeted look (individually-logged stuck-run cancel, per sanctioned levers)
  separate from the broad capacity finding.
- PR #8214 (task #4) re-checked: **17 of 19 checks SUCCESS, only 2 PENDING**
  (Green Gate Precheck, Directory core-tests) -- up from 14/19 at last check.
  Very close to mergeable-green. **Correction per main: I will NOT merge this
  myself when green** -- worldarchitect.ai merges are human-approval-only
  (the earlier 8217/8218 merges are already flagged as an anomaly). When
  fully green, message main with the URL and "READY TO MERGE"; main has
  already asked the user for the decision.

## E3 cancellation ledger

- **Run 28884233335** (Green Gate, branch `integrate-after-runnner-hardening-
  2026-07-05`, queued since 2026-07-07T17:03:07Z, ~278min old at time of
  action) -- verified genuinely abandoned: `git fetch origin
  integrate-after-runnner-hardening-2026-07-05` in the local worldarchitect.ai
  clone returned "couldn't find remote ref" -- **the branch no longer exists
  on the remote at all**, stronger evidence than a sibling-activity check.
  Reason class: abandoned-branch queued run, source branch deleted, no path
  to ever complete. Pre-authorized individually-logged stuck-run cancel per
  standing user directive.
  - Action: `gh run cancel 28884233335` (14:47 PT) -- API accepted (no
    error), then `gh api -X POST .../cancel` again via the exact method
    `scripts/cleanup-stuck-runs.sh` uses (14:48 PT) -- also accepted.
  - **Outcome: NOT achieved.** After 2+ minutes of polling, `status` remained
    `queued` both times. Tried `gh run delete` as a fallback -- failed with
    the documented HTTP 403 ("Could not delete the workflow run"), consistent
    with this repo's own known zombie-delete-requires-non-queued-state
    pattern (bead/commit d105dc4), except this run is UNDER the 8h zombie
    threshold (only ~4.6h old) so it wasn't expected to hit that exact path.
  - **Honest status: cancellation ATTEMPTED via both sanctioned methods, NOT
    confirmed successful.** This run may be in a genuinely stuck GitHub-side
    state (never dispatched to any runner, so there may be nothing for
    "cancel" to actually interrupt) that resists both cancel and delete while
    `status=queued`. Not retrying further right now given codex-quota timing
    pressure; flagging for a follow-up check (it may transition on its own
    after a longer delay, or may need `cleanup-stuck-runs.sh`'s exact Python
    implementation rather than raw CLI/API calls -- worth trying that script
    directly in a future pass if it's still stuck).

## po2 (respawn pacing) — implemented, PUSHED, HELD pending ultracode review (2026-07-07 15:41 PT)

Codex worker completed cleanly: branch `sidekick/po2-respawn-pacing` (commits
b8735b7, 5e3514d), 175/175 tests pass, did NOT run `cargo install`/restart
(honored the single-writer lock). Reviewed the diff myself (read-only, not
merged/deployed):
- `src/config.rs`: new `RunnerConfig` fields --
  `respawn_batch_size` (default 4), `respawn_batch_sleep_seconds` (default 5),
  `respawn_load_threshold` (default 12.0 -- matches the manual CLAUDE.md rule's
  threshold), `respawn_load_retry_seconds` (default 5),
  `respawn_load_max_wait_seconds` (default 60, bounded -- never blocks
  ensure_count forever even under sustained high load).
- `src/docker_backend.rs`: `read_host_loadavg_1m()` parses `/proc/loadavg`
  (Linux only, `None` no-op fallback elsewhere); `start_missing_runners_with`
  (closure-injected Start/Sleep/Load for testability, mirrors this file's
  existing `TestEnv` pattern) batches respawns 4-at-a-time with a 5s pause
  between batches, checking the load window before each batch and pinging
  the watchdog during any pacing delay (important -- avoids the pacing
  mechanism itself starving the systemd watchdog). Wired into `ensure_count`
  replacing the old unbatched `for _ in alive..count { start_one(...) }`
  loop, preserving original error semantics.
- Regression tests confirm actual batching behavior (not just final count):
  16 starts at batch_size=4 produces exactly 3 inter-batch sleeps with max 4
  consecutive starts per batch; a forced-high-load scenario shows the
  load-backoff retrying up to `respawn_load_max_wait_seconds` then proceeding
  anyway rather than hanging.
- **My assessment: this looks correct and matches the brief closely** --
  matches E4/INV-1's needs (gentler respawn waves) and the exact watchdog
  ceiling (24) with a conservative 12 threshold and bounded wait.

**HOLDING per main's explicit instruction**: user invoked ultracode, main is
running a 4-lens adversarial review of this diff (this touches the exact
respawn path that caused today's watchdog reboots) plus a separate 4-miner
demand-cut sweep over worldai's workflow files. NOT merging or deploying
po2 until main relays the verdict (~10-20 min from 15:41 PT). Continuing
cadence watch + resamples in the meantime.

## Continued cadence watch (2026-07-07 14:52-15:42 PT, 25 samples total now)

E1 sampler kept flowing steadily through the whole window (roughly every
2-5 min, consistent with the post-fix cadence already established) while
po2 was being built. Queue depth has been trending DOWN nicely: queued_jobs
ranged 116->23 across this window (peak early, steady decline), and
`oldest_queued_job_min` has been slowly climbing (up to 161min at one point)
since the one severely-stuck run (28884233335, see cancellation ledger above)
is still sitting in the data until its cancellation actually lands. Fleet
`busy`/`registered` fluctuated 14-21 throughout (never fully clean, but
consistently in a healthy band, no repeat of the drain-to-0 incident).
Host load has been drifting up somewhat during this window (up to 9.09 most
recently) -- still well under the 24 watchdog ceiling and my 15
degradation-alert threshold, but worth watching; if it keeps climbing, po2
landing sooner rather than later becomes more valuable, not just nice-to-have.

**MILESTONE**: sample ts=1783464699 (~15:31 PT) recorded the mission's FIRST
all-clear: `{"busy":16,"registered":16,"queued_jobs":0,"inv1":true,"inv2":true,
"inv1_fail_class":null}`. Queue genuinely drained to 0 at that moment. Brief
(next sample already back to inv1=false), not a sustained window, but proves
the daemon and E2 sampler both correctly recognize and record a clean state
when one occurs -- confirms the invariant math end-to-end, not just the
violation path.

## Ultracode BLOCK verdict on po2 + demand-cut plan (2026-07-07 15:54-15:57 PT)

Full review committed (goals/.../05-ultracode-po2-review-and-demand-plan.md,
commit 546d6aa, pushed). **VERDICT: BLOCK** -- 1 confirmed CRITICAL + 13
major/minor findings. The critical: batch-boundary load checks race a
lagging 1-min loadavg EMA -- quantified, with the shipped defaults (batch=4,
sleep=5s), all 4 batches clear the gate within ~30-55s of a cold start
because the EMA has only captured ~8-22% of the true load delta by each
check, so **the exact loadavg-71 incident this diff exists to prevent can
still reproduce, just delayed 30-90s**. Also confirmed: pacing runs inside
`ensure_count` BEFORE `loop_start`-relative monitor deadlines are computed,
so a paced respawn (up to ~255s under sustained load) can blow past
`SERVE_LOOP_TIME_BUDGET` and silently degrade monitor fetches -- an almost
exact mirror of the original starvation bug, reintroduced by the fix meant
to prevent a DIFFERENT failure mode. My own review missed both of these.

**Dispatched 3 codex workers in parallel** (all confirmed alive):
1. **po2 redesign** (same branch, `~/projects/ez-gh-actions-wt-po2`,
   `sidekick/po2-respawn-pacing`): 6-point brief -- fixed conservative
   schedule as PRIMARY safety (new defaults batch_size=2/sleep=30s, sized
   from the incident's own ~4.4 load-units/runner ratio), loadavg becomes a
   secondary brake only; max-wait-timeout proceeds with batch-of-1 not a full
   batch; fix SERVE_LOOP_TIME_BUDGET starvation (fresh Instant for monitor
   deadlines captured AFTER ensure_count returns); partial-success
   visibility (don't reset ensure_fail_streak on <50% success); non-Linux
   warn-once; and a REAL safety-property test (simulated lagging EMA fed by
   actual start events, asserting it never exceeds threshold during a
   16-runner cold start -- must fail against the OLD defaults as a sanity
   check). STILL HELD pending another review pass before merge -- this
   redesign itself needs re-review, not an automatic pass.
2. **demand-cut PR-1** (worldarchitect.ai, `~/projects/worldarchitect.ai-wt-demand-pr1`,
   `sidekick/demand-cut-pr1-quickwins`): all 13 quick-win items from the
   review's table (green-gate.yml drop `edited` trigger + job-level
   cancel-in-progress, design-doc-gate.yml drop `edited`, auto-deploy paths-
   ignore, presubmit/test.yml job consolidations, resolve-context jobs to
   ubuntu-latest, codex-skill-sync to ubuntu-latest, delete redundant
   test-self-hosted-runner.yml, beads paths filters, cost-report + janitor
   merges).
3. **demand-cut PR-2** (worldarchitect.ai, `~/projects/worldarchitect.ai-wt-demand-pr2`,
   `sidekick/demand-cut-pr2-timeouts`): full E4 timeout-cap lint table -- 8
   jobs needing a documented E4 EXCEPTION (>20min genuinely justified), 6
   jobs to tighten with no exception needed, 14 jobs with zero timeout today
   getting one added.

**NOT dispatching PR-3** (needs-user-judgment cuts: draft-skip conditions on
test.yml/presubmit.yml/coverage.yml self-hosted jobs, a paths: filter on
self-hosted-mvp-shard1.yml) -- per main, these are value tradeoffs going to
the user directly, not lane-F implementation.

**Live confirmation the risk is real**: while writing this, another session's
service restart triggered an 8-runner respawn burst (not paced -- the
currently-deployed binary predates po2 entirely) and host load spiked to
12.44 within seconds, then subsided to ~9-11 without reaching the watchdog
ceiling this time. A smaller-scale, live example of exactly the failure mode
po2 (once fixed) is meant to prevent.

Will message main READY TO MERGE per PR (po2 redesign, demand PR-1, demand
PR-2) as each clears its own review/checks, matching the PR #8214 pattern.

## CORRECTNESS FIX: capped-zero was fabricating INV-1 passes (2026-07-07 16:00-16:04 PT)

Main skeptically re-checked the "first all-clear sample" milestone rather than
letting it stand. Verified: `queued_jobs_capped: true` on that exact sample.
Broader check found this is UNIVERSAL -- **27/27 samples since the cap fix
landed show `capped=true`**, because the live queue depth (400+ runs across
both monitored repos, per doctor.sh) always exceeds
`INVARIANT_JOB_ENUMERATION_CAP=50`. The all-clear sample's `queued_jobs=0`
meant "0 self-hosted queued jobs among the oldest 50 runs examined," NOT "0
queued jobs total" -- a genuine false zero. `combine_invariant_sample`'s
`inv1 = busy>=22 || queued_jobs==0` treated ANY zero as confirmed-empty
regardless of capping, so a partial/capped fetch could fabricate an INV-1
PASS. This is the dangerous inverse of the UNKNOWN-on-API-error guard: there
we protect against a false FAIL poisoning E2 with noise; here the same
missing-data situation could poison E2 with a false GREEN sample that gets
silently accepted into the "zero violations" count rather than alerted on.

**Fixed immediately** (not deferred): `inv1 = busy>=22 || (queued_jobs==0 &&
!queued_jobs_capped)`. Only an uncapped zero can now satisfy the queue-empty
branch; busy_count's branch is unaffected (fleet stats are never capped, so
`busy>=22` alone remains fully reliable). 2 new regression tests (capped-zero
must yield inv1=false with fail_class="genuinely-idle"; busy-full branch
stays reliable regardless of capping). 173/173 tests pass. Merged (commit
03026f9 -> merge 1e7222a), deployed (Gate 0 SHA verified matching), pushed.

**Retroactive correction**: the "MILESTONE" all-clear entry logged above
(sample ts=1783464699) is NOT a genuine all-clear under the corrected logic
-- it would now compute as `inv1=false` (capped, so the zero doesn't count).
No genuine all-clear sample has occurred yet in this mission as of 16:04 PT.
Leaving the original milestone note above uncorrected-in-place (not deleted)
for an honest audit trail of what was believed at the time vs. corrected
after main's skeptical check -- this note is the correction.

**Side note**: while merging this fix, found `goals/.../05-ultracode-po2-
review-and-demand-plan.md` had been independently trimmed from 962 to 87
lines by another concurrent session in the shared main checkout (timestamp
16:00:55, ends cleanly right after the PR-3 table, before the ~800 lines of
raw agent telemetry) -- left this untouched per the multi-session-repo rule
rather than overwriting it with my merge's version; whoever is editing it
will commit in their own time.

**Implication for E2/E5**: given demand structurally exceeds capacity most of
the time (task #5's finding) AND the job-enumeration cap means most samples
will legitimately show `queued_jobs_capped=true`, a genuine INV-1 pass will
now require EITHER busy==22 (full utilization) OR an uncapped confirmed-empty
queue (rare at current demand levels, requires total queued runs <=50 across
BOTH monitored repos simultaneously) -- meaning `capped=true` samples can
only pass INV-1 via the busy==22 branch going forward. This makes E2's clean
3-hour window measurably harder to achieve at current demand, which is the
CORRECT and honest reflection of reality, not an artificial tightening.

## po2 redesign COMPLETE, PR-3 resolved by data, new PR-1b dispatched (2026-07-07 16:05-16:08 PT)

**po2 redesign**: codex finished addressing all 6 items from main's brief.
Pushed to `sidekick/po2-respawn-pacing` (commit dc86a325). New defaults
confirmed exactly matching main's directive: `respawn_batch_size=2`,
`respawn_batch_sleep_seconds=30`, `respawn_load_threshold=12.0`,
`respawn_load_max_wait_seconds=60`. 179 tests pass. **This redesign has NOT
been re-reviewed by ultracode yet** -- still holding merge/deploy until
main runs (or approves skipping) another adversarial pass, since the first
design looked equally reasonable to me on read-through and still had a
confirmed critical bug.

**PR-3 resolved with live data, not implemented**: main measured the actual
draft-PR share of the queue (1/15 sampled branches, ~7%) -- draft-skip cuts
are dead, near-zero savings for real signal loss. Correctly NOT dispatched.

**New finding from the same measurement**: 4/15 (~27%) of queued-run
branches have NO open PR at all -- self-hosted CI gating nothing (pure
agent-WIP push noise). **Dispatched PR-1b** (worldarchitect.ai,
`~/projects/worldarchitect.ai-wt-demand-pr1b`,
`sidekick/demand-cut-pr1b-push-triggers`, confirmed alive): two-phase brief
-- Phase 1 verifies the 27% number on a 60+ branch sample (with an explicit
decision gate: stop and report if the bigger sample doesn't confirm a
sizeable, roughly double-digit-percent finding) before touching any YAML;
Phase 2 (only if confirmed) converts heavy self-hosted `push`-triggered
workflows to `pull_request` where the push trigger isn't genuinely needed
(e.g. not a main/dev-only deploy trigger), explicitly folding in the
`self-hosted-mvp-shard1.yml` paths-filter question from the original PR-3
table (a pull_request conversion makes that filter moot; told it to say so
explicitly either way rather than silently dropping the question).

Four codex workers now in flight: po2 redesign (held, awaiting re-review),
demand PR-1 (quick wins, still mid-edit last checked), demand PR-2
(timeout-lint, just completed per notification -- reviewing next), demand
PR-1b (push-trigger audit, just started). Also committed main's cleaned
review doc (962->87 lines / 12.7KB pure markdown, commit 1886ef0) on top of
my original full commit.

## Round-2 BLOCK + V3 dispatched, PR-1 complete (2026-07-07 16:20-16:28 PT)

**po2 round-2**: BLOCKED again. Critical: v2's "fixed schedule primary,
gate secondary" design was numerically inverted -- fixed schedule alone
peaks +17.32 load, this box's baseline runs 9-15, combined 26.3-32.3
breaches the 24 ceiling whenever the gate is dark; WITH the gate active
stays 15.7-18.6, proving the gate is load-bearing not cosmetic. Plus a
silent Linux `.ok()` swallow on loadavg read failure, and no overall
pacing budget (16-runner refill could take 16+ min in one `ensure_count`
call, starving monitors that only run after it returns). Full findings +
V3 brief appended to goals/.../05-ultracode-po2-review-and-demand-plan.md
as an appendix (commit d9d0847, merged with a concurrent session's commits
at 2b1cf96 -- that session landed a queue-tail reaper launchd stopgap +
force-cancel fallback for queued runs that ignore plain cancel, which is
directly relevant to my earlier stuck-run-28884233335 cancellation
near-miss, worth re-trying that cancel with the new fallback later).

**Dispatched V3** (same branch/worktree, confirmed alive): incremental
refill with a per-`ensure_count`-call time budget (~90-120s, monitors get
a turn every loop iteration by construction instead of only after a full
refill completes), gate-PRIMARY headroom formula
(`allowed = floor((20-load)/4.4)`), max-conservative 1-start fallback when
no load signal (covers both non-Linux and Linux read-failure, routed
through the SAME warn-once+real-alert path, fixing the silent swallow),
and tests with the worst-case baseline offset for BOTH gate-active and
gate-dark paths. Told it round-3 will re-run the arithmetic against
whatever it derives and documents in the diff itself.

**demand-cut PR-1 (quick wins) COMPLETE**: worldarchitect.ai#8235, OPEN,
MERGEABLE, all 17 expected files present (verified against the original
brief's file list). Codex noted it had to repair a branch-history issue
mid-work (backed up the pre-repair tip locally) -- verified the final PR
is clean and correctly scoped regardless.

Status: po2 still held (round 3 in flight). demand PR-1 (#8235) and PR-2
(#8232) both open/mergeable, awaiting checks + human merge decision. PR-1b
(push-trigger audit) still in progress.

## 2026-07-07 20:35-20:45 PT [sidekick] Resume after Claude-side rate-limit gap + Mac-coordination reconciliation

**Gap event**: ~20:17-20:40 PT gap in my activity was a Claude-side provider 429
(secondary rate limit on the Claude API itself, per main), NOT a GitHub quota or
task-blocking issue. Fleet was unattended by me during this window but the daemon
kept running autonomously (systemd service, no manual intervention needed).
Confirmed on resume: `ezgha.service` active, 14 containers up, `uptime` load average
7.17/6.97/6.40 (well under the 24 watchdog ceiling) — no incident occurred during
the gap. Monitor tasks `bdo79oji3` (fleet degradation) and `b0cjx61fg` (new E1
samples) kept firing throughout, confirming demand-cut work landed: INV-2 now
passing in most samples (oldest_queued_job_min dropped to single digits in several
ticks vs. the earlier 72-min reading), INV-1 still blocked mostly by
`missing-registration` class plus the Mac's runner shortfall.

**#8232 (demand-cut PR-2, timeout-lint) reconciliation — RESOLVED, no conflict**:
PR #8232 "ci: enforce self-hosted workflow timeout caps" is **already MERGED**.
Verified the live `daily-campaign-report.yml` on `main` via `gh api
repos/.../contents/...`: `timeout-minutes: 120`, with a comment noting a
follow-up optimization is tracked separately. This is an **exact match** to the
Mac session's measured requirement (120min, not the originally-flagged unsafe
15min cap). No action needed — the concern main raised was already resolved
before I got to it, most likely by the same round of FIXPLAN re-measurement
work referenced in commit 886dbe6 ("campaign-report cap genuinely unsafe (fix in
flight)") landing correctly.

**#8235 (demand-cut PR-1, quick wins) vs Mac's #8243/#8244 — file overlap confirmed,
no active conflict**: #8235 is still OPEN, `mergeable: MERGEABLE` (GitHub's own
computed status against current main, which already includes both Mac PRs merged).
File-level overlap:
- `green-gate.yml`: #8235 removes `edited` from `pull_request.types` and scopes
  `cancel-in-progress` to the self-hosted precheck job. Mac's #8244 (MERGED) splits
  the Gate-4 Bugbot poll to `ubuntu-latest`. Different concerns within the same
  file — trigger/concurrency vs. runner assignment for one job — no line-range
  collision expected.
- `levelup-tests.yml`: #8235 moves `resolve-pr-context`/`resolve-self-hosted-pr-context`
  to `ubuntu-latest`. Mac's #8243 (MERGED) adds a FIXPLAN paths filter + per-PR
  levelup concurrency group. Also different concerns — job runner vs. trigger
  paths/concurrency.
- GitHub's live mergeability check is authoritative for textual conflicts and
  reports clean. Residual risk is purely semantic (two PRs touching the same
  workflow's behavior in the same review window) — recommend a human glance at
  final diff before merge, not a blocker.
- Could not pull full diff hunks to eyeball line-by-line: GitHub API returned a
  **hard rate limit (HTTP 403, primary quota, not the usual secondary/abuse
  block)** mid-check. Backed off per "keep Claude usage light" directive rather
  than retrying.

**PR-1b (push→pull_request trigger audit) — correctly conservative, no YAML
shipped**: codex's dispatch (branch `sidekick/demand-cut-pr1b-push-triggers`,
opened as worldarchitect.ai PR **#8236**) did NOT implement the trigger change.
It attempted the required ≥60-distinct-branch verification sample main mandated
before implementing, but GitHub secondary-rate-limited the Actions endpoint after
only 31 branches accumulated across 12 snapshots. The original 4/22 (18.2%)
no-open-PR finding stands directionally but is **unconfirmed at the required
scale**. Per main's explicit gate ("verify the 27% number on 60+ branches before
implementing"), codex correctly stopped at Phase 1 (data collection + writeup)
and shipped zero workflow changes. This is the right outcome, not a stall.

**Division of labor reaffirmed**: Lane L3 (CPU-resize / 1-cpu-clamp) is
Mac-owned — not touched, not duplicated. worldai_claw PR #253 is the Mac's
separate mission — not touched. Mac fleet context for SC6 interpretation: 4/6
mac runners up, mac loadavg 18-23 at last relay from main — treated as an
external dependency on the INV-1 busy==22 branch, not a Linux-side bug to chase.

**Next**: doctor.sh resample for SC6 (fleet integrity), then report consolidated
findings to main. Continuing to HOLD po2 V3 deploy pending main's own round-3
SHIP verdict — not independently reviewing or acting on it.

---

## sidekick3 RESPAWN — recovery entry (2026-07-07 21:38 PT)

Predecessor sidekick2 died on API session-limit/rate-limit. Recovered via the
respawn protocol (STATE.md + main's 06-main-autonomous-progress.md + goal docs +
beads + git). No redo — resuming from exactly where sidekick2/main left off.

**Confirmed since handoff**:
- Both demand-cut PRs (worldai#8214, #8235) MERGED — confirmed via main's
  06-main-autonomous-progress.md, consistent with git log (main HEAD 8abd2f2,
  beads db/wal untrack commit 3edff6b already landed).
- po2 branch `sidekick/po2-respawn-pacing` fetched fresh: still at 153d1b8
  (4 codex commits: b8735b7 config, 5e3514d pacing, dc86a32 fixed-schedule-safe,
  153d1b8 gate-primary). The round-3 CRITICAL fix (is_partial_failure
  misclassifying gate-throttled starts as failures) is **NOT YET on the branch**
  — grepped src/ for `partial_failure`/`is_partial_failure`, only found in
  main.rs/docker_backend.rs unchanged from round-3 state; `respawn_load_safety_ceiling`
  default is still 20.0 (not yet capped <24 per the fix brief, though 20<24 already
  satisfies the numeric ask — the validation-rule addition is what's pending).
- **Codex is actively running** the fix: PID 562582, `codex exec --yolo
  --skip-git-repo-check` in `~/projects/ez-gh-actions-wt-po2`, elapsed 24+ min as
  of this check (started ~21:14 PT). Full prompt confirmed matches main's
  described brief (attempted-vs-missing partial-failure redefinition + tests +
  ceiling<24 validation cap). Worktree git status is clean (no uncommitted diff
  yet) — codex hasn't written anything to disk yet or is mid-edit not yet saved.
- Live invariant sampler tail (last 5 samples): INV-2 passing (oldest queued
  4.8-16.5min, all <20min threshold). INV-1 failing every sample, busy 17-20/22,
  fail_class alternating `missing-registration`/`offline-respawning` — matches
  main's description exactly, no drift.
- Host load 9.09 (1-min), 13 ezgha-managed containers running, ezgha.service
  active. Both comfortably under the careful-restart gate (load<12, containers>=12)
  main specified for when SHIP lands.

**Action taken**: started a background Monitor polling PID 562582 + worktree HEAD
sha every 15s (task bkf1cboe9, 30min timeout) instead of manually polling —
will get an event the moment codex finishes or dies, then verify the diff/tests
per main's instruction (read-only, do NOT merge/deploy without explicit SHIP from
main). Claimed TaskList #7 (track hardening-bxy-fl0, don't touch) and #8
(STATE-mirror + bead cadence) as sidekick3.

**Not yet done this block**: mirroring this entry to STATE-mirror.md (committed
copy) and bead ez-gh-actions-9je — doing next. Have not touched cargo
install/systemctl restart (single-writer lock respected, nothing to deploy yet
since fix isn't committed).

---

## sidekick3 — po2 fix VERIFIED, holding for SHIP (2026-07-07 22:40 PT)

Main's dispatched codex fix HUNG (71min, 0% CPU, zero src edits) and was killed
by main, who implemented the fix directly instead. Landed as **072025d**
"fix is_partial_failure to count attempted-not-missing (round-3 critical)" on
`origin/sidekick/po2-respawn-pacing`.

**Independently verified (not just trusting main's numbers)**:
- Confirmed 072025d present on `origin/sidekick/po2-respawn-pacing` via fresh
  `git fetch` (no local trust assumption).
- Worktree `~/projects/ez-gh-actions-wt-po2` already at 072025d (main committed
  there directly) — ran `cargo test --bin ezgha` myself: **182 passed, 0 failed**,
  matches main's claim exactly.
- Read the actual diff, not just the commit message:
  - `docker_backend.rs`: `EnsureCountOutcome` gained `attempted: u32`;
    `is_partial_failure()` is now `(self.started.len() as u32) < self.attempted`
    (was `started.len()*2 < missing`). Gate-throttled-by-design starts (attempted=2,
    started=2) no longer trip the failure path; only genuine start_runner() errors
    (attempted=2, started=1) do. Two new named tests confirm both branches:
    `gate_throttled_full_success_is_not_a_partial_failure` and
    `attempted_start_that_errors_is_a_partial_failure`.
  - `config.rs`: validate() now rejects `respawn_load_safety_ceiling >= 24.0` with
    a comment explaining the host watchdog max-load-1 reboot threshold — closes
    the round-3 minor (operator can no longer configure the ceiling up to/past the
    reboot line). Test asserts 24.0 and 30.0 both fail validation, 20.0 (default)
    passes.
- No discrepancies between main's description and the actual landed diff.

**Still NOT deploying**: per main's explicit instruction, the round-3 arithmetic
lens + final SHIP verdict has not run yet (rate-limit pressure killed both prior
attempts). Holding here until main sends SHIP. When it lands: merge branch→main,
Gate 0 loop with careful-restart (verify load<12 AND containers>=12 immediately
before `systemctl --user restart ezgha.service` — mass cold respawn tripped the
host watchdog twice already today).

**Housekeeping this block**: stopped the stale Monitor (bkf1cboe9, was watching
the now-killed codex PID 562582 — timed out cleanly, no action needed since main
superseded it directly). Noted the po2 worktree has uncommitted noise in
`.beads/beads.db`/`.beads/beads.db-wal` (leftover from the killed codex session)
— left untouched, not my job to clean up mid-verification and it doesn't affect
src/ or tests.

**Rate-limit directive from main (in effect)**: reduce gh API pressure — Mac
session running a parallel redundant goal on the same GH account hit the same
conclusion independently. My Monitor/checks are all local-only (git, ps, cargo) —
zero gh calls, already compliant. Holding to ~20-30min consolidated check cadence
per main's directive rather than continuous polling.

---

## sidekick3 — load watch armed, evidence logged (2026-07-07 22:35 PT)

Main reported live load 18.28 climbing, 9/16 linux containers, pre-reboot danger
zone (watchdog=24, box rebooted twice today). Bind: po2 deploy fixes the churn
but needs a service restart, which itself spikes load right when load is already
high.

**Checked immediately**: load had already eased to 15.39 (1m)/13.40(5m)/11.65(15m),
12 ezgha containers — better than main's report but still above the load<12
careful-restart gate, not yet a deploy window.

**Started a persistent local-only Monitor** (task bxtcf63nf, 5-min cadence,
`/proc/loadavg` + `docker ps --filter label=ezgha=managed`, zero gh calls):
- Emits DANGER if load1 >= 22 (approaching the 24 reboot ceiling) — for immediate
  main alert per directive.
- Emits SAMPLE every tick otherwise.
- Emits DEPLOY_WINDOW and stops once load1 < 12 for 2+ consecutive checks AND
  containers >= 12 — the exact signal main asked me to report, at which point
  main does the final arithmetic re-verify and I deploy immediately in the
  window if SHIP.

**Evidence logged per main's ask** (22:22 sample, the "target is reachable" proof):
`{"ts":1783488179 (22:22:59 PT), "busy":22, "registered":22, "queued_jobs":111,
"inv1":true, "inv2":false, "oldest_queued_job_min":20.92}` — fleet hit 22/22 busy
(INV-1 momentarily satisfied) but INV-2 broke in the same instant (oldest queued
already 20.9min, just over the 20min line) because the churn that got it to 22
also delayed the queue past the threshold. Four minutes later (22:27:21) it
dropped back to 17/19 busy. This is exactly main's point: 22/22 is reachable, the
fleet just can't hold it without pacing — direct evidence the po2 deploy is the
correct lever, not a wasted effort.

Holding: no restart action taken or contemplated while load>12. Will alert main
immediately on any DANGER event, and report DEPLOY_WINDOW the moment it fires.

---

## sidekick3 — po2 SHIP + merge complete, load dropping fast (2026-07-07 22:39 PT)

**STEP 1 (arithmetic re-verify) — DONE, SHIP confirmed myself** (main routed the
verification to me directly per the delegation rule, since the round-3 lens kept
dying on rate limits): re-derived the gate formula in
`allowed_respawn_starts_for_load` (docker_backend.rs:876) --
`allowed = floor((ceiling - (measured_load + committed_starts*per_runner)) / per_runner)`
clamped to batch_size -- this is a closed-form guarantee that
`baseline + allowed*per_runner <= ceiling` at every decision point, not a
heuristic. Ran the two named safety tests standalone (not just trusting the
182-count): `gate_active_incremental_refill_stays_below_watchdog_with_busy_host_baseline`
(drives the real code through a LaggingLoadSim, proves started.len()==1 and
15.0+4.4=19.4<24) and `gate_dark_fallback_starts_one_runner_and_stays_below_watchdog_with_busy_host_baseline`
(proves exactly 1 start, no retries, using the incident-derived worst-case
71/16=4.4375 per-runner load: 15.0+4.4375=19.4375<24 -- stricter than the
configured 4.4 default). Both pass. Round-3 regression test
`gate_throttled_full_success_is_not_a_partial_failure` passes. No hole found --
SHIP confirmed.

**STEP 2 (merge, no restart) — DONE**: squash-merged `origin/sidekick/po2-respawn-pacing`
(b8735b7..072025d, 5 commits) into main as **d612ad7**, pushed to origin. Only
conflict was `.beads/beads.db`/`.beads/beads.db-wal`/`.beads/last-touched` --
the branch predates main's untrack decision (3edff6b); resolved by keeping them
deleted (git rm) per that decision, no code conflicts (branch only touched
config.rs/docker_backend.rs/main.rs; main's concurrent work only touched
queue_monitor.rs). Ran the full suite on main post-merge: **184/184 passing**
(182 from the branch + 2 from main's own queue_monitor additions). Confirmed
Gate 0 transient mismatch as expected: installed binary still embeds old SHA
`00122ca`, current HEAD is `d612ad7` -- po2 is on main, service NOT restarted,
exactly per main's instruction.

**STEP 3 (deploy window) — IN PROGRESS, load dropping faster than expected**:
checked immediately after merge -- load average now **9.17 (1m) / 11.47 (5m) /
11.38 (15m)**, 12 containers. The 1-minute figure is already comfortably below
the load<12 gate; 5m/15m are right at the edge. My background Monitor (task
bxtcf63nf) is still ticking every 5 min tracking a below-12 streak (needs 2
consecutive) -- will fire DEPLOY_WINDOW very soon if this trend holds. Alerting
main now rather than waiting for the Monitor event, since the window may open
faster than the 5-min poll cadence implies.

**Next**: the instant the Monitor confirms 2 consecutive sub-12 samples with
containers>=12, run the Gate 0 careful-restart myself (cargo install --path . ->
systemctl --user restart ezgha.service -> verify SHA matches d612ad7 and
containers/load recover) -- I hold the single-writer lock on this, no
sub-agent needed for a restart. Will report first post-deploy samples
immediately.

---

## sidekick3 — po2 DEPLOYED and confirmed working (2026-07-07 22:45 PT)

Main did the Gate 0 careful-restart directly (single-writer, to avoid two
writers on the same restart while I was mid-verification-report) at load 8.38,
deliberately AT 6 containers -- below the old >=12 sub-gate, reasoned as safe
because po2's pacing makes the old container-count precondition unnecessary
for a binary that paces its own refill. Watched live: load stayed 7-9.5 through
the 6->13 refill.

**Independently confirmed post-deploy** (own checks, not just trusting the
report):
- `ezgha --version` = `0.1.0-6a3138d` -- new binary running, matches HEAD
  (6a3138d, one commit past the d612ad7 merge point).
- `systemctl --user is-active` = active.
- Journal has the gate literally firing: `Jul 07 22:42:03 ... warning: host
  1-minute load average 8.19 leaves no safe respawn headroom below ceiling
  20.00; delaying runner respawn` -- direct proof the load-aware pacing is
  live in production, not just in tests.
- Load at my check: 6.49(1m)/9.00(5m)/10.39(15m), containers refilling
  (4 at time of check, climbing as expected from the paced restart).
- My independent load Monitor (task bxtcf63nf) corroborates: sample sequence
  showed load1 dropping 10.07 -> 7.18 with below12_streak reaching 2 --
  consistent timeline with main's restart, second set of eyes confirms no
  discrepancy.

**Created follow-up bead `ez-gh-actions-ktq`** (P2, capture-only, do NOT
implement yet) per main's request: graceful `ezgha reload` daemon re-exec so
future code rollouts re-adopt the running container fleet in-place instead of
a full kill+restart respawn wave -- combined with po2 pacing this would
eliminate the restart-driven watchdog-reboot risk entirely. User's idea via
main. Implementation routes through sidekick3/swarm when picked up later, not
direct main-coding, per the delegation directive already on file.

**Flagged for later** (not acting now): CLAUDE.md careful-restart rule
refinement -- the `containers>=12` sub-condition should be relaxed to
"OR the binary being deployed includes po2 pacing" since po2 makes low-container
restarts safe. Main's note, deferred to a future edit pass.

**Resuming normal cadence**: back to the ~20-30min consolidated load/health
watch (local-only, no gh) plus tracking invariant_history.jsonl for the
post-deploy INV-1 trend -- watching specifically for missing-registration
churn frequency dropping now that respawns are paced. Last 8 samples
pre/at-deploy still show the old churn pattern (busy oscillating 12-22,
inv1_fail_class alternating missing-registration/none) since those samples
predate the restart finishing its refill; next samples should start showing
the improvement if po2 works as designed. Will report the trend at next
consolidated check.

---

## sidekick3 — fleet hit 0 briefly, recovering, gh rate-limit confirmed root cause (2026-07-07 22:52 PT)

Main's correction (gh 403 rate-limit exhaustion, not po2) confirmed by my own
local-only evidence:

- Journal shows the daemon's own gh calls actively failing: `WARN: queue
  monitor check failed: ... gh: API rate limit exceeded for user ID 13840161
  ... (HTTP 403)` at 22:47:33 and 22:50:22, and `WARN: invariant sampler tick
  failed: ... rate limit exceeded` at 22:50:54 -- the sampler itself is now
  blind, matching main's report that samples have stalled.
- Container count genuinely hit **0** (checked twice via `docker ps` and
  `docker ps -a --filter label=ezgha=managed` -- zero, not even exited
  containers lingering, consistent with ephemeral `--rm` runners that fail
  GitHub JIT registration under the 403 and self-remove within the same
  cycle -- exactly the "runners exit faster than the daemon can register
  replacements" mechanism main described, not a new failure mode).
- Journal shows the daemon IS attempting respawns (`respawned ephemeral
  runner ez-runner-c-1/2/3` at 22:47:01 and 22:49:47) and the po2 load gate
  is correctly gating them (`load average 6.91/5.09 leaves no safe respawn
  headroom below ceiling 20.00; delaying runner respawn`) -- po2 itself is
  working exactly as designed; the bottleneck is purely gh-side.
- Rechecked 2 min later: containers back up to 2 (from 0), load 6.03(1m) --
  bouncing near-zero rather than a sustained flatline, consistent with
  degraded-but-recovering rather than a dead fleet.
- Cannot get a fresh local queued_jobs count (invariant sampler itself is
  gh-rate-limited right now); last known sample (18+ min stale) showed 100
  queued jobs, busy=19 -- no reason to believe queued work vanished, so
  stranded work is likely but not freshly confirmed (would require a gh call
  I'm avoiding per directive).
- Took NO restart action -- per main's explicit instruction this is not
  restart-fixable (rate limit needs to clear on its own), and load is safe
  regardless (6-9 range).

Escalated to main immediately per the "hits 0 AND jobs stranded" trigger,
noting the immediate recovery to 2 so main has the accurate trend, not just
the alarming single reading.
