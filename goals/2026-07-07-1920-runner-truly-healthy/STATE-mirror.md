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
