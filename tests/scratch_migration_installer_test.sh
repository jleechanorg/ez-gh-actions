#!/usr/bin/env bash
# Hermetic coverage for scripts/install_scratch_migration.py (bead jleechan-0yic).
# No host ~/.claude is touched: every case runs against a throwaway fixture tree.
#
# The fixture contains the PRE-migration text for a subset of the real patterns,
# hand-copied from the shipped skill/script files — not generated from the
# installer's own table, so the test cannot pass tautologically.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/scripts/install_scratch_migration.py"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }; pass() { echo "PASS: $*"; }

FIX="$W/claude"
mkdir -p "$FIX/scripts" "$FIX/skills/clonefix" "$FIX/skills/clean" "$FIX/skills/testing-infrastructure"

fixture_clean() { # name-of-this-fixture
  rm -rf "$FIX"; mkdir -p "$FIX/scripts" "$FIX/skills/clonefix" "$FIX/skills/clean" "$FIX/skills/testing-infrastructure"
  cat > "$FIX/scripts/testerc.sh" <<'EOF'
#!/usr/bin/env bash
CAPTURE_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CAPTURE_DIR="/tmp/test_captures/$CAPTURE_TIMESTAMP"
export TEST_CAPTURE_DIR="$CAPTURE_DIR"
EOF
  cat > "$FIX/skills/clonefix/SKILL.md" <<'EOF'
### Phase 1: Clone Repository to /tmp
>    CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${repo_name}_clonefix_XXXXXX")"
   `mktemp -d "${TMPDIR:-/tmp}/${repo_name}_clonefix_XXXXXX"`, then clone
1. **Create proof**: `mkdir -p /tmp/{repo_name}_clonefix_proof/`
2. **Save proof**: `echo x > /tmp/{repo_name}_clonefix_proof/merge_state.txt`
EOF
  cat > "$FIX/skills/clean/SKILL.md" <<'EOF'
description: "Clean Room Reproduction — Runs isolated E2E bug reproductions inside /tmp from a fresh repository state"
`/clean` is used to reproduce issues from scratch in a fresh, isolated clean room directory inside `/tmp`. It guarantees that no side-effects or dirty local states affect the validity of the reproduction.
2. **Setup the Clean Room**: Create a fresh directory `/tmp/repro-cb-<issue_id>-<timestamp>`.
EOF
  cat > "$FIX/skills/testing-infrastructure/SKILL.md" <<'EOF'
- Results saved to `/tmp/repo/branch/smoke_tests/`
EOF
}
run() { python3 "$INSTALLER" --root "$FIX" "$@" >"$W/out" 2>"$W/err"; echo $?; }

# ── 1. Dry-run reports the plan and writes nothing ─────────────────────────
fixture_clean
before=$(shasum "$FIX/scripts/testerc.sh" "$FIX/skills/clonefix/SKILL.md" "$FIX/skills/clean/SKILL.md" | awk '{print $1}' | tr '\n' ' ')
rc=$(run)
[ "$rc" = "0" ] || { cat "$W/err"; fail "clean fixture dry-run must exit 0 (got $rc)"; }
[ "$(shasum "$FIX/scripts/testerc.sh" "$FIX/skills/clonefix/SKILL.md" "$FIX/skills/clean/SKILL.md" | awk '{print $1}' | tr '\n' ' ')" = "$before" ] \
  || fail "dry-run must not write"
grep -q "would-migrate" "$W/out" || fail "dry-run must report would-migrate"
grep -q "missing" "$W/out" || fail "absent skill files must be reported as missing, not fatal"
pass "dry-run reports the plan, writes nothing, skips absent files"

