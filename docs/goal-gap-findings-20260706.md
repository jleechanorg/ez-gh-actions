# Goal-Gap Review 2026-07-06 — Full Findings (evidence level)

Every finding below survived an independent adversarial skeptic instructed to refute it.
CONFIRMED = evidence checked out and no existing mechanism covers it.
PARTIAL = directionally right; the skeptic's corrected claim is recorded and should be treated as the accurate version.

## Confirmed findings (33)

### C1. [CRITICAL] (alerting) Goal 5 is unimplemented: zero Slack/email/webhook notification code exists anywhere in the repo

**Evidence:** rg -i 'slack|email|webhook|notify|alert|smtp|sendmail' across src/, *.sh, docs/ yields only: src/main.rs:316-331 (sd_notify systemd watchdog pings), src/service.rs:45-52 (Type=notify unit lines), src/service.rs:93,192-193 (SLACK_APP_TOKEN in an env-UNSET scrub list), docs/EXIT-CRITERIA.md:141-147 (the requirement text itself), DESIGN.md:355 (alerting deferred to milestone M3). src/config.rs:15-20 Config struct has only github/runner/limits/policy sections — no alerting/notification schema at all. doctor.sh contains no alert keywords.

### C2. [CRITICAL] (alerting) Gate 7 (Monitoring exists) in verify-exit-criteria.sh is a rubber stamp — it passes unconditionally without checking any monitor

**Evidence:** docs/verify-exit-criteria.sh:197-205 — MONITOR_TASKS=$(systemctl --user list-timers ... | grep -i ezgha || true) and CRON_SCHED=... are assigned but NEVER tested; the only conditional is 'if ! gh api rate_limit' (an API reachability check), then 'pass "Gate 7: Automated monitoring scheduled and active"' fires unconditionally. Compare docs/EXIT-CRITERIA.md:141-147, which requires a scheduled doctor run that 'on FLEET-FAIL, emits an alert to a durable channel'.

### C3. [CRITICAL] (alerting) 3am scenario: a silently dead fleet produces only journal and /tmp log entries — nothing reaches the user before they notice queued jobs

**Evidence:** Complete delivery-path audit: src/main.rs serve loop errors go to eprintln (main.rs:326 'ensure_count failed (will retry)') -> journal; systemd WatchdogSec restarts the unit (service.rs:45-52) but notifies no one; ezgha-watchdog.timer failures append to /tmp/ezgha-watchdog.log; doctor.sh and Commands::Doctor (src/main.rs:236-260) are on-demand terminal printouts with no scheduler in the repo and no alert emission; no crontab entry references ezgha (crontab -l).

### C4. [CRITICAL] (live-evidence) Service is being killed by its own systemd watchdog repeatedly — 10 watchdog timeouts today, the last one 30 minutes before this review

**Evidence:** journalctl: 'Watchdog timeout (limit 1min)!' at 17:59:11, 18:00:42, 19:44:35, 19:46:06, 19:47:38, 19:49:09, 19:59:22, 20:01:52; 'Watchdog timeout (limit 3min)!' at 20:05:54 and 20:09:26. systemctl status: 'Scheduled restart job, restart counter is at 2', Active since 20:09:57 (2s ago at check time). WatchdogUSec=3min.

### C5. [CRITICAL] (live-evidence) ALERTING (goal 5) is not implemented at all — a 4-hour total outage produced zero Slack/email notifications

