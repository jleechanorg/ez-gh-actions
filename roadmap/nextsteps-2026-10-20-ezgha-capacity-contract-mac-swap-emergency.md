# Nextsteps — ez-gh-actions fleet capacity & Mac swap emergency — 2026-10-20

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [Timeline and parallel lanes](#timeline-and-parallel-lanes)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- **Outcomes**: Fleet capacity contract reduced 24→18 (14 Linux @ 2000 MiB + 4 Mac) and encoded in code+docs (commit `fe11f92`, PR #181 draft); queue-trimmer stale-PR threshold lowered 2h→1.5h (live on Mac launchd); a Mac host-disk emergency (~1 GiB/min fall, 45 min from zero) was root-caused to **macOS swapfiles** under memory pressure — not CI data — and contained by unloading the Mac daemon and stopping colima (swap 28G→18.4G, free 24G→**90G** in ~30 min); a 12h44m-wedged trim-queued-runs.sh was killed and relaunched; the 18-contract binary is built on jeff-ubuntu (restart pending, guard-blocked).
- **Risks / blockers**: PR #181 has a **merge conflict** (`.beads/issues.jsonl` only); jeff-ubuntu daemon restart blocked by CLAUDE.md load guard (load 17–57 during queue grind); the colima-trim guard has been **dead since Oct 10** and the colima VM is ~8x oversized for its 2.8G live guest — the Mac fleet must NOT be restored to the old 22G VM shape.
- **Next (priority order)**: (1) resize colima VM 22G→12G **while it is still stopped** and restart the Mac fleet in one motion; (2) resolve PR #181's bead-ledger conflict and drive it green (do not merge until operator approves); (3) restart the jeff-ubuntu daemon when the load guard passes; (4) implement bead [jleechan-zmko](https://github.com/jleechanorg/ez-gh-actions/issues/) trim-guard repair.
- **Beads**: [jleechan-qbcm](https://github.com/jleechanorg/ez-gh-actions/issues/) (contract decision record), [jleechan-zmko](https://github.com/jleechanorg/ez-gh-actions/issues/) (VM right-size + trim guard), [jleechan-9ofp](https://github.com/jleechanorg/ez-gh-actions/issues/) / [jleechan-yib3](https://github.com/jleechanorg/ez-gh-actions/issues/) (pre-existing trim-guard/watchdog P0s), [ez-gh-actions-sa8c](https://github.com/jleechanorg/ez-gh-actions/issues/71) (host-OOM policy — gates the 16-runner restoration).

## Context

Work block: multi-day fleet operations on `jleechanorg/ez-gh-actions` (repo `/Users/jleechan/projects_other/ez-gh-actions`, branch `feat/x9n-registration-failure-alert`). Scope: fleet health on both hosts (MacBook + jeff-ubuntu), a live-config capacity reduction audit (20→14 Linux), CI queue tooling, a PR #10559 runner-disk-exhaustion fix (admission floor 30G), and a Mac disk emergency on the night of 2026-10-19/20. The Mac fleet is currently **paused** (daemon unloaded, colima stopped) as the deliberate emergency containment. CI is being served entirely by the 14-runner Linux fleet.

## Bead index

| Bead | Title | Link |
|------|-------|------|
| jleechan-qbcm | Track 14-Linux capacity contract reduction (24→18) + restoration condition + deploy steps | [br show jleechan-qbcm](https://github.com/jleechanorg/ez-gh-actions) |
| jleechan-zmko | Right-size Mac colima VM memory 22G→10-12G and repair dead colima-trim guard | [br show jleechan-zmko](https://github.com/jleechanorg/ez-gh-actions) |
| jleechan-9ofp | Mac Colima trim guard: reclaim discarded CI blocks before APFS admission outage (P0, pre-existing; guard proven dead since Oct 10) | [br show jleechan-9ofp](https://github.com/jleechanorg/ez-gh-actions) |
| jleechan-yib3 | Watchdog never runs its printed colima remediation; stale divergent deployed copy (P0, pre-existing) | [br show jleechan-yib3](https://github.com/jleechanorg/ez-gh-actions) |
| ez-gh-actions-sa8c | Host OOM kill order + protected reserve (P0 program; gates 16 @ 1750 MiB Linux restoration) | https://github.com/jleechanorg/ez-gh-actions/issues/71 |
| ez-gh-actions-hhkx | GOAL: restore fleet without host restart authority (P0; language predates 18-contract) | [br show ez-gh-actions-hhkx](https://github.com/jleechanorg/ez-gh-actions) |

## Work queue

1. **Resize colima VM memory 22GiB → 12GiB while it is still stopped, then restore the Mac fleet in the same motion.** This is the single highest-leverage action: the VM is stopped *right now* (zero extra downtime), 12 GiB fits the 4-runner envelope (4×2000 MiB + 2048 guest reserve ≈ 10.2G < 12G), and it directly implements [jleechan-zmko](https://github.com/jleechanorg/ez-gh-actions/issues/). Steps: edit `~/.colima/_lima/colima/colima.yaml` `memory: 12GiB`; `colima start`; update Mac config `vm_total_mb` 22528→12288 (`~/Library/Application Support/org.jleechanorg.ezgha/config.toml`); `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.jleechanorg.ezgha.plist`; verify 4 runners executing AND `sysctl vm.swapusage` total stays ≤ 8G during a CI burst. Acceptance: swap total ≤ 8G and free space flat across a 30-min burst; 18/18 contract intact.
2. **Resolve PR #181's `.beads/issues.jsonl` conflict** (the only conflicting file; `git merge-tree` confirms all else auto-merges). Use the beads union-sync flow (`br sync` on a main-rebased branch; never hand-merge the ledger). Then drive PR #181 to green (CI runs on the self-hosted fleet). **Do not merge** — operator approval boundary stands; merge releases the 18-contract to `main` and enables the jeff-ubuntu checkout to return to `main`.
3. **Restart the jeff-ubuntu daemon with the 18-contract binary** (already installed, embeds `029739b`). Guard: `load_1min < 12` AND `≥ 11/14` containers (CLAUDE.md rule). Until then its INV-1 alerts read `/24` (cosmetic phantom). After restart, verify the log line `INV-1 ... busy=X/18` and restore the checkout to `main` once PR #181 merges.
4. **Repair/replace the dead colima-trim guard** ([jleechan-zmko](https://github.com/jleechanorg/ez-gh-actions/issues/) + evidence to [jleechan-9ofp](https://github.com/jleechanorg/ez-gh-actions/issues/)): `~/.local/libexec/ezgha/colima-trim-guard.sh` died Oct 10 (`fork: retry`, `shlock: No space left on device`, `Killed: 9`); its launchd `StartInterval=60` (seconds) is also far too hot. Replace with the repo-standard nightly/bounded timer pattern (see the disk-magician systemd/launchd twins), cap runtime, and alert on failure.
5. **Monitor Mac recovery before step 1's fleet restart**: swap total was 18.4G and falling at 00:54 PDT. If it drains below ~8G without the fleet running, memory headroom is confirmed for the 12G VM shape. If swap usage climbs again while idle, the resident app zoo is the remaining pressure source — report before restoring runners.
6. **Standing (unchanged)**: Linux restoration to 16 @ 1750 MiB is gated on [ez-gh-actions-sa8c](https://github.com/jleechanorg/ez-gh-actions/issues/71) landing + host memory reclaimed; Mac-side, do not restore the 22G VM under any circumstances.

## Timeline and parallel lanes

| Elapsed estimate | Lane / owner | Scope / dependencies | Deliverable / proof |
|---|---|---|---|
| +0–20 min | Lane 1 — Mac VM resize + fleet restore (blocks nothing else on Mac) | colima.yaml edit; depends on colima being stopped (true now) | 4/4 runners executing; swap ≤ 8G sustained; `docker top` per-slot proof |
| +0–20 min (parallel) | Lane 2 — PR #181 conflict resolution | `.beads/issues.jsonl` union sync only; no file overlap with Lane 1 | Rebased branch, conflict-free `git merge-tree`, CI green |
| +20–60 min (parallel) | Lane 3 — jeff-ubuntu daemon restart | Only when load guard passes (independent of Lanes 1-2) | `INV-1 ... /18` in journal; fleet refills 14/14 |
| +1–3 h | Lane 4 — trim-guard repair (implementation) | After Lane 1 stabilizes (touches colima/trim surface) | New bounded timer installed; log shows successful trims |

- **Critical path**: Lane 1 (Mac capacity) → Lane 4 (trim guard); Lanes 2–3 are independent.
- **Concurrency ceiling**: 4 useful lanes; binding limit is **jeff-ubuntu host load** (CI queue) for Lane 3 and **operator merge approval** for Lane 2's final step. Label provisional until each lane's pre-flight (guard / swap level) is re-measured at execution start.
- **Milestones** (relative to execution start): +20m — VM resized, fleet restored OR guard still blocking (report which); +40m — PR conflict resolved, CI running; +60m (hourly rollup) — all lanes' proofs collected; repeat every 20m while active.
- **Execution start: pending authorized resumption; this handoff does not start it.**

## PR / merge state

- https://github.com/jleechanorg/ez-gh-actions/pull/181 — **OPEN** (draft), **mergeable: CONFLICTING** (`.beads/issues.jsonl` only). Carries: x9n registration-failure alerting, queue-trimmer 1.5h, capacity contract 24→18. **Do not merge** until the operator approves (standing instruction from 2026-10-20 session).
- main advanced past the branch base: `a58d17d` (Path-1 race fix), `b6b5db8` (#179 Mac 30G floor — converges with this branch's example-config change), `33a713d` (#180 Node cache in runner image).

## Learnings pointer

- `~/roadmap/learnings-2026-10.md` — section `2026-10-20 — Mac disk exhaustion was swapfiles, not CI data`: diagnose with `sysctl vm.swapusage` before blaming CI churn; swapfiles are invisible to du/find and reclaim slowly; a 22G VM pin on a 48G Mac is a standing swap minting machine.

## Roadmap pointer

- Appended `roadmap/activity/2026-10-20.md` (new date; README "Recent activity" date link added).
