# Mac runner outage saga — root-cause synthesis (2026-07-14 → 2026-07-20)

**Status:** fix shipped, deployed, and live-verified. This doc is the durable
record of a saga that unfolded across four layered incidents, each masking or
setting up the next, so a future reader does not have to re-derive it from
scattered bead notes and session transcripts.

## Layer 1 — the 2026-07-14 outage cascade (five stacked causes)

A Mac reboot triggered a chain where each fix (or non-fix) masked the next
problem:

1. **Colima stale-state** after the reboot.
2. **Watchdog printed its own remediation but never ran it.** The deployed
   `ensure_colima_running()` on a Colima start failure logs `try 'colima stop
   --force && colima start'` and returns — it never executes the command.
   The fleet sat down for 3h16m on 2026-07-14 and hit the same class of
   failure on 2026-07-07. Worse, the launchd plist invoked a stale, divergent
   221-line copy of the watchdog script living outside this repo, not the
   repo's own 451-line `scripts/ezgha-fleet-watchdog.sh` (which has no Colima
   remediation logic at all). Tracked as **bead `jleechan-yib3`, still OPEN**.
3. **A hardcoded 40GB disk floor**, originally tuned for a jeff-ubuntu OOM
   fix, flapped against this Mac's normal 35-46GB free range. Recalibrated,
   then superseded by a config-driven redesign.
4. **Missing `ezgha-runner:latest` image.** The daemon's disk-probe fails
   with "image missing" whenever the image is absent, and nothing rebuilds it
   automatically. Root-cause investigation later disproved the original
   "VM recreation" trigger for the 2026-07-14 occurrence (basedisk/diffdisk
   birth times were unchanged) and instead found the real vector: a weekly
   `com.jleechan.cleanup-docker.plist` launchd job runs `docker image prune
   -af` every Sunday and had already deleted images twice before (logged
   699.7MB removed 2026-06-28, 567.7MB removed 2026-07-05). `install.sh` now
   rebuilds the image automatically on install, which partially mitigates
   this, but nothing rebuilds it automatically after a *later* prune event
   with no install run in between. Tracked as **bead `jleechan-kobt`, still
   OPEN** (partially mitigated, not closed); the prune-cron exclusion itself
   is a separate bead, `jleechan-h30q`.
5. **Dual-Colima-instance conflict.** Tracked as **bead `ez-gh-actions-apye`,
   still OPEN** (jeff-ubuntu-specific; see bead for the ghd2.6 acceptance
   criteria PR #56 did not address).

## Layer 2 — the Colima disk-churn problem (2026-07-17/18, bead `jleechan-93cf`)

Ephemeral runner containers had zero host mounts, so every job's
checkout/build scratch lived in the container's throwaway writable overlay
layer, inflating Colima's sparse disk file. Measured: one runner alone
reached 1.7GB writable-layer size; the VM's disk allocation hit ~56GiB while
actual guest-used space was ~7GiB. This is documented in more detail in
`docs/design/disk-churn-reduction-swarm-20260717.md`.

**Fix:** `runner.workspace_host_path` config field bind-mounts a real host
directory at `/home/runner/_work`, keeping checkout/build scratch off the
ephemeral overlay. Shipped as commit `d43e941`.

**Process gap that enabled Layer 3:** the bead's own acceptance criteria
required validation against 6 concurrent real jobs sustained for 30 minutes
of churn before shipping. That validation was never completed — the bead
notes explicitly recorded the acceptance criteria as "still open" — while the
feature was simultaneously live in production config. It shipped on the
strength of a synthetic single-file-write test only.

## Layer 3 — the regression this fix introduced (2026-07-19)

`tar` extraction of an archive containing a **symlink** corrupts the symlink
into an unreadable 0-byte mode-000 file (`Cannot open: Permission denied`)
when the destination is the virtiofs-backed workspace mount on Colima/Mac.
Confirmed live with `actions/setup-python`'s own tarball (which the GitHub
Actions runner extracts into `_work/_actions` when downloading the action).
A plain `ln -s` on the mount works fine; extraction into the container's own
overlay filesystem works fine; only tar-extracting a real archive onto
virtiofs corrupts symlink members. This matches upstream reports: Docker for
Mac issue #6277, Apple `container` issue #1209, and Podman issue #28817 —
this is a known virtiofs/FUSE-class limitation, not something specific to
this repo's code.