**Evidence:** rg for slack|webhook|smtp|sendmail|email in src/*.rs matches only env-var passthrough names in service.rs:93,192-193 (SLACK_APP_TOKEN forwarded to runner containers, not used for alerting). journalctl 14 days: 0 lines matching 'slack|alert sent|notified'. DESIGN.md:355 lists alerting only as future milestone 'M3: health/queue-depth monitoring + alerting hooks'.

### C6. [CRITICAL] (self-healing) Colima/Lima VM death mid-run is never recovered by anything — daemon error-loops passively forever

**Evidence:** src/main.rs:320-333 (serve loop only eprintln-retries); src/docker_backend.rs:398-410 (managed_containers bails when docker ps fails); no `colima start`/`limactl start` invocation anywhere in src/ (rg confirmed); live host: `systemctl show lima-vm@colima.service -p Restart` → Restart=no on both user and system units; doctor.sh:144 and CLAUDE.md prescribe manual `colima start`/`limactl start colima`

### C7. [CRITICAL] (spec-gap) Goal 4 (TRIMMING) has zero design and zero implementation — no code detects or cancels long-running workflow runs

**Evidence:** grep -iE 'cancel|trim|too.?long|max_duration' src/*.rs returns only unrelated string-trim and probe-timeout hits (platform.rs:11, github.rs:18). DESIGN.md Milestones (lines 350-357) list M1-M4 and none mentions run/job duration monitoring or cancellation. doctor.sh and verify-exit-criteria.sh have no duration checks either.

### C8. [CRITICAL] (spec-gap) Goal 5 (ALERTING) is entirely absent: milestone M3 is deferred and no Slack/email/notification path exists anywhere

**Evidence:** DESIGN.md:355-356 defers 'M3: health/queue-depth monitoring + alerting hooks' to a future milestone. grep -iE 'slack|alert|notify|email|webhook' across src/, doctor.sh, verify-exit-criteria.sh finds only sd_notify systemd plumbing (src/main.rs:316-331) and an env-var *strip* list containing SLACK_APP_TOKEN (src/service.rs:93,192). The live watchdog ~/.local/bin/ezgha-fleet-watchdog.sh only restarts the service and appends to /tmp/ezgha-watchdog.log — no alert channel.

### C9. [CRITICAL] (spec-gap) verify-exit-criteria.sh silently omits Gates 5, 6, and 8, fakes Gate 7, and weakens Gates 3/4/10 — while README/CLAUDE.md claim it checks 'Gates 0–10'

**Evidence:** Script (docs/verify-exit-criteria.sh) has no Gate 5, 6, or 8 sections at all. Gate 7 block (lines 197-205) computes MONITOR_TASKS and CRON_SCHED then never tests them — it passes whenever `gh api rate_limit` succeeds, so 'Automated monitoring scheduled and active' is asserted unconditionally. Gate 4: doc (EXIT-CRITERIA.md:83-94) requires a nonce-tracked fresh canary via `doctor.sh --prove`; script lines 176-195 only check the LAST 5 selftest runs, never dispatching one. Gate 3: doc requires the anti-gaming rule (lines 30-37, snapshot slot file across GitHub-unreachable cycles) — absent; script line 140 only enforces capacity when BUSY_COUNT=0. Gate 10: doc requires 'no 403/429 in journal in last 30 min' + poll-budget math (lines 157-159) — script lines 208-215 check only core remaining ≥20%. README.md:405 and 412 claim the script covers 'Gates 0–10' / '7 ironclad gates' including Gate 7 monitoring; CLAUDE.md repeats 'Gates 0–10'.

### C10. [CRITICAL] (throughput) Zombie runner blind spot: a container that is up but whose GitHub runner is offline/dead permanently occupies capacity with no detection or replacement

**Evidence:** src/docker_backend.rs:503-505 — `let alive = managed_containers()?.len() as u32; if alive >= cfg.runner.count { return Ok(Vec::new()); }`; src/docker_backend.rs:218-242 — release_stale_slots_from only checks `!live_ids.contains(&rid)` (runner id existence), never `status == offline`; src/docker_backend.rs:185-199 — orphan sweep reaps only runners NOT in owned_ids; ~/.local/bin/ezgha-fleet-watchdog.sh check_linux — compares only `managed containers: N` vs configured count

### C11. [CRITICAL] (throughput) No queued-job starvation detection anywhere — GitHub queue depth is never measured by daemon, doctor, watchdog, or gates

**Evidence:** `rg -in 'queued' src/ docs/verify-exit-criteria.sh doctor.sh` returns zero matches; src/main.rs:320-333 serve loop only calls ensure_count; docs/EXIT-CRITERIA.md Gates 3-5 measure runner counts and canary success, never queue depth

### C12. [MAJOR] (alerting) The live ezgha watchdog only self-heals and logs to /tmp — it never notifies a human, and it is not committed to the repo

**Evidence:** ~/.config/systemd/user/ezgha-watchdog.timer (OnUnitActiveSec=120s) runs ~/.local/bin/ezgha-fleet-watchdog.sh --host linux with StandardOutput/StandardError=append:/tmp/ezgha-watchdog.log. rg -i 'slack|mail|curl|webhook|notify|ntfy|alert' on ezgha-fleet-watchdog.sh returns zero hits — on failure it restarts the supervisor and writes a log line. git ls-files | rg -i 'watchdog|monitor|timer|cron|health' returns nothing: neither the script nor the units are in the repo.

### C13. [MAJOR] (crash-hardening) All docker CLI invocations on the serve hot path have no timeout — a wedged Docker daemon hangs the loop (permanent on macOS launchd)

**Evidence:** src/docker_backend.rs:274-278 (daemon_capacity), :327-329 (docker rm in start_one), :369 (docker run), :399-408 (managed_containers), :426 (stop_all), :473-477 (free_disk_gb) — all use Command::output() with no deadline. Contrast: gh calls get GH_TIMEOUT=45s (src/github.rs:18-72) and platform probes get 4s (src/platform.rs:11-45).

### C14. [MAJOR] (crash-hardening) A single ensure_count iteration can exceed WatchdogSec — systemd SIGABRTs the daemon mid-spawn under slow GitHub or a cold 16-runner fleet

**Evidence:** src/main.rs:320-332 — sd_notify Watchdog ping fires ONCE per loop, only after ensure_count returns; comment claims '30s loop cadence is well inside WatchdogSec=60'. src/github.rs:18 GH_TIMEOUT=45s per gh call. src/docker_backend.rs:493-554: one cycle = list_runners (45s) + up to N remove_runner (45s each) + per-runner start_one, each with jitconfig up to 45s plus the 409-heal chain (list 45s + remove 45s + retry 45s ≈ 180s, github.rs:134-179). Live config: runner.count = 16.

### C15. [MAJOR] (crash-hardening) Installed unit drift: live ezgha.service has WatchdogSec=180 (hand-tuned) but service.rs writes WatchdogSec=60 — any reinstall silently regresses the mitigation

**Evidence:** src/service.rs:51 writes "WatchdogSec=60"; `systemctl --user cat ezgha.service` on this host shows WatchdogSec=180. All other lines match, proving the installed unit was manually edited after install.

### C16. [MAJOR] (crash-hardening) Corrupt slot_assignments.toml wedges runner spawning permanently — no self-heal path, recovery is a documented manual rm

**Evidence:** src/docker_backend.rs:59-72 read_slot_assignments returns Err on TOML syntax corruption; next_slot (:97-115), start_one (:337), release_stale_slots (:161) all propagate it; ensure_count (:499) discards the reconcile error with `let _ =` and then fails at start_one every 30s tick forever. CLAUDE.md 'Common self-healing recipes' prescribes the manual fix: `rm ~/.config/ezgha/slot_assignments.toml`.

### C17. [MAJOR] (crash-hardening) Gate 6 (resilience) is not implemented: verify-exit-criteria.sh skips it entirely, and the 'single most important regression test' does not exist in the suite

**Evidence:** grep of docs/verify-exit-criteria.sh shows gates 0,1,2,3,4,7,10 only — the script jumps from Gate 4 (line 175) to Gate 7 (line 197); no Gate 5/6/8/9 checks despite the final banner 'ALL AUTO GATES PASS EXCELLENTLY!'. Test suite: docker_backend.rs tests (:775, :796, :816, :834) exercise only release_stale_slots_from() with a caller-supplied live list; no test injects a list_runners Err to prove release_stale_slots (:154-160) returns Ok(0) without mutating the slot file — the exact test EXIT-CRITERIA.md:127-129 calls 'the single most important regression test'.

### C18. [MAJOR] (job-trimming) Config schema has no timeout/max-duration keys of any kind

**Evidence:** src/config.rs:15-81 — full schema is Config{version, github, runner, limits, policy}; Limits (config.rs:62-69) contains only memory_mb, cpus, pids, min_free_disk_gb. RunnerConfig (config.rs:41-53) has labels, count, image, name_prefix. No key resembling job_timeout, max_job_duration, max_container_lifetime, or run_max_minutes exists. The only 'timeout' constants in src are process-exec bounds: GH_TIMEOUT=45s for gh CLI (github.rs:18), PROBE_TIMEOUT=4s (platform.rs:11), wait_for_backend 120s (main.rs:125), systemd TimeoutStartSec=130 (service.rs:55) — none bound job or run duration.

### C19. [MAJOR] (job-trimming) EXIT-CRITERIA.md, DESIGN.md, doctor.sh, and verify-exit-criteria.sh contain zero coverage of trimming — the gap is invisible to the verification suite

**Evidence:** rg -in 'cancel|trim|too long|max.?duration|max.?lifetime' over docs/EXIT-CRITERIA.md, DESIGN.md, README.md, doctor.sh, docs/verify-exit-criteria.sh returns no output. EXIT-CRITERIA.md gates are: 0 deploy parity, 1 code quality, 2 service up, 3 fleet capacity, 4 real job execution, 5 sustained health, 6 resilience, 7 monitoring, 8 security, 9 docs truth, 10 API budget — no gate mentions run duration or cancellation. DESIGN.md's 'Known limitations (v1)' list (DESIGN.md:359-390) enumerates 10 deferred items and trimming is not among them.

### C20. [MAJOR] (live-evidence) TRIMMING (goal 4) is not implemented — no code anywhere detects or cancels long-running workflow runs/jobs

**Evidence:** rg -ril 'gh run cancel|cancel-workflow|max_run_minutes|max_job_minutes' across the whole repo (excluding target/): zero matches. rg 'cancel|trim' in src/*.rs matches only string .trim() calls (config.rs:171, docker_backend.rs:66, etc.). ~/.config/ezgha/config.toml has no run/job duration limits.

### C21. [MAJOR] (self-healing) Corrupt slot_assignments.toml (whole-file TOML parse failure) wedges the daemon in a silent permanent error loop; the 'rm slot file' recipe is not automated

**Evidence:** src/docker_backend.rs:69-71 (parse error propagates as Err); docker_backend.rs:499 (`let _ = release_stale_slots(cfg)` swallows it), docker_backend.rs:101→323 (next_slot → start_one fails every spawn); main.rs:327-331 (error printed, watchdog still pinged). Contrast: per-key tolerance exists at docker_backend.rs:224-227, but not file-level.

### C22. [MAJOR] (self-healing) Fast-crash scenarios (corrupt config.toml, policy-blocked) exhaust StartLimitBurst and leave the service permanently dead with no alert

**Evidence:** src/main.rs:298 (`Config::load(&path)?` fails in seconds), src/main.rs:144-151 (PolicyBlocked bails immediately, explicitly not retried); src/service.rs:41-42 + live unit: StartLimitIntervalSec=300, StartLimitBurst=5, RestartSec=30 — 5 failures land within ~150s < 300s window → start-limit-hit

### C23. [MAJOR] (self-healing) Watchdog is liveness-only and there is no degraded-state signal: a permanently failing ensure_count loop looks healthy to systemd forever

**Evidence:** src/main.rs:320-332: watchdog ping `sd_notify(..., Watchdog)` is sent unconditionally after the match, including on the `Err(e)` arm; no failure counter, no escalation, no exit-after-N-consecutive-failures

### C24. [MAJOR] (spec-gap) Gate 6's mandated resilience regression tests do not exist in the test suite

**Evidence:** EXIT-CRITERIA.md:127-129 demands 'a test where list_runners returns Err must show release_stale_slots returns Ok(0) and does NOT modify the slot file... the single most important regression test'. src/docker_backend.rs tests (lines 775-844) only exercise release_stale_slots_from() with caller-supplied lists — the Err branch of the production entry point (docker_backend.rs:154-160) is untested because list_runners is not injectable. No atomic-write crash-simulation test exists (grep 'fn.*atomic' in tests: none; the atomic write itself is at docker_backend.rs:80-88). Restart-recovery live check and slot-file non-numeric-key corruption test are likewise absent; only the disk strike-counter tests (lines 844-865) cover Gate 6's disk-floor item.

### C25. [MAJOR] (spec-gap) Four DESIGN.md 'Known limitations' that directly contradict goals 1-3 remain open in code: no crash-loop backoff, stop-vs-service race, docker CLI <23 breakage, non-target-scoped managed label

**Evidence:** (a) Backoff: DESIGN.md:365-369 promises 'exponential backoff on repeated immediate exits'; grep -i backoff src/ finds nothing — the reconcile half landed (forward orphan sweep, docker_backend.rs:163-205) but a crash-looping container still gets a fresh JIT config every 30s cycle. (b) `ezgha stop` (main.rs:335-339) only calls stop_all — never `systemctl --user stop`, so the installed service respawns runners within 30s (DESIGN.md:371-373). (c) managed_containers (docker_backend.rs:399-406) still uses `--format json`, which prints a literal template on Docker CLI <23 / Ubuntu 22.04 (DESIGN.md:374-376). (d) MANAGED_LABEL is the constant 'ezgha=managed' (docker_backend.rs:15) — not target-scoped, so two configs on one daemon miscount each other's capacity (DESIGN.md:377-379).

### C26. [MAJOR] (throughput) Disk-floor bail and disk-measurement strike-out drive capacity to zero indefinitely with no recovery pressure and no alert

**Evidence:** src/docker_backend.rs:507-533 — `Some(free) if free < cfg.limits.min_free_disk_gb => bail!(...refusing to spawn...)` and `None => { if n >= DISK_MEASURE_STRIKES { bail!("could not measure daemon free disk for {n} cycles...") } }`; src/main.rs:327 — serve catches with `eprintln!("ensure_count failed (will retry)")` and sleeps 30s; no `docker system prune`, no host-df fallback, no alert path exists in src/

### C27. [MAJOR] (throughput) verify-exit-criteria.sh omits Gate 5 and Gate 6 entirely, and Gate 7 passes unconditionally — the monitoring and sustained-health gates cannot fail

**Evidence:** docs/verify-exit-criteria.sh contains only Gates 0,1,2,3,4,7,10; lines 197-205: `MONITOR_TASKS=$(systemctl --user list-timers --all | grep -i ezgha || true)` and `CRON_SCHED=...` are computed but never tested — the gate only fails if `gh api rate_limit` errors, then prints 'PASS Gate 7: Automated monitoring scheduled and active'

### C28. [MINOR] (alerting) The only script on the machine that 'sends an alert' just echoes to stderr, and it monitors the legacy runner stack, not ezgha

**Evidence:** ~/.local/bin/jleechanorg-runner-health.sh:52-71 — the rate-limited 'Send alert' block is a bash heredoc echoed to >&2 (journal only, no Slack/email/curl); line 22 shows COMPOSE_DIR=/home/jleechan/projects/worktree_runner/self-hosted-colima and it iterates org-runner-1..16 compose containers, i.e., the pre-ezgha legacy fleet. The old crontab monitor entries for that stack are all commented out (crontab -l shows '# */15 ... monitor.sh').

