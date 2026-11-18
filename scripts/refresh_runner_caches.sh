#!/usr/bin/env bash
# Refresh host-side git mirrors and pip wheelhouse caches for ezgha runners.
# Portable across Ubuntu Linux (bash + GNU) and macOS (bash 3.2+ + BSD).
set -euo pipefail

umask 0022

# Ensure standard tool paths (Homebrew on macOS, cargo/local bins) are visible
# even under minimal launchd/systemd environments.
for _dir in /opt/homebrew/bin /usr/local/bin "${HOME}/.local/bin" "${HOME}/.cargo/bin"; do
  if [ -d "${_dir}" ] && [[ ":${PATH}:" != *":${_dir}:"* ]]; then
    PATH="${_dir}:${PATH}"
  fi
done
export PATH

exec python3 - "$@" <<'PY'
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time


GIT_REPO_ENV_RESET = {
    k: None
    for k in (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
    )
}
GIT_SANITARY_ENV = {**GIT_REPO_ENV_RESET, "GIT_TERMINAL_PROMPT": "0"}


DEFAULT_MIRROR_REPOS = "jleechanorg/worldarchitect.ai jleechanorg/ez-gh-actions"
DEFAULT_CORE_PACKAGES = [
    "pip",
    "setuptools",
    "wheel",
    "pytest",
    "pytest-xdist",
    "pytest-cov",
    "pytest-testmon",
    "coverage",
    "pydantic",
    "ruff",
    "mypy",
]


