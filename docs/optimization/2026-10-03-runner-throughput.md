# Nextsteps — runner throughput optimization — 2026-10-03

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

Prioritize demand reduction and Mac contention: consolidate short gates, avoid superseded queued heads, and stop repeated automated branch refresh from invalidating ongoing gates. Measure Linux turnover before changing the runner lifecycle. Keep the configured 14 Linux + 6 Mac capacity contract and prove execution using actual Runner.Worker processes.

This is a lean planning handoff. Existing Beads are updated; production implementation has not started. The reported 30% lifecycle loss and 2–3x Mac runtime penalty are hypotheses awaiting comparable measurements. A full swap device is not evidence of current memory pressure.

## Context

Scope: ez-gh-actions at /Users/jleechan/projects_other/ez-gh-actions, Linux host jeff-ubuntu, and consumer workflow/queue policy in worldarchitect.ai. The current checkout is fix/harness-fleet-outage-impl and contains substantial pre-existing dirty work; future code changes need isolated worktrees. The prior audit used SSH for Linux and observed a local cmux workspace; it did not independently inspect the Linux Warp tab cited by the user. That transcript is supplied evidence, not a verified automation attribution.

Session observations around 14:24–14:28 PDT: Mac doctor reported load 222.35 on 14 cores, 5/6 containers, 3 recent Docker timeout messages and 6 settling warnings; Linux journal counted 37 reclaims and respawns over ten minutes, 4 settling ceilings and 2 stats errors. A separate direct Linux docker top sample found Workers in all ten containers. These are dated samples, not current fleet health or a continuous utilization measurement.

User-supplied audit additionally reports 154 Linux reclaims/15m, 15–25s micro-jobs, 7–9s lifecycle overhead, 3.2–4.5s Mac probes, repeated automated main merges, and a 2–3x Mac runtime penalty. Retain these as candidate explanations. At 15s work plus 7–9s overhead, hypothetical per-job overhead is 32–38%; extrapolating to the whole fleet requires the actual job mix and slot-time denominator. Peak runner RSS alone does not identify workflow type or full process-tree memory use.

Fresh Linux follow-up confirmed PID 291901 is baobab, VmSwap 4,518,936 kB and RSS 66,344 kB. Memory PSI some/full averages were 0.00; two live vmstat intervals showed si=0, so=0 and CPU idle 87%/85%. The first vmstat line is a since-boot average. This does not support an immediate swap reset for throughput.

Current source confirms LOCAL_TOP_TIMEOUT=3s and LOCAL_READINESS_BUDGET=30s. Sequential readiness probes consume the shared remaining deadline. The readiness implementation counts Runner.Listener as well as Runner.Worker, despite its executing terminology. Deployed binary behavior must be pinned separately before attributing source behavior to either host.

## Bead index

Beads have no confirmed issue URLs for this handoff. Links point to their self-contained task descriptions below; resolve live records using the listed br command from the ez-gh-actions checkout.

