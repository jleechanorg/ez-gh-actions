# ez-gh-actions roadmap

Rolling operational notes for the `ezgha` self-hosted runner daemon.

## Next-steps queue (full, prioritized — 2026-07-06)

Source: docs/goal-gap-review-20260706.md (53-agent adversarial review, 45 findings, 0 refuted;
scorecard: hardened 5/10, self-healing 4/10, throughput 4/10, trimming 1/10, alerting 0/10)
plus docs/innovation-canary-slo-20260706.md. Track live status with `br list --status open`.

**Phase 1 — stop the bleeding (S each)**
1. ~~Watchdog pings + WatchdogSec=180 in source~~ — DONE `aabd822`/`42dff7c` (Linux deployed; Mac install pending, see jleechan-5rv/0q9)
2. `bxy` (P2) — release_slot on JIT failure + quarantine corrupt slot_assignments.toml (two documented manual-recovery wedges)
3. Docker CLI timeout wrapper on all `Command::output()` calls (github.rs:18-72 pattern) — permanent-hang mode on macOS, watchdog churn on Linux
4. `twp` (P2) — regression test: list_runners Err must not mutate slot file (EXIT-CRITERIA's "single most important regression test")
5. `n5p` (P2) — build.rs: fail loudly / append `-dirty` instead of silently embedding "unknown" (Gate 0 provenance)

**Phase 2 — real self-healing + eyes (S–M)**
6. `zmk` (P1) — Slack webhook + email alerting module; Goal 5 is 0/10, every other gap fails silently without this
7. `9yt` (P1) — Colima/Lima VM auto-restart on backend failure (cooldown + attempt cap); the 4h crash-loop class from 2026-07-06 incident A
8. `juv` (P1) — end-to-end canary workflow + SLO alert + deep-reconcile trigger (/innovate pick; universal ground-truth sensor)
9. `qbl` (P2) — zombie-runner reaper; MUST cancel the stuck run first, then delete registration (HTTP 422 lock, incident C)
10. Degraded-state escalation: consecutive-failure counter → sd_notify STATUS → exit-after-N so systemd machinery engages

**Phase 3 — harness honesty (M)**
11. `k4h` (P2) — verify-exit-criteria.sh: implement Gate 6, real Gate 7, fix Gate 3 empty-input/--slurp bugs; stop printing "ALL AUTO GATES PASS" while skipping gates
12. `2ik` (P3) — commit or delete external ~/.local/bin/ezgha-fleet-watchdog.sh (Gate 7 committed-config rule)

**Phase 4 — Goal 4 + remaining throughput (M–L)**
13. `ftw` (P3) — max-job-duration config + cancel enforcement (first actual Goal 4 code; reuses juv's run↔runner correlation)
14. `len` (P3) — queued-job starvation detection (integrate scripts/queue-health.sh into daemon + alert)
15. `ozk` (P3) — 403/429 detection + exponential backoff in run_gh
16. `5rz`/`1fu`/`gdy`/`zkn`/`zyb` — pagination >100, hostname-scoped dereg residual, init count clamp, runner_group_id config, minor review gaps

**Cross-host (Mac)**: jleechan-5rv (P0 ensure_count wedge), jleechan-0q9 (Colima socket flaps), install watchdog binary on Mac host.

## Recent activity (rolling)

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

### 2026-07-06 — Binary at 51a5b35, external fleet-watchdog band-aid

- Fleet functional but AMBER: external `ezgha-fleet-watchdog.sh` restarts every ~120s when count < configured.
- Slot reconciliation fixes landed in `077d07c` / `51a5b35` but supervisor kills and Mac policy gaps still cause 3–6 / 14–16 flapping.
