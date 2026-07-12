---
description: ez-gh-actions repo-local /code-standards — review code, diffs, PRs, or proposed implementations against THIS repo's design goals and tenets. Loads repo-specific gates (fleet capacity, single-writer, layered-design, blast-radius, self-outage prevention, fmt) on top of the user-scope ZFC + ponytail ladder.
type: quality
execution_mode: immediate
---

# /code-standards (ez-gh-actions repo-local)

> This is the **repo-local** `/code-standards` command. It exists at
> `.claude/commands/code-standards.md` so it specializes the user-scope version
> at `~/.claude/commands/code-standards.md` with this repo's actual design
> goals and tenets. The user-scope command is still the parent — load it
> first; this file layers repo-specific gates ON TOP of it.

## Bidirectional pointer

| Direction | Where |
|---|---|
| Up to user-scope (ZFC, ponytail ladder, root-cause-first) | `~/.claude/commands/code-standards.md` + `~/.claude/skills/zero-framework-cognition/SKILL.md` + `~/.claude/skills/ponytail/SKILL.md` |
| Down to repo-local (these gates) | this file |

Repo-local command may add gates, NEVER remove user-scope gates. Conflict = user-scope wins; file a bead to escalate.

## Source skills (loaded by this command)

| Skill | Path |
|-------|------|
| Ponytail — lazy senior dev mode | `~/.claude/skills/ponytail/SKILL.md` |
| Zero-Framework Cognition (ZFC) | `~/.claude/skills/zero-framework-cognition/SKILL.md` |
| Thermo-nuclear code quality | `~/.claude/skills/thermo-nuclear-code-quality-review/SKILL.md` |
| User-scope /code-standards (parent) | `~/.claude/commands/code-standards.md` |

## Repo design goals (from CLAUDE.md)

These are the **enforceable** rules derived from the repo's own statements. Every review must check each one.

### 1. Fleet capacity standard (P0)
**The fleet MUST run 22/22 (16 Linux + 6 Mac).** Anything less is BROKEN; root-cause and fix. **No "churn" / "normal cycling" excuses.**
- GitHub API is **NOT** authoritative — use local `docker top` / `docker ps` for per-slot `Runner.Worker` proof.
- `./doctor-runner` is authoritative; it enforces a 4-state model: EXECUTING / IDLE-OK / IDLE-STARVED / DOWN. Busy fleets must never measure as dead.
- **Review gate**: any PR that touches `ensure_count`, `release_stale_slots`, runner registration, slot reconciliation, or job assignment MUST prove (in the PR description) that 22/22 holds under a busy CI burst, not just at idle.

### 2. Single-writer rule (P0, mandatory)
Steps 2–5 of Gate 0 (`cargo install`, `systemctl --user restart ezgha.service`, `./docs/verify-exit-criteria.sh`, `docker rm -f`) are the **deploy-owner's** responsibility ONLY.
- Sub-agents, codex jobs, sidekick workers, factory coders: **commit + push ONLY.** No install, no restart, no verify-exit-criteria.
- Coder prompts MUST include the verbatim single-writer rule.
- **Review gate**: PR descriptions that include commands for the deploy to execute are fine; PR descriptions that show the deploy as already-executed are violations.

