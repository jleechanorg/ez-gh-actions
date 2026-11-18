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

SCRATCH_CANDIDATE="$("${HOME}/.claude/skills/scratch-space/scripts/scratch-dir.sh" hydration-test 2>/dev/null || true)"
WORKDIR=""
for base in "${SCRATCH_CANDIDATE}" "${TMPDIR:-/tmp}"; do
  [ -n "${base}" ] || continue
  mkdir -p "${base}" 2>/dev/null || continue
  probe="$(mktemp -d "${base}/ezgha-hydration-probe.XXXXXX" 2>/dev/null || true)"
  [ -n "${probe}" ] || continue
  if git init -q "${probe}/r" 2>/dev/null \
     && printf 'ok\n' | git -C "${probe}/r" hash-object -w --stdin >/dev/null 2>&1; then
    rm -rf "${probe}"
    WORKDIR="$(mktemp -d "${base}/ezgha-hydration-run.XXXXXX")"
    break
  fi
  rm -rf "${probe}"
done
if [ -z "${WORKDIR}" ] || [ "${WORKDIR}" = "/" ]; then
  echo "FAIL: unable to allocate git-capable temp workspace" >&2
  exit 1
fi
trap 'if [ -n "${WORKDIR:-}" ] && [ "${WORKDIR}" != "/" ]; then rm -rf "${WORKDIR}"; fi' EXIT

info "Using IMAGE=${IMAGE}, WORKDIR=${WORKDIR}"

# ── Build bare upstream repo (>50 commits/blobs), immutable generation, and +2 advance ──
UPSTREAM_GIT="${WORKDIR}/upstream.git"
SEED_WORK="${WORKDIR}/seed-work"
MIRROR_ROOT="${WORKDIR}/mirrors"
GEN_DIR="${MIRROR_ROOT}/generations/jleechanorg__testrepo.1000"
ACTIVE_DIR="${MIRROR_ROOT}/active"

export HERMES_SKIP_EXAMPLE_COM_GUARD=1
git init --bare -b main "${UPSTREAM_GIT}" >/dev/null || { echo "FAIL: git init bare failed" >&2; exit 1; }
git clone "${UPSTREAM_GIT}" "${SEED_WORK}" >/dev/null 2>&1 || { echo "FAIL: git clone fixture failed" >&2; exit 1; }
git -C "${SEED_WORK}" config core.hooksPath /dev/null || { echo "FAIL: git config core.hooksPath failed" >&2; exit 1; }
git -C "${SEED_WORK}" config user.email "jleechan2015@users.noreply.github.com" || { echo "FAIL: git config email failed" >&2; exit 1; }
git -C "${SEED_WORK}" config user.name "ezgha-test" || { echo "FAIL: git config name failed" >&2; exit 1; }

for i in $(seq 1 55); do
  printf 'seed-blob-%03d-%s\n' "${i}" "$(printf 'x%.0s' {1..128})" > "${SEED_WORK}/file_${i}.txt"
  git -C "${SEED_WORK}" add "file_${i}.txt" || { echo "FAIL: git add failed" >&2; exit 1; }
  git -C "${SEED_WORK}" commit -q -m "seed commit ${i}" || { echo "FAIL: git commit failed" >&2; exit 1; }
done
git -C "${SEED_WORK}" push -q origin main || { echo "FAIL: git push initial failed" >&2; exit 1; }

mkdir -p "${MIRROR_ROOT}/generations" "${ACTIVE_DIR}" || { echo "FAIL: mkdir mirror dirs failed" >&2; exit 1; }
git clone --bare "${UPSTREAM_GIT}" "${GEN_DIR}" >/dev/null 2>&1 || { echo "FAIL: git clone --bare generation failed" >&2; exit 1; }
SEED_SHA="$(git -C "${GEN_DIR}" rev-parse refs/heads/main)" || { echo "FAIL: rev-parse SEED_SHA failed" >&2; exit 1; }
printf '%s\n' "${SEED_SHA}" > "${GEN_DIR}/SEED_SHA"
rm -rf "${GEN_DIR}/objects/info/commit-graph"*
ln -s "../generations/jleechanorg__testrepo.1000" "${ACTIVE_DIR}/jleechanorg__testrepo" || { echo "FAIL: symlink active failed" >&2; exit 1; }

