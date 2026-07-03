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