### C29. [MINOR] (crash-hardening) Slot file read-modify-write is unlocked against manual `ezgha start`/`stop` — a concurrent start can docker-rm-force a live runner mid-job

**Evidence:** src/main.rs:303 — serve.lock is acquired only in Commands::Serve; Commands::Start (:283-296) and Commands::Stop (:335-339) mutate slot_assignments.toml with no lock. src/docker_backend.rs:97-115 next_slot is a plain read-modify-write; :327-329 start_one runs `docker rm -f <name>` as a failsafe before docker run.

### C30. [MINOR] (crash-hardening) start_one leaks its slot reservation on JIT failure; while GitHub is down, reservations accumulate until 'all slots in use' masks the real error

**Evidence:** src/docker_backend.rs:342-349 — on generate_jitconfig Err, start_one returns without release_slot, violating next_slot's documented contract (:93-96 'callers MUST ... release it via release_slot if the registration fails'). Cleanup is delegated to release_stale_slots (:546), but that reconcile is skipped whenever list_runners fails (:154-160) — i.e. precisely during the outage that made jitconfig fail.

### C31. [MINOR] (self-healing) macOS/launchd deployment has no hang protection: unbounded docker `.output()` calls plus KeepAlive-only supervision

**Evidence:** src/docker_backend.rs:369,399-408,426,472-477,274-278 — all docker invocations use bare `Command::output()` with no timeout (contrast github.rs run_gh 45s timeout, platform.rs capture_with_timeout 4s); src/service.rs:126-144 launchd plist has only KeepAlive, no watchdog equivalent

