#!/usr/bin/env bash
# Regression tests for scripts/refresh_runner_caches.sh, sibling Python modules,
# scripts/verify_live_cache_savings.sh, and cache-warm installer behavior.
set -euo pipefail

export BASH_ENV=/dev/null

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFRESH_SCRIPT="${REPO_ROOT}/scripts/refresh_runner_caches.sh"
VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify_live_cache_savings.sh"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

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
[ -n "${WORK}" ] && [ "${WORK}" != "/" ] || { echo "FAIL: unable to allocate git-capable temp workspace" >&2; exit 1; }

# shellcheck disable=SC2329  # Invoked by EXIT trap.
cleanup() { if [ -n "${WORK}" ] && [ "${WORK}" != "/" ]; then rm -rf "${WORK}"; fi; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -x "${REFRESH_SCRIPT}" ] || fail "missing executable ${REFRESH_SCRIPT}"
[ -x "${VERIFY_SCRIPT}" ] || fail "missing executable ${VERIFY_SCRIPT}"

PYTHON_BIN=""
for _py in python3 python3.14 python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v "${_py}")"
    break
  fi
done
[ -n "${PYTHON_BIN}" ] || fail "Python 3.11+ with stdlib tomllib is required to run refresh_runner_caches_test.sh"

POISON_BIN="${WORK}/poison_bin"
POISON_LOG="${WORK}/poison_docker.log"
mkdir -p "${POISON_BIN}"
cat > "${POISON_BIN}/docker" <<EOF
#!/usr/bin/env bash
printf 'POISON_DOCKER:%s\n' "\$*" >> "${POISON_LOG}"
exit 99
EOF
chmod +x "${POISON_BIN}/docker"
: > "${POISON_LOG}"

# ── (a) Disk-floor refusal (100% hermetic with poison docker stub) ───────────
HOME_A="${WORK}/home_a"
MIRRORS_A="${WORK}/mirrors_a"
WHEELHOUSE_A="${WORK}/wheelhouse_a"
NPM_CACHE_A="${WORK}/npm_cache_a"
mkdir -p "${HOME_A}" "${MIRRORS_A}" "${WHEELHOUSE_A}" "${NPM_CACHE_A}"

CFG_A="${WORK}/cfg_a.toml"
cat > "${CFG_A}" <<EOF
version = 1
[runner]
image = "ezgha-runner:latest"
git_mirror_host_path = "${MIRRORS_A}"
wheelhouse_host_path = "${WHEELHOUSE_A}"
npm_cache_host_path = "${NPM_CACHE_A}"
[limits]
min_free_disk_gb = 30
EOF

OUT_A="${WORK}/out_a.log"
PATH="${POISON_BIN}:/usr/local/bin:/usr/bin:/bin" \
  HOME="${HOME_A}" \
  EZGHA_CACHE_TEST_FREE_GB=20 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_A}" > "${OUT_A}" 2>&1 \
  || fail "disk-floor refusal exited non-zero: $(cat "${OUT_A}")"

[ ! -s "${POISON_LOG}" ] || fail "disk-floor refusal touched docker daemon: $(cat "${POISON_LOG}")"
grep -qiE 'warn|skip|below|disk|free' "${OUT_A}" || fail "disk-floor refusal did not emit warning: $(cat "${OUT_A}")"
if [ -d "${MIRRORS_A}/generations" ] && [ -n "$(ls -A "${MIRRORS_A}/generations" 2>/dev/null || true)" ]; then
  fail "disk-floor refusal created mirror generations"
fi
[ -z "$(find "${WHEELHOUSE_A}" -name '*.whl' 2>/dev/null || true)" ] || fail "disk-floor refusal created wheelhouse files"
[ ! -d "${NPM_CACHE_A}/_cacache" ] || fail "disk-floor refusal created npm _cacache directory"
pass "(a) disk-floor refusal exited 0 hermetically (poison docker untouched) and created no artifacts"

# ── (b) Git mirror generation publish & safe reaping ─────────────────────────
HOME_B="${WORK}/home_b"
UPSTREAM_ROOT="${WORK}/upstream"
MIRRORS_B="${WORK}/mirrors_b"
WORK_CLONE="${WORK}/work_clone"
mkdir -p "${HOME_B}" "${UPSTREAM_ROOT}/jleechanorg" "${MIRRORS_B}"

export HERMES_SKIP_EXAMPLE_COM_GUARD=1
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

git init --bare -q "${UPSTREAM_ROOT}/jleechanorg/masteronly.git"
git clone -q "${UPSTREAM_ROOT}/jleechanorg/masteronly.git" "${WORK_CLONE}/masteronly"
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

mkdir -p "${HOME_B}/projects"
git clone -q --depth=1 "file://${UPSTREAM_ROOT}/jleechanorg/testrepo.git" "${HOME_B}/projects/testrepo"
git clone -q "file://${UPSTREAM_ROOT}/jleechanorg/testrepo.git" "${HOME_B}/testrepo"

OUT_B1="${WORK}/out_b1.log"
HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=100 EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
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
    assert os.path.islink(active_link) and re.match(rf"^\.\./generations/{re.escape(slug)}\.[0-9]+$", os.readlink(active_link))
    gen_dir = os.path.realpath(active_link)
    assert os.path.isdir(gen_dir)
    for marker in ("SEED_SHA", "MAIN_SHA"):
        assert open(os.path.join(gen_dir, marker), encoding="utf-8").read().strip() == expected_sha
    for cg in ("commit-graph", "commit-graphs"):
        assert not os.path.exists(os.path.join(gen_dir, "objects", "info", cg))
    for root, _dirs, files in os.walk(gen_dir):
        assert (stat.S_IMODE(os.stat(root).st_mode) & 0o005) == 0o005, root
        for f in files:
            if f in ("SEED_SHA", "MAIN_SHA") or f.endswith((".pack", ".idx")):
                assert (stat.S_IMODE(os.stat(os.path.join(root, f)).st_mode) & 0o004) == 0o004
PY
pass "(b1) mirror symlink, SEED_SHA/MAIN_SHA, master fallback, commit-graph removal, permissions"

