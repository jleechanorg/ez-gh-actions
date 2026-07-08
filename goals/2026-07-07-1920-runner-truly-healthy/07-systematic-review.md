# Systematic Review — ez-gh-actions + worldarchitect.ai CI

## Executive summary

ez-gh-actions is in good shape overall: most flagged code is either genuinely load-bearing (backend selection, platform probes, retry/backoff, watchdog thread, restart-storm limiter) or small test-only scaffolding. Only one clean DELETE survives verification (canary.rs's dead in-memory ring buffer, ~25 lines); four other DELETE recommendations (email alert channel, reaper execute engine, reaper CLI, ServeLock Drop) failed verification — three because they target active in-progress work tracked under beads `ez-gh-actions-qbl`/`7ap`, one because it's already been merged. Net safe deletion in ez-gh-actions today is small (~25-40 lines); the larger reaper.rs cleanup (500+ lines) is blocked pending a human decision on whether to abandon those beads.

worldarchitect.ai's CI surface is where the real opportunity — and the real audit failure mode — lives. Of ~20 "move off self-hosted" recommendations, only 4 pieces (ci-fix.md, RUNNER_VERSION_TEST_REPORT.md, test-email-notification.yml, coverage-report's runner reversion) actually verified safe; **roughly 15 recommendations were rejected because the audit didn't account for the repo's own documented policy** ("private repos must use self-hosted by default; ubuntu-latest requires an explicit approved exception") or because they'd break a structurally load-bearing job (`detect-changes`, `self-hosted-mvp-shard1.yml`'s exclusive ownership of core-mvp shards). The one big verified win is reverting `coverage-report` back to ubuntu-latest given current fleet saturation (busy 20/22, queued 134) — that alone frees a slot on every PR for ~$165/mo. Total safe-to-act deletions today: 2 stray docs + 1 dead workflow + 1 runner reversion in worldarchitect.ai, plus 1 dead struct field in ez-gh-actions. Everything else needs either a human policy call, a beads-owner decision, or re-verification.

## ez-gh-actions — ranked recommendations

