# Goal-Gap Deep Review — 2026-07-06 (adversarially verified)

**Method:** 53-agent ultracode workflow — 7 parallel deep reviewers (crash-hardening, self-healing,
throughput, job-trimming, alerting, spec-gap, live-evidence), one independent adversarial skeptic per
finding (prompted to refute), synthesis pass. **45 findings: 33 CONFIRMED, 12 PARTIAL
(skeptic-corrected), 0 REFUTED.** Zero refutations means no reviewer noise survived into this report.

**Companion docs:** `goal-gap-findings-20260706.md` (full finding-level evidence),
`incident-20260706-fleet-outage.md` (timeline of today's outages).

---

# ezgha Goal-Gap Review — Synthesis Report

**Repo:** /home/jleechan/projects/ez-gh-actions · **Date:** 2026-07-06
**Basis:** adversarially-verified findings (CONFIRMED = skeptic failed to refute; PARTIAL = skeptic-corrected claim used)

**Live-evidence headline:** the fleet looks green right now (15–16/16 containers, 21/21 runners online), but the daemon was watchdog-SIGABRT'd 10 times *today* (17:59–20:16, ongoing during review), crash-looped for 4 hours while Colima was down (1,380+ exits), has logged **1,562 service starts in 14 days**, and both machine-checkable health gates currently FAIL. None of this generated a single notification.

---

## 1. Per-Goal Scorecard (10 = fully achieved)

| # | Goal | Score | Justification |
|---|------|-------|---------------|
| 1 | Hardened / never crashes | **5/10** | Zero panics in 14 days and gh/probe calls are timeout-bounded, but the daemon is in an *active* watchdog kill/restart loop today (single ensure_count iteration with count=16 exceeds WatchdogSec; src/main.rs:320-332), every docker call is unbounded (permanent hang on macOS; src/docker_backend.rs:274-477), and a corrupt slot file wedges spawning forever (src/docker_backend.rs:59-72). |
| 2 | Self-healing | **4/10** | Strong container/slot/409 recovery, but three of the four CLAUDE.md recipes are human-only: Colima VM death is never recovered by anything (critical — Restart=no, no `limactl start` in src/), corrupt slot file needs manual `rm`, and fast-crash modes exhaust StartLimitBurst and leave the service permanently dead; every sustained failure collapses into an eprintln loop that still pets the watchdog. |
| 3 | Always-healthy throughput | **4/10** | ensure_count genuinely tops up to N every 30s and the incident-hardened reconcile logic is solid, but health is measured purely by local container count: zombie containers (up locally, offline on GitHub) permanently occupy capacity undetected (critical; docker_backend.rs:503-505), queued-job starvation is measured nowhere (critical; zero `queued` matches repo-wide), and the daemon has zero API-budget awareness or backoff. |
| 4 | Trim/cancel long-running actions | **1/10** | Zero matches for "cancel" repo-wide; container age (`RunningFor`) is parsed but display-only (main.rs:345); every reclaim path skips busy runners, so a hung job holds its slot until GitHub's 6h default timeout. The single point is for read-only run visibility in doctor.sh and delegation to GitHub's server-side timeout. |
| 5 | Slack/email alerting | **0/10** | No notification code, no config schema, no delivery channel — the only "notify" in src/ is sd_notify to systemd; worse, Gate 7 ("Monitoring exists") passes vacuously in verify-exit-criteria.sh:197-205, green-lighting the exact silent-3am-decay it was written to prevent. Today's 4-hour outage paged no one. |

---

## 2. Top Gaps — Ranked by (User Impact × Effort-to-Close)

Ranked with quick wins first when impact is comparable.

### Tier 1 — high impact, small effort (do this week)

1. **Watchdog kill/restart loop is live right now.** Ping the systemd watchdog *inside* ensure_count between per-runner steps (or from a dedicated thread), and port the hand-tuned WatchdogSec=180 back into source. — src/main.rs:320-332, src/service.rs:51, src/docker_backend.rs:493-554. Effort: **S**. Impact: stops the active SIGABRT churn (10 kills today) and prevents the next `install-service` from silently regressing 180→60.

2. **Slot-leak on JIT failure + corrupt-slot-file quarantine.** (a) Call release_slot in start_one's jitconfig-error path (contract at docker_backend.rs:93-96 already demands it). (b) On TOML parse failure, rename the file to `.corrupt.<ts>` and start empty — the reconcile logic already tolerates an empty set. — src/docker_backend.rs:342-349, :59-72. Effort: **S**. Impact: kills two documented manual-recovery wedges outright.

3. **Timeout-wrap all docker CLI calls.** The helper pattern already exists twice in the codebase (github.rs:18-72 45s; platform.rs 4s) — apply it to daemon_capacity, docker rm/run, managed_containers, free_disk_gb. — src/docker_backend.rs:274-278, :327-329, :369, :399-408, :473-477. Effort: **S**. Impact: closes the permanent-hang mode on macOS launchd and converts Linux watchdog-kill churn into logged skip-and-retry.

4. **Colima VM auto-restart.** The single confirmed *critical* self-healing gap: on docker-backend failure N consecutive times, attempt `limactl start colima` (bounded, once per cooldown) before the passive retry loop. — src/main.rs:320-333, src/docker_backend.rs:398-410. Effort: **S–M**. Impact: removes the only failure class that darkened the fleet for 4 hours today.

### Tier 2 — high impact, medium effort

5. **Zombie-runner detection (critical, Goal 3).** Cross-check managed containers against GitHub runner status each cycle; `docker rm -f` a container whose owned runner is offline > N minutes so the slot recycles. Today `alive == count` short-circuits everything and throughput can silently hit zero while all local signals read healthy. — src/docker_backend.rs:503-505, :218-242. Effort: **M**.

6. **Alerting channel (Goal 5, currently 0%).** A minimal `[alert]` config block (Slack webhook and/or email) + a single `alert()` used by: N-consecutive ensure_count failures, disk-floor breach, VM-restart attempts, start-limit-hit. Without this, every other self-heal failure stays invisible. — new module; hook points at src/main.rs:327-331. Effort: **M**.

7. **Degraded-state escalation.** Count consecutive ensure_count failures; after N, stop petting the watchdog / exit non-zero so systemd's Restart + a future OnFailure= hook engage; emit sd_notify STATUS so `systemctl status` shows degraded. — src/main.rs:320-332. Effort: **S–M** (pairs with #6).

8. **Fix the verification harness itself.** Gate 6 (resilience) does not exist in verify-exit-criteria.sh despite the banner "ALL AUTO GATES PASS"; the "single most important regression test" (list_runners Err → no slot-file mutation) is absent from the suite; Gate 7 passes vacuously; Gate 3 crashes unlabeled on API blips and fails OPEN above 100 runners (missing `--slurp`, same bug fixed in src/github.rs:236). — docs/verify-exit-criteria.sh:113-147, :197-215; test seam in src/docker_backend.rs:154-160. Effort: **M**.

### Tier 3 — real gaps, larger or lower urgency

9. **Goal 4 trimming: max job duration enforcement.** Compare `RunningFor` (already parsed, docker_backend.rs:394-395) against a configurable ceiling; on breach, cancel the run via `gh run cancel` / POST .../runs/{id}/cancel, then rm the container. Effort: **M–L** (needs run↔runner correlation).

10. **Queue-starvation detection.** Periodically compare GitHub queued jobs (matching cfg labels) against online-idle capacity; alert on sustained mismatch (catches label typos, wrong runner group, zombie fleets). Effort: **M**.

11. **API-budget awareness.** Detect 403/429 in run_gh, back off exponentially instead of hammering every 30s (secondary-rate-limit risk), surface remaining budget in status. — src/github.rs:27-72, src/main.rs:332. Effort: **M**.

12. **Hygiene batch:** commit-or-delete the out-of-repo `~/.local/bin/ezgha-fleet-watchdog.sh` (currently broken on ssh timeouts, misleading header, unversioned); extend the flock to `ezgha start/stop` slot mutations (main.rs:283-296, :335-339); document/decide the disk-floor no-reclamation stance and add an alert to it. Effort: **S each**.

---

## 3. Prioritized Roadmap

**Phase 1 — Stop the bleeding (all S, ~1–2 days total)**
1. In-cycle watchdog pings + WatchdogSec=180 in source (`src/service.rs`, `src/main.rs`) — fixes the live kill loop. **S**
2. release_slot on jitconfig failure + corrupt-slot-file quarantine-and-reset. **S**
3. Timeout wrapper on all docker `Command::output()` calls (reuse the github.rs pattern). **S**
4. Regression test for the no-wipe-on-list_runners-Err guard (needs an injection seam) — the doc's own "single most important regression test". **S**

**Phase 2 — Real self-healing + eyes (M, ~1 week)**
5. Colima/Lima VM restart attempt on backend failure, with cooldown + attempt cap. **S–M**
6. Consecutive-failure counter → degraded sd_notify STATUS → exit-after-N so systemd restart machinery engages. **S–M**
7. Alerting module (Slack webhook first, email second) wired to: sustained ensure_count failure, disk floor, VM restart, start-limit risk. This takes Goal 5 from 0 to functional. **M**
8. Zombie-runner reaper: offline-owned-runner ≥ threshold → docker rm -f + slot release. **M**

**Phase 3 — Harness honesty (M, ~3–4 days)**
9. verify-exit-criteria.sh: implement Gate 6, make Gate 7 assert something, fix Gate 3's empty-input arithmetic crash + missing `--slurp` + INFRA-FLAKE/FLEET-FAIL labeling; stop printing "ALL AUTO GATES PASS" while skipping gates. **M**
10. Commit or delete the external fleet-watchdog script + units; if kept, install via `install-service` and fix its false "serve does not top-up" header. **S**

**Phase 4 — Goals 4 + remaining throughput (M–L, ~1–2 weeks)**
11. Max-job-duration config key + enforcement (cancel run via GitHub API, then reclaim container/slot) — first actual Goal 4 code. **M–L**
12. Queue-depth vs capacity monitor with alert on sustained starvation. **M**
13. 403/429 detection + exponential backoff in run_gh; adaptive loop interval under rate pressure. **M**
14. Flock all slot-file mutators (manual start/stop vs daemon race). **S**

**Sequencing rationale:** Phase 1 items are all confirmed-active or one-bad-day-away failures with existing in-repo patterns to copy. Alerting (Phase 2) deliberately precedes trimming (Phase 4) because every other gap's blast radius is currently unbounded by silence — the system's dominant meta-failure is that it fails quietly while every health signal reads green.

## Dimension summaries (reviewer verdicts)

### crash-hardening

The daemon is genuinely hardened against the incident classes it has already lived through: gh calls are timeout-bounded (45s), platform probes are bounded (4s), slot-file writes are atomic, config is fail-closed validated, the GitHub-unreachable no-wipe guard exists, and the serve loop logs-and-retries instead of aborting. The remaining crash/hang/wedge surface is concentrated in three places: docker CLI calls have no timeouts at all (permanent hang on macOS launchd, watchdog-kill churn on Linux), the systemd watchdog budget (60s in code, hand-patched to 180s only in the live unit) is smaller than a single worst-case ensure_count iteration with count=16, and a corrupt slot file wedges spawning with only a documented manual fix. Separately, Gate 6 exists only on paper — verify-exit-criteria.sh has no resilience gate and the doc's "single most important regression test" (list_runners Err → no slot-file mutation) is not in the test suite, so the hardest-won hardening property is unverified.

### self-healing

The daemon has genuinely strong self-healing for the container/registration/slot state classes: docker rm -f before every spawn (the only spawn path, so the c6defc7 failsafe is complete), guarded 409 name-conflict reclaim, per-tick fail-closed slot reconciliation with forward orphan sweep, systemd Restart+Watchdog, boot-race retry, and a solid flock single-instance guard. However, three of the four CLAUDE.md "self-healing recipes" remain human-only — Colima VM restart (critical: nothing anywhere restarts the VM and lima-vm@colima has Restart=no), corrupt slot-file removal, and effectively the service-restart recipe for fast-crash modes that exhaust StartLimitBurst — and disk-floor breaches halt the fleet with no reclamation. The common thread is that every sustained failure collapses into an eprintln retry loop that still pets the watchdog, with zero alerting, so the system reliably survives bad states (goal 1) but frequently cannot exit them without a human (goal 2 partially met).

### throughput

Goal 3's mechanics for the failure modes already lived through (slot wedging, API-blip slot-file wipe, name conflicts, disk floor) are genuinely solid — fail-safe reconciliation in release_stale_slots and the 2-strike disk guard are well reasoned. But throughput health is measured almost entirely by local docker-container count: there is no detection of a container that is up while its GitHub runner is offline/dead (silent zero-throughput passes every automatic check), no queue-depth-vs-capacity measurement anywhere (queued jobs can starve invisibly on label mismatch or zombie fleets), no daemon-side API-budget awareness or backoff, and the fail-closed disk clamps can legitimately hold capacity at zero indefinitely with only journald warnings. The gate suite that is supposed to catch this omits Gates 5/6, rubber-stamps Gate 7, and the only automatic shortfall watchdog is uncommitted, count-blind, restart-only infrastructure outside the repo.

### job-trimming

Goal 4 (trim/cancel long-running workflow runs and jobs) is entirely absent from the repository: no cancellation API calls (the word 'cancel' appears in zero files), no container max-lifetime enforcement (docker 'RunningFor' is parsed but display-only in ezgha status), no timeout/duration config keys in config.rs, and no mention in EXIT-CRITERIA.md gates 0-10, DESIGN.md (including its Known Limitations list), doctor.sh, or verify-exit-criteria.sh. The closest existing mechanism is ephemeral JIT runner turnover plus zombie/orphan reclaim, but turnover only occurs after a job finishes and every reclaim path explicitly skips busy runners (docker_backend.rs:189, :446; github.rs:223), so a hung job holds its slot indefinitely — meaning this gap also silently erodes Goal 3 throughput.

### alerting

Goal 5 (Slack/email alerting) is entirely unimplemented: the repo contains no notification code, no alerting config schema, and no delivery channel — every 'slack'/'notify' hit is either systemd sd_notify watchdog plumbing or a token-scrubbing unset list. Worse, the Gate 7 'Monitoring exists' check in verify-exit-criteria.sh passes unconditionally (it greps timers into variables it never inspects), so the exit-criteria harness green-lights the exact silent-3am-decay failure mode the gate was written to prevent. The live out-of-repo ezgha-watchdog.timer self-heals by restarting the supervisor but pages no one; if self-healing fails, the only trail is journalctl and /tmp/ezgha-watchdog.log, and the user learns of the outage from queued jobs.

### spec-gap

Spec-vs-implementation drift is concentrated in the verification and operations layers, not the core runner lifecycle: the Rust daemon has genuinely absorbed most prior findings (no-wipe reconcile, aggregate capacity clamp, pagination, disk strike counter, ownership-scoped reclaim), but two of the user's five goals — trimming (goal 4) and alerting (goal 5) — have zero implementation and, for trimming, zero design anywhere in the docs. The exit-criteria harness itself has regressed into the failure mode it was built to prevent: verify-exit-criteria.sh omits Gates 5/6/8, passes Gate 7 vacuously, and weakens Gates 3/4/10, while README claims it machine-checks 'Gates 0–10'; meanwhile fleet top-up in production depends on an uncommitted ~/.local/bin watchdog that the repo does not know exists.

### live-evidence

Live evidence contradicts a green picture: the fleet is up right now (15-16/16 containers, 21/21 org runners online and busy, GitHub rate limit healthy, 0 panics in 14 days), but today alone the daemon crash-looped for 4 hours (1,380+ exits on 'no usable backend found' while Colima was down) and was watchdog-killed 10 times between 17:59 and 20:09, the last kill minutes before this review — 1,562 service starts in 14 days. Both machine-checkable health gates fail as of this run (verify-exit-criteria Gate 0 FAIL with a binary that embeds no SHA at all, doctor verdict [BAD] with 2 criticals), and goals 4 (trimming) and 5 (alerting) have zero implementation — the 4-hour outage generated no notification of any kind.