run_b() {
  HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=100 EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
    EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
    EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
    "$@" bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
}

# (b2) Active generation protection when mtime > retention
GEN1="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
python3 -c 'import os,sys,time; old=time.time()-36000; os.utime(sys.argv[1], (old, old))' "${GEN1}"
EZGHA_MIRROR_RETENTION_MIN=240 run_b
[ -d "${GEN1}" ] || fail "active generation deleted despite no upstream change"
[ "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")" = "${GEN1}" ] \
  || fail "active symlink changed unexpectedly"
pass "(b2) active generation protected from reaping even when mtime > retention"

# (b3) Upstream advance publishes GEN2 and preserves just-retired GEN1
printf 'second commit\n' >> "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=test@example.com commit -qm "second main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_2="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"
EZGHA_MIRROR_RETENTION_MIN=240 run_b
GEN2="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
[ "${GEN2}" != "${GEN1}" ] && [ -d "${GEN2}" ] && [ -d "${GEN1}" ] && [ -f "${GEN1}/RETIRED_AT" ] || fail "GEN1/GEN2 post-retirement check failed"
[ "$(tr -d '[:space:]' < "${GEN2}/SEED_SHA")" = "${SHA_2}" ] || fail "new SEED_SHA mismatch"
pass "(b3) upstream advance published new generation and preserved just-retired generation"

# (b4) Backdate GEN1 RETIRED_AT beyond retention -> reaped
python3 -c 'import os,sys,time; t=int(time.time())-18000; open(os.path.join(sys.argv[1],"RETIRED_AT"),"w").write(f"{t}\n"); os.utime(sys.argv[1],(t,t))' "${GEN1}"
EZGHA_MIRROR_RETENTION_MIN=240 run_b
[ ! -e "${GEN1}" ] && [ -d "${GEN2}" ] || fail "expired retired generation was NOT reaped cleanly"
pass "(b4) retired generation reaped once RETIRED_AT exceeds retention window"

# (b5) Per-repo error isolation
printf 'third commit\n' >> "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=test@example.com commit -qm "third main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_3="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"
set +e
HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=100 EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" \
  EZGHA_MIRROR_REPOS="jleechanorg/missing_broken_repo jleechanorg/testrepo" \
  EZGHA_MIRROR_RETENTION_MIN=240 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels >/dev/null 2>&1
ISO_RC=$?
set -e
[ "${ISO_RC}" -ne 0 ] || fail "expected non-zero exit when one mirror repo fails"
GEN3="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
[ "$(tr -d '[:space:]' < "${GEN3}/SEED_SHA")" = "${SHA_3}" ] || fail "healthy second repo blocked by broken first repo"
pass "(b5) per-repo error isolation refreshes healthy repos even when an earlier repo fails"

# (b6) Dot-suffixed sibling repo protection
FAKE_SIBLING_GEN="${MIRRORS_B}/generations/jleechanorg__testrepo.ai.1000000000"
mkdir -p "${FAKE_SIBLING_GEN}"
ln -s "../generations/jleechanorg__testrepo.ai.1000000000" "${MIRRORS_B}/active/jleechanorg__testrepo.ai"
printf '1000\n' > "${FAKE_SIBLING_GEN}/RETIRED_AT"
EZGHA_MIRROR_RETENTION_MIN=240 run_b
[ -d "${FAKE_SIBLING_GEN}" ] || fail "reap_old_generations deleted sibling dot-repo generation"
pass "(b6) dot-suffixed sibling repo generation protected from prefix collision"

# (b7) Default 480m retention preserves 5h-retired gen, reaps 9h-retired gen
GEN_B7="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000001"
mkdir -p "${GEN_B7}"
python3 -c 'import os,sys,time; open(os.path.join(sys.argv[1],"RETIRED_AT"),"w").write(f"{int(time.time())-18000}\n")' "${GEN_B7}"
run_b
[ -d "${GEN_B7}" ] || fail "5h-retired generation was reaped under default 480m retention"
python3 -c 'import os,sys,time; open(os.path.join(sys.argv[1],"RETIRED_AT"),"w").write(f"{int(time.time())-32400}\n")' "${GEN_B7}"
run_b
[ ! -e "${GEN_B7}" ] || fail "9h-retired generation was not reaped under default 480m retention"
pass "(b7) default 480m retention preserves 5h-retired and reaps 9h-retired generation"

# (b8) Live container pinning + fail-closed error handling
GEN_B8="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000002"
mkdir -p "${GEN_B8}"
RETIRED_B8="$(python3 -c 'import time; print(int(time.time()) - 32400)')"
printf '%s\n' "${RETIRED_B8}" > "${GEN_B8}/RETIRED_AT"

HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=100 EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH="$((RETIRED_B8 - 3600))" \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ -d "${GEN_B8}" ] || fail "retired generation reaped while pre-retirement container still running"

HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=100 EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=error \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ -d "${GEN_B8}" ] || fail "retired generation reaped despite docker error"

HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=100 EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH="$((RETIRED_B8 + 120))" \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels
[ ! -e "${GEN_B8}" ] || fail "retired generation not reaped after oldest container advanced past RETIRED_AT+60"
pass "(b8) container pinning preserves pre-retirement gens, fails closed on error, reaps once past RETIRED_AT+60"

# (b9) Unstamped retired generation stamped on first observation
GEN_B9="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000003"
mkdir -p "${GEN_B9}"
python3 -c 'import os,sys,time; old=time.time()-36000; os.utime(sys.argv[1], (old, old))' "${GEN_B9}"
run_b
[ -d "${GEN_B9}" ] && [ -f "${GEN_B9}/RETIRED_AT" ] || fail "unstamped retired generation was not stamped"
pass "(b9) unstamped retired generation stamped with RETIRED_AT on first observation"

