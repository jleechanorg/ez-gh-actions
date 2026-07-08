# attractor_spec.md — Reactive-cascade guardrail attractor

This is the **goal-state complement** to `spec.md` (in this same
`.dark-factory/` directory). The main spec asks "how do we get there?"
This attractor spec asks "what does done look like as a stable end
state, and what MUST NOT happen as a result of this work?"

## Convergence target

A single, concrete noun phrase:

> A pre-commit script and CI workflow in the `jleechanorg/ez-gh-actions`
> repository that fires BEFORE the next compensating fix is written or
> shipped, surfacing the four reactive-cascade rules as structured
> `GUARDRAIL:` findings attached to every PR — and is never bypassed,
> deleted, or grown past its initial four-rule scope.

## Observable convergence criteria

A reviewer can verify the system has reached the attractor by running
exactly one of these checks (all must hold simultaneously):

1. **Script exists, is executable, and exits 0 on a clean PR:**
   ```bash
   test -x scripts/guardrail-precommit.sh && \
     scripts/guardrail-precommit.sh HEAD >/dev/null; echo $?
   ```
   Expected output: `0`.

2. **CI workflow is wired and triggers on PRs:**
   ```bash
   python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/guardrail.yml')); assert 'pull_request' in str(d.get(True, d))"
   ```
   Expected output: silent (no assertion error).

3. **All four rules are active and detectable:**
   ```bash
   bash tests/test_guardrail_precommit.sh && echo PASS
   ```
   Expected output: `PASS`.

4. **No fifth rule was accreted after merge.** The script's source
   contains exactly four rule functions (`rule_second_fix_stop`,
   `rule_audit_on_root_cause_change`,
   `rule_ground_truth_before_success`,
   `rule_complexity_budget`). Verify:
   ```bash
   grep -E "^rule_[a-z_]+\s*\(\s*\)" scripts/guardrail-precommit.sh | wc -l
   ```
   Expected output: `4`.

