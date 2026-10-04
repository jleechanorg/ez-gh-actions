# Mac and Linux runner outage alerts implementation plan

> Execution is NOT authorized by this document. A future implementation session follows this plan task by task; do not auto-invoke implementation from `/sq`.

**Goal:** Deliver verified Slack and email outage/recovery alerts for this Mac (six slots) and jeff-ubuntu (ten), even when either host cannot run its notifier.

**Architecture:** Reuse local Docker process observation and native schedulers. A host-local bounded observer sends thresholded health to hosted Healthchecks, which owns per-host Slack and email transitions and missing-heartbeat detection. Keep recovery separate from monitoring.

**Tech stack:** Existing Rust alert module, Bash observation/install code, Python 3 standard library, launchd/systemd, hosted Healthchecks integrations.

**Specification:** [design](../specs/2026-09-13-runner-outage-alerts-design.md). Tracking: `br show ez-gh-actions-zmk`, `br show jleechan-vsd1`, `br show jleechan-79gu`, `br show jleechan-cklq`.

## Scope and execution preconditions

Work now is documentation and lean handoff only. No live test alert, account setup, commit or push is part of this alert-design workflow. The user separately authorized Mac runner restoration on 2026-09-13; its operational repairs are tracked separately and do not activate alerts. During later implementation use an isolated task worktree and preserve unrelated changes. Read AGENTS/CLAUDE and ponytail/root-cause instructions. Before activation resolve authorized hosted project, Slack destination, verified recipient email, per-host secure references, independent daily-test scheduler, and receipt-read permissions. If unavailable, complete fixtures/local checks and report activation blocked; do not substitute log delivery for remote delivery.

Source paths below exist unless explicitly marked NEW. Commands for future tests are acceptance interfaces to implement, not claims they exist or passed today. Prefix any future live mutation instructions in the operator runbook `OPERATOR-ONLY:`. The authoritative full harness dispatches live jobs; do not run it as a read-only check.

## Task 1 — Freeze configuration identity and observation contract

Files: modify `scripts/runner_dashboard_host_probe.sh`, reuse `scripts/launchd-service-docker-endpoint.sh`; extend `tests/runner_dashboard_host_probe_test.sh`; NEW `tests/runner_monitor_probe_test.sh`.

1. Add fixture tests for a Mac active plist using Application Support config while an XDG config differs; service DOCKER_HOST differs from interactive Docker context; Linux ExecStart explicitly selects config; prefixes rotate; counts silently shrink; config parse fails. All fixture configs contain fake data and no secrets.
2. Add the versioned monitor JSON contract from the spec: host/config/endpoint identity, sequence/boot/freshness, required image, exact slot array and explicit UNKNOWN. Fixture Docker scripts record every invocation and reject run/create/remove/restart/prune and network API calls.
3. RED command: `bash tests/runner_monitor_probe_test.sh`; fail for absent `--monitor`, wrong endpoint, aggregate-only output, or container mutation. Assert timeout/hang returns unknown in <=25s, not a green empty fleet.
4. Implement a backward-compatible monitor mode that skips the existing disk-container sampling path and old 30-second down recheck; observer timing owns debounce. Factor/reuse helpers once. Resolve expected 6/10 independently from mutable runtime count and emit a config fault on mismatch. Preserve existing dashboard output mode.
5. GREEN: run the new test plus `bash tests/runner_dashboard_host_probe_test.sh`. Require current dashboard fixtures unchanged and every expected slot represented once. Prove fixture calls never launch a container.

## Task 2 — Expose daemon progress and fresh eligible-queue evidence

Files: inspect/modify `src/queue_monitor.rs`, `src/main.rs`, `src/config.rs`; Rust unit tests in owning modules; NEW `tests/fixtures/fleet_monitor/` sanitized samples.

