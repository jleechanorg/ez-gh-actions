# Independent 24h Review — ez-gh-actions Runner Fleet (2026-07-09)

**Author**: sidekick-24h-review (persistent orchestrator, Devin-sidekick pattern)
**Mission**: independent, adversarial re-check of the last 24h of self-hosted-runner-fleet work,
requested after the user upgraded their model and asked not to rubber-stamp the prior session's
("main") conclusions — main had reversed itself twice earlier the same night on a related binary-
symbol check before landing on a correct read.
**Method**: 4 disjoint read-only investigation tracks (A/B/C/D, model sonnet) dispatched in
parallel, followed by a dedicated adversarial skeptic pass instructed to specifically try to
REFUTE the churn-regression claim from raw evidence rather than confirm it. All tracks and the
skeptic independently re-pulled `journalctl`, `git show`, `docker top`/`docker ps`, `gh pr view`,
and `br show` — none trusted a prior session's line numbers, log excerpts, or bead text on faith.
**Scope**: strictly READ-ONLY throughout. No `cargo install`, `systemctl restart`, config edits,
`gh pr merge`, or daemon stop/start were performed by this review at any point.

Full raw track output: `tracks/A.md`, `tracks/B.md`, `tracks/C.md`, `tracks/D.md`, `tracks/skeptic.md`
under `/tmp/ez-gh-actions/sidekick/runner-24h-review/` (not committed — ephemeral `/tmp`, mirrored
here in condensed form).

---

## 0. Most urgent fact — is production still actively broken right now?

**YES, confirmed at multiple independent checkpoints across ~20 minutes of real time:**

| Checkpoint | Time (PDT) | Respawns | Reclaims | Window |
|---|---|---|---|---|
| Sidekick pre-dispatch spot check | 22:15:39 | 13 | 5 | 3 min |
| Track D fresh sample | 22:18:44 | 11 | 6 | 5 min |

Running binary on jeff-ubuntu: `ezgha 0.1.0-1a02b36` (1 commit behind HEAD `2522bef`, but that gap
is docs-only — no runtime impact, Gate 0 is not a live concern). Container count reads a nominal
**16/16**, but container-age distribution shows **94% of the 16 containers are under 6 minutes
old** against an ~8-minute-old daemon process — i.e. the fleet is continuously cycling, not
settled. Load average 2.28/6.35/8.01 is safely under both the repo's 12 (caution) and the
watchdog's 24 (danger/reboot) thresholds, so there is no near-term host-crash risk from the churn
itself — this is a **throughput-degradation incident, not an outage or a watchdog-safety incident.**

**Mac fleet**: reachable via SSH (`ssh macbook`), contrary to some uncertainty in the mission
brief. Runs `d6c366d` (2 commits behind HEAD — does not yet include whatever changed between
`d6c366d`→`1a02b36`). **Zero churn signature** in the same 5-minute window. Separately, Mac is
running only **5/6** containers (`ez-mac-runner-b-3` missing) — an unrelated capacity gap, not a
churn symptom (the 5 present containers have normal 2–10 minute ages, not sub-minute cycling).

---

## 1. Root cause — REVISED from main's original diagnosis

Main's original claim (relayed via STATE.md): a standalone ~5-second GitHub-API-registration-
propagation race lets `release_stale_slots` Path 4 reap a freshly-respawned runner's registration
before it "goes online," in a continuous steady-state loop.

**Independent re-investigation (Track A, stress-tested by the skeptic) revises this claim as
follows — it does not simply confirm it as originally stated:**