for i in 56 57; do
  printf 'delta-blob-%03d-%s\n' "${i}" "$(printf 'y%.0s' {1..128})" > "${SEED_WORK}/file_${i}.txt"
  git -C "${SEED_WORK}" add "file_${i}.txt" || { echo "FAIL: git add delta failed" >&2; exit 1; }
  git -C "${SEED_WORK}" commit -q -m "delta commit ${i}" || { echo "FAIL: git commit delta failed" >&2; exit 1; }
done
git -C "${SEED_WORK}" push -q origin main || { echo "FAIL: git push delta failed" >&2; exit 1; }

chmod -R a+rX "${UPSTREAM_GIT}" "${MIRROR_ROOT}" || { echo "FAIL: chmod fixture failed" >&2; exit 1; }
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
    # Case 3: matching origin, but fetching an explicit non-origin remote passes straight through
    git init -b main /tmp/fo3 >/dev/null
    git -C /tmp/fo3 remote add origin "https://github.com/jleechanorg/testrepo.git"
    git -C /tmp/fo3 remote add upstream "file:///upstream.git"
    EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors git -C /tmp/fo3 fetch --depth 1 upstream main >/dev/null 2>&1 && echo "FO_NONORIGIN_RC=0"
    [ -e /tmp/fo3/.git/ezgha-hydrated ] && echo "FO_NONORIGIN_HYDRATED=PRESENT" || echo "FO_NONORIGIN_HYDRATED=ABSENT"
  ' 2>&1)
echo "${FAILOPEN_OUT}" | sed 's/^/    /'
if printf '%s\n' "${FAILOPEN_OUT}" | grep -q "^FO_MISSING_RC=0$" \
  && printf '%s\n' "${FAILOPEN_OUT}" | grep -q "^FO_UNMATCHED_RC=0$" \
  && printf '%s\n' "${FAILOPEN_OUT}" | grep -q "^FO_NONORIGIN_RC=0$" \
  && printf '%s\n' "${FAILOPEN_OUT}" | grep -q "^FO_NONORIGIN_HYDRATED=ABSENT$"; then
  ok "(d) fail-open invariant verified for missing mirror dir, non-matching repo, and non-origin remote"
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

