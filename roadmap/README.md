# ez-gh-actions roadmap

Rolling operational notes for the `ezgha` self-hosted runner daemon.

## Next-steps queue (full, prioritized — 2026-07-07 takeover)

Source: docs/goal-gap-review-20260706.md (53-agent adversarial review, 45 findings, 0 refuted;
scorecard: hardened 5/10, self-healing 4/10, throughput 4/10, trimming 1/10, alerting 0/10)
plus docs/innovation-canary-slo-20260706.md and docs/planning-takeover-20260707.md.
Track live status with `br list --status open`.
Reordered 2026-07-06 (late eve) per external cold review: k4h promoted (don't build green
features on dishonest gates), ozk/9yt precede exit-after-N escalation (restart-storm risk),
juv reframed as a reusable run↔job↔runner correlation layer. Stale beads audited: 5rz closed
(Rust pagination fixed at github.rs:226), gdy closed (init capacity bail at main.rs:190-210),
jleechan-5rv downgraded P0→P2 (watchdog landed; residual suspicion is the bxy slot leak).
Takeover audit 2026-07-07 reconciled current beads against Claude/Codex sparse history:
`gdy` is now actually closed in beads, `bxy` promoted to P1, `ozk` promoted to P2,
`juv` retitled as the correlation layer, and missing Docker-timeout bead `fl0` created.