1. Add an atomic daemon progress record after completed stages (boot ID, sequence, stage, last-progress time); no timer-only refresh. RED unit cases cover active PID with stalled stage, normal completed stage, malformed/future progress and boot change. Verify real stage deadlines fit the 120-second freshness bound before activation.
2. Trace the existing job-level queue correlation producer before adding anything. Its disabled/300s default and 240s alternate snapshot do not meet the <=120s freshness contract. Implement one dedicated producer worker thread started by the jeff-ubuntu daemon with its own 60s schedule and shutdown signal; it must not wait for serve-loop completion. In producer mode disable the old serve-loop fetch and make consumers read the cached snapshot. Allow one fetch in flight, 20s deadline and existing REST budget floor. Mac reads the atomic result via existing authorized SSH with a five-second deadline; no observer-side `gh api` polling. A missing SSH grant blocks that data path, not local capacity/missing-heartbeat alerts.
3. Define an explicit versioned snapshot: source timestamp, collection status, routing labels, eligible queued job evidence, and eligibility unknown when approvals/concurrency/routing cannot be established. Derive host label sets from service-owned runner config plus verified registration projection and store mapping/config digest. A Mac-hosted Docker runner is not automatically a macOS label target. A generic self-hosted job, a job eligible for both hosts without narrower correlation, or stale mapping is UNKNOWN for per-host starvation. Missing or stale >120s is UNKNOWN. Snapshot persistence must not leak workflow bodies, tokens or repo secrets.
4. RED: `cargo test queue_monitor` with cases for unrelated labels, blocked concurrency, pending approval, API rate limit, stale snapshot, partial API response, fresh empty eligible queue and proven same-label backlog. Assert ambiguous eligibility never becomes starvation.
5. Produce atomic snapshots from the bounded 60s producer without blocking reconciliation; use structured job facts, not title substring routing. Add schema validation and maximum file size at consumption. Keep the prior snapshot on failed collection with its old timestamp; never refresh freshness on failure.
6. GREEN: same tests plus `cargo test config`; prove repeated observer reads make zero extra GitHub requests and a failed collection becomes visibly stale.

## Task 3 — Implement thresholded host observer and durable state

Files: NEW `scripts/fleet_monitor.py`, NEW `scripts/tests/test_fleet_monitor.py`, NEW `config/fleet-monitor.toml.example`; replace internals of `scripts/ezgha-fleet-alert.sh` with a compatibility entrypoint after migration tests exist.

1. Expose a pure evaluation interface taking sample, queue snapshot, prior state and injected monotonic/wall clock. Result contains next state, reasons, incident generation and action `success|fail|withhold`. A test controls clock and boot ID; never sleep five real minutes for unit coverage.
2. RED command: `python3 -m unittest discover -s scripts/tests -p 'test_fleet_monitor.py' -v`. Cases: two consecutive 60s-spanning direct faults, first-miss recovery, one missing slot, zero fleet, missing image with active workers, five-minute starvation, five-minute queue unknown, healthy listeners with fresh empty queue, skipped tick, boot change, reversed clock, corrupt state, unknown during recovery, two-sample recovery, and a host that disappeared while locally healthy (provider may already be Down). First post-gap success is withheld until two good samples; an ordinary 60s one-shot restart does not reset persisted progress. Assertions check actions and reasons, not copied implementation expressions.
3. Implement 60s sampling contract with 25s probe budget, at most two parallel Docker probes, 3s individual timeouts and 45s process budget. Use a process-group-aware timeout so descendants do not outlive the invocation. On total timeout do not emit success.
4. Persist generation-scoped delivery intent BEFORE network send, fsync plus atomic rename; acknowledge only after semantic acceptance. Inject crashes before write, after write/before send, after send/before ack, and after a newer fault supersedes an old recovery. Replay only current intents under the same lock; never send stale recovery from a prior generation. Test duplicate same-state requests and retain provider receipts rather than assert exactly-once delivery.
5. Persist atomic state under `~/.local/state/ezgha/fleet-monitor/` with one OS process lock, secure permissions and bounded rotating audit output. Lock contention sends no fabricated health; the external missed heartbeat protects prolonged contention. Startup/corruption cannot erase a known unresolved external failure or announce recovery.
6. Resolve secret references through macOS Keychain / designated Linux store; hold heartbeat URL in memory and make HTTPS requests without command-line secrets. Only nonsecret configuration enters TOML/plists. Do not add .env files or credentials to shell wrappers.
7. GREEN same tests. Concurrent invocation test proves one emitter. Fake hung-child test proves deadline and cleanup. Secret canary test proves no credential in stdout, stderr, state or child argv.

