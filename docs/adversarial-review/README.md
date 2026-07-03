# How the ez-gh-actions adversarial review was done

Project: https://github.com/jleechanorg/ez-gh-actions — an isolated ephemeral GitHub Actions
runner CLI, built 2026-07-03 from a design gist, reviewed and verified by multi-agent
workflows before and after implementation.

## Forensic artifacts in this directory

Everything needed to audit — or re-run — the review is committed here:

| Path | Contents |
|---|---|
| [`inputs/original-design-gist.txt`](inputs/original-design-gist.txt) | The original `gha-isolated` design that was reviewed |
| [`workflows/1-design-review.workflow.js`](workflows/1-design-review.workflow.js) | Workflow script: 4 reviewers → adversarial verifiers (32 agents) |
| [`workflows/2-er-audit.workflow.js`](workflows/2-er-audit.workflow.js) | Workflow script: /er audit — 4 auditors → refuters → judge (15 agents) |
| [`workflows/3-er-reverdict.workflow.js`](workflows/3-er-reverdict.workflow.js) | Workflow script: post-fix re-verdict (3 agents) |
| [`results/*.result.json`](results/) | Full structured result of each workflow (confirmed/refuted findings, verdicts, per-agent progress + token counts) |
| [`transcripts/<workflow>/journal.jsonl`](transcripts/) | Per-workflow journal: one record per completed `agent()` call with its exact return value |
| [`transcripts/<workflow>/agent-*.jsonl`](transcripts/) | **Full per-subagent conversation transcripts** — every prompt, tool call, tool result, and final structured output (50 subagents) |
| [`transcripts/<workflow>/agent-*.meta.json`](transcripts/) | Per-subagent metadata (model, timing) |
| [`REPRODUCE.md`](REPRODUCE.md) | How to re-run the same adversarial review on this repo |
| [`checksums.sha256`](checksums.sha256) | Integrity manifest over every artifact in this directory |

**Sanitization disclosure** (forensic honesty): the committed transcripts differ from the
raw originals in exactly two mechanical ways, applied by a scripted sanitizer and then
independently audited by two fresh subagents before publication:

1. Claude Code's injected context attachments were dropped from every transcript —
   `skill_listing` (the operator's private skill inventory) and `deferred_tools_delta`
   (the operator's private MCP tool inventory): 100 attachment records total.
2. Tool outputs containing verbatim file contents from a *private* repository
   (worldarchitect.ai self-hosted runner scripts, read by the `infra-fit` reviewer and
   its verifiers) were replaced with an explicit `[REDACTED for publication: ...]`
   marker — in both the in-message `tool_result` blocks and the harness's duplicate
   top-level `toolUseResult` field; 68 records across 103 files.

The first sanitizer pass missed 13 relative-path reads and the `toolUseResult`
duplicates; the pre-publication audit (itself a 2-agent workflow) caught both, and this
final version was re-verified to contain zero unredacted private-repo tool outputs.
References to private script *names* inside prompts and reviewer analysis are retained
deliberately — the findings quoting them are published in `results/` regardless. No
findings, reasoning, verdicts, or ez-gh-actions content were altered. E2E runtime
evidence lives separately in [`/evidence/e2e-20260703/`](../../evidence/e2e-20260703/).

## Was it a subagent? An agent? A workflow?

**All three, layered — but the orchestration mechanism was the Workflow tool.**

- **Workflow**: a JavaScript orchestration script executed by Claude Code's `Workflow`
  tool. The script deterministically controls fan-out, phases, and data flow
  (`parallel()`, `phase()`, `agent()` calls). The main Claude session wrote the script;
  the runtime executed it in the background.
- **Subagents**: every `agent(prompt, {schema})` call inside the workflow script spawned
  an independent Claude subagent with its own fresh context, its own tool access
  (file reads, `gh` CLI, live web search), and a JSON schema its answer had to satisfy.
  Subagents could not see each other's work — that independence is the point.
- Not a single monolithic "Agent task": no one agent produced the review. Three separate
  workflows ran, totaling **50 subagents / ~3.4M tokens**.

The adversarial structure: **finders → refuters → judge.** Every critical/major finding
from a reviewer was handed to a *separate* verifier subagent whose explicit instruction
was to **try to refute it** by reading the actual code/evidence and querying live GitHub.
Only findings that survived refutation counted. This kills plausible-but-wrong findings
that a single reviewer (or a single big-context agent) happily asserts.

---

## Workflow 1 — Design review (before writing any code)

**32 subagents.** Phase 1 ran 4 independent reviewers in parallel over the original
`gha-isolated` design gist:

| Reviewer | Lens | Tools used |
|---|---|---|
| `facts` | Verify every external claim | Live web search/fetch |
| `architecture` | Internal completeness/soundness | Doc analysis |
| `rust` | Cargo.toml + skeleton code defects | Code reading |
| `infra-fit` | Fit vs. the existing battle-tested runner fleet | Repo exploration, git log |

Phase 2 spawned one adversarial verifier per critical/major finding (~28 verifiers).
**Result: 39 raw findings → 26 confirmed, 2 refuted, 11 minor.**

Headline confirmed findings that changed the design:

1. **`gha-outrunner` exists but is bus-factor-1** (NetwindHQ/gha-outrunner: 3 stars,
   0 forks, 1 maintainer) — and the gist's assumed interface didn't match the real tool.
   → Decision: build self-contained, wrap nothing.
2. **"GCE has no strong KVM" is factually wrong** — GCE supports nested virtualization
   on Intel x86 machine types.
3. **serde_yaml is archived/deprecated** → TOML + typed serde structs.
4. **Backend selection failed open** (silent downgrade to weakest isolation) →
   fail-closed `minimum_isolation` policy.
5. **Hardcoded 4G/2cpu limits** → capacity-derived defaults.
6. **`/dev/kvm` existence ≠ usable** (kvm group perms) → open() check.
7. **Zero disk-management story** — the #1 incident class in the existing fleet →
   disk floor guard.
8. **No registration/auth design at all** in the original → JIT config via `gh` CLI.

Notably refuted (the process working in both directions): "no ephemeral lifecycle
design" was thrown out because the original doc explicitly delegated lifecycle to the
wrapped tool — a fair reading a hostile reviewer missed.

## Workflow 2 — /er evidence review + code audit (after implementation & E2E)

**15 subagents**: 4 parallel auditors → 10 adversarial verifiers → 1 final judge.

| Auditor | What it did |
|---|---|
| `evidence-provenance` | `sha256sum -c`, circular-provenance analysis, internal math checks |
| `live-reverify` | Re-verified every claim against **live GitHub APIs**, trusting nothing in the bundle |
| `code-bugs` | Hostile Rust review of all sources |
| `security` | Injection surfaces, container hardening, public-repo runner posture |

**Verdict: FAIL** — despite all 5 substantive claims being PROVEN against live GitHub
(real run 28685531107, cgroup `memory.max`/`pids.max` visible inside the job, full
ephemeral cleanup), the bundle failed its own integrity check: `git_sha.txt` was listed
in `checksums.sha256` but missing from the committed bundle. Checksum failure = FAIL,
no exceptions.

The code audit also confirmed **2 critical bugs** (both then fixed):

1. **Disk floor guard measured the HOST filesystem** at the daemon's path — silently
   failing open when docker runs in a VM (Colima/Lima/Docker Desktop). Verified live:
   host showed ~494 GB free while the daemon VM had ~25 GB (~20x divergence). Fix:
   measure from *inside* a container (`docker run --rm --entrypoint df <image> -Pk /`).
2. **`ezgha stop` deregistered ALL idle `ezgha-*` runners** on the target — other
   hosts' runners included; in org scope, a fleet-wide outage button. Fix: scope to
   `ezgha-<hostname>-` prefix.

Confirmed majors (documented as prioritized known limitations in DESIGN.md): crash-loop
JIT-registration leak, stop-vs-service race, `docker ps --format json` on CLI <23,
non-target-scoped managed label, missing cap-drop/egress/read-only hardening, JIT
credential in argv. One security finding was **refuted** by its verifier (dash-prefixed
image value: docker fails closed, the claimed impact can't occur).

## Workflow 3 — Re-verdict after fixes

**3 subagents**: integrity re-audit (13/13 checksums OK) + fix verification (both
criticals confirmed real in code *and* live-proven) → judge.

**Final verdict: PASS.** One disclosed minor remains: `git_sha.txt` pins the mid-run fix
commit rather than the original commit-under-test (direct parent, both SHAs disclosed).

## Why this beats one big review prompt

- **Independence**: reviewers can't anchor on each other; verifiers can't anchor on the
  finder's confidence.
- **Live ground truth**: verifiers re-queried GitHub instead of trusting artifacts —
  which is exactly how the missing-checksum-file and the honest-but-unproven narrative
  line got caught.
- **Refutation as the default stance**: 2 design findings + 1 security finding were
  killed; the 26 that survived were worth acting on.
- **The verdict had teeth**: the first /er run FAILED the author's own work on a real
  defect, forcing a fix before the PASS.
