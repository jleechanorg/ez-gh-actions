#!/usr/bin/env bash
# Regression tests for scripts/refresh_runner_caches.sh,
# scripts/verify_live_cache_savings.sh, and install.sh cache-warm wiring.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFRESH_SCRIPT="${REPO_ROOT}/scripts/refresh_runner_caches.sh"
VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify_live_cache_savings.sh"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

# Resolve Scratch space and verify git object creation works (handles fuse2fs fallback).
SCRATCH_CANDIDATE="$("${HOME}/.claude/skills/scratch-space/scripts/scratch-dir.sh" cache-test 2>/dev/null || true)"
WORK=""
for base in "${SCRATCH_CANDIDATE}" "${TMPDIR:-/tmp}"; do
  [ -n "${base}" ] || continue
  mkdir -p "${base}" 2>/dev/null || continue
  probe="$(mktemp -d "${base}/ezgha-cache-probe.XXXXXX" 2>/dev/null || true)"
  [ -n "${probe}" ] || continue
  if git init -q "${probe}/r" 2>/dev/null \
     && printf 'ok\n' > "${probe}/r/f" \
     && git -C "${probe}/r" add f 2>/dev/null \
     && git -C "${probe}/r" -c user.name=t -c user.email=t@t commit -qm init 2>/dev/null; then
    rm -rf "${probe}"
    WORK="$(mktemp -d "${base}/ezgha-cache-test.XXXXXX")"
    break
  fi
  rm -rf "${probe}"
done

if [ -z "${WORK}" ] || [ "${WORK}" = "/" ]; then
  echo "FAIL: unable to allocate git-capable temp workspace" >&2
  exit 1
fi

# shellcheck disable=SC2329  # Invoked by EXIT trap.
cleanup() {
  if [ -n "${WORK}" ] && [ "${WORK}" != "/" ]; then
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

[ -x "${REFRESH_SCRIPT}" ] || fail "missing executable ${REFRESH_SCRIPT}"
[ -x "${VERIFY_SCRIPT}" ] || fail "missing executable ${VERIFY_SCRIPT}"

# ── (a) Disk-floor refusal ───────────────────────────────────────────────────
HOME_A="${WORK}/home_a"
MIRRORS_A="${WORK}/mirrors_a"
WHEELHOUSE_A="${WORK}/wheelhouse_a"
mkdir -p "${HOME_A}" "${MIRRORS_A}" "${WHEELHOUSE_A}"

CFG_A="${WORK}/cfg_a.toml"
cat > "${CFG_A}" <<EOF
version = 1

[runner]
image = "ezgha-runner:latest"
git_mirror_host_path = "${MIRRORS_A}"
wheelhouse_host_path = "${WHEELHOUSE_A}"

[limits]
min_free_disk_gb = 30
EOF

OUT_A="${WORK}/out_a.log"
HOME="${HOME_A}" EZGHA_CACHE_TEST_FREE_GB=20 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_A}" > "${OUT_A}" 2>&1 \
  || fail "disk-floor refusal exited non-zero"

grep -qiE 'warn|skip|below|disk|free' "${OUT_A}" \
  || fail "disk-floor refusal did not emit warning message: $(cat "${OUT_A}")"

if [ -d "${MIRRORS_A}/generations" ] && [ -n "$(ls -A "${MIRRORS_A}/generations" 2>/dev/null || true)" ]; then
  fail "disk-floor refusal created mirror generations"
fi
if [ -n "$(find "${WHEELHOUSE_A}" -name '*.whl' 2>/dev/null || true)" ]; then
  fail "disk-floor refusal created wheelhouse files"
fi
pass "(a) disk-floor refusal exited 0 with warning and created no artifacts"

# ── (b) Git mirror generation publish & safe reaping ─────────────────────────
HOME_B="${WORK}/home_b"
UPSTREAM_ROOT="${WORK}/upstream"
MIRRORS_B="${WORK}/mirrors_b"
WORK_CLONE="${WORK}/work_clone"
mkdir -p "${HOME_B}" "${UPSTREAM_ROOT}/jleechanorg" "${MIRRORS_B}"