# (b10) GIT_DIR=/bogus/gitdir sanitized
printf 'fourth commit\n' >> "${WORK_CLONE}/testrepo/README.md"
git -C "${WORK_CLONE}/testrepo" add README.md
git -C "${WORK_CLONE}/testrepo" -c user.name=test -c user.email=test@example.com commit -qm "fourth main"
git -C "${WORK_CLONE}/testrepo" push -q origin main
SHA_4="$(git -C "${UPSTREAM_ROOT}/jleechanorg/testrepo.git" rev-parse refs/heads/main)"
GIT_DIR=/bogus/gitdir GIT_WORK_TREE=/bogus/wt run_b
GEN4="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${MIRRORS_B}/active/jleechanorg__testrepo")"
[ "$(tr -d '[:space:]' < "${GEN4}/SEED_SHA")" = "${SHA_4}" ] || fail "caller GIT_DIR broke refresh"
pass "(b10) GIT_DIR=/bogus/gitdir in caller environment sanitized cleanly"

# (b11) Default min_free_disk_gb=10 + buffer=5 & low-disk mode reaps retired gens
CFG_LOW="${WORK}/cfg_low.toml"
MIRRORS_LOW="${WORK}/mirrors_low"
mkdir -p "${MIRRORS_LOW}/generations" "${MIRRORS_LOW}/active"
printf 'version = 1\n[runner]\nimage = "ezgha-runner:latest"\ngit_mirror_host_path = "%s"\n' "${MIRRORS_LOW}" > "${CFG_LOW}"
STALE_LOW="${MIRRORS_LOW}/generations/jleechanorg__testrepo.1000"
mkdir -p "${STALE_LOW}"
printf '1000\n' > "${STALE_LOW}/RETIRED_AT"

OUT_LOW="${WORK}/out_low.log"
HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=14 EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=none \
  EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  bash "${REFRESH_SCRIPT}" --config "${CFG_LOW}" --skip-wheels > "${OUT_LOW}" 2>&1 || fail "low-disk mode exited non-zero"
grep -q "below safety floor+5 (15 GiB)" "${OUT_LOW}" || fail "expected floor+5 (15 GiB) warning: $(cat "${OUT_LOW}")"
[ ! -e "${STALE_LOW}" ] && [ ! -e "${MIRRORS_LOW}/active/jleechanorg__testrepo" ] || fail "low-disk mirror reap check failed"
pass "(b11) default floor=10 + buffer=5 enforces 15 GiB and low-disk mode reaps retired generations"

# (b12) Missing docker CLI fails closed (0.0) and preserves expired retired gen
GEN_B12="${MIRRORS_B}/generations/jleechanorg__testrepo.1000000004"
mkdir -p "${GEN_B12}"
printf '1000\n' > "${GEN_B12}/RETIRED_AT"
MIN_BIN_B12="${WORK}/min_bin_b12"
mkdir -p "${MIN_BIN_B12}"
ln -s "${PYTHON_BIN}" "${MIN_BIN_B12}/python3"
ln -s "$(which -a git | grep -v '/\.local/bin/' | head -n1 || command -v git)" "${MIN_BIN_B12}/git"
OUT_B12="${WORK}/out_b12.log"
env -u EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH BASH_ENV=/dev/null EZGHA_STRICT_PATH=1 PATH="${MIN_BIN_B12}" HOME="${HOME_B}" \
  EZGHA_CACHE_TEST_FREE_GB=100 EZGHA_MIRROR_URL_TEMPLATE="file://${UPSTREAM_ROOT}/%s.git" EZGHA_MIRROR_REPOS="jleechanorg/testrepo" \
  "$(command -v bash)" "${REFRESH_SCRIPT}" --config "${CFG_B}" --skip-wheels > "${OUT_B12}" 2>&1 \
  || fail "missing docker CLI fail-closed test exited non-zero: $(cat "${OUT_B12}")"
[ -d "${GEN_B12}" ] || fail "expired retired generation deleted when docker CLI missing"
grep -q "docker CLI not found; failing closed to preserve retired generations" "${OUT_B12}" || fail "missing docker CLI warning absent"
pass "(b12) missing docker CLI fails closed (0.0) and preserves expired retired generation"

# ── (b13) Wheelhouse pruning (normal + reap_only + distinct-version build tags) + deconfigured-slug reaping ──
DECFG_GEN="${MIRRORS_B}/generations/jleechanorg__deconfigured_repo.999"
mkdir -p "${DECFG_GEN}"
printf '1000\n' > "${DECFG_GEN}/RETIRED_AT"
run_b
[ ! -e "${DECFG_GEN}" ] || fail "normal mode failed to reap expired generation of deconfigured repo"

WH_PRUNE_NORMAL="${WORK}/wh_prune_normal"
WH_PRUNE_LOW="${WORK}/wh_prune_low"
WH_PRUNE_BUILDTAGS="${WORK}/wh_prune_buildtags"
mkdir -p "${WH_PRUNE_NORMAL}" "${WH_PRUNE_LOW}" "${WH_PRUNE_BUILDTAGS}"
"${PYTHON_BIN}" - "${REPO_ROOT}/scripts" "${WH_PRUNE_NORMAL}" "${WH_PRUNE_LOW}" "${WH_PRUNE_BUILDTAGS}" <<'PY'
import os, sys

scripts_dir, wh_normal, wh_low, wh_btags = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, scripts_dir)
import ezgha_wheelhouse  # noqa: E402

def seed_wheels(wh):
    for fn in (
        "alpha_pkg-1.2.0-py3-none-any.whl",
        "alpha_pkg-1.9.0-py3-none-any.whl",
        "alpha_pkg-1.10.0-py3-none-any.whl",
        "alpha_pkg-1.0.0-cp311-cp311-manylinux_2_17_x86_64.whl",
    ):
        open(os.path.join(wh, fn), "w", encoding="utf-8").write("whl")
    os.symlink("alpha_pkg-1.2.0-py3-none-any.whl", os.path.join(wh, "alpha_pkg-1.2.0-999999ezgha-py3-none-any.whl"))
    os.symlink("orphan-0.1.0-py3-none-any.whl", os.path.join(wh, "orphan-0.1.0-999999ezgha-py3-none-any.whl"))
    os.symlink("wrong-target.whl", os.path.join(wh, "alpha_pkg-1.10.0-999999ezgha-py3-none-any.whl"))

