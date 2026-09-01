# Ironclad goal — restore 16/16 without host restart authority

**Goal bead:** `ez-gh-actions-hhkx`

**Literal goal:** Restore and keep 10 Linux plus 6 Mac ezgha runners healthy
while runner automation never reboots, shuts down, force-panics, or otherwise
restarts either physical host.

**Verdict:** FAIL until every criterion below passes simultaneously at the same
merged and deployed revision.

| # | Criterion | Executable check | External anchor | Independent verifier | Status |
|---|---|---|---|---|---|
| 1 | Host lifecycle authority remains absent from the repository and both live hosts. | Repo: `bash tests/forbid_host_reboot_primitives_test.sh`. Linux: `systemctl is-enabled watchdog.service; systemctl is-active watchdog.service; sysctl kernel.panic kernel.panic_on_oops`. Mac: `launchctl print-disabled user/$(id -u) \| rg ezgha-watchdog; test ! -e ~/Library/LaunchAgents/org.jleechanorg.ezgha-watchdog.plist`. | Checked-out merged SHA plus actual systemd/launchd/sysctl state. | Terra reviewer reproduces the read-only audit. | FAIL |
| 2 | The first divergent child-layer event is identified for every observed churn class, and fixes address that cause rather than a symptom. | Collect normal serve-tick evidence with `docker ps`, `docker top <slot>`, and bounded daemon logs; run the exact new regression test before and after each fix and preserve RED then GREEN output. | Local container/process state and real daemon boundary evidence, not GitHub API counts. | Terra reviewer checks causal trace; Luna verifier reproduces tests. | FAIL |
| 3 | Exact-head fixes are review- and CI-clean without destructive recovery from partial GitHub snapshots. | `gh pr view <PR> --json headRefOid,mergeable,mergeStateStatus,statusCheckRollup,reviews`; run targeted Rust tests and `cargo test` in an isolated worktree. | GitHub PR head SHA and CI conclusions plus fresh local test output. | Different model from implementer. | FAIL |
| 4 | Deployment cannot create a fleet-wide failure. One behavioral change is deployed to one host at a time only below fixed safety gates. | Before deployment record boot ID, `uptime`, per-slot workers, and the 1-minute load average in three samples 30 seconds apart. All three load samples must be `<12`; any sample `>=12` aborts. Drain existing jobs. During deployment, Linux `<8` or Mac `<4` containers is an abort floor, never permission to proceed. Do not touch the second host until the first has returned to configured capacity and passed criterion 5 without a new unexplained reclaim cluster. | Timestamped host/process evidence immediately before and throughout each deployment. | Primary operator owns deployment; Luna verifies the captured gate evidence. | FAIL |
| 5 | Every named slot executes a real job and stays healthy across reconciliation ticks. | Produce a 10-minute ledger sampled every 30 seconds. Every sample has exactly 16 rows and every row records timestamp, host, slot, container ID, `Runner.Worker` PID, workflow run ID, and workflow job ID. All c-1..c-10 and f-1..f-6 must be executing in every sample. Then run `./doctor-runner`; missing fields, transient shortfall, or API-only evidence fails. | Local Docker process tables correlated to real Actions job metadata; GitHub runner-count APIs are inadmissible. | Luna verifier reproduces the ledger parser and doctor result. | FAIL |
| 6 | Both installed binaries exactly match merged `origin/main`. | Compare `git rev-parse origin/main` with `ezgha --version` on Linux and Mac after deployment. | Remote merged SHA and installed executable metadata. | Terra reviewer checks the comparison independently. | FAIL |
| 7 | The host survives bounded normal-production verification without any prohibited test. | Record Linux `/proc/sys/kernel/random/boot_id` and Mac `sysctl -n kern.boottime` before and after the observation window; audit the command log to confirm no pressure, panic, reboot, shutdown, watchdog, or host-restart test ran. | Physical-host boot identity across real workload time. | Sol primary plus Terra final review. | FAIL |

## Release 1 execution contract — 2026-09-01

This is the bounded implementation dependency for the broader 16/16 goal. It reuses parent bead `ez-gh-actions-sa8c`; it does not add a new program or expand Release 1.

| # | Criterion | Executable check | External anchor | Independent verifier | Status |
|---|---|---|---|---|---|
| R1 | Tracked policy and a hermetic assertion prove finite `actions.slice`, `agents.slice`, and `automation.slice` values, neutral broad OOM roots, and absence of the legacy PSI watcher and runner OOM exemption. | `bash tests/host_crash_containment_release1_artifacts_test.sh && bash tests/assert_host_containment_release1_test.sh && systemd-analyze verify systemd/host/actions.slice` | Tracked systemd files and fixture-observed effective values. | One independent verifier reproduces the focused commands. | FAIL |
| R2 | Fixed Linux HostDocker admission performs no slot, JIT, workspace, removal, or Docker mutation unless containment and the canonical endpoint pass; every created PID is below `/actions.slice`. | `cargo test host_containment -- --nocapture && cargo test configured_cgroup_parent_is_emitted_on_runner_start -- --nocapture` | Rust effect ledger and real `/proc/<pid>/cgroup` ancestry contract. | One independent verifier reviews the affected Rust surfaces and reruns focused tests. | FAIL |
| R3 | `./install.sh` stages and invokes one canonical activation path that reaches exactly ten contained slot names/PIDs or leaves `ezgha.service` inactive without Docker/VM/host lifecycle recovery. | `bash tests/apply_host_containment_release1_test.sh && bash tests/install_watchdog_gate_test.sh && bash tests/install_uninstall_aux_units_test.sh` | Versioned bundle manifest, activation ledger, and service post-state. | One independent verifier reproduces fixtures; live activation remains primary-operator-only. | FAIL |

**Process ceiling:** one RED/GREEN pair at a time, one integrated review after R1-R3 are green, expensive outcome evidence once and last. Every 30 minutes must produce an executable RED or GREEN result. After two gate cycles or three hours, stop with the exact failing command and blocker. Do not create new criteria, reviewers, architecture, or tracking artifacts while an owning RED is unresolved.

## Anti-gaming rules

- A single transient 16/16 frame is insufficient.
- Online/busy counts from the GitHub API are insufficient.
- Mocks, dry runs, daemon self-report, or implementer-authored evidence alone are
  insufficient.
- Reducing configured capacity below 10 Linux or 6 Mac cannot pass.
- Restarting either host to obtain a green sample immediately fails the goal.
- If any criterion regresses, the whole goal returns to FAIL.

## Safe execution order

1. Admit work only when host memory, swap, and PSI allow it.
2. Gather read-only normal-operation evidence and review PRs #134 and #136.
3. Write regression tests first; observe RED; implement the smallest causal fix.
4. Obtain independent review and exact-head CI.
5. Deploy one behavioral change to one host behind the sampled load, capacity-floor,
   drain, and boot-ID gates. Require that host to pass full configured recovery and
   the fixed evidence window before touching the second host.
6. Prove sustained 10+6 execution locally and run `./doctor-runner`.
7. Re-audit the host boundary and only then close `ez-gh-actions-hhkx`.