export HERMES_SKIP_EXAMPLE_COM_GUARD=1
# Create bare upstream repo on `main`
git init --bare -q "${UPSTREAM_ROOT}/jleechanorg/testrepo.git"
git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" symbolic-ref HEAD refs/heads/main
git clone -q "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" "${WORK_CLONE}/testrepo"
git -C "${WORK_CLONE}/testrepo" config core.hooksPath /dev/null
git -C "${WORK_CLONE}/testrepo" checkout -q -B main
printf 'hello\n' > "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=jleechan2015@users.noreply.github.com commit -qm "initial main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_1="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"

# Create bare upstream repo with ONLY `master` (and broken HEAD -> refs/heads/main) to test fallback
git init --bare -q "${UPSTREAM_ROOT}/jleechanorg/masteronly.git"
git clone -q "${UPSTREAM_ROOT}/masteronly.git" "${WORK_CLONE}/masteronly" 2>/dev/null || git clone -q "${UPSTREAM_ROOT}/jleechanorg/masteronly.git" "${WORK_CLONE}/masteronly"
git -C "${WORK_CLONE}/masteronly" config core.hooksPath /dev/null
git -C "${WORK_CLONE}/masteronly" checkout -q -B master
printf 'master only\n' > "${WORK_CLONE}/masteronly/README.md"
git -C "${WORK_CLONE}/masteronly" add README.md
git -C "${WORK_CLONE}/masteronly" -c user.name=test -c user.email=jleechan2015@users.noreply.github.com commit -qm "initial master"
git -C "${WORK_CLONE}/masteronly" push -q origin master
git -C "${UPSTREAM_ROOT}/jleechanorg/masteronly.git" symbolic-ref HEAD refs/heads/main
MASTER_SHA="$(git -C "${UPSTREAM_ROOT}/jleechanorg/masteronly.git" rev-parse refs/heads/master)"

CFG_B="${WORK}/cfg_b.toml"
cat > "${CFG_B}" <<EOF
version = 1

[runner]
image = "ezgha-runner:latest"
git_mirror_host_path = "${MIRRORS_B}"

[limits]
min_free_disk_gb = 30
EOF

# Populate a shallow ~/projects/testrepo donor + unshallow ~/testrepo donor in HOME_B
# to prove find_local_donor skips shallow donors and resolves unshallow git-common-dir.
mkdir -p "${HOME_B}/projects"
git clone -q --depth=1 "file://${UPSTREAM_ROOT}/jleechanorg/testrepo.git" "${HOME_B}/projects/testrepo"
git clone -q "file://${UPSTREAM_ROOT}/jleechanorg/testrepo.git" "${HOME_B}/testrepo"

OUT_B1="${WORK}/out_b1.log"
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo jleechanorg/masteronly" \
  EZGHA_MIRROR_RETENTION_MIN=240 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels > "${OUT_B1}" 2>&1

grep -q "initializing staging mirror for jleechanorg/testrepo with local donor" "${OUT_B1}" \
  || fail "expected unshallow local donor to be used: $(cat "${OUT_B1}")"

python3 - "${MIRRORS_B}" "${SHA_1}" "${MASTER_SHA}" <<'PY'
import os, re, stat, sys

mirror_root, sha1, master_sha = sys.argv[1], sys.argv[2], sys.argv[3]