## Task 4 — Hosted checks and delivery contract

Files: NEW `docs/fleet-alerts.md`, extend NEW `scripts/tests/test_fleet_monitor.py`; NEW `scripts/tests/test_fleet_delivery.py` with local fake HTTP server only.

1. Document the concrete provider setup: one check per stable host ID, period=60s, grace=120s, Slack AND verified email linked to both checks, Down and Up transitions enabled. Hourly unresolved email reminders are account-wide, so default OFF until activation owner explicitly approves the effect on every account check; record this choice. Never assume account defaults apply to both checks. No automated account purchase.
2. RED fake-server tests: mature failure sends `/fail`; failure POST rejected/DNS blocked means no success; accepted first miss/pending starvation heartbeat means threshold has not matured; recovery requires both samples. Test HTTP 403, 429, 500, HTTP200 with ignored not-found/rate-limited body, timeout, stale response and credential absence; only documented status plus exact stripped body OK is accepted. All calls use localhost and dummy URLs.
3. Bound connect=5s and total request=10s; no unbounded retry within a tick. Require response validation plus activation/daily Management API readback of exact existing, active checks and last-ping advancement. Missing/paused/deleted check or integration drift is an audit failure. Record attempt/result separately from local audit; preserve provider failure. Repeating `/fail` while Down must not imply repeated notifications; provider transition behavior owns dedup.
4. GREEN: `python3 -m unittest discover -s scripts/tests -p 'test_fleet_delivery.py' -v`. Verify failed explicit reports still yield external timeout by withholding success. Test dual independent fake integration outcomes for accounting only; one channel's success never satisfies both. These fake tests never prove Healthchecks managed integrations; Task7 requires real receipts.
5. Runbook defines unique incident ID, host/config identity, failed slots and proof links, plus provider acceptance vs actual Slack and mailbox receipt. Choose verified existing operator destinations at activation; unresolved destinations block activation. Do not run live messages in this planning session.

## Task 5 — Correct existing daemon delivery accounting

Files: modify `src/alert.rs`, affected callers in `src/main.rs` and other compiler-reported call sites, tests in `src/alert.rs`.

1. Preserve public compatibility where possible, but introduce explicit per-channel results and cooldown state. A local file write is audit success only; it must not reset remote-delivery/deadman health or suppress retries for failed Slack/email.
2. RED: `cargo test alert::tests` adds Slack failure + log success, email failure + Slack success, both remote failures, no remote configured, retry after failed channel, cooldown per channel, bounded deadline and secret-redacted errors. Tests use faithful fake commands/localhost only; no real webhook or sendmail.
3. Implement minimal shared fix and update callers deliberately: distinguish best-effort logging from remote delivery. Keep bounded synchronous work; do not add retries to serve loop. In-process deadman stays explicitly different from external host-outage detection.
4. GREEN: same targeted tests, then `cargo test`. Verify logs remain useful when no external channels configured but configuration does not claim remote alerting is ready. Existing alert failure hooks continue to operate.

## Task 6 — Reproducible native installation and migration

Files: modify `launchd/org.jleechanorg.ezgha-fleet-alert.plist.template`, `launchd/install-launchagents.sh`, `launchd/README-ezgha-fleet-alert.md`, `systemd/ezgha-fleet-alert.service`, `systemd/ezgha-fleet-alert.timer`, `install.sh`; NEW `tests/fleet_monitor_install_test.sh`; extend `.github/workflows/ci.yml` using its existing test job.

