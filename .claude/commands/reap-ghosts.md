---
description: Reap ghost workflow runs (queued with zero jobs) via cancel → force-cancel → delete. Dry run by default.
---

# /reap-ghosts

Marker: `EZGHA_GHOST_REAP_COMMAND_V1`

Thin dispatcher — the workflow and safety invariants are owned by the skill.

Read `.claude/skills/ezgha-ghost-reap/SKILL.md` completely, then run:

```bash
python3 .claude/skills/ezgha-ghost-reap/scripts/reap_ghosts.py $ARGUMENTS
```

Forward `$ARGUMENTS` unchanged. **Dry run is the default** — `--apply` is required to
mutate anything, and only pass it when the user has explicitly authorized reaping.

Before promising a cleanup, check `gh api /rate_limit`: each run costs 2–4 core requests.
Exit `3` means some runs were wedged or refused deletion — report the outcome histogram,
and do not claim a cleanup succeeded when `reaped` is 0.