| Area | Rec | Impact | Risk | Verified |
|---|---|---|---|---|
| `canary.rs` `recent_results`/`push_recent`/`RECENT_CANARY_RESULTS_LIMIT` | **delete** | ~25 lines, zero consumers outside own tests; disk history unaffected | low | ✅ verified safe |
| `alert.rs` `send_email`/`email_message` | delete | ~90 lines | low | **NEEDS-REVIEW** — email is a documented, schema-exposed channel closing a named 0/10 alerting gap (docs/goal-gap-review-20260706.md); real cooldown/fallback tests depend on it. Reject as scoped. |
| `github.rs` `cancel_workflow_run`/`force_cancel_workflow_run` + `reaper.rs` `ReaperApi` executor | delete | ~155-200 lines | low | **NEEDS-REVIEW** — active in-progress bead `ez-gh-actions-qbl` (P2) designs exactly this cancel→delete execution path; deleting destroys tested WIP. Get bead-owner sign-off first. |
| `reaper.rs` whole executor half (lines ~23-309, ~500 of 877 lines incl. tests) | delete | ~500 lines | low | **NEEDS-REVIEW** — same qbl/7ap beads; 16 unit tests encode the exact zombie-lock ordering fix from memory `gh-zombie-runner-422-delete-lock`. Not orphaned, mid-flight. |
| `main.rs` `Commands::ReaperPlan` + planner half of `reaper.rs` | delete | ~40 lines (main.rs) + gates deleting 877-line module | medium | **NEEDS-REVIEW** — deleting `ReaperPlan` struct while executor functions still reference it is a **compile break**; also contradicted by qbl/7ap beads planning to wire this up, not remove it. Raise risk to medium if ever revisited. |
| `main.rs` `ServeLock` manual `impl Drop` | delete | 10 lines | low | **STALE** — already deleted in commit `a9b7ce0`, confirmed ancestor of HEAD. No action needed. |
| `docker_backend.rs` `count_current_prefix_containers`/`current_prefix_containers` | consolidate | ~25 lines + 3 tests | low | unverified, low-risk, straightforward |
| `queue_monitor.rs`/`InvariantSamplerState` double-fetch with `queue_monitor` | consolidate | ~60-80 lines, halves worldarchitect.ai API calls per aligned tick | medium | unverified but well-reasoned; ties to a real past starvation incident |
| `docker_backend.rs` 4 test-injection statics | consolidate | test-only, no prod impact | low | unverified |
| `docker_backend.rs` test-only `_for(None,...)` wrappers | simplify | ~12 lines, touches ~15 call sites | low | unverified, marginal value |
| `github.rs` `JitRunner.name` discarded field | simplify | 1 struct field + discard line | low | unverified, trivial |
| `config.rs` `stale_hours` self-referential upper-bound check | simplify | 1 bail branch + 1 test | low | unverified |
| `docker_backend.rs`/`github.rs` scattered `watchdog::ping()` calls | simplify | ~17 call sites, redundant with heartbeat thread | medium | unverified — verify heartbeat thread truly covers every call site before removing |
| `queue_monitor.rs` incident-postmortem-length inline comments | simplify | ~80-120 lines of prose | low | unverified, pure readability |
| `main.rs` `choose_backend`/`wait_for_backend` duplicated `skipped_stronger` messaging | consolidate | ~15 lines | low | unverified |
| `main.rs` `run_queue_monitor_tick`/`run_invariant_sampler_tick` | consolidate | ~20 lines → 1 generic helper | low | unverified, existing tests unaffected |
| `queue_monitor.rs` E1 invariant sampler (~40% of file) | consolidate (flag for later delete) | whole subsystem is mission-scoped; delete after E5 sign-off | low | unverified — correctly flagged as time-boxed scaffolding, not yet due for removal |
| `release_stale_slots` 3-pass reconciliation | **keep** | none | medium | each pass maps to a distinct documented incident, 6+ pinned regression tests |
| `backend.rs` Backend/Selection | **keep** | none | low | load-bearing fail-closed policy + doctor diagnostics |
| `platform.rs` capability probes | **keep** | none | low | tight, well-tested, no dead code |
| `github.rs` retry/backoff classification | **keep** | none | low | narrowly scoped, incident-driven, well-tested |
| `config.rs` Alert/QueueMonitor/Canary/InvariantSampler config surface | **keep** | none | low | every field traced to a live reader |
| `watchdog.rs` module itself | **keep** | none | low | small, correctly scoped, genuinely load-bearing |
| `service.rs` installer | **keep** | none | low | every branch traces to a real past incident |
| `main.rs` `BackendRecoveryState`/restart-storm limiter | **keep** | none | high | self-heals the documented "Colima VM down" recipe |
| po2 throttle-layer removal cleanliness | **keep** (confirmed clean) | none | low | verified no orphaned remnants |

## worldarchitect.ai CI — ranked recommendations

