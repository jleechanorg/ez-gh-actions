# /doctor — diagnose and self-heal the ezgha runner fleet

Repo-level command for ez-gh-actions. Runs the `doctor.sh` health check script, analyzes errors, and performs self-healing steps to restore fleet health.

## Skill Reference
* **Diagnostic Skill**: [ezgha-doctor](file:///home/jleechan/projects/ez-gh-actions/.claude/skills/ezgha-doctor/SKILL.md)

## Action Instructions for LLM

When this command is invoked, immediately execute the following steps:

1. **Run the health check**:
   ```bash
   bash "$(git rev-parse --show-toplevel)/doctor.sh"
   ```
   Read the output, exit code, and verdict. Exit 0 = healthy; exit 1 = unhealthy.

2. **If unhealthy, perform diagnostics**:
   * Inspect which of the 6 critical checks failed.
   * Check systemd service status: `systemctl --user status ezgha.service`
   * Check docker daemon: `docker ps` and `docker info`
   * Check recent journalctl logs: `journalctl --user -u ezgha.service --no-pager -n 50`

3. **Execute named remediation**:
   * **Service inactive**: Run `systemctl --user restart ezgha.service`
   * **Docker daemon down / Colima stopped**: Run `limactl start colima`
   * **Slot file desync / permanent 409 loops**: 
     ```bash
     systemctl --user stop ezgha.service
     rm -f ~/.config/ezgha/slot_assignments.toml
     systemctl --user start ezgha.service
     ```
   * **Offline runners on GitHub**: Retrieve the auth token and prune offline registrations via:
     ```bash
     TOKEN=$(gh auth token)
     for id in $(gh api orgs/jleechanorg/actions/runners --paginate | jq -r '.runners[] | select(.name|startswith("ez-org-")) | select(.status=="offline") | .id'); do
       gh api -X DELETE "orgs/jleechanorg/actions/runners/$id"
     done
     ```

4. **Verify repair**:
   * Re-run `doctor.sh` to confirm the exit status is now 0.
