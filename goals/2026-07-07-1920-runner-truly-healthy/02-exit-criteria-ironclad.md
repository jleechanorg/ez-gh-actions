# IRONCLAD Exit Criteria — sustained fleet health (defined 2026-07-07 20:05 PT)

User goal: "keep going until we always have 22 runs active or queue empty and runs
shorter 20 min." These criteria are MACHINE-CHECKABLE, SUSTAINED, and ANTI-GAMEABLE.
No criterion may be marked met by narrative assertion — only by the evidence artifacts
named below, each independently re-derivable from raw logs.

## The two invariants (evaluated per sample, at the JOB level)

- **INV-1 Utilization**: `busy_self_hosted_runners == 22` (16 ez-runner-c-* +
  6 ez-mac-runner-b-*) **OR** `queued_self_hosted_jobs == 0`.
  Source: org runners API (busy flags) + queued runs' job labels. Run-object counts
  are FORBIDDEN as a measurement (proven misleading 2026-07-07: "13 runs" while 229
  queued and 22/22 busy).
- **INV-2 Duration**: no current JOB in monitored repos (worldarchitect.ai,
  ez-gh-actions) is queued > 20 min, AND no in-progress JOB has been running > 20 min.
  Job-level ages, not run-object ages.

## E1 — Automated sampler exists and has an automatic caller
- [ ] A sampler evaluates INV-1 + INV-2 and appends one JSON line per sample to
      `~/.local/state/ezgha/invariant_history.jsonl`
      (`{ts, busy, queued_jobs, oldest_queued_job_min, oldest_running_job_min, inv1, inv2}`)
- [ ] Sampling cadence ≤ 5 min, called AUTOMATICALLY (queue_monitor loop inside the
      daemon, or a systemd user timer). A script with only manual invocation FAILS
      this criterion (automation-completeness rule).
- [ ] Any violated sample fires a Slack alert via src/alert.rs (delivery already
      proven 2026-07-07). Alert contains the violating numbers.

## E2 — Sustained green window (the core "always" test)
- [ ] **3 continuous hours** with **zero violated samples** (≥36 consecutive samples
      at ≤5-min cadence) in invariant_history.jsonl, ending no earlier than the time
      of validation.
- [ ] The window must contain REAL load: ≥20 completed self-hosted jobs in
      worldarchitect.ai during the window (an idle overnight window with an empty
      queue and no work does NOT count unless queue stayed empty because demand was
      genuinely absent — flagged distinctly in the validation report).
- Evidence: the JSONL slice itself, committed under the goal dir + sha256.

## E3 — Anti-gaming clauses (validator MUST check all)
- [ ] Queue reductions during the mission came only from: natural completion,
      superseded-run cancellation (newest-per-branch+workflow kept), stale-zombie
      (>8h) deletion, or individually root-caused stuck runs (each logged with run
      URL + reason). Mass indiscriminate cancellation = automatic FAIL.
- [ ] Workflow success rate in worldarchitect.ai during the green window ≥ the
      7-day baseline minus 5 percentage points (can't get "short runs" by making
      everything fail/cancel fast).
- [ ] The 22-runner denominator may only change via an explicit user-approved
      capacity decision recorded in this file.

## E4 — Structural guarantees (so "always" survives after we stop watching)
- [ ] Every workflow in worldarchitect.ai that targets self-hosted runners declares
      `timeout-minutes: ≤ 20` at job level (lintable: rg over .github/workflows).
      Exceptions require a written justification list in the goal dir, each entry
      user-visible.
- [ ] Verdict Poll (Gate 7) class fixed: poll jobs can no longer run >20 min after
      upstream success (workflow PR merged in worldarchitect.ai, run URLs proving
      new behavior).
- [ ] doctor.sh + docs/verify-exit-criteria.sh contain the INV-1/INV-2 gate (Lane G)
      and PASS at validation time.
- [ ] ed8 (JIT re-registration capacity loss) root-caused with fix landed or a
      quantified accepted-risk note (gap duration distribution + expected capacity
      cost).

## E5 — Independent adversarial validation
- [ ] A skeptic subagent (different model family when available: codex) is given ONLY
      this file + the evidence artifacts and prompted to REFUTE each criterion.
      Verdict attached to 03-validation-log.md. Any refutation → not done.
- [ ] Validator re-derives E2's window arithmetic from the raw JSONL (no trusting
      summaries) and spot-checks ≥3 samples against GitHub API history where possible.

## Exit condition
ALL of E1–E5 checked, with evidence committed to the goal dir and pushed to
origin/main. Until then the mission continues (sidekick + swarm), max window per
user: 12h from 19:20 PT; if the deadline lands first, report exact criterion-by-
criterion status honestly — no partial-credit "done".

## Failure honesty clause
If steady-state demand > 22-runner capacity makes INV-2 structurally impossible even
after the CI-demand audit removes no-value checks, the exit deliverable becomes the
NUMERIC capacity finding (arrival jobs/hr vs completion jobs/hr, gap in runner-hours)
plus a concrete scaling proposal — presented as NOT MET + decision needed, never
reframed as success.