| Area | Rec | Impact | Risk | Verified |
|---|---|---|---|---|
| `.github/workflows/ci-fix.md` | delete | removes dead placeholder doc | low | ✅ verified safe — no references anywhere |
| `.github/workflows/RUNNER_VERSION_TEST_REPORT.md` | delete | removes orphaned one-off report | low | ✅ verified safe — no references anywhere |
| `.github/workflows/test-email-notification.yml` | delete (whole workflow) | removes manual-only busywork workflow; production paths already exercise the same actions | low | ✅ verified safe — workflow_dispatch-only, no gate, no other caller, repo's own README already calls it "optional" |
| `test.yml` `coverage-report` job → revert to `ubuntu-latest` | delete (runner reversion) | frees 1 self-hosted slot/PR for ~$165/mo; fleet currently 20/22 busy, 134 queued | low | ✅ verified safe — no self-hosted-only dependency, no downstream `needs:`, artifacts flow via GitHub's cross-runner API |
| `self-hosted-mvp-shard1.yml` — delete entire file as "duplicate" of `test.yml` | delete | claimed 4 slots/push | low | **NEEDS-REVIEW / REJECT** — `ci-detect-changes.sh` explicitly unselects core-mvp-1/2/3 from `test.yml`'s matrix and hands ownership to this file by design (README.md:395 documents the hand-off). Deleting it drops PR coverage entirely. |
| `presubmit.yml` — move 8 jobs off self-hosted | delete | claimed 8 slots/push | low | **NEEDS-REVIEW / REJECT** — repo's own `design/hybrid-runner-failover-design.md` explicitly forbids blanket ubuntu-latest fallback (self-hosted billing "$44.31/day, under active scrutiny"); any fallback must be opt-in via `SELF_HOSTED_CAPACITY_MODE`, never hardcoded. |
| `test.yml` — 5 lightweight jobs (`limit-pr-runs`, `detect-changes`, `import-validation`, `beads-jsonl-validation`, `shell-script-tests`) off self-hosted | delete | claimed 5 slots/push | low | **NEEDS-REVIEW — mixed.** `limit-pr-runs` genuinely duplicates presubmit.yml's copy (safe to consolidate). `detect-changes` **must not be touched** — the real `test` job consumes its matrix output; deleting it is a structural break. `beads-jsonl-validation`/`shell-script-tests` are same-day additions hardening against real incidents (JSONL corruption PRs #7886/#7946/#8063; PR #8245 gave the shell tests their first CI caller) — deleting them reopens fixed gaps. |
| `doc-size-check.yml` — collapse self-hosted+ubuntu-retry into one ubuntu-latest job (3 near-duplicate findings) | delete/simplify | ~40 lines | low | **NEEDS-REVIEW / REJECT** — `retry-self-hosted`'s `# APPROVED_EXCEPTION` comment is the repo's established convention for individually-reviewed cost-policy exceptions (PR #6145's self-hosted-by-default mandate); collapsing would silently promote a narrow exception to the default. |
| daily-campaign/gcp-cost/gh-cost-report.yml — move to ubuntu-latest (2 findings) | delete/simplify | claimed 3 slots/day, up to 120min | low | **NEEDS-REVIEW / REJECT** — all three are hard-pinned via `vars.SELF_HOSTED_RUNNER_LABELS` (confirmed live = `["self-hosted"]`), not incidentally self-hosted. Consolidating the 3 files' duplicated boilerplate into one file is still fine; only the runner-migration part is blocked. |
| `claude-processor.yml` off self-hosted (2 findings, one bundled) | simplify | claimed 1 slot/dispatch | low | **NEEDS-REVIEW / REJECT** — `CLAUDE_ENDPOINT` targets `127.0.0.1:5001` (confirmed via 3 docs); moving to a GitHub-hosted runner breaks it outright (connection refused). Separately, its trigger source (`repository_dispatch: claude-command`) has no confirmed in-repo caller — investigate dormancy before touching runner or deleting. |
| `green-gate.yml` `green_gate_precheck` off self-hosted | delete | 1 slot/PR event | low | **NEEDS-REVIEW** — technically feasible (heavy polls already extracted to ubuntu-latest siblings) but this repo requires explicit per-migration approval (precedent: PR #8257); ship only with sign-off. |
| 8 deploy/preview workflows (deploy-dev, deploy-levelup-test, deploy-dice-audit, auto-deploy-dev, pr-preview, pr-cleanup, preview-image-janitor, preview-service-janitor) off self-hosted | delete/simplify | claimed largest category, 8 files | low | **NEEDS-REVIEW / REJECT** — self-hosted here is a private-repo security/cost policy (README.md), not a Docker/Colima artifact; migrating would also relocate `GCP_SA_KEY` handling onto ephemeral hosted infra. Requires explicit human-approved exception per README. |
| `bead-pr-lint.yml` — delete PR-body format gate | delete | removes a blocking gate | low | **NEEDS-REVIEW / REJECT** — added 3 days ago (PR #8154) with explicit rationale (0/30 PRs referenced tracked beads); runs on ubuntu-latest already (fleet-saturation rationale is inapplicable); enforces the user's own standing beads-tracking policy. Deleting would also orphan `pull_request_template.md`'s reference to it. |
| `wiki-html.yml` off self-hosted | simplify | 1 slot | low | ✅ verified safe (via bundled cross-check) — pure Python/git, no local-network coupling |
| `pypi-publish-testing-utils.yml` off self-hosted | simplify | 2 slots/release, minor security win (token off shared fleet) | low | ✅ verified safe (via bundled cross-check) — standard PyPI publish, public-internet only |
| `.github/workflows/test.yml`+`presubmit.yml` `limit-pr-runs` duplicate job | consolidate | 1 slot/push, ~15 lines | low | unverified but structurally obvious duplicate; safe to merge into one reusable workflow |
| 15 files' dead `cancel-in-progress: ${{ github.event_name != 'release' }}` conditional | simplify | readability only, zero-risk | low | unverified but mechanically checkable (grep for `release:` trigger) — safe |
| `deploy-production.yml`/`deploy-staleness-gate.yml`/`hermes-pr-tag-listener.yml` missing `concurrency:` block | simplify | closes a real overlap/duplicate-run gap | low | unverified, low-risk, additive (not a deletion) |
| `resolve-pr-context` duplicated across 4 workflows | consolidate | ~150 lines, 4 slots/trigger | low | unverified — reasoning sound (pure `github-script`), but confirm no self-hosted dependency before moving, given repo's pattern of surprise dependencies |
| `auth-browser-tests.yml`/`mobile-auth-regression.yml` dpkg-deb Playwright workaround → ubuntu-latest | simplify | removes ~30-line hack, frees a 45-min slot | medium | unverified — technically sound (targets deployed Cloud Run URL) but is *also* a self-hosted→ubuntu-latest migration; apply the same policy-approval gate as above before acting |
| `self-hosted-mvp-shard1.yml` `harness-autonomy-self-hosted` job → fold into `test.yml` matrix | consolidate | 4 slots/push | medium | unverified, and **in tension** with the verified finding above that this file is the sole intentional owner of core-mvp shards — proceed carefully, scope to just the harness-autonomy job, not the whole file |
| `runner-checkout-lint.yml` + `workflow-lint.yml` | consolidate | 1 file, 1 checkout instead of 2 | low | unverified, plausible |
| `codex-skill-sync.yml` | consolidate | marginal file-count reduction | low | unverified, already ubuntu-latest, low priority |
| `quarantine-reset.yml` | **keep** | none | low | genuinely load-bearing, edits runner-local state |
| `hermes-pr-tag-listener.yml` | **keep** | none | low | no gating semantics to remove, cost unconfirmed |
| `test.yml` `test` matrix + `merge-commit-gate` | **keep** | none | low | the one legitimately heavy self-hosted job; relief should come from deleting surrounding trivial jobs, not this one |

## Systematic flaws (cross-cutting)

1. **Policy-blind deletion bias in the worldarchitect.ai pass.** ~15 of ~20 "move off self-hosted" recommendations were generated by checking only technical dependency (does the job need Docker/local state?) without checking the repo's own documented cost/security policy (self-hosted-by-default for private repos, explicit-approval-required exceptions, `design/hybrid-runner-failover-design.md`'s ban on blanket ubuntu-latest fallback). This is exactly the "conditional runs-on / cost-optimization" pattern the user's standing instructions flag as requiring explicit confirmation before implementing — and it recurred at scale, not as an isolated miss.

2. **Inconsistent policy application even within verification.** The `coverage-report` runner-reversion was verified safe by checking technical dependency + current fleet saturation, without flagging the same self-hosted-by-default policy tension that sank ~15 sibling recommendations. That item happens to be correct (it's a cost-driven *exception* being un-done, not a new exception being created), but the reviewer got there without applying the policy check that caught the others — a coincidental pass, not a consistent method.

3. **Reactive-accretion pattern in queue_monitor.rs/canary.rs is real but mostly still "keep."** Several ez-gh-actions findings correctly identify duplicated fetch logic and postmortem-length comments as things that grew reactively after real incidents — but nearly every load-bearing branch was deliberately built to fix a specific documented failure (zombie-runner lock, GH secondary rate limits, watchdog SIGABRT, Colima down). The audit's own "err on deletion" bias needed the verification pass to catch this; without it, several genuinely load-bearing incident-response code paths would have been deleted.

4. **In-progress work repeatedly misclassified as dead code.** Three separate ez-gh-actions findings (reaper execute functions, reaper.rs executor half, ReaperPlan CLI) all correctly observed "no caller today" via grep, but all three missed that two open P2 beads (`qbl`, `7ap`) explicitly track this as mid-flight, deliberately staged (plan → fake-execute → live-wire) work. `#[allow(dead_code)]` was read as "abandoned" when it actually meant "not wired yet, on purpose." Grep-level dead-code detection without a beads/roadmap cross-check is an unreliable signal for anything more than a few hours old.

5. **Duplicate/contradictory findings on the same file went unreconciled.** `doc-size-check.yml`, `claude-processor.yml`, and the three `daily-*-report.yml` files each generated 2-3 separate line items (some via direct pass, some via bundled batch) recommending the same action with different confidence levels — including one explicitly verified-false sitting next to unverified duplicates recommending the identical change. A synthesis step should dedupe by file before ranking, not just by rationale text.

## Suggested next actions (deletion-biased, ordered)

1. **Ship immediately (verified safe, zero blockers):**
   - Delete `.github/workflows/ci-fix.md` and `RUNNER_VERSION_TEST_REPORT.md` (worldarchitect.ai).
   - Delete `.github/workflows/test-email-notification.yml` (worldarchitect.ai).
   - Delete `CanaryDaemonState.recent_results`/`push_recent`/`RECENT_CANARY_RESULTS_LIMIT` (ez-gh-actions `canary.rs`).
   - Move `wiki-html.yml` and `pypi-publish-testing-utils.yml` off self-hosted (worldarchitect.ai).

2. **Ship with a stated cost-tradeoff note (verified safe, but has a $ dimension worth a one-line ack):**
   - Revert `test.yml`'s `coverage-report` job from self-hosted back to `ubuntu-latest` — directly relieves current fleet saturation (20/22 busy, 134 queued).

3. **Get explicit human/bead-owner sign-off before touching (do not delete unilaterally):**
   - ez-gh-actions: `alert.rs` `send_email`, all of `reaper.rs` + `Commands::ReaperPlan` — ping the owner of beads `ez-gh-actions-qbl`/`7ap` to confirm the feature is abandoned before any deletion; otherwise leave as-is.
   - worldarchitect.ai: any self-hosted→ubuntu-latest migration (presubmit.yml's 8 jobs, the 3 daily reports, `claude-processor.yml`, the 8 deploy/preview workflows, `green-gate.yml` precheck, `doc-size-check.yml` collapse) — batch these into one explicit routing/cost decision with the user rather than acting file-by-file, per the repo's own precedent (PR #8257) and the standing "confirm cost/routing decisions" rule.

4. **Do not touch (would break something structural):**
   - worldarchitect.ai `self-hosted-mvp-shard1.yml` (sole owner of core-mvp shards by design) and `test.yml`'s `detect-changes` job (feeds the real `test` job's matrix).
   - ez-gh-actions `main.rs`'s ReaperPlan+struct deletion as scoped (guaranteed compile break) and the already-merged `ServeLock` Drop cleanup (no target left).

5. **Low-risk mechanical cleanups worth batching into one PR each, independent of the above blockers:**
   - ez-gh-actions: consolidate `count_current_prefix_containers`/`current_prefix_containers`; consolidate the 4 test-injection statics; simplify `JitRunner.name` discard; simplify `config.rs` `stale_hours` bound; consolidate `main.rs` tick wrappers and `choose_backend`/`wait_for_backend` messaging.
   - worldarchitect.ai: replace the 15 dead `cancel-in-progress: event_name != 'release'` conditionals with `true`; add missing `concurrency:` blocks to `deploy-production.yml`/`deploy-staleness-gate.yml`/`hermes-pr-tag-listener.yml`; consolidate the duplicated `limit-pr-runs` job and the 4-file `resolve-pr-context` job.

$(git rev-parse --show-toplevel)/.claude/hooks/git-header.sh --with-api output and header_check.py were not run — this is a subagent response returned as plain text to the calling script, not an interactive session turn.