# ── 2. Ambiguity and drift fail closed, and unsafe files are untouched ─────
fixture_clean
# duplicate one exact snippet -> ambiguous
grep '^description:' "$FIX/skills/clean/SKILL.md" >> "$FIX/skills/clean/SKILL.md"
# a file a human rewrote -> drift (neither old nor new text)
echo "something a human rewrote" > "$FIX/skills/testing-infrastructure/SKILL.md"
rc=$(run --apply)
[ "$rc" = "1" ] || fail "ambiguous/drift fixture must exit 1 (got $rc)"
grep -q "ambiguous" "$W/err" || fail "duplicate snippet must be reported as ambiguous"
grep -q "drift" "$W/err" || fail "unrecognised file must be reported as drift"
[ "$(grep -c '^description:' "$FIX/skills/clean/SKILL.md")" = "2" ] || fail "ambiguous file must be left untouched"
grep -q "something a human rewrote" "$FIX/skills/testing-infrastructure/SKILL.md" || fail "drift file must be left untouched"
grep -q 'scratch-dir.sh test_captures' "$FIX/scripts/testerc.sh" || fail "safe patterns must still be applied"
pass "ambiguous and drift cases fail closed without clobbering other files"

# ── 3. --apply migrates to the resolver with a /tmp fallback ───────────────
fixture_clean
rc=$(run --apply)
[ "$rc" = "0" ] || { cat "$W/err"; fail "apply must exit 0 on a clean fixture (got $rc)"; }
grep -q 'scratch-space/scripts/scratch-dir.sh test_captures' "$FIX/scripts/testerc.sh" || fail "testerc.sh must resolve scratch"
grep -q '|| echo /tmp' "$FIX/scripts/testerc.sh" || fail "resolver must keep a /tmp fallback"
grep -q '/tmp/test_captures' "$FIX/scripts/testerc.sh" && fail "hardcoded /tmp capture path must be gone"
grep -q 'SCRATCH="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh clonefix' "$FIX/skills/clonefix/SKILL.md" \
  || fail "clonefix CLONE_DIR must resolve scratch"
grep -q "Clone Repository to the scratch root" "$FIX/skills/clonefix/SKILL.md" || fail "legacy heading must be rewritten"
grep -q "/tmp/{repo_name}_clonefix_proof" "$FIX/skills/clonefix/SKILL.md" && fail "legacy proof token must be gone"
grep -q "inside the resolved scratch root" "$FIX/skills/clean/SKILL.md" || fail "clean-room description must be rewritten"
grep -q 'scratch-dir.sh smoke-tests' "$FIX/skills/testing-infrastructure/SKILL.md" || fail "smoke-test results path must resolve scratch"
bash --version >/dev/null && bash -n "$FIX/scripts/testerc.sh"
pass "apply rewrites producers to the scratch resolver with a /tmp fallback"

# ── 4. Re-running is idempotent ───────────────────────────────────────────
sum_before=$(shasum "$FIX/scripts/testerc.sh" "$FIX/skills/clonefix/SKILL.md" "$FIX/skills/clean/SKILL.md" "$FIX/skills/testing-infrastructure/SKILL.md" | awk '{print $1}' | tr '\n' ' ')
rc=$(run --apply)
[ "$rc" = "0" ] || fail "second apply must exit 0 (got $rc)"
grep -q "already-migrated" "$W/out" || fail "second apply must report already-migrated"
sum_after=$(shasum "$FIX/scripts/testerc.sh" "$FIX/skills/clonefix/SKILL.md" "$FIX/skills/clean/SKILL.md" "$FIX/skills/testing-infrastructure/SKILL.md" | awk '{print $1}' | tr '\n' ' ')
[ "$sum_before" = "$sum_after" ] || fail "second apply must not modify files"
pass "re-running the installer is a no-op"

# ── 5. JSON report + bad root ─────────────────────────────────────────────
python3 "$INSTALLER" --root "$FIX" --json "$W/report.json" >/dev/null 2>&1 || true
python3 - "$W/report.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["mode"] == "dry-run", r["mode"]
assert any(x["status"] == "already-migrated" for x in r["results"]), "report must carry per-file status"
assert r["problems"] == [], r["problems"]
PY
pass "JSON report carries per-file status"
rc=$(python3 "$INSTALLER" --root "$W/does-not-exist" 2>/dev/null; echo $?)
[ "$rc" = "2" ] || fail "bad root must exit 2 (got $rc)"
pass "bad root exits 2"

echo "ALL PASS"
