#!/usr/bin/env bash
# Gate 0 must tolerate HEAD advancing past the deployed binary's SHA by commits
# that touch no build input (src/, Cargo.toml, Cargo.lock, build.rs), and must
# still fail when any build input changed. Hermetic: temporary git repo fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/docs/verify-exit-criteria.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO/src" "$REPO/docs"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
echo 'fn main(){}' > "$REPO/src/main.rs"
echo '[package]' > "$REPO/Cargo.toml"
echo 'x' > "$REPO/Cargo.lock"
echo a > "$REPO/docs/a.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
DEPLOYED=$(git -C "$REPO" rev-parse --short HEAD)

gate0() {
  (cd "$REPO" && VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=gate0 \
     VERIFY_EXIT_CRITERIA_DEPLOYED_SHA="$1" bash "$VERIFY" 2>&1)
}

out=$(gate0 "$DEPLOYED") || fail "identical SHA must pass: $out"

echo b >> "$REPO/docs/a.md"; echo 'x' > "$REPO/rustfmt.toml"
git -C "$REPO" add -A && git -C "$REPO" commit -qm docs-only
out=$(gate0 "$DEPLOYED") || fail "docs/format-only advance must pass: $out"

echo '// change' >> "$REPO/src/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm src-change
rc=0; out=$(gate0 "$DEPLOYED") || rc=$?
[ "$rc" -ne 0 ] || fail "src/ change after deployed SHA must fail"
grep -Fq 'src/main.rs' <<<"$out" || fail "failure omitted changed build input: $out"

# Cargo.lock / Cargo.toml / build.rs each count as build inputs.
for f in Cargo.lock Cargo.toml build.rs; do
  rc=0
  base=$(git -C "$REPO" rev-parse --short HEAD)
  echo "// $f" >> "$REPO/$f"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "touch $f"
  out=$(gate0 "$base") && fail "$f change must fail Gate 0" || true
done

# Must not depend on the caller's cwd: a src/ change seen from a subdirectory
# (pathspecs resolve relative to cwd) must still fail.
rc=0
out=$(cd "$REPO/docs" && VERIFY_EXIT_CRITERIA_TEST_MODE=1 VERIFY_EXIT_CRITERIA_TEST_CASE=gate0 \
  VERIFY_EXIT_CRITERIA_DEPLOYED_SHA="$DEPLOYED" bash "$VERIFY" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "src change must fail Gate 0 when run from a subdirectory"

# Build-input change followed by a revert has an empty endpoint diff but the
# deployed binary may have been built from the intermediate tree: must fail.
git -C "$REPO" checkout -q -b rev-branch
rbase=$(git -C "$REPO" rev-parse --short HEAD)
cp "$REPO/src/main.rs" "$TMP/main.rs.orig"
echo '// transient' >> "$REPO/src/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm transient
echo '// transient-built' > "$TMP/marker"
cp "$TMP/main.rs.orig" "$REPO/src/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm revert
rc=0; out=$(gate0 "$rbase") || rc=$?
[ "$rc" -ne 0 ] || fail "src change then revert after deployed SHA must fail"

# A sibling (non-ancestor) deployed SHA must fail even if trees match on inputs.
git -C "$REPO" checkout -q -b sibling "$rbase"
echo sib > "$REPO/docs/sib.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm sibling
sib=$(git -C "$REPO" rev-parse --short HEAD)
git -C "$REPO" checkout -q rev-branch
rc=0; out=$(gate0 "$sib") || rc=$?
[ "$rc" -ne 0 ] || fail "non-ancestor deployed SHA must fail"
grep -Fq 'not an ancestor' <<<"$out" || fail "non-ancestor failure omitted diagnostic: $out"

# Unknown deployed SHA (not in history) must fail closed.
rc=0; out=$(gate0 deadbee) || rc=$?
[ "$rc" -ne 0 ] || fail "unresolvable deployed SHA must fail"

echo "VERIFY_EXIT_GATE0_TEST: PASS"
