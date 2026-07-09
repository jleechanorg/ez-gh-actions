# 48-hour runner-problem retrospective (2026-07-07T12:00 PDT → 2026-07-09)

Bead: jleechan-c97c (P3 of the 2026-07-09 measurement/reliability plan).
Mined by three parallel read-only agents (Mac launchd logs, jeff-ubuntu
journalctl via SSH, `br`/`git log` bead timeline) + one manual follow-up
verification. Every incident below cites its source directly; anything not
independently confirmed is marked UNVERIFIED rather than asserted as fact.

## Failure-class taxonomy

### 1. GitHub App token staleness (401 Bad credentials)
- **Evidence**: `~/.local/state/ezgha/alerts.jsonl` (Mac), `ensure_count failed
  64/67/69 consecutive time(s) ... gh api generate-jitconfig failed for
  jleechanorg: gh: Bad credentials (HTTP 401)` at ts 1783617408-1783619793
  (2026-07-09, ~40min window). Beads: `jleechan-wzk` (token rotation root
  cause, interim fix commit `23e734f`), `jleechan-9rk` (acute Mac token-stale
  incident, remediated 2026-07-09 11:15 PDT).
- **Frequency**: 69 consecutive `ensure_count` failures before recovery
  (single episode in the 48h window, on the Mac).
- **MTTR**: ~40min from first 401 to alerts.jsonl going quiet; token-refresh
  launchd job deployed as the durable fix at 11:45 PDT (commit `23e734f`).
- **Existing metric that caught it**: `doctor-runner` section 4b (GitHub App
  token freshness: `ok`<45min / `warn` 45-60min / `bad`>60min), shipped
  `205b660` (2026-07-08) — pre-dates and directly targets this class. This
  metric was already in place; the 2026-07-09 recurrence was caught by it and
  fed the interim watchdog kick (`23e734f`).
- **Earlier-detection metric**: none needed on the doctor side — the gap here
  was operational (a launchd job to auto-kick token refresh on 401), which is
  now shipped. `jleechan-wzk` (the root-cause bead — cached `gh_token` bound
  to the pre-rotation private key, never re-minted on key rotation) is
  **CLOSED** as of 2026-07-09, fixed in commit `23e734f`: the `run_gh`
  chokepoint now detects "Bad credentials" and kicks the refresh job with a
  300s cooldown, with 3 new unit tests, deployed to the Mac binary same day.
  No residual gap tracked for this class.

### 2. GitHub API secondary rate-limit (403)
- **Evidence**: jeff-ubuntu journalctl, `gh api
  repos/jleechanorg/worldarchitect.ai/actions/runs/28894482050/jobs?per_page=100
  failed: gh: API rate limit exceeded for user ID 13840161 (HTTP 403)`, first
  at Jul 07 13:29:47, 55 total occurrences concentrated 13:29-14:30.
- **Frequency**: 55 errors in a ~1h window, one episode in the 48h window.
- **MTTR**: not independently determinable from journal alone; queue-monitor
  loop was starved for the duration of the blockade per the mining agent's
  read, then recovered post-reboot (see class 5).
- **Existing metric**: `doctor-runner`'s serve-loop-starvation signal
  (`RATE_LIMIT_COUNT` = `recent_logs | grep -i 'rate limit'` in the last N
  minutes) — but this is a **pull** metric, only visible when someone runs
  `doctor-runner`/`/doctor-ezactions`, not a push alert. No evidence anyone
  ran doctor during the 13:29-14:30 window, so this class went undetected
  live even though the ground truth was already loggable.
- **Earlier-detection metric (candidate for LANE-3/r83a)**: a daemon-side
  counter that alerts (writes to `alerts.jsonl`) when rate-limit occurrences
  exceed a threshold within a rolling window, rather than requiring a human
  to run doctor and grep logs after the fact. `src/github.rs`'s
  `run_gh_with_backoff_until` already has the counting infrastructure this
  would build on (see `SERVE_LOOP_TIME_BUDGET`/backoff plumbing referenced in
  `.claude/skills/ezgha-doctor/SKILL.md` Step 2b).

