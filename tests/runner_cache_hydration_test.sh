#!/usr/bin/env bash
# Integration test for ezgha runner cold-start cache hydration:
#   1) Git mirror wrapper (/usr/local/bin/git + EZGHA_GIT_MIRRORS)
#   2) Baked Playwright Chromium + wheelhouse offline availability (--network=none)
#
# Usage:
#   EZGHA_TEST_IMAGE=ezgha-runner:hydration-test bash tests/runner_cache_hydration_test.sh

set -u
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

info() { printf '  [..] %s\n' "$1"; }
ok()   { printf '  [OK] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

if ! docker version >/dev/null 2>&1; then
  echo "SKIP: docker daemon unreachable (set DOCKER_HOST if using Colima) -- cannot run this integration test"
  exit 0
fi

IMAGE="${EZGHA_TEST_IMAGE:-ezgha-runner:latest}"
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "FAIL: ${IMAGE} not present locally"
  exit 1
fi

SCRATCH_BASE="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh hydration-test 2>/dev/null || echo /tmp)"
WORKDIR="${SCRATCH_BASE}/run-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

info "Using IMAGE=${IMAGE}, WORKDIR=${WORKDIR}"

# ── Build bare upstream repo (>50 commits/blobs), immutable generation, and +2 advance ──
UPSTREAM_GIT="${WORKDIR}/upstream.git"
SEED_WORK="${WORKDIR}/seed-work"
MIRROR_ROOT="${WORKDIR}/mirrors"
GEN_DIR="${MIRROR_ROOT}/generations/jleechanorg__testrepo.1000"
ACTIVE_DIR="${MIRROR_ROOT}/active"

git init --bare -b main "${UPSTREAM_GIT}" >/dev/null
git clone "${UPSTREAM_GIT}" "${SEED_WORK}" >/dev/null 2>&1
git -C "${SEED_WORK}" config user.email "ezgha-test@example.com"
git -C "${SEED_WORK}" config user.name "ezgha-test"

for i in $(seq 1 55); do
  printf 'seed-blob-%03d-%s\n' "${i}" "$(printf 'x%.0s' {1..128})" > "${SEED_WORK}/file_${i}.txt"
  git -C "${SEED_WORK}" add "file_${i}.txt"
  git -C "${SEED_WORK}" commit -q -m "seed commit ${i}"
done
git -C "${SEED_WORK}" push -q origin main

mkdir -p "${MIRROR_ROOT}/generations" "${ACTIVE_DIR}"
git clone --bare "${UPSTREAM_GIT}" "${GEN_DIR}" >/dev/null 2>&1
SEED_SHA="$(git -C "${GEN_DIR}" rev-parse refs/heads/main)"
printf '%s\n' "${SEED_SHA}" > "${GEN_DIR}/SEED_SHA"
rm -rf "${GEN_DIR}/objects/info/commit-graph"*
ln -s "../generations/jleechanorg__testrepo.1000" "${ACTIVE_DIR}/jleechanorg__testrepo"

for i in 56 57; do
  printf 'delta-blob-%03d-%s\n' "${i}" "$(printf 'y%.0s' {1..128})" > "${SEED_WORK}/file_${i}.txt"
  git -C "${SEED_WORK}" add "file_${i}.txt"
  git -C "${SEED_WORK}" commit -q -m "delta commit ${i}"
done
git -C "${SEED_WORK}" push -q origin main

chmod -R a+rX "${UPSTREAM_GIT}" "${MIRROR_ROOT}"
info "Created upstream (>55+2 commits) and generation SEED_SHA=${SEED_SHA}"

# ── (a) Unshallow git fetch with standard URL and tokenized URL ──
echo "=== (a) Unshallow git fetch with mirror hydration (standard + tokenized GitHub URLs) ==="

run_hydrated_fetch_case() {
  local label="$1"
  local origin_url="$2"
  local mode="$3"
  local out
  out=$(docker run --rm \
    -v "${UPSTREAM_GIT}:/upstream.git:ro" \
    -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
    -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
    -e ORIGIN_URL="${origin_url}" \
    -e SEED_SHA="${SEED_SHA}" \
    -e FETCH_MODE="${mode}" \
    "${IMAGE}" bash -lc '
      set -euo pipefail
      git config --global "url.file:///upstream.git.insteadOf" "${ORIGIN_URL}"
      if [ "${FETCH_MODE}" = "unshallow" ]; then
        git clone --depth=1 file:///upstream.git /tmp/repo >/dev/null 2>&1
        git -C /tmp/repo remote set-url origin "${ORIGIN_URL}"
        fetch_args=(fetch --unshallow origin main)
      else
        git init -b main /tmp/repo >/dev/null
        git -C /tmp/repo remote add origin "${ORIGIN_URL}"
        fetch_args=(fetch origin main)
      fi
      actual_url="$(git -C /tmp/repo config --get remote.origin.url)"
      echo "ORIGIN_URL_CHECK=${actual_url}"
      before_loose="$(git -C /tmp/repo count-objects -v | awk "/^count:/ {print \$2}")"
      before_pack="$(git -C /tmp/repo count-objects -v | awk "/^in-pack:/ {print \$2}")"
      before_objs=$((before_loose + before_pack))
      set +e
      GIT_TRACE_PACKET=1 git -C /tmp/repo "${fetch_args[@]}" --progress >/tmp/fetch.log 2>&1
      rc=$?
      set -e
      cat /tmp/fetch.log
      echo "FETCH_RC=${rc}"
      if git -C /tmp/repo show-ref | grep -q "refs/ezgha-seed/"; then
        echo "RESIDUE_CHECK=FOUND"
      else
        echo "RESIDUE_CHECK=CLEAN"
      fi
      git -C /tmp/repo fsck --full >/tmp/fsck.log 2>&1 && echo "FSCK_RC=0" || { cat /tmp/fsck.log; echo "FSCK_RC=1"; }
      loose_count="$(git -C /tmp/repo count-objects -v | awk "/^count:/ {print \$2}")"
      pack_count="$(git -C /tmp/repo count-objects -v | awk "/^in-pack:/ {print \$2}")"
      after_objs=$((loose_count + pack_count))
      echo "TRANSFERRED_OBJECTS=$((after_objs - before_objs))"
    ' 2>&1)

  echo "${out}" | sed 's/^/    /'
  local transferred_objs
  transferred_objs="$(printf '%s\n' "${out}" | awk -F= '/^TRANSFERRED_OBJECTS=/{print $2}' | tail -n1)"

  if printf '%s\n' "${out}" | grep -q "^FETCH_RC=0$" \
    && printf '%s\n' "${out}" | grep -q "ORIGIN_URL_CHECK=${origin_url}" \
    && printf '%s\n' "${out}" | grep -q "have ${SEED_SHA}" \
    && printf '%s\n' "${out}" | grep -q "^RESIDUE_CHECK=CLEAN$" \
    && printf '%s\n' "${out}" | grep -q "^FSCK_RC=0$" \
    && [ -n "${transferred_objs}" ] && [ "${transferred_objs}" -le 15 ]; then
    ok "(a) ${label}: have <SEED_SHA> negotiated, transferred_objects=${transferred_objs} <= 15, no refs/ezgha-seed/ residue, fsck clean"
  else
    bad "(a) ${label}: failed assertion (transferred_objects=${transferred_objs:-unknown})"
  fi
}

run_hydrated_fetch_case "cold fetch standard URL" "https://github.com/jleechanorg/testrepo.git" "cold"
run_hydrated_fetch_case "unshallow fetch tokenized URL" "https://x-access-token:tok123@github.com/jleechanorg/testrepo" "unshallow"

# ── (b) Sequential shallow fetch: --depth=1 then --no-tags --depth=20 ──
echo "=== (b) Sequential shallow fetch (--depth=1 then --no-tags --depth=20) ==="
SHALLOW_OUT=$(docker run --rm \
  -v "${UPSTREAM_GIT}:/upstream.git:ro" \
  -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
  -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
  "${IMAGE}" bash -lc '
    set -euo pipefail
    ORIGIN_URL="https://github.com/jleechanorg/testrepo.git"
    git config --global "url.file:///upstream.git.insteadOf" "${ORIGIN_URL}"
    git init -b main /tmp/shallow-repo >/dev/null
    git -C /tmp/shallow-repo remote add origin "${ORIGIN_URL}"
    git -C /tmp/shallow-repo fetch --depth=1 origin main >/tmp/f1.log 2>&1 && echo "FETCH1_RC=0" || { cat /tmp/f1.log; echo "FETCH1_RC=1"; }
    git -C /tmp/shallow-repo fetch --no-tags --depth=20 origin main >/tmp/f2.log 2>&1 && echo "FETCH2_RC=0" || { cat /tmp/f2.log; echo "FETCH2_RC=1"; }
    git -C /tmp/shallow-repo fsck --full >/tmp/fsck.log 2>&1 && echo "FSCK_RC=0" || { cat /tmp/fsck.log; echo "FSCK_RC=1"; }
    if git -C /tmp/shallow-repo show-ref | grep -q "refs/ezgha-seed/"; then
      echo "RESIDUE_CHECK=FOUND"
    else
      echo "RESIDUE_CHECK=CLEAN"
    fi
  ' 2>&1)
echo "${SHALLOW_OUT}" | sed 's/^/    /'
if printf '%s\n' "${SHALLOW_OUT}" | grep -q "^FETCH1_RC=0$" \
  && printf '%s\n' "${SHALLOW_OUT}" | grep -q "^FETCH2_RC=0$" \
  && printf '%s\n' "${SHALLOW_OUT}" | grep -q "^FSCK_RC=0$" \
  && printf '%s\n' "${SHALLOW_OUT}" | grep -q "^RESIDUE_CHECK=CLEAN$"; then
  ok "(b) sequential shallow fetch (--depth=1 -> --no-tags --depth=20) + git fsck --full passed"
else
  bad "(b) sequential shallow fetch failed"
fi

# ── (c) Read-only security invariant ──
echo "=== (c) Read-only mirror mount security invariant ==="
RO_OUT=$(docker run --rm \
  -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
  -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
  "${IMAGE}" bash -lc '
    set +e
    out1="$(touch /opt/ezgha-git-mirrors/pwn 2>&1)"; rc1=$?
    out2="$(touch /opt/ezgha-git-mirrors/active/jleechanorg__testrepo/pwn 2>&1)"; rc2=$?
    echo "RC1=${rc1} OUT1=${out1}"
    echo "RC2=${rc2} OUT2=${out2}"
  ' 2>&1)
echo "${RO_OUT}" | sed 's/^/    /'
if printf '%s\n' "${RO_OUT}" | grep -Eq "^RC1=[1-9][0-9]* " \
  && printf '%s\n' "${RO_OUT}" | grep -Eq "^RC2=[1-9][0-9]* " \
  && printf '%s\n' "${RO_OUT}" | grep -q "Read-only file system"; then
  ok "(c) read-only mirror mount blocks writes inside container"
else
  bad "(c) read-only mirror mount check failed"
fi

# ── (d) Fail-open invariant ──
echo "=== (d) Fail-open invariant when EZGHA_GIT_MIRRORS missing or repo unmatched ==="
FAILOPEN_OUT=$(docker run --rm \
  -v "${UPSTREAM_GIT}:/upstream.git:ro" \
  -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
  "${IMAGE}" bash -lc '
    set -euo pipefail
    git config --global "url.file:///upstream.git.insteadOf" "https://github.com/jleechanorg/unmatched.git"
    # Case 1: missing EZGHA_GIT_MIRRORS path
    git init -b main /tmp/fo1 >/dev/null
    git -C /tmp/fo1 remote add origin "https://github.com/jleechanorg/unmatched.git"
    EZGHA_GIT_MIRRORS=/opt/does-not-exist git -C /tmp/fo1 fetch origin main >/dev/null 2>&1 && echo "FO_MISSING_RC=0"
    # Case 2: valid EZGHA_GIT_MIRRORS path, non-matching repo
    git init -b main /tmp/fo2 >/dev/null
    git -C /tmp/fo2 remote add origin "https://github.com/jleechanorg/unmatched.git"
    EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors git -C /tmp/fo2 fetch origin main >/dev/null 2>&1 && echo "FO_UNMATCHED_RC=0"
  ' 2>&1)
echo "${FAILOPEN_OUT}" | sed 's/^/    /'
if printf '%s\n' "${FAILOPEN_OUT}" | grep -q "^FO_MISSING_RC=0$" \
  && printf '%s\n' "${FAILOPEN_OUT}" | grep -q "^FO_UNMATCHED_RC=0$"; then
  ok "(d) fail-open invariant verified for missing mirror dir and non-matching repo"
else
  bad "(d) fail-open invariant failed"
fi

# ── (e) Baked Playwright Chromium offline proof ──
echo "=== (e) Baked Playwright Chromium + wheelhouse offline proof (--network=none) ==="
PW_OUT=$(docker run --rm --network=none "${IMAGE}" bash -lc '
  set -euo pipefail
  test -f /ms-playwright/PLAYWRIGHT_VERSION
  python3 -m venv /tmp/pw
  /tmp/pw/bin/pip install --no-index --find-links=/opt/baked-wheels playwright
  /tmp/pw/bin/python -m playwright install chromium
  echo "PW_OFFLINE_RC=0"
' 2>&1)
echo "${PW_OUT}" | sed 's/^/    /'
if printf '%s\n' "${PW_OUT}" | grep -q "^PW_OFFLINE_RC=0$"; then
  ok "(e) offline Playwright Chromium install succeeded with --network=none"
else
  bad "(e) offline Playwright Chromium proof failed"
fi

# ── (f) Post-exec rollback on failed git fetch ──
echo "=== (f) Post-exec rollback on failed git fetch ==="
ROLLBACK_OUT=$(docker run --rm \
  -v "${UPSTREAM_GIT}:/upstream.git:ro" \
  -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
  -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
  "${IMAGE}" bash -lc '
    set -euo pipefail
    ORIGIN_URL="https://github.com/jleechanorg/testrepo.git"
    git config --global "url.file:///upstream.git.insteadOf" "${ORIGIN_URL}"
    git init -b main /tmp/rb >/dev/null
    git -C /tmp/rb remote add origin "${ORIGIN_URL}"
    set +e
    git -C /tmp/rb fetch origin refs/heads/nonexistent-branch >/dev/null 2>&1
    rc=$?
    set -e
    echo "FAILED_FETCH_RC=${rc}"
    [ -e /tmp/rb/.git/ezgha-hydrated ] && echo "HYDRATED_MARKER=PRESENT" || echo "HYDRATED_MARKER=ABSENT"
    [ -e /tmp/rb/.git/objects/info/alternates ] && echo "ALTERNATES=PRESENT" || echo "ALTERNATES=ABSENT"
    git -C /tmp/rb show-ref | grep -q "refs/ezgha-seed/" && echo "RESIDUE=FOUND" || echo "RESIDUE=CLEAN"
  ' 2>&1)
echo "${ROLLBACK_OUT}" | sed 's/^/    /'
if printf '%s\n' "${ROLLBACK_OUT}" | grep -Eq "^FAILED_FETCH_RC=[1-9][0-9]*$" \
  && printf '%s\n' "${ROLLBACK_OUT}" | grep -q "^HYDRATED_MARKER=ABSENT$" \
  && printf '%s\n' "${ROLLBACK_OUT}" | grep -q "^ALTERNATES=ABSENT$" \
  && printf '%s\n' "${ROLLBACK_OUT}" | grep -q "^RESIDUE=CLEAN$"; then
  ok "(f) failed git fetch rolls back ezgha-hydrated, alternates, and refs/ezgha-seed/*"
else
  bad "(f) failed git fetch did not cleanly roll back hydration state"
fi

echo
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
