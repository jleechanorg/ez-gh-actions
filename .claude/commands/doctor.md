# /doctor — diagnose and self-heal the ezgha runner fleet

Repo-level command for ez-gh-actions. Runs `doctor.sh` (fleet + queue health), self-heals when safe, and **always** runs `/harness` when unhealthy or queue tail exceeds threshold.

## Skill Reference
* **Diagnostic Skill**: [ezgha-doctor](file:///Users/jleechan/projects_other/ez-gh-actions/.claude/skills/ezgha-doctor/SKILL.md)

## Action Instructions for LLM

When this command is invoked, immediately execute the following steps:

1. **Run the health check** (always includes queue metrics):
   ```bash
   bash "$(git rev-parse --show-toplevel)/doctor.sh"
   ```
   Read the output, exit code, and verdict. Exit 0 = healthy; exit 1 = unhealthy.

   **Section 8 — queue health** (from `scripts/queue-health.sh`):
   - `in_progress` / `queued` counts on `QUEUE_REPO` (default `jleechanorg/worldarchitect.ai`)
   - Fresh queue p50 / p90 / max wait (minutes)
   - Oldest fresh queued run (actionable backlog)
   - Stale queued zombies (>8h by default — GitHub artifacts, not waiting for runners)
   - **BAD if max fresh wait > 20 min** (`QUEUE_TAIL_WARN_MIN`, default 20)

   **Section 9 — per-slot local execution proof** (LOCAL-ONLY, no GitHub API — the
   API lies under rate limit): every configured Linux slot (+ Mac slots over
   SSH if reachable) is classified DOWN / IDLE / EXECUTING via `docker top
   <container> | grep Runner.Worker`. DOWN is always a defect; IDLE is only a
   defect when there's a queue backlog. Also surfaces the serve-loop-
   starvation signal (max gap between respawn bursts, rate-limit occurrence
   count) — a gap over 150s means `ensure_count` is being starved by a
   rate-limited monitor tick (see `.claude/skills/ezgha-doctor/SKILL.md`
   Step 2b and bead ez-gh-actions-yrt/g3o).

2. **If unhealthy OR queue tail > 20 min, run `/harness`** (mandatory):
   * Read `~/.claude/commands/harness.md` and `~/.claude/skills/harness-engineering/SKILL.md`
   * Produce full harness analysis (5 Whys technical + agent path)
   * Classify failure: silent degradation | missing validation | repeated manual fix | etc.
   * Propose durable fixes (doctor.sh, skill, verify-exit-criteria gate, watchdog script)

3. **If unhealthy, perform diagnostics**:
   * Inspect which critical checks failed (sections 1–9)
   * Check supervisor: `systemctl --user status ezgha.service` (Linux) or `launchctl print gui/$(id -u)/org.jleechanorg.ezgha` (macOS)
   * Check docker: `docker ps --filter label=ezgha=managed`
   * Check logs: `journalctl --user -n 50 -u ezgha.service` or `/tmp/ezgha-launchd-stderr.log`
   * Check external watchdog: `tail -20 /tmp/ezgha-watchdog-stdout.log`

4. **Execute named remediation** (only when safe — do not restart-loop):
   * **Service inactive**: `ezgha install-service` then restart supervisor
   * **Docker/Colima down**: `colima start` or `limactl start colima`
   * **Slot file wedge**: stop service → `rm -f ~/.config/ezgha/slot_assignments.toml` → restart
   * **Queue tail > 20m**: verify runners busy (saturation) vs offline; delete stale zombies:
     ```bash
     gh run delete <stale_run_id> -R jleechanorg/worldarchitect.ai
     ```
   * **Offline runners**: prune only when not busy (use configured `name_prefix` from config.toml)

5. **Verify repair**:
   * Re-run `doctor.sh` until exit 0 AND queue tail ≤ 20m
   * Optionally: `doctor.sh --prove` for live canary dispatch