1. RED install fixture checks: 60s cadence; whole-service timeout backstop (systemd 45s and wrapper-enforced deadline on Mac); stable installed executable/config paths; nonsecret refs only; explicit host ID and service config; one observer per host; cleanup rollback limited to files installer owns.
2. Replace old shell alert scheduling with new observer through existing installer. Test dry installation in temporary HOME with stubbed launchctl/systemctl: no production calls, no default Slack/email secrets. Linux uses existing alert service/timer names; do not create a duplicate timer. Record rendered hashes and paths.
3. Preserve existing watchdog/recovery ownership, fleet size, Docker resource limits and daemon restart behavior. Explicitly migrate Linux OnFailure/ExecStopPost to retain local diagnostics/distinct cause events while disabling their overlapping fleet-availability remote page; hosted checks alone own availability Down/Up. Test that a daemon exit still records hook diagnostics and opens only one availability incident. Monitoring failure cannot invoke recovery, `docker run`, rebuild, or prune. Make upgrades recoverable and do not stop a production unit until replacement validation and rollback state are ready.
4. GREEN: `bash tests/fleet_monitor_install_test.sh` plus existing launchagent tests discovered under `tests/`. Wire the new probe/observer/delivery/install tests into an actual CI caller. Tests must pass without Docker, GitHub, Slack or email credentials.
5. Only after code is complete run `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, and the four new test commands. Re-run only affected gates after material fixes. Stage only owned files; future commits/pushes follow repo policy and single deploy-owner rules.

## Task 7 — One final activation and delivery proof

Files: `docs/fleet-alerts.md`; NEW `evidence/fleet-alerts-<activation-date>/` sanitized records. Requires later authorization plus all implementation preconditions.

1. Resolve account and both destinations; confirm whether account-wide hourly reminders may be enabled (default OFF); provision per-host references securely. Verify provider project associations using authenticated readback. Inventory current loaded units, executable hashes, service-owned config/endpoint and prior installer version for rollback. Resolve current Mac missing-image incident separately before claiming availability.
2. Capture baseline latency/CPU on both hosts without changing runner capacity. Require p95 sample <=25s, each invocation <=45s and no more than two concurrent Docker probes. If overloaded, stop activation; do not lower fleet contract or modify restart thresholds to pass.
3. Deploy the observer using the single deploy-owner and prove loaded ProgramArguments/ExecStart, interval, last-run timestamp and actual running executable match rendered artifacts. Do not infer deployment from repository files. Leave old observer rollback artifact; remove duplicate scheduling only via owned installer migration.
4. Create dedicated test checks using production notification integrations. Simulate missing slot/image/hung backend with fixtures; simulate total Mac, Linux, and simultaneous host silence by stopping only the test heartbeat streams. Production runners remain untouched. Require Down in <=3min since last success and actual Slack AND mailbox receipts in <=5min; failed channel stays failed even if provider accepted heartbeat.
5. Recover test streams with two good samples; assert one recovery transition and both receipts. Retain exact incident IDs/timestamps, uploaded template hashes, provider activity and sanitized message IDs. Verify HTTP 403 integration failure and restored credentials only in safe test destinations; never deliberately revoke production credentials.
6. Configure an independent daily synthetic check runner outside these hosts/their CI fleet, using the same Slack/email integrations. Verify through authorized receipt reads; missing receipt creates an operational failure. Activation cannot be complete without runner ownership and a real scheduled invocation; a runbook-only test is insufficient.
7. When separately authorized for fleet restoration proof, run existing bounded capacity workflow/harness once at final deployed revision and record `docker top` Worker evidence for each of six Mac and ten Linux slots. Historical job successes and API runner counts cannot satisfy current execution proof. Do not use this proof to claim notification delivery.
8. Close zmk only with both-host scheduler proof, missing-heartbeat and recovery proof, and dual-channel receipts. Update related beads with precise delivered scope; never close watchdog/trim implementation work merely because generic host alerts exist. Roll back monitor migration on failed validation using preserved owned units, keeping external checks visibly Down rather than silencing them indefinitely.

## Planning validation and known limits

This plan is self-contained and has no application changes. Exact cause of Mac image removal, Linux webhook 403, provider account ownership, destinations and external daily-runner/read permissions remain implementation/activation preconditions with explicit stop rules. Missing email infrastructure is avoided through hosted delivery, not presumed installed. Local doctor was attempted read-only with a 100s outer bound and stopped before full final verdict; its partial output confirmed active daemon/reachable Docker/zero containers and six DOWN first-pass candidates, but is not a complete harness pass.

The specification and this plan require independent `/advice` and browser `/web-advice` results bound to their final content digests. Review evidence is a separate artifact so recording results does not change the documents reviewed.
