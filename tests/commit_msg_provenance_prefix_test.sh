#!/usr/bin/env bash
# Regression test for .githooks/commit-msg — proves the hook:
#   (a) REJECTS subjects without a recognized runtime provenance prefix
#   (b) REJECTS subjects where the prefix is present but the ':' delimiter
#       is missing (must be `prefix/model:` or `human:`)
#   (c) ACCEPTS every canonical prefix from the global CLAUDE.md
#       "Commit provenance tag" table
#   (d) ACCEPTS git-merge subjects (they bypass the prefix gate)
#   (e) ACCEPTS empty-commit-file abort path (no crash; returns 2)
#   (f) ACCEPTS comments-only commit-msg files (treated as empty subject)
#
# Why: bead ez-gh-actions-jcie. Five squash merges on origin/main landed
# without a runtime prefix (d79d502, 629ee4d, 8eac59f, b3bbe1c, d54cb0b);
# we must not regress to that state again.
#
# Usage: bash tests/commit_msg_provenance_prefix_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/.githooks/commit-msg"
SERVER_WORKFLOW="$REPO_ROOT/.github/workflows/ci-selfhosted.yml"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable: $HOOK" >&2
  exit 1
fi

# The local hook cannot see squash commits created by GitHub. Keep the
# server-side PR-title gate wired to this same validator so the default squash
# subject is checked without duplicating the prefix contract in workflow YAML.
# `pull_request_target` loads the workflow from the trusted default branch. The
# whole self-hosted job must also be skipped for fork heads, before a runner is
# allocated, and the validator must come from the trusted base revision.
if ! grep -Eq '^[[:space:]]+pull_request_target:' "$SERVER_WORKFLOW"; then
  echo "FAIL: self-hosted CI does not use trusted pull_request_target metadata" >&2
  exit 1
fi
if grep -Eq '^[[:space:]]+pull_request:' "$SERVER_WORKFLOW"; then
  echo "FAIL: self-hosted CI still schedules untrusted pull_request code" >&2
  exit 1
fi
if ! grep -Fq "github.event.pull_request.head.repo.full_name == github.repository" "$SERVER_WORKFLOW"; then
  echo "FAIL: self-hosted CI does not skip fork pull requests at the job boundary" >&2
  exit 1
fi
if ! grep -Fq "ref: \${{ github.event.pull_request.base.sha }}" "$SERVER_WORKFLOW"; then
  echo "FAIL: self-hosted CI does not load the validator from the trusted base revision" >&2
  exit 1
fi
if ! grep -Fq "PR_TITLE: \${{ github.event.pull_request.title }}" "$SERVER_WORKFLOW"; then
  echo "FAIL: self-hosted CI does not validate the pull-request title" >&2
  exit 1
fi
if ! grep -Fq "bash .githooks/commit-msg \"\$commit_msg_file\"" "$SERVER_WORKFLOW"; then
  echo "FAIL: self-hosted CI does not reuse the commit-msg validator" >&2
  exit 1
fi
if ! grep -Eq 'types:.*edited' "$SERVER_WORKFLOW"; then
  echo "FAIL: editing a rejected pull-request title does not rerun the gate" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: write a commit-msg file with the given subject as the FIRST
# non-comment line. If subject is empty, write an entirely empty file.
write_msg() {
  local msgfile="$1"
  local subject="$2"
  : > "$msgfile"
  if [ "$subject" = "__EMPTY__" ]; then
    return
  fi
  if [ "$subject" = "__COMMENTS_ONLY__" ]; then
    printf '# just a comment\n# nothing else\n' > "$msgfile"
    return
  fi
  printf '%s\n' "$subject" > "$msgfile"
}

# Asserts: hook exit code matches expected; on REJECT we also expect the
# REJECTED marker in stderr (proves the helpful error path fires, not just
# a generic non-zero).
assert_hook() {
  local label="$1"
  local subject="$2"
  local expected_rc="$3"
  local expect_stderr_marker="${4:-}"   # empty -> no stderr assertion

  local msgfile="$TMPDIR/${label// /_}.msg"
  write_msg "$msgfile" "$subject"

  local actual_rc=0
  local stderr_collected=""
  stderr_collected="$(bash "$HOOK" "$msgfile" 2>&1 >/dev/null)" || actual_rc=$?

  if [ "$actual_rc" != "$expected_rc" ]; then
    echo "FAIL [$label]: expected rc=$expected_rc got rc=$actual_rc" >&2
    echo "  subject: $subject" >&2
    echo "  stderr:  $stderr_collected" >&2
    exit 1
  fi

  if [ -n "$expect_stderr_marker" ]; then
    if ! printf '%s' "$stderr_collected" | grep -q -- "$expect_stderr_marker"; then
      echo "FAIL [$label]: expected stderr to contain '$expect_stderr_marker'" >&2
      echo "  actual stderr: $stderr_collected" >&2
      exit 1
    fi
  fi
}

# ----- (a) REJECT: no prefix -----
assert_hook "no_prefix_simple"      "fix: typo in README"             1 "REJECTED"
assert_hook "no_prefix_feat"        "feat(runner): faster cycle"      1 "REJECTED"
assert_hook "no_prefix_chore"       "chore(beads): update"            1 "REJECTED"

