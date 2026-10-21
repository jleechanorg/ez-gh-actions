# Scratch pressure recovery (jleechan-uh1h)

Status: partial implementation, draft only. No installation, service restart,
real scratch deletion, credential changes, cgroup changes, or host configuration
changes are part of this patch. The admission feature is opt-in. The scratch
program is an eligibility auditor: `--apply` always fails before probing anything.
It contains no deletion or quarantine-rename implementation.

## Why cleanup is not enabled

An idle directory plus empty `lsof` is not proof that a job will never write again.
Even an empty root-owned cgroup snapshot is insufficient: a controller could add a
process after the check, a descendant could have escaped, or a bind mount could
expose unrelated data. Same-UID `0700` directories are not a malicious-process
boundary. Independent review required these remaining integration conditions:

1. A trusted controller owns an immutable, non-reused lease UUID and metadata
   namespace outside workload write access. It binds canonical repository and
   numeric GitHub Actions job ID, not the textual `GITHUB_JOB` key.
2. A pre-exec handshake binds the workload and every descendant to an exclusive,
   non-escapable containment scope. The controller permanently closes admission
   before the final kernel emptiness check. Neither this patch's scope probe nor
   its optional wrapper proves that lifecycle.
3. The controller preserves a retained external lease lock across terminal-job
   confirmation, identity checks, quarantine, and cleanup/recovery. It must pin
   and recheck directory identity after rename, reject mount crossings (including
   same-device bind mounts), and never adopt arbitrary old `/tmp` trees.
4. Live activation and irreversible deletion require separate approval and a
   staged, disposable canary. This draft does not reclaim the reported 146 GiB.

Proposed marker convention is `<root>/owners/<uuid>.json` with version,
`disposable: true`, lease ID, repository, numeric job ID, directory device/inode,
and diagnostic scope identity. Locks live at `<root>/locks/<uuid>.lock` and are
never unlinked. Trees are `<root>/trees/<uuid>`; UUID names are never reused.
The wrapper is experimental producer scaffolding, not a supported containment
adapter. Do not use it on runner hosts until the above conditions are implemented.

The auditor probes only below its caller-supplied low-water threshold, queries the
exact Actions job endpoint for `status: completed`, requires the lease lock,
checks marker/directory identity, checks scope emptiness, and treats any lsof
error/diagnostic as unknown. It reports candidate IDs, never authorization to
delete. Legacy trees, symlinks, replacement inodes, busy locks, and unknown probes
are excluded. No credentials are read or installed by tests.

## Opt-in daemon admission hysteresis

Existing configs omit `limits.disk_recovery`, preserving existing behavior.
When configured, the initial/restarted/config-changed latch is paused. Admission
requires both host/Docker/scratch disk measurements above the recovery threshold
and the existing MemAvailable and PSI admission predicates. Unknown disk or memory
measurements fail closed even for legacy configurations without host reserves.
Any observed admission pause or reconciliation error closes the latch again. An already-full fleet
is not fresh admission evidence and cannot open the latch. At most one runner is
started per reconciliation, requiring fresh measurements for the next runner.
A one-shot `start --count N` reports a partial failure when pacing leaves runners
unlaunched; it does not claim they are becoming ready. The daemon can reconcile
again, or an operator can repeat `start` under the same admission guards.
The existing serve/slot locks and native host capacity reservations remain active;
this patch does not authorize a second daemon or competing dispatcher.

The high-water calculation (GiB, not decimal GB) is:

    high = low + ceil(aggregate_burn_gib_per_minute * delay_secs / 60)
               + active_job_growth_gib + protected_reserve_gib

The observed 6 GiB/minute is evidence for sizing, not a proven upper bound.
`delay_secs` must include sample age, scheduler/polling jitter, queued dispatch,
and admission-close latency. `active_job_growth_gib` is additional bounded demand
not already counted in that aggregate rate; do not double-count or omit writers.
The protected reserve is independent of the 30 GiB pause floor. All inputs are
required positive integers, arithmetic is checked, and low must be at least 30.
If the initial measurement phase exhausts the configured delay, no spawn is attempted.
This is not a final-launch deadline: later JIT/slot/Docker operations can add delay.
The full dispatch bound remains an externally measured assumption, not enforcement.

