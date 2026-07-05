# What a 50-Subagent Adversarial Workflow Review Missed — and a Single-Context Audit Caught

**Audience**: Anthropic Claude Code team (Workflow tool / multi-agent orchestration patterns).
**Purpose**: A reproducible case study of false negatives in a finders → refuters → judge
adversarial workflow review, with root-cause analysis and concrete recommendations for
improving the built-in workflow quality patterns.

**Repo under review**: https://github.com/jleechanorg/ez-gh-actions
**Code state audited**: commit `3f04937` (HEAD at time of audit; all findings verified at this SHA)
**Date**: 2026-07-03
**Codebase size**: ~1,164 lines of Rust across 7 files (`src/`)

---

## 1. Executive summary

A three-workflow, 50-subagent (~3.4M token) adversarial review pipeline was run over this
project: a 32-agent design review before implementation, a 15-agent `/er` evidence +
code audit after implementation, and a 3-agent re-verdict after fixes. It performed well
on its own terms — 26 confirmed design findings, 2 confirmed critical code bugs (both
fixed), a FAIL verdict on the author's own evidence bundle, and refutation of 3
plausible-but-wrong findings.

A subsequent **single-context adversarial audit** (one agent, whole codebase read
end-to-end, explicitly diffed against the workflow's already-documented findings) found
**5 substantive defects and 4 minor ones that all 50 subagents missed** — including a
fail-open path in the *very disk guard the workflow review had fixed and live-verified*,
and an aggregate-capacity hole that defeats the tool's core purpose.

The misses cluster into four systematic blind spots of the workflow structure, not
random oversights:

1. **Fix-failure-mode blindness** — verifiers confirm a fix does what it claims; nobody
   asks how the fix itself fails.
2. **Aggregate/composition blindness** — per-item lenses miss N× effects.
3. **Silent-cap blindness** — ironically the exact category the Workflow tool's own
   guidance warns about ("no silent caps").
4. **Deployment-environment blindness** — no lens examined installed-service runtime
   conditions (PATH, unit ordering).

Adversarial verification (refuters) is a **false-positive filter. It does nothing for
false negatives** — refuters can only attack findings that finders surfaced, and the
judge only judges what is presented. This report proposes concrete workflow-pattern
additions to close that gap (§6).

---

## 2. What the workflow review was

Three workflows executed via Claude Code's `Workflow` tool (deterministic JavaScript
orchestration; each `agent()` call spawns an independent subagent with fresh context,
its own tools, and a JSON schema its answer must satisfy):

### Workflow 1 — Design review (32 subagents, pre-implementation)
- Phase 1: 4 independent reviewers in parallel over the original design gist:
  `facts` (live web verification of external claims), `architecture` (internal
  soundness), `rust` (Cargo.toml + skeleton defects), `infra-fit` (fit vs. an existing
  battle-tested runner fleet).
- Phase 2: ~28 adversarial verifiers, one per critical/major finding, each instructed
  to **refute** the finding using live GitHub/web data.
- Result: 39 raw findings → 26 confirmed, 2 refuted, 11 minor. Confirmed findings
  materially changed the design (fail-closed isolation policy, disk floor guard,
  TOML over archived serde_yaml, JIT registration, capacity-derived limits).

### Workflow 2 — /er evidence review + code audit (15 subagents, post-implementation)
- 4 parallel auditors: `evidence-provenance` (sha256 + circular-provenance),
  `live-reverify` (re-verified every claim against live GitHub APIs, trusting nothing
  in the bundle), `code-bugs` (hostile Rust review), `security` (injection surfaces,
  container hardening).
- 10 adversarial verifiers → 1 judge.
- Verdict: **FAIL** on a real integrity defect (checksummed file missing from bundle),
  plus 2 confirmed critical code bugs:
  - **C1**: disk floor guard measured the HOST filesystem, not the docker daemon's
    (silently wrong under Colima/Lima/Docker Desktop; ~20× divergence measured live).
  - **C2**: `ezgha stop` deregistered ALL idle `ezgha-*` runners on the target —
    including other hosts' — a fleet-wide outage button in org scope.
- 6 confirmed majors were documented as prioritized known limitations in `DESIGN.md`.

### Workflow 3 — Re-verdict (3 subagents, post-fix)
- Integrity re-audit (13/13 checksums OK) + verification that both critical fixes were
  real in code and live-proven → **PASS**.

Both critical fixes (commit `2e3ac2b`) are genuinely correct *for the cases they
targeted*. That qualifier is the crux of this report.

---

## 3. What the post-hoc single-context audit did differently

Method (one agent, one context window):

1. Read **all 7 source files in full** (~1,164 lines) — the entire codebase fits
   comfortably in one context, so no sharding was necessary.
2. Read `DESIGN.md` "Known limitations (v1)" first and treated it as an exclusion
   list — every already-documented finding was deliberately not re-reported. Everything
   in §4 below is absent from both the workflow's report and `DESIGN.md`.
3. For each function, explicitly asked: *what happens on the error/None/fallback path?*
   *what happens at N× scale?* *what happens in the installed-service environment
   rather than an interactive shell?*
4. Re-verified the workflow review's own factual claims live (checksums, GitHub API
   facts) — those all held up. The gap is exclusively **false negatives**.