### 3. Layered design (architecture)
Runners live in **Docker containers inside the Colima VM inside the Linux host**. The layered design is the protection. Each layer must:
- Be independently testable.
- Have a defined boundary (`Docker`, `daemon`, `runner, `VM`, `host kernel`) and a clear handoff contract.
- **No sudo in the layered design.** User-scope systemd + libexec scripts deliver the workload protection. Host-kernel touches (systemd-oomd tuning, earlyoom, /etc/ configs) are **opt-in hardening for the host kernel's view**, not part of this layered protection.
- **Review gate**: any PR that adds sudo commands must (a) be filed against a system-scope bead, AND (b) explain why a user-scope path is impossible, AND (c) be clearly labeled "host kernel hardening" in the PR body.

### 4. Self-Outage Prevention Principle
A safety, health, or monitoring mechanism must not be able to cause the outage or failure it is designed to guard against.
- The watchdog that rebooted the box twice on 2026-07-07 was the motivating incident. Watchdog re-arm is still gated on `30p` (SIGTERM drain, P0) + `xfw` (reboot-stale-state) + `lxn` (churn-guard).
- **Review gate**: any change to a watchdog, monitor, alert, or restart policy must include a blast-radius statement (the normal peak of the bounded metric + safe remaining margin).

### 5. Blast-Radius & Interaction Review (P0, CLAUDE.md "Safety & Monitoring Principles")
Any change to a threshold, health-check, watchdog configuration, restart policy, resource limit, or monitor cadence must be accompanied by:
- The normal peak of the bounded metric.
- A safe remaining margin.
- **Review gate**: PR descriptions for the above classes MUST include a "Blast radius" section. Cold reviewers REJECT otherwise (proven pattern: PR #53 drain deadline was checked between slots but not inside in-flight gh DELETE — false "below TimeoutStopSec" claim; caught by adversarial skeptic 2026-07-10).

### 6. Self-Healing Recipes
The repo carries documented recipes in CLAUDE.md "Common self-healing recipes" (container conflict, slot wedge, Colima VM down). Any new failure class with a manual recovery procedure MUST be added there — and the recipe MUST have an **automatic caller**, not a manual invocation path only. Automation without a caller is not automation.

### 7. Honest gates, not green features on dishonest ones (roadmap "Phase 1 — k4h promoted")
Don't build features on dishonest gate output. `k4h` was the exemplar: verify-exit-criteria.sh honesty updates (Gate 3 pagination, Gate 7 real monitor checks) had to land BEFORE alerts (zmk) and self-healing (9yt).
- **Review gate**: if a PR claims a metric is improving X, the metric must be defined, measured, and the measurement honest (no green CI badge covering a red dashboard).

### 8. Automation requires callers (rule-level general)
Every script MUST have an automatic caller. CI workflow, systemd timer, launchd plist, git hook, or a parent script that IS auto-triggered. A script with only a manual invocation path is not automation. (Motivating incident: shell-test orphan at 2026-07-10; 14+ regression tests had no CI step — fixed in PR r8od.)

### 9. No silent underprovisioning
The daemon historically clamped `runner_floor_mb` silently to fit a too-tight budget. The clamp hid 5GB of underprovisioning for weeks.
- **Review gate**: any budget clamp MUST log the derivation (input, clamped value, expected, shortfall) and refuse to start if the floor exceeds the budget (per `yz6b` PR #55).

### 10. Test isolation (rule-level general)
Tests must be hermetic by default. A test that fires a real API call, real systemd action, or real Colima touch is a test bug.
- **Review gate**: tests that touch the network / system / external processes must use stubbed or fake harnesses (existing pattern: `refresh_gh_app_token_timeout_test.sh` uses a `GH_EXE_OVERRIDE` thread-local fake `gh` shell stub).

## Commit conventions (CLAUDE.md)

Every commit subject MUST be prefixed with the runtime that produced it:
- `gemini/<model-id>: <subject>`
- `claude/<model-id>: <subject>`
- `human: <subject>`
- (Recent addition: `claudem/<model>: ` for MiniMax pairs)

**Review gate**: a commit with no recognizable prefix is a violation. The coder agent must identify itself in the prefix.

## Review dispatcher (when invoked)

When `/code-standards [target]` is run, dispatch the following lanes against `[target]` (defaults to `origin/main..HEAD`):

| Lane | Skill / Agent | Purpose |
|---|---|---|
| 1. Ponytail ladder | `~/.claude/skills/ponytail/SKILL.md` | 7-rung laziness check (reuse > rewrite, stdlib > dep, etc.) |
| 2. ZFC compliance | `~/.claude/skills/zero-framework-cognition/SKILL.md` | No keyword routing / heuristic scoring in app code |
| 3. Root-cause-first | explicit | 5 Whys on the failure, not just the symptom fix |
| 4. **Repo gates** | THIS FILE (sections 1–10) | Each repo rule gets a per-rule pass |
| 5. Cross-model skeptic | codex exec or minimax verifier | Adversarial prompt to REFUTE readiness |
| 6. Thermo-nuclear review | `~/.claude/skills/thermo-nuclear-code-quality-review/SKILL.md` | Strict structural quality (only invoked for medium/large changes) |

### Output

Per-lane verdict (PASS / WARN / FAIL with evidence) + a final composite verdict. Same shape as user-scope /code-standards but with repo-rule results explicit. Composite failures require a fix-it round or a bead (not a "fix later").

## Verdict example

```
REPO CODE-STANDARDS — PR #53 (SIGTERM drain)

Lane 1 (ponytail)              PASS — reuses src/shutdown.rs handler; no new dep
Lane 2 (ZFC)                    PASS — no app-code keyword routing
Lane 3 (root-cause-first)       PASS — addresses the orphan-reg cause, not just the symptom
Lane 4 (repo gates):
  1. fleet capacity              PASS — neutral on ensure_count, drain only handles exit
  2. single-writer               PASS — commit+push only per commit log
  3. layered design              PASS — drain scoped to daemon exit, no host touch
  4. self-outage prevention      PASS — only deregisters container-LESS regs
  5. blast-radius                PASS (after round-2 fix) — explicit "15s + one child-kill latency" margin
  6. self-healing recipes        N/A (no manual recipe added)
  7. honest gates                PASS — claim proven by test
  8. automation callers          PASS — N/A (no new script)
  9. no silent underprovisioning N/A (out of scope)
 10. test isolation              PASS — fake-gh stub via GH_EXE_OVERRIDE
Lane 5 (skeptic, codex gpt-5.6-sol)  APPROVE with one nit
Lane 6 (thermo)                  N/A (medium change)

COMPOSITE: APPROVE
```

## Bidirectional reminder

If a repo-local rule conflicts with a user-scope rule, **user-scope wins** and the conflict is beaded for upstream resolution. Example: if a future repo rule wanted to relax ZFC for performance, that's an upstream question, not a repo-level override.