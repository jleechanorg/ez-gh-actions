# Capacity finding: queue growth is organic demand, not a runaway loop

**Investigated**: 2026-07-07 ~13:14 PT, by sidekick2 (task #5 of the runner-truly-healthy mission)

## Question

Queued runs in jleechanorg/worldarchitect.ai grew 270 -> 267 -> 456 -> ~509-520 between
19:20 PT (mission start) and 13:14 PT — outpacing every drain effort. Is this a runaway
matrix/retry/loop (fixable) or genuine demand exceeding the 22-runner fleet (a capacity
finding, not a bug)?

## Method

Ran the sanctioned dry-run lever (`scripts/queue-backlog-drain.sh`, superseded-run
dedup, newest-per-branch+workflow) against the live queue:

```
QUEUE_REPO=jleechanorg/worldarchitect.ai ./scripts/queue-backlog-drain.sh --min-age-min 20
scan: repo=jleechanorg/worldarchitect.ai queued=507 groups=503 tail_older_than_min=454
      superseded_candidates=4 min_age_min=20 keep_per_group=1
```

Also sampled queued-run composition by workflow name and branch (first 100 of 509 via
GitHub API):
- Top workflows: Presubmit Checks (13), WorldArchitect Tests Directory-Based (13),
  Green Gate (10), Deploy PR Preview Rotating Pool (9), Self-Hosted MVP Shards (9),
  CodeRabbit ping (8), Coverage Report (8), Mobile Auth Regression (8), Design Doc
  Gate (6), + 6 more workflows each <5.
- Top branches: homunculus-qwen3-coder (13), feat/quick-start-campaign (10),
  fix/campaign-duplicate-batch (10), fix/rewards-box-not-showing-8020-v2 (10),
  feat/stripe-infrastructure (8), + dozens more each 1-7.

## Finding

**503 of 507 queued runs are in distinct (branch, workflow) groups — a 1:1 ratio.**
Only 4 runs are superseded duplicates prunable by the sanctioned dedup lever. No
single branch or workflow dominates (max 13 out of 507, ~2.5%). This rules out a
runaway matrix explosion or retry loop, which would show one branch/workflow with
hundreds of duplicate runs. Cross-checked against the live worktree fleet on this
box: `ls ~/projects | grep -c worktree_` shows **53 concurrent worktree_* directories**
(verified 2026-07-07 13:15 PT) for jleechanorg/worldarchitect.ai, evidence of dozens of parallel AI-agent coding
sessions each independently pushing commits/PRs that each trigger their own
Presubmit Checks + Green Gate + WorldArchitect Tests + Self-Hosted MVP Shards jobs.

**Conclusion: the queue growth is genuine, organic, broad-based CI demand from a
large concurrent-agent fleet, not a bug.** Superseded-cancellation and zombie-deletion
(the sanctioned levers) can only recover ~1% of the backlog at any sample point;
they are not a lever for closing this gap.

## Numeric capacity estimate

- Arrival: queued count grew from ~267 (12:44 PT) to ~509 (13:14 PT) = +242 net over
  30 min = **~8 net additional queued runs/min**, each run averaging ~2-4 self-hosted
  jobs (Presubmit + Green Gate + WorldArchitect Tests + sometimes Self-Hosted MVP
  Shards) => roughly **16-32 net additional self-hosted jobs/min** arriving faster
  than they complete.
- Capacity: 16 Linux + 6 Mac + 1 canary = 23 runner-equivalents. Doctor Gate 3 shows
  effective capacity further clamped under load (14 effective / 15 slots observed
  during this investigation, see STATE-mirror.md). At an optimistic 5-10 min average
  job duration, steady-state completion throughput is roughly **23 runners / 5-10 min
  ≈ 2.3-4.6 jobs/min** — an order of magnitude below the arrival rate implied above.
- **Gap: demand is running at roughly 3-10x the fleet's completion throughput** during
  this sampling window. This is consistent with, and quantifies, the goal doc's original
  caution ("worldarchitect.ai demand may structurally exceed 22-runner capacity").

## Recommendation (per E5 failure-honesty clause — not reframed as a fixable bug)

This is a scaling/demand-shaping decision, not something the mission's sanctioned
levers (drain + zombie cleanup) can close. Options for the user to decide between,
NOT unilaterally executed by any agent per the 22-runner denominator rule in E3:
1. Increase runner count (capacity scaling) — requires explicit user-approved
   change to the 22-runner denominator (E3 constraint).
2. Reduce concurrent-agent fleet size on this box (fewer simultaneous
   worktree_* AI coding sessions each generating their own CI load) — a scheduling/
   demand-shaping decision outside ez-gh-actions' scope.
3. CI-demand reduction in worldarchitect.ai itself — the SC8 CI-check value audit
   (PR #8214, lane-f) targets exactly this: removing low-value checks (e.g.
   redundant CodeRabbit ping, limit-pr-runs as a separate job) so each push
   consumes fewer self-hosted-job-minutes. This helps but is unlikely to close a
   3-10x gap alone since it doesn't reduce the number of *branches* pushing.

No further mission cycles should be spent trying to "drain" this queue with the
sanctioned levers alone — they were already run and only reclaim ~1% of backlog.
The right framing for E2/E5 sign-off is: INV-1 will very likely keep failing during
periods of high concurrent-agent activity on this box, for capacity reasons outside
ez-gh-actions' own code, not because the daemon or monitor is broken.

## Update: measured JOB-level demand is much higher than the run-level estimate

The E1 daemon-native sampler's first real sample (ts=1783457458, ~13:51 PT,
`~/.local/state/ezgha/invariant_history.jsonl`) measured
**`queued_jobs: 1290`** — the actual count of queued self-hosted JOBS across
both monitored repos, not run objects. This is the ground-truth number the
goal doc's own opening caution warned about ("run-object counts are FORBIDDEN
as a measurement... proven misleading"): the ~509-520 run-level figure used
above undercounts true demand. 1290 jobs / ~509 runs ≈ 2.5 self-hosted jobs
per run, which is in the same ballpark as this doc's earlier "~2-4 jobs per
run" assumption, but now measured rather than assumed, and the absolute
number (1290 queued jobs against 22 runner-equivalents) makes the gap far
starker: oldest_queued_job_min was 72.05 at that sample (3.6x the 20-min
threshold), and INV-1 failed with `inv1_fail_class: "missing-registration"`
(only 19 of 22 expected runners registered at sample time — see
ez-gh-actions-po2, the durable respawn-pacing fix bead, for that half of the
gap). Going forward, `queued_jobs` from invariant_history.jsonl (not run
counts) is the authoritative demand metric for this finding.