for slug, expected_sha in [("jleechanorg__testrepo", sha1), ("jleechanorg__masteronly", master_sha)]:
    active_link = os.path.join(mirror_root, "active", slug)
    assert os.path.islink(active_link), f"missing symlink: {active_link}"
    target = os.readlink(active_link)
    assert re.match(rf"^\.\./generations/{re.escape(slug)}\.[0-9]+$", target), (
        f"unexpected relative symlink target for {slug}: {target}"
    )
    gen_dir = os.path.realpath(active_link)
    assert os.path.isdir(gen_dir), f"missing resolved generation dir: {gen_dir}"

    seed_path = os.path.join(gen_dir, "SEED_SHA")
    main_path = os.path.join(gen_dir, "MAIN_SHA")
    assert os.path.isfile(seed_path), f"missing SEED_SHA: {seed_path}"
    assert os.path.isfile(main_path), f"missing MAIN_SHA: {main_path}"
    seed_val = open(seed_path).read().strip()
    main_val = open(main_path).read().strip()
    assert re.match(r"^[0-9a-f]{40}$", seed_val), f"invalid SEED_SHA: {seed_val}"
    assert re.match(r"^[0-9a-f]{40}$", main_val), f"invalid MAIN_SHA: {main_val}"
    assert seed_val == expected_sha, f"{slug} SEED_SHA mismatch: {seed_val} != {expected_sha}"
    assert main_val == expected_sha, f"{slug} MAIN_SHA mismatch: {main_val} != {expected_sha}"

    cg = os.path.join(gen_dir, "objects", "info", "commit-graph")
    cgs = os.path.join(gen_dir, "objects", "info", "commit-graphs")
    assert not os.path.exists(cg), f"commit-graph must not exist: {cg}"
    assert not os.path.exists(cgs), f"commit-graphs must not exist: {cgs}"

    for root, dirs, files in os.walk(gen_dir):
        mode = stat.S_IMODE(os.stat(root).st_mode)
        assert (mode & 0o005) == 0o005, f"dir not world r+x ({oct(mode)}): {root}"
        for f in files:
            fp = os.path.join(root, f)
            if f in ("SEED_SHA", "MAIN_SHA") or f.endswith((".pack", ".idx")):
                fmode = stat.S_IMODE(os.stat(fp).st_mode)
                assert (fmode & 0o004) == 0o004, f"file not world readable ({oct(fmode)}): {fp}"
PY
pass "(b1) mirror symlink, SEED_SHA/MAIN_SHA, master fallback, commit-graph removal, permissions"

# P1 Active generation protection: backdate mtime to 10h ago, re-run with NO upstream change
GEN1="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
python3 - "${GEN1}" <<'PY'
import os, sys, time
gen = sys.argv[1]
old = time.time() - 36000
os.utime(gen, (old, old))
PY

HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  EZGHA_MIRROR_RETENTION_MIN=240 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels

[ -d "${GEN1}" ] || fail "active generation was deleted despite no upstream change: ${GEN1}"
GEN1_AFTER="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
[ "${GEN1_AFTER}" = "${GEN1}" ] || fail "active symlink changed unexpectedly when upstream was unchanged"
pass "(b2) active generation protected from reaping even when mtime > retention"

# Advance upstream main by 1 commit, re-run:
# Even though GEN1 was published 10h ago, its post-retirement retention window
# starts NOW (at retirement), so GEN1 MUST remain on disk immediately after
# retirement while GEN2 becomes active.
printf 'second commit\n' >> "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=test@example.com commit -qm "second main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_2="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"

HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  EZGHA_MIRROR_RETENTION_MIN=240 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels

GEN2="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
[ "${GEN2}" != "${GEN1}" ] || fail "new generation did not replace active symlink after upstream advance"
[ -d "${GEN2}" ] || fail "new active generation missing: ${GEN2}"
[ -d "${GEN1}" ] || fail "just-retired generation was prematurely deleted despite 0m post-retirement age: ${GEN1}"
[ -f "${GEN1}/RETIRED_AT" ] || fail "missing RETIRED_AT marker on retired generation: ${GEN1}"
SEED_2="$(tr -d '[:space:]' < "${GEN2}/SEED_SHA")"
[ "${SEED_2}" = "${SHA_2}" ] || fail "new SEED_SHA mismatch: ${SEED_2} != ${SHA_2}"
pass "(b3) upstream advance published new generation and preserved just-retired generation for post-retirement window"

# Backdate GEN1's RETIRED_AT beyond retention (5h > 240m) and re-run: GEN1 is now safely reaped
python3 - "${GEN1}" <<'PY'
import os, sys, time
gen = sys.argv[1]
expired = int(time.time()) - 18000
with open(os.path.join(gen, "RETIRED_AT"), "w", encoding="utf-8") as fh:
    fh.write(f"{expired}\n")
os.utime(gen, (expired, expired))
PY

HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  EZGHA_MIRROR_RETENTION_MIN=240 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels

[ ! -e "${GEN1}" ] || fail "expired retired generation (>240m post-retirement) was NOT reaped: ${GEN1}"
[ -d "${GEN2}" ] || fail "active generation GEN2 missing after reaping GEN1: ${GEN2}"
pass "(b4) retired generation reaped once RETIRED_AT exceeds retention window"

# Per-repo error isolation: a broken first repo does not prevent refreshing a healthy second repo
printf 'third commit\n' >> "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=test@example.com commit -qm "third main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_3="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"