Cost comparison: the post-hoc audit was a single agent reading ~1.2k lines — roughly
two orders of magnitude cheaper than the 50-subagent pipeline it audited.

---

## 4. The missed findings

All file:line references are at commit `3f04937`.

### M1 (substantive) — The fixed disk floor guard fails open on its own failure path

`src/docker_backend.rs:196-208`:

```rust
match free_disk_gb(&cfg.runner.image) {
    Some(free) if free < cfg.limits.min_free_disk_gb => {
        bail!("only {free} GB free ... refusing to spawn");
    }
    Some(_) => {}
    None => eprintln!(
        "warning: could not measure daemon free disk — disk floor guard is NOT active this cycle"
    ),
}
// ...proceeds to spawn runners
```

`free_disk_gb()` measures free disk by running `docker run --rm --entrypoint df <image>
-Pk /`. When that probe returns `None`, the code **warns and spawns anyway**.

Why this is not a nitpick:

- Measurement failure **correlates with the guarded condition**. On a nearly-full
  daemon disk, the `docker run` probe itself is what fails (ENOSPC on image pull or
  container create). The guard is most likely to be inactive exactly when it is most
  needed.
- If the configured image lacks a `df` binary (minimal/distroless custom image), the
  guard is **permanently inactive** with only a per-cycle stderr line that, under the
  installed service, nobody reads.
- The project's stated design philosophy — adopted *because of* Workflow 1's findings —
  is **fail-closed**. The backend-selection ladder fails closed; the flagship guard
  does not.

**Why the workflow missed it**: Workflow 2's `code-bugs` auditor found C1 (wrong
filesystem measured) and Workflow 3 verified the fix measured the right filesystem —
live, with a real ~20× host/VM divergence. No agent was ever asked "how does the
*fixed* code fail?" The refuters attacked the finding's validity, not the fix's
completeness.

Tracked as bead `ez-gh-actions-tj2`.

### M2 (substantive) — No aggregate capacity check: `count × limits` can exceed the daemon

`src/docker_backend.rs:50-63` (`effective_limits`) clamps a **single** runner's cpu/mem
to 100% of daemon capacity. `ensure_count` then spawns `cfg.runner.count` runners, each
with those limits. Four runners × 8 GB on a 16 GB Colima VM are each individually
compliant and collectively OOM the daemon VM — **the exact "runaway job takes the host
down" failure mode the tool exists to prevent** (per its own `--about` string and
design doc). Nothing anywhere divides by `count`; `init`'s one-time halving of host
capacity also ignores `count`.

**Why the workflow missed it**: every capacity-related lens (design reviewer, code
auditor, fix verifier) reasoned about **one runner's** limits. Composition across the
fleet on one daemon was in no prompt. This is a lens-taxonomy gap: per-item correctness
lenses cannot see emergent N× effects.

Tracked as bead `ez-gh-actions-vmz`.

### M3 (substantive) — The fleet-wide-stop fix has a residual collision

The C2 fix scopes deregistration to `ezgha-<hostname>-` (`src/docker_backend.rs:143-145`),
but:

- Hostnames are not unique across fleets (cloned VMs, default `ubuntu`, `Mac.local`
  DHCP churn). Two hosts sharing a hostname can still deregister each other's runners.
- `hostname()` (`src/docker_backend.rs:24-31`) falls back to the **literal string
  `"host"`** when the `hostname` command fails — so any two degraded hosts converge on
  the same `ezgha-host-` prefix and recreate the original outage bug.

The fix narrowed the outage button; it did not eliminate it. A persisted per-install
UUID (written into config at `init`) would.

**Why the workflow missed it**: Workflow 3's fix-verification agent confirmed the
prefix was host-scoped (there is even a unit test asserting exactly that,
`docker_backend.rs:221-231`). Verifying "the fix does what it says" is not the same as
adversarially attacking the fix's assumptions ("is hostname a unique key? what does the
fallback do?").

Tracked as bead `ez-gh-actions-1fu`.

### M4 (substantive) — `list_runners` silently truncates at 100

`src/github.rs:74` requests `per_page=100` with no pagination. On an org/repo with more
than 100 registered runners, `ezgha stop` never deregisters runners past page 1 and
`ezgha status` undercounts — silently.

**The irony**: the Workflow tool's own quality-pattern guidance includes, verbatim,
"**No silent caps**: if a workflow bounds coverage (top-N, no-retry, sampling), log()
what was dropped — silent truncation reads as 'covered everything' when it didn't."
The review pipeline that embodies this rule did not carry it as a *code-review lens*,
and so missed a textbook instance in the code under review.

Tracked as bead `ez-gh-actions-5rz`.

### M5 (substantive) — `install-service` produces a PATH-broken service

`src/service.rs:60-94` (launchd) and `:24-58` (systemd --user):

- The launchd plist sets no `EnvironmentVariables`. Default launchd PATH is
  `/usr/bin:/bin:/usr/sbin:/sbin` — it excludes `/opt/homebrew/bin` and
  `/usr/local/bin`, where `docker` and `gh` are typically installed on macOS. The
  installed `serve` daemon therefore cannot find either binary it shells out to.
- `launchctl load -w` errors with "already loaded" on re-run, so re-running
  `install-service` bails (and the API is deprecated in favor of
  `bootstrap`/`bootout`).