| Bead | Priority / status | Title and lookup |
|---|---|---|
| [jleechan-95jk](#mac-contention-and-probe-budget) | P1 / open | Mac host overload; `br show jleechan-95jk` |
| [ez-gh-actions-ghd2.1](#linux-lifecycle-measurement) | P0 / open | Linux reclaim/refill amplification; `br show ez-gh-actions-ghd2.1` |
| [ez-gh-actions-ghd2.4](#queue-and-micro-job-demand) | P1 / open | Cancellation waste and final-gate latency; `br show ez-gh-actions-ghd2.4` |
| [jleechan-yiz](#automated-branch-refresh) | P3 / open | Push batching and CI demand; `br show jleechan-yiz` |

## Work queue

### Queue and micro-job demand

1. **Measure and reduce avoidable queued work** — [ez-gh-actions-ghd2.4](#bead-index). Owner: queue/workflow lane. Inspect /Users/jleechan/.claude/skills/ci-queue-trim/scripts/ci_queue_trim.py and the deployed consumer workflow definitions. The script fetches run headSha (around line 90), uses head committer date (279–288), falls back to run age on missing commit data (322), and retains runs on a fresh branch without head comparison (342–344). Capture workflow/event/run SHA/current PR head and merge-ref semantics. Failed identity lookup must produce UNKNOWN and preserve the run; revalidate candidates immediately before cancellation. Protect main, deployment/release work and distinct required workflows. Existing local test.yml and presubmit.yml already use cancel-in-progress; inspect the actual remote versions and groups before adding new concurrency rules.

   Measure short-job execution time, completed jobs, failure outcomes, container lifecycle time and runner-minutes by workflow over 15–30 minutes. Consolidate lightweight gates into a preflight job where required status names, permissions, triggers and failure isolation can be preserved. Moving to ubuntu-latest is an optional alternative after checking private-repo policy, cost and secrets/network requirements. Acceptance: same required gates and semantics, fewer runner-minutes per completed required check, fewer superseded queued runs, and improved job-level queue p90 under comparable arrivals. No cancellation based solely on stale-looking timestamps.

### Automated branch refresh

2. **Keep an active review/CI head stable** — [jleechan-yiz](#bead-index). Owner: automation lane; depends on identifying the real writer. Correlate the user-supplied Warp report with automation logs, branch update events and cancelled runs. Locate the scheduler or agent policy actually merging main; do not attribute it from commit subjects alone. Coalesce updates and hold automatic refresh through a bounded review/test interval, refreshing once afterward when required. Preserve explicit conflict/security refresh and a timeout escape for stalled work. Acceptance: one stable head through gate completion, no repeated invalidation solely because main advanced, and measured reduction in consumed cancelled-run minutes. This plan does not authorize a force push or indiscriminate service stop.

### Mac contention and probe budget

3. **Restore useful Mac slot time before expanding resources** — [jleechan-95jk](#bead-index). Owner: Mac lane. Pin Docker endpoint, active service executable/config and 6-slot prefix. Measure host CPU consumers, available RAM/pressure, VM CPU utilization, container throttled CPU time, top/inspect latency distribution, refill latency and per-slot Worker occupancy. Source area: src/docker_backend.rs timeout constants, executing_runner_count_from_containers, local_runner_activity and resource clamping. Attribute contention to actual workloads before choosing remediation.

   Evaluate 6–8s probes only with a whole-pass deadline analysis: six 8s probes cannot all fit 30s; even six 4.5s probes leave only 3s for listing and other work. Preserve Unknown activity safety and bounded recovery progress. Prefer reducing contention and eliminating redundant probes before blindly extending waits. Acceptance: measured p95/p99 probes fit the chosen budget, no false stale reclaim, lower completion-to-replacement latency, and full six-slot Worker proof under backlog. Compare the same workflow, shard, revision and cache condition across hosts before claiming 2–3x slowdown. Raising VM CPU on a heavily loaded physical host may worsen contention; preserve the 6+14 contract rather than reducing runner count to make a graph look better.

### Linux lifecycle measurement

4. **Separate legitimate micro-job turnover from failed recycling** — [ez-gh-actions-ghd2.1](#bead-index). Owner: Linux lane. Capture bounded Docker event timestamps/container IDs, job start/end/outcomes, daemon reason codes and local Worker samples against the exact active backend. Correlate job completion -> container exit -> replacement registration -> next Worker. Count successful jobs/hour, failed launches, orphaned work, average/p95 gap and unavailable slot-seconds divided by configured slot-seconds. Never infer failure or 30% fleet loss from reclaim count or last_run_id=0 alone. The source readiness count accepts listeners, so its executing logs do not satisfy Worker-per-slot proof.

   Acceptance: every sampled reclaim classified with supporting event evidence; optimization targets the largest measured waste category; all fourteen Linux slots demonstrated executing under backlog; a comparable before/after interval improves useful throughput without killing live work. Any implementation regression checks must cover the actual measured failure, including consecutive reconciliation ticks if relevant.

5. **Keep swap and cache work conditional.** The current Linux PSI/vmstat follow-up shows no active memory stall. Do not run swapoff/swapon or terminate baobab solely to make swap usage zero. If pressure recurs, attribute swap-in/stall time and identify whether the GUI task is actually disposable before a targeted close. Reuse existing jleechan-93cf workspace/cache isolation and jleechan-yov cold-start tasks only if profiling shows checkout/dependency installation is material; these historical tasks are not evidence of a current measured saving. Persisted caches need trust isolation, version keys and bounded storage.

## Timeline and parallel lanes

The handoff used one independent read-only queue scout alongside the root tracker/source lane. Admission measurement: (3,980 free + 519,853 inactive + 25,281 speculative + 0 purgeable) * 16,384 = about 8.38 GiB available; pressure=2. Virtualization.framework was the top RSS consumer reported. Two lanes ran within four available agent slots. High observed host load argues against adding benchmark load during planning.

Future execution estimates start only after implementation is requested; refresh host admission first. Four independent questions exist, but with root coordination the provisional ceiling is three worker lanes. Each writer owns isolated files/worktrees; queue workflow and automation changes serialize if they share files or policy.

| Elapsed estimate | Owner / exclusive scope | Dependency and deliverable |
|---|---|---|
| 0–30m | Queue lane: queue-tool/workflow inspection; Mac lane: Mac read-only telemetry; Linux lane: Linux read-only event correlation | Root pins deployed state; produce comparable baseline and source attribution |
| 30–60m | Root synthesis + automation lane replacing completed queue discovery | Rank measured savings, verify automatic refresh owner, choose smallest intervention |
| 60–120m | Queue/automation owner; Mac owner; Linux owner only if a lifecycle defect was proven | Isolated implementation proposals and focused checks; serialize shared files |
| 120–150m | Root + independent verifier | One final comparable validation interval; queue p90, required job throughput, lost slot-seconds, Worker-per-slot proof |

Critical path: baseline and cause attribution -> selected minimal change -> final measurement. Report milestones at +20m, +40m and +60m/hourly, then repeat while execution remains active. These are estimates, not a promised daemon or already-started implementation.

## PR / merge state

No PR is proposed for merge or used as a dependency in this handoff. Historical PR references inside older Beads were not re-endorsed. Current branch contains unrelated changes and prior commits; artifacts are local planning updates, not deployed optimization or a merge verdict.

## Learnings pointer

[October learnings](/Users/jleechan/roadmap/learnings-2026-10.md): 2026-10-03 — Runner throughput optimization evidence. Records denominator-based utilization, listener-vs-Worker semantics, bounded probe budgets and swap-pressure qualification.

## Roadmap pointer

[Session activity](/Users/jleechan/projects_other/ez-gh-actions/roadmap/activity/2026-10-03.md) appended; roadmap/README.md receives the new date link. A new topic document was chosen because the existing latest document concerns a merge incident and the September ezgha document concerns recovery/alerts, not this October throughput plan.
