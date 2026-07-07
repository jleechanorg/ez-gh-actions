# ed8 fleet churn root cause - 2026-07-07

## Summary

The Linux `ez-runner-c-*` dips observed in `ez-gh-actions-ed8` are transient slot
reconciliation windows under high ephemeral-runner churn, not a permanently wedged
fleet state.

The concrete mechanism is:

1. `start_one` reserves a numeric slot in `slot_assignments.toml` with an empty
   runner id before calling GitHub for a JIT config.
2. GitHub creates a JIT runner registration, then Docker starts a short-lived
   `--rm` runner container.
3. The code records the GitHub runner id in the slot file only after `docker run -d`
   succeeds.
4. Under heavy queue churn, a runner can finish and deregister, the container can
   disappear, or the service can restart between those steps.
5. The next `ensure_count` tick runs `release_stale_slots`, which frees empty slots,
   frees slots whose runner id disappeared from GitHub, frees offline/idle runners
   with no local container, and reaps offline unowned orphan registrations.
6. The following spawn pass fills the shortfall.

That means a sample can briefly see:

- 16 slot-file entries, one pointing at a missing registration/container.
- 15 slot-file entries and 15 production containers while the missing slot has just
  been released and the replacement has not connected yet.
- A GitHub-side offline orphan with no slot-file owner just before the forward sweep
  removes it.

The mechanism self-heals because `serve` calls `ensure_count` every 30 seconds, and
`ensure_count` reconciles before and after attempting replacements.

## Evidence

Code paths:

- `src/docker_backend.rs:199` to `src/docker_backend.rs:217`: `next_slot` reserves an
  empty slot marker.
- `src/docker_backend.rs:576` to `src/docker_backend.rs:639`: `start_one` reserves a
  slot, generates the JIT config, starts Docker, then records the runner id.
- `src/docker_backend.rs:256` to `src/docker_backend.rs:360`: production stale-slot
  reconciliation and forward orphan sweep.
- `src/docker_backend.rs:417` to `src/docker_backend.rs:443`: empty, missing-id, and
  offline/idle missing-container slots are released.
- `src/docker_backend.rs:452` to `src/docker_backend.rs:477`: offline/busy
  missing-container slots are only released after GitHub removal succeeds.
- `src/main.rs:718` to `src/main.rs:783`: `serve` repeats `ensure_count` on a 30s loop.

Observed 2026-07-07 PDT timeline from:

```bash
TZ=America/Los_Angeles journalctl --user -u ezgha.service \
  --since '2026-07-07 12:30:00' --until '2026-07-07 12:39:30' \
  --no-pager -o short-iso
```

Relevant lines:

```text
12:33:16 respawned ephemeral runner ez-runner-c-2
12:33:58 respawned ephemeral runner ez-runner-c-12
12:35:12 service restarted
12:35:19 respawned ephemeral runner ez-runner-c-2
12:35:58 respawned ephemeral runner ez-runner-c-2
12:37:43 service restarted
12:37:43 warning: orphaned runner ez-runner-c-12 (id 134511, status offline) has no slot-file owner
12:37:44 info: reaped 1 orphaned runners with prefix ez-runner-c-
12:38:06 respawned ephemeral runner ez-runner-c-12
12:38:48 respawned ephemeral runner ez-runner-c-12
12:39:06 service restarted
12:39:10 respawned ephemeral runner ez-runner-c-4
12:39:10 respawned ephemeral runner ez-runner-c-6
```

The `ez-runner-c-12` orphan cycle is the clearest full cycle in the logs:

- Orphan detected: 12:37:43.
- Orphan removed: 12:37:44.
- Replacement spawned: 12:38:06.

That gives a measured orphan-to-respawn duration of about 23 seconds in this sample.
The earlier reported `ez-runner-c-2` offline sample fits the same pattern: the journal
shows repeated `ez-runner-c-2` respawns at 12:33:16, 12:35:19, and 12:35:58 while the
fleet was under a 200+ queued-run backlog and several service restarts occurred.

## Duration

