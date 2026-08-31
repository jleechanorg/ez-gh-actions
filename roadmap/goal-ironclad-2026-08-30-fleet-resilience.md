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
| 4 | Deployment cannot create a fleet-wide failure. Each host is changed separately only below safety gates. | Immediately before deployment record `uptime`, load, `docker ps`, per-slot workers, and boot ID; require load `<12`, Linux floor `>=8` or Mac floor `>=4`, and drain existing jobs. | Actual host and container state immediately before each deployment. | Primary operator owns deployment; Luna verifies the captured gate evidence. | FAIL |
| 5 | Every named slot executes a real job and stays healthy across reconciliation ticks. | Take at least three local samples spanning multiple configured serve ticks; each sample must show `Runner.Worker` in c-1..c-10 and f-1..f-6 via `docker top`. Then run `./doctor-runner`. | Local Docker process tables on both hosts; GitHub API counts are inadmissible. | Luna verifier reproduces the sample parser and doctor result. | FAIL |
| 6 | Both installed binaries exactly match merged `origin/main`. | Compare `git rev-parse origin/main` with `ezgha --version` on Linux and Mac after deployment. | Remote merged SHA and installed executable metadata. | Terra reviewer checks the comparison independently. | FAIL |
| 7 | The host survives bounded normal-production verification without any prohibited test. | Record Linux `/proc/sys/kernel/random/boot_id` and Mac `sysctl -n kern.boottime` before and after the observation window; audit the command log to confirm no pressure, panic, reboot, shutdown, watchdog, or host-restart test ran. | Physical-host boot identity across real workload time. | Sol primary plus Terra final review. | FAIL |

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
5. Deploy one host at a time behind load, capacity-floor, drain, and boot-ID gates.
6. Prove sustained 10+6 execution locally and run `./doctor-runner`.
7. Re-audit the host boundary and only then close `ez-gh-actions-hhkx`.
