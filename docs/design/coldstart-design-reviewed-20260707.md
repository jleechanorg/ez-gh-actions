# ezgha cold-start elimination — design v2 (2026-07-07, post-adversarial-review)

## Changes from v1 (both reviewers independently converged)
v1's per-slot persistent writable _work volume is REMOVED — it reintroduced the
stateful-runner attack surface ephemeral runners exist to prevent: `clean:true`
never touches .git/hooks, .git/config (core.hooksPath/fsmonitor/sshCommand), so a
low-trust PR job could plant RCE for the next job on that slot (privilege
escalation when a privileged main job lands there); plus named-volume concurrency
races; plus checkout-v6 credentials under RUNNER_TEMP persisting. All replaced by
read-only + pre-seed patterns below. Shared writable pip cache also removed
(untrusted-writer surface).

## Measured problem (unchanged)
Setup = 62-97% of self-hosted job wall-clock; checkout 33-185s/job; deps install
53-58s; respawn/re-register gap 30-60s per job cycle. Hundreds of jobs/day.

## C1v2 — daemon-owned READ-ONLY git mirror + pre-seeded ephemeral workspace
1. ezgha maintains a bare mirror per configured repo on the HOST:
   ~/.cache/ezgha/mirrors/<owner>-<repo>.git — `git fetch --prune` on a timer
   (serve-tick integrated, ~5 min). `gc.auto=0`; no auto-prune (object-removal
   races with concurrent readers); periodic manual repack documented.
2. docker_backend bind-mounts the mirror READ-ONLY at /ezgha/mirror/<repo>.git.
3. Container entrypoint (BEFORE runner job pickup, i.e., inside the existing
   30-60s respawn/registration window): `git clone /ezgha/mirror/<repo>.git
   <workspace>/<repo-dir>` — local disk-to-disk, seconds; then
   `git remote set-url origin https://github.com/<owner>/<repo>`.
   actions/checkout detects the existing repo in the workspace and does
   incremental fetch (network transfers only objects newer than mirror head,
   typically tiny) + reset/clean. Job-visible checkout: 100s → expected <10s.
4. Workspace stays fully EPHEMERAL — created fresh in each container, destroyed
   with it. No cross-job writable state anywhere:
   - mirror is read-only to containers (bind-mount :ro) → un-poisonable by jobs
   - fresh .git per job → no hook/config persistence
   - no named volumes → no concurrency races
5. Fallback semantics: if mirror is missing/stale/corrupt, entrypoint skips
   seeding (log line); checkout does its normal full clone — behavior identical
   to today. Mirror is purely an accelerator; correctness never depends on it.
6. Mechanism note: clone-from-local-mirror was chosen over
   GIT_ALTERNATE_OBJECT_DIRECTORIES because fetch negotiation is ref-driven — a
   fresh init with alternates but no refs still downloads a near-full pack;
   local clone transfers objects at disk speed AND establishes refs so the
   subsequent network fetch is a true delta. (--dissociate not needed: the clone
   hardlinks/copies from a local path by default, making the workspace
   self-contained; verify hardlink behavior across the bind-mount during the
   spike — if git falls back to alternates-style sharing, add --dissociate.)

## C2v2 — wheelhouse baked into runner image (not installed tools)
Dockerfile.runner gains /ezgha/wheelhouse containing wheels for the pinned CI
toolchain (ruff==0.8.4, mypy==1.13.0) + worldarchitect.ai requirements*.txt set;
container env PIP_FIND_LINKS=/ezgha/wheelhouse. Workflows keep their existing
pip install steps and repo requirements remain AUTHORITATIVE — pip resolves
pinned versions from the local wheelhouse (~5s) and transparently falls back to
PyPI for anything not present (no drift trap: a stale wheelhouse only loses
speed, never correctness). Weekly image rebuild cron refreshes wheels.

## C3v2 — dropped (was shared writable pip cache)
Wheelhouse covers the win; per-container pip cache dies with the container
(default behavior, fine). No shared writable surfaces.

## Quick win alongside (worldai-side, separate small PR)
fetch-depth: 1 is already used by most workflows; audit stragglers + add
--filter=blob:none where full history isn't needed. NOTE: branch
chore/ci-fast-checkout exists (another session) — diff it FIRST; if it already
implements this, adopt/land theirs instead.

## Rollout
1. Spike (1 job): hand-run the entrypoint seed on one Mac runner container;
   measure checkout step before/after via job-level step timing.
2. Implement in ezgha behind [runner] git_mirror = true (default false):
   mirror maintenance in serve tick + :ro mount + entrypoint seed script.
3. Enable Mac fleet (we own it); 24h soak w/ step-timing comparison.
4. Offer to Linux via jeff-ubuntu mission (their single-writer config).
5. C2v2 image rebuild after C1v2 soak (isolate measurement).

