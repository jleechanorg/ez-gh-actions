# 4kv — Merge + Deploy Plan: u3w + adafa19 Reaper to Both Machines

**Bead:** ez-gh-actions-4kv (`deploy-current-adafa19-to-both-machines`)
**Author:** codex/gpt-5 (auto-factory DEPLOY-PLANNER, single-writer rule respected)
**Date:** 2026-07-08
**Branch:** `factory/ez-gh-actions-4kv-r1`
**Target machines:** jeff-ubuntu (Linux, 16 slots) + MacBook (6 slots)

---

## Why this plan exists (TL;DR)

- **Neither machine is running the qbl adversarially-reviewed reaper.**
  - Mac binary: `7f476ac-dirty` (App-token wiring only, NO reaper code) per s9d Track D §6.
  - jeff binary: `5f0374a` (reaper wiring pre-adafa19, missing the 422-substring fix and force-cancel hardening).
  - **This is the durable fix for both stale-registration classes:** 422-lock zombies (qbl) + offline+!busy self-heal (u3w) + App-token rate-limit isolation.
- PR #32 (u3w) is mergeable=CLEAN, all 4 CI checks SUCCESS, 2-commit factory overlay, factory/ez-gh-actions-u3w-r1 at `bf07f87`. **Live confirmation deferred** — both `gh api graphql` and `gh api` REST exhausted (user 13840161) at 2026-07-08 19:38 UTC. Bead text from team-lead cites same state; trusting that until a fresh API window allows independent re-verification pre-merge.
- Deploy bundles the future s9d fix once u3w merges.

---

## Scope of what is being deployed

| Layer | Source commit | What it carries |
|-------|---------------|-----------------|
| qbl reaper (adafa19) | `adafa19` (already on origin/main) | 422-classifier false positive fix + force-cancel test hardening. Adversarially reviewed. |
| u3w reaper 4th sub-pass | PR #32 (`bf07f87` head) | `offline_not_busy_owned_missing_container_registrations` helper wired between Path 1 and Path 3 of `release_stale_slots`. 5 fail-first tests. +262 lines `src/docker_backend.rs`. |
| App-token (7f476ac) | already on origin/main | Reaper self-heal authentication via GitHub App token (isolated ~9350/hr bucket). |
| Net effect | origin/main after PR #32 merge | Both stale-reg classes (422-lock zombie + offline+!busy self-heal) get force-cancel'd on dedicated paths, App-token bucket-isolated, fleet converges to 22/22 stable. |

What is **NOT** in this deployment: any token rotation, any `~/.config/ezgha/config.toml` edit, any slot-assignment reset, any new beads. Read-only deploy on running daemons until restart is authorized.

---

## Pre-flight snapshot (captured 2026-07-08 12:38 PDT, informational only)

- jeff `uptime`: load_1min = **21.36**, load_5min = 14.24, load_15min = 12.56.
  - **STOP-RESTART signal:** load_1min above 12 threshold. Mass cold respawn of 16 runners under load_1min=21 would risk host watchdog (`/etc/watchdog.conf max-load-1 = 24` on this 32-thread box) which has tripped twice this week (2026-07-07).
  - **Action:** do NOT restart jeff right now even after merge+cargo install. Wait for load_1min < 12 before issuing `systemctl --user restart ezgha.service`. The check is the deploy-owner's, not mine. This plan flags it; the deploy-owner enforces it.
  - **Why:** bead `ez-gh-actions-po2` carries the durable fix (load-aware respawn pacing inside the daemon). Until that ships, the manual check is mandatory.
- jeff containers: `docker ps --filter label=ezgha=managed | wc -l` = 14. Below the >=12 threshold for safe restart. Tie restart to a time when container count is also at or above the floor.
- jeff `ExecMainStartTimestamp`: `Wed 2026-07-08 12:38:09 PDT` (current 5f0374a binary is live).
- Mac state: deferred to Mac-side verification step (Step 3b). Plan does **not** ssh macbook or run any launchctl command in advance.

---

## STEP 1 — Merge PR #32 to main

**Who:** the user (deploy-owner).
**Why:** PR #32 carries the u3w 4th sub-pass. Adversarial review (bead qbl auto-factory) and CI green per bead text. Squash-merge bundles u3w changes on top of adafa19 + 7f476ac, all already on origin/main.