This broke `actions/setup-python`, `setup-node`, and `setup-gcloud` (all
download-and-extract their own action repo, which contains symlinks) at a
**41% (13/32) Mac job failure rate for roughly 1-2 days** before being
caught.

### Why it took 1-2 days to catch

1. Pre-deploy validation for the workspace-mount feature (Layer 2) was a
   synthetic single-file write test, not a real job — as noted above, the
   bead's own acceptance criteria were left "still open" and skipped anyway.
2. **No job-success-rate monitor existed anywhere in this repo's health
   tooling.** `doctor-runner` measures container *activity*
   (EXECUTING/IDLE/DOWN), never job *outcome* — so a fleet failing 75-100% of
   the jobs it actually picks up read as perfectly healthy the entire time.
   This is the single biggest structural gap the whole saga exposed (see
   "Prevention" below).
3. A separate, independently-discovered bug in `doctor-runner`'s own TOML
   parser made the health check itself unreliable during this exact window.
   Live `count = 6 # RESIZED 2026-07-13 ...` inline comments were parsed by
   stripping every non-digit character from the *entire* right-hand side,
   producing a garbage huge number (e.g. `620260713...`) that fed a `seq`
   loop and hung the doctor script for 2+ minutes. Fixed in commit
   `eecd8cff969ed0c8c042114dd6280db9ddbc0021` (centralized both count
   consumers on Python's `tomllib`, added inline-comment regression tests,
   fixed the `set -o pipefail`/SIGPIPE issue in the new host-pressure
   section). Confirmed present in the current `doctor-runner` (uses
   `tomllib.load(...)["runner"]["count"]`, line 57).

### Reconciling the "read-only dirs" claim

A concurrent session's finding described the bug more broadly, as "any
action archive containing read-only dirs," and pointed at a not-locally-found
bead `rev-0lh8w`. Direct investigation (independent live repro, retained
fixture at `~/.cache/ezgha-laneb-readonly-20260718-01`) established:

- `rev-0lh8w` does not exist in this repo's bead DB or in any of 43 scanned
  worldarchitect.ai bead DBs — its exact notes are an evidence gap, not a
  trusted input.
- The "read-only dirs" framing does **not** reproduce in isolation:
  mode-0555 directories and mode-0444 files extract successfully everywhere
  (overlay fs, raw virtiofs mount, tmpfs-shadowed dirs).
- The real mechanism is the same symlink-in-tar-extraction corruption
  described above, and it is **broader than the originally-shipped fix**:
  any tar extraction of an archive containing symlinks into the
  **checkout path** (`_work/<owner>/<repo>`, which the first fix did not
  cover) still corrupts symlinks identically. Reproduced live with a
  synthetic npm-style `node_modules/.bin/pkg -> ../pkg_bin` archive.
- Real-world exposure of the unfixed checkout-path gap: `npm ci`/`npm
  install`, Python wheel/venv installs, downloaded release tarballs, `docker
  save`/`load`, and git submodule tarballs extracted via `tar` were all still
  exposed. A separate live probe using the actual runner image's Node/npm
  disproved one part of the original PR description's claim that npm/pip/
  Docker "don't shell out to tar" for these paths in general — but that
  distinction turned out not to matter for the fix strategy chosen below,
  since the wrapper approach intercepts the PATH-level `tar` binary
  regardless of which callers use it.

## Layer 4 — the fix, in three adversarially-reviewed rounds

**Fix (part 1 — runner-internal cache dirs, commit `0d5a802`):** the daemon
tmpfs-shadows the three fixed runner-internal cache dirs (`_actions`,
`_temp`, `_tool`) inside the workspace mount, so the runner's own
action/tool-cache extraction never touches virtiofs. TDD: Layer 1 unit test
(`workspace_mount_shadows_actions_temp_tool_with_tmpfs`) + Layer 2 real-Docker
test (`tests/workspace_mount_symlink_extraction_test.sh`). This fix was
narrow by design — it only covered the three runner-internal cache dirs, not
the checkout path.

**Found incomplete:** the checkout-path reconciliation above proved
`_work/<owner>/<repo>` (where `actions/checkout` and any subsequent
tar-based install step operate) remained fully exposed. Two candidate wider
fixes were evaluated:

