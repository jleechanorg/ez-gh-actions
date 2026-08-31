# ez-gh-actions next steps — child-layer fleet churn after watchdog removal

## Verdict

The physical-host boundary remains the invariant: a job may fail, then its runner
process or container, then its VM; ezgha automation must never reboot, shut down,
force-panic, or restart the physical host. The live ironclad goal is **FAIL** until
the fixed-duration 16-slot proof in
[`goal-ironclad-2026-08-30-fleet-resilience.md`](goal-ironclad-2026-08-30-fleet-resilience.md)
passes at one merged and deployed revision.

The current root-cause route is **under-instrumented, with a bounded first-divergence
hypothesis**. Normal Docker event streams observed managed runners exit with code 0
and be destroyed after jobs. During the same periods, the single-threaded settling
episode continued polling while ready-container counts regressed (for example,
Linux 9→7→5 and Mac 3→1), delaying reconciliation. This supports a narrow settling
regression test; it does not prove every historical reclaim was normal completion.

## Baseline captured without deployment

- Linux and Mac Docker events showed managed containers ending with `exitCode=0`,
  followed by `destroy`; no forced host or container failure was injected.
- A later bounded sample observed Linux 9/10 then 7/10 and Mac 3/6 then 1/6 while
  both physical-host boot identities stayed unchanged.
- Mac runner admission was also blocked by its 10 GiB free-space floor. Removing
  only regenerable caches recovered free space from about 3 GiB to about 24 GiB;
  the existing daemon then replenished runners without a daemon or host restart.
- This baseline identifies normal completion/container disappearance in the
  sampled `gh-missing-no-local-container` cases, but does not yet provide the
  durable per-slot run/job correlation required for final acceptance.

## PR topology and publication blockers

| PR | Accurate scope | Required disposition |
|---|---|---|
| [#139](https://github.com/jleechanorg/ez-gh-actions/pull/139) | Publishes this plan, its activity pointer, beads, and the ironclad goal. | Preserve `jleechan-q8y`, retain the provenance-compliant title, require exact-head green checks, and keep the full plan in-repo rather than pointing only to a local home-directory file. |
| [#134](https://github.com/jleechanorg/ez-gh-actions/pull/134) | Eight commits and a broad Docker subprocess-lifecycle diff, including readiness timing, child reaping, and timeout behavior for Docker commands. | Do not describe or deploy it as a one-second readiness tweak. Split the original readiness-only commits onto current main, or explicitly reclassify and review it as broad lifecycle work. |
| [#136](https://github.com/jleechanorg/ez-gh-actions/pull/136) | Draft lifecycle instrumentation. Durable evidence is written when a local container remains but registration disappears; the principal no-local-container path remains volatile. | Keep draft and narrow its diagnostic claim, or extend it test-first to record normal completion/container disappearance with bounded durable evidence. Docker event samples do not substitute for the missing durable path. |

## Ordered work queue

1. Repair and publish PR #139 at its exact head: restore the protected bead, keep
   provenance checks compliant, and commit this complete plan under `roadmap/`.
2. Preserve the undeployed baseline above and capture additional normal serve-tick
   evidence only. No pressure, panic, reboot, watchdog, or host-restart testing.
3. Add a regression test for settling-count regression. The expected decision is
   immediate reconciliation when `executing < best_executing`; unchanged or
   improving startup evidence may retain bounded polling. Record RED then GREEN.
4. Resolve PR #134's scope before publication or deployment. One rollout SHA must
   contain one reviewed behavioral change.
5. Keep PR #136 draft unless its claim is narrowed, or extend the exact
   no-local-container evidence path with tests and bounded storage semantics.
6. Obtain exact-head CI and cross-model review for the selected minimal change.
7. Deploy to one host only after its **1-minute load average** is `<12` in three
   consecutive samples 30 seconds apart and active jobs drain. Linux `<8` or Mac
   `<4` containers is an immediate abort floor, not a success condition.
8. Require the first host to return to its full configured capacity (10/10 Linux
   or 6/6 Mac) with no new unexplained reclaim cluster before touching the other.
9. After both hosts run the same merged SHA, collect a 10-minute ledger every 30
   seconds. Every sample must contain all 16 slots and, per row: timestamp, host,
   slot, container ID, `Runner.Worker` PID, workflow run ID, and workflow job ID.
10. Run `./doctor-runner`, verify both installed binary SHAs, and compare both boot
    identities to the pre-rollout values. Any missing row, capacity dip, unexplained
    reclaim cluster, boot change, or prohibited test leaves the goal **FAIL**.

## Non-negotiable evidence rules

- GitHub runner counts cannot prove capacity; local `docker ps` and `docker top`
  are authoritative for the named slots.
- A capacity floor prevents cascading damage. Only stable configured capacity
  permits progression to the second host.
- A transient 16/16 frame, an idle listener, a daemon self-report, or an
  implementer-only assertion cannot close the goal.
- The physical host must retain the same boot identity throughout verification.