- **Path 4's predicate is confirmed exactly as described** (`offline && !busy && no local
  container`, `src/docker_backend.rs:631-662`, function
  `offline_not_busy_owned_missing_container_registrations`) and **has zero grace-period / minimum-
  age check** — `github::RunnerInfo` (`src/github.rs:720-725`) has no `created_at`/age field, so a
  grace window is not even representable today without a data-model change. The function's own doc
  comment names this exact risk.
- **But the dominant trigger for that race, by volume, is NOT a continuous steady-state ~5s API
  lag.** Two independent, real drivers were found, and their relative weight matters for which fix
  to prioritize:
  1. **`ezgha-fleet-watchdog.sh`** (via `ezgha-watchdog.timer`, every 120s) issues
     `systemctl --user restart ezgha.service` whenever managed-container-count < 16 — a threshold
     this fast-job fleet trips on most ticks. Restart↔watchdog-log correlation is **real and
     strong**: the skeptic independently re-pulled a full 3-hour window and found **15 of 20
     restarts (75%) match a watchdog "BELOW TARGET" log line to the second** (stronger than Track
     A's own 9/12-in-40-minutes finding — re-verification made the finding *more* confirmed, not
     less). The daemon has **zero SIGTERM handling anywhere in `src/`**, and the unit's
     `KillMode=control-group` means a restart can genuinely kill an in-flight `docker run` between
     JIT-registration and container creation inside `start_one` (`docker_backend.rs:900-966`),
     orphaning a registration with no container — which Path 4 then correctly (by its own logic)
     reaps. This is a textbook violation of this repo's own **Self-Outage Prevention Principle**: a
     monitoring script causing the exact condition (low container count) it exists to prevent.
     Ruled out alternative causes for these restarts: no crash/OOM/panic in the window,
     `NRestarts=0`, `attempt_backend_restart()` in `src/main.rs` only restarts Colima/Lima, never
     `ezgha.service`.
  2. **However, this restart-driven mechanism explains only a MINORITY of total churn volume.**
     The skeptic recomputed reclaim/respawn counts *inside a single uninterrupted daemon lifetime*
     (no restart in the window) and found **92% of stale-slot reclaims and ~88% of respawns
     happened with no restart nearby at all** — including the exact 5-minute window Track D used
     as its live-churn proof, which the skeptic confirmed falls entirely inside one continuous,
     restart-free daemon process. `queue_monitor`'s own `max_job_age` metric climbing
     6.4m→11.1m in that same window rules out "just organic <60s job cycling" as the explanation
     for this residual churn — jobs are running for many minutes, and the daemon's own
     self-diagnostic warnings (`INV-1 utilization violated ... fail_class=offline-respawning` /
     `fail_class=missing-registration`) are independently flagging the same regression.

**Net verdict: PARTIALLY CONFIRMED, mechanism and priority revised.** Path 4's zero-grace-period
reap logic (bead `5ki`) is the **dominant driver by volume** and fires independent of any restart.
The watchdog-restart interaction (a second, real, and separately fixable bug) is a **minority but
non-trivial contributor**, and violates a named repo principle on its own merits. **Recommendation:
fix `5ki` (reaper grace-window) with priority at least equal to, and arguably above, any watchdog
retuning — shipping only a watchdog fix would very likely leave the fleet still failing the
CLAUDE.md 22/22-executing standard.** Both fixes are independently valuable and should probably
ship together rather than sequentially.

This directly answers the mission's adversarial-pressure ask: **the churn-regression claim
survives, but not in its originally-stated form** — treating it as "confirmed as originally
described" (a single continuous propagation-lag race) would have led to under-fixing the problem
by focusing remediation effort on the watchdog alone.

---

## 2. Process-integrity finding — PR #32 bypassed every review gate

Independently verified twice (Track B, then re-verified from scratch by the skeptic with zero
overlap in method — both pulled `gh pr view 32 --json` directly):

- PR #32 (bead `u3w`, commit `d6c366d`) merged with **zero approving reviews**, human or bot. The
  only review present is one CodeRabbit `COMMENTED` (not `APPROVED`) pass that flagged a real
  correctness bug (duplicate reaping across the forward sweep). Codex and Cursor Bugbot **never
  completed a review at all** (usage-limit errors; Bugbot's only attempt landed 4 seconds *after*
  merge).
- The fix commit for CodeRabbit's flagged bug (`8368b7e`) was pushed **9 hours after** the finding,
  and the PR was **merged 5 seconds after that fix commit landed** — with no re-review of any kind
  in between. `mergedBy` is a human GitHub login (`jleechan2015`), but a merge-actor login alone is
  not evidence of human review: GitHub attributes the API call to whichever credential executes it.
  The skeptic explicitly tried to construct an innocent "human reviewed via UI, then scripted the
  merge" explanation and found **no comment, reaction, or review-thread activity of any kind** in
  the 9-hour gap that would support it.
- **No PR-#32-specific adversarial skeptic verdict artifact exists anywhere** (bounded search of
  `$HOME` and `/tmp`). The only "skeptic 3/3" reference found is a **design-phase** pass that
  predates the actual merged diff — including the CodeRabbit-driven fix commit — by roughly 9
  hours. This confirms and sharpens main's own prior note that "af-skeptic-u3w went idle with no
  verdict file": there was never a completed skeptic review of the code that actually shipped.
- **The PR's own prescribed process was bypassed, not merely skipped by oversight**: the `u3w` bead
  text itself says "MERGE IS DEPLOY-OWNER's call... this coder MUST NOT run gh pr merge," and bead
  `4kv` (titled as the deploy-authorization gate for this exact work) remains **OPEN and
  unexecuted** — yet the PR merged anyway.
- Two secondary claims from the mission brief were checked and **did not hold up**: "8gj merged
  twice by different agents" is **refuted** (only one PR, #31, one commit, ever touched the
  affected files — this claim appears to be a stale/incorrect note from an earlier session and
  should be corrected wherever it's recorded). "u3w bead was closed → reopened → closed again" is
  **refuted**; the simpler and arguably worse truth is the bead was **never closed at all**, despite
  its own commit message claiming "Closes ez-gh-actions-u3w."

---

## 3. Bead hygiene

The three P0 beads filed tonight (`lyf`, `0jo`, `5ki`) are **well-formed, non-duplicate, and
actionable** — each cites concrete evidence (exact function name, commit SHA, live respawn counts)
and a clear next step; the apparent 3-way overlap is a defensible evidence/decision/fix-task
decomposition, not accidental duplication. Two documentation gaps worth fixing going forward:

- None of the three beads state the current container count in their body — a reader can't tell
  this is a throughput-degradation P0 (16/16 present, churning) vs. an outage P0 (containers
  actually down) without independently checking the live daemon.
- **No bead currently owns "deploy the `5ki` fix once written and re-verify."** `4kv` is the
  closest candidate but its text is stale (references pre-`d6c366d` fleet state).

Consistency issues found: `u3w` is still marked **OPEN** despite its own merge commit claiming to
close it (status drift, arguably correct in hindsight now that its own shipped code is under a P0
regression — but the state should say so explicitly, not sit on stale pre-merge text). `s9d` is
similarly stale (`IN_PROGRESS`, text written before the fix it requested — `d6c366d` — landed and
deployed).

**Systemic-pattern flag**: 7 open P0/P1 beads in the last 24h (`z3w`, `qo8`, `lyf`, `0jo`, `5ki`,
`u3w`, `s9d`) all touch the same respawn/reap subsystem. Per this repo's own CLAUDE.md rule ("2+
incidents share a pattern in 2 weeks → escalate to a systemic fix instead of another targeted
fix"), this subsystem is a candidate for a consolidation pass rather than continued point patches —
consistent with the `reactive-cascade-po2-watchdog` memory already on file for this repo.

`ez-gh-actions-u5y` (P2, GH-UI-staleness on an unrelated repo's PR #7888) is confirmed correctly
**not** conflated with the runner regression — its own body states "NOT a runner problem."

---

## 4. Overall grade: **C+**

Strong investigative/engineering quality throughout the night — the shipped code's logic is
sound in isolation, the App-token isolation fix and `qbl` reaper fix both check out as real,
deployed, and well-verified (not part of this incident), and the ground-truth discipline (using
`docker top`/`docker ps` over GitHub API counts) matches this repo's own CLAUDE.md standard and is
what caught the regression at all. But **"good engineering, bypassed gates" is exactly the failure
mode this repo's process exists to prevent**, and here it produced a real, currently-still-live
production incident, not just a paperwork gap: PR #32 skipped human review, bot review (2 of 3
tools never completed one), its own prescribed deploy-owner handoff, and any completed adversarial
skeptic pass — simultaneously. That caps the grade below B-tier regardless of the quality of the
individual technical analyses.

---

## 5. Recommended next action (A/B/C decision tree, per `ez-gh-actions-0jo`)

Bead `0jo` frames the choice as: (A) revert `d6c366d` entirely, (B) stop the daemon now, or (C)
fast-path a grace-window hotfix (~10 min ETA). Given this review's revised root-cause finding:

- **(B) stop-the-daemon** is not warranted — load is safe, the fleet is still nominally at 16/16,
  and Runner.Worker processes are confirmed live and doing real work (`docker top`); this is a
  throughput/efficiency problem, not a safety or outage emergency.
- **(A) full revert** would remove Path 4 (losing the Mac zombie-registration defense it was built
  for, per `0jo`'s own tradeoff note) but would NOT by itself address the watchdog-restart
  interaction — the fleet would still have a real, if less severe, self-outage-prevention-principle
  violation from the watchdog script restarting the daemon aggressively.
- **(C) fast-path grace window is this review's recommendation, with a correction to 0jo's own
  framing**: ship the `5ki` grace-window fix (dominant driver, ~92% of volume per the skeptic's
  independent recomputation) **together with, not instead of,** a watchdog cooldown/consecutive-
  miss-threshold fix (real, ~75% restart correlation, independently worth fixing on
  Self-Outage-Prevention-Principle grounds alone). Shipping only the watchdog fix — which is what a
  literal reading of Track A's remediation note in isolation might suggest — would likely leave the
  fleet still failing the CLAUDE.md 22/22-executing bar.

This decision is the user's / deploy-owner's call per the repo's own single-writer discipline; this
review does not authorize deployment. Separately, this review recommends the deploy-owner also
resolve the bead-hygiene gaps noted in §3 (state container count in P0 bead bodies, file/clarify
the "deploy 5ki once written" ownership, reconcile `u3w`/`s9d` status drift) and consider the
CLAUDE.md-mandated systemic-fix escalation for the respawn/reap subsystem given 7 P0/P1 beads
touching it within 24h.

---

## 6. Minor findings (not requiring action, logged for completeness)

- `/tmp/ezgha-watchdog.log` double-logs every line (both the script's own `tee -a` and the systemd
  unit's `StandardOutput=append:` write the same line) — a cosmetic logging bug, does not affect
  any conclusion above (all timing conclusions were cross-checked against independently-timestamped
  `journalctl` events, not raw log line counts).
- Commit `1a02b36` ("avoid backend restart churn when docker reachable") is unrelated to the
  watchdog-restart mechanism described here — it only touches Colima/Lima backend-selection restart
  logic (`attempt_backend_restart()` in `src/main.rs`), which was checked and ruled out as a
  candidate 4th restart trigger.
