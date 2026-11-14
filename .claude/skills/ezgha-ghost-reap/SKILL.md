---
name: ezgha-ghost-reap
description: Reap ghost GitHub Actions workflow runs (status=queued with zero jobs). Use when queued-run counts look inflated, the queue never drains despite idle runners, or an agent needs to explain why a stuck-queued run cannot be cancelled.
---

# ezgha ghost reap — cancel/delete zero-job queued runs

Marker: `EZGHA_GHOST_REAP_SKILL_V1`

## What a ghost is

A run record with `status=queued`, `run_attempt=1`, `updated_at == created_at` (never
touched since creation), and `jobs.total_count == 0`. No job was ever created, so nothing
is scheduled and the run never consumes a runner. Ghosts inflate every queued-run count.

## The operation sequence, and why

`DELETE .../actions/runs/{id}` is documented with **no status precondition** but returns
**403** while a run is still `queued`. The run must first leave queued:

1. re-check it is still queued (race guard — a run can be picked up after days)
2. `POST .../cancel` (expect 202)
3. wait, re-check; if still queued → `POST .../force-cancel`
4. re-check; only then `DELETE .../actions/runs/{id}` (expect 204)

Plain `cancel` returning **202 can silently no-op** on runs whose only job never started
(`runner_id:0`, bead jleechan-uud) — the ghost profile exactly. Never trust the 202.

## The dead-end population (read this before promising a cleanup)

There is a wedged subclass that **no documented API path can remove**:

| Attempt | Result |
|---|---|
| `POST .../cancel` | **409** `Cannot cancel a workflow run that has not been queued yet.` |
| `POST .../force-cancel` | **409** same |
| `DELETE .../actions/runs/{id}` | **403** `Could not delete the workflow run` |

The 409 text is the tell: GitHub does not consider the run to have reached the queue, so
nothing can transition it and delete never becomes legal.

**Measured 2026-11-14 on `jleechanorg/worldarchitect.ai`: 149 of 149 zero-job queued runs
are in this state — 0 reaped.** The script reports `wedged_unreapable` (cancel/force-cancel
409) separately from `delete_403` (delete refused) so the two are not conflated. Do not
retry these every cycle; they cost API budget and change nothing.

Note the reaper's historical successes (`deleted zombie 39912506885` in
`~/.local/state/ezgha/queue-reaper.log`) came from an **earlier** population that was not
wedged this way. Past success does not predict success on today's ghosts.

## Run it

```bash
# dry run (default) — never mutates
python3 .claude/skills/ezgha-ghost-reap/scripts/reap_ghosts.py

# apply, targeting runs older than 2h
python3 .claude/skills/ezgha-ghost-reap/scripts/reap_ghosts.py --apply --min-age-min 120

# bounded probe before a full sweep
python3 .claude/skills/ezgha-ghost-reap/scripts/reap_ghosts.py --apply --limit 5
```

Options: `--repo`, `--apply`, `--min-age-min`, `--limit`, `--verify-wait`, `--json`.

Exit codes: `0` ok, `2` measurement/API failure, `3` partial (wedged/403/failed present),
`4` rate-limited.

## Mandatory safety invariants

- **Dry run by default.** `--apply` is required for any mutation.
- **Ghost proof.** Eligible only when `jobs.total_count == 0` **and** `status == queued`,
  re-verified immediately before acting. Never act on a cached list.
- **Deploy workflows are never touched** — matched on workflow `path`, not display name
  (`NEVER_CANCEL_PATHS`). A cancelled deploy is worse than a slow queue (FIXPLAN §5 risk #1).
- **Race guard.** Re-check still-queued right before each destructive call.
- **Budget.** Each run costs 2–4 core requests. A 149-run sweep exhausts a 5,000/hr budget;
  check `gh api /rate_limit` first, and do not run alongside other heavy `gh` work.
- **Report, do not retry.** A `wedged_unreapable`/`delete_403` outcome is terminal. Surface
  it; do not loop.

## Reporting

State: how many queued runs were scanned, how many were eligible ghosts, how many deploy
runs were protected, and the outcome histogram. If every candidate came back
`wedged_unreapable`/`delete_403`, say plainly that **cleanup is not possible via the
documented API** and that the ghosts will remain until GitHub's own retention removes them.
Do not report a ghost cleanup as done when 0 runs were reaped.