**Command:**
```bash
cd /home/jleechan/projects/ez-gh-actions
gh pr merge 32 --squash --body "Closes ez-gh-actions-u3w; deploy-bundles reaper self-heal on top of adafa19 + new s9d 4th sub-pass"
```

**Verification post-merge (deploy-owner runs, not the planner):**
```bash
gh pr view 32 --json mergedAt,mergeCommit 2>&1 | head -5
git log origin/main --oneline -10 | head -5
git log origin/main --oneline | grep -i "4th sub-pass\|offline+!busy\|u3w"
```
Expect: `mergeCommit.oid` populated, `mergedAt` set to just-now, `origin/main` advances `c24137c → <new SHA>` containing the squash line for u3w.

If GH is still rate-limited (user 13840161 was 403'd at 12:38 PDT), the merge command itself may still succeed via gh CLI's local cache + GitHub web-side merge — if `gh pr merge` fails with rate limit, fall back to **GitHub UI merge with squash** (preserves the squash semantics).

---

## STEP 2 — Build clean from origin/main HEAD

**Who:** the deploy-owner.
**Why:** merges are not live daemons; the installed binary only updates after `cargo install --path .` re-embeds the HEAD SHA. Both mac and jeff share the source but rebuild independently.

**Pre-step (clean detached worktree, prevents accidental branch edits):**
```bash
# jeff side
cd /home/jleechan/projects/ez-gh-actions-wt-4kv
git fetch origin && git checkout --detach origin/main
git log -1 --oneline   # confirm HEAD is the squashed merge commit
```

**Build + install:**
```bash
cargo test --release 2>&1 | tail -20     # full test suite, must be all green before install
cargo install --path .                    # embeds new HEAD SHA in ~/.cargo/bin/ezgha
```

**Verify embedded SHA:**
```bash
strings ~/.cargo/bin/ezgha | grep -E "^[a-f0-9]{7,12}$" | sort -u | head -5   # should contain origin/main HEAD SHA
which ezgha && ezgha --version 2>&1 | head -5
```

Expected: `which ezgha` → `~/.cargo/bin/ezgha`; binary contains the new SHA; `ezgha --version` reports HEAD SHA correctly.

---

## STEP 3a — Gate-0-safe jeff restart

**Who:** the deploy-owner. **NOT** the planner.
**Why:** the planner is a coder agent; per `CLAUDE.md` "After any commit" Steps 2–5 single-writer rule, all restart/steps go through the deploy-owner (the user).

### Pre-checks (BOTH must pass — if either fails, defer the restart)

```bash
# Check 1: load below watchdog ceiling with margin
load_1min=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
[ "$(echo "$load_1min < 12" | bc)" = "1" ] && echo "LOAD OK: $load_1min" || { echo "LOAD HIGH: $load_1min — DEFER"; exit 1; }

# Check 2: at-or-above container floor
container_count=$(docker ps --filter label=ezgha=managed | wc -l)
[ "$container_count" -ge 12 ] && echo "CONTAINERS OK: $container_count" || { echo "CONTAINERS LOW: $container_count — DEFER (likely actively draining)"; }

# EXCEPTION branch (per CLAUDE.md "exceptions" note): if containers are draining
# AND load is LOW, the serve loop is stuck; restart IS the remediation. Document
# the exact (load < 12 AND containers < 12 AND shrinking-over-multiple-checks) state
# in #before-restart channel before proceeding.
```

### Restart

```bash
systemctl --user restart ezgha.service
```

### Verify the new binary is live

```bash
sleep 3
systemctl --user show ezgha.service -p ExecMainStartTimestamp   # must be > 12:38:09 PDT
date '+%Y-%m-%d %H:%M:%S %Z'                                     # current time
pid=$(systemctl --user show ezgha.service -p MainPID | awk -F= '{print $2}')
ls -la /proc/$pid/exe                                                    # must point to new ~/.cargo/bin/ezgha
strings /proc/$pid/exe | grep -E "^[a-f0-9]{7,12}$" | sort -u | head -5  # new HEAD SHA embedded

# Reaper self-heal symbol presence (proves u3w helper is in the binary)
strings /proc/$pid/exe | grep "offline_not_busy_owned_missing_container_registrations"
# expected: at least one match (function name embedded)

# qbl reaper symbols still present (proves adafa19 is in the binary, not stripped)
strings /proc/$pid/exe | grep -E "reap_stale_registrations|force_cancel" | head -5

# App token still active post-restart
tail -100 ~/.local/share/ezgha/ezgha.log 2>/dev/null | grep -E "App.*token|GH_APP|github_app_id" | tail -5
```

### Expected first-3-cycles cancel-log watch (jeff)

```bash
journalctl --user -n 200 -u ezgha.service --since "1 minute ago" 2>&1 | grep -E "force-cancel|cancel:|reclaim:" | tail -20
```

Watch for any line that is NOT clearly `offline AND busy AND containerless`. If you see a `force-cancel` against a runner that was `online` or `idle` or `offline+!busy+container-present`, **STOP** and escalate to main immediately — that means the qbl false-positive regression is back.

---

## STEP 3b — MacBook restart via launchd

**Who:** the deploy-owner (typically via `/mac` skill ssh to macbook).
**Why:** mirrors Step 3a for the macOS half of the fleet.

### From jeff via /mac

```bash
# ssh to macbook
ssh macbook
```

### On macbook

```bash
# Pre-check 1: load
load_1min=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
[ "$(echo "$load_1min < 12" | bc)" = "1" ] && echo "LOAD OK: $load_1min" || echo "LOAD HIGH — DEFER"

# Pre-check 2: containers
container_count=$(docker ps --filter label=ezgha=managed | wc -l)
[ "$container_count" -ge 4 ] && echo "CONTAINERS OK: $container_count" || echo "CONTAINERS LOW: $container_count — defer or investigate"

# Restart
launchctl kickstart -k gui/$(id -u)/org.jleechanorg.ezgha

# Verify
sleep 3
launchctl print gui/$(id -u)/org.jleechanorg.ezgha | grep -E "pid|last exit"
new_pid=$(pgrep -f "/Users/jleechan/projects/ezgha/target/release/ezgha|ezgha/ezgha" | head -1)
strings /proc/$new_pid/exe 2>/dev/null | grep -E "^[a-f0-9]{7,12}$" | sort -u | head -5
strings /proc/$new_pid/exe 2>/dev/null | grep "offline_not_busy_owned_missing_container_registrations"
strings /proc/$new_pid/exe 2>/dev/null | grep -E "reap_stale_registrations" | head -3
```

### Cancel-log watch (mac)

```bash
# macs log via launchd; check unified log filtered to ezgha
log show --predicate 'process == "ezgha"' --last 1m --style compact 2>&1 | grep -E "force-cancel|cancel:|reclaim:|reaper" | tail -20
```

Same acceptance criterion as jeff: every `force-cancel` line must be against a runner that was `offline AND busy AND containerless`. Anything else = STOP and escalate.

---

## STEP 4 — 5-min sustained fleet check

**Who:** the deploy-owner (or delegated monitor). **NOT** the planner.
**Why:** "Confirmed X deployed" from a single data point is not verification. The bead rule for this fix class requires sustained steady state, not a healthy snapshot seconds after restart.

**Acceptance (from `docs/EXIT-CRITERIA.md` and `./docs/verify-exit-criteria.sh` Gates 0–10):**

```bash
# 5 min after Step 3b completes
./doctor.sh                                          # Gates 0,3 must pass: 16/16 on jeff + 6/6 on mac
./docs/verify-exit-criteria.sh 2>&1 | tee /tmp/4kv-gate-check.log  # all 11 gates
```

Gates that MUST pass:

| Gate | What it checks | Why this plan cares |
|------|----------------|---------------------|
| 0 | installed binary SHA matches origin/main HEAD | proves the new code is actually running |
| 3 | container count == configured (16 + 6 = 22) | proves no mass respawn regression |
| 4 | every Runner.Worker process alive (`docker top`) | per-slot executing proof — the fleet MUST run full capacity |
| 5 | App-token auth working post-restart (reaper self-heal) | proves rate-limit isolation survived the restart |
| 7 | reaper self-heal ran at least once and produced no FP cancellations | proves the qbl adversarial fix is live |

If any gate fails, do NOT claim success — open a `br create ...` bead at the priority matching the symptom's user-impact, file the symptom, and roll forward to the next fix.

---

## STEP 5 — 5-min sustained "fleet holds 22/22 stable" check

```bash
# 5 min after gates pass
./doctor.sh 2>&1 | tee /tmp/4kv-doctor-5min.log
./docs/verify-exit-criteria.sh 2>&1 | tee /tmp/4kv-gates-5min.log
# expect all 11 gates green AND 22/22 slots executing AND zero force-cancel against healthy runners
```

If at the 5-min mark anything is red: STOP, file bead, do not declare mission complete. If everything is green at 5 min AND at 10 min AND at 15 min: proceed to Step 6.

---

## STEP 6 — Close the mission

**Who:** the deploy-owner (or delegated post-deploy writer).

```bash
# Issue a follow-up verification check (the bead stays in_progress until doctor returns 22/22 stably)
./doctor.sh
# if green: file the success evidence to docs/4kv-deploy-evidence-20260708.md
#          br close ez-gh-actions-4kv
# if red:   keep open, file blockers, do not close
```

**Close bead text:**
```
4kv deployed: adafa19+qbl+u3w+App-token live on jeff+mac. Gates 0/3/4/5/7 green at 5/10/15 min post-restart. Fleet 22/22 stable. No force-cancel false-positives observed. Evidence: docs/4kv-deploy-evidence-20260708.md (or path).
```

---

## Risk register + freeze signals

| Risk | Signal | Mitigation |
|------|--------|------------|
| Host watchdog reboot on jeff | load_1min >= 18 around restart | Pre-check load < 12; defer to off-peak |
| Mass cold respawn drains jeff to 0 | serve loop stuck under load | Pre-check containers >= 12; if drain occurs with low load, restart IS the remediation (CLAUDE.md exception) |
| qbl false-positive regression returns | force-cancel against online/idle/offline+!busy runner | STOP, file P0 bead, do not close 4kv |
| Mac token-refresh bug surface re-fires (hcu) | any `401 invalid_auth` in mac logs | run hcu bead verification step, file follow-up |
| GH API still rate-limited at deploy time | `gh pr view` 403s | Use GitHub web UI for merge verification; locally confirm via `git log origin/main` |
| App-token revoked during restart | reaper self-heal cannot authenticate | The token source is the GitHub App installation (system); restart should not affect it. If reaped token cache somehow cleared, restore from `docs/gh-app-token.md` runbook |

---

## Stagger vs. simultaneous — OPEN QUESTION FOR THE DEPLOY-OWNER

This plan as written does **both** machines nearly back-to-back (Step 3a then 3b, with the cancel-log watch running in parallel via journald on jeff + log show on mac). This is the lowest wall-clock-risk approach IF the deploy-owner is monitoring both simultaneously.

Alternative strategies the deploy-owner may pick from:

1. **jeff first, mac 15 min later (staggered, default in this plan but not strict):** if mac fails, jeff has stable self-heal already live. Lower blast radius.
2. **mac first, jeff 15 min later:** same in reverse.
3. **Simultaneous back-to-back:** shorter total deploy window, but if both fail at once, both halves of the fleet are degraded at the same time. Higher blast radius.

**This plan does NOT pick between these** — the user is the deploy-owner and the bead description explicitly requires us to STOP and ask if two materially-different deploy strategies are on the table. **Asking main to escalate that question.**

---

## Coordinator handoff

**What the planner did:**
- Wrote this plan.
- Will commit + push `docs/4kv-deploy-plan-20260708.md` to `factory/ez-gh-actions-4kv-r1`.
- Will NOT touch any daemons, NOT merge PR #32, NOT `cargo install`, NOT restart either service.

**What we are waiting on:**
- The user's `gh pr merge 32 --squash` (or web UI squash if rate-limited).
- The user's build + install steps on jeff (or mac, depending on order picked).
- The user's `systemctl --user restart` on jeff + `launchctl kickstart` on mac.
- The user's stagger decision (above "open question" section) before Step 3 starts.
- Bead resolution path from main once Step 5 confirms sustained 22/22 green at 5/10/15 min.

This file is the deploy playbook. Planner is hands-off from here.
