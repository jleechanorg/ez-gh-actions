# Complete deterministic RED review evidence

## FINAL-REPORT.md

```text
# Executable RED: post-refill released-slot boundary

## Result

**Reproduced deterministically at the requested baseline.** The new full-path Rust test reaches its intended final RED assertion: the actual serve plan is `(5s, false)` instead of the requested `(0ns, false)`. Three additional runs reproduce that identical failure. Fourteen existing preservation controls pass. Production code is unchanged; this is the requested test-only review checkpoint.

This establishes that the proposed sequence is possible in the exact code. It does not prove that the live 23:23 incident used these particular GitHub snapshots; live snapshot evidence was not collected or invented.

## Execution provenance

- Cloud hostname: `5d6c64d9e6b6`
- Tested absolute source path: `/workspace/scratch/78718234b9b0/runner-post-refill.tmAX2GJj/test-source`
- Unmodified baseline snapshot: `/workspace/scratch/78718234b9b0/runner-post-refill.tmAX2GJj/source`
- Baseline commit: `c29df6d0d94b9a4b245d8945959ee5d59f387840`
- Commit tree: `582111986eb27116db74cc1c6d954dd4a2c78a58`
- Source type: **25-file, blob-verified partial source snapshot, not a full Git checkout**. All Rust sources, Cargo.lock/Cargo.toml/build.rs, repository policies and compile-time included assets are present. Each original file matches its pinned Git blob hash. No invented Git history or baseline commit.
- Remote main was re-pinned immediately before the RED run and still resolved to the requested baseline. Receipt: `evidence/remote-main-repin.json`.
- Requested branch `codex/post-refill-released-slot-20261004` was absent (404) and was not created or pushed.
- `rustc 1.99.0 (b940084d7 2026-09-28)`; `cargo 1.99.0 (5f94df478 2026-08-27)`.
- Official rustup downloaded from static.rust-lang.org, checked against its official SHA-256 file, and installed under this diagnostic workspace. HOME, RUSTUP_HOME, CARGO_HOME and CARGO_TARGET_DIR are workspace-local; no shell profile modification. Build dependencies come from the existing lockfile. No ezgha service was installed.

## Exact command and full output

With the workspace-local toolchain bin directory on PATH and HOME/CARGO_HOME/RUSTUP_HOME/CARGO_TARGET_DIR set as recorded in `run-red.sh`, from the tested source directory:

```sh
cargo test --offline --locked --bin ezgha docker_backend::tests::post_refill_released_slot_requests_immediate_reconcile -- --exact --nocapture --test-threads=1
```

Full intended RED output: `evidence/released-slot-red-attempt3.log`.
Repeatability, including all three full outputs: `evidence/released-slot-red-repeatability.log`.
Exact source diff: `test-only.patch` (168 inserted lines, one test in the existing test module; no production lines changed).

The first two attempts were fixture debugging, not accepted REDs: attempt 1 rejected the production Docker endpoint prefix; attempt 2 detected a stale mock log after a recycled test PID. The final fixture strips the fake command's endpoint argument and clears only its own named fixture artifacts. Those full outputs remain in the evidence bundle.

## Proven sequence and first divergence

The test uses existing TestEnv, a real persisted slot table, strict mock Docker/GitHub executables, and the actual `ensure_count_outcome`, `release_stale_slots`, `next_slot_excluding`, `start_missing_runners`, `start_one_with_generate_at_slot`, GitHub parsing and serve decision functions.

1. c4 has persisted runner ID 1004. The first complete GitHub snapshot still lists that matching registration online/busy, while successful Docker inventory already omits c4 and c10. The first release preserves c4.
2. The sole start batch finds only c10 vacant. Its JIT snapshot proves c4=1004 and c10's newly reserved empty ID. The real start path records c10=1010 and issues exactly one fake Docker start for c10. Allocation then reports no free slot.
3. The second complete GitHub snapshot omits c4. A successful local inventory also omits c4. The actual trailing release removes c4's assignment with reason `gh-missing-no-local-container`; c10 remains assigned.
4. The returned outcome is:

```text
started=["ez-runner-c-10"]
missing=2
remaining_shortage=1
post_refill_readiness_error=None
post_refill_capacity_lost=[]
start_failures=0
admission_paused_reason=None
```

**First semantic divergence:** docker_backend.rs:5234–5241 derives the loss signal exclusively from initial inventory witnesses. c4 was absent from that inventory, so its newly released capacity is omitted. Its release at line 5225 occurred after the only start batch at line 5223 and is otherwise discarded by ensure_count_outcome.

5. Actual serve decision functions return `StartSettling { executing: 13 }` and `(5s, false)`. The actual settling episode observes 13 ready/zero absent at synthetic monotonic +5/+10/+15/+20 seconds and returns Continue, then Ceiling at +25 seconds. These are deterministic time inputs, not a claim that the test slept 25 wall-clock seconds.
6. The final assertion fails only because the expected bounded next reconciliation is zero-sleep. Exit code 101 is the intended Rust assertion failure.

Important evidence boundary: existing unit builds require TEST_EXECUTING_RUNNER_COUNTS, so readiness responses use that existing seam; the real inventory-filtered readiness fanout is exercised. This is not a live Docker test or a launched daemon process. The full ensure path and actual serve decision/pacing functions execute, rather than an isolated replacement helper or handwritten Python model.

## Preservation controls

All 14 selected existing tests pass; full names and commands are in `evidence/preservation-controls.log`. They cover:

- Newly started crashes retain ordinary settling, including consecutive fresh-start losses
- Existing initial-witness loss requests immediate reconciliation
- Unconfigured names and still-present not-ready witnesses are excluded
- Confirmed loss survives later readiness error
- Consecutive existing loss is paced before a second immediate reconciliation
- Deliberate admission pause remains distinct
- Quarantined allocation remains excluded, including across calls
- Empty never-started reservations retain their grace window
- Unknown local activity remains fail-safe
- Failed GitHub inventory does not mutate slots
- Occupied reservations remain pending turnover, not backend failures
- Only one bounded start batch per ensure call
- A full idle/listener fleet does not enter settling

The pre-existing baseline control `post_refill_inventory_loss_forces_immediate_reconcile` also passed before applying the test. This is focused evidence, not a full-suite pass or live fleet validation. A Rust 1.99 deprecation warning for existing fetch_update usage was left unchanged.

## Minimal repair proposal for review, not implemented

Retain named configured reservations held immediately before the sole batch and determine which actually become available through its trailing release. Only a relevant named transition, still absent from a successful post-refill local inventory, should request the existing bounded next reconciliation. Reuse the current first-immediate / consecutive-loss settling machinery, leaving one start batch per call.

Do not trigger on the numerical release count: it also includes orphaned GitHub registration removal and does not prove a configured slot became allocatable. Exclude out-of-range names, currently quarantined slots, newly started names, same-name live replacements and empty never-started reservations. Admission-paused decisions must keep priority; unknown inventory must retain its existing evidence handling.

Before accepting production code, add full-path controls for these exact new eligibility rules. In particular, a nonempty persisted JIT ID does not by itself prove that a container previously started. If “never-started” includes that ambiguous historical state, the repair must explicitly preserve that distinction or obtain stronger existing provenance; do not quietly equate registration with prior running capacity. A name-specific newly-allocatable outcome may express the event more accurately than broadening the existing initial-witness loss definition.

No scheduler/parallelism rewrite, dependency, timer heuristic, second unbounded start loop or retry-until-pass mechanism is needed.

## Scope preserved

All 25 baseline hashes were reverified after execution. Only an inserted test block differs; removing that exact block restores docker_backend.rs byte-for-byte. No production edit, commit, push, remote branch creation, CI trigger, merge, live configuration change, service installation/restart, deployment or canary. Neither Mac nor jeff-ubuntu was used.

```