set +e
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/missing_broken_repo jleechanorg/testrepo" \
  EZGHA_MIRROR_RETENTION_MIN=240 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels >/dev/null 2>&1
ISO_RC=$?
set -e
[ "${ISO_RC}" -ne 0 ] || fail "expected non-zero exit when one mirror repo fails"
GEN3="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
SEED_3="$(tr -d '[:space:]' < "${GEN3}/SEED_SHA")"
[ "${SEED_3}" = "${SHA_3}" ] || fail "healthy second repo was blocked by broken first repo (${SEED_3} != ${SHA_3})"
pass "(b5) per-repo error isolation refreshes healthy repos even when an earlier repo fails"

# Dot-suffixed sibling repo protection (P1): refreshing jleechanorg/testrepo must never reap jleechanorg/testrepo.ai
FAKE_SIBLING_GEN="${MIRRORS_B}/generations/jleechanorg__testrepo.ai.1000000000"
mkdir -p "${FAKE_SIBLING_GEN}"
python3 - "${FAKE_SIBLING_GEN}" <<'PY'
import os, sys, time
old = time.time() - 36000
os.utime(sys.argv[1], (old, old))
PY
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  EZGHA_MIRROR_RETENTION_MIN=240 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ -d "${FAKE_SIBLING_GEN}" ] || fail "reap_old_generations deleted sibling dot-repo generation: ${FAKE_SIBLING_GEN}"
pass "(b6) dot-suffixed sibling repo generation protected from prefix collision"

# ── (b7) Default 480m retention preserves 5h-retired gen, reaps 9h-retired gen ──
GEN_B7="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000001"
mkdir -p "${GEN_B7}"
python3 - "${GEN_B7}" <<'PY'
import os, sys, time
t = int(time.time()) - 18000  # 5h ago (>240m, <480m)
with open(os.path.join(sys.argv[1], "RETIRED_AT"), "w", encoding="utf-8") as fh:
    fh.write(f"{t}\n")
PY
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ -d "${GEN_B7}" ] || fail "5h-retired generation was reaped under default 480m retention: ${GEN_B7}"

python3 - "${GEN_B7}" <<'PY'
import os, sys, time
t = int(time.time()) - 32400  # 9h ago (>480m)
with open(os.path.join(sys.argv[1], "RETIRED_AT"), "w", encoding="utf-8") as fh:
    fh.write(f"{t}\n")
PY
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ ! -e "${GEN_B7}" ] || fail "9h-retired generation was not reaped under default 480m retention: ${GEN_B7}"
pass "(b7) default 480m retention preserves 5h-retired and reaps 9h-retired generation"

# ── (b8) Live container pinning + fail-closed error handling ─────────────────
GEN_B8="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000002"
mkdir -p "${GEN_B8}"
RETIRED_B8="$(python3 -c 'import time; print(int(time.time()) - 32400)')"
printf '%s\n' "${RETIRED_B8}" > "${GEN_B8}/RETIRED_AT"

OLD_CONTAINER_EPOCH=$((RETIRED_B8 - 3600))
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH="${OLD_CONTAINER_EPOCH}" \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ -d "${GEN_B8}" ] || fail "retired generation was reaped while pre-retirement container is still running"

HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=error \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ -d "${GEN_B8}" ] || fail "retired generation was reaped despite docker error (expected fail-closed)"

NEW_CONTAINER_EPOCH=$((RETIRED_B8 + 120))
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH="${NEW_CONTAINER_EPOCH}" \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ ! -e "${GEN_B8}" ] || fail "retired generation was not reaped after oldest container advanced past RETIRED_AT+60"
pass "(b8) container pinning preserves pre-retirement gens, fails closed on error, reaps once past RETIRED_AT+60"

# ── (b9) Unstamped retired generation gets RETIRED_AT stamped on first observation
GEN_B9="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000003"
mkdir -p "${GEN_B9}"
python3 - "${GEN_B9}" <<'PY'
import os, sys, time
old = time.time() - 36000
os.utime(sys.argv[1], (old, old))
PY
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ -d "${GEN_B9}" ] || fail "unstamped retired generation was deleted immediately instead of being stamped"
[ -f "${GEN_B9}/RETIRED_AT" ] || fail "unstamped retired generation did not receive RETIRED_AT marker"
pass "(b9) unstamped retired generation stamped with RETIRED_AT on first observation"