1. Tmpfs-shadow `_work/<owner>/<repo>` too — simple, but reintroduces the
   original Layer 2 disk-churn problem, since checkout/build scratch is the
   highest-volume directory the workspace mount exists to keep off the
   ephemeral overlay (confirmed against bead `jleechan-93cf`'s own
   measurements).
2. A `tar` wrapper shimmed into the runner image's `PATH`: stage extraction
   on tmpfs/overlay, then `cp -a` (a safe, symlink-preserving syscall path)
   into the virtiofs destination. Preserves the disk-churn win and fixes
   symlink corruption for every tar-based extraction into the mount, at the
   cost of new surface on a production-critical path.

Option 2 was chosen, since it's the only one that fixes the bug without
undoing the Layer 2 disk-churn win.

**Fix (part 2 — checkout path, `docker/tar-workspace-wrapper.sh`), three
revisions:**

- **v1 (commit `243e1a5`):** naive stage-then-copy tar wrapper baked into
  `Dockerfile.runner` at `/usr/local/bin/tar`, gated by a new
  `EZGHA_VIRTIOFS_WORKSPACE=1` env var the daemon sets whenever
  `workspace_host_path` is configured. TDD Layer 1 + Layer 2 green.
- **First adversarial review** (independent teammate) found two real bugs
  (a path-boundary false-positive matching `/home/runner/_workevil`; staging
  into an empty directory defeated `--keep-old-files` collision protection)
  plus a documentation overclaim (the original PR description implied
  npm/pip/Docker were affected by shelling out to PATH tar — a live probe
  using the real runner image's npm disproved this for the direct-library
  case, though it doesn't change the fix's necessity for genuine `tar`
  invocations).
- **v2** fixed those two bugs, but a further check found v2's "only stage
  when destination is empty" restriction never actually engages in
  production: real jobs run `actions/checkout` first, so `_work/<owner>/
  <repo>` is essentially always already populated by the time any other
  step tar-extracts something. v2 would have shipped a fix that does not fix
  anything in the realistic case.
- **v3 (commit `4970b5e`):** redesigned as mirror-then-sync — pre-existing
  destination content is mirrored into the tmpfs stage first (a no-op for a
  fresh destination), the real tar runs in the stage, the stage is `cp -a`'d
  back onto the real destination, and tar's real exit code is propagated.
  This fixes the realistic populated-checkout case while still preserving
  `--keep-old-files`/collision semantics, since GNU tar's own
  collision/overwrite logic now sees the same pre-existing files in the
  stage it would see extracting in place. Same commit also fixed **bead
  `jleechan-krow`** (see below) since it was a small, well-understood,
  already-RED-tested one-liner blocking the shared test suite. 319/319 cargo
  tests pass, clippy clean, Layer 2 real-Docker suite 7/7 (mode-000 checks
  downgraded to informational — see "known accepted gaps" below).
- **Second, separately-spawned adversarial review** of v3's mirror logic
  found a third real bug: GNU tar supports **multiple `-C`/`--directory`
  occurrences** in one invocation, each scoping only the members listed
  after it. The wrapper collapsed every `-C` into a single trailing `-C
  "${stage}"` placed after all member names; GNU tar silently ignores a
  trailing `-C` with nothing after it, so it extracted relative to its
  inherited cwd instead — `rc=0` (looks successful) while both real
  destinations ended up empty. This is **worse** than a loud failure: silent
  success with misplaced output. Fixed in **commit `16ae5fc`** by detecting
  2+ `-C`/`--directory` occurrences up front and bailing out to native tar
  unmodified before any staging (see the "EXPLICIT CARVE-OUT" comment in
  `docker/tar-workspace-wrapper.sh:114`). Verified live: wrapped and
  unwrapped tar now produce byte-for-byte identical output for this
  invocation shape. 319/319 unit tests, clippy clean, Layer 2 suite 8/8.