- On Linux, `After=docker.service` in a **user** unit is a silent no-op — user
  managers cannot order against system units — and no `Environment=PATH=` is set
  either.

**Why the workflow missed it**: no auditor lens covered "the code as it runs under the
installed service environment." The E2E evidence was produced by running `ezgha`
interactively from a shell (where PATH is fine), so `live-reverify` had no chance to
catch it. Environment fidelity between "how it was tested" and "how it will run" was
nobody's assignment.

Tracked as bead `ez-gh-actions-xh4`.

### M6–M9 (minor)

| # | Finding | Location |
|---|---------|----------|
| M6 | `runner_group_id=1` hardcoded — org scope with non-default runner groups fails or lands runners in the Default group; not configurable, not documented | `src/github.rs:40` |
| M7 | Default runner image is unpinned `ghcr.io/actions/actions-runner:latest` — reproducibility/supply-chain gap for a security-posture tool | `src/config.rs:92` |
| M8 | `ezgha init` silently overwrites an existing config | `src/main.rs:125` |
| M9 | Evidence bundle mixes artifacts from two code states (files 01–08 at `c27d389`, files 09–10 at `2e3ac2b`) under a single `git_sha.txt`; the review's disclosed minor covers the pin *choice* but not the mixed provenance | `evidence/e2e-20260703/` |

Tracked as bead `ez-gh-actions-zyb`.

### What the audit confirmed the workflow got right

For calibration, the post-hoc audit also re-verified the workflow's positive claims and
found **no false positives**: gist arithmetic internally consistent (32+15+3 = 50
agents; 26+2+11 = 39 findings), evidence checksums 13/13 OK, live facts re-checked
(NetwindHQ/gha-outrunner 3★/0 forks; serde-yaml archived; GCE nested-virt claim
correctly qualified to Intel x86), and both critical fixes present and correct for
their targeted cases. The refuter layer works. The gap is entirely on the
finder/coverage side.

---

## 5. Root-cause analysis: why 50 agents missed what 1 caught

### RC1 — Refutation filters false positives; nothing in the pipeline hunts false negatives

The pipeline's adversarial energy points at *findings*: refuters try to kill them, the
judge scores survivors. No stage's incentive is "find what every finder missed." The
closest built-in pattern, the *completeness critic*, was not run — and as usually
prompted ("what's missing — modality not run, claim unverified, source unread?") it
audits *process coverage*, not *code-path coverage*.

### RC2 — Lens taxonomy had four systematic holes

The finder lenses (facts / architecture / rust / infra-fit; provenance / live-reverify
/ code-bugs / security) partition the review by *topic*. All five substantive misses
fall between topics, into *mode*-shaped holes:

| Blind spot | Missed findings | Lens that would have caught it |
|---|---|---|
| Failure modes of error/None/fallback branches | M1, M3 (fallback `"host"`) | "For every `Option`/`Result`/default branch: what happens when it takes the sad path, and does that violate a stated invariant (fail-closed)?" |
| Aggregate/composition at N× | M2 | "Assume every config knob at max and every quantity × count — what breaks?" |
| Silent caps / truncation | M4 | "Find every bounded fetch/list/loop; is the bound disclosed or silent?" |
| Deployment-environment fidelity | M5 | "Trace the code as it runs under the *installed* service env (PATH, unit ordering, cwd), not an interactive shell" |

### RC3 — Fix verification ≠ fix adversarial review

Workflow 3 asked "is the fix real and does it do what it claims?" — and answered
correctly. It never asked "attack the fix": what key does it assume is unique (M3)?
what happens when its measurement fails (M1)? A fix is new code and deserves the same
finder→refuter treatment as the original code; in this pipeline fixes only got the
refuter half.

### RC4 — Sharding cost whole-system coherence on a codebase that fit in one context