### C32. [MINOR] (self-healing) Installed systemd unit has drifted from source (WatchdogSec=180 on disk vs 60 in code) — next install-service silently reverts operator tuning

**Evidence:** src/service.rs:51 writes "WatchdogSec=60"; live ~/.config/systemd/user/ezgha.service contains WatchdogSec=180 (verified via cat + `systemctl --user show` WatchdogUSec=3min)

### C33. [MINOR] (spec-gap) Three minor gaps from the prior adversarial-review gap report remain open: hardcoded runner_group_id=1, unpinned :latest default image, init silently overwrites config

**Evidence:** M6: `runner_group_id=1` still hardcoded at src/github.rs:130 and 166. M7: default image still `ghcr.io/actions/actions-runner:latest` at src/config.rs:113. M8: `Commands::Init` calls `cfg.save(&path)?` unconditionally at src/main.rs:221 with no existing-file check. For calibration, the report's substantive findings are FIXED: M1 disk-guard fail-open (strike counter, docker_backend.rs:844-865, commit afa8de5), M2 aggregate capacity (effective_limits_aggregate_fits_daemon test + init clamp main.rs:198-220, commit 077d07c), M3 hostname collision (replaced by slot-ownership + liveness model, github.rs:214-230), M4 pagination (--paginate --slurp, github.rs:92-95, tests at 489-528), M5 service PATH (Environment=PATH/HOME in unit, service.rs:56-58; launchd wrapper).


