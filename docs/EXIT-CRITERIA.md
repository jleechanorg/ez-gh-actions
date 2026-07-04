# Ironclad exit criteria — ezgha fleet is "truly healthy"

A coding agent may declare the ezgha runner fleet **done / healthy** ONLY when every
criterion below passes. Each is objective and machine-checkable — no eyeballing, no
"looks fine", no single snapshot. If any gate fails, the agent loops: fix → re-run the
full gate suite → repeat. "Working" is a sustained green gate, never a produced artifact
or a favorable snapshot (see `docs/harness-early-victory-5whys.md`).

## How to run the whole suite

```bash
cd ~/projects/ez-gh-actions && bash docs/verify-exit-criteria.sh
```

**This script does not exist yet — writing it is the coding agent's first task.** It must
run every AUTO gate below, print PASS/FAIL per gate, and exit 0 ONLY if all AUTO gates
pass. The agent loops on non-zero exit. Manual gates (marked ⊘) are checked by a human/
reviewing agent once, not in the automated loop.

## Definitions (read first — these prevent false reds/greens)

- **`COUNT`** = `runner.count` read from `~/.config/ezgha/config.toml`, never hardcoded.
- **Effective capacity** = (online-and-idle runners) + (runners currently executing a
  job). A JIT/ephemeral runner that is mid-job then deregisters is HEALTHY, not missing —
  count raw registrations AND in-flight jobs, or you will false-red constantly under load.
- **Failure classification** (critical for Gate 5): a gate sample failing because
  `gh api` / GitHub was unreachable is an **INFRA-FLAKE**, not a **FLEET-FAIL**. The suite
  must label each failure. Only FLEET-FAILs are disqualifying; INFRA-FLAKEs get a small
  budget (below). This stops an unrelated network blip from resetting a 29-minute run.

---

## Gate 0 — Deployed code == committed code (AUTO)

