# .githooks — runtime provenance prefix enforcement

This directory contains the `commit-msg` hook that enforces the runtime
provenance prefix rule from `CLAUDE.md` (project) and the global
`~/.claude/CLAUDE.md` "Commit provenance tag" rule.

## Why this exists

In July 2026, five squash-merge commits landed on `origin/main` without
the required runtime prefix:

- `d79d502` (#47 fix(...))
- `629ee4d` (#51 fix(...))
- `8eac59f` (#53 feat(...))
- `b3bbe1c` (#54 feat(...))
- `d54cb0b` (#55 feat(...))

Each lacked the `claude/<model>:`, `gemini/<model>:`, `codex/<model>:`, or
`human:` prefix mandated by the project's own commit conventions. Future
authors must not be allowed to silently regress to that state — bead
`ez-gh-actions-jcie`.

## Hook contract

| Aspect | Behavior |
|--------|----------|
| Subject line | First non-comment, non-blank line of the commit-msg file |
| Allowed prefixes | `claude/`, `claudem/`, `claudew/`, `gemini/`, `codex/`, `cursor/`, `ao/`, `human` (terminated by `:`) |
| Merge commits | Bypass the gate (subjects like `Merge branch 'foo' into main`) |
| Empty subject | Reject (rc=2) |
| Comments-only | Reject (treated as empty subject) |
| Bypass | `git commit --no-verify` (emergency only) |

## How to opt in (per-developer)

This repo intentionally does **not** commit a `core.hooksPath` change —
that would force every clone to use these hooks. To enable locally:

```bash
# One-time: point git at the in-repo hooks dir
git config core.hooksPath .githooks

# Verify it works (should reject with a clear message)
git commit --allow-empty -m "fix: no prefix"
git commit --allow-empty -m "claude/sonnet: test"   # should succeed
```

## How to opt in (repository-wide via install.sh)

`install.sh` (if/when extended) may run `git config --local core.hooksPath
.githooks` so every developer's clone gets the gate. Until then, the
opt-in is per-developer as above.

## Adding new prefixes

Keep `.githooks/commit-msg` `allowed_re` in lockstep with the canonical
list in global `~/.claude/CLAUDE.md` "Commit provenance tag" table. If
a new runtime appears, update BOTH at once and extend
`tests/commit_msg_provenance_prefix_test.sh` with a new `accept_*` case.

## Bypassing the hook

```bash
git commit --no-verify -m "emergency hot-fix without prefix"
```

Use this only for emergencies. The bypass is logged in the commit's reflog
and is visible to reviewers — it is not silent.