**Bead `jleechan-krow` (fixed in the v3/`4970b5e` commit):** the first
adversarial review round also found that the part-1 tmpfs shadows
(`_actions`/`_temp`/`_tool`) used Docker's default tmpfs mount options,
which include `noexec` — but `_tool` stores installed tool runtimes (e.g.
`setup-python`'s Python binary) that the job then executes directly from
that path. Without `:exec`, those runtimes failed with `rc126 Permission
denied` even though extraction itself succeeded. Fixed by adding `:exec` to
all three tmpfs mount option strings (`src/docker_backend.rs:2163`,
confirmed present in current `main`). **This bead should be closed** — see
bead triage below.

**Known accepted gaps (documented, not fixed, genuinely out of scope):**

1. An archive member whose stored mode blocks even owner-read (mode 000)
   fails to sync from the tmpfs stage back to the real destination, since
   `cp` cannot re-read a file with zero permission bits — universal
   non-root Unix behavior on any filesystem, not virtiofs-specific.
2. Separately, mode-000 archive members fail to extract even via direct,
   unwrapped tar on this virtiofs mount, reproducing even as root — an
   already-broken-natively virtiofs/FUSE limitation, unrelated to this fix.

Neither blocks the symlink fix — real CI archives essentially never contain
owner-unreadable members. The shared test file's mode-000 check was
rescoped from a hard pass/fail gate to informational/diagnostic, matching
the existing convention for a similar check earlier in that same test file.

### Deployment and live verification (both rounds)

Both `4970b5e` and `16ae5fc` were deployed via the single-writer discipline
(`cargo install --path .` + `launchctl kickstart -k gui/501/org.jleechanorg.ezgha`)
per an explicit standing user directive not to gate routine deploys on this
Mac's chronic elevated load average (89-131 1-min avg observed at deploy
time, well above the repo's documented ≤12 restart-safety threshold — the
directive was scoped to this saga's deploys specifically, not a blanket
policy change). Each deploy recycled one confirmed-idle runner to get a
genuinely fresh post-restart container, then verified via `docker inspect`
(`EZGHA_VIRTIOFS_WORKSPACE=1` present, tmpfs shadows show `:exec`) and a real
functional test inside the live container — extracting a symlink-containing
tar archive into a pre-populated checkout-path destination (simulating
post-`actions/checkout` state) and confirming both correct symlink
extraction and preservation of pre-existing content, checked both inside the
container and directly on the host-side virtiofs mount. `doctor-runner`
confirmed the fleet fully healthy (6/6 Mac, 10/10 Linux) after each deploy.
This fix has now survived **three independent adversarial review rounds,
each of which found and fixed a real, distinct bug** — a durable example of
the review process working as designed, and a reason a future reader
touching this file again should keep testing live rather than trusting the
header comment's claims at face value (the comment says this explicitly).

## Layer 5 — prevention: what's actually built vs. still needed

**Built:**

- **Job-outcome monitor** (`scripts/job_outcome_monitor.py` +
  `tests/job_outcome_monitor_test.py`, commit `8a745e8`). Implements a
  bounded, exact-runner-prefix-attributed sample of recently *completed* job
  conclusions (not just container activity), with an explicit created-run
  time window, a 75-second whole-probe monotonic deadline, and honest
  `UNKNOWN` verdicts on API/parse/truncation/insufficient-sample conditions
  rather than a false-healthy default. 11/11 focused tests pass. **This is
  the actual missing piece the saga exposed** — a fleet failing every job it
  picks up previously read as healthy under `doctor-runner`'s
  activity-only model.
  - **Real gap, not yet closed:** this script is a standalone, unscheduled
    primitive. It is not invoked by any launchd job, cron entry, or
    `doctor-runner` section, and is not referenced anywhere else in the
    repo (verified: no matches for `job_outcome_monitor` outside its own
    script/test pair, no launchd plist, no crontab entry). Tracked as
    **bead `jleechan-frzq`, open**, which explicitly scopes the remaining
    scheduler + doctor-cache-consumption integration work.