Each subagent saw a slice framed by its prompt. The interaction M2 requires
(`config.count` × `effective_limits` × `ensure_number`'s spawn loop, across three
files) and M1 requires (design doc's fail-closed philosophy × one `None` branch) are
cross-cutting. A single context holding all 1,164 lines *plus* the design doc's stated
invariants noticed both in one pass. Fan-out is the right call when the corpus exceeds
one context; here it was pure overhead plus a coherence tax.

### RC5 — Verifying the fix "live" created misplaced confidence

The disk-guard fix was live-proven with a real 20× host/VM divergence — a genuinely
strong proof *of the happy path*. That strength anchored the PASS verdict; nobody
priced in that the sad path had never been exercised. Evidence strength on one branch
is not evidence about the other branches.

---

## 6. Recommendations for workflow quality patterns

Concrete, adoptable additions to the Workflow tool's documented patterns:

1. **Fix-adversary stage** (closes RC3): after any fix is applied, spawn a finder whose
   prompt is *"this fix is wrong or incomplete — prove it"* against the fix diff, not
   just a verifier confirming the fix's claim. Findings feed the normal refuter path.
2. **Mode lenses alongside topic lenses** (closes RC2): ship four reusable finder
   prompts — *sad-path/fallback sweep*, *N×/aggregate sweep*, *silent-cap sweep*,
   *deployment-environment sweep* — and recommend including them in any code-review
   fan-out. Topic lenses find what code does wrong; mode lenses find what code fails to
   do.
3. **Whole-corpus control agent** (closes RC4): when the corpus fits in one context
   (say < 5k lines), always run one un-sharded reviewer over everything in addition to
   the sharded lenses, and diff its findings against theirs. Cheap, and in this case it
   would have been the difference.
4. **False-negative estimator** (closes RC1): the pipeline reported "26 confirmed, 2
   refuted" with no estimate of what it *didn't* find. Two cheap options:
   (a) loop-until-dry on the finder stage (the tool already documents this pattern —
   it was not used here); (b) seeded-canary calibration — plant K known defects, report
   the catch rate alongside the findings.
5. **Invariant-anchored review** (closes RC5 + RC2): extract the design's stated
   invariants first ("fail closed", "a runaway job cannot take the host down") into a
   checklist, then task one agent per invariant with *"find any code path that violates
   this"*. M1 and M2 are both single-invariant violations that no topic lens owned.

---

## 7. Reproduction instructions

> **Note**: §7 describes the original, unblinded repro. A cleaner **blinded protocol
> has since been designed and executed — see §9–§13**, which supersede this section
> for anyone rerunning the experiment. The §7 steps remain valid for verifying the
> findings themselves.

1. **Check out the audited state**:
   ```bash
   git clone https://github.com/jleechanorg/ez-gh-actions
   cd ez-gh-actions && git checkout 3f04937
   ```
2. **Confirm the misses are absent from the workflow's output**: read `DESIGN.md`
   "Known limitations (v1)" (the workflow's confirmed-major list) — none of M1–M9
   appear there or in the review summary gist.
3. **Verify each finding** at the file:line references in §4 (all are static-readable;
   M1 additionally reproduces dynamically by pointing `runner.image` at any image
   without `df` and observing the warn-and-spawn behavior in `ensure_count`).
4. **Repro the workflow gap experimentally**: run a finders→refuters→judge review
   workflow over `src/` with the four *topic* lenses from §2 (architecture, rust
   correctness, security, infra-fit) and check whether M1–M5 surface (in our run, they
   did not). Then add the four *mode* lenses from §6.2 and the invariant-anchored
   prompts from §6.5, and compare. The delta is the measurable improvement.
5. **Calibration check**: also run one single-agent whole-repo review (~1.2k lines in
   one context, prompt: "adversarially review; for every Option/Result branch ask what
   the sad path does; check every quantity times runner count; find silent caps;
   trace the installed-service environment") — this reproduces the audit that caught
   M1–M9.

## 8. Related artifacts

- Review-methodology gist (produced by the original workflow run):
  https://gist.github.com/jleechan2015/3175ea3679efe854b2fd1f21d88df008
- Evidence bundle: `evidence/e2e-20260703/` in this repo (13/13 checksums verify at
  `3f04937`).
- Beads tracking the fixes: `ez-gh-actions-tj2` (M1), `ez-gh-actions-vmz` (M2),
  `ez-gh-actions-1fu` (M3), `ez-gh-actions-5rz` (M4), `ez-gh-actions-xh4` (M5),
  `ez-gh-actions-zyb` (M6–M9) — in `.beads/` in this repo.
- Key commits: `5ef5406` (v1), `c27d389` (daemon-capacity fix), `537e1e5` (E2E
  evidence), `2e3ac2b` (critical fixes C1+C2), `3f04937` (post-fix evidence, audited
  HEAD).

---

# Part II — Blinded reproduction protocol (designed and executed 2026-07-03)

The §7 repro has contamination problems: the answer key (this report, the expanded
`DESIGN.md` limitations, public PR #1) lives in the same repo a fresh reviewer would
read, and any web-enabled agent can find it. §9–§13 define and execute a blinded
version.

## 9. Blinding design

**Blind target**: https://github.com/jleechanorg/ezgha-blind-review (private), whose
`main` is the original repo's history **truncated at `537e1e5`** — the exact tree the
original Workflow 2 audited. At that commit:

- Both criticals (C1 host-vs-daemon measurement, C2 fleet-wide stop) are unfixed.
- `DESIGN.md` has only the 3 pre-review limitations (gh-CLI auth, detect-only VMs, no
  per-job quota) — none of the review's findings.
- No `docs/` directory, no transcripts, no gap report, no fix commits.
- The evidence bundle has the original integrity defect (`git_sha.txt` listed in
  `checksums.sha256` but absent) — the original FAIL condition is reproducible.

Anthropic can reconstruct the identical tree from the public repo with
`git checkout 537e1e5`; the private fork exists so blinded sessions have a clean clone
URL that carries no answer key and is not web-discoverable.

**Contamination controls**:

1. Arm A reuses the original workflow **prompts byte-for-byte** (Appendix A), with
   exactly three mechanical edits, all path/name swaps: `meta.name`, the `REPO`
   constant → the blind checkout path, and the verify-stage prompt's public-repo
   pointer → the blind fork (so no verifier browses the original repo, where PR #1
   contains the answer key). The full diff is 3 lines and is reproduced in §11.
2. Arm B (human-driven single-context session) must be opened **in the blind clone
   directory**. Rationale: project-scoped auto-memory in the operator's usual project
   directory contains an ez-gh-actions entry that leaks the daemon-vs-host lesson
   (C1). A session rooted in the blind clone loads no such memory.
3. Arm B's prompt (Appendix C) is deliberately **neutral** — it does not include the
   mode lenses from §6.2, so it tests "fresh single context, generic adversarial
   prompt" rather than "single context told where to look."
4. The answer key (§13) lives only in the original repo, never in the blind fork.

## 10. Arms

| Arm | What | Tests |
|---|---|---|
| **A** | Original Workflow 2 script, prompts verbatim, run against the blind checkout (executed by this session; results in §12) | Do the false negatives reproduce with the same prompts on the same code? (Variance check on the original run) |
| **B** | Fresh interactive session in the blind clone dir, neutral single-context adversarial prompt (Appendix C), run by the human operator | Does an uninformed single context catch what the workflow missed? (The original single-context audit was prompted only with "review this adversarial and see if anything was missed" — Arm B approximates that, minus this session's accumulated context) |
| **A′** (optional) | Workflow 2 + the four mode lenses and invariant-anchored prompts from §6 | Measures the delta the §6 recommendations buy |

Score every arm against the §13 answer key.

## 11. Arm A mechanical diff (original script → blind run)

```diff
2c2
< name: 'er-ez-gh-actions',
---
> name: 'er-ezgha-blind-repro',
11c11
< const REPO = '/home/jleechan/projects/ez-gh-actions'
---
> const REPO = '<local blind checkout of ezgha-blind-review @ 537e1e5>'
107c107 (verify-stage prompt only)
< (public: github.com/jleechanorg/ez-gh-actions, ...)
---
> (public: github.com/jleechanorg/ezgha-blind-review, ...)
```

## 12. Arm A results

*(Executed 2026-07-03; this section records the blind re-run's findings scored against
§13. Filled in from the workflow's structured output — see the run transcript
directory referenced in the PR.)*

**PENDING AT WRITE TIME — populated in a follow-up commit once the workflow
completes.**

## 13. Answer key at `537e1e5` (keep OUT of the blind fork)

"Caught" = appeared in the original workflow's confirmed output. "Missed" = absent
from all 50 subagents' output, found by the post-hoc single-context audit.

| ID | Finding (at `537e1e5`) | Original run | Applies at blind commit |
|---|---|---|---|
| INT-1 | `git_sha.txt` in `checksums.sha256` but missing from bundle → integrity FAIL | caught | yes |
| C1 | Disk floor guard + limits measure the HOST fs/capacity, not the docker daemon's | caught | yes |
| C2 | `stop` deregisters ALL idle `ezgha-*` runners incl. other hosts' | caught | yes |
| J1 | Crash-looping containers leak JIT registrations, no backoff | caught | yes |
| J2 | `stop` vs installed service race (serve respawns in 30s) | caught | yes |
| J3 | `docker ps --format json` breaks on Docker CLI < 23 | caught | yes |
| J4 | Managed label not target-scoped (two configs miscount) | caught | yes |
| J5 | Hardening gaps: no cap-drop/egress/read-only rootfs | caught | yes |
| J6 | JIT config visible in argv / docker inspect | caught | yes |
| M1 | Disk guard fails open when measurement fails (`if let Some` silently skips — at this commit there is not even a warning) | **missed** | yes |
| M2 | No aggregate check: `count × limits` can exceed daemon capacity | **missed** | yes |
| M3 | Hostname-prefix residual collision + `"host"` fallback | **missed** | no — post-fix only (subsumed by C2 here) |
| M4 | `list_runners` silently truncates at `per_page=100`, no pagination | **missed** | yes |
| M5 | `install-service` PATH-broken under launchd; `After=docker.service` no-op in user unit; `launchctl load -w` re-run failure | **missed** | yes |
| M6 | `runner_group_id=1` hardcoded | **missed** | yes |
| M7 | Default image unpinned `:latest` | **missed** | yes |
| M8 | `init` silently overwrites existing config | **missed** | yes |
| M9 | Evidence bundle mixes two code states under one SHA pin | **missed** | no — post-fix artifact |

Scoring: catch rate over {M1, M2, M4–M8} is the false-negative metric; {INT-1, C1, C2,
J1–J6} is the regression floor (an arm that loses these is strictly worse, not just
differently focused).

---

# Appendix A — Original workflow prompts (verbatim)

Complete scripts (including schemas and orchestration) are committed at
`docs/adversarial-review/workflows/*.workflow.js`. The prompts below are the exact
strings from those scripts. `${GIST}`/`${REPO}`/`${EV}` are path constants defined at
the top of each script.

## A.1 Workflow 1 — design review finder lenses (4 reviewers)

**`facts`**:

> You are a technical fact-checker with web access. Read the design document at
> ${GIST} (a design for "gha-isolated", a Rust CLI wrapping "gha-outrunner" for
> isolated self-hosted GitHub Actions runners). Use WebSearch/WebFetch extensively to
> verify EVERY external factual assumption in the design. Specifically investigate:
> 1. Does a project called "gha-outrunner" actually exist? Search GitHub, crates.io,
> web. If it does not exist or is obscure/unmaintained, that is a CRITICAL finding —
> the whole design wraps it. Check if the author may have meant something else (e.g.
> actions-runner-controller, github-runner projects, "runs-on", ...).
> 2. Tart (tart.run / cirruslabs/tart) licensing: is it free for this use? (Fair
> Source / paid tiers — what are the actual limits as of 2026?)
> 3. GitHub "Scale Sets": runner scale sets are an Actions Runner Controller (ARC /
> Kubernetes) concept — can a standalone CLI use scale sets without k8s? Or should the
> design say "ephemeral runners + JIT config" instead?
> 4. GCE nested virtualization: the design claims GCE has "no strong KVM" — but GCE
> supports nested virtualization on most x86 machine types. Verify.
> 5. Sysbox status in 2026: Docker acquired Nestybox; is Sysbox CE maintained?
> Kernel/distro requirements?
> 6. serde_yaml crate: deprecated/archived? What's the recommended replacement?
> 7. Any well-established existing tools that already do what gha-isolated proposes
> (e.g. cirruslabs gitlab/github runner tart executors, RunsOn, actuated, garm
> (Cloudbase GitHub Actions Runner Manager), ARC, ubicloud, warpbuild, etc.) — is this
> reinventing an existing wheel?
> Report each as a finding with evidence URLs. Be precise about what you could and
> could not verify.

**`architecture`**:

> You are a senior infrastructure architect reviewing a design doc. Read ${GIST} — a
> design for "gha-isolated", a Rust CLI that wraps "gha-outrunner" to run isolated
> self-hosted GitHub Actions runners (Tart VMs on macOS, libvirt on Linux,
> Docker+Sysbox fallback). Review the ARCHITECTURE for gaps and design flaws. Consider
> at minimum:
> - Runner registration/auth: the design never mentions GitHub PAT/GitHub App tokens,
> JIT runner config, registration token lifecycle, or repo/org scoping. How do runners
> actually register?
> - VM image management: where do Tart/libvirt guest images come from? Versioning,
> updates, disk usage, caching of toolchains inside images?
> - Ephemeral lifecycle: who destroys VMs after a job? Crash recovery, orphan cleanup,
> disk-space reclamation?
> - Backend selection: is 'has_kvm => libvirt' a sane default? libvirt setup burden vs
> docker on a typical Linux box. Is silent fallback to plain Docker (weakest
> isolation) acceptable, or should it require explicit opt-in ("fail closed vs fail
> open" on isolation)?
> - Resource limits: hardcoded 4G/2cpu/count:2 — how should host capacity be
> reflected? What about disk limits (the most common runner failure mode)?
> - Config: written to cwd as outrunner.yml — should be XDG/user config dir; no schema
> versioning; no secrets handling story.
> - Observability: status, logs, health checks, alerting hooks.
> - Security: job-to-host escape surface per backend, docker.sock exposure, network
> egress policy, secrets in env.
> - Service management: launchd/systemd story is 'not yet implemented' but is
> essential for real use.
> Rate each gap by severity. Do NOT fact-check external tools (another reviewer does
> that); focus on the design's internal completeness and soundness.

**`rust`**:

> You are a Rust reviewer. Read the design + skeleton code at ${GIST}. Review the
> Cargo.toml and skeleton Rust code for concrete issues:
> - Dependency choices: serde_yaml (archived?), sysinfo pulled in but barely used
> (System::new_all + refresh_all just to detect OS — wasteful), duct vs std::process,
> missing deps for the stated scope (e.g. tokio? tracing? directories/xdg?
> thiserror?), version pinning.
> - Code issues: config generation via format! string templating vs typed structs +
> serde (the design itself lists 'better config model' as future work — should be v1);
> Platform detection via cfg! at runtime vs compile time; /dev/kvm existence check
> doesn't verify permissions (user must be in kvm group); backend.rs 'assume Sysbox is
> installed' comment is a landmine; std::fs::write("outrunner.yml") writes to cwd;
> error handling; missing service.rs and limits.rs despite being in the module table
> (module table lists 7 files, main.rs declares only 4 mods).
> - Structure: suggest what a credible v1 module layout and trait design would be
> (e.g. a Backend trait with detect/validate/start/stop implemented per backend).
> Report concrete findings with severity.

**`infra-fit`**:

> You are reviewing how a proposed new tool fits an existing codebase. The proposal
> (read it at ${GIST}) is "gha-isolated": a Rust CLI for isolated self-hosted GitHub
> Actions runners (Tart on macOS, libvirt on Linux, Docker+Sysbox fallback), wrapping
> a tool called gha-outrunner.
> The repo at ${REPO} ALREADY runs self-hosted GitHub Actions runners. Explore:
> - ${REPO}/self-hosted-oss/ (read README.md, install.sh header comments,
> docker-compose.yml, pre-job-hook.sh, heal-runners.sh, mac-runner-health.sh,
> LINUX_HOST_POLICY.md, linux/ subdir)
> - ${REPO}/self-hosted-colima/ (README.md, docker-compose.yml, scripts/)
> - Recent git log in that repo mentioning runners (git -C ${REPO} log --oneline -20)
> Summarize: (1) what the existing runner setup does today (platforms, isolation
> level, resource limits, health/healing, disk cleanup, launchd/systemd wiring); (2)
> which pain points the existing setup has that gha-isolated would genuinely solve;
> (3) which hard-won operational lessons in the existing scripts (disk cleanup pre-job
> hooks, health thresholds, colima VM sizing, cache integrity checks, Slack alerting)
> are MISSING from the gha-isolated design and must be carried over; (4) whether a new
> Rust binary is justified vs extending the existing bash/compose setup — give an
> honest assessment. Also note the repo CLAUDE.md rule that self-hosted runner changes
> must be in git and reproducible via install.sh.

**Workflow 1 verifier template** (one per critical/major finding):

> Adversarially verify this finding about a design doc (the doc is at ${GIST}; the
> repo is ${REPO}; you may use WebSearch/WebFetch and read files). Try to REFUTE it.
> Finding from the "${f.from}" reviewer, severity ${f.severity}:
> TITLE: ${f.title}
> DETAIL: ${f.detail}
> RECOMMENDATION: ${f.recommendation}
> Is the finding factually correct and does the recommendation make sense? If the
> factual basis is wrong or the severity is inflated, refute it. Default to
> refuted=true only if you have concrete contrary evidence or the claim is unsupported
> after checking.

## A.2 Workflow 2 — /er audit lenses (4 auditors) — **the run that missed M1–M9**

**`evidence-provenance`**:

> You are a skeptical evidence auditor (/er style — zero tolerance for assertions
> without raw proof). Audit the evidence bundle at ${EV} (files: EVIDENCE.md,
> 01_init.txt..08_status_after_job.txt, config.toml, checksums.sha256).
> Checks: (1) run `cd ${EV} && sha256sum -c checksums.sha256` — any failure is a
> critical finding. (2) Circular provenance: is any claim supported only by an
> artifact the claim itself generated, or do independent artifacts corroborate (e.g.
> container ID in 04_status_before_job.txt vs hostname in 07_job_log.txt — these come
> from different systems: local docker vs GitHub's job log)? (3) Internal consistency:
> runner name, container id, limits (5977MB=6267338752 bytes? do the math), timestamps
> ordering. (4) Do the artifacts actually show what EVIDENCE.md claims, line by line?
> (5) Anything that smells fabricated or copy-pasted. Report findings with severity;
> if the bundle is sound say so explicitly in the summary.

**`live-reverify`**:

> You are an independent verifier with live access. Re-verify the E2E claims of
> ${EV}/EVIDENCE.md against LIVE GitHub state — do not trust the bundle:
> (1) `gh run view 28685531107 -R jleechanorg/ez-gh-actions --json
> status,conclusion,headSha,event,workflowName` — confirm success, workflow_dispatch,
> workflow name ezgha-selftest.
> (2) `gh run view 28685531107 -R jleechanorg/ez-gh-actions --log | grep -E 'runner
> name|hostname|6267338752|pids'` — confirm the runner name
> ezgha-Jeff-Ubuntu-6a4833a11c652b and cgroup values appear in GitHub's own logs.
> (3) `gh api repos/jleechanorg/ez-gh-actions/actions/runners` — confirm 0 lingering
> runners (ephemeral cleanup claim).
> (4) `gh api
> repos/jleechanorg/ez-gh-actions/commits/5ef5406779925598565c8d277d13b865db78947a
> --jq .sha` and confirm the repo at github.com/jleechanorg/ez-gh-actions has the
> claimed code (spot-check src/docker_backend.rs on main for
> --memory/--cpus/--pids-limit flags via gh api or git -C ${REPO} show).
> (5) Check the CI workflow runs on main: `gh run list -R jleechanorg/ez-gh-actions -w
> CI --json conclusion,headSha -L 3` — all green?
> Any mismatch between bundle claims and live state is a critical finding. Report
> PROVEN/mismatch per claim in your summary.

**`code-bugs`** (the lens that owned M1–M4, M6–M8's territory):

> You are a hostile Rust code reviewer. Review ALL source at ${REPO}/src/ (main.rs,
> platform.rs, backend.rs, config.rs, github.rs, docker_backend.rs, service.rs) plus
> Cargo.toml for REAL bugs that would bite in production: incorrect error handling,
> race conditions (e.g. serve loop vs stop, ensure_count counting
> exited-but-not-removed containers), wrong docker/gh CLI usage (flag syntax, output
> parsing fragility — docker ps --format json availability, df parsing), edge cases
> (count>1, org scope, config with cpus exceeding daemon after VM resize, memory-swap
> semantics), the unique_suffix collision risk, stop_all deregistering OTHER hosts'
> ezgha-* runners (org/multi-host hazard), managed_containers missing exited
> containers still holding registrations. Only report defects with a concrete failure
> scenario. Severity by impact.

**`security`**:

> You are a security reviewer. Review ${REPO}/src/ and the workflows in
> ${REPO}/.github/workflows/ for security issues: (1) command construction — can
> config values (target, labels, image) inject arguments into gh/docker invocations?
> Note std::process::Command passes args as vectors (no shell), but leading-dash
> argument injection into docker/gh flags is still possible — check each. (2) JIT
> config exposure via docker inspect / process listing — evaluate the documented
> tradeoff honestly. (3) Runner container hardening: what's missing (network egress,
> read-only rootfs, seccomp)? Is no-new-privileges + cgroup limits + no docker.sock
> accurate per the code? (4) Public-repo self-hosted runner risk: selftest.yml is
> workflow_dispatch-only — is anything else triggerable by forks? Is CI (ci.yml) on
> ubuntu-latest (safe)? (5) service.rs: unit/plist content injection via exe path?
> Report findings with severity and concrete attack scenarios.

**Workflow 2 verifier template**:

> Adversarially verify this finding about the repo at ${REPO} (public:
> github.com/jleechanorg/ez-gh-actions, evidence at ${EV}, run ${RUN_URL}). Try to
> REFUTE it by reading the actual code/evidence and, where relevant, live gh queries.
> Finding from "${f.from}" (${f.severity}): ${f.title}
> ${f.detail}
> Refute if the factual basis is wrong, the scenario cannot occur, or severity is
> inflated (severity inflation alone -> not refuted, but say so).

**Workflow 2 judge prompt**:

> You are the final /er evidence-review judge for ez-gh-actions v1 (repo ${REPO},
> evidence ${EV}, live run ${RUN_URL}).
> Auditor summaries: [injected]
> Confirmed critical/major findings after adversarial verification: [injected]
> The claims under review: (1) ezgha starts a real ephemeral JIT runner with hard
> cgroup limits; (2) a real GitHub Actions job executed on it; (3) the runner
> deregistered and container cleaned up after the job; (4) limits were enforced
> (memory.max/pids.max inside the job); (5) unit tests + CI green.
> Rules: checksum failure or live-state mismatch = FAIL. Confirmed critical
> evidence-integrity finding = FAIL. Confirmed critical code bug does NOT fail the
> evidence claims but must appear in reasoning. Produce a claim-by-claim table and
> overall PASS/PARTIAL/FAIL.

**Observation for Anthropic**: the `code-bugs` prompt *names specific suspicions*
(unique_suffix collision, stop_all cross-host hazard, exited-container counting) —
seeded by the orchestrating session's own hunches. The subagent dutifully investigated
those and caught C2, but the named-suspicion framing plausibly *narrowed* exploration:
everything named got checked; the un-named modes (sad-path branches, aggregates,
pagination, service env) went unexamined. A finder prompt that enumerates suspicions
trades breadth for the orchestrator's priors.

## A.3 Workflow 3 — re-verdict prompts

Committed at `docs/adversarial-review/workflows/3-er-reverdict.workflow.js`: an
integrity re-auditor (re-runs `sha256sum -c`, checks `git_sha.txt` now present and
sane), a fix verifier (confirms both critical fixes in code and against live state),
and a judge (same FAIL rules as A.2's judge). No net-new finder ran in Workflow 3 —
that is RC3 in §5.

# Appendix B — The post-hoc single-context audit (this report's source)

**Operator prompt, verbatim** (the entire task specification the auditing session
received):

> review this adversarial and see if aything was missed

(accompanied by the review-methodology gist pasted in the message). No lenses, no
checklist, no file list were provided by the operator.

**What the session actually did**, reconstructed from its transcript:

1. Fetched the gist; checked its arithmetic (32+15+3=50; 26+2+11=39).
2. Located the local repo; read **all 7 source files in full** (~1,164 lines) in one
   context, plus `Cargo.toml`.
3. Read `DESIGN.md` "Known limitations (v1)" first and used it as an exclusion list —
   only never-documented findings were reported.
4. Applied three recurring questions per function: *what does the error/None/fallback
   branch do, and does it violate a stated invariant (fail-closed)?* — *what happens
   at N× (× count, × fleet, × >100 runners)?* — *what happens in the installed-service
   environment rather than an interactive shell?*
5. Re-verified the workflow's positive claims live (`sha256sum -c` 13/13; gh API
   checks on gha-outrunner and serde-yaml; `git_sha.txt` parentage) before reporting
   any gap.

Result: M1–M9 in ~15 tool calls with zero false positives against the original run's
output. The honest caveats: the auditor had (a) the gist summarizing what the workflow
already found — steering it toward *unclaimed* territory, and (b) generic operational
familiarity with self-hosted-runner failure modes from the surrounding project. Arm B
(§10) exists to measure how much of the result survives without (a)'s specificity and
with a different context.

# Appendix C — Arm B: paste-ready prompt for the human's fresh window

Run this in a **new session whose working directory is a fresh clone of the blind
fork** (not the original repo, and not a directory whose project memory mentions this
project):

```
git clone https://github.com/jleechanorg/ezgha-blind-review ~/tmp/ezgha-blind-arm-b
cd ~/tmp/ezgha-blind-arm-b
claude
```

Then paste:

> Adversarially review this repository for real defects that would bite in
> production. Read every source file in full before reporting. For each finding give
> file:line, a concrete failure scenario, and a severity (critical/major/minor). Do
> not use web search or fetch anything from the network except commands I explicitly
> approve; work only from this checkout. Report everything you find, including
> findings you suspect the authors already know.

Rules for the operator: do not hint at categories, do not mention any prior review,
do not paste this report. When the session finishes, score its findings against §13
and record catch/miss per row, plus any *novel* findings not in the answer key (those
extend the answer key after verification).

# Appendix D — Materials index for Anthropic

| Artifact | Where |
|---|---|
| Blind fork (target `537e1e5`) | https://github.com/jleechanorg/ezgha-blind-review (private; same tree as `git checkout 537e1e5` of the public repo) |
| Original workflow scripts + schemas | `docs/adversarial-review/workflows/` (this repo) |
| Original per-agent transcripts (all 3 runs) | `docs/adversarial-review/transcripts/` |
| Original structured results | `docs/adversarial-review/results/` |
| Arm A blind re-run script (3-line diff from original) | §11; script derived mechanically via sed |
| Answer key + scoring sheet | §13 (this file only — never in the blind fork) |
| Single-context audit method | Appendix B |
| Arm B operator protocol | Appendix C |
