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

## Next Actions (rewritten every step)

1. Poll for reaper-wiring's pushed branch (`git branch -r | grep -iE 'reaper|qbl|zombie'`).
   When present: build+test it, spawn adversarial verifier, and on PASS merge to origin/main
   + Gate 0. This is the top priority — it's the durable fix for the exact bug that capped
   the Mac.
2. Collect capacity-proof's peak-executing result when it reports; log it here + to main.
3. Chase app-wiring's status; review + merge any committable refresh-helper/systemd-unit
   code (never the token value). Confirm separate-bucket proof.
4. After reaper fix lands + app token wired: request main coordinate a Gate-0-safe jeff
   restart if needed, then re-verify sustained 16/16 + 6/6 (or queue-drained).
