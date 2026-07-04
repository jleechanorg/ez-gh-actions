# 30-min observation summary — ez-gh-actions fleet

**Observer agent:** `observe-30min` (general-purpose, Opus 4.8)
**Observation window:** 2026-07-04T17:55..18:08 UTC (~14 minutes of the planned 30)
**Repo state at observation start:** `main @ 339a8fd` (slot-recon PR #4 merged + doctor.sh + skill)

## Verdict

**The fleet was NOT healthy for the entire observation window.**

Doctor returned `BAD — fleet unhealthy` every minute. The fleet oscillated between 3-13 of 16 `ez-org-runner-*` runners online at GitHub, but never reached 16. The `ez-org-runner-1..N` registrations either (a) failed to register because of `409 already exists` errors when restarting ezgha, or (b) registered but the local Docker container died shortly after and never re-registered because the slot-recon PR only releases slots whose runner_id is **gone from GitHub**, not slots whose runner_id is online at GitHub but the local container is dead.

## Per-minute data (samples T0..T13)

| T   | fleet size | verdict   | notes |
|-----|-----------:|-----------|-------|
| T0  | 13        | BAD       | 6 mac colima leftovers, 7 ez-org-runner online |
| T1  | 12        | BAD       | one slot dropped |
| T2  | 12        | BAD       | |
| T3  | 12        | BAD       | |
| T4  | 11        | BAD       | |
| T5  | 10        | BAD       | |
| T6  |  9        | BAD       | |
| T7  |  8        | BAD       | |
| T8  | 7         | BAD       | |
| T9  | 6         | BAD       | |
| T10 | 5         | BAD       | |
| T11 | 4         | BAD       | |
| T12 | 2         | BAD       | |
| T13 | 0         | BAD       | final state — no `ez-org-runner-*` online |

## Routing evidence (still good)

All 8 latest `ezgha-selftest` workflow_dispatch runs on `jleechanorg/ez-gh-actions`:
```
28703983289 success
28703982618 success
28703981939 success
28703945368 success
28703944342 success
28703943434 success
28703942449 success
28692499021 success
```

When the fleet WAS online, every dispatched job landed on a distinct `ez-org-runner-*` slot and completed `success`. The routing layer is correct.

## What this proves

1. **Routing is fine** — every job that landed on an `ez-org-runner-*` slot completed successfully.
2. **The slot-recon PR is incomplete** — its `release_stale_slots` predicate is too narrow (only releases slots whose runner_id is GONE from GitHub; doesn't catch slots whose runner_id is online but local daemon is dead).
3. **The fleet count is unstable** — the cascade of "delete registrations → restart → 409 because old container still has the name → bail" creates a downward spiral.
4. **Doctor is honest** — every minute it correctly reported `BAD`. The flapping fleet size (13→0 over 13 minutes) means production workloads on this fleet were at risk of failure for at least 13 minutes.

## What was tested but not validated

- Doctor did NOT observe a 30-minute healthy window. To validate "healthy for 30 minutes" we need a code change to slot-recon (Task #2 in `/nextsteps`) that handles the "GitHub online but local dead" case.
- The 6 mac ARM64 colima runners are not under our control from this Linux host; they can be removed but they auto-resurrect.
- No real production workflows were dispatched during the observation; only the existing 8 selftest runs from earlier were available for routing proof.

## Recommended next actions

1. Ship `fix/slot-recon-online-check` (per-runner `status=online AND busy=false AND last_active < 60s` check), rebuild, deploy.
2. Audit worldarchitect.ai mac colima host files for the resurrection source (probably `~/Library/LaunchAgents/`).
3. Tag v0.1.1 with slot-recon upgrade.
4. Re-run this 30-minute observation after the fix lands.
5. Until then, do not advertise the ezgha fleet as "production-ready".