**Phase 1 — stop the bleeding + honest gates (S each)**
1. ~~Watchdog pings + WatchdogSec=180 in source~~ — DONE `aabd822`/`42dff7c` (Linux deployed; Mac install pending, see jleechan-5rv/0q9)
2. ~~`bxy` (P1)~~ — DONE: release_slot on JIT failure + quarantine corrupt slot_assignments.toml instead of wedging (read_slot_assignments hard-fails)
3. ~~`k4h` (P1, promoted)~~ — DONE: verify-exit-criteria.sh honesty updated (Gate 3 pagination/empty-edge checks, Gate 7 real monitor checks)
4. ~~`fl0` (P1)~~ — DONE: Docker CLI timeout wrapper on all `Command::output()` calls used by serve/status/stop/init
5. `twp` (P2) — regression test: list_runners Err must not mutate slot file (EXIT-CRITERIA's "single most important regression test")
6. `n5p` (P2) — build.rs: fail loudly / append `-dirty` instead of silently embedding "unknown" (Gate 0 provenance)

**Phase 2 — eyes, then self-healing (S–M)**
7. ~~`zmk` (P1)~~ — DONE: alert contract, durable file channel, Slack/email transports, systemd failure hooks, and Gate 7 live test-send proof
8. `ozk` (P2) — 403/429 detection + exponential backoff in run_gh; REQUIRED before any exit-after-N escalation (otherwise degraded-state restarts recreate incident-A restart storms against the API)
9. `9yt` (P1) — Colima/Lima VM auto-restart on backend failure (cooldown + attempt cap); the 4h crash-loop class from incident A
10. ~~`juv` (P1)~~ — DONE: reusable GitHub run↔job↔runner correlation layer plus manual and daemon-scheduled canary SLO consumer with host-specific workflow dispatch
11. Degraded-state escalation (consecutive-failure counter → sd_notify STATUS → exit-after-N) — only after ozk + 9yt bound the restart loop

**Phase 3 — reap + trim on the correlation layer (M–L)**
12. `qbl` (P2) — zombie-runner reaper on juv's layer; MUST cancel the stuck run first, then delete registration (planner + fake executor landed; live mutation still gated)
13. `ftw` (P3) — max-job-duration config + cancel enforcement (first actual Goal 4 code; same layer)
14. ~~`len` (P3)~~ — DONE: queued-job starvation detection integrated into daemon + alert log proof captured; real throughput still blocked by saturated queue/juv correlation work

**Phase 4 — hygiene tail**
15. `2ik` (P3) — commit or delete external ~/.local/bin/ezgha-fleet-watchdog.sh (Gate 7 committed-config rule)
16. `1fu`/`zkn`/`zyb` — hostname-scoped dereg residual, runner_group_id config, minor review gaps
17. Add `.claude/hooks/git-header.sh` or drop the footer convention for this repo (hook referenced by global CLAUDE.md is absent here)

**Cross-host (Mac)**: jleechan-5rv (P2, re-test after new binary + bxy), jleechan-0q9 (Colima socket flaps), install watchdog binary on Mac host.

## Recent activity (rolling)

### 2026-07-07 (Codex continuation) — saturation investigation + `/nextsteps` tracker sync

- Investigated reported runs older than 30 minutes. Current evidence points to `jleechanorg/worldarchitect.ai` saturation, not label mismatch: roughly 90+ queued runs, 20 in-progress runs, oldest fresh queued run >200m, and the `ez-runner-c-*` fleet online/busy.
- Found one real runner-health contributor during the same investigation: `ez-runner-c-16` / runner id `133301` was offline+busy with no local container and pinned to run `28879329099`; cancelling that run allowed deleting the stale runner registration and repopulating slot 16.
- Stale queued zombie cleanup is not complete: `scripts/cleanup-stuck-runs.sh --zombies` found `28845560622`, but `gh run delete` returned HTTP 403 with current auth. Tracked as `ez-gh-actions-nq0`.
- External watchdog was hot-patched out-of-repo to run locally on Linux and avoid false restarts during ephemeral churn when all configured slots are reserved. It still violates the committed-config rule until versioned or removed; tracked as `ez-gh-actions-2ik`.
- Tracker sync: created `ez-gh-actions-6ah` for queue backlog drain/superseded-run cleanup policy and `ez-gh-actions-nq0` for stale zombie cleanup permissions; updated `ez-gh-actions-142` with canary-capacity proof blocker evidence.
- Implemented `ez-gh-actions-6ah`: `scripts/queue-backlog-drain.sh` gives a read-only tail/superseded report with exact run URLs; `scripts/cleanup-stuck-runs.sh` is now dry-run by default, supports `--superseded`, requires `--apply` for mutation, and keeps broad fresh-tail cancellation behind explicit `--tail --apply`.
- Current blockers before claiming healthy throughput: reserve canary capacity (`ez-gh-actions-142`), fix zombie delete permissions (`ez-gh-actions-nq0`), and version or remove the external watchdog (`ez-gh-actions-2ik`). Backlog tooling (`ez-gh-actions-6ah`) is implemented, and the latest dry-run found zero superseded candidates, so broad cancellation is not evidence-backed.

### 2026-07-06 (eve) — 53-agent adversarial goal-gap review + zombie-registration incident

- Ran ultracode workflow (7 reviewers + 1 adversarial skeptic per finding): **45 findings, 33 confirmed, 12 partial, 0 refuted**. Scorecard vs user goals: hardened 5/10, self-healing 4/10, throughput 4/10, trimming 1/10, **alerting 0/10**.
- Docs: `docs/goal-gap-review-20260706.md` (scorecard + ranked gaps + 4-phase roadmap), `docs/goal-gap-findings-20260706.md` (per-finding evidence), `docs/incident-20260706-fleet-outage.md` (repo-lifetime timeline: 1,490 service starts + 32 watchdog events + 1,380 no-backend errors on 07-06 alone; incidents A/B/C causal chain), `docs/innovation-canary-slo-20260706.md` (/innovate pick + brainstorm).
- Live incident C diagnosed + healed: 14/15 registrations offline-but-busy wedged JIT names → fleet ~1/16, worldarchitect.ai queue 42+. **Key API learning: `DELETE /orgs/.../runners/{id}` returns HTTP 422 while a zombie job is assigned — cancel the run first, then delete.** Fleet self-recovered to 15/16; queue drained.
- 12 beads filed (zmk 9yt juv qbl bxy n5p k4h twp ftw len ozk 2ik); closed drg as superseded by aabd822.
- Docker/Colima question answered: colima IS the VM hosting dockerd (context `lima-colima`, 4cpu/12GiB — source of the `cpus 2→0.5` clamping); "only colima" isn't an option; alternative is native dockerd minus the isolation boundary. Keep VM, add auto-restart (9yt), consider sizing up.

### 2026-07-07 — Fleet doctor session + watchdog root-cause

- Root-caused Linux flapping: `WatchdogSec=60/180` kills `ezgha serve` when `ensure_count` + paginated `gh api` exceeds watchdog window; fix drafted locally (`src/watchdog.rs`, ping before/after + per-runner ping).
- Mac: `minimum_isolation=vm` on container-only Colima caused fail-closed; fixed in `~/.config/ezgha/config.toml` → `container`.
- Added `scripts/queue-health.sh`, `scripts/cleanup-stuck-runs.sh`, doctor section 8 (queue tail >20m), harness trigger on failure.
- Scanned last 20 open PRs: **0 runner failures in completed job logs**; saturation = stuck `queued`, not infra crash.
- [PR #8193](https://github.com/jleechanorg/worldarchitect.ai/pull/8193) (worldarchitect.ai): CodeRabbit APPROVED on `ce269044`; checks pending on saturated fleet.
- **Next:** commit/push local watchdog fix → `cargo install` both hosts → re-enable stable `WatchdogSec=180`.

### 2026-07-07 (second pass) — hardening reconciliation + exit criteria revalidation

- Ran `/nextsteps` equivalent and synced `roadmap/README.md` + beads for implemented P1 items `bxy`, `k4h`, and `fl0`.
- Ran targeted Rust test ladder on `src/docker_backend` and full suite (`cargo test`, `cargo clippy`, `cargo check` all passing).
- Rebuilt and restarted service with `cargo install --path .` and verified `systemctl --user status ezgha.service` active.
- Re-ran `./docs/verify-exit-criteria.sh`: **ALL AUTO GATES PASS** after reinstall; Gate 10 only passed once GitHub API budget recovered (4950 remaining).

### 2026-07-07 (hardening follow-up)

- Landed `ez-gh-actions-ozk`: added `run_gh` exponential backoff + 403/429 parser with retry-after support in `src/github.rs`; added unit tests in `src/github.rs`.
- Landed `ez-gh-actions-n5p`: updated `build.rs` to embed `-dirty` when git worktree has uncommitted changes instead of `unknown`; verified Gate 0 after reinstall.
- Landed `ez-gh-actions-twp`: added regression unit coverage in `src/docker_backend.rs` ensuring `list_runners` failure does not mutate `slot_assignments.toml`.
- Closed `ez-gh-actions-bn0` with a `/nextsteps` synchronization pass and synchronized issue states.

### 2026-07-07 (Codex continuation) — Gate 4 rate-limit hardening + current blockers

- Confirmed current open queue has **no P0**; `ez-gh-actions-nq6` is tracking the P0/P1 hardening alignment pass.
- Added realistic `gh` rate-limit regression coverage in `src/github.rs`: `gh` exit-code 1 with HTTP 403/429, missing `Retry-After` fallback to default backoff, and a fake-`gh` retry-count proof.
- Hardened `docs/verify-exit-criteria.sh` Gate 4: checked `gh` calls now report API/rate-limit failures explicitly, one failed job lookup is skipped with a warning, TOML parsing uses stdlib `tomllib` before external `toml`, and the gate now fails unless 5 completed selftests prove the configured runner prefix.
- Added `docs/test-verify-exit-criteria-gate4.sh`, a shell regression for the exact Gate 4 failure mode where the newest job lookup is rate-limited but later completed selftests prove the configured fleet.
- Hardened `ez-gh-actions-zmk`: bounded Slack/sendmail alert transport, Slack HTTP failures fail delivery, cooldown is recorded only after at least one transport succeeds, email subjects include severity, and Linux systemd units now wire watchdog/start-limit alert hooks.
- Verification: `cargo test` (81/81), `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `docs/test-verify-exit-criteria-gate4.sh`, and `doctor.sh` prefix-honesty checks pass. Live `docs/verify-exit-criteria.sh` passes Gates 0/1/2/3/4/7/10 after five completed `ez-runner-b-*` selftests: 28849106680, 28849103583, 28845059991, 28844964976, and 28843056881.
- Remaining health blockers: `doctor.sh` still fails queue health (`worldarchitect.ai` fresh queue tail >100m), zmk lacks a runtime durable alert channel/test-send gate, and `juv`/`len` remain required before claiming truly healthy throughput.
- `/f` binary run: `dark-factory` run `1a5a794f5e02`, evidence `/tmp/ezgha-dark-factory-zmk-20260707001325`, final outcome `exhausted`; `df-healer` points at `sandbox-exec unavailable` and missing holdout evaluator issues in the factory harness.

### 2026-07-07 (Codex continuation) — daemon queue starvation monitor

- Implemented and closed `ez-gh-actions-len`: optional `[queue_monitor]` config with legacy-config compatibility, daemon-side GitHub Actions queued/in_progress REST checks, fresh-vs-stale queue tail stats, consecutive starvation alerts, and independent stale queued zombie alerts.
- Integrated queue monitoring into `ezgha serve` as a non-fatal check after successful `ensure_count`; it is skipped after runner reconciliation failures to avoid compounding API pressure, and the loop pings the watchdog immediately before queue polling.
- Added focused tests for config compatibility, example configs, invalid repo/interval values, timestamp/stat boundaries, alert-log delivery after consecutive bad samples, critical escalation cooldown separation, stale zombie warnings, and non-fatal monitor errors.
- Verification: `cargo test` 100/100, `cargo fmt --check`, and `cargo clippy --all-targets -- -D warnings` pass. After Linux deploy at `fc17ed0`, Gate 0/1/2/3 passed; the daemon logged queue bad sample 1/2 and then wrote durable alert `queue.starvation.tail` to `/home/jleechan/.local/state/ezgha/alerts.jsonl` on sample 2.
- Current live state remains detection-only: `docs/verify-exit-criteria.sh` Gate 4 still fails because only 1 completed `ez-runner-c-*` selftest exists, and `doctor.sh` still marks `worldarchitect.ai` queue health BAD with >100m fresh tail. Do not claim queue recovery until fresh selftests complete.

### 2026-07-07 (Codex continuation) — watchdog stability, canary proof, and reaper safety seam

- Landed Linux watchdog stabilization through `7b6b262`: background systemd heartbeat, `NotifyAccess=all`, READY notification order preserving `WATCHDOG_USEC`, and a saturated-load soak with `NRestarts=0`.
- Revalidated exit criteria after reinstalling `7b6b262`: Gates 0/1/2/3/4/7/10 all pass; fresh canary run 28858122814 completed on `ez-runner-c-14` in 19s total, and Gate 7 wrote a fresh durable test alert to `/home/jleechan/.local/state/ezgha/alerts.jsonl`.
- Closed `ez-gh-actions-zmk`: alerting now has a runtime durable channel, bounded Slack/sendmail transports, `test-alert`, and systemd watchdog/start-limit hooks; residual notification transport expansion should be tracked separately if needed.
- Advanced `ez-gh-actions-qbl` without enabling live mutation: added `reaper-plan` dry-run planner, then a fake `ReaperApi` execution seam that enforces cancel -> poll -> optional force-cancel -> poll -> delete, exact job/runner revalidation, duplicate-runner-plan rejection, and fail-closed tests for every refusal path.
- Advanced `jleechan-0q9` with a Linux-side Mac-stability fix: backend restart commands are now bounded by a 30s spawn/poll/kill timeout instead of bare `Command::status()`, with tests for success, nonzero, missing command, and hung command. `/mac` still needs install + launchd/Colima/socket/6-runner soak proof before closing.
- Advanced `ez-gh-actions-juv`: added daemon-side background canary scheduler, `[canary].check_interval_seconds` defaulting to 10 minutes, bounded in-memory recent-result ring buffer, early SLO timeout for canaries that never start, and alerting for successful workflows that completed outside the configured runner prefix. Post-deploy Gate 4 found GitHub can expose provisional job `started_at` before `runner_name`; canary timing now requires a matching configured runner, and scheduled canaries wait one interval after service startup to avoid colliding with manual verifier canaries. A second live failure showed generic `[self-hosted, ezgha]` selftests can run on sibling Mac runners; selftest dispatch now passes `cfg.runner.labels` through `runs_on_json` so the canary targets the active host fleet.
- Closed `ez-gh-actions-juv` after live proof: manual verifier canary run 28859911319 completed on `ez-runner-c-6` with time-to-start 87s under the 90s SLO, and daemon-scheduled canary run 28860442002 dispatched at 03:47:23 and completed on `ez-runner-c-7` with time-to-start 68s.
- Fixed a test-harness flake exposed by the quality lane: Docker limit unit tests now inject daemon capacity instead of reading `docker` while alert tests mutate process `PATH`.
- Current next hardening focus: continue Mac `/mac` soak for `jleechan-5rv` and `jleechan-0q9`; then pick up `9yt` Colima/Lima auto-restart and the remaining qbl/ftw consumers.

### 2026-07-06 — Binary at 51a5b35, external fleet-watchdog band-aid

- Fleet functional but AMBER: external `ezgha-fleet-watchdog.sh` restarts every ~120s when count < configured.
- Slot reconciliation fixes landed in `077d07c` / `51a5b35` but supervisor kills and Mac policy gaps still cause 3–6 / 14–16 flapping.