# ── (b10) GIT_DIR=/bogus/gitdir in caller env does not break git operations ──
printf 'fourth commit\n' >> "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=test@example.com commit -qm "fourth main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_4="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"

HOME="${HOME_B}" \
  GIT_DIR=/bogus/gitdir \
  GIT_WORK_TREE=/bogus/wt \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
GEN4="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
SEED_4="$(tr -d '[:space:]' < "${GEN4}/SEED_SHA")"
[ "${SEED_4}" = "${SHA_4}" ] || fail "caller GIT_DIR broke refresh: ${SEED_4} != ${SHA_4}"
pass "(b10) GIT_DIR=/bogus/gitdir in caller environment sanitized cleanly"

# ── (b11) Default min_free_disk_gb=10 + buffer=5 & low-disk mode still reaps ──
CFG_LOW="${WORK}/cfg_low.toml"
MIRRORS_LOW="${WORK}/mirrors_low"
mkdir -p "${MIRRORS_LOW}/generations" "${MIRRORS_LOW}/active"
cat > "${CFG_LOW}" <<EOF
version = 1

[runner]
image = "ezgha-runner:latest"
git_mirror_host_path = "${MIRRORS_LOW}"
EOF

STALE_LOW="${MIRRORS_LOW}/generations/jleechanorg__testrepo.1000"
mkdir -p "${STALE_LOW}"
printf '1000\n' > "${STALE_LOW}/RETIRED_AT"

OUT_LOW="${WORK}/out_low.log"
HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=14 \
  EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_LOW}" --skip-wheels > "${OUT_LOW}" 2>&1 \
  || fail "low-disk mode exited non-zero"
grep -q "below safety floor+5 (15 GiB)" "${OUT_LOW}" \
  || fail "expected default floor+5 (15 GiB) warning, got: $(cat "${OUT_LOW}")"
[ ! -e "${STALE_LOW}" ] || fail "low-disk mode failed to reap retired generation ${STALE_LOW}"
[ ! -e "${MIRRORS_LOW}/active/jleechanorg__testrepo" ] || fail "low-disk mode should not clone/publish new active mirror"
pass "(b11) default floor=10 + buffer=5 enforces 15 GiB and low-disk mode reaps retired generations"

# ── (b12) Missing docker CLI fails closed (0.0) and preserves expired retired gen ──
GEN_B12="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000004"
mkdir -p "${GEN_B12}"
printf '1000\n' > "${GEN_B12}/RETIRED_AT"

MIN_BIN_B12="${WORK}/min_bin_b12"
mkdir -p "${MIN_BIN_B12}"
PYTHON3_REAL="$(command -v python3)"
GIT_REAL="$(which -a git | grep -v '/\.local/bin/' | head -n1 || command -v git)"
BASH_REAL="$(command -v bash)"
ln -s "${PYTHON3_REAL}" "${MIN_BIN_B12}/python3"
ln -s "${GIT_REAL}" "${MIN_BIN_B12}/git"

OUT_B12="${WORK}/out_b12.log"
env -u EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH \
  PATH="${MIN_BIN_B12}" \
  HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  "${BASH_REAL}" "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels > "${OUT_B12}" 2>&1 \
  || fail "missing docker CLI fail-closed test exited non-zero: $(cat "${OUT_B12}")"
[ -d "${GEN_B12}" ] || fail "expired retired generation was deleted when docker CLI was missing: ${GEN_B12}"
grep -q "docker CLI not found; failing closed to preserve retired generations" "${OUT_B12}" \
  || fail "expected missing docker CLI fail-closed warning, got: $(cat "${OUT_B12}")"
pass "(b12) missing docker CLI fails closed (0.0) and preserves expired retired generation"

# ── (d) Wheelhouse relative -r base.txt closure, manifest SHA, separate pip solve ──
HOME_D="${WORK}/home_d"
WH_D="${WORK}/wheelhouse_d"
REQ_DIR="${WORK}/reqs_d"
FAKE_BIN="${WORK}/fake_bin"
DOCKER_LOG="${WORK}/fake_docker.log"
mkdir -p "${HOME_D}" "${WH_D}" "${REQ_DIR}" "${FAKE_BIN}"