def log(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[cache-warm {ts}] {msg}", flush=True)


def warn(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[cache-warm {ts}] WARNING: {msg}", file=sys.stderr, flush=True)


def resolve_config_path(explicit_path):
    if explicit_path:
        return os.path.expanduser(explicit_path), True
    env_cfg = os.environ.get("EZGHA_CONFIG", "").strip()
    if env_cfg:
        return os.path.expanduser(env_cfg), True
    home = os.path.expanduser("~")
    if platform.system() == "Darwin":
        mac_cfg = os.path.join(
            home, "Library", "Application Support", "org.jleechanorg.ezgha", "config.toml"
        )
        if os.path.isfile(mac_cfg):
            return mac_cfg, False
    return os.path.join(home, ".config", "ezgha", "config.toml"), False


def _strip_toml_comment(line):
    in_quote = None
    escaped = False
    for idx, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if in_quote == '"' and ch == "\\":
            escaped = True
            continue
        if ch in ('"', "'"):
            if in_quote is None:
                in_quote = ch
            elif in_quote == ch:
                in_quote = None
            continue
        if ch == "#" and in_quote is None:
            return line[:idx]
    return line


def _parse_toml_fallback(text):
    data = {}
    section = None
    for raw_line in text.splitlines():
        line = _strip_toml_comment(raw_line).strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            sec_name = line[1:-1].strip()
            if not sec_name.startswith("["):
                section = data.setdefault(sec_name, {})
            continue
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if (val.startswith('"') and val.endswith('"')) or (
            val.startswith("'") and val.endswith("'")
        ):
            parsed = val[1:-1]
        elif re.fullmatch(r"[+-]?[0-9]+", val):
            parsed = int(val)
        elif val in ("true", "false"):
            parsed = val == "true"
        else:
            parsed = val
        target = section if section is not None else data
        target[key] = parsed
    return data


def load_toml(path):
    try:
        import tomllib  # Python 3.11+

        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except ImportError:
        with open(path, "r", encoding="utf-8") as fh:
            return _parse_toml_fallback(fh.read())


def chmod_a_rx(root_path):
    """Apply portable chmod -R a+rX semantics without spawning external tools."""
    def _chmod_dir(d):
        st = os.lstat(d)
        if stat.S_ISLNK(st.st_mode):
            return
        os.chmod(d, stat.S_IMODE(st.st_mode) | 0o555)

    def _chmod_file(f):
        st = os.lstat(f)
        if stat.S_ISLNK(st.st_mode):
            return
        mode = stat.S_IMODE(st.st_mode)
        add_bits = 0o444 | (0o111 if (mode & 0o111) else 0)
        os.chmod(f, mode | add_bits)

    _chmod_dir(root_path)
    for dirpath, dirnames, filenames in os.walk(root_path):
        for d in dirnames:
            _chmod_dir(os.path.join(dirpath, d))
        for fn in filenames:
            _chmod_file(os.path.join(dirpath, fn))


def nearest_existing_dir(path):
    cur = os.path.abspath(os.path.expanduser(path))
    while cur and not os.path.exists(cur):
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return cur or "/"


def get_free_gb(paths):
    override = os.environ.get("EZGHA_CACHE_TEST_FREE_GB", "").strip()
    if override:
        return float(override)
    free_values = []
    for p in paths:
        if not p:
            continue
        existing = nearest_existing_dir(p)
        st = os.statvfs(existing)
        free_values.append((st.f_bavail * st.f_frsize) / (1024 ** 3))
    if not free_values:
        st = os.statvfs(os.path.expanduser("~"))
        return (st.f_bavail * st.f_frsize) / (1024 ** 3)
    return min(free_values)


def git_auth_args(url):
    if url.startswith("https://github.com/") and shutil.which("gh"):
        return ["-c", "credential.helper=!gh auth git-credential"]
    return []


def merge_env(extra_env):
    merged_env = os.environ.copy()
    if extra_env:
        for k, v in extra_env.items():
            if v is None:
                merged_env.pop(k, None)
            else:
                merged_env[k] = v
    return merged_env


def run_cmd(cmd, timeout=None, env=None, capture=False, input_text=None):
    return subprocess.run(
        cmd,
        timeout=timeout,
        env=merge_env(env),
        check=True,
        text=True,
        input=input_text,
        capture_output=capture,
    )


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
        cand_dir = os.path.dirname(cand)
        proc = subprocess.run(
            [
                "git",
                "-C",
                cand_dir,
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
                "--is-shallow-repository",
            ],
            env=sanitary_env,
            text=True,
            capture_output=True,
        )
        if proc.returncode != 0:
            continue
        lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
        if len(lines) < 2:
            continue
        common_dir, is_shallow = lines[0], lines[1]
        if common_dir in seen_common:
            continue
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
            env=sanitary_env,
            text=True,
            capture_output=True,
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
            if not name.startswith(prefix):
                continue
            suffix = name[len(prefix):]
            if suffix.isdigit():
                max_existing = max(max_existing, int(suffix))
    return max(now, max_existing + 1)


def _parse_docker_iso_timestamp(ts_raw):
    ts = ts_raw.strip()
    if not ts:
        raise ValueError("empty timestamp")
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    ts = re.sub(
        r"\.([0-9]+)",
        lambda m: "." + (m.group(1) + "000000")[:6],
        ts,
    )
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


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
        return None

    docker_proc_env = merge_env(docker_env)
    try:
        ps_proc = subprocess.run(
            ["docker", "ps", "-q", "--filter", "label=ezgha=managed"],
            env=docker_proc_env,
            text=True,
            capture_output=True,
            timeout=15,
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
            env=docker_proc_env,
            text=True,
            capture_output=True,
            timeout=15,
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
    prefix = f"{slug}."
    tmp_prefix = f".{slug}."

    for name in os.listdir(generations_dir):
        is_tmp = False
        if name.startswith(prefix):
            suffix = name[len(prefix):]
            if not suffix.isdigit():
                continue
        elif name.startswith(tmp_prefix):
            suffix = name[len(tmp_prefix):]
            if not re.fullmatch(r"[0-9]+\.tmp\.[0-9]+", suffix):
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


def discover_generation_slugs(generations_dir, repos):
    slugs = {r.replace("/", "__") for r in repos}
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


def refresh_git_mirrors(mirror_root, reap_only=False):
    mirror_root = os.path.abspath(os.path.expanduser(mirror_root))
    staging_root = os.path.join(mirror_root, ".staging")
    generations_dir = os.path.join(mirror_root, "generations")
    active_dir = os.path.join(mirror_root, "active")

    repos_raw = os.environ.get("EZGHA_MIRROR_REPOS", DEFAULT_MIRROR_REPOS).strip()
    repos = [r for r in repos_raw.split() if r]
    url_tmpl = os.environ.get("EZGHA_MIRROR_URL_TEMPLATE", "https://github.com/%s.git")
    # Default 480 min (8h): GitHub Actions' max workflow job timeout is 360 min
    # (normal peak <= 360m), plus a +120 min safety margin.
    retention_min = int(os.environ.get("EZGHA_MIRROR_RETENTION_MIN", "480"))
    oldest_runner_epoch = oldest_running_runner_start_epoch(resolve_docker_env())

    if reap_only:
        if os.path.isdir(generations_dir):
            for slug in discover_generation_slugs(generations_dir, repos):
                reap_old_generations(
                    generations_dir,
                    active_dir,
                    slug,
                    retention_min,
                    oldest_runner_epoch=oldest_runner_epoch,
                )
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
        slug = repo.replace("/", "__")
        url = url_tmpl % repo if "%s" in url_tmpl else f"{url_tmpl.rstrip('/')}/{repo}.git"
        staging_dir = os.path.join(staging_root, f"{slug}.git")
        auth_args = git_auth_args(url)

        try:
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
                [
                    "git",
                    *auth_args,
                    "-C",
                    staging_dir,
                    "fetch",
                    "--prune",
                    url,
                    "+refs/heads/*:refs/heads/*",
                    "+refs/tags/*:refs/tags/*",
                ],
                timeout=300,
                env=GIT_SANITARY_ENV,
            )

            seed_sha = resolve_seed_sha(staging_dir)
            if not seed_sha:
                warn(f"could not resolve SEED_SHA for {repo}; skipping generation publish")
                continue

            active_link = os.path.join(active_dir, slug)
            prev_active_real = os.path.realpath(active_link) if os.path.lexists(active_link) else None
            active_seed_file = os.path.join(active_link, "SEED_SHA")
            current_seed = ""
            if os.path.isfile(active_seed_file):
                with open(active_seed_file, "r", encoding="utf-8") as fh:
                    current_seed = fh.read().strip()

            if current_seed == seed_sha:
                log(f"mirror {repo} unchanged at {seed_sha}")
            else:
                epoch = next_generation_epoch(generations_dir, slug)
                gen_tmp = os.path.join(generations_dir, f".{slug}.{epoch}.tmp.{os.getpid()}")
                gen_final = os.path.join(generations_dir, f"{slug}.{epoch}")
                if os.path.exists(gen_tmp):
                    shutil.rmtree(gen_tmp, ignore_errors=True)

                run_cmd(
                    ["git", "clone", "--bare", "--local", staging_dir, gen_tmp],
                    timeout=300,
                    env=GIT_SANITARY_ENV,
                )

                info_dir = os.path.join(gen_tmp, "objects", "info")
                for cg_name in ("commit-graph", "commit-graphs"):
                    cg_path = os.path.join(info_dir, cg_name)
                    if os.path.isdir(cg_path) and not os.path.islink(cg_path):
                        shutil.rmtree(cg_path)
                    elif os.path.lexists(cg_path):
                        os.unlink(cg_path)

                for marker_name in ("SEED_SHA", "MAIN_SHA"):
                    marker_path = os.path.join(gen_tmp, marker_name)
                    with open(marker_path, "w", encoding="utf-8") as fh:
                        fh.write(f"{seed_sha}\n")

                chmod_a_rx(gen_tmp)
                os.replace(gen_tmp, gen_final)
                gen_final_real = os.path.realpath(gen_final)

                tmp_link = os.path.join(active_dir, f".{slug}.link.{os.getpid()}")
                if os.path.lexists(tmp_link):
                    os.unlink(tmp_link)
                os.symlink(f"../generations/{slug}.{epoch}", tmp_link)
                os.replace(tmp_link, active_link)

                if (
                    prev_active_real
                    and prev_active_real != gen_final_real
                    and os.path.isdir(prev_active_real)
                    and prev_active_real.startswith(gens_real + os.sep)
                ):
                    retired_at = int(time.time())
                    retired_marker = os.path.join(prev_active_real, "RETIRED_AT")
                    try:
                        with open(retired_marker, "w", encoding="utf-8") as fh:
                            fh.write(f"{retired_at}\n")
                        os.chmod(retired_marker, 0o644)
                        os.utime(prev_active_real, None)
                    except OSError as exc:
                        warn(f"could not stamp RETIRED_AT on {prev_active_real}: {exc}")

                log(f"published mirror {repo} -> {slug}.{epoch} ({seed_sha})")

            reap_old_generations(
                generations_dir,
                active_dir,
                slug,
                retention_min,
                oldest_runner_epoch=oldest_runner_epoch,
            )
        except Exception as exc:
            warn(f"failed refreshing mirror for {repo}: {exc}")
            repo_errors.append(repo)

    if repo_errors:
        raise RuntimeError(f"mirror refresh failed for: {', '.join(repo_errors)}")


def resolve_docker_env():
    env = {}
    if os.environ.get("DOCKER_HOST", "").strip():
        env["DOCKER_CONTEXT"] = None
        return env
    sysname = platform.system()
    if sysname == "Darwin":
        plist = os.path.expanduser("~/Library/LaunchAgents/org.jleechanorg.ezgha.plist")
        if os.path.isfile(plist) and shutil.which("plutil"):
            try:
                proc = subprocess.run(
                    ["plutil", "-extract", "EnvironmentVariables.DOCKER_HOST", "raw", "-o", "-", plist],
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                if proc.returncode == 0 and proc.stdout.strip():
                    env["DOCKER_HOST"] = proc.stdout.strip()
                    env["DOCKER_CONTEXT"] = None
                    return env
            except (subprocess.TimeoutExpired, OSError) as exc:
                warn(f"plutil failed reading DOCKER_HOST from {plist}: {exc}")
        if not os.path.exists("/var/run/docker.sock"):
            colima_sock = os.path.expanduser("~/.colima/default/docker.sock")
            if os.path.exists(colima_sock):
                env["DOCKER_HOST"] = f"unix://{colima_sock}"
                env["DOCKER_CONTEXT"] = None
    elif sysname == "Linux":
        unit_path = os.path.expanduser("~/.config/systemd/user/ezgha.service")
        if os.path.isfile(unit_path):
            try:
                with open(unit_path, "r", encoding="utf-8") as fh:
                    for raw_line in fh:
                        line = raw_line.strip()
                        if not line or line.startswith(("#", ";")):
                            continue
                        if not line.startswith("Environment="):
                            continue
                        rhs = line.split("=", 1)[1].strip()
                        for token in shlex.split(rhs):
                            if token.startswith("DOCKER_HOST="):
                                val = token.split("=", 1)[1].strip()
                                if val:
                                    env["DOCKER_HOST"] = val
                                    env["DOCKER_CONTEXT"] = None
                                    return env
            except (OSError, ValueError) as exc:
                warn(f"could not parse DOCKER_HOST from {unit_path}: {exc}")
    return env


def gather_req_files():
    override = os.environ.get("EZGHA_WHEELHOUSE_REQ_FILES", "").strip()
    if override:
        candidates = [os.path.expanduser(p) for p in re.split(r"[\s:]+", override) if p]
    else:
        home = os.path.expanduser("~")
        candidates = [
            os.path.join(home, "projects", "worldarchitect.ai", "mvp_site", "requirements.txt"),
            os.path.join(home, "projects", "worldarchitect.ai", "mvp_site", "requirements-test.txt"),
        ]
    return [p for p in candidates if os.path.isfile(p)]


BUILD_TAG_MARKER = "999999ezgha"


def sync_wheelhouse_build_tag_symlinks(wheelhouse_path, clear_only=False):
    """Ensure relative PEP 427 build-tag symlinks exist for every real wheel.

    Upstream pip's resolvelib Factory._iter_found_candidates reverses
    sorted([file_candidates, page_candidates], key=_sort_key), which flips
    tie-break precedence to PyPI when version, wheel tags, and build_tag tie.
    Adding a relative `{dist}-{ver}-999999ezgha-{py}-{abi}-{plat}.whl -> {fn}`
    symlink keeps `candidate.version` identical while setting
    `build_tag = (999999, 'ezgha') > ()`, so pip strictly selects the local
    wheel over equal-version PyPI wheels while still allowing newer PyPI
    versions when unpinned.
    """
    for fn in list(os.listdir(wheelhouse_path)):
        full = os.path.join(wheelhouse_path, fn)
        if os.path.islink(full) and (f"-{BUILD_TAG_MARKER}-" in fn or not os.path.exists(full)):
            if clear_only or not os.path.exists(full):
                try:
                    os.unlink(full)
                except OSError:
                    pass
    if clear_only:
        return
    for fn in sorted(os.listdir(wheelhouse_path)):
        if not fn.endswith(".whl"):
            continue
        full = os.path.join(wheelhouse_path, fn)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        parts = fn[:-4].rsplit("-", 3)
        if len(parts) != 4:
            continue
        dv = parts[0].split("-")
        if len(dv) != 2:
            continue
        alias = f"{dv[0]}-{dv[1]}-{BUILD_TAG_MARKER}-{parts[1]}-{parts[2]}-{parts[3]}.whl"
        alias_path = os.path.join(wheelhouse_path, alias)
        if not os.path.lexists(alias_path):
            os.symlink(fn, alias_path)


def _iter_logical_req_lines(path):
    with open(path, "r", encoding="utf-8") as fh:
        buf = ""
        for raw_line in fh:
            stripped = raw_line.rstrip("\r\n")
            if stripped.endswith("\\"):
                buf += stripped[:-1] + " "
                continue
            buf += stripped
            yield buf
            buf = ""
        if buf:
            yield buf


def collect_req_closure(req_files):
    """Resolve top-level requirement files and recursive -r/-c local includes."""
    entries = []
    all_files = set()

    for rf in req_files:
        rf_real = os.path.realpath(rf)
        closure = set()
        queue = [rf_real]
        while queue:
            cur = queue.pop(0)
            if cur in closure or not os.path.isfile(cur):
                continue
            closure.add(cur)
            all_files.add(cur)
            cur_dir = os.path.dirname(cur)
            try:
                for line in _iter_logical_req_lines(cur):
                    clean = re.sub(r"(^|\s)#.*$", "", line).strip()
                    if not clean:
                        continue
                    try:
                        tokens = shlex.split(clean)
                    except ValueError:
                        tokens = clean.split()
                    i = 0
                    while i < len(tokens):
                        tok = tokens[i]
                        ref = None
                        if tok in ("-r", "--requirement", "-c", "--constraint") and i + 1 < len(tokens):
                            ref = tokens[i + 1]
                            i += 2
                        elif tok.startswith(("--requirement=", "--constraint=")):
                            ref = tok.split("=", 1)[1]
                            i += 1
                        elif (tok.startswith("-r") or tok.startswith("-c")) and len(tok) > 2:
                            ref = tok[2:]
                            i += 1
                        else:
                            i += 1
                            continue
                        if ref and "://" not in ref:
                            cand = os.path.realpath(os.path.join(cur_dir, ref))
                            if os.path.commonpath([os.path.dirname(rf_real), os.path.dirname(cand)]) == "/":
                                if os.path.isfile(cand):
                                    warn(f"skipping requirement include {cand} outside root of {rf_real}")
                                continue
                            if os.path.isfile(cand) and cand not in closure:
                                queue.append(cand)
            except OSError:
                continue

        if closure:
            common_dir = os.path.commonpath([os.path.dirname(p) for p in closure])
            entries.append((rf_real, common_dir, sorted(closure)))

    return entries, sorted(all_files)


def refresh_wheelhouse(wheelhouse_path, image):
    wheelhouse_path = os.path.abspath(os.path.expanduser(wheelhouse_path))
    os.makedirs(wheelhouse_path, exist_ok=True)
    chmod_a_rx(wheelhouse_path)

    if not shutil.which("docker"):
        warn("docker CLI not found; skipping wheelhouse refresh")
        return

    docker_env = resolve_docker_env()
    docker_proc_env = merge_env(docker_env)
    try:
        info_proc = subprocess.run(
            ["docker", "info"], env=docker_proc_env, capture_output=True, timeout=30
        )
    except subprocess.TimeoutExpired:
        warn("docker info timed out after 30s; skipping wheelhouse refresh")
        return
    if info_proc.returncode != 0:
        warn("docker daemon unreachable; skipping wheelhouse refresh")
        return

    try:
        inspect_proc = subprocess.run(
            ["docker", "image", "inspect", "--format", "{{.Id}}", image],
            env=docker_proc_env,
            text=True,
            capture_output=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        warn(f"docker image inspect timed out after 30s for {image}; skipping wheelhouse refresh")
        return
    if inspect_proc.returncode != 0:
        warn(f"runner image {image} not present locally; skipping wheelhouse refresh")
        return
    image_id = inspect_proc.stdout.strip()

    try:
        pw_proc = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "--entrypoint",
                "bash",
                image,
                "-lc",
                "cat /ms-playwright/PLAYWRIGHT_VERSION 2>/dev/null || echo 1.65.2",
            ],
            env=docker_proc_env,
            text=True,
            capture_output=True,
            timeout=60,
        )
        pw_ver = pw_proc.stdout.strip() if pw_proc.returncode == 0 and pw_proc.stdout.strip() else "1.65.2"
    except subprocess.TimeoutExpired:
        warn(f"timed out querying PLAYWRIGHT_VERSION from {image}; skipping wheelhouse refresh")
        return

    req_files = gather_req_files()
    req_entries, all_req_files = collect_req_closure(req_files)
    core_pkgs = DEFAULT_CORE_PACKAGES + [f"playwright=={pw_ver}"]

    hasher = hashlib.sha256()
    hasher.update(f"image={image_id}\n".encode("utf-8"))
    hasher.update(f"playwright={pw_ver}\n".encode("utf-8"))
    hasher.update(("core=" + " ".join(core_pkgs) + "\n").encode("utf-8"))
    for fp in all_req_files:
        with open(fp, "rb") as fh:
            raw = fh.read()
        hasher.update(f"file={fp}\n".encode("utf-8"))
        hasher.update(raw)
    manifest_sha = hasher.hexdigest()

    manifest_file = os.path.join(wheelhouse_path, ".manifest.sha256")
    whl_count = sum(
        1
        for fn in os.listdir(wheelhouse_path)
        if fn.endswith(".whl") and not os.path.islink(os.path.join(wheelhouse_path, fn))
    )
    if os.path.isfile(manifest_file):
        with open(manifest_file, "r", encoding="utf-8") as fh:
            prev_sha = fh.read().strip()
        if prev_sha == manifest_sha and whl_count >= 10:
            sync_wheelhouse_build_tag_symlinks(wheelhouse_path)
            log(f"wheelhouse up-to-date ({whl_count} wheels, manifest {manifest_sha[:12]})")
            return

    sync_wheelhouse_build_tag_symlinks(wheelhouse_path, clear_only=True)

    staged_files = []
    req_container_paths = []
    for idx, (req_real, common_dir, closure_files) in enumerate(req_entries):
        for fp in closure_files:
            rel_fp = os.path.relpath(fp, common_dir).replace(os.sep, "/")
            with open(fp, "r", encoding="utf-8", errors="replace") as fh:
                staged_files.append((f"{idx}/{rel_fp}", fh.read()))
        rel_req = os.path.relpath(req_real, common_dir).replace(os.sep, "/")
        req_container_paths.append(f"/tmp/ezgha-reqs/{idx}/{rel_req}")

    payload = json.dumps(
        {
            "core": core_pkgs,
            "staged_files": staged_files,
            "req_paths": req_container_paths,
        }
    )
    container_script = (
        "import glob, json, os, shutil, subprocess, sys\n"
        "data = json.load(sys.stdin)\n"
        "for whl in glob.glob('/opt/baked-wheels/*.whl'):\n"
        "    dst = os.path.join('/wheelhouse', os.path.basename(whl))\n"
        "    if not os.path.exists(dst):\n"
        "        shutil.copy2(whl, dst)\n"
        "stage_root = '/tmp/ezgha-reqs'\n"
        "for rel, content in data.get('staged_files', []):\n"
        "    dst = os.path.normpath(os.path.join(stage_root, rel))\n"
        "    if not dst.startswith(stage_root + '/'):\n"
        "        raise ValueError(f'unsafe staged path: {rel}')\n"
        "    os.makedirs(os.path.dirname(dst), exist_ok=True)\n"
        "    with open(dst, 'w', encoding='utf-8') as fh:\n"
        "        fh.write(content)\n"
        "base_cmd = [sys.executable, '-m', 'pip', 'download', '--dest', '/wheelhouse', '--find-links', '/wheelhouse']\n"
        "subprocess.run(base_cmd + data['core'], check=True)\n"
        "if data['req_paths']:\n"
        "    req_cmd = list(base_cmd)\n"
        "    for p in data['req_paths']:\n"
        "        req_cmd.extend(['-r', p])\n"
        "    subprocess.run(req_cmd, check=True)\n"
    )
    docker_cmd = ["docker", "run", "--rm", "-i", "-v", f"{wheelhouse_path}:/wheelhouse"]
    if platform.system() == "Linux":
        docker_cmd.extend(["--user", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp"])
    docker_cmd.extend([image, "python3", "-c", container_script])

    log(f"refreshing wheelhouse via {image} (playwright=={pw_ver}, {len(req_files)} req files)")
    run_cmd(docker_cmd, timeout=900, env=docker_env, input_text=payload)

    chmod_a_rx(wheelhouse_path)
    sync_wheelhouse_build_tag_symlinks(wheelhouse_path)
    with open(manifest_file, "w", encoding="utf-8") as fh:
        fh.write(f"{manifest_sha}\n")
    os.chmod(manifest_file, 0o644)
    new_count = sum(
        1
        for fn in os.listdir(wheelhouse_path)
        if fn.endswith(".whl") and not os.path.islink(os.path.join(wheelhouse_path, fn))
    )
    log(f"wheelhouse refreshed ({new_count} wheels, manifest {manifest_sha[:12]})")


def main():
    parser = argparse.ArgumentParser(description="Refresh ezgha runner git mirrors and wheelhouse.")
    parser.add_argument("--config", help="Path to ezgha config.toml")
    parser.add_argument("--skip-git", action="store_true", help="Skip git mirror refresh")
    parser.add_argument("--skip-wheels", action="store_true", help="Skip wheelhouse refresh")
    args = parser.parse_args()

    cfg_path, explicit = resolve_config_path(args.config)
    if not os.path.isfile(cfg_path):
        if explicit:
            warn(f"config file not found: {cfg_path}")
            return 1
        log(f"config file not found ({cfg_path}); nothing to warm")
        return 0

    cfg = load_toml(cfg_path)
    runner_cfg = cfg.get("runner", {})
    limits_cfg = cfg.get("limits", {})

    git_mirror_path = (runner_cfg.get("git_mirror_host_path") or "").strip()
    wheelhouse_path = (runner_cfg.get("wheelhouse_host_path") or "").strip()
    image = (runner_cfg.get("image") or "ezgha-runner:latest").strip()
    min_free_gb = int(limits_cfg.get("min_free_disk_gb", 10))

    if not git_mirror_path and not wheelhouse_path:
        log("neither runner.git_mirror_host_path nor runner.wheelhouse_host_path configured; exiting")
        return 0

    state_dir = os.environ.get("EZGHA_CACHE_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".local", "state", "ezgha"
    )
    os.makedirs(state_dir, exist_ok=True)
    lock_path = os.path.join(state_dir, "cache-warm.lock")
    lock_fh = open(lock_path, "a+", encoding="utf-8")
    try:
        try:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log("cache-warm lock already held; exiting")
            return 0

        buffer_gb = int(os.environ.get("EZGHA_CACHE_MIN_FREE_BUFFER_GB", "5"))
        required_gb = min_free_gb + buffer_gb

        stage_errors = []
        if git_mirror_path and not args.skip_git:
            git_free_gb = get_free_gb([git_mirror_path])
            if git_free_gb < required_gb:
                warn(
                    f"free disk {git_free_gb:.1f} GiB below safety floor+{buffer_gb} ({required_gb} GiB); skipping new git mirror clones and reaping retired generations only"
                )
                try:
                    refresh_git_mirrors(git_mirror_path, reap_only=True)
                except Exception as exc:
                    warn(f"git mirror reap-only stage encountered error: {exc}")
                    stage_errors.append("git")
            else:
                try:
                    refresh_git_mirrors(git_mirror_path, reap_only=False)
                except Exception as exc:
                    warn(f"git mirror stage encountered error: {exc}")
                    stage_errors.append("git")

        if wheelhouse_path and not args.skip_wheels:
            wheel_free_gb = get_free_gb([wheelhouse_path])
            if wheel_free_gb < required_gb:
                warn(
                    f"free disk {wheel_free_gb:.1f} GiB below safety floor+{buffer_gb} ({required_gb} GiB); skipping wheelhouse refresh"
                )
            else:
                try:
                    refresh_wheelhouse(wheelhouse_path, image)
                except Exception as exc:
                    warn(f"wheelhouse stage encountered error: {exc}")
                    stage_errors.append("wheelhouse")

        if stage_errors:
            return 1
    finally:
        lock_fh.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