## test-only.patch

```text
--- a/src/docker_backend.rs
+++ b/src/docker_backend.rs
@@ -7340,6 +7340,174 @@
     }
 
     #[test]
+    #[cfg(target_os = "linux")]
+    fn post_refill_released_slot_requests_immediate_reconcile() {
+        let env = TestEnv::new("post_refill_released_slot");
+        let dir = env.path.parent().unwrap();
+        // TestEnv paths can recur after a test process PID is recycled.
+        for file in ["calls", "started-c10", "at-c10-jit.toml", "at-second-release.toml"] {
+            let _ = std::fs::remove_file(dir.join(file));
+        }
+        let mut cfg = cfg_with(14, "ez-runner-c");
+        cfg.state_dir = Some(dir.into());
+        cfg.runner.host_reserve_mb = 0;
+        cfg.limits.memory_mb = 1;
+        cfg.limits.cpu_burst = false;
+        cfg.limits.cgroup_parent = Some("actions.slice".into());
+        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
+        *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
+        *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
+        cpu_probe_overrides::set(Some(true));
+        let cgroup = dir.join("cgroup");
+        write_actions_slice_fixture(&cgroup, 14);
+        std::fs::write(cgroup.join("actions.slice/memory.current"), "0\n").unwrap();
+        std::fs::write(
+            cgroup.join("actions.slice/memory.pressure"),
+            "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
+        ).unwrap();
+        *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(cgroup);
+
+        // Real release, allocation and start functions; all state is isolated.
+        // c4 is already missing locally but still has a matching online GH
+        // registration at the first release. c10 is the only vacant slot.
+        let mut assignments = SlotAssignments::default();
+        for slot in (1..=14).filter(|slot| *slot != 10) {
+            assignments.assignments.insert(slot.to_string(), (1000 + slot).to_string());
+            assignments.registered_at.insert(slot.to_string(), now_epoch_secs());
+        }
+        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();
+        for (file, after) in [("before.json", false), ("after.json", true)] {
+            let runners: Vec<_> = (1..=14)
+                .filter(|slot| if after { *slot != 4 } else { *slot != 10 })
+                .map(|slot| serde_json::json!({
+                    "id": 1000 + slot,
+                    "name": format!("ez-runner-c-{slot}"),
+                    "status": "online",
+                    "busy": true
+                })).collect();
+            std::fs::write(
+                dir.join(file),
+                serde_json::json!([{"total_count": runners.len(), "runners": runners}]).to_string(),
+            ).unwrap();
+            let containers = (1..=14)
+                .filter(|slot| *slot != 4 && (after || *slot != 10))
+                .map(|slot| format!("{}\n", serde_json::json!({
+                    "ID": format!("container-{slot}"),
+                    "Names": format!("ez-runner-c-{slot}"),
+                    "State": "running", "RunningFor": "one minute"
+                }))).collect::<String>();
+            std::fs::write(dir.join(if after { "after.jsonl" } else { "before.jsonl" }), containers).unwrap();
+        }
+        let gh = dir.join("fake-gh");
+        std::fs::write(&gh, format!(r#"#!/bin/sh
+set -eu
+PATH=/usr/bin:/bin
+cd '{}'
+printf 'gh %s\n' "$*" >> calls
+case "$*" in
+  'api --paginate --slurp '*'/actions/runners'*)
+    if [ -f started-c10 ]; then
+      cp slot_assignments.toml at-second-release.toml
+      cat after.json
+    else
+      cat before.json
+    fi;;
+  'api -X POST '*'/actions/runners/generate-jitconfig '*'name=ez-runner-c-10 '*)
+    cp slot_assignments.toml at-c10-jit.toml
+    printf '%s\n' '{{"encoded_jit_config":"synthetic-jit","runner":{{"id":1010}}}}';;
+  *) echo unexpected-gh-call >&2; exit 71;;
+esac
+"#, dir.display())).unwrap();
+        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
+        let _gh_guard = crate::github::with_gh_exe(gh.to_str().unwrap());
+        let _token_guard = crate::github::with_gh_token_file(dir.join("no-token"));
+        let docker = dir.join("fake-docker");
+        std::fs::write(&docker, format!(r#"#!/bin/sh
+set -eu
+PATH=/usr/bin:/bin
+cd '{}'
+if [ "${{1:-}}" = --host ]; then shift 2; fi
+printf 'docker %s\n' "$*" >> calls
+case "$*" in
+  'ps --filter label=ezgha=managed --format json')
+    if [ -f started-c10 ]; then cat after.jsonl; else cat before.jsonl; fi;;
+  'stats '*) exit 0;;
+  'ps --quiet --no-trunc') exit 0;;
+  'info '*) printf '32 64000000000\n';;
+  'rm -f ez-runner-c-10') exit 0;;
+  'run -d --rm --name ez-runner-c-10 '*)
+    : > started-c10
+    printf 'container-10\n';;
+  *) echo unexpected-docker-call >&2; exit 71;;
+esac
+"#, dir.display())).unwrap();
+        std::fs::set_permissions(&docker, std::fs::Permissions::from_mode(0o755)).unwrap();
+        *TEST_DOCKER_BIN.lock().unwrap() = Some(docker.to_string_lossy().into_owned());
+        // Test builds require the existing readiness seam. It drives the real
+        // inventory-filtered probe fanout, and cannot invent an absent name
+        // for c4, which is never in these docker-ps results.
+        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
+            (0..6).map(|_| Ok(ReadinessSummary { ready: 13, absent: vec![] })).collect(),
+        );
+
+        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();
+        assert_eq!(outcome.started, vec!["ez-runner-c-10"]);
+        assert_eq!(outcome.missing, 2);
+        assert_eq!(outcome.remaining_shortage, 1);
+        assert_eq!(outcome.start_failures, 0);
+        assert!(outcome.admission_paused_reason.is_none());
+        assert!(outcome.post_refill_readiness_error.is_none());
+        let at_jit: SlotAssignments = toml::from_str(
+            &std::fs::read_to_string(dir.join("at-c10-jit.toml")).unwrap()
+        ).unwrap();
+        assert_eq!(at_jit.assignments.get("4").map(String::as_str), Some("1004"));
+        assert_eq!(at_jit.assignments.get("10").map(String::as_str), Some(""));
+        let at_second: SlotAssignments = toml::from_str(
+            &std::fs::read_to_string(dir.join("at-second-release.toml")).unwrap()
+        ).unwrap();
+        assert_eq!(at_second.assignments.get("4").map(String::as_str), Some("1004"));
+        assert_eq!(at_second.assignments.get("10").map(String::as_str), Some("1010"));
+        let after_second = read_slot_assignments_for(Some(&cfg)).unwrap();
+        assert!(!after_second.assignments.contains_key("4"));
+        assert_eq!(after_second.assignments.get("10").map(String::as_str), Some("1010"));
+        let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
+        assert_eq!(calls.lines().filter(|line| line.starts_with("gh api --paginate")).count(), 2);
+        assert_eq!(calls.lines().filter(|line| line.starts_with("docker run -d")).count(), 1);
+        assert_eq!(calls.lines().filter(|line| line.contains("generate-jitconfig")).count(), 1);
+        assert!(!calls.contains("--name ez-runner-c-4 "));
+        eprintln!("COMMAND TRACE:\n{calls}");
+        eprintln!("C4 RESERVED AT C10 JIT=1004; C10 RESERVED EMPTY; C10 ID AFTER START=1010; C4 RELEASED AFTER BATCH");
+        eprintln!("OUTCOME: {outcome:?}");
+
+        let decision = crate::ensure_success_decision_with_pending_readiness(
+            crate::ensure_success_decision(&cfg, &outcome), false, false, 13,
+        );
+        let plan = crate::ensure_success_plan(&cfg, decision);
+        eprintln!("SERVE DECISION: {decision:?}; PLAN: {plan:?}");
+        if matches!(decision, crate::EnsureSuccessDecision::StartSettling { .. }) {
+            let start = Instant::now();
+            let mut settling = None;
+            let mut pending = false;
+            crate::apply_ensure_success_decision(&mut settling, &mut pending, start, decision);
+            for seconds in [5, 10, 15, 20, 25] {
+                let summary = local_executing_runner_count(&cfg).unwrap();
+                assert_eq!(summary.ready, 13);
+                assert!(summary.absent.is_empty());
+                let observed = settling.as_mut().unwrap().observe(
+                    start + Duration::from_secs(seconds), summary.ready, cfg.runner.count,
+                );
+                eprintln!("SERVE POLL +{seconds}s: ready={}, absent={:?}, decision={observed:?}", summary.ready, summary.absent);
+                assert_eq!(observed, if seconds < 25 { crate::SettlingDecision::Continue } else { crate::SettlingDecision::Ceiling });
+            }
+        }
+        assert_eq!(
+            plan,
+            (Duration::ZERO, false),
+            "a configured reservation released after the sole start batch must request the next bounded reconciliation"
+        );
+    }
+
+    #[test]
     fn post_refill_inventory_loss_forces_immediate_reconcile() {
         let _env = TestEnv::new("post_refill_inventory_loss");
         let cfg = cfg_with(14, "ez-runner-c");

```