printf 'requests==2.31.0\n' > "${REQ_DIR}/base.txt"
mkdir -p "${REQ_DIR}/sub"
printf -- '-r ../base.txt\npytest-mock==3.12.0\n' > "${REQ_DIR}/sub/requirements-test.txt"

cat > "${FAKE_BIN}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
if [ "${sub}" = "info" ]; then
  exit 0
elif [ "${sub}" = "image" ] && [ "${2:-}" = "inspect" ]; then
  echo "sha256:fakeimageid"
  exit 0
elif [ "${sub}" = "run" ]; then
  if echo "$*" | grep -q "PLAYWRIGHT_VERSION"; then
    echo "1.65.2"
    exit 0
  fi
  printf 'ARGS:%s\n' "$*" >> "${FAKE_DOCKER_LOG}"
  payload="$(cat)"
  printf 'PAYLOAD:%s\n' "${payload}" >> "${FAKE_DOCKER_LOG}"
  if [ "${FAKE_DOCKER_FAIL:-0}" = "1" ]; then
    exit 1
  fi
  # Verify no /req_mounts bind, staged_files layout under /tmp/ezgha-reqs, wheel staging, and live symlink preservation
  python3 - "${payload}" "${FAKE_WH_HOST}" "${FAKE_EXPECT_SYMLINK:-0}" "$@" <<'PY'
import io, json, os, subprocess, sys, tempfile

payload_raw = sys.argv[1]
payload = json.loads(payload_raw)
wh_host = sys.argv[2]
expect_symlink = sys.argv[3] == "1"
args = sys.argv[4:]

assert not any(":/req_mounts/" in a for a in args), f"unexpected /req_mounts bind in {args}"
binds = [args[i + 1] for i, a in enumerate(args) if a == "-v"]
assert binds == [f"{wh_host}:/wheelhouse"], f"expected only /wheelhouse bind, got {binds}"

if expect_symlink:
    live_link = os.path.join(wh_host, "pkg0-1.0.0-999999ezgha-py3-none-any.whl")
    assert os.path.islink(live_link), f"expected build-tag symlink to stay live during docker run: {live_link}"

staged = dict(payload["staged_files"])
assert "0/base.txt" in staged and "requests==" in staged["0/base.txt"], staged
assert "0/sub/requirements-test.txt" in staged and "-r ../base.txt" in staged["0/sub/requirements-test.txt"], staged
assert payload["req_paths"] == ["/tmp/ezgha-reqs/0/sub/requirements-test.txt"], payload

container_script = args[-1]
assert "stage_root = '/tmp/ezgha-reqs'" in container_script, container_script
assert "wheel_stage = '/tmp/ezgha-wheel-stage'" in container_script, container_script

pip_calls = []
orig_run = subprocess.run
orig_stdin = sys.stdin
with tempfile.TemporaryDirectory() as stage_tmp, tempfile.TemporaryDirectory() as wheel_stage_tmp:
    def fake_run(cmd, **kwargs):
        pip_calls.append((list(cmd), bool(kwargs.get("check"))))
        for i in range(12):
            fn = f"pkg{i}-1.0.0-py3-none-any.whl"
            with open(os.path.join(wheel_stage_tmp, fn), "w", encoding="utf-8") as fh:
                fh.write("whl")
        return subprocess.CompletedProcess(cmd, 0)

    patched_script = (
        container_script
        .replace("stage_root = '/tmp/ezgha-reqs'", f"stage_root = {json.dumps(stage_tmp)}", 1)
        .replace("wheel_stage = '/tmp/ezgha-wheel-stage'", f"wheel_stage = {json.dumps(wheel_stage_tmp)}", 1)
        .replace("'/wheelhouse'", json.dumps(wh_host))
    )
    try:
        sys.stdin = io.StringIO(payload_raw)
        subprocess.run = fake_run
        exec(compile(patched_script, "<container_script>", "exec"), {"__name__": "__main__"})
    finally:
        subprocess.run = orig_run
        sys.stdin = orig_stdin

    staged_base = os.path.join(stage_tmp, "0", "base.txt")
    staged_req = os.path.join(stage_tmp, "0", "sub", "requirements-test.txt")
    assert os.path.isfile(staged_base), f"missing staged base: {staged_base}"
    assert os.path.isfile(staged_req), f"missing staged req: {staged_req}"
    resolved_inc = os.path.realpath(os.path.join(os.path.dirname(staged_req), "../base.txt"))
    assert resolved_inc == os.path.realpath(staged_base), (resolved_inc, staged_base)
    if expect_symlink:
        assert not os.path.exists(os.path.join(wheel_stage_tmp, "pkg0-1.0.0-999999ezgha-py3-none-any.whl")), (
            "symlinks must not be copied into /tmp/ezgha-wheel-stage"
        )

