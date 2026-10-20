# Nextsteps — ezgha Release 1 crash containment — 2026-09-01

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- Planning is closed. After 29 containment-document commits in about 11 hours and no Release 1 implementation, the reviewed design now has a hard execution ceiling.
- Release 1 has exactly three outcomes: finite policy/assertion, fail-closed HostDocker admission, and one canonical activation path.
- Work is serialized into six TDD beads under existing parent `ez-gh-actions-sa8c`; no parallel program or broader criterion was created.
- The only next action is causal RED bead [ez-gh-actions-sa8c.1 / #142](https://github.com/jleechanorg/ez-gh-actions/issues/142). No new design, review, roadmap, memory, deployment, or outcome-monitoring work begins while that RED is unresolved.
- A separate coding agent owns that next action. This planning session does not claim a bead, edit implementation, merge, rebuild, deploy, or activate services.
- `/advice` independently approved the exact design/plan content using Codex and Opus. AI Universe `/secondo` was unavailable because its token was expired; browser review was disabled by the `/sq` authorization boundary.

## Context

The active repository is `/home/jleechan/projects/ez-gh-actions` on branch `docs/nextsteps-2026-08-30-fleet-churn`; [PR #139](https://github.com/jleechanorg/ez-gh-actions/pull/139) is open and remains a documentation/planning PR. Release 1 implementation has not started, and the live host is not changed by this planning block. The reviewed design preserves ten Linux HostDocker runners and adds finite systemd cgroup-v2 policy, fixed admission, and canonical activation; security redesign, VM fallback, scheduling, queue work, Mac changes, and global-OOM proof remain non-goals. The overall contract is [the existing fleet goal](goal-ironclad-2026-08-30-fleet-resilience.md), and the micro-plan is `/home/jleechan/roadmap/2026-09-01-ezgha-runner-crash-containment-plan-micro.md`.

## Bead index

| Bead | Title | Priority / status | Link |
|---|---|---|---|
| `ez-gh-actions-sa8c` | Existing finite OOM-policy implementation parent | P0 / in progress | `br show ez-gh-actions-sa8c` |
| `ez-gh-actions-e0z0` | Existing ten-runner availability program | P0 / open | `br show ez-gh-actions-e0z0` |
| `ez-gh-actions-e0z0.2` | Existing portable profile/install owner | P0 / open | `br show ez-gh-actions-e0z0.2` |
| `ez-gh-actions-hhkx` | Existing 16/16 no-host-restart goal | P0 / open | `br show ez-gh-actions-hhkx` |
| `ez-gh-actions-0vzn` | Existing guarded deployment gate | P0 / in progress | `br show ez-gh-actions-0vzn` |
| [ez-gh-actions-sa8c.1](https://github.com/jleechanorg/ez-gh-actions/issues/142) | Finite boundary tests (RED) | P0 / open | [#142](https://github.com/jleechanorg/ez-gh-actions/issues/142) |
| [ez-gh-actions-sa8c.2](https://github.com/jleechanorg/ez-gh-actions/issues/143) | Finite boundary implementation (GREEN) | P0 / open | [#143](https://github.com/jleechanorg/ez-gh-actions/issues/143) |
| [ez-gh-actions-sa8c.3](https://github.com/jleechanorg/ez-gh-actions/issues/145) | Fail-closed admission tests (RED) | P0 / open | [#145](https://github.com/jleechanorg/ez-gh-actions/issues/145) |
| [ez-gh-actions-sa8c.4](https://github.com/jleechanorg/ez-gh-actions/issues/146) | Fail-closed admission implementation (GREEN) | P0 / open | [#146](https://github.com/jleechanorg/ez-gh-actions/issues/146) |
| [ez-gh-actions-sa8c.5](https://github.com/jleechanorg/ez-gh-actions/issues/144) | Canonical activation tests (RED) | P0 / open | [#144](https://github.com/jleechanorg/ez-gh-actions/issues/144) |
| [ez-gh-actions-sa8c.6](https://github.com/jleechanorg/ez-gh-actions/issues/147) | Canonical activation implementation (GREEN) | P0 / open | [#147](https://github.com/jleechanorg/ez-gh-actions/issues/147) |

## Work queue

1. **Produce finite-boundary RED** — [ez-gh-actions-sa8c.1](https://github.com/jleechanorg/ez-gh-actions/issues/142). Change only the four named policy/assertion tests. Acceptance is a causal failure from missing Release 1 behavior within the first 30-minute executable checkpoint.
2. **Make the finite boundary GREEN** — [ez-gh-actions-sa8c.2](https://github.com/jleechanorg/ez-gh-actions/issues/143), blocked by `.1`. Implement tracked policy, remove watcher/exemption artifacts, and add the read-only assertion without editing tests.
3. **Produce admission RED** — [ez-gh-actions-sa8c.3](https://github.com/jleechanorg/ez-gh-actions/issues/145), blocked by `.2`. Add test-only Rust evidence for zero pre-admission mutation and post-create ancestry compensation.
4. **Make admission GREEN** — [ez-gh-actions-sa8c.4](https://github.com/jleechanorg/ez-gh-actions/issues/146), blocked by `.3`. Implement canonical Docker command routing and fixed-Linux admission without editing tests.
5. **Produce activation RED** — [ez-gh-actions-sa8c.5](https://github.com/jleechanorg/ez-gh-actions/issues/144), blocked by `.4`. Add test-only bundle, immutable-preflight, frozen-migration, and inactive-service fixtures.
6. **Make activation GREEN** — [ez-gh-actions-sa8c.6](https://github.com/jleechanorg/ez-gh-actions/issues/147), blocked by `.5`. Implement the bundle/activation/install path without editing tests or activating it live. Then run one integrated independent review and expensive outcome evidence once and last.

Every 30 minutes must end with fresh RED or GREEN command output. After two complete gate cycles or three total hours, stop with the exact failing command and blocker. A non-blocking style, wording, margin, or broader-hardening observation becomes a follow-up and does not restart planning.

### Coding-agent handoff

- Start from the latest `origin/docs/nextsteps-2026-08-30-fleet-churn` in an isolated branch/worktree; reviewed planning content begins at `fcd0b9e188cffec87fecf56ad3fa294a488306ba`. Claim only `ez-gh-actions-sa8c.1`.
- Read `/home/jleechan/roadmap/ez-gh-actions/ironclad/ez-gh-actions-sa8c.1-goal-ironclad-2026-09-01.md`; change only its four owned test files.
- The first checkpoint is a causal RED from `bash tests/host_crash_containment_release1_artifacts_test.sh` and `bash tests/assert_host_containment_release1_test.sh`.
- Do not begin `.2`, alter production code, or activate host state until `.1` is independently reproduced and committed.

## PR / merge state

- [PR #139](https://github.com/jleechanorg/ez-gh-actions/pull/139): **OPEN**, non-draft, mergeable, and **UNSTABLE** when refreshed on 2026-09-01. CI, both self-hosted tests, secret scans, and CodeRabbit were successful; `virtiofs-canary` was queued. The Beads Regression Guard failed because closed historical bead `jleechan-q8y` was missing from the branch export; this refresh restores the exact base record for the next push.
- The PR remains planning state, not implementation evidence. Do not call `/ready`, merge, rebuild, deploy, or activate from this handoff.
- Issues [#142](https://github.com/jleechanorg/ez-gh-actions/issues/142), [#143](https://github.com/jleechanorg/ez-gh-actions/issues/143), [#144](https://github.com/jleechanorg/ez-gh-actions/issues/144), [#145](https://github.com/jleechanorg/ez-gh-actions/issues/145), [#146](https://github.com/jleechanorg/ez-gh-actions/issues/146), and [#147](https://github.com/jleechanorg/ez-gh-actions/issues/147) are **OPEN**.

## Learnings pointer

- `/home/jleechan/roadmap/learnings-2026-09.md` — `2026-09-01 — Runner containment delivery over process`: planning and review support delivery but cannot displace executable TDD increments.

## Roadmap pointer

- Appended `roadmap/activity/2026-09-01.md` and added its first-date pointer to `roadmap/README.md`.
- Updated [the existing fleet goal](goal-ironclad-2026-08-30-fleet-resilience.md) with the bounded Release 1 contract.
- Detailed micro-plan: `/home/jleechan/roadmap/2026-09-01-ezgha-runner-crash-containment-plan-micro.md`.
- Claude memory was updated at `/home/jleechan/.claude/projects/-home-jleechan-projects-ez-gh-actions/memory/`; mem0 was unavailable because `/home/jleechan/.hermes/scripts/mem0_shared_client.py` is absent.