## Partial findings (12) — corrected claims

### P1. [CRITICAL] (job-trimming) No workflow-run or job cancellation exists anywhere in the repo — Goal 4 is 0% implemented

**Corrected claim:** No workflow-run or job cancellation exists anywhere in the repo — zero matches for 'cancel'. src/github.rs only calls generate-jitconfig, runner listing, and runner deregistration; there is no POST .../actions/runs/{id}/cancel and no 'gh run cancel'. The health-check scripts (doctor.sh:262,298; docs/verify-exit-criteria.sh:178,189) do have READ-ONLY workflow-run/job visibility via `gh run list` and `gh api .../actions/runs/{id}/jobs`, but only to prove routing after the fact — neither they nor the daemon measure job durations, detect hung runs, or trim anything. The daemon itself has zero run/job visibility (the runner `busy` flag is used only to guard slot reclamation). A hung workflow run wedges an ephemeral runner slot until GitHub's own ceiling or human intervention. Goal 4 (TRIMMING) is 0% implemented on the enforcement side; the claim's "complete absence of visibility" is overstated only with respect to the read-only script-side run listing.

### P2. [CRITICAL] (job-trimming) No container max-lifetime kill — container age is parsed but used only for display

**Corrected claim:** The daemon has no local container max-lifetime enforcement: RunningFor is parsed (docker_backend.rs:394-395) but only displayed (main.rs:345), and no age-threshold kill exists. However, recovery is not absent — it is delegated to external mechanisms: GitHub's job timeout (default 6 h, operator-extendable) kills hung jobs, after which the ephemeral --rm container exits and the 30 s serve loop replaces it; offline wedged runners are auto-removed by GitHub after ~1 day, unblocking release_stale_slots and start_one's docker rm -f name-reuse failsafe. The real gap (severity: medium) is that a runner GitHub reports as busy is locally untouchable for the duration of its job timeout, temporarily reducing fleet capacity by one slot per hung job with no locally-configurable ceiling.