seed_wheels(wh_normal)
assert ezgha_wheelhouse.prune_old_wheels(wh_normal, keep_versions=2) == 1
assert not os.path.exists(os.path.join(wh_normal, "alpha_pkg-1.2.0-py3-none-any.whl"))
assert not os.path.lexists(os.path.join(wh_normal, "alpha_pkg-1.2.0-999999ezgha-py3-none-any.whl"))
assert not os.path.lexists(os.path.join(wh_normal, "orphan-0.1.0-999999ezgha-py3-none-any.whl"))
assert os.path.isfile(os.path.join(wh_normal, "alpha_pkg-1.9.0-py3-none-any.whl"))
assert os.path.isfile(os.path.join(wh_normal, "alpha_pkg-1.10.0-py3-none-any.whl"))
assert os.path.isfile(os.path.join(wh_normal, "alpha_pkg-1.0.0-cp311-cp311-manylinux_2_17_x86_64.whl"))
newest_alias = os.path.join(wh_normal, "alpha_pkg-1.10.0-999999ezgha-py3-none-any.whl")
assert os.path.islink(newest_alias) and os.readlink(newest_alias) == "alpha_pkg-1.10.0-py3-none-any.whl"

for fn in (
    "beta_pkg-1.0.0-py3-none-any.whl",
    "beta_pkg-2.0.0-1-py3-none-any.whl",
    "beta_pkg-2.0.0-2-py3-none-any.whl",
):
    open(os.path.join(wh_btags, fn), "w", encoding="utf-8").write("whl")
assert ezgha_wheelhouse.prune_old_wheels(wh_btags, keep_versions=2) == 0
assert os.path.isfile(os.path.join(wh_btags, "beta_pkg-1.0.0-py3-none-any.whl"))
assert os.path.isfile(os.path.join(wh_btags, "beta_pkg-2.0.0-2-py3-none-any.whl"))
btag_alias = os.path.join(wh_btags, "beta_pkg-2.0.0-999999ezgha-py3-none-any.whl")
assert os.path.islink(btag_alias) and os.readlink(btag_alias) == "beta_pkg-2.0.0-2-py3-none-any.whl"

seed_wheels(wh_low)
PY

CFG_WH_LOW="${WORK}/cfg_wh_low.toml"
printf 'version = 1\n[runner]\nimage = "ezgha-runner:latest"\nwheelhouse_host_path = "%s"\n[limits]\nmin_free_disk_gb = 10\n' "${WH_PRUNE_LOW}" > "${CFG_WH_LOW}"
: > "${POISON_LOG}"
PATH="${POISON_BIN}:/usr/local/bin:/usr/bin:/bin" HOME="${HOME_B}" EZGHA_CACHE_TEST_FREE_GB=14 \
  bash "${REFRESH_SCRIPT}" --config "${CFG_WH_LOW}" --skip-git >/dev/null 2>&1 \
  || fail "low-disk wheelhouse reap_only exited non-zero"
[ ! -s "${POISON_LOG}" ] || fail "low-disk wheelhouse reap_only invoked docker"
[ ! -e "${WH_PRUNE_LOW}/alpha_pkg-1.2.0-py3-none-any.whl" ] || fail "low-disk reap_only did not prune 1.2.0"
[ ! -L "${WH_PRUNE_LOW}/orphan-0.1.0-999999ezgha-py3-none-any.whl" ] || fail "low-disk reap_only left dangling symlink"
[ "$(readlink "${WH_PRUNE_LOW}/alpha_pkg-1.10.0-999999ezgha-py3-none-any.whl")" = "alpha_pkg-1.10.0-py3-none-any.whl" ] \
  || fail "low-disk reap_only did not refresh newest -999999ezgha- symlink"
pass "(b13) prune_old_wheels (normal + reap_only low-disk) and deconfigured-slug reaping verified"

# ── (d) Wheelhouse relative -r base.txt closure, manifest SHA, separate pip solve ──
HOME_D="${WORK}/home_d"
WH_D="${WORK}/wheelhouse_d"
REQ_DIR="${WORK}/reqs_d"
FAKE_BIN="${WORK}/fake_bin"
FAKE_PYLIB="${WORK}/fake_pylib"
DOCKER_LOG="${WORK}/fake_docker.log"
mkdir -p "${HOME_D}" "${WH_D}" "${REQ_DIR}/sub" "${FAKE_BIN}" "${FAKE_PYLIB}/pip"

printf 'requests==2.31.0\n' > "${REQ_DIR}/base.txt"
printf -- '-r ../base.txt\npytest-mock==3.12.0\n' > "${REQ_DIR}/sub/requirements-test.txt"
: > "${FAKE_PYLIB}/pip/__init__.py"
cat > "${FAKE_PYLIB}/pip/__main__.py" <<'PY'
import json, os, sys
argv = sys.argv[1:]
open(os.environ["FAKE_PIP_LOG"], "a", encoding="utf-8").write(json.dumps(argv) + "\n")
dest = argv[argv.index("--dest") + 1]
for i in range(12):
    open(os.path.join(dest, f"pkg{i}-1.0.0-py3-none-any.whl"), "w", encoding="utf-8").write("whl")
PY

cat > "${FAKE_BIN}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
if [ "${sub}" = "info" ]; then exit 0; fi
if [ "${sub}" = "image" ] && [ "${2:-}" = "inspect" ]; then echo "sha256:fakeimageid"; exit 0; fi
if [ "${sub}" = "run" ]; then
  if echo "$*" | grep -q "PLAYWRIGHT_VERSION"; then echo "1.65.2"; exit 0; fi
  printf 'ARGS:%s\n' "$*" >> "${FAKE_DOCKER_LOG}"
  payload="$(cat)"
  printf 'PAYLOAD:%s\n' "${payload}" >> "${FAKE_DOCKER_LOG}"
  [ "${FAKE_DOCKER_FAIL:-0}" != "1" ] || exit 1
  python3 - "${payload}" "${FAKE_WH_HOST}" "${FAKE_PYLIB}" "${FAKE_EXPECT_SYMLINK:-0}" "$@" <<'PY'
