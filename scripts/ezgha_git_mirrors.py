#!/usr/bin/env python3
"""Host-side bare git mirror generation staging, swap, and retention reaping."""

from datetime import datetime, timezone
import os
import re
import shutil
import stat
import subprocess
import time

from ezgha_cache_common import chmod_a_rx, log, merge_env, resolve_docker_env, run_cmd, warn

_GIT_RESET_KEYS = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR",
)
GIT_SANITARY_ENV = {**{k: None for k in _GIT_RESET_KEYS}, "GIT_TERMINAL_PROMPT": "0"}
DEFAULT_MIRROR_REPOS = "jleechanorg/worldarchitect.ai jleechanorg/ez-gh-actions"


def git_auth_args(url):
    if url.startswith("https://github.com/") and shutil.which("gh"):
        return ["-c", "credential.helper=!gh auth git-credential"]
    return []


def find_local_donor(repo):
    if os.environ.get("EZGHA_DISABLE_LOCAL_DONOR", "").strip() == "1":
        return None
    home = os.path.expanduser("~")
    short = repo.split("/")[-1]
    candidates = [os.path.join(home, short, ".git")]
    for base in ("projects", "projects_other"):
        for sub in (repo, short):
            candidates.append(os.path.join(home, base, sub, ".git"))
    wt_root = os.path.join(home, ".worktrees", short)
    if os.path.isdir(wt_root):
        for name in sorted(os.listdir(wt_root))[:32]:
            candidates.append(os.path.join(wt_root, name, ".git"))

    seen_common = set()
    sanitary_env = merge_env(GIT_SANITARY_ENV)
    for cand in candidates:
        if not os.path.exists(cand):
            continue
        proc = subprocess.run(
            [
                "git", "-C", os.path.dirname(cand), "rev-parse",
                "--path-format=absolute", "--git-common-dir", "--is-shallow-repository",
            ],
            env=sanitary_env, text=True, capture_output=True,
        )
        if proc.returncode != 0:
            continue
        lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
        if len(lines) < 2 or lines[0] in seen_common:
            continue
        common_dir, is_shallow = lines[0], lines[1]
        seen_common.add(common_dir)
        if is_shallow == "false" and os.path.isdir(os.path.join(common_dir, "objects")):
            return common_dir
        log(f"skipping shallow or unreadable local donor {common_dir}")
    return None


def resolve_seed_sha(repo_dir):
    sanitary_env = merge_env(GIT_SANITARY_ENV)
    for ref in ("refs/heads/main", "HEAD", "refs/heads/master"):
        proc = subprocess.run(
            ["git", "-C", repo_dir, "rev-parse", "--verify", "--quiet", ref],
            env=sanitary_env, text=True, capture_output=True,
        )
        if proc.returncode == 0:
            sha = proc.stdout.strip()
            if re.fullmatch(r"[0-9a-f]{40}", sha):
                return sha
    return None


def next_generation_epoch(generations_dir, slug):
    now = int(time.time())
    max_existing = 0
    prefix = f"{slug}."
    if os.path.isdir(generations_dir):
        for name in os.listdir(generations_dir):
            if name.startswith(prefix) and name[len(prefix):].isdigit():
                max_existing = max(max_existing, int(name[len(prefix):]))
    return max(now, max_existing + 1)


def _parse_docker_iso_timestamp(ts_raw):
    ts = ts_raw.strip()
    if not ts:
        raise ValueError("empty timestamp")
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    ts = re.sub(r"\.([0-9]+)", lambda m: "." + (m.group(1) + "000000")[:6], ts)
    dt = datetime.fromisoformat(ts)
    return (dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)).timestamp()