The running binary must be built from current `main`. A fix on disk that isn't deployed
does not count (this session's #1 trap). **mtime comparison is forbidden** — `git pull`
touches file mtimes and `touch` can fake them; both false. Use an embedded git SHA:

- Add a `build.rs` that stamps `git rev-parse --short HEAD` into the binary; `ezgha --version`
  prints it. Gate asserts `ezgha --version` SHA == `git rev-parse --short HEAD`.
- `git status --porcelain` is empty (clean tree) AND local HEAD == `origin/main` HEAD
- Until the SHA-stamp exists, the gate FAILS closed (forces the agent to add it) — do not
  fall back to mtime.

## Gate 1 — Code quality

- `cargo build --release` clean
- `cargo test` — all pass, count ≥ the current committed count
- `cargo clippy --all-targets -- -D warnings` — zero warnings
- `cargo fmt --check` — clean
- No open bead labelled `thermo` with priority 0 (critical) in `status: open`

## Gate 2 — Service + daemon up

- `systemctl --user is-active ezgha.service` == `active`
- `systemctl --user is-enabled ezgha.service` == `enabled` (survives reboot)
- `docker info` succeeds within a 5s timeout
- colima VM (if used) status == `Running`

## Gate 3 — Fleet capacity (ephemeral-aware, not naive "exactly N") (AUTO)

Naive "exactly COUNT online right now" false-reds constantly: JIT runners deregister the
instant they finish a job, before the respawn lands. Measure **effective capacity**:

- (online-and-idle `ez-org-runner-*`) + (`ez-org-runner-*` currently busy on a job) == COUNT,
  allowing a transient shortfall of at most 1 in any single sample (respawn in flight)
- In a QUIESCENT sample (zero busy runners), online count == COUNT exactly, zero offline
- Local managed-container count is within 1 of COUNT
- Every online runner name matches `ez-org-runner-<1..COUNT>` (no gaps, no duplicates,
  no legacy `ezgha-<hostname>-<hex>` registrations)

## Gate 4 — Real job execution (online ≠ working) (AUTO)

- `doctor.sh --prove` exits 0: a freshly dispatched `ezgha-selftest` ran on an
  `ez-org-runner-*` and concluded `success` (verified via the run's jobs API — the
  `runner_name`, NOT a `busy` flag; a zombie runner is `busy` on a phantom job)
- The last ≥5 `ezgha-selftest` runs each concluded `success` on an `ez-org-runner-*`
- **Conditional** (don't false-red an idle weekend): IF any non-selftest workflow job ran
  in the last 24h, at least one concluded `success` on an `ez-org-runner-*`. The canary is
  the always-available proof; real traffic is checked only when it exists.

## Gate 5 — Sustained health, 30 min (the anti-early-victory gate) (AUTO)

- `doctor.sh` returns exit 0 on every sample across a continuous **30-minute** window,
  sampled every 60s (31 samples).
- **Budget:** ≥30/31 samples PASS, AND every non-PASS sample is classified INFRA-FLAKE
  (GitHub unreachable), not FLEET-FAIL. **Any single FLEET-FAIL resets the clock to zero.**
  Two INFRA-FLAKEs in the window also reset (persistent external flakiness ≠ proof).
- `ensure_count failed` (real fleet errors, excluding the benign "already at capacity"
  no-op) stays 0 in each rolling 3-min time-window across the whole 30 min.
- Effective capacity (Gate 3 definition) never drops below COUNT-1 for two consecutive
  samples.
- Evidence committed to `docs/observe-<date>/` with the per-sample timeline (minute,
  verdict, INFRA-FLAKE|FLEET-FAIL|PASS, capacity) + `checksums.sha256`.

## Gate 6 — Resilience (proves the root-cause class is fixed, not just this instance) (AUTO)

These must be **unit/integration tests in the suite** — NEVER live breaks on the
production fleet (breaking real `gh` auth to test would take the real fleet down):

- **API-blip survival (test):** a test where `list_runners` returns `Err` must show
  `release_stale_slots` returns `Ok(0)` and does NOT modify the slot file (the no-wipe
  root-cause fix). This is the single most important regression test.
- **Slot-file corruption survival (test):** a slot file with a non-numeric key must not
  panic reconciliation; the key is log-skipped (parse-guard fix).
- **Atomic-write (test):** a simulated crash between temp-write and rename leaves the old
  file intact and parseable.
- **Restart recovery (live, once):** `systemctl --user restart ezgha.service`; within
  3 min effective capacity returns to COUNT with zero manual intervention.
- **Disk-floor (test or live):** below `min_free_disk_gb`, ezgha refuses to spawn and logs
  loudly.

## Gate 7 — Monitoring exists (so decay at 3am is caught) (AUTO)

The fleet decayed silently for ~7h this session because nothing alerted. A healthy fleet
must be *observably* healthy without a human running doctor:

- A monitor (cron/systemd-timer/`ezgha monitor`) runs `doctor.sh` on a schedule and, on
  FLEET-FAIL, emits an alert to a durable channel (log the operator watches, Slack, or a
  file a human checks). Its config is committed and its trigger is auto (a script with no
  caller is not monitoring — CLAUDE.md automation rule).

## Gate 8 — Security + hygiene (⊘ manual review + AUTO greps) (AUTO where noted)

- (AUTO) No self-hosted workflow triggers on fork `pull_request`:
  `grep -L pull_request $(grep -rl 'self-hosted' .github/workflows)` — any self-hosted
  workflow with a `pull_request:` trigger and no fork guard FAILS (bead `ez-gh-actions-prq`).
- (AUTO) `grep` the docker-run args: every managed container gets `--security-opt
  no-new-privileges`, memory/cpu/pids limits, and NO `-v /var/run/docker.sock`.
- (⊘ manual) No secrets in committed files (`gitleaks`/`gh secret` review); config/slot
  files are user-scoped.

## Gate 9 — Documentation truth (⊘ manual) (manual)

- `README.md` "Status" and any "production-ready" claim match actual gate results — if
  Gate 5 hasn't passed a full 30-min window, docs must NOT claim production-ready.
- Every known-unfixed finding has an open bead (no silent gaps).

---

## Loop protocol for the coding agent

1. Run `bash docs/verify-exit-criteria.sh` (write it first if absent — Gate 0 forces this).
2. If exit 0 → **all AUTO gates pass**. Do the ⊘ manual gates (8-manual, 9), commit the
   passing evidence + timeline, update docs to match, stop.
3. If non-zero → read the FIRST failing gate, fix its ROOT CAUSE (not by restart-looping —
   see `docs/harness-early-victory-5whys.md`), re-run the FULL suite (a fix can regress an
   earlier gate), repeat.
4. Never declare done on a partial pass. Never skip Gate 5's full 30-min window. Gate 5 is
   the last gate to attempt — running it before Gates 0-4/6-7 pass wastes 30 min.
5. **Two caps** (either stops the loop → escalate with evidence):
   - Same gate FLEET-FAILs 5× in a row despite fixes → likely upstream (colima/host/GitHub).
   - Total loop iterations exceed 15 → a fix is chasing its tail across gates.
6. Escalation is not failure — a documented "here's the wall I hit and the evidence" is a
   valid, honest stop. A false-green is not.

## Anti-patterns that count as FAIL even if gates look green

- Declaring healthy from a single snapshot (Gate 5 exists precisely to forbid this)
- Treating `busy=true` as "working" (a zombie runner is busy on a phantom job — Gate 4
  requires a *concluded success*, not a busy flag)
- Deploying nothing but committing a "fix" (Gate 0)
- Restart-looping to force a green snapshot instead of fixing the reconcile logic