## Expected win (same measured baseline)
Presubmit-family jobs 2.3-4.6m → ~0.7-1.5m. Checkout 100s→<10s; deps 55s→~5s.
Fleet-wide: equivalent of +5-10 runners, zero hardware, zero new attack surface
(strictly fewer writable surfaces than v1).

## Security invariants (explicit, testable)
- No container may hold a WRITABLE mount shared with any other container (test:
  docker inspect all ezgha containers, assert mounts are :ro or container-local).
- Mirror updates run on the host as the daemon user; containers cannot write it.
- Workspace lifetime == container lifetime (test: respawn slot, assert workspace
  inode gone).

---
# v3 amendments (post v2 re-review, Reviewer A gates + verified answers)

## A — Runner scope (VERIFIED: org-scoped, config target = "jleechanorg")
Pre-seed cannot know the assigned repo (JIT registration precedes job assignment).
Resolution: OPPORTUNISTIC seeding — config `[runner] seed_repos = ["jleechanorg/worldarchitect.ai"]`
(the repo carrying ~95% of job volume, measured). Entrypoint seeds exactly the
configured repos into their expected `_work/<repo>/<repo>` paths. Jobs for any
other repo behave exactly as today (checkout full-clones). Seed is an accelerator
for the dominant path, never a correctness dependency. Multi-repo seeding = just
more entries, each a few seconds of local disk copy.

## B — Mirror fetch NEVER inline in serve tick (fleet-drain incident class)
Mirror maintenance runs as a SPAWNED subprocess with hard timeout (30s kill,
same bounded spawn/poll/kill helper as restart_command, src/main.rs:329) +
single-flight guard (skip if previous fetch still running) + due-time check.
The serve tick's critical path only reads a "fetch due/running?" flag — O(1),
no network. This is the queue_monitor::SERVE_LOOP_TIME_BUDGET lesson applied
at design time.

## C — Automated bounded mirror maintenance + guaranteed dissociation
- Workspace seeds MUST be self-contained: entrypoint clone uses `--dissociate`
  explicitly (do not rely on hardlink heuristics across bind-mounts); spike
  asserts `test ! -s .git/objects/info/alternates` post-clone.
- BECAUSE seeds are self-contained, mirror repack/prune cannot corrupt in-flight
  jobs → maintenance is safe to automate: weekly `git repack -ad + pack-refs`
  + `git gc --prune=2.weeks.ago`, guarded by the same single-flight lock as
  fetch, with a size cap check (if mirror > configured GB, log CRITICAL).
  Caller: the daemon's own timer (not "documented manual" — automation-
  completeness rule).

## D — Seed-consumption metric (anti-silent-regression)
Entrypoint writes a marker (seed SHA + timestamp) into the workspace; a serve-
tick counter (or doctor.sh check) samples completed-job checkout step durations
weekly: if median checkout > 30s while seeding is enabled, WARN loudly —
detects silent fall-back to full clone (path/origin mismatch, checkout behavior
change) during soak instead of months later.

## E — Concurrent clone from a mid-fetch mirror (codex v2 finding #1)
A `git clone` from the bare mirror while the daemon's `git fetch` is writing new
packs into it is NOT guaranteed consistent (clone may see a half-written pack /
ref). Two-part fix:
- Mirror writer publishes atomically: fetch into the mirror, then the daemon
  exposes a read-only SNAPSHOT for containers. Cheapest correct form: keep the
  bare mirror private to the daemon; after each successful bounded fetch,
  `git clone --bare --local` (or hardlinked cp) into a versioned dir
  mirror.<epoch>.git and atomically flip a `current` symlink; containers mount
  `current` (:ro). In-flight clones hold the old snapshot dir open (unlinked but
  not freed until they exit) — POSIX-safe. Old snapshots reaped by the same
  maintenance timer once no reader holds them (mtime + no-open-fd check).
- This makes reader isolation total: containers never touch a mutating object
  store, so item C's repack/prune runs only on retired snapshots.