### P3. [CRITICAL] (live-evidence) 4-hour full-fleet outage today: daemon crash-looped 1,380+ times on 'no usable backend found' instead of surviving Docker/Colima down

**Corrected claim:** On Jul 06 09:03–12:59 PDT a host reboot left the Colima VM down and the then-installed pre-fix ezgha binary exited status 1 on startup 1,380 times (~10s systemd restart loop), leaving the fleet dark ~4h until Colima was started externally — a real hardening-goal violation at the time. However, remediation landed and was deployed the same day (13:04–15:14): wait_for_backend 120s startup retry, Wants=/After=lima-vm@colima.service so systemd starts Colima at boot (with a patched Type=forking lima unit that waits for VM readiness), Type=notify watchdog, and StartLimitBurst crash-storm capping. Residual (medium, not critical) gap: if Docker/Colima stays down longer than 120s mid-session, the daemon still exits and cycles every ~150s (the 5-failures-in-300s StartLimitBurst never trips at that cadence) instead of entering an indefinite degraded/retry mode, and the daemon itself never runs limactl start colima — runtime Colima recovery is still external.

### P4. [MAJOR] (live-evidence) Gate 0 FAIL: installed binary reports '0.1.0-unknown' — SHA embedding broken and binary stale vs HEAD; verify-exit-criteria.sh fail-fasts so Gates 1-10 went unverified

**Corrected claim:** Gate 0 currently FAILs: ~/.cargo/bin/ezgha reports '0.1.0-unknown' vs HEAD 2186aba, and because verify-exit-criteria.sh fail-fasts, Gates 1-10 went unverified. However, the SHA-embedding mechanism (build.rs) is NOT broken — in-repo builds embed real SHAs, and a fresh `cargo install --path .` embeds 2186aba, which would make Gate 0 pass. The installed binary was actually rebuilt AFTER the latest commit (mtime 20:02 vs commit 19:36) but in an environment where `git rev-parse` failed, triggering build.rs's 'unknown' fallback. Fix is a standard `cargo install --path .` from the repo (with git working) plus service restart; HEAD's only change since 51a5b35 is Dockerfile.runner, so the running Rust code is not functionally stale. PID 94757 cited in the claim is stale (daemon since restarted as PID 151892). Severity: moderate — verification is currently blind past Gate 0, but the root cause is a one-command remediation, not a broken embedding system.

