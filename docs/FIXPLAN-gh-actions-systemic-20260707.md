# FIXPLAN — jleechanorg GitHub Actions Queue Health (Systemic)

**Goal:** every run waits <= 20 minutes for a runner; Mac + Linux self-hosted fleets stay at expected online counts.
**Date:** 2026-07-07
**Status of findings:** all 7 findings below survived 2-lens adversarial review (evidence lens + safety lens). No finding required a `(single-lens verified)` downgrade.
**Fleet baseline:** 22 configured self-hosted runners (Mac: 6 per `capacity_mac.txt`, Linux: 16 per `capacity_linux.txt`). Current measured queue: p50=70.0m, p90=198.6m, max=275.6m (`capacity_mac.txt:64`) against a 141-job queued backlog (`queue_now.json`). 353 stale queued runs were already cancelled today (18 orphaned + 335 fresh-tail).

---

## 1. Executive summary

Root causes are (a) structural waste in the highest-volume workflows — Green Gate burns up to 13.3 min of a self-hosted slot per PR event purely sleep-polling Bugbot, and every push to main/dev fires 4 parallel self-hosted MVP shard jobs with no paths filter — plus (b) a family of missing `timeout-minutes` keys that let any hung job hold a slot for GitHub's 360-minute default, and (c) a global concurrency lock in levelup-tests that cancels unrelated PRs' runs and forces re-queues. Short-term (this week, config-only): land one worldarchitect.ai PR with exact YAML diffs (paths filter on the shard push trigger, per-PR concurrency key for levelup, job-level timeouts on 7 jobs), keep the launchd queue-reaper stopgap cancelling queued runs older than 20 min every 15 min, and let the jeff-ubuntu Rust reaper own hung *in-progress* zombies. Long-term: split Green Gate's Gate-4 Bugbot poll onto `ubuntu-latest` (the proven Gate-7/8 pattern), right-size capacity against measured demand (~2,385 exec-minutes per 800-run sample, of which a large share is eliminable waste), consolidate low-value workflows per the CI value audit (PR #8214), and enforce trigger discipline for bot-generated pushes.

---

## 2. Root causes, ranked by queue-minutes impact

### RC1 — Green Gate: Gate 4 Bugbot poll runs INSIDE the self-hosted `green_gate_precheck` job (largest offender)

- **Verified evidence:** `.github/workflows/green-gate.yml:331-369` — `BUGBOT_POLL_MAX=40` with `sleep 20` per iteration (up to 800s = 13.3 min) runs as a bash step inside `green_gate_precheck` (`runs-on: self-hosted`, `timeout-minutes: 20`). The workflow's own comment (lines 702-720) documents that this exact anti-pattern was already fixed for Gate 8 (`smoke_gate_wait` split to `runs-on: ubuntu-latest`, line 726) after "several Green Gate runs got stuck in this poll for hours" during a capacity outage. Gate 4 was left behind. Safety-lens re-verification against the live repo additionally found Gate 7 (`verdict_poll`) was also already split to `ubuntu-latest`, and that the in-file comment claiming "Gates 1-6 are bounded" is now stale/wrong — independent evidence Gate 4 was overlooked.
- **Queue impact:** Green Gate is the single largest current-queue offender: **38 of 141 queued jobs (27% of the entire backlog)**, triggered on every PR event (opened/synchronize/edited/reopened). Every eligible run burns up to ~13 min of a scarce self-hosted slot doing nothing but `gh api` polling.
- **Term:** LONG (structural job split; see §4). No stopgap config tweak exists that removes the poll without the split.

### RC2 — self-hosted-mvp-shard1.yml: push trigger has no `paths:` filter → 4 parallel self-hosted jobs on EVERY merge to main/dev

