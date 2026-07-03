# Reproducing the adversarial review

The review was executed by [Claude Code](https://claude.com/claude-code)'s **Workflow**
tool: a JavaScript orchestration script in which every `agent(prompt, {schema})` call
spawns an independent subagent with fresh context, its own tool access, and a JSON
schema its answer must satisfy. The scripts in [`workflows/`](workflows/) are the exact
scripts that ran; each script's `meta.name` matches the `workflowProgress` records in
the corresponding `results/*.result.json`, which also carries per-agent IDs that map
1:1 to the `transcripts/<workflow>/agent-<id>.jsonl` files.

## Prerequisites

- Claude Code with the Workflow tool available (multi-agent orchestration enabled).
- `gh` CLI authenticated (`gh auth login`) — the /er audit re-verifies claims against
  live GitHub APIs.
- A clone of this repo.

## Re-running each workflow

The scripts reference absolute paths from the original session. Adjust two kinds of
constants at the top of each script, then ask Claude Code to run the script with the
Workflow tool (e.g. "run the workflow script at <path>"):

1. **`workflows/1-design-review.workflow.js`** — reviews the *original design*, not this
   repo. Point `GIST` at [`inputs/original-design-gist.txt`](inputs/original-design-gist.txt)
   in your clone. The `infra-fit` reviewer's `REPO` pointed at a private repository
   (worldarchitect.ai) you won't have; either drop that reviewer or point it at your own
   runner infrastructure — the other three reviewers (facts, architecture, rust) are
   fully reproducible. Note: the `facts` reviewer does live web research, so its findings
   reflect the state of the world when run (e.g. gha-outrunner's star count).

2. **`workflows/2-er-audit.workflow.js`** — set `REPO` to your clone path and `EV` to
   `<clone>/evidence/e2e-20260703`. The `live-reverify` auditor queries the real run
   ([28685531107](https://github.com/jleechanorg/ez-gh-actions/actions/runs/28685531107))
   and this repo's runners endpoint via `gh` — those live checks reproduce as long as
   GitHub retains the run.

3. **`workflows/3-er-reverdict.workflow.js`** — same two constants. Re-runs the
   integrity re-audit (`sha256sum -c`) and the fix verification (reads
   `src/docker_backend.rs`, runs `cargo test` / `clippy`, and performs the live
   host-vs-daemon `df` divergence check) before issuing the final verdict.

## The adversarial pattern (if you want to apply it elsewhere)

```
Phase 1  N independent reviewers, parallel, disjoint lenses, schema-forced findings
Phase 2  one verifier per critical/major finding, prompted to REFUTE it,
         with live ground-truth access (code, gh API, web)
Phase 3  a judge that only sees auditor summaries + surviving findings,
         with hard rules (e.g. "checksum failure = FAIL, no exceptions")
```

The two properties that made it work: **independence** (no reviewer sees another's
output; verifiers are told to kill findings, not confirm them) and **live ground truth**
(verifiers re-query GitHub/the filesystem instead of trusting artifacts — which is how
the missing `git_sha.txt` and the host-vs-daemon disk bug were caught).

## Verifying the artifacts you're looking at

```bash
cd docs/adversarial-review && sha256sum -c checksums.sha256
```

Each `transcripts/<wf>/agent-*.jsonl` is a complete subagent conversation: the exact
prompt (first `user` record), every tool call and result, and the final `StructuredOutput`
call carrying the finding/verdict JSON. `journal.jsonl` in the same directory maps each
`agent()` invocation to its return value; `results/*.result.json` is the whole workflow's
structured output including per-agent token counts and timings.