5. **The script is never bypassed on a merged PR.** The CI workflow
   ran on every merged PR in the 30 days following merge (auditable
   via the workflow's run history on the `main` branch).
   Verify: `gh run list --workflow=guardrail.yml --branch=main --limit=30 --json conclusion --jq '[.[] | select(.conclusion=="success" or .conclusion=="neutral")] | length'` returns 30.

## Anti-attractor states (end states the system MUST NOT converge to)

The attractor is ONLY reached if NONE of the following is true. Each
anti-state is a *concrete, observable* failure mode — not a vague
aspiration.

1. **The script is bypassed by a `skip-guardrail` label or commit
   message flag.** The system is NOT at the attractor if any merged
   PR was exempted by an escape hatch. The script has no `--skip` flag
   and the CI workflow has no `paths-ignore` for the guardrail step.

2. **The script grows past four rules.** The system is NOT at the
   attractor if `scripts/guardrail-precommit.sh` defines a 5th, 6th,
   or Nth rule. Reactive-cascade prevention is the *only* scope.
   Adding a "deploy safety" or "secret leak" or "license header"
   check is out of scope and is itself a cascade.

3. **The script auto-blocks the PR.** The system is NOT at the
   attractor if a `GUARDRAIL:` finding causes `exit 1` in the CI
   workflow's `pull_request` job. Findings are review signals, not
   gates. A reactive-cascade gate that auto-blocks will itself
   generate a reactive cascade (revert the gate, relax the gate,
   comment out the gate).

4. **The script and workflow exist but no PR has ever triggered
   them.** The system is NOT at the attractor if `gh run list
   --workflow=guardrail.yml` returns 0 runs after 7 days post-merge.
   A script with no caller is documentation, not automation.

5. **A second copy of the rules was added to `CLAUDE.md` (this
   repo) that duplicates the prose in `~/.claude/CLAUDE.md`.** The
   system is NOT at the attractor if the new "Reactive-cascade
   guardrail" section restates the four rules instead of
   cross-referencing the canonical prose. The whole point is to
   keep prose as source of truth and the script as the machine
   version.

6. **The script is "fixed" by a second fix within 30 days.** The
   system is NOT at the attractor if a PR merges a change to
   `scripts/guardrail-precommit.sh` and a subsequent PR within 30
   days merges another change to the same script that exists only
   to compensate for the first change. This is the rule biting
   itself, which is the failure mode the rule exists to prevent.
   (Auditable via `git log --follow scripts/guardrail-precommit.sh`.)

## Attractor verification command

A single deterministic command that proves the system is at the
attractor. Per the spec_gen prompt, this is the same as the main
spec's test command (consistency requirement):

```bash
bash tests/test_guardrail_precommit.sh && \
  test -x scripts/guardrail-precommit.sh && \
  python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/guardrail.yml')); assert 'pull_request' in str(d.get(True, d))" && \
  grep -qE "Reactive-cascade guardrail" CLAUDE.md && \
  echo ATTRACTOR_REACHED
```

Expected output: `ATTRACTOR_REACHED`.

## Evidence expected before merge

Per the main spec (`spec.md`, "Evidence expected before merge"
section), the same evidence proves the attractor:

1. `bash tests/test_guardrail_precommit.sh` output.
2. A real `gh pr create` + workflow run on a synthetic bad-PR,
   uploaded as the `guardrail-report` artifact.
3. `gh pr view` showing the actual PR is `success`/`neutral`.

The attractor adds ONE more evidence requirement that the main spec
does not require, because the main spec is about the work and the
attractor is about the *post-merge steady state*:

4. **30-day post-merge audit:** After 30 days, the convergence
   criteria 4 ("no fifth rule") and 5 ("never bypassed") must still
   hold. The audit is a single command:
   ```bash
   gh run list --workflow=guardrail.yml --branch=main --limit=30 --json conclusion \
     --jq '[.[] | select(.conclusion=="success" or .conclusion=="neutral")] | length'
   ```
   Expected: 30. If less, the system has regressed from the attractor.

## Non-attractor states (negative scope)

The system is NOT at the attractor when any of the following is true.
These are *not* anti-attractor states (those are concrete failure
modes above); these are end states that are simply outside the
attractor's scope.

- The system is NOT at the attractor when other repos
  (`jleechanorg/worldarchitect.ai`, `jleechanorg/agent-orchestrator`,
  etc.) lack the same guardrail. The attractor is per-repo; cross-repo
  rollout is out of scope.
- The system is NOT at the attractor when reactive cascades still
  happen. The attractor is the *guardrail*, not a guarantee.
  Reactive cascades may still occur; they will now be surfaced as
  `GUARDRAIL:` findings on the PR that introduced them.
- The system is NOT at the attractor when the prose in
  `~/.claude/CLAUDE.md` is updated. The attractor references that
  prose; changes to it are out of scope.

## Distinction from main spec

The main spec (`spec.md`) describes the *implementation path*: the
files to create, the test command, the file-ownership matrix (none
in this single-lane case), the acceptance criteria for the work.
This attractor spec describes the *convergence target*: the stable
end state, the anti-states the system MUST NOT converge to, and the
30-day post-merge audit. The main spec answers "how do we get
there?"; this attractor spec answers "what does done look like?"

Concretely, the main spec's "Deterministic test command" is
`bash tests/test_guardrail_precommit.sh` (spec.md, line "Deterministic
test command"). This attractor spec's "Attractor verification
command" extends that same command with three pre-conditions
(executable bit, CI workflow YAML, CLAUDE.md cross-reference) and
an `ATTRACTOR_REACHED` echo suffix. The test command is shared;
the attractor verification is the test command plus a steady-state
assertion. This consistency is required by the spec_gen review
contract (consistency with main spec, step 5).

The main spec's "Evidence expected before merge" lists four items
(1–4). This attractor spec's "Evidence expected before merge"
inherits items 1–3 verbatim and adds item 4 (30-day post-merge
audit) as an attractor-only requirement. This is the *only*
deliberate divergence between the two specs' evidence sections,
and the rationale is that the attractor's anti-state #6 ("a second
fix within 30 days") can only be detected *post-merge*, so the
attractor spec must require a post-merge audit that the main spec
cannot.
