# Innovation addendum — ground-truth canary SLO (2026-07-06 /innovate)

## The one addition: measure the thing the user actually cares about

Every detector in the 4-phase roadmap (zombie reaper, queue-depth monitor, watchdog pings,
name-conflict counters) is a sensor for a **known** failure mode. The 2026-07-06 incident proved
the limits of proxy sensors: `systemctl` said active, containers were cycling, and yet real
throughput was ~1/16 because of a failure mode nobody had enumerated (GitHub-side zombie busy
registrations wedging JIT names).

The smartest single addition is a **continuous end-to-end canary**: the daemon periodically
dispatches a real, trivial workflow (`workflow_dispatch` on a dedicated canary repo/workflow
targeting this fleet's labels) and measures the full pipeline —
`dispatch → queued → in_progress → completed` — as timestamps.

**One number — canary time-to-start — is ground truth for the user's Goal 3** ("actions are
always getting healthy throughput"). It subsumes, as a single universal sensor:

- zombie/offline runners (canary queues but never starts)
- label typos, wrong runner group, JIT registration breakage
- runner image rot (canary starts but fails — e.g. the exit-127 `gh`/`jq` class)
- gh auth expiry, API budget exhaustion
- Colima/VM/docker daemon death
- **failure modes not yet imagined** — anything that breaks the chain anywhere surfaces as
  canary latency/failure, which is exactly the unknown-unknowns coverage a 3-day-old system needs

## Design sketch (S–M, ~150 lines + one canary repo)

1. `[canary]` config block: `repo`, `workflow`, `interval_minutes` (default 10), `slo_start_seconds`
   (default 90), `enabled`.
2. Each interval: `POST .../workflows/{id}/dispatches`, then poll the run (2 API calls/cycle —
   trivially within Gate 10 budget; back off when ozk's rate-limit backoff engages).
3. Record ring buffer of results (`~/.config/ezgha/canary_history.jsonl`): dispatch ts, time-to-start,
   time-to-complete, conclusion.
4. SLO breach (p95 time-to-start > threshold, or canary failed/never started) → `alert()` (bead zmk)
   **and** trigger an immediate deep-reconcile: zombie reap (qbl), Colima check (9yt) — the canary
   is the sensor; everything already on the roadmap becomes its actuators.
5. `ezgha status` prints last canary result + p95; `sd_notify STATUS=` carries it so
   `systemctl status` shows real health, not just "active".

## Compounding payoffs

- **Gate 4/5 for free, honestly:** verify-exit-criteria.sh's real-job-execution and
  sustained-health gates stop re-testing and instead read recorded ground truth from
  canary_history.jsonl — directly fixing part of the Gate-honesty problem (bead k4h) with data
  instead of more bash.
- **Goal 4 machinery for free:** the canary already correlates run → job → runner_name; that is
  the exact plumbing the max-job-duration canceller (bead ftw) and zombie reaper (qbl) need.
- **The 3am story finally works:** silent decay becomes "canary hasn't started within SLO twice
  in a row → Slack" — regardless of *why* it decayed.

## Runner-up ideas (brainstorm, kept for the record)

1. **SLO control loop (v2 evolution):** change the daemon's controlled variable from "N containers
   up" to "p95 queue-wait < X": count, trimming, and reaping become actuators of one feedback
   controller. The canary is the prerequisite sensor; do this after it proves out.
2. **LLM incident diagnosis (ZFC-aligned):** on N consecutive ensure_count failures, pipe the last
   50 journal lines to `claude -p` for classification into the known remediation set (restart VM /
   reap zombies / back off API / page human) instead of hand-coded triage chains. Keeps judgment
   out of application code per ZFC; needs a strict allowlist of actions.
3. **Chaos gate:** automate Gate 6 by having verify-exit-criteria.sh *inject* one failure
   (kill a container mid-canary) and assert recovery within SLO — turning the resilience gate from
   aspiration into regression test.
4. **Zombie prevention at the source:** before killing/replacing a container the daemon owns, check
   whether its runner is mid-job and cancel that run first — closing the loop that *created*
   tonight's zombie registrations (watchdog SIGABRT → orphaned busy jobs).

## Bead

`ez-gh-actions-juv` — feat(canary): end-to-end canary workflow + SLO alert + deep-reconcile trigger (P1).