- **Verified evidence:** `.github/workflows/self-hosted-mvp-shard1.yml:4-16` — the `push:` trigger (`branches: [main, dev]`) has no `paths:` key while the `pull_request:` trigger immediately below is scoped (`mvp_site/**`, `tests/**`, `run_tests.sh`, specific scripts/schema paths). Jobs `harness-autonomy-self-hosted`, `mvp-shard-1/2/3` all run self-hosted with zero `needs:` edges (grep-confirmed), so all 4 schedule in parallel. **Verifier correction:** all 4 jobs have `timeout-minutes: 30` (not the 30/45/45/45 originally claimed). Safety lens confirmed no downstream workflow references these jobs, main has zero required status checks, and `scripts/ci-detect-changes.sh:293-298` already designates this workflow as the path-gated owner of core-mvp coverage — path gating on push is architecturally consistent, not a new coverage gap.
- **Queue impact:** every docs-only / unrelated-CI merge consumes 4 slots (≈18% of the 22-runner fleet) for up to 30 min each. `queue_now.json` shows 9 "Self-Hosted MVP Shards" jobs queued — the 4th-largest backlog (after Green Gate 38, WorldArchitect Tests 11, Presubmit Checks 11). Auto-factory merge cadence to main/dev is frequent, so this fires many times per day.
- **Bonus:** adding the paths filter also **closes** an existing latent hazard — the workflow's `cancel-in-progress: true` group is keyed on `github.ref`, so today an irrelevant push to main can cancel an in-flight *relevant* run; filtered pushes stop triggering at all.
- **Term:** SHORT.

### RC3 — levelup-tests.yml: single global concurrency lock across ALL PRs → cross-PR cancellation and re-queue churn