### 3. Runner slot-drift / JIT registration races (empty-id flap + in-flight-JIT reclaim race + 409 conflicts + missing-registration cascade)
- **Evidence**: this is the single largest class by volume.
  - jeff-ubuntu: `warning: INV-1 utilization violated: busy=19/22
    registered=19 queued_jobs=1290 fail_class=missing-registration` (Jul 07
    13:55:21); 246 INV-1 warnings on Jul 8 alone; **5,307**
    `respawned ephemeral runner` log lines across the 48h window (≈2.3/min
    average, i.e. constant churn, not a one-off).
  - jeff-ubuntu: 9× `gh: Already exists - A runner with the name *** already
    exists. (HTTP 409)` for `ez-runner-c-2`, Jul 08 23:27:47-23:28:22 (5
    attempts in ~55s).
  - jeff-ubuntu: `warning: orphaned runner ez-runner-c-7 (id 134035, status
    offline) has no slot-file owner — removing to prevent future 409
    self-heal churn` (Jul 07 11:11:41) — evidence the slot-file/runner-id
    sync was already degraded before the rate-limit blockade.
  - Mac: repeated `warning: removing stale offline/idle registration
    ez-mac-runner-b-{1..6} ... slot entry was already released by Path 1`
    across all 6 Mac slots, plus `generate-jitconfig` 409s citing "already in
    use by an online/busy runner ... presumed to belong to a live sibling
    host."
  - Beads: `jleechan-kbd` (empty-id slot-drift flap, Mac) and
    `jleechan-tku` (in-flight JIT race, Linux) — **both fixed by the same PR
    #33 (commit `1a9baf4`)**, merged 2026-07-08 23:20 PDT.
- **Frequency**: dominant failure mode of the window — thousands of
  respawns, hundreds of INV-1 warnings, both hosts affected.
- **MTTR**: from first detection signal (Mac slot ID flapping, kbd, ~11:54
  PDT Jul 8) to fix merged (23:20 PDT Jul 8) ≈ **11.5 hours**. Churn is
  described as "residual into Jul 9 morning" by the mining agent, so full
  drain took longer than the fix landing.
- **Existing metric that caught it**: none at the time — this is *why* it
  took 5,307 respawns and 11.5h to fix; the only signal was raw log volume,
  not a dedicated alert.
- **Earlier-detection metric (candidate for LANE-3/r83a)**: a per-slot
  state-transition log line (EXECUTING→IDLE→DOWN→EXECUTING with timestamps,
  r83a item (c)) would have made the flap *visible as a rate* (N transitions
  per slot per minute) within the first few minutes instead of only
  reconstructible after the fact by grepping 5,307 log lines. This is the
  highest-value new metric in this retro — it directly targets the largest
  failure class by volume.

### 4. Docker/VM backend restart misfire on native-docker hosts (Linux)
- **Evidence** (verified live 2026-07-09 during this retro, not just mined):
  jeff-ubuntu journalctl shows, at Jul 07 12:52:32 / 12:54:15 / 12:55:27 PDT,
  the daemon logging `colima exists but restart returned non-zero
  (["start"])`, `limactl exists but restart returned non-zero (["start",
  "colima"])`, and `systemctl exists but restart returned non-zero
  (["--user", "start", "lima-vm@colima.service"])`. **But** `which colima
  limactl` on jeff-ubuntu returns rc=1 (not found), and a filesystem search
  (`find / -maxdepth 4 -iname colima` across the confirmed `systemd --user`
  PATH) found no such binary anywhere on the host. jeff-ubuntu runs native
  Docker; colima/lima are Mac-only in this fleet's design (see
  `Dockerfile.runner`/config conventions).
