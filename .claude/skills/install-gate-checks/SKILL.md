---
name: install-gate-checks
description: Use when adding or modifying any install-time sentinel (install.sh guard, launchd/install-launchagents.sh verify_rendered_plist, verify_scripts_exist, pre-commit hook check). Mandates behavioral correctness assertions over presence-only string greps. The 2026-08-20 Mac fleet outage shipped because install.sh:619 only checked for the *presence* of ensure_runner_image (grep -q) — the function existed, the sentinel passed, the underlying build command was silently broken for 19 days. Use this skill BEFORE writing any new install-time check.
---

# Install-Time Gate Checks — Behavioral, Not Presential

## Why this skill exists

The 2026-08-20 Mac fleet outage was traced to a single bash line at `scripts/ezgha-fleet-watchdog.sh:366`:

```bash
# WRONG — relative -f, breaks under launchd's cwd-of-/
build_log="$(DOCKER_BUILDKIT=0 docker build -f Dockerfile.runner -t "$image" "$repo_root" 2>&1)" || build_rc=$?
```

The companion sentinel at `install.sh:619` was:

```bash
# WRONG — checks function presence, not behavioral correctness
if [[ "${name}" == "watchdog" ]] && ! grep -q 'ensure_runner_image' "${exec_path}" 2>/dev/null; then
  bad "refusing to install ${plist}: ${exec_path} is missing ensure_runner_image sentinel"
```

The sentinel passed because `ensure_runner_image` was present. The function was broken — 311+ silent `REBUILD FAILED` events over 19 days, every 120s of watchdog tick. The bug produced the 2026-08-20 outage.

## When to use

Use this skill BEFORE adding or modifying:
- Any `install.sh` sentinel (currently `install.sh:619`, the watchdog function-presence check)
- Any `launchd/install-launchagents.sh:verify_rendered_plist` or `verify_scripts_exist` check
- Any pre-commit hook that gates script installation
- Any sentinel that claims "the script will work" via string match

## Decision table

| Pattern | ❌ Wrong (presence-only) | ✅ Right (behavioral) |
|---|---|---|
| Sentinel checks script will work | `grep -q 'function_name'` | Run the function in dry-run, assert output |
| Sentinel checks build command works | `grep -q 'docker build'` | Run `docker build` against a real test Dockerfile, assert exit 0 |
| Sentinel checks plist is renderable | `grep -q 'EnvironmentVariables'` | Render the plist template, parse with `plutil`, assert keys |
| Sentinel checks path is absolute | `grep -q '$absolute_path'` | `[[ "$path" = /* ]]` test, or `readlink -f` and assert no `..` segments |
| Sentinel checks alert path is wired | `grep -q 'alerts.jsonl'` | Run a probe that writes a sentinel event to alerts.jsonl, parse and assert |

## Pattern template for a behavioral sentinel

```bash
# Probe the actual behavior, not a substring match
verify_behavioral() {
  local probe_rc=0
  local probe_output
  probe_output="$(cd /tmp && DOCKER_BUILDKIT=0 docker build -f "$abs_dockerfile_path" -t probe:test . 2>&1)" || probe_rc=$?
  if (( probe_rc != 0 )); then
    bad "behavioral sentinel FAILED: docker build against $abs_dockerfile_path exited $probe_rc: $probe_output"
    return 1
  fi
  return 0
}
```

For shell functions, prefer:
1. **Probe invocation**: run the function in a dry-run/test mode and assert exit + output
2. **Syntax + semantic check**: `bash -n` for syntax, then a focused semantic assertion (e.g., `grep -E '^\s*docker build -f \$absolute_path'`)
3. **Marker file**: have the function write a marker file on success, sentinel checks for that file

For Cargo binaries, prefer:
1. **Run a unit test that exercises the code path**: `cargo test -p <crate> <test_name>`
2. **Run a probe binary**: ship a `--probe` mode that exits 0 if the function works

## Anti-patterns to flag in code review

When reviewing any new install-time sentinel, REJECT if you see:
- `grep -q '<symbol_name>'` — symbol can exist while broken
- `grep -q '<literal_string>'` — string can exist while broken
- `grep -q '<error_message>'` — error string can exist while broken
- No `--dry-run` or `--probe` mode that exits 0 when correct
- No test that exercises the sentinel's claim end-to-end
- Silent `exit 0` on any failure path (the 11,141 `untrusted_docker_host` skip class)

## Real-Docker integration test pattern

`tests/watchdog_ensure_runner_image_test.sh` (the companion test to this skill) exercises the sentinel's claim end-to-end:
- Removes `ezgha-runner:latest` from local docker
- Invokes `ensure_runner_image` in dry-run + probe mode
- Asserts the image is rebuilt
- Asserts no `Lstat` error in stderr
- Asserts a sentinel-marker file is written on success

This is the canonical Layer 2 test for this skill's claims.

## Related

- Project CLAUDE.md: `Sentinel checks at install time — behavioral, not presential` section
- Bead `jleechan-zgvz`: line 366 fix + 5 follow-up safety gaps (this skill addresses gaps #4-#7)
- Bead `jleechan-xlo7`: parent image-heal class regression
- Memory `feedback_2026-08-25_harness_fix_presence_vs_behavioral.md`: the 5 Whys analysis
- Commit `b3fe954` (claude/MiniMax-M3): the original line 366 fix + the FIRST behavioral sentinel at install.sh:619

## Verification

After applying this skill to a new sentinel:
1. The sentinel exits non-zero when the function/command is broken
2. The sentinel exits zero when the function/command works
3. A test exercises both paths
5. A test asserts that 19+ days of silent failures cannot recur (e.g., asserts an alert fires after N consecutive failures)