- **Verified evidence:** `.github/workflows/levelup-tests.yml:12-14` — `group: ${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: ${{ github.event_name != 'release' }}`. Triggers are `issue_comment` + `workflow_dispatch` only; for `issue_comment`, `github.ref` is always `refs/heads/main`, so every `/levelup` on every PR shares ONE concurrency group. There is no `release` trigger on this file at all, so cancel-in-progress is unconditionally true. **Live production proof:** runs 28905070397 (PR #8228) and 28905070266 (PR #8233) — two different PRs — both cancelled within the same second today (2026-07-07T23:10:23Z). Root cause traced to PR #8175's blanket concurrency pass (2026-07-05). Cancelled runs force re-`/levelup`, which re-queues the whole up-to-65-min job (`timeout-minutes: 65`, line 101).
- **Magnitude caveat (from verification):** sampled execution times for this workflow are short (most issue_comment triggers short-circuit as "skipped"), so the per-incident waste is smaller than a full 65-min burn — but the cancellation mechanism is confirmed live-firing today and generates duplicate queue entries.
- **Term:** SHORT.

### RC4 — Missing `timeout-minutes` family: any hang holds a self-hosted slot for GitHub's 360-minute default

A single 6-hour hang exceeds the entire observed queue tail (275.6m, `capacity_mac.txt:64` — verifier corrected the earlier "350min" figure). Five verified instances:

| File | Job(s) | Evidence | Notes |
|---|---|---|---|
| `codex-skill-sync.yml` | `check` (line 27, self-hosted line 29) | zero `timeout-minutes` in file; every sibling self-hosted job in the batch sets one (claude-processor:15, coverage:47, pr-cleanup:20/171, quarantine-reset:24). Measured p50/max ≈ 6.5 min (run_stats.json, n=2); 2 runs currently queued — live, not dead code | SHORT |
| `daily-campaign-report.yml` | `report:` (line 16, self-hosted line 17) | zero `timeout-minutes`; shells out to SMTP send + awk/sed parsing | SHORT |
| `daily-gcp-cost-report.yml` | `report:` (line 21) | zero `timeout-minutes`; BigQuery billing export + SMTP. Scheduled 09:20 UTC | SHORT |
| `daily-gh-cost-report.yml` | `report:` (line 21) | zero `timeout-minutes`. Scheduled 09:30 UTC — 10 min after the GCP report, so one hang can overlap the next job's start, compounding slot loss | SHORT |
| `pypi-publish-testing-utils.yml` | `build` (line 24) + `publish` (line 54, `twine upload` line 81) | zero `timeout-minutes`; two sequential self-hosted jobs; twine can hang on network/auth retry. Low frequency (<2 runs in 800-run sample) — defense-in-depth | SHORT |
| `mcp-smoke-tests.yml` | `preview-smoke-tests` (line 148, self-hosted line 163) | only a STEP-level `timeout-minutes: 25` (line 281); no job-level key, so checkout/pip-install/resolve steps are unbounded → 360-min default. Human-gated (`/smoke` comment) so low frequency, but each hang is catastrophic to a 22-slot fleet | SHORT |

**Verifier notes carried forward:** (a) the daily-report workflows do NOT appear in run_stats.json at all — the originally cited "0.1-4.1min p50/max" was unsupported; the 15-min timeout value is still sound from code inspection (no retry loops in the backing scripts). (b) The repo has direct precedent: commit `8651cf51d3` fixed an identical 4h48m hang with the same pattern. (c) The existing queue-reaper stopgap only cancels `status=queued` runs (`cleanup-stuck-runs.sh:138`) — hung IN-PROGRESS jobs are completely unprotected today, which is exactly the gap these timeouts close.

### RC5 — Ruled OUT: hermes-pr-tag-listener (20% of run count) is GitHub-hosted

- **Verified evidence:** `.github/workflows/hermes-pr-tag-listener.yml:29` calls reusable `jleechanorg/.github/.github/workflows/hermes-pr-tag-listener.yml@main`, whose sole job is `runs-on: ubuntu-latest` (line 37) with `timeout-minutes: 3`. 161/800 runs but only ~16.1 of 2,385.5 sampled exec-minutes (0.7%), all on GitHub-hosted infra.
- **Action:** none for capacity. Do NOT spend remediation effort here. (Optional GH-API-quota trim: it double-fires on issue_comment created+edited — a rate-limit concern only.)

---

## 3. SHORT-TERM (this week, config-only)

**Owner: Mac-side sidekick, lane 2** — one worldarchitect.ai PR containing all diffs below, ordered by impact. All changes verified safe by the safety lens: none touch deploy workflows, none touch required PR checks (main has `required_status_checks.contexts: []`), none alter cancel-in-progress semantics on push-to-main except to *narrow* blast radius.

### 3.1 `.github/workflows/self-hosted-mvp-shard1.yml` — paths filter on push (impact rank 1 of the config fixes)

```yaml
 on:
   push:
     branches: [main, dev]
+    paths:                    # mirror the pull_request paths list below VERBATIM
+      - 'mvp_site/**'
+      - 'tests/**'
+      - 'run_tests.sh'
+      # ...copy the remaining entries from this file's own pull_request.paths
+      #    block (lines 6-16) exactly — do not hand-retype; any drift between
+      #    the two lists creates a push/PR coverage asymmetry.
   pull_request:
     paths:
       - 'mvp_site/**'
       ...
```

- `workflow_dispatch` remains the manual escape hatch for on-demand full runs on main/dev.
- Optional follow-up (same PR or later): give `harness-autonomy-self-hosted` its own narrower filter since it tests harness scripts, not `mvp_site`.
- Expected effect: eliminates 4 × 30-min slot claims on every non-mvp merge; directly shrinks the #4 backlogged workflow (9 queued now).

### 3.2 `.github/workflows/levelup-tests.yml` — per-PR concurrency key

```yaml
 concurrency:
-  group: ${{ github.workflow }}-${{ github.ref }}
-  cancel-in-progress: ${{ github.event_name != 'release' }}
+  # issue_comment events always carry github.ref = refs/heads/main, so keying
+  # on ref made ONE global lock across all PRs (cross-PR cancellation, proven
+  # live 2026-07-07: runs 28905070397 / 28905070266). Key per-PR instead.
+  # Pattern mirrors mcp-smoke-tests.yml (the /smoke sibling this file mirrors).
+  group: ${{ github.workflow }}-${{ github.event.inputs.pr_number || github.event.issue.number || github.ref }}
+  cancel-in-progress: true
```

- `cancel-in-progress: true` is safe to simplify: the file has no `release` trigger, so the old expression was constant-true anyway.
- Preserves the intended behavior (a re-`/levelup` on the SAME PR supersedes the stale run) while ending cross-PR kills.
- Do NOT simply delete the `concurrency:` block — that reintroduces unbounded same-PR pile-up (a naive deletion was observed accidentally applied on an unrelated local branch; revert/avoid it).

### 3.3 Timeout family — 7 jobs across 6 files

> **CORRECTION (2026-07-07 ~17:30 PT, post-verification by sidekick during PR implementation — DO NOT implement the minute values below as written).** Independent measurement of actual historical durations (n=10 per workflow via gh api, vs this section's n=2-or-unsupported samples) shows the proposed caps would kill real successful runs: codex-skill-sync measured p50=21.1min/max=57.7min (proposed 10min cap would have killed 8 of last 10 successful runs); daily-campaign-report max=178.5min vs proposed 15min (6/10 runs exceed); daily-gcp/gh-cost-report max=469min/397min. Working hypothesis: these durations are inflated by the 1-cpu-clamped runner fleet (Lane L3 finding), not genuine hangs. **Revised plan:** (1) the STRUCTURAL rule stands — every self-hosted job must declare `timeout-minutes` (§4.4 lint enforces presence, not specific values); (2) re-measure these workflows AFTER the VM CPU resizes land, using JOB-level `started_at→completed_at` (not run-level created→updated, which conflates queue wait with execution), then set caps at post-fix p95 + margin. Timeout items were deliberately DROPPED from PR #8243 pending that re-measurement.

```yaml
# codex-skill-sync.yml — job `check` (after runs-on, line 29)
     runs-on: ${{ fromJson(vars.SELF_HOSTED_RUNNER_LABELS || '["self-hosted"]') }}
+    timeout-minutes: 10    # measured p50/max ~6.5min (run_stats.json), 35-50% headroom
```

```yaml
# daily-campaign-report.yml, daily-gcp-cost-report.yml, daily-gh-cost-report.yml
# — job `report:` in each (3 files, 1 line each)
     runs-on: ${{ fromJson(vars.SELF_HOSTED_RUNNER_LABELS || '["self-hosted"]') }}
+    timeout-minutes: 15    # report scripts have no retry/sleep loops; schedule-only,
+                           # never PR-gating; precedent: commit 8651cf51d3
```

```yaml
# pypi-publish-testing-utils.yml — BOTH jobs `build` (line 24) and `publish` (line 54)
     runs-on: ${{ fromJson(vars.SELF_HOSTED_RUNNER_LABELS || '["self-hosted"]') }}
+    timeout-minutes: 10    # small-package build + twine upload; caps a 360-min hang
```

```yaml
# mcp-smoke-tests.yml — job `preview-smoke-tests` (line 148), JOB level
     runs-on: ${{ fromJson(vars.SELF_HOSTED_RUNNER_LABELS || '["self-hosted"]') }}
+    timeout-minutes: 40    # step-level 25-min cap (line 281) covers only one step;
+                           # 40 gives margin for checkout/pip/resolve overhead
+                           # (safety lens: 40 preferred over 35 for margin)
```

### 3.4 Launchd queue-reaper stopgap (owner: Mac-side sidekick, lane 3)

Spec (already partially deployed as `scripts/queue-reaper-stopgap.sh`, keep/verify):

- **Schedule:** launchd StartInterval 900s (every 15 min). Plist template must live in the owning repo per launchd-plist-template policy.
- **Action:** `gh api` list runs with `status=queued` across jleechanorg repos; cancel any run whose `created_at` age > 20 min (`FRESH_TAIL_MIN=20`).
- **Scope guard (verified in `cleanup-stuck-runs.sh:138`):** only `status=queued` runs are candidates — **in_progress runs are NEVER cancelled** by the stopgap. Hung in-progress jobs are the timeout family's job (3.3) and the Rust reaper's job (3.5).
- **Exclusions:** never cancel runs of deploy workflows (deploy-production.yml, auto-deploy-dev.yml) even if queued >20 min — page instead.
- **Logging:** append every cancellation (run id, workflow, age) to a local log so acceptance sampling (§6) can distinguish "queue healthy" from "reaper masking sustained overload".
- **Sunset criterion:** retire the stopgap once §6 acceptance holds for 7 consecutive days WITH reaper cancellation count = 0 over that window (i.e., the queue is healthy without masking).

### 3.5 Coverage map — what existing in-flight work already owns

| Workstream | Owns | Does NOT cover |
|---|---|---|
| jeff-ubuntu Rust-native zombie reaper (beads qbl/7ap) + Linux fleet mission | Hung/zombie runner containers and stuck in-progress runs on the Linux fleet; Linux fleet uptime | Workflow YAML defects (RC1-RC4); Mac fleet tuning |
| CI value audit — PR [#8214](https://github.com/jleechanorg/worldarchitect.ai/pull/8214) | Which workflows deserve to exist / run frequency reduction (long-term consolidation input, §4.2) | Per-workflow structural bugs above — do not wait on the audit to land §3.1-3.3 |
| Today's 353-run cancellation (18 orphaned + 335 fresh-tail) | One-time backlog drain | Recurrence prevention — that is §3.1-3.4 |
| Mac runner count tuning (sidekick lane 4) | Mac supply side | Demand-side waste (this doc's §3) |

---

## 4. LONG-TERM

### 4.1 Green Gate Gate-4 split (RC1) — the single biggest structural win

Apply the exact pattern already proven twice in the same file (Gate 7 `verdict_poll`, Gate 8 `smoke_gate_wait`):

- Extract the Bugbot poll (green-gate.yml lines 331-369 + final re-check 370-389) into a new job `bugbot_gate_wait`, `runs-on: ubuntu-latest`, `needs: green_gate_precheck` (or parallel, feeding the final `green_gate` aggregator via `needs:`).
- The poll only calls `gh api .../check-runs` — no self-hosted tooling required. All `BUGBOT_*` variables are self-contained within the Gate-4 block (grep-verified); Gates 5/6 read nothing from them, so extraction has zero shared-state coupling.
- **Fail-closed requirement:** replicate the existing `if: always()` + explicit "Enforce/Apply result" step pattern in the final `green_gate` job (already used for Gates 7/8) so a skipped/failed split-out job can never silently pass the gate.
- Also fix the now-stale comment at lines ~56-60 claiming "Gates 1-6 are bounded".
- Expected effect: self-hosted slot occupancy per Green Gate run drops from up-to-20-min (dominated by the 800s poll) to seconds-to-low-minutes, on the workflow that is 27% of the current backlog. This is the largest single queue-minutes lever identified.

### 4.2 Capacity right-sizing — demand math

Supply: 22 configured self-hosted slots (Mac 6 + Linux 16).

Demand (800-run sample, run_stats.json): ~2,385.5 total exec-minutes. Composition of eliminable waste identified above:

- Green Gate poll waste: up to 13.3 min/run of pure sleep on the highest-volume self-hosted workflow → removed by §4.1.
- MVP shard waste: 4 jobs × ≤30 min on every non-mvp push to main/dev → removed by §3.1.
- Levelup duplicate re-queues from cross-PR cancellation → removed by §3.2.
- Tail risk: any single 360-min hang exceeds the entire observed 275.6m queue tail → capped by §3.3.

**Order of operations: eliminate waste FIRST, then re-measure demand over a 7-day window, then decide runner counts.** Do not buy/provision capacity against pre-fix demand — a large share of current queue-minutes is structural waste, not real work. If post-fix p90 queue wait still exceeds 20m, scale the Linux fleet (cheaper slots) before Mac, using the re-measured exec-minutes/day ÷ (minutes/day × target utilization ≤ 0.7) per pool.

### 4.3 Workflow consolidation

Feed the CI value audit ([#8214](https://github.com/jleechanorg/worldarchitect.ai/pull/8214)) with this doc's frequency data: hermes-pr-tag-listener (161/800 runs) is GitHub-hosted and harmless to capacity, but the audit should target self-hosted workflows with high run counts and low p50s (candidates for merging into fewer jobs to amortize checkout/setup overhead) and schedule-only reports that could share one daily job.

### 4.4 Trigger discipline for bot-generated pushes

- Every workflow with a `push: branches: [main, dev]` trigger MUST have a `paths:` filter or a one-line justification comment. Auto-factory merge cadence makes unfiltered push triggers a multiplier on every structural inefficiency.
- Every `issue_comment`-triggered workflow MUST key concurrency on `github.event.issue.number` (never `github.ref` — it is always the default branch for comments) and SHOULD short-circuit non-matching comments in a cheap GitHub-hosted resolve job before any self-hosted job starts.
- Every self-hosted job MUST have `timeout-minutes` (enforce via a repo lint/presubmit check on `.github/workflows/*.yml`: reject any job whose `runs-on` references SELF_HOSTED_RUNNER_LABELS without a `timeout-minutes` key — this makes RC4 a class-level fix, not whack-a-mole).
- Blanket concurrency-group passes (like PR #8175) must be reviewed per-trigger-type: `github.ref`-keyed groups are wrong for `issue_comment` workflows (RC3 is the proof).

---

## 5. Risks / what NOT to do

1. **Never add `cancel-in-progress: true` to deploy workflows** (deploy-production.yml, auto-deploy-dev.yml) and never let the queue reaper cancel their runs, even if queued >20 min — a cancelled deploy mid-flight is worse than a slow queue. Page a human instead.
2. **Do not delete the levelup-tests `concurrency:` block** as a "fix" — that trades cross-PR cancellation for unbounded same-PR pile-up. The per-PR key (§3.2) is the only correct shape. An accidental deletion already exists on an unrelated local branch; do not merge it.
3. **Do not let the stopgap reaper touch `in_progress` runs.** It cancels `queued` only. Hung in-progress runs are handled by job timeouts (§3.3) and the jeff-ubuntu Rust reaper — three mechanisms with disjoint scopes; keep them disjoint.
4. **Do not hand-retype the paths filter** in §3.1 — copy the `pull_request.paths` list verbatim. Any drift creates asymmetric push/PR coverage that is hard to notice.
5. **Do not provision new runner capacity before the waste fixes land and demand is re-measured** (§4.2). Buying capacity against pre-fix demand locks in paying for structural waste.
6. **Do not spend effort on hermes-pr-tag-listener for capacity** — verified GitHub-hosted, 0.7% of exec-minutes (RC5). Any work there is API-quota hygiene only.
7. **Do not treat "workflow deleted from queue" as "problem fixed"** while the reaper is active — the reaper masks overload. Acceptance (§6) requires low queue tail *with* near-zero reaper cancellations.
8. **Green Gate split must be fail-closed** (§4.1) — a split-out gate job that can be skipped-and-ignored silently weakens a merge gate. Replicate the existing Gate-7/8 enforcement steps exactly.

---

## 6. Acceptance criteria (maps to goal: all runs wait <= 20 min; fleets stay up)

| # | Criterion | Measurement | Source |
|---|---|---|---|
| A1 | Queue tail <= 20m, sustained | Fresh-queue max wait <= 20 min in **2+ consecutive 15-min samples** (doctor.sh / capacity snapshot; same metric that currently reads max=275.6m) | `capacity_mac.txt`-style doctor output |
| A2 | Not reaper-masked | Over the same A1 window, launchd stopgap cancellation count for that window is reported alongside the sample; steady-state target 0 (reaper sunset per §3.4) | reaper log |
| A3 | Mac fleet up | >= 6 runners `status:"online"` via `gh api .../actions/runners` (end-state proof, not container `Up` status) | GitHub API |
| A4 | Linux fleet up | >= 16 runners `status:"online"` via `gh api .../actions/runners` | GitHub API |
| A5 | Shard waste gone | Push-triggered "Self-Hosted MVP Shards" runs appear ONLY for pushes touching filtered paths (spot-check `recent_runs.jsonl` equivalent after landing §3.1) | run history |
| A6 | Cross-PR cancellation gone | Zero levelup-tests runs cancelled by a *different* PR's trigger after §3.2 (check cancelled runs' triggering PR numbers) | run history |
| A7 | No 360-min hangs | No self-hosted job exceeds its declared `timeout-minutes`; zero jobs without `timeout-minutes` targeting SELF_HOSTED_RUNNER_LABELS (lint from §4.4) | workflow lint + run history |
| A8 | Green Gate slot time (long-term, post §4.1) | `green_gate_precheck` job duration p90 drops from up-to-20-min to < 5 min; Green Gate queued count no longer dominates `queue_now` snapshots | run stats |

**Definition of done for this plan:** A1+A2 hold across 2+ consecutive samples AND A3+A4 hold at the same timestamps, verified from the GitHub API layer (not container/tool layer), with the short-term PR merged and the stopgap logs attached as evidence.
