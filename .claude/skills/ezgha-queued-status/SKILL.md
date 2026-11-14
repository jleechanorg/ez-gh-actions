---
name: ezgha-queued-status
description: Measure real CI queue depth and job pickup wait for any repo, without counting ghost workflow runs. Use when asked whether the CI queue is OK, how long jobs are waiting, why checks look stuck queued, or whether runners are the bottleneck.
---

# ezgha queued-status — real queue depth and pickup wait

Marker: `EZGHA_QUEUED_STATUS_SKILL_V1`

## Why the raw number is wrong

`gh api .../actions/runs?status=queued` is **not** a backlog metric. It returns a large
population of *ghost* runs — records whose check suite never expanded, so
`jobs.total_count == 0`. A ghost has nothing to schedule and never occupies a runner, but
it counts as "queued" forever.

Measured 2026-11-14 on `jleechanorg/worldarchitect.ai`: **~160 queued runs, 149 of them
ghosts.** Reading the raw figure produced confident, wrong conclusions — "the queue is
backed up", "runners are starving the queue", "a label has no eligible runner". Ghosts also
explain the standing bead `bd-5h44` ("149 queued runs with 18 idle runners"): idle runners
never consumed those runs because those runs had no jobs to place.

## Run it

```bash
python3 .claude/skills/ezgha-queued-status/scripts/queued_status.py
python3 .claude/skills/ezgha-queued-status/scripts/queued_status.py --repo owner/name
python3 .claude/skills/ezgha-queued-status/scripts/queued_status.py --json
```

Exit `2` + `MEASUREMENT FAILED: …` on API error or rate limit. **A failed measurement is
never a zero** — never report "queue empty" from a non-zero exit or from a body carrying
`message` without `total_count`. Re-run after the reset (`gh api /rate_limit`).

## What to report, in this order

1. **Ghost vs live split.** The backlog is `live`, never the raw total. State both.
2. **Live queue depth.** Job-level queued count across live runs.
3. **Pickup wait** — `started_at − created_at` per job. Median/p90/max, not one run's age.
4. **Fleet registrations at org level** — labelled as GitHub's view, never as live
   capacity. Say explicitly that these are registrations.
5. **Interpretation.** You may NOT conclude capacity from the API. Idle registrations +
   waiting jobs is suggestive, not proof. Zero idle + waiting jobs is **not** saturation:
   a fully-offline runner prefix produces the identical API shape (measured
   2026-11-14 — every `ez-runner-c-*` offline read as "genuine capacity pressure").
   Report **capacity: UNKNOWN** and direct the operator to `./doctor-runner` for
   per-slot `Runner.Worker` truth, unless you have run that local probe yourself.

**Never** present the API snapshot as confirmation of fleet health. `AGENTS.md`: the
GitHub API cannot be trusted for fleet state. A parked leg is DISABLED, not DOWN — see
`MAC_RUNNER_DISABLED` / `REMOTE_LINUX_DISABLED`; do not report a parked leg as an
outage.

## Rules this encodes

- **Classify ghosts by timestamp, confirm by jobs.** Ghost ⇔ `updated_at == created_at` and
  older than 15 min. A run created seconds ago matches the timestamp test only because
  nothing has happened yet, so those fresh runs are resolved via `jobs.total_count` instead
  of being guessed. A bounded sample is re-confirmed against the jobs endpoint each run, so
  a change in GitHub's behaviour surfaces as a WARN, not a silent wrong number.
- **Never use a run's `created_at` age as queue wait.** A run can be hours old while its
  jobs were created minutes ago (e.g. a run created 18:06 whose shard jobs were created
  19:13). Run age measures suite latency, not runner contention.
- **Query runners at org level** (`/orgs/{org}/actions/runners`). Repo-level
  `/repos/.../actions/runners` returns `0` on these repos and looks like an empty fleet.
- **One sample is not a trend.** Queue depth moves within a minute; take two samples a few
  minutes apart before calling anything rising or draining.
- **Read-only.** This skill never cancels or deletes. Reaping is `ezgha-ghost-reap`.

## Relationship to the other queue tools

| Tool | Owns |
|---|---|
| `ezgha-queued-status` (this) | measuring the queue |
| `ezgha-ghost-reap` | removing ghosts (cancel → force-cancel → delete) |
| `scripts/cleanup-stuck-runs.sh` | the scheduled multi-repo reaper (`--apply`, 6h launchd) |
| `scripts/ttv_zombie_reaper.py` | age-only zombie scan (never reads `jobs`) |

Cross-check worth keeping: on 2026-11-14 the age-only reaper reported 149 zombie candidates
while this skill independently measured 149 ghosts — agreement between an age-only scan and
a jobs-confirmed classification is a validity signal. A large **disagreement** means one is
wrong; investigate and prefer the jobs-confirmed figure.

Note that the scheduled reaper exits `0` even when it skips a tick for rate limiting
(`SKIP TICK: /actions/runs still rate-limited`). A green reaper job is not evidence that
cleanup happened — check the log for `zombie_deleted` counts.