## evidence/released-slot-red-attempt3.log

```text
$ cargo test --offline --locked --bin ezgha docker_backend::tests::post_refill_released_slot_requests_immediate_reconcile -- --exact --nocapture --test-threads=1
   Compiling ez-gh-actions v0.1.0 (/workspace/scratch/78718234b9b0/runner-post-refill.tmAX2GJj/test-source)
warning: use of deprecated method `std::sync::atomic::Atomic::<u32>::fetch_update`: renamed to `try_update` for consistency
    --> src/docker_backend.rs:4076:30
     |
4076 | ...                   .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |x| {
     |                        ^^^^^^^^^^^^
     |
     = note: `#[warn(deprecated)]` on by default
help: replace the use of the deprecated method
     |
4076 -                             .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |x| {
4076 +                             .try_update(Ordering::SeqCst, Ordering::SeqCst, |x| {
     |

warning: `ez-gh-actions` (bin "ezgha" test) generated 1 warning (run `cargo fix --bin "ezgha" -p ez-gh-actions --tests` to apply 1 suggestion)
    Finished `test` profile [unoptimized + debuginfo] target(s) in 2.58s
     Running unittests src/main.rs (/workspace/scratch/78718234b9b0/runner-post-refill.tmAX2GJj/target/debug/deps/ezgha-ba21ced74795f6cd)

running 1 test
test docker_backend::tests::post_refill_released_slot_requests_immediate_reconcile ... admission pressure source: /tmp/ezgha-test-297-post_refill_released_slot-0/cgroup/actions.slice/memory.pressure high=/tmp/ezgha-test-297-post_refill_released_slot-0/cgroup/actions.slice/memory.high (host-docker)
info: no free runner slot yet; registration turnover is still settling
info: release_stale_slots reclaimed slot 4: runner_id=1004 last_run_id=0 monotonic_ts=0.000 wall_ts=1791157675 elapsed_secs=0 peak_rss_mb=0 in_grace=false reason=gh-missing-no-local-container
info: release_stale_slots reclaimed 1 stale slot(s) for prefix ez-runner-c (live GH runners: 13, local containers tracked: 13)
COMMAND TRACE:
gh api --paginate --slurp orgs/jleechanorg/actions/runners?per_page=100
docker ps --filter label=ezgha=managed --format json
docker stats --no-stream --format {{.Name}}	{{.MemUsage}} container-1 container-2 container-3 container-5 container-6 container-7 container-8 container-9 container-11 container-12 container-13 container-14
docker ps --filter label=ezgha=managed --format json
docker ps --quiet --no-trunc
docker info --format {{.NCPU}} {{.MemTotal}}
docker rm -f ez-runner-c-10
gh api -X POST orgs/jleechanorg/actions/runners/generate-jitconfig -f name=ez-runner-c-10 -F runner_group_id=1 -f labels[]=self-hosted -f labels[]=ezgha
docker run -d --rm --name ez-runner-c-10 --label ezgha=managed --label ezgha.runner_id=1010 --memory 1m --memory-swap 1m --cpus 2.00 --pids-limit 512 --security-opt no-new-privileges --cgroup-parent actions.slice ghcr.io/actions/actions-runner:latest ./run.sh --jitconfig synthetic-jit
gh api --paginate --slurp orgs/jleechanorg/actions/runners?per_page=100
docker ps --filter label=ezgha=managed --format json
docker ps --filter label=ezgha=managed --format json

C4 RESERVED AT C10 JIT=1004; C10 RESERVED EMPTY; C10 ID AFTER START=1010; C4 RELEASED AFTER BATCH
OUTCOME: EnsureCountOutcome { started: ["ez-runner-c-10"], missing: 2, remaining_shortage: 1, post_refill_readiness_error: None, post_refill_capacity_lost: [], start_failures: 0, admission_paused_reason: None }
SERVE DECISION: StartSettling { executing: 13 }; PLAN: (5s, false)
SERVE POLL +5s: ready=13, absent=[], decision=Continue
SERVE POLL +10s: ready=13, absent=[], decision=Continue
SERVE POLL +15s: ready=13, absent=[], decision=Continue
SERVE POLL +20s: ready=13, absent=[], decision=Continue
SERVE POLL +25s: ready=13, absent=[], decision=Ceiling

thread 'docker_backend::tests::post_refill_released_slot_requests_immediate_reconcile' (298) panicked at src/docker_backend.rs:7503:9:
assertion `left == right` failed: a configured reservation released after the sole start batch must request the next bounded reconciliation
  left: (5s, false)
 right: (0ns, false)
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
FAILED

failures:

failures:
    docker_backend::tests::post_refill_released_slot_requests_immediate_reconcile

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 483 filtered out; finished in 0.05s

error: test failed, to rerun pass `--bin ezgha`
EXIT=101

```

## source-manifest.json

```text
{
  "repository": "jleechanorg/ez-gh-actions",
  "base_sha": "c29df6d0d94b9a4b245d8945959ee5d59f387840",
  "commit_tree_sha": "582111986eb27116db74cc1c6d954dd4a2c78a58",
  "hostname": "5d6c64d9e6b6",
  "source_path": "/workspace/scratch/78718234b9b0/runner-post-refill.tmAX2GJj/source",
  "kind": "partial blob-verified source snapshot; not a Git checkout",
  "remote_branch": "codex/post-refill-released-slot-20261004",
  "remote_branch_state": "404; not created",
  "files": [
    {
      "path": "AGENTS.md",
      "sha": "52c4695fb7cfabc0f49b0a403189c459c6a6fb40",
      "size": 5328
    },
    {
      "path": "CLAUDE.md",
      "sha": "6ad7ced5077c414a5784153886693b50387df288",
      "size": 21283
    },
    {
      "path": "Cargo.lock",
      "sha": "7097b4be5d9eb856824834e1dec219c0f6b4fd73",
      "size": 15340
    },
    {
      "path": "Cargo.toml",
      "sha": "205913000007362114f250ed19b49ad75d8856bb",
      "size": 533
    },
    {
      "path": "build.rs",
      "sha": "a4982e306ace76a5509bf6e30a9690ff6e83c6d5",
      "size": 1193
    },
    {
      "path": "src/alert.rs",
      "sha": "71d738ab52398b90d6a1845ea08eb1186d1207a6",
      "size": 31166
    },
    {
      "path": "src/backend.rs",
      "sha": "12148bece7cd1a13d1a5f3e4ddf507a34871991a",
      "size": 6521
    },
    {
      "path": "src/canary.rs",
      "sha": "ebe33f5a0bf13b1371e1c823444bfd90b88ff5f2",
      "size": 23895
    },
    {
      "path": "src/config.rs",
      "sha": "58d7e9f2f88d25d36d4d889e073c2d22eacb0d18",
      "size": 53995
    },
    {
      "path": "src/docker_backend.rs",
      "sha": "37da2855c8819d78b00575d9f6acc303afe5d615",
      "size": 543540
    },
    {
      "path": "src/failure_ladder.rs",
      "sha": "b96205605ee614a60ae552ade56ec6c659892072",
      "size": 17651
    },
    {
      "path": "src/github.rs",
      "sha": "9882bfe7fb0eb4bbdcf91834662136b4546123c4",
      "size": 124383
    },
    {
      "path": "src/lima_convergence.rs",
      "sha": "22f4a3aa66de8a92f9c1c82197b61731669fef9f",
      "size": 40656
    },
    {
      "path": "src/main.rs",
      "sha": "1dbfd472d81d14261d9459fb846a736b8cac993c",
      "size": 127074
    },
    {
      "path": "src/platform.rs",
      "sha": "c5668e3a47a26697a0e39bd7bb61eb126801acdb",
      "size": 10676
    },
    {
      "path": "src/quarantine.rs",
      "sha": "15b1ffc2c1dd2b02f916fceef36dd74e23d7ec62",
      "size": 20205
    },
    {
      "path": "src/queue_monitor.rs",
      "sha": "fab4bf52d814f565b4bfdf43855a925b608d50df",
      "size": 147715
    },
    {
      "path": "src/reaper.rs",
      "sha": "1f17e54fc2d6e25e1a7c5d6e2442070ef15849ca",
      "size": 31517
    },
    {
      "path": "src/service.rs",
      "sha": "a65e4caca2bbd27898db4488980dda2c4600cced",
      "size": 21624
    },
    {
      "path": "src/shutdown.rs",
      "sha": "fd2a4a6c94fb3732420605ac0fc0fa2614db9da6",
      "size": 2871
    },
    {
      "path": "src/watchdog.rs",
      "sha": "70d39520e6db2c7b0c14892d08b48aa4a7328b03",
      "size": 3279
    },
    {
      "path": "systemd/host/actions.slice",
      "sha": "991bd5ba5f18130d30019336d4bfd25d3cbb8189",
      "size": 457
    },
    {
      "path": "config/config.toml.mac.example",
      "sha": "3df2e84dd09f561631c3ea27fa76b419f8379ed0",
      "size": 3031
    },
    {
      "path": "install.sh",
      "sha": "c558d439424b513a9be5d6ac2d010ed68c93e45e",
      "size": 51720
    },
    {
      "path": "config/config.toml.linux.example",
      "sha": "2afa2907c646220fbd2caf0ccec659d4b0c17510",
      "size": 1769
    }
  ]
}

```
