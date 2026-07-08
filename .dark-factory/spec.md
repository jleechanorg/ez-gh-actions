# spec.md — Process guardrail: prevent reactive-cascade / house-of-cards fix accretion

Goal: codify the four reactive-cascade prevention rules in `~/.claude/CLAUDE.md`
(second-fix-means-stop, audit-on-root-cause-change, ground-truth-before-declaring-
success, complexity-budget checkpoint) into a durable, machine-checkable harness
that fires BEFORE the next compensating fix is written or shipped.

This is a **brownfield** change. The four rules already exist as prose
guidance in `~/.claude/CLAUDE.md` and as one captured memory
(`feedback_2026-07-08_reactive_cascade_po2_watchdog.md`). The work is to turn
that prose into executable harness artifacts in this repository (CLAUDE.md
additions, a CI-skill `guardrail-precommit` script, and a CI workflow that
runs the script on every PR), plus wire it to a callable trigger so it is not
documentation-only.

## Brownfield classification

- Greenfield: NO. The four rules are already documented.
- Brownfield: YES. We are modifying three existing surfaces in the
  `jleechanorg/ez-gh-actions` repository:
  1. `CLAUDE.md` — add a "Reactive-cascade guardrail" section pointing
     agents at the new harness artifacts.
  2. A new `scripts/guardrail-precommit.sh` script (does not yet exist).
  3. `.github/workflows/guardrail.yml` (does not yet exist) that calls
     the script on every PR.

- Step-0 deletion/migration plan: none required. There is no pre-existing
  script to delete. The new artifacts are strictly additive. The CLAUDE.md
  addition is documentation; it does not delete or alter the existing
  "Reactive-cascade / house-of-cards prevention" prose, it cross-references it.

## Non-goals

- Replacing the existing prose in `~/.claude/CLAUDE.md`. The prose stays;
  the harness is a *machine* version of the same rules.
- Detecting reactive cascades that are already in production. The
  guardrail fires on the *next* PR's diff and on the *next* commit message,
  not retroactively.
- Auto-rejecting a PR. The guardrail emits structured findings; humans
  decide whether to proceed. A PR that triggers the guardrail is not
  a CI failure — it is a review signal.
- Replacing human judgment on whether a fix is "compensating." The
  guardrail surfaces the question; the agent and reviewer answer it.
- Cross-repo coverage. The script is wired into this repo's CI only.
  Other repos can copy the script but that's out of scope.

## Acceptance criteria

Each AC is a deterministic check a reviewer can run or observe.

1. `scripts/guardrail-precommit.sh` exists, is executable, and exits 0
   on a clean commit/PR. Verify: `test -x scripts/guardrail-precommit.sh && scripts/guardrail-precommit.sh HEAD; echo $?`.
2. The script exits 1 and emits a structured finding (one line starting
   with `GUARDRAIL:`, JSON or key=value) on a commit whose diff message
   contains a "compensating" keyword (`revert`, `compensate`, `patch the
   patch`, `workaround for the workaround`, `relax the ceiling we just
   raised`, or `tune the limit we just set`) when that commit is the
   *third-or-later* commit in the same PR touching the same file.
   Verify: create a 3-commit branch where commit 3 raises a threshold in
   `src/config.rs` and commit 1 already touched the same line; run the
   script; assert exit 1 and at least one `GUARDRAIL:` line.
3. The script flags any commit message that contains the phrase
   `deployed and working` and the prior commit on the same branch is
   <5 minutes old (ground-truth-before-declaring-success rule).
   Verify: create a 2-commit branch with a 1-minute gap where commit 2
   says `deployed and working`; assert exit 1 and a `GUARDRAIL:` line
   citing the time delta.
4. The script greps for every "X exists because we set Y to Z" comment
   in `src/` whenever any commit in the PR raises a threshold/limit/
   rate/toggle/ceiling. If a match is found in a non-test file, the
   script emits a finding (audit-on-root-cause-change rule).
   Verify: seed a comment `// x exists because limit was 10` in src/foo.rs
   and a PR commit that changes `10` to `20`; assert exit 1 and a
   `GUARDRAIL:` line naming the file and line number.
5. The script refuses to run the same root-cause change (same file, same
   function) three times in a single PR without a `DECISION:` line in a
   commit body explaining why a 3rd change is correct vs deletion
   (second-fix-means-stop + complexity-budget).
   Verify: create a 3-commit branch where commits 1, 2, 3 all modify
   `src/docker_backend.rs::spawn`; assert exit 1 with a `GUARDRAIL:`
   line on the 3rd commit.
6. `.github/workflows/guardrail.yml` exists, is syntactically valid
   YAML, and triggers on `pull_request` events for this repo.
   Verify: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/guardrail.yml'))"`.
