# /ezgha-doctor — prove the ezgha runner fleet is healthy

Repo-scoped command for ez-gh-actions. Runs the `doctor.sh` health gate and,
on request, a live canary that dispatches a real GitHub Actions job and
verifies it executes on an `ez-org-runner-*` runner.

## When invoked

1. **Run the gate:**
   ```bash
   bash "$(git rev-parse --show-toplevel)/doctor.sh"
   ```
   Read the verdict line and the exit code. Exit 0 = healthy; exit 1 = unhealthy
   (the script prints which of the 6 critical checks failed + remediation).

2. **If the user wants proof of real job execution** (or the request says
   "prove", "make sure runners are working", "handled for real"):
   ```bash
   bash "$(git rev-parse --show-toplevel)/doctor.sh" --prove
   ```
   `--prove` dispatches a fresh `ezgha-selftest` workflow_dispatch and blocks
   until it completes, then confirms `runner_name` is `ez-org-runner-*` and
   `conclusion=success`. This is the strongest "working right now" evidence and
   adds ~1-2 min.

3. **If unhealthy**, follow the named remediation in
   `.claude/skills/ezgha-doctor/SKILL.md` — do NOT restart-loop the service
   (that re-creates the 409 name-collision spiral; see
   `docs/harness-early-victory-5whys.md`). The 409 self-heal + slot
   reconciliation are deployed; give them a cycle to converge and re-run the
   gate.

## What the gate proves (6 critical checks + 2 evidence gates)

1. `ezgha.service` active
2. docker daemon reachable
3. colima VM running (if applicable)
4. at least one `ez-org-runner-*` online at GitHub
5. ≥14 managed containers running locally
6. no `ensure_count failed` in the last `LOOP_WINDOW` (default 3) min — a
   TIME window, not a line window, so a since-recovered incident doesn't keep
   the gate red
7. **real-execution gate:** ≥1 of the last `ROUTING_N` (default 6)
   `ezgha-selftest` runs succeeded on an `ez-org-runner-*` (not colima /
   GitHub-hosted)
8. **canary gate** (only with `--prove`): a freshly dispatched job ran on our
   fleet and succeeded

## Tuning (env vars)

- `LOOP_WINDOW` — minutes of journal to scan for errors (default 3)
- `ROUTING_N` — how many recent runs to check for real execution (default 6)
- `ORG` / `EZGHA_REPO` — override targets (default jleechanorg /
  jleechanorg/ez-gh-actions)

## Rule

"Working" means this gate returns exit 0 AND stays green across a sustained
window (see `docs/observe-*/`) — never because a single snapshot looked good
or an artifact was produced. See `docs/harness-early-victory-5whys.md`.
