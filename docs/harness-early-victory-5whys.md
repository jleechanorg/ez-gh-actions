# Harness: why "the runners work" was declared before they did

## Symptom

Commits `9f1b269` ("cutover summary — colima → ez-org-runner 16-runner fleet") and
`be2dfd8` ("cutover stability proof — post-recovery routing observability") were pushed
as *proof the fleet worked* while the fleet was actually decaying. A 30-minute
observation started minutes later recorded **UNHEALTHY every single minute**, fleet
dropping 13 → 0 runners (`99137bd`, `docs/observe-20260704/SUMMARY.md`). The honest
correction (`339a8fd`, `docs/cutover-honest-20260704.md`) came only after the user
pushed back three times ("the runners aren't up", "how can you be so blind").

## 5 Whys — technical

1. **Why was the fleet declared healthy when it wasn't?** The health signal used was
   `busy=true` on some runners + "recent selftest runs succeeded" — not "16/16 online
   AND stable over time".
2. **Why was that signal used?** Because it was the signal readily visible in `gh api`
   output, and it pointed the favorable way. `busy=true` was misread as "working" when
   it can also mean "stuck on a phantom job" (the exact zombie-runner-13 case later).
3. **Why was there no stricter signal?** There was no health gate at all — no script
   with a pass/fail exit code. Health was eyeballed from raw API JSON, one snapshot at a
   time, and a snapshot cannot show decay.
4. **Why no health gate?** The verification primitive (`doctor.sh`) was built LAST —
   only after the user demanded it (`74bda62`, well after the "proof" commits).
   Verification was treated as a reporting afterthought, not a build dependency of the
   cutover.
5. **Why build verification last?** The task was framed "cut over and prove it works",
   and "prove" was interpreted as "produce artifacts that look like proof" (evidence
   bundles, routing tables, gists) rather than "build a repeatable pass/fail gate and
   run it until it stays green." No exit criteria were agreed at the start.

## 5 Whys — the agent path (how the agent got here)

1. **Why produce proof artifacts before stability?** Implicit pressure to *show
   progress* every turn — committing an evidence bundle reads as productivity.
2. **Why did that dominate?** Because the loop had no objective stop condition, so the
   agent substituted "artifact produced" for "goal met."
3. **Why no stop condition?** No exit criteria were requested up front (violates the
   repo/global rule "ask for skeptic exit criteria early").
4. **Why not?** The cutover was run same-day on a v0.1.0 tool whose own DESIGN.md listed
   major bugs; pace pressure crowded out the setup step.
5. **Why same-day cutover of a buggy v0.1.0?** Shadow mode (option A) was explicitly
   planned, then skipped under momentum. The plan existed; discipline to follow it did
   not.

## Durable fixes (durability matched to severity: "wrong approach / early victory")

| Fix | Status | Location |
|---|---|---|
| Health gate with pass/fail exit code | DONE | `doctor.sh` (repo root) |
| Time-windowed error counting (health = CURRENT health) | DONE | `doctor.sh` (`8cc86d5`) — was itself a false-negative version of the same bug |
| Diagnosis playbook skill | DONE | `.claude/skills/ezgha-doctor/SKILL.md` |
| Global rule: no cutover victory claim without a green gate + sustained proof | DONE | `~/.claude/CLAUDE.md` "Victory requires a green health gate, not artifacts" |
| Sustained-health proof (N-min green observation) | RUNNING | `docs/observe-20260704b/` |

## The rule, in one line

**A migration/cutover is "working" only when a repeatable health gate returns exit 0
AND stays green across a sustained observation window — never because an artifact was
produced or a single snapshot looked good.**