import json, os, subprocess, sys, tempfile

payload_raw, wh_host, fake_pylib, expect_sym = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
args = sys.argv[5:]
payload = json.loads(payload_raw)
assert not any(":/req_mounts/" in a for a in args)
assert [args[i + 1] for i, a in enumerate(args) if a == "-v"] == [f"{wh_host}:/wheelhouse"]
if expect_sym:
    assert os.path.islink(os.path.join(wh_host, "pkg0-1.0.0-999999ezgha-py3-none-any.whl"))
staged = dict(payload["staged_files"])
assert "0/base.txt" in staged and "0/sub/requirements-test.txt" in staged
assert payload["req_paths"] == ["/tmp/ezgha-reqs/0/sub/requirements-test.txt"]

with tempfile.TemporaryDirectory() as stage_tmp, tempfile.TemporaryDirectory() as wheel_stage_tmp, tempfile.TemporaryDirectory() as baked_tmp:
    pip_log = os.path.join(stage_tmp, "pip_calls.jsonl")
    env = os.environ.copy()
    env.update({
        "PYTHONPATH": fake_pylib + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""),
        "FAKE_PIP_LOG": pip_log,
        "EZGHA_WHEELHOUSE_MOUNT": wh_host,
        "EZGHA_BAKED_WHEELS_DIR": baked_tmp,
        "EZGHA_WHEEL_STAGE": wheel_stage_tmp,
        "EZGHA_STAGE_ROOT": stage_tmp,
    })
    subprocess.run([sys.executable, "-c", args[-1]], input=payload_raw, text=True, env=env, check=True)
    staged_base = os.path.join(stage_tmp, "0", "base.txt")
    staged_req = os.path.join(stage_tmp, "0", "sub", "requirements-test.txt")
    assert os.path.realpath(os.path.join(os.path.dirname(staged_req), "../base.txt")) == os.path.realpath(staged_base)
    if expect_sym:
        assert not os.path.exists(os.path.join(wheel_stage_tmp, "pkg0-1.0.0-999999ezgha-py3-none-any.whl"))
    pip_calls = [json.loads(ln) for ln in open(pip_log, encoding="utf-8").read().splitlines() if ln.strip()]
    expected_base = ["download", "--dest", wheel_stage_tmp, "--find-links", wheel_stage_tmp]
    assert pip_calls == [expected_base + payload["core"], expected_base + ["-r", "/tmp/ezgha-reqs/0/sub/requirements-test.txt"]]
PY
  exit 0
fi
exit 1
SH
chmod +x "${FAKE_BIN}/docker"
ln -sf "${PYTHON_BIN}" "${FAKE_BIN}/python3"

CFG_D="${WORK}/cfg_d.toml"
printf 'version = 1\n[runner]\nimage = "ezgha-runner:latest"\nwheelhouse_host_path = "%s"\n[limits]\nmin_free_disk_gb = 10\n' "${WH_D}" > "${CFG_D}"

run_d() {
  PATH="${FAKE_BIN}:${PATH}" HOME="${HOME_D}" FAKE_DOCKER_LOG="${DOCKER_LOG}" FAKE_WH_HOST="${WH_D}" \
    FAKE_PYLIB="${FAKE_PYLIB}" EZGHA_CACHE_TEST_FREE_GB=100 \
    EZGHA_WHEELHOUSE_REQ_FILES="${REQ_DIR}/sub/requirements-test.txt" \
    "$@" bash "${REFRESH_SCRIPT}" --config "${CFG_D}" --skip-git
}

EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-18" run_d
[ -f "${WH_D}/.manifest.sha256" ] && [ -L "${WH_D}/pkg0-1.0.0-999999ezgha-py3-none-any.whl" ] || fail "initial wheelhouse check failed"
SHA_WH1="$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")"

printf 'requests==2.32.3\n' > "${REQ_DIR}/base.txt"
FAKE_EXPECT_SYMLINK=1 EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-18" run_d
SHA_WH2="$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")"
[ "${SHA_WH1}" != "${SHA_WH2}" ] || fail "manifest SHA did not change when base.txt changed"

DOCKER_LINES_BEFORE="$(wc -l < "${DOCKER_LOG}")"
EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-18" run_d
[ "$(wc -l < "${DOCKER_LOG}")" = "${DOCKER_LINES_BEFORE}" ] || fail "expected wheelhouse cache hit"

set +e
FAKE_DOCKER_FAIL=1 EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-19" run_d >/dev/null 2>&1
FAIL_RC=$?
set -e
[ "${FAIL_RC}" -ne 0 ] || fail "expected non-zero exit on simulated wheelhouse docker failure"
[ -L "${WH_D}/pkg0-1.0.0-999999ezgha-py3-none-any.whl" ] || fail "build-tag symlink lost after failure"
[ "$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")" = "${SHA_WH2}" ] || fail "manifest advanced on failed run"

FAKE_EXPECT_SYMLINK=1 EZGHA_WHEELHOUSE_DATE_BUCKET="2026-11-19" run_d
SHA_WH3="$(tr -d '[:space:]' < "${WH_D}/.manifest.sha256")"
[ "${SHA_WH2}" != "${SHA_WH3}" ] || fail "manifest SHA did not change when date bucket changed"

"${PYTHON_BIN}" - "${REPO_ROOT}/scripts" "${REQ_DIR}" "${WORK}" <<'PY'
import base64, hashlib, json, os, sys, time
from unittest import mock

scripts_dir, req_dir, work_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, scripts_dir)
import ezgha_cache_common  # noqa: E402
import ezgha_git_mirrors  # noqa: E402
import ezgha_npm_cache  # noqa: E402
import ezgha_wheelhouse  # noqa: E402
import refresh_runner_caches  # noqa: E402

assert ezgha_git_mirrors.slugs_for(["o/r"]) == ["o__r"]
assert ezgha_git_mirrors.parse_mirror_repos("jleechanorg/ok ../escape ./dot a//b bare a/..") == ["jleechanorg/ok"]
assert "jleechanorg/worldai_frontend" in ezgha_git_mirrors.parse_mirror_repos(ezgha_git_mirrors.DEFAULT_MIRROR_REPOS)

