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

## Next actions (in order)

1. [in progress] Recreate TaskList tasks (#1-#8 equivalents) since tracker was empty.
2. Salvage lane-cg: worktree + build/test + merge queue_monitor.rs work → main.
3. Salvage lane-d: worktree + review + merge ed8 doc + docker_backend.rs line → main.
4. Respawn lane-h (gitleaks across repos) as a fresh codex background task.
5. Investigate why queue is STILL CLIMBING (520, was 267 at mission start) — is this
   organic demand or something runaway (matrix/loop)? This is the single biggest
   threat to E2 (3hr zero-violation window) and needs root-causing before more drain
   cycles are wasted on a refilling bucket.
6. Monitor PR #8214 (lane-f) for CI to clear once queue drains; merge when green.
7. Re-run doctor.sh / verify-exit-criteria.sh once fleet fully settles post-restart to
   get a clean baseline sample for the E1 sampler once it lands.
