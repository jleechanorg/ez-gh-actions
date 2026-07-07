# Ultracode review + demand-mining synthesis (wf_99a3ba68-260, 2026-07-07 ~15:30 PT)

37 agents (4 review lenses x adversarial 2-refuter verify, 4 demand miners, 1 synthesis), 0 agent errors.
Inputs: po2.diff (main...sidekick/po2-respawn-pacing b8735b7+5e3514d), fresh shallow clone of worldarchitect.ai .github/workflows (43 files).

## PO2 VERDICT: BLOCK

One confirmed **critical** finding survives (batch-boundary load checks racing a lagging 1-minute EMA) — per rule, any confirmed critical forces BLOCK regardless of the other findings' severity mix.

**Per-finding one-liners** (14 findings, all confirmed/survives=true; duplicates noted):

1. **[MAJOR]** `wait_for_respawn_load_window` pacing runs *inside* `ensure_count`, before `loop_start`-relative monitor deadlines are checked — a paced respawn (up to ~255s under sustained load) can blow past `SERVE_LOOP_TIME_BUDGET` (75s) and silently degrade `queue_monitor`/`invariant_sampler` fetches for that whole tick. *(main.rs:737-808, docker_backend.rs:216-310)*
2. **[MINOR]** `read_host_loadavg_1m()` returns `None` on non-Linux, so the load-aware backoff is a total no-op on macOS hosts with no warning logged. *(docker_backend.rs:203-214)*
3. **[MINOR]** No test exercises `ensure_count`'s real wiring to `start_missing_runners`/`std::thread::sleep`/`read_host_loadavg_1m` — only the injectable `_with` variant is tested, so a wiring regression (arg order, count math) ships undetected.
4. **[MAJOR — duplicate of #1]** Same SERVE_LOOP_TIME_BUDGET-starvation mechanism restated with queue_monitor.rs line-level detail (fetch_capped_queue_snapshot short-circuits on first page).
5. **[MINOR]** `ensure_count` treats any `Ok(_)` (even 1-of-16 successes) as full success, resetting `ensure_fail_streak` with no alert — made more likely because pacing activates precisely during the high-load window when individual starts are more likely to fail.
6. **[MINOR — duplicate of #2]** Load-aware backoff silent no-op on non-Linux, restated under "concurrency" lens.
7. **[MAJOR — duplicate of #1]** Same monitor-starvation risk restated under "failure-modes" lens, adds that `last_check` still advances, extending the next real check by a full `check_interval_seconds`.
8. **[MAJOR]** The load gate fires at every batch boundary (`i % batch_size == 0`) including single-runner steady-state churn, not just mass cold-start bursts — it can't distinguish self-caused load from legitimate concurrent CI load, throttling routine refills during exactly the high-queue-depth saturation scenario this repo already struggles with.
9. **[MINOR]** Load is only sampled at batch boundaries (every 5-15s); 1-minute loadavg's EMA lags real CPU pressure from just-started containers, so a batch can pass the check on stale data.
10. **[CRITICAL]** Quantified version of #9: with default batch_size=4/sleep=5s, all 4 batches (16 `docker run`s) clear the gate within ~30-55s of a cold restart because the EMA has only captured ~8-22% of the true load delta by each check — the exact loadavg-71 incident this diff exists to prevent can still reproduce, just delayed 30-90s past `ensure_count` returning, with no batches left to pace it.
11. **[MAJOR]** `respawn_load_max_wait_seconds` force-proceeds a batch after 60s regardless of current load — the one case where the gate would actually trip (sustained real elevated load) is exactly when it gives up and dispatches 4 more cold starts anyway.
12. **[MAJOR]** Both new tests use *constant* loadavg stubs (`|| Some(0.0)`, `|| Some(20.0)`) with no feedback relationship to batches started — the property the diff exists to prove (pacing keeps loadavg under 24) is asserted only in a code comment, never verified by test, so a future regression (e.g., shrinking `respawn_batch_sleep_seconds`) would pass all tests and only surface at the next real incident.
13. **[MINOR — duplicate of #2/#6]** `read_host_loadavg_1m` no-ops on non-Linux with zero signal that the safety check is inert, a risk if this path is ever shared with the mac-remote runner fleet.

---

## DEMAND-CUT PLAN

### PR-1: Quick wins (low-risk, high-impact)

| Workflow | Change | Impact | Risk |
|---|---|---|---|
| green-gate.yml | Remove `edited` from `on.pull_request.types` (keep `[opened, synchronize, reopened]`) | Top queue offender — 74/343 (22%) of queued self-hosted runs; pure additive backlog on no-op PR body edits | low |
| green-gate.yml | Move `cancel-in-progress` to job level: `true` for `green_gate_precheck` (self-hosted), keep `false` only on `smoke_gate_wait` (ubuntu-latest) | Only self-hosted, unfiltered, per-push workflow in the repo without cancel-on-supersede — every superseded push leaves a stale 20-min precheck occupying a slot across ~50 agent branches | medium (YAML-correctness risk only, not a value tradeoff) |
| design-doc-gate.yml | Remove `edited` from `on.pull_request.types` | Tied #5 offender (24 queued runs), same no-commit re-trigger waste as green-gate | low |
| auto-deploy-dev.yml | Add `paths-ignore: [docs/**, roadmap/**, '*.md', .github/ISSUE_TEMPLATE/**]` to `on.push.branches:[main]` | Skips full Cloud Build+Cloud Run deploy on doc/roadmap-only merges, recurring across ~50 branches | low |
| presubmit.yml | Merge `schema-coverage`, `prompt-contracts`, `function-loc-ratchet`, `agy-json-contract` (+`limit-pr-runs`) into one `presubmit-fast-checks` job | Fires on nearly every PR; recovers 4 slot-allocations + checkouts for <2 min combined real work | low |
| test.yml | Merge `limit-pr-runs`, `import-validation`, `beads-jsonl-validation` into one `pr-guards` job | Fires on every PR + main/dev push; recovers 2 slot-allocations per trigger, no loss of per-step failure attribution | low |
| dice-tests.yml, levelup-tests.yml, mcp-smoke-tests.yml, auth-browser-tests.yml | Move `resolve-pr-context`/`resolve-self-hosted-pr-context` job to `ubuntu-latest` (no checkout, no self-hosted-only tooling) | Frees a self-hosted slot on every slash-command trigger during PR-review burst windows across 4 workflows | low |
| codex-skill-sync.yml | Move `check` job to `ubuntu-latest` | Zero-cost win whenever `.claude/skills/**`/`.codex/skills/**` changes | low |
| test-self-hosted-runner.yml | Delete — workflow_dispatch-only smoke ping, gates nothing, duplicative of `doctor.sh` | Reduces workflow-count noise / false "fleet healthy" signal | low |
| bead-jsonl-sort-check.yml, bead-pr-lint.yml | Add `paths: ['.beads/**']` to `on.pull_request` | Cuts org-wide Actions dispatch/API-rate-limit load on every PR touch; runs on ubuntu-latest so no direct fleet relief | low |
| daily-gcp-cost-report.yml + daily-gh-cost-report.yml | Merge into one scheduled workflow, shared checkout/setup-python | Saves 1 container startup/day; already off-peak so minimal contention relief | low |
| preview-image-janitor.yml + preview-service-janitor.yml | Merge into one nightly janitor, shared GCP auth/gcloud setup | Saves 1 slot/day; already off-peak (03:37/04:11 UTC) | low |

### PR-2: Timeout-lint (all timeout-cap items)

| Workflow — job | Change | Impact | Risk |
|---|---|---|---|
| mcp-smoke-tests.yml — preview-smoke-tests | Add job-level `timeout-minutes: 30` (only one step is bounded today) + document as E4 exception | No job-level cap at all — ack/checkout/env-setup steps can starve a slot for hours (default 360-min ceiling) | high |
| pr-preview.yml — deploy-preview | Add job-level `timeout-minutes: 40` (only the deploy step is bounded) + document as E4 exception | Fires on every non-fork, non-draft PR touching mvp_site; unbounded pre-deploy image build/push | high |
| auth-browser-tests.yml — run-auth-browser-tests | Set `timeout-minutes: 30` (or split 15-min preview-poll into its own ubuntu-latest job like green-gate's smoke_gate_wait) + `# E4 EXCEPTION` comment | No job timeout today; hung poll/browser install can pin a slot indefinitely | high |
| test.yml — test | Align job-level `timeout-minutes` 30→25 to match documented 25-min step budget; split matrix so non-core legs get a tighter own cap (e.g. 15) | Main PR-blocking matrix — fast legs currently hide hangs under the slow core-* legs' ceiling | medium |
| deploy-dev.yml — deploy | Tighten 45→25-30 + `# E4 EXCEPTION: Cloud Build + Cloud Run deploy` comment | 45 min gives 2x+ headroom over realistic worst case | medium |
| dice-tests.yml — run-dice-audit | Drop 65→60 to match cited Cloud Run job's 3600s budget exactly + explicit `# E4 EXCEPTION` | Legitimate exception but undocumented, will keep failing lint sweeps | medium |
| levelup-tests.yml — run-levelup-tests | Drop 65→60 to match cited 3600s budget + explicit `# E4 EXCEPTION` | Same as dice-tests | medium |
| self-hosted-mvp-shard1.yml — mvp-shard-1/2/3 | Tighten 45→35 (30-min internal budget + ~5 min overhead) + document as E4 exception, or split into more shards to fit under 20 min | Runs on every relevant PR + main/dev push; currently excess slack beyond even the long internal budget | medium |
| preview-image-janitor.yml — prune-preview-images | Tighten 60→20 | Nightly API-loop prune; scarce-runner-capacity risk pattern flagged in this repo's own postmortem comments | medium |
| preview-service-janitor.yml — prune-preview-services | Tighten 60→20 | Same rationale as image janitor | medium |
| coverage.yml — test | Tighten 30→15 (file's own comment: full suite ~1.5 min) | Wastes a scarce slot up to 28 extra minutes on any hang | low |
| green-gate.yml — green_gate | Tighten 60→10 (Gate-8 poll already split out to smoke_gate_wait; only lightweight gh-api steps remain) | Stale 60-min headroom from before the 2026-07-02 split | low |
| styleguide-compliance-gate.yml — styleguide-gate | Tighten 40→20 | Doubles acceptable hang window on every frontend_v1 PR today | low |
| self-hosted-mvp-shard1.yml — harness-autonomy-self-hosted | Tighten 30→15 | Small pytest suite over 4-5 files; no component justifies 30 min | low |
| auth-browser-tests.yml — resolve-pr-context | Add `timeout-minutes: 5` | Currently unbounded API-call-only job | low |
| auth-browser-tests.yml — post-result | Add `timeout-minutes: 5` | Currently unbounded single-comment-post job | low |
| codex-skill-sync.yml — check | Add `timeout-minutes: 5` | Currently unbounded for a sub-1-min job | low |
| daily-campaign-report.yml — report | Add `timeout-minutes: 15` | Unbounded BQ+SMTP scheduled job | low |
| daily-gcp-cost-report.yml — report | Add `timeout-minutes: 15` | Unbounded billing-export job | low |
| daily-gh-cost-report.yml — report | Add `timeout-minutes: 15` | Unbounded GH-cost-aggregation job | low |
| dice-tests.yml — resolve-pr-context | Add `timeout-minutes: 5` | Unbounded github-script-only job | low |
| levelup-tests.yml — resolve-pr-context | Add `timeout-minutes: 5` | Unbounded github-script-only job | low |
| mcp-smoke-tests.yml — resolve-self-hosted-pr-context | Add `timeout-minutes: 5` | Unbounded github-script-only job | low |
| presubmit.yml — limit-pr-runs | Add `timeout-minutes: 5` | Unbounded checkout+composite-action job | low |
| pypi-publish-testing-utils.yml — build | Add `timeout-minutes: 10` | Unbounded small-package build | low |
| pypi-publish-testing-utils.yml — publish | Add `timeout-minutes: 5` | Unbounded, also holds pypi credentials — exposure-window concern | low |
| test.yml — limit-pr-runs | Add `timeout-minutes: 5` | Unbounded; first job on every push/PR | low |
| test.yml — detect-changes | Add `timeout-minutes: 5` | Unbounded; blocks whole downstream matrix | low |

### PR-3: Needs-user-judgment (cuts of possibly-valued checks)

| Workflow | Change | Impact | Risk |
|---|---|---|---|
| test.yml | Add draft-skip `if:` condition to self-hosted job(s) | #2 offender, 68 queued runs, 6 job legs — but removes CI signal from draft PRs mid-WIP | medium — value tradeoff: does the team want feedback during draft iteration? |
| presubmit.yml | Same draft-skip condition, 8 self-hosted job legs | #3 offender, 41 queued runs, widest fan-out workflow — largest per-run waste reduction if drafts are truly not actionable | medium — same tradeoff, amplified by fan-out |
| self-hosted-mvp-shard1.yml | Add `paths:` filter to `on.push.branches:[main,dev]` matching the existing PR-trigger filter | #4 offender, 29 queued runs, 4 job legs — risk of silently skipping legitimate main/dev CI if the paths list is later incomplete or a new test-relevant path is added outside it | medium — requires owner sign-off on the exact path list and a process for keeping it in sync |
| coverage.yml | Add draft-skip condition to the self-hosted `coverage` job only | Tied #5 offender, 24 queued runs — but some teams want coverage trend visibility even pre-review | medium — value tradeoff on WIP coverage visibility |

---

## APPENDIX: Round-2 ultracode review on po2-v2 (dc86a325) -- 2026-07-07 ~16:20 PT

**VERDICT: BLOCK** (6 confirmed findings: 1 critical, 2 major, 3 minor/not itemized here).

**THE CRITICAL** (arithmetic, verified numerically by the reviewer): the v2
design's framing -- "fixed schedule is the primary safety, the loadavg gate
is a secondary brake" -- is FALSE on this specific box. The fixed schedule
alone (batch=2, sleep=30s) peaks at **+17.32 respawn load**. This box's own
baseline load runs **9-15** (not near-zero, as an idealized "safe with zero
feedback" design implicitly assumed). Combined: **26.3-32.3, BREACHING the
24 watchdog ceiling** whenever the load gate isn't functioning for any
reason. v2's own safety test used a 20.0 ceiling with NO baseline load
offset added -- it validated an easier claim than the code comment actually
asserted. A composite simulation WITH the gate active stays at 15.7-18.6 --
meaning **the gate is load-bearing, not cosmetic** -- directly inverting
v2's design principle (main's v2 brief said the fixed schedule should be
primary and the gate secondary; the numbers say the opposite is true on
this box).

**Supporting majors**:
(a) On Linux, a failed `/proc/loadavg` read is silently swallowed via
    `.ok()` with no warning -- the daemon can silently regress into the
    unsafe no-gate regime with zero operator visibility.
(b) Pacing has no OVERALL budget across the whole `ensure_count` call --
    under sustained load, a full 16-runner refill can take 16+ minutes
    inside ONE `ensure_count` invocation, starving monitors/canary (they
    only run AFTER `ensure_count` returns; v2's deadline-rebasing fix
    doesn't help if they never get a turn to run at all).

## V3 BRIEF (dispatched to codex, same branch sidekick/po2-respawn-pacing)

1. **Incremental refill**: give the respawn loop a per-`ensure_count`-call
   budget (~90-120s max). Start whatever fits safely within that budget,
   then RETURN -- let the NEXT serve-loop iteration continue the refill.
   Monitors run in between iterations naturally; starts-per-minute become
   inherently bounded. Ephemeral refill does not need to complete in one
   call; `ensure_count` runs every loop anyway. This structurally kills the
   monitor-starvation major and simplifies the batch-schedule arithmetic.
2. **Gate-primary, honestly**: the loadavg gate becomes the PRIMARY safety
   mechanism (matching what the numbers actually showed, not the v2
   framing). Compute allowed concurrent starts from headroom:
   `allowed = floor((safety_ceiling(default 20) - current_load) / 4.4)`,
   clamped to `[0, batch_size]`. When no load signal is available (non-Linux,
   OR a Linux read/parse failure), fall back to MAX-CONSERVATIVE: 1 start
   per iteration (15 baseline + 4.4 = 19.4, stays under 24 even in this
   box's worst-case baseline) + warn-once AND fire a real `alert::` alert
   that the safety gate is dark (not just a log line).
3. Fix the silent Linux `.ok()` swallow -- route it through the same
   warn-once + alert path as the non-Linux case.
4. **Tests**: the safety-property test must add the worst-case baseline
   load offset (15) and assert the simulated total stays under 24 for BOTH
   the gate-active path AND the gate-dark (no-signal) fallback path; keep
   the existing must-fail-against-old-defaults sanity check; add a
   `main.rs` match-arm wiring test for the partial-success streak logic
   (a round-2 minor finding).
5. Update the design comment in the code to match reality: gate-primary,
   not schedule-primary.

Round-3 review will re-run the same arithmetic against the new diff --
codex was told to derive and document the actual numbers (headroom formula,
worst-case totals) directly in the diff/commit message this time, not just
assert a comment. Still holding: nothing deploys until a SHIP verdict.