empty_darwin_home = os.path.join(work_dir, "empty_darwin_home")
os.makedirs(empty_darwin_home, exist_ok=True)
with mock.patch("platform.system", return_value="Darwin"), mock.patch.dict(
    os.environ,
    {
        "HOME": empty_darwin_home,
        "DOCKER_HOST": "unix:///intended.sock",
        "DOCKER_CONTEXT": "wrong-ctx",
    },
    clear=True,
):
    raw_env = ezgha_cache_common.resolve_docker_env()
    assert "DOCKER_CONTEXT" in raw_env and raw_env["DOCKER_CONTEXT"] is None, raw_env
    merged_env = ezgha_cache_common.merge_env(raw_env)
    assert merged_env.get("DOCKER_HOST") == "unix:///intended.sock", merged_env
    assert merged_env.get("DOCKER_CONTEXT") is None and "DOCKER_CONTEXT" not in merged_env, merged_env

rf_path, outside_file = os.path.join(req_dir, "cross_root.txt"), "/etc/hosts"
if os.path.commonpath([os.path.dirname(os.path.realpath(rf_path)), os.path.dirname(os.path.realpath(outside_file))]) == "/" and os.path.isfile(outside_file):
    open(rf_path, "w", encoding="utf-8").write(f"-r {outside_file}\n-r base.txt\n")
    entries, all_files = ezgha_wheelhouse.collect_req_closure([rf_path])
    assert len(entries) == 1 and os.path.realpath(outside_file) not in all_files and entries[0][1] != "/"

for idx, bad_path in enumerate(["", "   ", "~/.cache/ezgha", "relative/path"]):
    for field in ("git_mirror_host_path", "wheelhouse_host_path", "npm_cache_host_path"):
        bad_cfg = os.path.join(work_dir, f"bad_{field}_{idx}.toml")
        open(bad_cfg, "w", encoding="utf-8").write(f'version = 1\n[runner]\n{field} = "{bad_path}"\n')
        try:
            refresh_runner_caches.load_config(bad_cfg)
        except ValueError:
            pass
        else:
            raise AssertionError(f"load_config accepted invalid {field}={bad_path!r}")

# Unit tests for ezgha_npm_cache._synthesize_or_read_pkg_json and prune_old_npm_cache
lock_sample = json.dumps({
    "name": "unused-top",
    "lockfileVersion": 3,
    "packages": {
        "": {
            "name": "frontend-app",
            "version": "2.3.4",
            "dependencies": {"react": "^18.0.0"},
            "devDependencies": {"vitest": "^1.0.0"},
        }
    },
})
synth_pkg = json.loads(ezgha_npm_cache._synthesize_or_read_pkg_json(None, lock_sample))
assert synth_pkg["name"] == "frontend-app" and synth_pkg["version"] == "2.3.4"
assert synth_pkg["dependencies"] == {"react": "^18.0.0"} and synth_pkg["devDependencies"] == {"vitest": "^1.0.0"}
assert synth_pkg["optionalDependencies"] == {} and synth_pkg["peerDependencies"] == {}
assert ezgha_npm_cache._synthesize_or_read_pkg_json('{"name":"real"}', lock_sample) == '{"name":"real"}'

npm_dir = os.path.join(work_dir, "npm_prune_unit")
ref_digest = hashlib.sha512(b"referenced-blob").digest()
ref_b64 = base64.b64encode(ref_digest).decode("ascii")
ref_hex = ref_digest.hex()
unref_hex = hashlib.sha512(b"unreferenced-blob").hexdigest()

ref_blob = os.path.join(npm_dir, "_cacache", "content-v2", "sha512", ref_hex[:2], ref_hex[2:4], ref_hex[4:])
unref_blob = os.path.join(npm_dir, "_cacache", "content-v2", "sha512", unref_hex[:2], unref_hex[2:4], unref_hex[4:])
stale_tmp = os.path.join(npm_dir, "_cacache", "content-v2", "sha512", "ab", "cd", "ef.tmp.999")
idx_file = os.path.join(npm_dir, "_cacache", "index-v5", "11", "22", "3344")
for p in (ref_blob, unref_blob, stale_tmp, idx_file):
    os.makedirs(os.path.dirname(p), exist_ok=True)
open(ref_blob, "wb").write(b"referenced-blob")
open(unref_blob, "wb").write(b"unreferenced-blob")
open(stale_tmp, "wb").write(b"leftover")
old_mtime = time.time() - 40000
os.utime(stale_tmp, (old_mtime, old_mtime))
idx_entry = json.dumps({"key": "pacote:pkg@1.0.0", "integrity": f"sha1-deadbeef sha512-{ref_b64}"})
open(idx_file, "w", encoding="utf-8").write(f"0123456789abcdef\t{idx_entry}\n")

# Pass 1: stamps unreferenced blob without deleting it, keeps referenced blob, removes stale .tmp.
assert ezgha_npm_cache.prune_old_npm_cache(npm_dir, retention_min=480, oldest_runner_epoch=None) == 0
assert os.path.isfile(ref_blob) and os.path.isfile(unref_blob) and not os.path.exists(stale_tmp)
unref_rel = f"sha512/{unref_hex[:2]}/{unref_hex[2:4]}/{unref_hex[4:]}"
unref_map = json.load(open(os.path.join(npm_dir, ".unreferenced.json"), encoding="utf-8"))
assert unref_rel in unref_map

# Backdate unreferenced timestamp past 480m retention
old_unref_ts = time.time() - 32400
open(os.path.join(npm_dir, ".unreferenced.json"), "w", encoding="utf-8").write(json.dumps({unref_rel: old_unref_ts}))

# Pass 2: fail-closed when oldest_runner_epoch == 0.0
assert ezgha_npm_cache.prune_old_npm_cache(npm_dir, retention_min=480, oldest_runner_epoch=0.0) == 0
assert os.path.isfile(unref_blob)