## F — checkout reuse invariants (codex v2 finding #4) — SPIKE MUST PROVE ALL
Before any fleet rollout, the 1-job spike asserts every one of these, else the
seed is discarded silently by checkout and we regress to full-clone:
- origin URL byte-matches what checkout expects (https://github.com/<owner>/<repo>
  — no .git suffix, no trailing slash; verify against checkout's url-helper).
- workspace path == GITHUB_WORKSPACE == _work/<repo>/<repo> exactly.
- UID/GID of seeded files == the runner job user (seed runs as same user, or
  chown in entrypoint); else checkout hits dubious-ownership.
- `git config --global --add safe.directory <ws>` set in the image for the job
  user (checkout also sets this, but seed touches .git first).
- auth: seed leaves NO credential in .git/config (rewrite origin to bare https,
  strip any extraheader); checkout injects the job token itself.
- runner/checkout version floor: pin minimum actions/checkout in the assertion;
  if worldai pins an older checkout that `git init`s unconditionally, seed is
  moot — verify actual version in the spike.
- GHES N/A (github.com only).
Metric D catches any of these regressing silently post-rollout.

## G — wheelhouse claim softened (codex v2 finding #5)
Drop the absolute "only loses speed never correctness". Precise claim: wheelhouse
is platform/Python-scoped (built FROM the runner image so ABI matches) and
version-pinned to the CI toolchain; pip still resolves repo requirements as
authoritative via PIP_FIND_LINKS (local-first, PyPI fallback). If a repo requires
a version/platform not in the wheelhouse, pip fetches it from PyPI (slower, still
correct). The wheelhouse is rebuilt in the same Docker build as the image so it
can never be ABI-mismatched. NOT a substitute for lockfile hash-checking where a
workflow already does `pip install --require-hashes` — those are unaffected.

## Review status
v1 REVISE (opus+codex, .git-poisoning) → v2 REVISE (opus: scope/tick-drain/GC;
codex: concurrent-clone/checkout-invariants) → v3 addresses all. Awaiting v3
APPROVE from both before swarm-stage parallel adversarial review + implementation.

## Build-time notes (Reviewer A v3 APPROVE — watch items, folded in)
1. Mirror BOOTSTRAP (first-ever full `git clone --mirror`, minutes) uses a
   SEPARATE unbounded/long budget path — NOT the 30s incremental-fetch kill
   helper (which would kill it forever = accelerator never turns on). Bootstrap
   is a one-time init step (out-of-band or generous timeout); only steady-state
   incremental fetch uses the 30s bounded path.
2. Size-cap CRITICAL must REMEDIATE not just log: wire the over-cap signal into
   doctor.sh AND trigger a forced aggressive repack on the retired snapshot;
   logging alone violates automation-completeness on this disk-sensitive fleet.

## FINAL REVIEW STATUS
- Reviewer A (opus): v1 REVISE → v2 REVISE → **v3 APPROVE (high confidence)**.
- Reviewer B (codex, cross-model): v1 REVISE → v2 REVISE → v3 pending.
Proceed to swarm-stage parallel adversarial review once codex v3 verdict is in.

## v3.1 — codex v3 REVISE points (2 sharp catches folded, opus already APPROVE)
Codex v3 verdict REVISE; 2 of its 4 points are genuinely correct and change the design:

H. "restart_command helper reference" is WRONG — that helper (main.rs:329) is
   spawn+poll+KILL and BLOCKS its caller up to 30s. Citing it for mirror
   maintenance would put a 30s stall INTO the serve tick = the exact drain class.
   CORRECTION: mirror maintenance (fetch + snapshot-flip + repack) runs on a
   DEDICATED std::thread (or tokio task) spawned once at daemon start, looping on
   its own timer, fully OFF the serve loop. The serve tick only reads an
   AtomicBool/Instant ("fetch running? / last success when?") — never spawns,
   never joins, never waits. The 30s timeout applies to the git subprocess
   INSIDE that dedicated thread, not to anything the tick touches.

I. Workspace pre-creation collision — org-scoped runner pre-seeds
   _work/<repo>/<repo> BEFORE the job's repo is known. If the assigned job IS a
   seeded repo, checkout must ACCEPT the pre-existing dir; if it's a DIFFERENT
   repo, the runner creates its own _work/<other>/<other> and our seed sits
   unused (fine). SPIKE MUST PROVE: (a) the actions/runner does not wipe or
   choke on a pre-populated _work/<repo>/<repo> at job start; (b) no path
   collision when the SAME runner runs seeded-repo then other-repo jobs across
   its ephemeral life; (c) the seed dir ownership/permissions don't block the
   runner's own workspace setup. If (a) fails, move seeding from container-start
   to a checkout-wrapper/composite-action on the worldai side instead.
   Codex points 3 (dissociate/local-race) and 4 (disk-drain) already covered by
   E + build-note-2; no change.

## REVIEW LEDGER (final)
v1: opus REVISE + codex REVISE (.git-poisoning RCE) →
v2: opus REVISE (scope/tick-drain/GC) + codex REVISE (concurrent-clone/checkout-invariants) →
v3: opus APPROVE (high conf, 2 build notes) + codex REVISE (blocking-helper/workspace-precreation) →
v3.1: both codex REVISE points folded (H dedicated thread, I spike gates).
Net: 11 distinct flaws caught across 2 model families + 3 rounds. Design is
implementation-ready with H/I as spike gates. → proceed to SWARM parallel review.
