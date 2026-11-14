---
description: Measure real CI queue depth and job pickup wait, separating ghost queued runs from live ones.
---

# /queued-status

Marker: `EZGHA_QUEUED_STATUS_COMMAND_V1`

Thin dispatcher — the workflow is owned by the skill.

Read `.claude/skills/ezgha-queued-status/SKILL.md` completely, then run:

```bash
python3 .claude/skills/ezgha-queued-status/scripts/queued_status.py $ARGUMENTS
```

Forward `$ARGUMENTS` unchanged (`--repo owner/name`, `--json`, `--verify-sample N`).
Exit `2` means the measurement failed — report that, never a zero backlog.