# Pass 3: pinned by older running container
assert ezgha_npm_cache.prune_old_npm_cache(npm_dir, retention_min=480, oldest_runner_epoch=old_unref_ts - 600) == 0
assert os.path.isfile(unref_blob)

# Pass 4: fail-closed on index-v5 OSError
orig_open = open
def _fail_idx_open(path, *args, **kwargs):
    if path == idx_file:
        raise OSError("simulated read error")
    return orig_open(path, *args, **kwargs)
with mock.patch("builtins.open", side_effect=_fail_idx_open):
    assert ezgha_npm_cache.prune_old_npm_cache(npm_dir, retention_min=480, oldest_runner_epoch=None) == 0
assert os.path.isfile(unref_blob)

# Pass 5: expired unreferenced blob is pruned, referenced blob preserved, tracker cleaned
assert ezgha_npm_cache.prune_old_npm_cache(npm_dir, retention_min=480, oldest_runner_epoch=None) == 1
assert os.path.isfile(ref_blob) and not os.path.exists(unref_blob)
unref_after = json.load(open(os.path.join(npm_dir, ".unreferenced.json"), encoding="utf-8"))
assert unref_rel not in unref_after

# Test refresh_npm_cache reap_only=True when _cacache absent does NOT invoke docker
empty_npm = os.path.join(work_dir, "empty_npm_reap")
os.makedirs(empty_npm, exist_ok=True)
with mock.patch("ezgha_npm_cache.oldest_running_runner_start_epoch", side_effect=AssertionError("should not call docker")):
    ezgha_npm_cache.refresh_npm_cache(empty_npm, "ezgha-runner:latest", reap_only=True)

# Test gather_npm_lock_sources (EZGHA_NPM_LOCKFILES + bare mirror SEED_SHA) and stubbed refresh_npm_cache + --skip-npm
lock_dir = os.path.join(work_dir, "npm_lock_src")
os.makedirs(lock_dir, exist_ok=True)
lock_file_p = os.path.join(lock_dir, "package-lock.json")
open(lock_file_p, "w", encoding="utf-8").write(lock_sample)
with mock.patch.dict(os.environ, {"EZGHA_NPM_LOCKFILES": lock_file_p}, clear=False):
    gathered = ezgha_npm_cache.gather_npm_lock_sources()
    assert len(gathered) == 1 and gathered[0][0] == lock_file_p and json.loads(gathered[0][1])["name"] == "frontend-app"

# Bare mirror with master-only branch resolved via resolve_seed_sha (HEAD points to missing main)
import subprocess
npm_mirror_root = os.path.join(work_dir, "npm_mirror_src")
npm_mirror_gen = os.path.join(npm_mirror_root, "generations", "jleechanorg__npmrepo.1")
npm_mirror_act = os.path.join(npm_mirror_root, "active")
npm_work_repo = os.path.join(work_dir, "npm_work_repo")
os.makedirs(npm_mirror_act, exist_ok=True)
subprocess.run(["git", "init", "--bare", "-q", npm_mirror_gen], check=True)
subprocess.run(["git", "clone", "-q", npm_mirror_gen, npm_work_repo], check=True)
subprocess.run(["git", "-C", npm_work_repo, "config", "core.hooksPath", "/dev/null"], check=True)
subprocess.run(["git", "-C", npm_work_repo, "checkout", "-q", "-B", "master"], check=True)
open(os.path.join(npm_work_repo, "package-lock.json"), "w", encoding="utf-8").write(lock_sample)
subprocess.run(["git", "-C", npm_work_repo, "add", "package-lock.json"], check=True)
subprocess.run(["git", "-C", npm_work_repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "lock"], check=True)
subprocess.run(["git", "-C", npm_work_repo, "push", "-q", "origin", "master"], check=True)
subprocess.run(["git", "-C", npm_mirror_gen, "symbolic-ref", "HEAD", "refs/heads/main"], check=True)
os.symlink("../generations/jleechanorg__npmrepo.1", os.path.join(npm_mirror_act, "jleechanorg__npmrepo"))
with mock.patch.dict(os.environ, {"EZGHA_NPM_LOCKFILES": "", "EZGHA_NPM_REPOS": "jleechanorg/npmrepo"}, clear=False):
    mir_gathered = ezgha_npm_cache.gather_npm_lock_sources(git_mirror_path=npm_mirror_root)
    assert len(mir_gathered) == 1 and mir_gathered[0][0] == "mirror:jleechanorg/npmrepo"

# Stubbed refresh_npm_cache: first run invokes run_cmd + writes .manifest.sha256; second run short-circuits; reap_only prunes _cacache
npm_refresh_dir = os.path.join(work_dir, "npm_refresh_stub")
run_calls = []
def _fake_npm_run_cmd(cmd, timeout=None, env=None, capture=False, input_text=None):
    run_calls.append((cmd, json.loads(input_text)))
    b_path = os.path.join(npm_refresh_dir, "_cacache", "content-v2", "sha512", ref_hex[:2], ref_hex[2:4], ref_hex[4:])
    i_path = os.path.join(npm_refresh_dir, "_cacache", "index-v5", "11", "22", "3344")
    for p in (b_path, i_path):
        os.makedirs(os.path.dirname(p), exist_ok=True)
    open(b_path, "wb").write(b"referenced-blob")
    open(i_path, "w", encoding="utf-8").write(f"0123456789abcdef\t{idx_entry}\n")

with mock.patch.dict(os.environ, {"EZGHA_NPM_LOCKFILES": lock_file_p}, clear=False), \
     mock.patch("ezgha_npm_cache.inspect_docker_image_id", return_value="sha256:fakeimg123"), \
     mock.patch("ezgha_npm_cache.oldest_running_runner_start_epoch", return_value=None), \
     mock.patch("ezgha_npm_cache.run_cmd", side_effect=_fake_npm_run_cmd):
    ezgha_npm_cache.refresh_npm_cache(npm_refresh_dir, "ezgha-runner:latest")
    assert len(run_calls) == 1 and os.path.isfile(os.path.join(npm_refresh_dir, ".manifest.sha256"))
    ezgha_npm_cache.refresh_npm_cache(npm_refresh_dir, "ezgha-runner:latest")
    assert len(run_calls) == 1, "manifest hit should skip second container run"

