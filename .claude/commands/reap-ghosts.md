---
description: Reap ghost workflow runs (queued with zero jobs) via cancel → force-cancel → delete. Dry run by default.
---

# /reap-ghosts

Marker: `EZGHA_GHOST_REAP_COMMAND_V1`

Thin dispatcher — the workflow and safety invariants are owned by the skill.

**MANUAL DIAGNOSTIC ONLY.** Ghost handling for the scheduled agents lives in
`scripts/cleanup-stuck-runs.sh` (and ghost classification in PR #227, not yet
merged/deployed). This command exists to measure and explain the population by
hand; it is not a second agent and must not be scheduled. Dry-run is the default;
`--apply` is required for any mutation.

Read `.claude/skills/ezgha-ghost-reap/SKILL.md` completely, then run:

```bash
python3 .claude/skills/ezgha-ghost-reap/scripts/reap_ghosts.py $ARGUMENTS
```

Forward `$ARGUMENTS` unchanged. **This tool is read-only.** It classifies and reports;
it never cancels or deletes. `--apply` is accepted for compatibility and is a no-op.

Before promising a cleanup, check `gh api /rate_limit`: each run costs 2–4 core requests.
Exit `3` means some runs were wedged or refused deletion — report the outcome histogram,
and do not claim a cleanup succeeded when `reaped` is 0.
