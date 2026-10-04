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
git -C "$REPO" init -q -b fixture
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

# A merge resolution can itself alter a build input even if neither side branch
# did. Default `git log --name-only` omits merge diffs, so Gate 0 must inspect
# the merge against each parent rather than trusting path-limited log output.
git -C "$REPO" checkout -q -B merge-main "$rbase"
merge_deployed=$(git -C "$REPO" rev-parse --short HEAD)
echo main > "$REPO/docs/merge-main.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm merge-main-docs
git -C "$REPO" checkout -q -b merge-side "$merge_deployed"
echo side > "$REPO/docs/merge-side.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm merge-side-docs
git -C "$REPO" checkout -q merge-main
git -C "$REPO" merge --no-ff --no-commit merge-side >/dev/null
echo '// merge resolution build input' >> "$REPO/src/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm merge-resolution-build-input
rc=0; out=$(gate0 "$merge_deployed") || rc=$?
[ "$rc" -ne 0 ] || fail "build-input change in a merge resolution must fail Gate 0"
grep -Fq 'src/main.rs' <<<"$out" \
  || fail "merge-resolution failure omitted changed build input: $out"

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

# The normal verifier path must share verify_deployed_sha's tolerant policy;
# exercising VERIFY_EXIT_CRITERIA_TEST_MODE=gate0 above alone would miss a
# stale inline strict-equality check in the normal dispatch.
NORMAL_REPO="$TMP/normal-repo"
mkdir -p "$NORMAL_REPO/src" "$NORMAL_REPO/docs"
git -C "$NORMAL_REPO" init -q -b fixture
git -C "$NORMAL_REPO" config user.email t@example.com
git -C "$NORMAL_REPO" config user.name t
echo 'fn main(){}' > "$NORMAL_REPO/src/main.rs"
echo '[package]' > "$NORMAL_REPO/Cargo.toml"
echo x > "$NORMAL_REPO/Cargo.lock"
echo a > "$NORMAL_REPO/docs/a.md"
git -C "$NORMAL_REPO" add -A && git -C "$NORMAL_REPO" commit -qm normal-base
NORMAL_DEPLOYED=$(git -C "$NORMAL_REPO" rev-parse --short HEAD)
echo b >> "$NORMAL_REPO/docs/a.md"
git -C "$NORMAL_REPO" add -A && git -C "$NORMAL_REPO" commit -qm normal-docs-only

normal_gate0() {
  local home helper_start helper_end gate_start gate_end
  home="$TMP/normal-home"
  mkdir -p "$home/.cargo/bin"
  cat > "$home/.cargo/bin/ezgha" <<EOF
#!/usr/bin/env bash
echo "ezgha-$1"
EOF
  chmod +x "$home/.cargo/bin/ezgha"
  helper_start=$(grep -n '^verify_deployed_sha() {' "$VERIFY" | cut -d: -f1)
  helper_end=$(awk -v start="$helper_start" 'NR > start && /^}$/ { print NR; exit }' "$VERIFY")
  gate_start=$(grep -n '^# --- Gate 0: Deployed code == committed code ---$' "$VERIFY" | cut -d: -f1)
  gate_end=$(grep -n '^# --- Gate 1: Code quality ---$' "$VERIFY" | cut -d: -f1)
  [ -n "$helper_start" ] && [ -n "$helper_end" ] && [ -n "$gate_start" ] && [ -n "$gate_end" ] || fail "could not extract normal Gate 0 dispatch"
  {
    echo 'FAILURES=0'
    echo 'fail() { echo "FAIL: $*" >&2; FAILURES=1; }'
    echo 'pass() { echo "PASS: $*"; }'
    grep '^GATE0_BUILD_INPUTS=' "$VERIFY"
    sed -n "${helper_start},${helper_end}p" "$VERIFY"
    sed -n "${gate_start},$((gate_end - 1))p" "$VERIFY"
    echo 'exit "$FAILURES"'
  } > "$TMP/normal-gate0.sh"
  (cd "$NORMAL_REPO" && HOME="$home" bash "$TMP/normal-gate0.sh" 2>&1)
}

rc=0; out=$(normal_gate0 "$NORMAL_DEPLOYED") || rc=$?
[ "$rc" -eq 0 ] || fail "normal Gate 0 must accept a deployed SHA that trails HEAD only by docs: $out"
grep -Fq 'matches HEAD (' <<<"$out" \
  || fail "normal Gate 0 omitted tolerant deployed-SHA pass message: $out"

echo "VERIFY_EXIT_GATE0_TEST: PASS"