reap_epochs = []
with mock.patch("ezgha_npm_cache.oldest_running_runner_start_epoch", side_effect=lambda _e: reap_epochs.append(1) or None):
    ezgha_npm_cache.refresh_npm_cache(npm_refresh_dir, "ezgha-runner:latest", reap_only=True)
    assert len(reap_epochs) == 1

cfg_skip_npm = os.path.join(work_dir, "cfg_skip_npm.toml")
open(cfg_skip_npm, "w", encoding="utf-8").write(f'version = 1\n[runner]\nnpm_cache_host_path = "{npm_refresh_dir}"\n[limits]\nmin_free_disk_gb = 1\n')
with mock.patch.dict(os.environ, {"EZGHA_CACHE_STATE_DIR": work_dir, "EZGHA_CACHE_TEST_FREE_GB": "100"}, clear=False), \
     mock.patch("refresh_runner_caches.refresh_npm_cache", side_effect=AssertionError("--skip-npm must bypass refresh_npm_cache")):
    assert refresh_runner_caches.main(["--config", cfg_skip_npm, "--skip-npm"]) == 0
PY
pass "(d) relative -r base.txt closure, atomic manifest SHA, direct module imports, npm cache unit tests, and path validation parity verified"

# ── (e) Hermetic stubbed test of scripts/verify_live_cache_savings.sh ─────────
VERIFY_WORK="${WORK}/verify_e"
VERIFY_BIN="${VERIFY_WORK}/bin"
VERIFY_WH="${VERIFY_WORK}/wh"
VERIFY_GM="${VERIFY_WORK}/gm"
mkdir -p "${VERIFY_BIN}" "${VERIFY_WH}" "${VERIFY_GM}/active/jleechanorg__testrepo"
for i in $(seq 1 10); do printf 'whl' > "${VERIFY_WH}/pkg${i}-1.0.0-py3-none-any.whl"; done
printf '0123456789abcdef0123456789abcdef01234567\n' > "${VERIFY_GM}/active/jleechanorg__testrepo/SEED_SHA"

cat > "${VERIFY_BIN}/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ] && { echo "ghs_stubtoken"; exit 0; }
exit 1
SH
cat > "${VERIFY_BIN}/docker" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "info" ]; then echo "27.0.0"; exit 0; fi
if [ "${1:-}" = "run" ]; then
  printf 'RX_BEFORE=1000\nRX_AFTER=%s\n' "$((1000 + ${STUB_RX_DELTA:-4096}))"
  exit 0
fi
exit 1
SH
chmod +x "${VERIFY_BIN}/gh" "${VERIFY_BIN}/docker"

CFG_E_OK="${VERIFY_WORK}/cfg_ok.toml"
printf 'version = 1\n[runner]\nimage = "ezgha-runner:latest"\nwheelhouse_host_path = "%s"\ngit_mirror_host_path = "%s"\n' "${VERIFY_WH}" "${VERIFY_GM}" > "${CFG_E_OK}"

OUT_E_PASS="${VERIFY_WORK}/pass.log"
PATH="${VERIFY_BIN}:/usr/local/bin:/usr/bin:/bin" STUB_RX_DELTA=4096 \
  bash "${VERIFY_SCRIPT}" --host local --config "${CFG_E_OK}" --repo jleechanorg/testrepo > "${OUT_E_PASS}" 2>&1 \
  || fail "verify_live_cache_savings.sh failed on <25 MiB delta: $(cat "${OUT_E_PASS}")"
grep -q '^LIVE_CACHE_RX_BYTES=4096$' "${OUT_E_PASS}" || fail "missing LIVE_CACHE_RX_BYTES=4096"

if PATH="${VERIFY_BIN}:/usr/local/bin:/usr/bin:/bin" STUB_RX_DELTA=30000000 \
   bash "${VERIFY_SCRIPT}" --host local --config "${CFG_E_OK}" --repo jleechanorg/testrepo >/dev/null 2>&1; then
  fail "verify_live_cache_savings.sh unexpectedly succeeded on >=25 MiB delta"
fi

CFG_E_TILDE="${VERIFY_WORK}/cfg_tilde.toml"
printf 'version = 1\n[runner]\nimage = "ezgha-runner:latest"\nwheelhouse_host_path = "~/.cache/ezgha-wheelhouse"\ngit_mirror_host_path = "/var/cache/ezgha-git-mirrors"\n' > "${CFG_E_TILDE}"
OUT_E_TILDE="${VERIFY_WORK}/tilde.log"
if PATH="${VERIFY_BIN}:/usr/local/bin:/usr/bin:/bin" \
   bash "${VERIFY_SCRIPT}" --host local --config "${CFG_E_TILDE}" --repo jleechanorg/testrepo > "${OUT_E_TILDE}" 2>&1; then
  fail "verify_live_cache_savings.sh accepted tilde wheelhouse_host_path"
fi
grep -q "must be an absolute path without leading '~'" "${OUT_E_TILDE}" || fail "unexpected tilde error: $(cat "${OUT_E_TILDE}")"
pass "(e) verify_live_cache_savings.sh hermetic <25 MiB PASS, >=25 MiB FAIL, and tilde path rejection verified"

# ── (c) Syntax & behavioral cache-warm installer execution ───────────────────
bash -n "${INSTALL_SCRIPT}"
bash -n "${REFRESH_SCRIPT}"
bash -n "${VERIFY_SCRIPT}"
[ -f "${REPO_ROOT}/systemd/ezgha-cache-warm.service" ] || fail "missing systemd/ezgha-cache-warm.service"
[ -f "${REPO_ROOT}/systemd/ezgha-cache-warm.timer" ] || fail "missing systemd/ezgha-cache-warm.timer"
bash "${REPO_ROOT}/tests/install_cache_warm_agent_test.sh" >/dev/null
pass "(c) syntax checks and behavioral install_cache_warm_agent_test.sh verified"

echo "ALL CACHE TESTS PASS"