An illustrative envelope, NOT a measured host configuration or deployment:

```toml
[limits]
min_free_disk_gb = 30
# Preserve all other existing limits.

[limits.disk_recovery]
scratch_root = "/tmp/ezgha-managed-scratch"
aggregate_burn_gib_per_minute = 6
detection_and_dispatch_delay_secs = 75
active_job_growth_gib = 4
protected_reserve_gib = 3
```

This derives 45 GiB: 30 + ceil(7.5) + 4 + 3. It is deliberately not an arbitrary
40 GiB resume mark. `scratch_root` must already exist; statvfs uses available-to-
service blocks on that filesystem. Host and Docker filesystem gates also apply.
The example delay/growth/reserve need actual fleet measurements before activation.
The conditional recovery-event bound is 45 - 8 - 4 >= 30 + 3; it is not a hard quota
or a continuing floor invariant. Once open, the pause threshold is 30, so delayed
detection plus ongoing writes can overshoot below 30. Hysteresis reduces cycling;
it does not make the nominal pause floor an enforced free-space reservation.
Independent writers, longer dispatch, cgroup constraints, or a faster burn can
invalidate the envelope. Host MemAvailable is not proof of spare memory inside
an independently constrained daemon cgroup. Retain existing container/cgroup and
native capacity safeguards; validate the effective cgroup budget before rollout.

## Acceptance matrix and receipts

- Active-job exclusion: retained producer lock and incomplete remote status tests.
- lsof failures: nonempty stderr, nonstandard status, and probe exception tests.
- Reuse: replacement inode, symlink, and competing retained-lock tests.
- Detached descendants: populated-scope negative test. Permanent scope closure,
  escape prevention, mount safety, and race-safe actual deletion remain BLOCKED.
- Overshoot: pure checked-arithmetic envelope test, no live bound claimed.
- Joint disk/memory: daemon-path tests for high-water disk and low/unknown memory;
  existing PSI tests remain relevant. Real fleet envelope not measured here.
- Staged rollback: feature absent is the old policy; deletion is hard-disabled.

Run from the checkout:

```sh
python -m unittest discover -s tests -p test_scratch_reclaimer.py -v
cargo test --offline disk_recovery -- --test-threads=1
cargo test --offline -- --test-threads=1
```

Use one build job and a scoped target directory. Tests use temporary directories
and synthetic job/lsof/scope results; no GitHub request or real cleanup is needed.

## Staging and rollback (operator action, not performed)

1. Review the exact draft head and complete containment/mount safety integration.
2. Measure actual filesystems, aggregate burn, maximum observation/dispatch lag,
   active demand, service cgroup headroom, and existing dispatcher ownership.
3. Evaluate the candidate auditor on disposable fixtures only; audit false positives.
4. Independently enable admission on one approved fleet after preserving its config.
   Observe pause/resume cycles and no over-admission; stop if assumptions fail.
5. To roll back admission, remove only the `limits.disk_recovery` table and restore
   the prior reviewed config through the normal approved deployment process.
   Preserve the existing disk floor and memory reserve; never disable those guards.
   No deletion feature exists to roll back and no legacy scratch is adopted.

## Cloud verification, 2026-10-20 PST (UTC-08:00)

Base: `b468bb665f13f5fb08b0d8b1b8be51674ba674b8` (exact GitHub tree materialized).
At 20:44 PST, focused tests: 17 Python tests and 8 Rust tests passed. These are
hermetic tests, not live fleet, cleanup, containment, or hysteresis acceptance.
Final serialized full Rust comparison:
base 478 passed / 11 failed / 2 ignored; patch 486 passed / same 11 failed / 2 ignored.
Ten failures are unchanged Lima tests trying to create forbidden fixture paths;
one is the unchanged queue-monitor invariant-history write to read-only
`/home/agent/.local/state/ezgha`. No permissions were expanded to make them pass.
Existing PR #182 owns the Lima fixture-path repair; this branch does not duplicate it.
All runs use one build job, one test thread, and a 3 GiB virtual-memory cap in the
cloud workspace. Full suite is NOT green. No CI result or merge readiness claimed.