# ----- (b) REJECT: prefix present but missing ':' delimiter -----
assert_hook "prefix_no_colon"       "claude/sonnet fix the bug"       1 "REJECTED"
assert_hook "human_no_colon"        "human tweak"                     1 "REJECTED"

# ----- (b2) REJECT: prefix present but missing mandatory model-id segment -----
# (CodeRabbit/Codex review, PR #66: "claude: fix" without a model-id used to
# pass because the '/model-id' segment was optional in the regex.)
assert_hook "claude_no_model"       "claude: missing model"          1 "REJECTED"
assert_hook "gemini_no_model"       "gemini: missing model"          1 "REJECTED"
assert_hook "codex_no_model"        "codex: missing model"           1 "REJECTED"

# ----- (b3) REJECT: word that merely starts with "human" -----
# (CodeRabbit review, PR #66: "humane: tweak" used to slip through because
# the trailing 'e' was absorbed by the optional model-id character class.)
assert_hook "humane_lookalike"      "humane: tweak"                  1 "REJECTED"

# ----- (c) ACCEPT: every canonical prefix -----
assert_hook "accept_claude_sonnet"  "claude/sonnet: chore: lint fix"      0
assert_hook "accept_claudem_minimax" "claudem/minimax-M3: chore: hook"    0
assert_hook "accept_claudew_glm"    "claudew/glm-5.1: feat(api): tweak"   0
assert_hook "accept_gemini"         "gemini/3-flash: docs: update"        0
assert_hook "accept_codex"          "codex/o3-mini: fix: race"            0
assert_hook "accept_cursor"         "cursor/claude: refactor: clean"      0
assert_hook "accept_ao"             "ao/claude: chore: spawn retry"       0
assert_hook "accept_human"          "human: merge resolution"             0

# ----- (d) ACCEPT: merge commits bypass the gate -----
assert_hook "accept_merge_branch"   "Merge branch 'foo' into main"        0
assert_hook "accept_merge_tag"      "Merge tag 'v1.2.3'"                 0
assert_hook "accept_merge_commit"   "Merge commit 'abc123' into main"     0
# (CodeRabbit review, PR #66: these two real git/GitHub merge subject forms
# used to be REJECTED because merge_re only matched "Merge branch|tag|commit".)
assert_hook "accept_merge_remote_tracking" \
  "Merge remote-tracking branch 'origin/main'"                            0
assert_hook "accept_merge_pull_request" \
  "Merge pull request #66 from jleechanorg/factory/ez-gh-actions-jcie-r1"  0

# ----- (e) Edge: missing arg / unreadable file -----
# (bash "$HOOK" with no $1) — the hook must exit non-zero, not crash with
# an unhelpful shell error.
set +e
no_arg_rc=0
bash "$HOOK" >/dev/null 2>&1 || no_arg_rc=$?
set -e
if [ "$no_arg_rc" -eq 0 ]; then
  echo "FAIL [no_arg]: expected non-zero rc when invoked without commit-msg file" >&2
  exit 1
fi

# ----- (f) Edge: comments-only commit-msg file -----
# git itself strips leading comments, but the hook still sees them. If the
# file has NO non-comment content, treat as empty subject -> reject.
comments_msg="$TMPDIR/comments_only.msg"
write_msg "$comments_msg" "__COMMENTS_ONLY__"
comments_rc=0
bash "$HOOK" "$comments_msg" >/dev/null 2>&1 || comments_rc=$?
# comments-only is treated as empty subject -> rc=2 from the hook
if [ "$comments_rc" != "2" ]; then
  echo "FAIL [comments_only]: expected rc=2 (empty subject) got rc=$comments_rc" >&2
  exit 1
fi

# ----- (g) Edge: comment line THEN a valid subject must ACCEPT -----
mixed_msg="$TMPDIR/mixed.msg"
printf '# This is a comment that git will strip\nclaude/sonnet: actual subject\n' > "$mixed_msg"
mixed_rc=0
bash "$HOOK" "$mixed_msg" >/dev/null 2>&1 || mixed_rc=$?
if [ "$mixed_rc" != "0" ]; then
  echo "FAIL [comment_then_subject]: expected rc=0 (valid subject after comment) got rc=$mixed_rc" >&2
  exit 1
fi

echo "PASS: commit-msg provenance prefix hook behaves correctly across"
echo "  - 3 reject cases (no prefix, 3 styles)"
echo "  - 2 reject cases (prefix without ':' delimiter)"
echo "  - 3 reject cases (prefix missing mandatory model-id segment)"
echo "  - 1 reject case  (word merely starting with 'human')"
echo "  - 8 accept cases (all canonical runtime prefixes)"
echo "  - 5 accept cases (git-merge subjects bypass the gate)"
echo "  - 1 edge case  (missing arg -> non-zero, no crash)"
echo "  - 1 edge case  (comments-only file -> rc=2 empty-subject)"
echo "  - 1 edge case  (comment-then-subject -> rc=0)"
echo "Reference bead: ez-gh-actions-jcie"
