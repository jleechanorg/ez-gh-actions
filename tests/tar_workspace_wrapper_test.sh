#!/usr/bin/env bash
# Regression unit test for docker/tar-workspace-wrapper.sh option parsing.
# Exercises the real wrapper script with a stubbed REAL_TAR (plus a real-tar
# -C + --exclude integration check) in an isolated temp workspace.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_WRAPPER="${REPO_ROOT}/docker/tar-workspace-wrapper.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

ok() { printf '  [OK] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

FAKE_WORKSPACE="${WORK}/workspace"
OUTSIDE_DIR="${WORK}/outside"
SIBLING_EVIL="${WORK}/workspaceevil"
mkdir -p "${FAKE_WORKSPACE}/owner/repo" "${OUTSIDE_DIR}" "${SIBLING_EVIL}"

STUB_TAR="${WORK}/stub-tar"
TAR_LOG="${WORK}/tar-args.log"
cat > "${STUB_TAR}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${TAR_LOG:?}"
{
  printf 'PWD=%s\n' "${PWD}"
  printf 'ARGC=%s\n' "$#"
  for a in "$@"; do
    printf 'ARG=%s\n' "${a}"
  done
} > "${TAR_LOG}"
exit 0
EOF
chmod +x "${STUB_TAR}"

WRAPPER="${WORK}/tar-wrapper"
sed \
  -e "s|^REAL_TAR=/usr/bin/tar$|REAL_TAR=\"${STUB_TAR}\"|" \
  -e "s|^WORKSPACE_ROOT=/home/runner/_work$|WORKSPACE_ROOT=\"${FAKE_WORKSPACE}\"|" \
  "${SRC_WRAPPER}" > "${WRAPPER}"
chmod +x "${WRAPPER}"

grep -q "^REAL_TAR=\"${STUB_TAR}\"$" "${WRAPPER}" || {
  echo "FATAL: failed to patch REAL_TAR in test copy of tar-workspace-wrapper.sh" >&2
  exit 2
}
grep -q "^WORKSPACE_ROOT=\"${FAKE_WORKSPACE}\"$" "${WRAPPER}" || {
  echo "FATAL: failed to patch WORKSPACE_ROOT in test copy of tar-workspace-wrapper.sh" >&2
  exit 2
}

REAL_TAR_WRAPPER="${WORK}/real-tar-wrapper"
sed \
  -e "s|^WORKSPACE_ROOT=/home/runner/_work$|WORKSPACE_ROOT=\"${FAKE_WORKSPACE}\"|" \
  "${SRC_WRAPPER}" > "${REAL_TAR_WRAPPER}"
chmod +x "${REAL_TAR_WRAPPER}"

export EZGHA_VIRTIOFS_WORKSPACE=1
export TAR_LOG

assert_passthrough() {
  local label="$1"
  shift
  : > "${TAR_LOG}"
  "${WRAPPER}" "$@"
  local expected_argc="$#"
  local actual_argc
  actual_argc="$(sed -n 's/^ARGC=//p' "${TAR_LOG}")"
  if grep -q '^ARG=/tmp/ezgha-tar-stage\.' "${TAR_LOG}"; then
    bad "${label}: unexpectedly entered staged extract mode: $(tr '\n' ' ' < "${TAR_LOG}")"
    return
  fi
  if [ "${actual_argc}" != "${expected_argc}" ]; then
    bad "${label}: argc mismatch (expected ${expected_argc}, got ${actual_argc}): $(tr '\n' ' ' < "${TAR_LOG}")"
    return
  fi
  local i=1
  for expected_arg in "$@"; do
    local actual_arg
    actual_arg="$(grep '^ARG=' "${TAR_LOG}" | sed -n "${i}p" | sed 's/^ARG=//')"
    if [ "${actual_arg}" != "${expected_arg}" ]; then
      bad "${label}: arg ${i} mismatch (expected '${expected_arg}', got '${actual_arg}')"
      return
    fi
    i=$((i + 1))
  done
  ok "${label}"
}

assert_staged_extract() {
  local label="$1"
  shift
  : > "${TAR_LOG}"
  "${WRAPPER}" "$@"
  if grep -q '^ARG=/tmp/ezgha-tar-stage\.' "${TAR_LOG}" && grep -q '^ARG=-C$' "${TAR_LOG}"; then
    ok "${label}"
  else
    bad "${label}: expected staged extract (-C /tmp/ezgha-tar-stage.*), got: $(tr '\n' ' ' < "${TAR_LOG}")"
  fi
}

echo "=== 1. Long options containing 'x' must NOT trigger extract mode ==="
cd "${FAKE_WORKSPACE}/owner/repo"
assert_passthrough "--exclude=foo with -czf" -czf out.tgz --exclude=foo dir
assert_passthrough "--exclude foo with -czf" -czf out.tgz --exclude foo dir
assert_passthrough "--exclude-vcs with -czf" -czf out.tgz --exclude-vcs dir
assert_passthrough "--xz -cf" --xz -cf out.tar.xz dir
assert_passthrough "--xattrs with -cf" -cf out.tar --xattrs dir

cd "${OUTSIDE_DIR}"
assert_passthrough "-C <workspace> with -czf --exclude=foo" -C "${FAKE_WORKSPACE}/owner/repo" -czf /tmp/out.tgz --exclude=foo dir
assert_passthrough "--directory=<workspace> with --xz -cf" "--directory=${FAKE_WORKSPACE}/owner/repo" --xz -cf /tmp/out.tar.xz dir
assert_passthrough "--directory <workspace> with -czf --exclude-vcs" --directory "${FAKE_WORKSPACE}/owner/repo" -czf /tmp/out.tgz --exclude-vcs dir

echo "=== 2. Extract flags (-x, --extract, --get, short bundles) MUST trigger staged extract mode ==="
cd "${FAKE_WORKSPACE}/owner/repo"
assert_staged_extract "-xf" -xf archive.tar
assert_staged_extract "-xzf" -xzf archive.tar.gz
assert_staged_extract "old-style xzf" xzf archive.tar.gz
assert_staged_extract "--extract" --extract -f archive.tar
assert_staged_extract "--get" --get -f archive.tar
assert_staged_extract "--xz -xf" --xz -xf archive.tar.xz
assert_staged_extract "-x --exclude=foo" -x --exclude=foo -f archive.tar

cd "${OUTSIDE_DIR}"
assert_staged_extract "-C <workspace> -xf" -C "${FAKE_WORKSPACE}/owner/repo" -xf archive.tar
assert_staged_extract "--directory=<workspace> -xzf" "--directory=${FAKE_WORKSPACE}/owner/repo" -xzf archive.tar.gz
assert_staged_extract "--directory <workspace> --extract" --directory "${FAKE_WORKSPACE}/owner/repo" --extract -f archive.tar
# Verify original -C/--directory was stripped when replaced by -C <stage>
c_count="$(grep -c '^ARG=-C$' "${TAR_LOG}")"
if [ "${c_count}" = "1" ] && ! grep -q '^ARG=--directory' "${TAR_LOG}"; then
  ok "--directory <workspace> replaced cleanly by single -C <stage>"
else
  bad "--directory <workspace> was not stripped cleanly: $(tr '\n' ' ' < "${TAR_LOG}")"
fi

echo "=== 3. Boundary and multi-C guards remain intact ==="
cd "${OUTSIDE_DIR}"
assert_passthrough "extract outside workspace is passthrough" -xf archive.tar
assert_passthrough "sibling prefix _workspaceevil is passthrough" -C "${SIBLING_EVIL}" -xf archive.tar
assert_passthrough "multiple -C defers to native tar" -C "${FAKE_WORKSPACE}/owner/repo" -xf archive.tar a -C "${FAKE_WORKSPACE}/owner/repo" b

echo "=== 4. Real tar integration: -C <workspace> -czf --exclude=foo works end-to-end ==="
mkdir -p "${FAKE_WORKSPACE}/owner/repo/dir"
printf 'keep\n' > "${FAKE_WORKSPACE}/owner/repo/dir/keep.txt"
printf 'skip\n' > "${FAKE_WORKSPACE}/owner/repo/dir/foo"
REAL_ARCHIVE="${WORK}/real-out.tgz"
if (cd "${OUTSIDE_DIR}" && COPYFILE_DISABLE=1 "${REAL_TAR_WRAPPER}" -C "${FAKE_WORKSPACE}/owner/repo" -czf "${REAL_ARCHIVE}" --exclude=foo dir); then
  listing="$(/usr/bin/tar -tzf "${REAL_ARCHIVE}")"
  if printf '%s\n' "${listing}" | grep -q 'dir/keep.txt' && ! printf '%s\n' "${listing}" | grep -q 'dir/foo'; then
    ok "real tar -C <workspace> -czf --exclude=foo archived dir/keep.txt and excluded dir/foo"
  else
    bad "real tar archive contents unexpected: ${listing}"
  fi
else
  bad "real tar -C <workspace> -czf --exclude=foo failed"
fi

echo
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