### P5. [MAJOR] (live-evidence) doctor.sh verdict [BAD] — 2 critical checks failed: real-job-execution proof is 0/6 on the current fleet, and container count dipped below configured 16

**Corrected claim:** doctor.sh verdict [BAD] with 1 persistent critical: the REAL_ON_FLEET gate fails 0/6 because the last 6 ezgha-selftest runs all executed on ez-org-runner-* names, and a fresh selftest dispatched today (run 28819819695, after the 2026-07-05 prefix change) still landed on ez-org-runner-1 — a runner not registered in the org and with no container on this host — so [self-hosted, ezgha]-labeled jobs are being taken by a foreign/legacy host and the current ez-runner-b fleet has zero real-job proof (not merely stale proof). The second cited critical (container count 15<16, doctor.sh:322) is a transient churn snapshot that flips within a minute and should be reported as churn-sensitivity of the gate, not a standing failure. Confirmed minor bugs: doctor.sh:269 hardcodes '(NOT an ez-org-runner)' instead of $RUNNER_NAME_PREFIX, and the --prove canary at doctor.sh:301/:305 still hardcodes ez-org-runner-*, so it can never pass on the current fleet.

### P6. [MAJOR] (self-healing) Disk-floor breach halts spawning permanently with no automated reclamation — `docker system prune` is only an error-message suggestion

**Corrected claim:** During a disk-floor breach, ensure_count bails every 30s cycle (src/docker_backend.rs:507-514) and the serve loop retries (src/main.rs:327), so spawning auto-resumes if disk recovers — but the daemon performs no reclamation of its own (no image/build-cache prune anywhere in src/; `docker system prune` appears only in the error string) and emits no alert beyond journal stderr. Because runners are ephemeral --rm containers, ezgha's own job debris self-frees, so a *sustained* breach implies image/cache/external pressure that drains the fleet to zero until disk is freed by something outside the daemon. This is a documented design limitation (DESIGN.md:384-385: "the floor guard bounds daemon-level damage instead"), and the manual doctor.sh//doctor path has no automated caller. Severity: moderate-to-major gap in self-healing/alerting for the repo's self-declared dominant incident class (DESIGN.md:194), not a permanent-halt defect.

### P7. [MAJOR] (spec-gap) Fleet capacity top-up depends on an uncommitted, out-of-repo watchdog script — violating Gate 7's committed-config rule and masking a serve-loop gap

**Corrected claim:** Gate 7 (docs/EXIT-CRITERIA.md:139-147) is unmet: no committed monitoring/alerting exists (git ls-files has no watchdog/monitor/alert files), the only fleet monitor is an ad-hoc uncommitted ~/.local/bin/ezgha-fleet-watchdog.sh + user systemd timer, and the Gate 7 check in docs/verify-exit-criteria.sh:197-205 is vacuous — it collects MONITOR_TASKS but never tests it, passing whenever `gh api rate_limit` succeeds. However, fleet capacity top-up does NOT depend on that script: `serve` calls ensure_count every 30s (src/main.rs:320-333) which starts the full shortfall alive..count (src/docker_backend.rs:536, present since the v1 initial commit), the watchdog log shows zero "BELOW TARGET" remediations ever, and the script is currently non-functional (ssh timeouts). The script's "serve does not top-up" header is a false premise; the real fix is committing/automating Gate 7 monitoring-with-alerting and making the verifier's Gate 7 check actually assert something. Severity: minor-to-moderate compliance/verifier gap, not a major throughput gap.

### P8. [MAJOR] (throughput) Gate 10 (API budget) exists only in the manually-run verify script; the daemon has zero rate-limit awareness, backoff, or 403/429 detection

**Corrected claim:** Gate 10 (API budget) exists only in the agent/manually-run verify script (docs/verify-exit-criteria.sh:209-215); the daemon has zero rate-limit awareness, backoff, or 403/429 detection (src/github.rs run_gh has only a 45s hang timeout; src/main.rs:332 fixed 30s loop). When core budget exhausts, ensure_count still attempts one generate-jitconfig POST per missing slot every 30s — each fails fast (the 409 list_runners+retry self-heal path only triggers on "Already exists" errors, NOT on rate-limit 403s, so no extra calls fire and rejected requests do not further deplete the primary budget). The real impact is that the ephemeral fleet drains as runners finish jobs and cannot be replaced until the window resets, plus the blind 30s retry hammering risks GitHub secondary-rate-limit/abuse triggers; the existing ezgha-fleet-watchdog only restarts the supervisor, which does not mitigate API exhaustion. Severity: major.