- **Root cause status**: UNVERIFIED / not fully disambiguated. Current HEAD
  `src/main.rs:365-389` (`attempt_backend_restart`) has an explicit
  `io::ErrorKind::NotFound => continue` guard that should silently skip a
  missing binary (an `ENOENT` from `Command::new(cmd).spawn()`) rather than
  ever reaching the `Ok(false)` branch that prints "exists but restart
  returned non-zero" — those are two different code paths for two different
  outcomes (spawn failed vs. process ran and exited non-zero). Two candidate
  explanations, not yet distinguished:
  (a) `err.downcast_ref::<std::io::Error>()` (line 383) doesn't see through
  the `.with_context()` wrapper applied at line 340, making the `NotFound`
  guard dead code — a real bug in the current source.
  (b) The binary actually running on jeff-ubuntu at 2026-07-07 12:52 PDT was
  an older build lacking this guard (see `project_2026-07-07
  _ezgha_fleet_pacing_deadlock_and_version_skew.md` — "fleets run non-main
  binaries" is an independently known, standing issue).
  Filed as `jleechan-d4mk` for disambiguation (check jeff-ubuntu's deployed
  binary SHA vs HEAD; add a unit test spawning a nonexistent command through
  `run_restart_command_with_timeout`).
- **Impact**: 3 wasted restart attempts (~2s timeout each) on
  platform-inappropriate tooling, and a misleading log message implying
  colima IS installed on a host where it never was — noise that would
  mislead anyone debugging this class of incident from logs alone.
- **Separately**, a genuine colima hang WAS observed on the **Mac** (where
  colima is actually installed and load-bearing): `/tmp/ezgha-launchd-stderr.log`
  shows repeated `colima restart command timed out after 30s` /
  `Error: no usable backend found — docker daemon is not reachable`,
  correlated with a Mac reboot at **2026-07-09 11:13 PDT** (`last reboot`).
  This is class 4a (Mac-real) vs. the jeff-ubuntu anomaly being class 4b
  (Linux-spurious) — same restart-attempt code path, different underlying
  reality per host.
- **Existing metric**: none (no doctor-runner section currently distinguishes
  "backend restart attempted and failed because platform-inappropriate" from
  "backend restart attempted and failed because the real VM is hung").
- **Earlier-detection metric candidate**: gate `attempt_backend_restart`'s
  colima/limactl/lima-vm attempts behind a one-time `command -v colima`
  platform check at daemon startup (cached), so native-docker hosts never
  attempt them at all — this converts an always-failing 3-attempt/6s-timeout
  dead code path into a single early skip, and removes the misleading log
  line entirely (no metric needed once the misfire itself is removed).

### 5. Backend-restart-attempt thrashing (self-limiting, worked as designed)
- **Evidence**: Mac `~/.local/state/ezgha/alerts.jsonl`: `"saw too-frequent
  backend restart attempts for jleechanorg (28 since last); backing off"`
  (ts 1783620983), then `"saw 3 restart attempts in last 600s for
  jleechanorg; suppressing to avoid start-limit"` (ts 1783623606, marked
  CRITICAL by the mining agent). ~30min of thrashing before the daemon's own
  cooldown logic kicked in and suppressed further attempts.
- **Frequency**: one episode, correlated with the Mac colima hang (class 4a)
  — the daemon was trying to self-heal a genuinely-hung backend and hit its
  own rate limit doing so.
- **Assessment**: this is **not a bug** — `BACKEND_RESTART_MAX_ATTEMPTS` /
  `BACKEND_RESTART_WINDOW` (see `src/main.rs` backoff struct, lines ~300-330)
  is exactly the self-outage-prevention behavior this repo's CLAUDE.md
  mandates ("a safety mechanism must not be able to cause the outage it
  guards against"). It correctly avoided compounding a hung-backend incident
  with a restart-storm.
- **Existing metric**: the alert line itself (`alerts.jsonl`), but it's only
  visible if someone reads that file — not surfaced in `doctor-runner`'s
  output today.
- **Earlier-detection metric candidate**: surface `alerts.jsonl`'s restart-
  attempt-count-in-window as a `doctor-runner` info/warn line (cheap — the
  file already exists and is small), so an operator sees "backend restart
  suppressed N times in the last hour" without needing to know to check
  `alerts.jsonl` separately.

### 6. Host reboot / watchdog governance
- **Evidence**: Mac reboot at 2026-07-09 11:13 PDT (`last reboot`),
  correlated with the colima hang (class 4a). jeff-ubuntu shows two `last
  reboot` entries within ~2 minutes on Jul 07 (12:52, 12:54) — a double-
  reboot signature the mining agent attributes to watchdog intervention,
  though no explicit `exit 78` log line was found in the mined window to
  confirm that specific mechanism.
- **Related bead**: `jleechan-0ox` (watchdog exit code 78 triage) — **OPEN,
  P3**, not yet root-caused. This retro did not find direct exit-78 evidence
  in the 48h window, so `0ox` remains an open question rather than confirmed
  root cause of either reboot.
- **Existing metric**: `last reboot` (manual, not wired into doctor).
- **Earlier-detection metric candidate**: this is r83a item (d) — fold
  `0ox`'s eventual fix into a doctor-visible "host uptime since last reboot +
  reboot reason (if determinable from `/var/log` or watchdog's own log)"
  line so unexpected reboots are visible without a manual `last reboot`.

### 7. Queue starvation / saturation (long queue wait times)
- **Evidence**: jeff-ubuntu, Jul 07 12:41:44: `266 queued runs (fresh=262,
  stale=4)... fresh queue wait p50=24.0m p90=112.2m max=175.7m exceeds
  threshold 20m` — continuous high-wait warnings for 90+ minutes before the
  12:52 reboot, i.e. this was a **leading indicator** of the incident chain,
  not a trailing symptom.
- **Frequency**: continuous during the ~90min pre-reboot window.
- **Existing metric**: `scripts/queue-health.sh` (section 8,
  `QUEUE_TAIL_WARN_MIN`=20min) already catches sustained queue-tail
  saturation exactly as seen here.
- **Earlier-detection metric**: **already shipped this session** — bead
  `jleechan-hca0` (commit `dbcf907`, same mission, LANE-1) added
  `IDLE-STARVED` (section 9/10 of `doctor-runner`), which flags any runner
  sitting idle while `QUEUE_OLDEST_FRESH_AGE_MIN >= 5min`, i.e. a 5-minute
  earlier warning than section 8's 20-minute queue-tail gate for exactly
  this failure mode. No further work needed for this class.

## Out of scope for this taxonomy (adjacent, not fleet-reliability incidents)
- `jleechan-2a8` — harness/agent-governance gap (a sub-agent ran a
  remediation command despite an explicit read-only instruction). This is an
  agent-discipline defect, not a runner/fleet metric; already tracked and
  informed the "NEVER restart/colima/limactl, read-only sub-agent prompts
  must say so verbatim" rule this mission's own sub-agents operated under.
- `jleechan-mw9` — Playwright CI image/dependency blocker. Application-level
  CI blocker, not a runner-fleet reliability incident.

## Summary table

| # | Class | Freq (48h) | MTTR | Existing metric | New/earlier metric | Status |
|---|-------|-----------|------|------------------|---------------------|--------|
| 1 | Token staleness (401) | 1 episode, 69 fails | ~40min | §4b token freshness (shipped) | none needed | Fixed, wzk CLOSED (23e734f) |
| 2 | API rate-limit (403) | 55 errors/1h | unclear | doctor-visible only (pull) | daemon-side push alert | Candidate for r83a |
| 3 | Slot-drift/JIT races | 5,307 respawns, 246 warnings | ~11.5h | none at time | per-slot state-transition log | **Highest-value candidate for r83a**; underlying bug already fixed (PR #33) |
| 4 | Backend-restart misfire (Linux) | 3 attempts/episode | n/a (Linux never succeeds) | none | gate on `command -v colima` at startup | New bug found this retro — jleechan-d4mk |
| 4a| Colima hang (Mac, real) | 1 episode, correlated w/ reboot | unclear | none | — | Tracked via class 6 |
| 5 | Restart-attempt thrashing | 1 episode, ~30min | self-resolved | alerts.jsonl only | surface in doctor | Self-limiting worked correctly |
| 6 | Reboot/watchdog governance | 2 reboots | n/a | `last reboot` (manual) | doctor-visible uptime+reason | jleechan-0ox open |
| 7 | Queue starvation | continuous, 90min pre-incident | n/a | §8 queue-tail (20min) | §9 IDLE-STARVED (5min) | **Already shipped** (hca0/dbcf907) |

## Sources
- Mac launchd logs + `~/.local/state/ezgha/alerts.jsonl` (mining agent
  `a88db2e70c43b6b4d`/summary "Mine Mac launchd logs for 48h runner
  incidents").
- jeff-ubuntu `journalctl --user -u ezgha.service` via read-only SSH (mining
  agent `aceac249045f3b537`/summary "Mine jeff-ubuntu journalctl for 48h
  runner incidents").
- `br` bead timeline + `git log --since` (mining agent
  `a2ed8be9a423b1799`/summary "Mine bead timeline for 48h runner
  incidents").
- Manual verification of class 4 (colima-on-Linux anomaly): `which colima
  limactl`, `find / -iname colima`, `systemctl --user show-environment`, and
  `src/main.rs:333-389` read, all run 2026-07-09 during this retro.