expected_base = [sys.executable, "-m", "pip", "download", "--dest", wheel_stage_tmp, "--find-links", wheel_stage_tmp]
assert len(pip_calls) == 2, f"expected 2 separate pip calls (core + reqs), got {pip_calls}"
assert pip_calls[0][0] == expected_base + payload["core"] and pip_calls[0][1] is True, pip_calls[0]
assert "-r" not in pip_calls[0][0], pip_calls[0]
assert pip_calls[1][0] == expected_base + ["-r", "/tmp/ezgha-reqs/0/sub/requirements-test.txt"] and pip_calls[1][1] is True, pip_calls[1]
PY
  exit 0
fi
exit 1
SH
chmod +x "${FAKE_BIN}/docker"

CFG_D="${WORK}/cfg_d.toml"
cat > "${CFG_D}" <<EOF
version = 1

[runner]
image = "ezgha-runner:latest"
wheelhouse_host_path = "${WH_D}"

[limits]
min_free_disk_gb = 10
EOF

PATH="${FAKE_BIN}:${PATH}" \
  HOME="${HOME_D}" \
  FAKE_DOCKER_LOG="${DOCKER_LOG}" \
  FAKE_WH_HOST="${WH_D}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-18" \
  EZGHA_WHEELHOUSE_REQ_FILES="${REQ_DIR}/sub/requirements-test.txt" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_D}" --skip-git

[ -f "${WH_D}/.manifest.sha256" ] || fail "wheelhouse manifest missing"
[ -L "${WH_D}/pkg0-1.0.0-999999ezgha-py3-none-any.whl" ] || fail "missing build-tag symlink after first wheelhouse refresh"
SHA_WH1="$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")"
grep -q '"core":' "${DOCKER_LOG}" || fail "missing core payload in docker run"
grep -q 'requirements-test.txt' "${DOCKER_LOG}" || fail "missing requirements-test.txt in payload"

# Modify included base.txt and re-run -> manifest SHA must change, and existing symlinks stay live during docker run!
printf 'requests==2.32.3\n' > "${REQ_DIR}/base.txt"
PATH="${FAKE_BIN}:${PATH}" \
  HOME="${HOME_D}" \
  FAKE_DOCKER_LOG="${DOCKER_LOG}" \
  FAKE_WH_HOST="${WH_D}" \
  FAKE_EXPECT_SYMLINK=1 \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-18" \
  EZGHA_WHEELHOUSE_REQ_FILES="${REQ_DIR}/sub/requirements-test.txt" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_D}" --skip-git
SHA_WH2="$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")"
[ "${SHA_WH1}" != "${SHA_WH2}" ] || fail "manifest SHA did not change when included base.txt changed (${SHA_WH1})"

# Same date bucket -> cache hit (no docker run)
DOCKER_LINES_BEFORE="$(wc -l < "${DOCKER_LOG}")"
PATH="${FAKE_BIN}:${PATH}" \
  HOME="${HOME_D}" \
  FAKE_DOCKER_LOG="${DOCKER_LOG}" \
  FAKE_WH_HOST="${WH_D}" \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-18" \
  EZGHA_WHEELHOUSE_REQ_FILES="${REQ_DIR}/sub/requirements-test.txt" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_D}" --skip-git
DOCKER_LINES_AFTER="$(wc -l < "${DOCKER_LOG}")"
[ "${DOCKER_LINES_BEFORE}" = "${DOCKER_LINES_AFTER}" ] || fail "expected wheelhouse cache hit for unchanged date bucket"