### P9. [MAJOR] (throughput) The fleet watchdog (the only automatic capacity-shortfall detector) is uncommitted infrastructure living outside the repo, and its GitHub-blind count check plus restart-only remediation are weak

**Corrected claim:** A redundant fleet-watchdog layer (~/.local/bin/ezgha-fleet-watchdog.sh + ezgha-watchdog.{service,timer}, enabled, every 120s) is live-enabled automation infrastructure living outside version control, with weak internals (fragile `^count = ` grep, ssh-to-self dependency, restart-only remediation, unmonitored /tmp/ezgha-watchdog.log, unmonitored exit-2 path) and a header that inaccurately claims serve does not top-up to N. This is a minor unversioned-infra/hygiene gap under the automation-completeness rule — not a major Goal 3 violation, because the committed daemon's ensure_count loop (src/main.rs:320-333, src/docker_backend.rs:493-554) is the primary automatic capacity-shortfall detector and tops the fleet up to N every 30s, backed by systemd WatchdogSec=60 restart of a hung daemon. Fix: either commit the script + units to the repo with an install path (or delete them as obsolete), and correct its misleading header.

### P10. [MINOR] (live-evidence) Persistent JIT name-conflict churn against stale offline-but-busy runners wasted start attempts for days

**Corrected claim:** On Jul 05 the daemon burned ~78 JIT start attempts in an ~11-minute window (plus 2 at 18:00) against stale ez-org-runner-* registrations reporting offline-but-busy, which the conflict policy refuses to delete as presumed sibling-host runners. This was resolved same-day by the per-host prefix change to ez-runner-b (a root-cause fix for cross-host name collisions, not a side-step), and commit 077d07c (merged Jul 06) added ownership-aware reclaim so same-host stale registrations now self-heal regardless of status. Residual minor gaps: cross-host offline+busy registrations remain non-reclaimable by design (self-heal by waiting for GitHub to purge them), and the per-install host-id commit 9b2210c that would guarantee prefix uniqueness is still unmerged (branch 1fu/fix-host-uuid), leaving prefix uniqueness dependent on manual config. No stale offline entries remain in the org listing today.

### P11. [MINOR] (spec-gap) README overclaims resilience framing: 'Self-healing conflict resolution' and gate table describe behavior stronger than the shipped checks

**Corrected claim:** README.md's gate table overstates two rows of verify-exit-criteria.sh semantics: (1) README.md:419 says Gate 3 checks 'online + busy ≥ N−1', but the script computes EFFECTIVE_CAPACITY as ONLINE_COUNT only and enforces the GitHub-side threshold only when BUSY_COUNT==0 (verify-exit-criteria.sh:140); under load Gate 3 falls back to local slot-file/container counting (lines 159-172). (2) README.md:421 says Gate 7 verifies 'Automated monitoring scheduled and active', but the script only checks that `gh api rate_limit` succeeds — MONITOR_TASKS/CRON_SCHED (lines 199-200) are computed and never used. However, the README's 'Self-healing conflict resolution' claim (README.md:320) is NOT an overclaim: it is implemented in src/github.rs:139-163 and 209 (409 self-heal with reclaimability check and pagination). Severity: minor (Gate 9 documentation accuracy).

### P12. [MINOR] (throughput) Gate 3 script misclassifies GitHub outage as fleet failure and has a multi-page arithmetic bug, violating EXIT-CRITERIA's INFRA-FLAKE rule

**Corrected claim:** Gate 3 of docs/verify-exit-criteria.sh violates EXIT-CRITERIA.md:25-37's failure-classification mandate: it performs no INFRA-FLAKE vs FLEET-FAIL labeling. On gh api failure, line 113 substitutes an empty runner list; the script then aborts with an unlabeled bash arithmetic error at line 117 (because line 115's `grep -c . || echo 0` emits "0\n0" on empty input), so a transient GitHub/network blip reads as a Gate 3 failure. Separately, once the org exceeds 100 runners, line 116/122 jq expressions without --slurp emit one number per page (the exact bug already fixed in src/github.rs:236); the resulting multi-line BUSY_COUNT makes both `-eq` tests at lines 140/146 silently evaluate false inside if-conditions (errexit suppressed), so the quiescent-fleet checks are skipped entirely and Gate 3 fails OPEN — a degraded quiescent fleet would pass. Severity minor is accurate: the org currently has 21 runners, so the pagination path is latent; the outage path is live.
