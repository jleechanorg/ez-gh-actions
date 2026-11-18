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

# Create bare upstream repo on `main`
git init --bare -q "${UPSTREAM_ROOT}/jleechanorg/testrepo.git"
git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" symbolic-ref HEAD refs/heads/main
git clone -q "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" "${WORK_CLONE}/testrepo"
git -C "${WORK_CLONE}/testrepo" checkout -q -B main
printf 'hello\n' > "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=test@example.com commit -qm "initial main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_1="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"

# Create bare upstream repo with ONLY `master` (and broken HEAD -> refs/heads/main) to test fallback
git init --bare -q "${UPSTREAM_ROOT}/jleechanorg/masteronly.git"
git clone -q "${UPSTREAM_ROOT}/jleechanorg/masteronly.git" "${WORK_CLONE}/masteronly"
git -C "${WORK_CLONE}/masteronly" checkout -q -B master
printf 'master only\n' > "${WORK_CLONE}/masteronly/README.md"
git -C "${WORK_CLONE}/masteronly" add README.md
git -C "${WORK_CLONE}/masteronly" -c user.name=test -c user.email=test@example.com commit -qm "initial master"
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