# Changed date bucket -> manifest SHA invalidates and refreshes; failed docker run still preserves symlinks via try..finally
set +e
PATH="${FAKE_BIN}:${PATH}" \
  HOME="${HOME_D}" \
  FAKE_DOCKER_LOG="${DOCKER_LOG}" \
  FAKE_WH_HOST="${WH_D}" \
  FAKE_DOCKER_FAIL=1 \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-19" \
  EZGHA_WHEELHOUSE_REQ_FILES="${REQ_DIR}/sub/requirements-test.txt" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_D}" --skip-git >/dev/null 2>&1
FAIL_RC=$?
set -e
[ "${FAIL_RC}" -ne 0 ] || fail "expected non-zero exit on simulated wheelhouse docker failure"
[ -L "${WH_D}/pkg0-1.0.0-999999ezgha-py3-none-any.whl" ] || fail "build-tag symlink lost after failed wheelhouse docker run"
SHA_WH_AFTER_FAIL="$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")"
[ "${SHA_WH_AFTER_FAIL}" = "${SHA_WH2}" ] || fail "manifest should not advance on failed wheelhouse run"

PATH="${FAKE_BIN}:${PATH}" \
  HOME="${HOME_D}" \
  FAKE_DOCKER_LOG="${DOCKER_LOG}" \
  FAKE_WH_HOST="${WH_D}" \
  FAKE_EXPECT_SYMLINK=1 \
  EZGHA_CACHE_TEST_FREE_GB=100 \
  EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-19" \
  EZGHA_WHEELHOUSE_REQ_FILES="${REQ_DIR}/sub/requirements-test.txt" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_D}" --skip-git
SHA_WH3="$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")"
[ "${SHA_WH2}" != "${SHA_WH3}" ] || fail "manifest SHA did not change when UTC date bucket changed (${SHA_WH2})"

# Verify collect_req_closure skips -r/-c includes whose commonpath with rf_real is "/"
python3 - "${REFRESH_SCRIPT}" "${REQ_DIR}" <<'PY'
import os, sys

script_path, req_dir = sys.argv[1], sys.argv[2]
text = open(script_path, "r", encoding="utf-8").read()
py_src = text.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
ns = {"__name__": "refresh_runner_caches_test"}
exec(compile(py_src, script_path, "exec"), ns)

rf_path = os.path.join(req_dir, "cross_root.txt")
outside_file = "/etc/hosts"
if os.path.commonpath([os.path.dirname(os.path.realpath(rf_path)), os.path.dirname(os.path.realpath(outside_file))]) == "/" and os.path.isfile(outside_file):
    with open(rf_path, "w", encoding="utf-8") as fh:
        fh.write(f"-r {outside_file}\n-r base.txt\n")
    entries, all_files = ns["collect_req_closure"]([rf_path])
    assert len(entries) == 1, entries
    rf_real, common_dir, closure = entries[0]
    assert os.path.realpath(outside_file) not in closure and os.path.realpath(outside_file) not in all_files, (closure, all_files)
    assert os.path.realpath(os.path.join(req_dir, "base.txt")) in closure, closure
    assert common_dir != "/", common_dir
PY

pass "(d) relative -r base.txt closure, manifest SHA invalidation, stdin-staged /tmp/ezgha-reqs, and separate core/req pip runs verified"

# ── (c) Syntax & install.sh wiring ───────────────────────────────────────────
bash -n "${INSTALL_SCRIPT}"
bash -n "${REFRESH_SCRIPT}"
bash -n "${VERIFY_SCRIPT}"

grep -E '^  AUX_NAMES=.*cache-warm' "${INSTALL_SCRIPT}" \
  || fail "install.sh AUX_NAMES missing cache-warm"
grep -q 'install_macos_plist "cache-warm"' "${INSTALL_SCRIPT}" \
  || fail "install.sh missing install_macos_plist \"cache-warm\""
grep -E 'for timer in .*ezgha-cache-warm\.timer' "${INSTALL_SCRIPT}" \
  || fail "install.sh Linux timer enable loop missing ezgha-cache-warm.timer"

[ -f "${REPO_ROOT}/systemd/ezgha-cache-warm.service" ] || fail "missing systemd/ezgha-cache-warm.service"
[ -f "${REPO_ROOT}/systemd/ezgha-cache-warm.timer" ] || fail "missing systemd/ezgha-cache-warm.timer"
pass "(c) syntax checks and install.sh wiring verified"

echo "ALL CACHE TESTS PASS"