def oldest_running_runner_start_epoch(docker_env):
    override = os.environ.get("EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH", "").strip()
    if override:
        if override.lower() == "error":
            warn("simulated docker failure via EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH=error; failing closed on reap")
            return 0.0
        if override.lower() == "none":
            return None
        try:
            return float(override)
        except ValueError:
            warn(f"invalid EZGHA_CACHE_TEST_OLDEST_CONTAINER_EPOCH={override!r}; failing closed on reap")
            return 0.0

    if not shutil.which("docker"):
        warn("docker CLI not found; failing closed to preserve retired generations")
        return 0.0

    docker_proc_env = merge_env(docker_env)
    try:
        ps_proc = subprocess.run(
            ["docker", "ps", "-q", "--filter", "label=ezgha=managed"],
            env=docker_proc_env, text=True, capture_output=True, timeout=15,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        warn(f"docker ps failed ({exc}); failing closed to preserve retired generations")
        return 0.0
    if ps_proc.returncode != 0:
        warn(f"docker ps exited {ps_proc.returncode}; failing closed to preserve retired generations")
        return 0.0

    ids = [ln.strip() for ln in ps_proc.stdout.splitlines() if ln.strip()]
    if not ids:
        return None

    try:
        inspect_proc = subprocess.run(
            ["docker", "inspect", "--format", "{{.State.StartedAt}}", *ids],
            env=docker_proc_env, text=True, capture_output=True, timeout=15,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        warn(f"docker inspect failed ({exc}); failing closed to preserve retired generations")
        return 0.0
    if inspect_proc.returncode != 0:
        warn(f"docker inspect exited {inspect_proc.returncode}; failing closed to preserve retired generations")
        return 0.0

    epochs = []
    for line in inspect_proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            epochs.append(_parse_docker_iso_timestamp(line))
        except ValueError as exc:
            warn(f"unparseable container StartedAt {line!r} ({exc}); failing closed to preserve retired generations")
            return 0.0
    if not epochs:
        warn("docker inspect returned no StartedAt timestamps; failing closed to preserve retired generations")
        return 0.0
    return min(epochs)


def reap_old_generations(generations_dir, active_dir, slug, retention_min, oldest_runner_epoch=None):
    if not os.path.isdir(generations_dir):
        return
    gens_real = os.path.realpath(generations_dir)
    active_link = os.path.join(active_dir, slug)
    active_real = os.path.realpath(active_link) if os.path.lexists(active_link) else None
    now = time.time()
    cutoff = now - (retention_min * 60.0)
    if oldest_runner_epoch is not None:
        cutoff = min(cutoff, oldest_runner_epoch - 60.0)
    prefix, tmp_prefix = f"{slug}.", f".{slug}."

    for name in os.listdir(generations_dir):
        is_tmp = False
        if name.startswith(prefix):
            if not name[len(prefix):].isdigit():
                continue
        elif name.startswith(tmp_prefix):
            if not re.fullmatch(r"[0-9]+\.tmp\.[0-9]+", name[len(tmp_prefix):]):
                continue
            is_tmp = True
        else:
            continue
        entry_path = os.path.join(generations_dir, name)
        if os.path.islink(entry_path):
            continue
        entry_real = os.path.realpath(entry_path)
        if not entry_real.startswith(gens_real + os.sep):
            warn(f"refusing to reap path outside generations root: {entry_real}")
            continue
        if active_real and entry_real == active_real:
            continue
        try:
            st = os.stat(entry_real)
        except OSError:
            continue
        if is_tmp:
            retired_ts = st.st_mtime
        else:
            retired_marker = os.path.join(entry_real, "RETIRED_AT")
            if not os.path.isfile(retired_marker):
                try:
                    with open(retired_marker, "w", encoding="utf-8") as fh:
                        fh.write(f"{int(now)}\n")
                    os.chmod(retired_marker, 0o644)
                except OSError as exc:
                    warn(f"could not stamp RETIRED_AT on unstamped retired generation {entry_real}: {exc}")
                continue
            try:
                with open(retired_marker, "r", encoding="utf-8") as fh:
                    retired_ts = float(fh.read().strip())
            except (OSError, ValueError) as exc:
                warn(f"could not read RETIRED_AT on {entry_real}: {exc}")
                continue
        if retired_ts < cutoff:
            log(f"reaping retired mirror generation: {entry_real}")
            shutil.rmtree(entry_real, ignore_errors=True)


def slugs_for(repos):
    return [r.replace("/", "__") for r in repos]


def discover_generation_slugs(generations_dir, repos=()):
    slugs = set(slugs_for(repos))
    if os.path.isdir(generations_dir):
        for name in os.listdir(generations_dir):
            if not name.startswith("."):
                m = re.fullmatch(r"(.+)\.[0-9]+", name)
                if m:
                    slugs.add(m.group(1))
                    continue
            m_tmp = re.fullmatch(r"\.(.+)\.[0-9]+\.tmp\.[0-9]+", name)
            if m_tmp:
                slugs.add(m_tmp.group(1))
    return sorted(slugs)


def _publish_repo_generation(repo, url, staging_root, generations_dir, active_dir, gens_real):
    slug = repo.replace("/", "__")
    staging_dir = os.path.join(staging_root, f"{slug}.git")
    auth_args = git_auth_args(url)

    if not os.path.isdir(os.path.join(staging_dir, "objects")) or not resolve_seed_sha(staging_dir):
        if os.path.exists(staging_dir):
            shutil.rmtree(staging_dir, ignore_errors=True)
        donor = find_local_donor(repo)
        clone_cmd = ["git", *auth_args, "clone", "--bare"]
        if donor:
            log(f"initializing staging mirror for {repo} with local donor {donor}")
            clone_cmd.extend(["--reference", donor, "--dissociate"])
        else:
            log(f"initializing staging mirror for {repo} from {url}")
        clone_cmd.extend([url, staging_dir])
        run_cmd(clone_cmd, timeout=600, env=GIT_SANITARY_ENV)

    run_cmd(["git", "-C", staging_dir, "config", "core.commitGraph", "false"], timeout=30, env=GIT_SANITARY_ENV)
    run_cmd(["git", "-C", staging_dir, "config", "gc.auto", "0"], timeout=30, env=GIT_SANITARY_ENV)
    run_cmd(
        ["git", *auth_args, "-C", staging_dir, "fetch", "--prune", url, "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"],
        timeout=300, env=GIT_SANITARY_ENV,
    )

    seed_sha = resolve_seed_sha(staging_dir)
    if not seed_sha:
        warn(f"could not resolve SEED_SHA for {repo}; skipping generation publish")
        return

    active_link = os.path.join(active_dir, slug)
    prev_active_real = os.path.realpath(active_link) if os.path.lexists(active_link) else None
    active_seed_file = os.path.join(active_link, "SEED_SHA")
    current_seed = ""
    if os.path.isfile(active_seed_file):
        with open(active_seed_file, "r", encoding="utf-8") as fh:
            current_seed = fh.read().strip()
    if current_seed == seed_sha:
        log(f"mirror {repo} unchanged at {seed_sha}")
        return

    epoch = next_generation_epoch(generations_dir, slug)
    gen_tmp = os.path.join(generations_dir, f".{slug}.{epoch}.tmp.{os.getpid()}")
    gen_final = os.path.join(generations_dir, f"{slug}.{epoch}")
    if os.path.exists(gen_tmp):
        shutil.rmtree(gen_tmp, ignore_errors=True)
    run_cmd(["git", "clone", "--bare", "--local", staging_dir, gen_tmp], timeout=300, env=GIT_SANITARY_ENV)

    info_dir = os.path.join(gen_tmp, "objects", "info")
    for cg_name in ("commit-graph", "commit-graphs"):
        cg_path = os.path.join(info_dir, cg_name)
        if os.path.isdir(cg_path) and not os.path.islink(cg_path):
            shutil.rmtree(cg_path)
        elif os.path.lexists(cg_path):
            os.unlink(cg_path)

    for marker_name in ("SEED_SHA", "MAIN_SHA"):
        with open(os.path.join(gen_tmp, marker_name), "w", encoding="utf-8") as fh:
            fh.write(f"{seed_sha}\n")

    chmod_a_rx(gen_tmp)
    os.replace(gen_tmp, gen_final)
    gen_final_real = os.path.realpath(gen_final)

    tmp_link = os.path.join(active_dir, f".{slug}.link.{os.getpid()}")
    if os.path.lexists(tmp_link):
        os.unlink(tmp_link)
    os.symlink(f"../generations/{slug}.{epoch}", tmp_link)
    os.replace(tmp_link, active_link)

    if prev_active_real and prev_active_real != gen_final_real and os.path.isdir(prev_active_real) and prev_active_real.startswith(gens_real + os.sep):
        retired_marker = os.path.join(prev_active_real, "RETIRED_AT")
        try:
            with open(retired_marker, "w", encoding="utf-8") as fh:
                fh.write(f"{int(time.time())}\n")
            os.chmod(retired_marker, 0o644)
            os.utime(prev_active_real, None)
        except OSError as exc:
            warn(f"could not stamp RETIRED_AT on {prev_active_real}: {exc}")
    log(f"published mirror {repo} -> {slug}.{epoch} ({seed_sha})")


def refresh_git_mirrors(mirror_root, reap_only=False):
    if not mirror_root or mirror_root.startswith("~") or not os.path.isabs(mirror_root):
        raise ValueError(f"mirror_root must be an absolute path without leading '~' (got {mirror_root!r})")
    mirror_root = os.path.abspath(mirror_root)
    staging_root = os.path.join(mirror_root, ".staging")
    generations_dir = os.path.join(mirror_root, "generations")
    active_dir = os.path.join(mirror_root, "active")

    if reap_only and not os.path.isdir(generations_dir):
        return

    repos = [r for r in os.environ.get("EZGHA_MIRROR_REPOS", DEFAULT_MIRROR_REPOS).strip().split() if r]
    url_tmpl = os.environ.get("EZGHA_MIRROR_URL_TEMPLATE", "https://github.com/%s.git")
    # Default 480 min (8h): GitHub Actions' max job timeout is 360m + 120m safety margin.
    retention_min = int(os.environ.get("EZGHA_MIRROR_RETENTION_MIN", "480"))
    oldest_runner_epoch = oldest_running_runner_start_epoch(resolve_docker_env())

    if reap_only:
        for slug in sorted(set(slugs_for(repos)) | set(discover_generation_slugs(generations_dir))):
            reap_old_generations(generations_dir, active_dir, slug, retention_min, oldest_runner_epoch=oldest_runner_epoch)
        return

    for d in (mirror_root, staging_root, generations_dir, active_dir):
        os.makedirs(d, exist_ok=True)
    gens_real = os.path.realpath(generations_dir)
    for d in (mirror_root, generations_dir, active_dir):
        st = os.lstat(d)
        if not stat.S_ISLNK(st.st_mode):
            os.chmod(d, stat.S_IMODE(st.st_mode) | 0o555)

    repo_errors = []
    for repo in repos:
        url = url_tmpl % repo if "%s" in url_tmpl else f"{url_tmpl.rstrip('/')}/{repo}.git"
        try:
            _publish_repo_generation(repo, url, staging_root, generations_dir, active_dir, gens_real)
        except Exception as exc:
            warn(f"failed refreshing mirror for {repo}: {exc}")
            repo_errors.append(repo)

    for slug in sorted(set(slugs_for(repos)) | set(discover_generation_slugs(generations_dir))):
        reap_old_generations(generations_dir, active_dir, slug, retention_min, oldest_runner_epoch=oldest_runner_epoch)

    if repo_errors:
        raise RuntimeError(f"mirror refresh failed for: {', '.join(repo_errors)}")