7. The workflow calls the script on every PR and uploads its output as
   a workflow artifact named `guardrail-report`. Verify: open the
   workflow file and confirm a `actions/upload-artifact` step references
   `guardrail-report`.
8. `CLAUDE.md` (this repo) gains a new section "Reactive-cascade
   guardrail" that points at `scripts/guardrail-precommit.sh` and the
   workflow file. The new section cross-references the existing
   "Reactive-cascade / house-of-cards prevention" prose in
   `~/.claude/CLAUDE.md` rather than duplicating it.
   Verify: `grep -c "Reactive-cascade guardrail" CLAUDE.md` returns >= 1.
9. The harness has a caller. The CI workflow is the auto-trigger
   (criterion 7). No script in this PR is added without a caller.

## Implementation plan

Single lane. No parallel work.

1. Add `scripts/guardrail-precommit.sh`. The script is shell + `git`
   (no extra runtime deps). It walks the PR's commit list via
   `git log origin/main..HEAD --format=%H` and applies rules 2–5 above.
   Findings are emitted to stdout in `GUARDRAIL: key=value` form
   (one per line) so the CI workflow can parse them mechanically.
2. Add `.github/workflows/guardrail.yml` that runs the script on every
   `pull_request` event, captures stdout to a file, and uploads it as
   the `guardrail-report` artifact. The workflow does NOT fail the PR
   on guardrail findings — it is a review signal. The PR status check
   is `neutral` or `success` regardless of findings.
3. Append a "Reactive-cascade guardrail" section to this repo's
   `CLAUDE.md` that:
   - names the four rules (one bullet each),
   - points agents at the script and the workflow,
   - cross-references the canonical prose in `~/.claude/CLAUDE.md`
     so the prose is the source of truth and the script is the
     machine version.
4. Add unit tests under `tests/test_guardrail_precommit.sh` that cover
   AC 2, 3, 4, 5 with synthetic git repos (use `git init` in a temp
   dir, not the live repo).

## File-ownership matrix

Single lane — no ownership matrix needed.

## Deterministic test command

```bash
bash tests/test_guardrail_precommit.sh
```

A reviewer can run this on a clean checkout; the script builds four
synthetic mini-repos in a temp dir, exercises each rule, and asserts
the expected exit codes and `GUARDRAIL:` line counts.

## Overlap pre-flight

```bash
git diff --name-only origin/main...HEAD
```

(Run once before opening the PR; should show only `scripts/`,
`.github/workflows/`, `CLAUDE.md`, `tests/`.)

## Public behavioral expectations

From the visible spec (what other agents and humans will read):

- A PR that contains a 3rd change to the same root-cause function in
  `src/` without a `DECISION:` line will get a `GUARDRAIL:` finding
  uploaded to the PR's `guardrail-report` artifact. The PR is not
  blocked; reviewers are expected to read the artifact.
- A PR whose commit message says `deployed and working` within 5
  minutes of the prior commit will get a `GUARDRAIL:` finding
  citing the time delta.
- A PR that raises a threshold/limit/ceiling in `src/` will trigger
  a grep for "X exists because we set Y to Z" comments in the same
  file; matches are flagged.
- The behavior is local to this repository. Other repos are not
  affected.

## Evidence expected before merge

1. `cargo test` output (existing test suite, must pass).
2. Output of `bash tests/test_guardrail_precommit.sh` showing all
   four unit tests pass.
3. A run of `.github/workflows/guardrail.yml` on a synthetic PR
   (created via `gh pr create --draft` then closed) showing the
   `guardrail-report` artifact is uploaded and contains at least one
   `GUARDRAIL:` line on the synthetic bad-PR.
4. `gh pr view` output showing the workflow run is `success` (or
   `neutral`) on the actual PR.

## Risk register

- **False positives**: rule 5 (3rd change to same function) may flag
  legitimate refactors that happen to touch the same function for
  unrelated reasons. Mitigation: the rule is a *finding*, not a
  *block*. The `DECISION:` line in the commit body is the escape
  hatch — agents add it when they have already considered
  second-fix-means-stop and chose to proceed.
- **Time delta sensitivity**: rule 3 uses a 5-minute threshold.
  If a CI environment has a >5 min wall-clock gap between commits
  (rare but possible on slow runners), the rule will miss the
  ground-truth window. Mitigation: the threshold is configurable
  via the `GUARDRAIL_DEPLOY_WINDOW_SEC` env var, default 300.
- **Comment-pattern fragility**: rule 4 looks for
  `X exists because we set Y to Z` patterns. Real code comments
  may not match. Mitigation: the rule is a *finding*, not a
  *block*. False negatives are acceptable for v1; false positives
  are not.

## Lane independence

Single lane — no ownership matrix needed. There are no parallel
worktrees, no stacked PRs, no shared files across lanes.