- **`doctor-runner` section 6b, host-resource-pressure** (top CPU consumers,
  load-vs-core-count, correlation with the daemon's own "docker CLI timed
  out" log frequency), plus the TOML count-parser fix, shipped together in
  commit `eecd8cff969ed0c8c042114dd6280db9ddbc0021`.
- **Three rounds of adversarial review, each catching a real, distinct
  bug** in the checkout-path tar-wrapper fix — demonstrated as a genuinely
  effective process for risky changes to this daemon, worth reusing
  deliberately (not just opportunistically) the next time a change touches
  `docker_backend.rs`'s container-start or mount path.

**Still open / needs an explicit "won't fix now" call or continued
tracking** (bead triage detail below): `jleechan-yib3` (watchdog never
executes its own remediation, plus a stale divergent deployed copy),
`jleechan-kobt` (image rebuild only on manual `install.sh` run, not
automatic after a later prune event), `ez-gh-actions-apye` (dual-Colima
instance conflict, jeff-ubuntu-specific), and a `doctor-runner` gate-tuning
issue where the Mac-specific real-execution check can read `0/6` purely
because a small sample of recent selftests happened to route entirely to
the Linux host in that window — a routing-coincidence false negative, not
an actual failure, confirmed by manually checking that all 6 sampled runs
in that window actually succeeded.

## Layer 6 — meta-lesson: the harness itself drifted mid-mission

During this multi-day, multi-lane mission, the sidekick/swarm skill files
that govern how this kind of long-running investigation should be run were
themselves found to be stale: an earlier lane operated under a policy
("in-session teammate is default") that did not actually match the skill
file it had loaded, and has since been corrected to explicitly ban
tmux-based and `codex exec -p`-based sidekicks entirely in favor of named,
in-session Agent-Team teammates. This synthesis doc itself is being written
under the corrected policy. It's included here as a concrete, dated example
of harness drift causing an agent to follow stale instructions in good
faith — worth checking for on any future multi-day mission that spans a
harness-skill edit in the middle of it.

## Bead triage (final state as of this doc)

| Bead | Status | Disposition |
|---|---|---|
| `jleechan-yib3` | OPEN (P0) | Left open — accurately describes a live, unresolved defect (watchdog prints but never runs its remediation; deployed plist points at a stale divergent script). No change made. |
| `jleechan-kobt` | OPEN (P1) | Left open — accurately describes a partially-mitigated defect (`install.sh` rebuilds the image at install time only; no automatic rebuild after a later prune event). No change made. |
| `ez-gh-actions-apye` | OPEN (P0) | Left open — jeff-ubuntu-specific dual-Colima acceptance criteria not yet met by PR #56. No change made. |
| `jleechan-pl2t` | CLOSED (already, prior to this doc) | Correctly closed as an invalid/stale-contract finding once `/Users/jleechan/roadmap/nextsteps-2026-07-12-ezgha-10-runner-host-availability.md` was found recording an operator-selected 10-runner Jeff-Ubuntu contract. Superseded by `jleechan-f621`. |
| `jleechan-f621` | CLOSED (already) | Correctly closed — the 10-Linux-runner contract was reconciled into `CLAUDE.md`/`AGENTS.md`/config examples/`code-standards.md` in commit `952d2ae`, confirmed live in `CLAUDE.md:7`. |
| `jleechan-krow` | **OPEN → should be CLOSED by this doc's author** | The `:exec` fix landed in commit `4970b5e` (confirmed live at `src/docker_backend.rs:2163`, deployed and live-verified twice). Being closed as part of this triage pass. |
| `jleechan-frzq` | OPEN (P1) | Left open — accurately describes the real remaining gap (job-outcome monitor exists but is unscheduled and unintegrated). No change made. |
| `jleechan-yn2o` | OPEN (P1, resumption bead) | Being closed by this doc's author once this doc and the bead triage are committed and pushed — see STATE.md Next Actions. |

## Evidence index (for future verification)

- Outage cascade: bead `jleechan-yib3`, `jleechan-kobt`, `ez-gh-actions-apye`.
- Disk-churn fix: `docs/design/disk-churn-reduction-swarm-20260717.md`, bead
  `jleechan-93cf`, commit `d43e941`.
- Symlink regression + part-1 fix: commit `0d5a802`,
  `tests/workspace_mount_symlink_extraction_test.sh`.
- Checkout-path widened fix: commits `243e1a5` → `4970b5e` → `16ae5fc`,
  `docker/tar-workspace-wrapper.sh`, `CLAUDE.md` "Workspace mount + virtiofs
  symlink extraction bug" section.
- Doctor host-pressure + count-parser fix: commit
  `eecd8cff969ed0c8c042114dd6280db9ddbc0021`.
- Job-outcome monitor: commit `8a745e8`, `scripts/job_outcome_monitor.py`,
  `tests/job_outcome_monitor_test.py`, bead `jleechan-frzq`.
- Fleet-contract reconciliation (16→22... →10 Linux/16 total): commit
  `952d2ae`, bead `jleechan-f621`, bead `jleechan-pl2t` (closed, superseded).