From the available journal evidence, the reclaim and replacement span is bounded by
the 30 second serve loop plus the time required for GitHub JIT generation and Docker
startup. In the concrete orphaned `ez-runner-c-12` cycle above, it took about 23 seconds
from orphan detection to replacement spawn.

Samples taken during the same period can still report 14 to 15 effective Linux runners
because they may land before the replacement runner has connected to GitHub or before
GitHub has propagated the runner's current status. This is expected under saturated
ephemeral churn; it should not persist across multiple serve ticks unless a separate
failure is present.

## Fleet sample

Lane D took a live doctor sample at `20260707T194730Z` and saved it at:

```text
/tmp/ezgha-sc6-doctor-20260707T194730Z.log
```

Result:

- `doctor.sh` exit status: 1.
- Service and Docker were healthy.
- GitHub showed zero offline org runners.
- Production `ez-runner-c-*` was transiently missing `ez-runner-c-8` in the displayed
  list, while the local managed-container count included the canary container. This is
  not a clean SC6 16/16 sample.
- The failure reason was queue tail health: 457 queued runs, p90 fresh wait 30.1m,
  max fresh wait 152.9m.

This sample should not count toward the 3 consecutive >=30 minute SC6 green samples.

## Harness note

The live sample exposed a measurement gap: `doctor.sh` counts all containers with
`ezgha=managed`, including `ez-canary-runner-b-1`, when printing managed container
count. For production fleet integrity, the count must be filtered by the configured
runner prefix (`ez-runner-c-*`) or canary state can mask one missing production
container. Gate 3 in `docs/verify-exit-criteria.sh` already has an "effective capacity"
concept, but the doctor output is easier to misread during live triage.

## 5 Whys - technical

1. Why did the Linux fleet dip to 14 to 15 of 16? Because one or more ephemeral slots
   were between registration/container teardown and the next successful replacement.
2. Why can a slot be between states? Because `start_one` reserves first, creates a JIT
   registration, starts a `--rm` container, and records the runner id only after Docker
   reports success.
3. Why can a stale slot or orphan remain visible? Because GitHub runner registration
   state and local Docker container state do not change atomically, and service restarts
   can land mid-cycle.
4. Why does it self-heal instead of wedge? Because `release_stale_slots` is fail-closed
   on GitHub errors and, when GitHub is reachable, frees empty/missing/offline slots and
   reaps offline unowned orphans; `serve` repeats this every 30 seconds.
5. Why did users observe it as a health dip? Because the fleet was saturated by
   worldarchitect.ai churn, so a single transient replacement window was visible in
   point-in-time API samples instead of hidden by idle spare capacity.

## 5 Whys - agent path

1. Why was this dispatched as a separate root-cause workstream? Because the main mission
   needed to distinguish a real slot leak from normal ephemeral churn before declaring
   SC6 green.
2. Why was the prior evidence ambiguous? Because snapshots mixed GitHub runner state,
   Docker container state, and slot-file state without a single timeline joining them.
3. Why did the ambiguity survive? Because the health scripts are not all prefix-scoped
   and can be read as fleet-green even when one production slot is transiently absent.
4. Why did Lane D document rather than patch immediately? Because the existing
   reconciliation logic is already recovering the observed mechanism, while the likely
   code hardening (persist runner id before Docker start, or add an explicit
   provisioning state with age) changes ownership timing and needs a focused test seam.
5. Why is a document still useful? Because SC6 needs a clear mechanism and duration
   bound; this note gives future samplers the difference between a bounded churn window
   and a persistent fleet failure.

## Follow-up options

- Tighten `doctor.sh` production fleet counting to filter managed containers by
  `runner.name_prefix`, not just `ezgha=managed`.
- Consider recording the GitHub runner id immediately after JIT generation, before
  `docker run`, and explicitly releasing/removing on Docker failure. This would reduce
  unowned orphan windows but requires tests around crash timing.
- Add a provisioning timestamp or slot-state enum instead of using an empty string
  marker. That would allow age-based diagnostics for "JIT in flight" versus "stale
  empty reservation".