# ── (g) Partial failed git fetch (ref advanced) preserves alternates ──
echo "=== (g) Partial failed git fetch that updated a ref preserves alternates ==="
PARTIAL_OUT=$(docker run --rm \
  -v "${UPSTREAM_GIT}:/upstream.git:ro" \
  -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
  -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
  "${IMAGE}" bash -lc '
    set -euo pipefail
    ORIGIN_URL="https://github.com/jleechanorg/testrepo.git"
    git config --global "url.file:///upstream.git.insteadOf" "${ORIGIN_URL}"
    git init -b main /tmp/rb2 >/dev/null
    git -C /tmp/rb2 remote add origin "${ORIGIN_URL}"
    empty_tree="$(git -C /tmp/rb2 mktree </dev/null)"
    blk_commit="$(git -C /tmp/rb2 -c user.name=ezgha-test -c user.email=jleechan2015@users.noreply.github.com commit-tree "${empty_tree}" -m blocker)"
    git -C /tmp/rb2 update-ref refs/heads/blocker "${blk_commit}"
    set +e
    git -C /tmp/rb2 fetch origin refs/heads/main:refs/heads/advanced refs/heads/main:refs/heads/blocker/sub >/tmp/rb2.log 2>&1
    rc=$?
    set -e
    cat /tmp/rb2.log
    echo "PARTIAL_FETCH_RC=${rc}"
    [ -e /tmp/rb2/.git/ezgha-hydrated ] && echo "HYDRATED_MARKER=PRESENT" || echo "HYDRATED_MARKER=ABSENT"
    [ -f /tmp/rb2/.git/objects/info/alternates ] && echo "ALTERNATES=PRESENT" || echo "ALTERNATES=ABSENT"
    git -C /tmp/rb2 show-ref | grep -q "refs/heads/advanced" && echo "ADVANCED_REF=PRESENT" || echo "ADVANCED_REF=ABSENT"
    git -C /tmp/rb2 show-ref | grep -q "refs/ezgha-seed/" && echo "RESIDUE=FOUND" || echo "RESIDUE=CLEAN"
    git -C /tmp/rb2 fsck --full >/tmp/rb2-fsck.log 2>&1 && echo "FSCK_RC=0" || { cat /tmp/rb2-fsck.log; echo "FSCK_RC=1"; }
  ' 2>&1)
echo "${PARTIAL_OUT}" | sed 's/^/    /'
if printf '%s\n' "${PARTIAL_OUT}" | grep -Eq "^PARTIAL_FETCH_RC=[1-9][0-9]*$" \
  && printf '%s\n' "${PARTIAL_OUT}" | grep -q "^HYDRATED_MARKER=PRESENT$" \
  && printf '%s\n' "${PARTIAL_OUT}" | grep -q "^ALTERNATES=PRESENT$" \
  && printf '%s\n' "${PARTIAL_OUT}" | grep -q "^ADVANCED_REF=PRESENT$" \
  && printf '%s\n' "${PARTIAL_OUT}" | grep -q "^RESIDUE=CLEAN$" \
  && printf '%s\n' "${PARTIAL_OUT}" | grep -q "^FSCK_RC=0$"; then
  ok "(g) failed git fetch that updated a ref preserves alternates and passes fsck"
else
  bad "(g) failed git fetch that updated a ref dropped alternates or broke repo"
fi

# ── (h) Two-step shallow then --unshallow keeps SEED_REF advertisement ──
echo "=== (h) Two-step wrapped fetch (--depth=1 then --unshallow) preserves SEED_REF ==="
TWOSTEP_OUT=$(docker run --rm \
  -v "${UPSTREAM_GIT}:/upstream.git:ro" \
  -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
  -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
  -e SEED_SHA="${SEED_SHA}" \
  "${IMAGE}" bash -lc '
    set -euo pipefail
    ORIGIN_URL="https://github.com/jleechanorg/testrepo.git"
    git config --global "url.file:///upstream.git.insteadOf" "${ORIGIN_URL}"
    git init -b main /tmp/twostep >/dev/null
    git -C /tmp/twostep remote add origin "${ORIGIN_URL}"
    git -C /tmp/twostep fetch --depth=1 origin main >/tmp/step1.log 2>&1
    [ -e /tmp/twostep/.git/ezgha-hydrated ] && echo "STEP1_HYDRATED=PRESENT" || echo "STEP1_HYDRATED=ABSENT"
    before_loose="$(git -C /tmp/twostep count-objects -v | awk "/^count:/ {print \$2}")"
    before_pack="$(git -C /tmp/twostep count-objects -v | awk "/^in-pack:/ {print \$2}")"
    before_objs=$((before_loose + before_pack))
    set +e
    GIT_TRACE_PACKET=1 git -C /tmp/twostep fetch --unshallow origin main --progress >/tmp/step2.log 2>&1
    rc=$?
    set -e
    cat /tmp/step2.log
    echo "STEP2_FETCH_RC=${rc}"
    if git -C /tmp/twostep show-ref | grep -q "refs/ezgha-seed/"; then
      echo "RESIDUE_CHECK=FOUND"
    else
      echo "RESIDUE_CHECK=CLEAN"
    fi
    git -C /tmp/twostep fsck --full >/tmp/step2-fsck.log 2>&1 && echo "FSCK_RC=0" || { cat /tmp/step2-fsck.log; echo "FSCK_RC=1"; }
    loose_count="$(git -C /tmp/twostep count-objects -v | awk "/^count:/ {print \$2}")"
    pack_count="$(git -C /tmp/twostep count-objects -v | awk "/^in-pack:/ {print \$2}")"
    after_objs=$((loose_count + pack_count))
    echo "TRANSFERRED_OBJECTS=$((after_objs - before_objs))"
  ' 2>&1)
echo "${TWOSTEP_OUT}" | sed 's/^/    /'
TWOSTEP_TRANSFERRED="$(printf '%s\n' "${TWOSTEP_OUT}" | awk -F= '/^TRANSFERRED_OBJECTS=/{print $2}' | tail -n1)"
if printf '%s\n' "${TWOSTEP_OUT}" | grep -q "^STEP1_HYDRATED=PRESENT$" \
  && printf '%s\n' "${TWOSTEP_OUT}" | grep -q "^STEP2_FETCH_RC=0$" \
  && printf '%s\n' "${TWOSTEP_OUT}" | grep -q "have ${SEED_SHA}" \
  && printf '%s\n' "${TWOSTEP_OUT}" | grep -q "^RESIDUE_CHECK=CLEAN$" \
  && printf '%s\n' "${TWOSTEP_OUT}" | grep -q "^FSCK_RC=0$" \
  && [ -n "${TWOSTEP_TRANSFERRED}" ] && [ "${TWOSTEP_TRANSFERRED}" -le 15 ]; then
  ok "(h) two-step --depth=1 -> --unshallow advertised have <SEED_SHA>, transferred_objects=${TWOSTEP_TRANSFERRED} <= 15, clean refs and fsck"
else
  bad "(h) two-step --depth=1 -> --unshallow failed (transferred_objects=${TWOSTEP_TRANSFERRED:-unknown})"
fi

# ── (10) Concurrent-borrower rollback guard ──
echo "=== (10) Failed initial hydrating fetch preserves alternates when concurrent borrower active ==="
BORROWER_OUT=$(docker run --rm \
  -v "${UPSTREAM_GIT}:/upstream.git:ro" \
  -v "${MIRROR_ROOT}:/opt/ezgha-git-mirrors:ro" \
  -e EZGHA_GIT_MIRRORS=/opt/ezgha-git-mirrors \
  -e SEED_SHA="${SEED_SHA}" \
  "${IMAGE}" bash -lc '
    set -euo pipefail
    ORIGIN_URL="https://github.com/jleechanorg/testrepo.git"
    git config --global "url.file:///upstream.git.insteadOf" "${ORIGIN_URL}"
    git init -b main /tmp/cb >/dev/null
    git -C /tmp/cb remote add origin "${ORIGIN_URL}"
    cat > /tmp/cb-upload-pack.sh <<EOF
#!/usr/bin/env bash
# Simulate a concurrent borrower attaching while this initial fetch is in flight.
/usr/bin/git -C /tmp/cb update-ref refs/ezgha-seed/pid-concurrent-borrower "${SEED_SHA}" ""
exit 1
EOF
    chmod +x /tmp/cb-upload-pack.sh
    set +e
    git -C /tmp/cb fetch --upload-pack /tmp/cb-upload-pack.sh origin refs/heads/nonexistent-branch >/dev/null 2>&1
    rc=$?
    set -e
    echo "CB_FETCH_RC=${rc}"
    [ -e /tmp/cb/.git/ezgha-hydrated ] && echo "CB_HYDRATED=PRESENT" || echo "CB_HYDRATED=ABSENT"
    [ -f /tmp/cb/.git/objects/info/alternates ] && echo "CB_ALTERNATES=PRESENT" || echo "CB_ALTERNATES=ABSENT"
    seed_refs="$(/usr/bin/git -C /tmp/cb for-each-ref --format="%(refname)" refs/ezgha-seed)"
    echo "CB_SEED_REFS=${seed_refs}"
    obj_type="$(/usr/bin/git -C /tmp/cb cat-file -t "${SEED_SHA}" 2>/dev/null || echo missing)"
    echo "CB_SEED_OBJ_TYPE=${obj_type}"
  ' 2>&1)
echo "${BORROWER_OUT}" | sed 's/^/    /'
if printf '%s\n' "${BORROWER_OUT}" | grep -Eq "^CB_FETCH_RC=[1-9][0-9]*$" \
  && printf '%s\n' "${BORROWER_OUT}" | grep -q "^CB_HYDRATED=PRESENT$" \
  && printf '%s\n' "${BORROWER_OUT}" | grep -q "^CB_ALTERNATES=PRESENT$" \
  && printf '%s\n' "${BORROWER_OUT}" | grep -q "^CB_SEED_REFS=refs/ezgha-seed/pid-concurrent-borrower$" \
  && printf '%s\n' "${BORROWER_OUT}" | grep -q "^CB_SEED_OBJ_TYPE=commit$"; then
  ok "(10) failed initial fetch deleted only its own SEED_REF and preserved alternates/ezgha-hydrated for concurrent borrower"
else
  bad "(10) concurrent-borrower rollback guard failed"
fi

echo
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
