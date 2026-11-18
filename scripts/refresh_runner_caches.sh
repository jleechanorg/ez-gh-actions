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
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import time


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
        st = os.stat(d, follow_symlinks=False)
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


def run_cmd(cmd, timeout=None, env=None, capture=False, input_text=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        cmd,
        timeout=timeout,
        env=merged_env,
        check=True,
        text=True,
        input=input_text,
        capture_output=capture,
    )


def find_local_donor(repo):
    home = os.path.expanduser("~")
    short = repo.split("/")[-1]
    candidates = []
    for base in ("projects", "projects_other"):
        for sub in (repo, short):
            candidates.append(os.path.join(home, base, sub, ".git"))
    for cand in candidates:
        if os.path.exists(cand):
            return os.path.dirname(cand)
    return None


def resolve_seed_sha(repo_dir):
    for ref in ("refs/heads/main", "HEAD", "refs/heads/master"):
        proc = subprocess.run(
            ["git", "-C", repo_dir, "rev-parse", "--verify", "--quiet", ref],
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


def reap_old_generations(generations_dir, active_dir, slug, retention_min):
    if not os.path.isdir(generations_dir):
        return
    gens_real = os.path.realpath(generations_dir)
    active_link = os.path.join(active_dir, slug)
    active_real = os.path.realpath(active_link) if os.path.lexists(active_link) else None
    cutoff = time.time() - (retention_min * 60.0)
    prefix = f"{slug}."
    tmp_prefix = f".{slug}."

    for name in os.listdir(generations_dir):
        if not (name.startswith(prefix) or name.startswith(tmp_prefix)):
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
        if st.st_mtime < cutoff:
            log(f"reaping retired mirror generation: {entry_real}")
            shutil.rmtree(entry_real, ignore_errors=True)


def refresh_git_mirrors(mirror_root):
    mirror_root = os.path.abspath(os.path.expanduser(mirror_root))
    staging_root = os.path.join(mirror_root, ".staging")
    generations_dir = os.path.join(mirror_root, "generations")
    active_dir = os.path.join(mirror_root, "active")
    for d in (mirror_root, staging_root, generations_dir, active_dir):
        os.makedirs(d, exist_ok=True)
    for d in (mirror_root, generations_dir, active_dir):
        st = os.stat(d)
        os.chmod(d, stat.S_IMODE(st.st_mode) | 0o555)

    repos_raw = os.environ.get("EZGHA_MIRROR_REPOS", DEFAULT_MIRROR_REPOS).strip()
    repos = [r for r in repos_raw.split() if r]
    url_tmpl = os.environ.get("EZGHA_MIRROR_URL_TEMPLATE", "https://github.com/%s.git")
    retention_min = int(os.environ.get("EZGHA_MIRROR_RETENTION_MIN", "240"))
    git_env = {"GIT_TERMINAL_PROMPT": "0"}

    for repo in repos:
        slug = repo.replace("/", "__")
        url = url_tmpl % repo if "%s" in url_tmpl else f"{url_tmpl.rstrip('/')}/{repo}.git"
        staging_dir = os.path.join(staging_root, f"{slug}.git")
        auth_args = git_auth_args(url)

        if not os.path.isdir(os.path.join(staging_dir, "objects")):
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
            run_cmd(clone_cmd, timeout=600, env=git_env)

        run_cmd(["git", "-C", staging_dir, "config", "core.commitGraph", "false"], timeout=30)
        run_cmd(["git", "-C", staging_dir, "config", "gc.auto", "0"], timeout=30)
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
            env=git_env,
        )

        seed_sha = resolve_seed_sha(staging_dir)
        if not seed_sha:
            warn(f"could not resolve SEED_SHA for {repo}; skipping generation publish")
            continue

        active_link = os.path.join(active_dir, slug)
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
                env=git_env,
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

            tmp_link = os.path.join(active_dir, f".{slug}.link.{os.getpid()}")
            if os.path.lexists(tmp_link):
                os.unlink(tmp_link)
            os.symlink(f"../generations/{slug}.{epoch}", tmp_link)
            os.replace(tmp_link, active_link)
            log(f"published mirror {repo} -> {slug}.{epoch} ({seed_sha})")

        reap_old_generations(generations_dir, active_dir, slug, retention_min)


def resolve_docker_env():
    env = {}
    if os.environ.get("DOCKER_HOST", "").strip():
        return env
    if platform.system() == "Darwin":
        plist = os.path.expanduser("~/Library/LaunchAgents/org.jleechanorg.ezgha.plist")
        if os.path.isfile(plist) and shutil.which("plutil"):
            proc = subprocess.run(
                ["plutil", "-extract", "EnvironmentVariables.DOCKER_HOST", "raw", "-o", "-", plist],
                text=True,
                capture_output=True,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                env["DOCKER_HOST"] = proc.stdout.strip()
                return env
        if not os.path.exists("/var/run/docker.sock"):
            colima_sock = os.path.expanduser("~/.colima/default/docker.sock")
            if os.path.exists(colima_sock):
                env["DOCKER_HOST"] = f"unix://{colima_sock}"
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


def refresh_wheelhouse(wheelhouse_path, image):
    wheelhouse_path = os.path.abspath(os.path.expanduser(wheelhouse_path))
    os.makedirs(wheelhouse_path, exist_ok=True)
    chmod_a_rx(wheelhouse_path)

    if not shutil.which("docker"):
        warn("docker CLI not found; skipping wheelhouse refresh")
        return

    docker_env = resolve_docker_env()
    if subprocess.run(["docker", "info"], env={**os.environ, **docker_env}, capture_output=True).returncode != 0:
        warn("docker daemon unreachable; skipping wheelhouse refresh")
        return

    inspect_proc = subprocess.run(
        ["docker", "image", "inspect", "--format", "{{.Id}}", image],
        env={**os.environ, **docker_env},
        text=True,
        capture_output=True,
    )
    if inspect_proc.returncode != 0:
        warn(f"runner image {image} not present locally; skipping wheelhouse refresh")
        return
    image_id = inspect_proc.stdout.strip()

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
        env={**os.environ, **docker_env},
        text=True,
        capture_output=True,
        timeout=60,
    )
    pw_ver = pw_proc.stdout.strip() if pw_proc.returncode == 0 and pw_proc.stdout.strip() else "1.65.2"

    req_files = gather_req_files()
    core_pkgs = DEFAULT_CORE_PACKAGES + [f"playwright=={pw_ver}"]

    hasher = hashlib.sha256()
    hasher.update(f"image={image_id}\n".encode("utf-8"))
    hasher.update(f"playwright={pw_ver}\n".encode("utf-8"))
    hasher.update(("core=" + " ".join(core_pkgs) + "\n").encode("utf-8"))
    req_payload = []
    for idx, rf in enumerate(req_files):
        with open(rf, "rb") as fh:
            raw = fh.read()
        hasher.update(f"file={os.path.basename(rf)}\n".encode("utf-8"))
        hasher.update(raw)
        req_payload.append((f"req_{idx}_{os.path.basename(rf)}", raw.decode("utf-8")))
    manifest_sha = hasher.hexdigest()

    manifest_file = os.path.join(wheelhouse_path, ".manifest.sha256")
    whl_count = sum(1 for fn in os.listdir(wheelhouse_path) if fn.endswith(".whl"))
    if os.path.isfile(manifest_file):
        with open(manifest_file, "r", encoding="utf-8") as fh:
            prev_sha = fh.read().strip()
        if prev_sha == manifest_sha and whl_count >= 10:
            log(f"wheelhouse up-to-date ({whl_count} wheels, manifest {manifest_sha[:12]})")
            return

    payload = json.dumps({"core": core_pkgs, "reqs": req_payload})
    container_script = (
        "import glob, json, os, shutil, subprocess, sys\n"
        "data = json.load(sys.stdin)\n"
        "os.makedirs('/tmp/ezgha-reqs', exist_ok=True)\n"
        "for whl in glob.glob('/opt/baked-wheels/*.whl'):\n"
        "    dst = os.path.join('/wheelhouse', os.path.basename(whl))\n"
        "    if not os.path.exists(dst):\n"
        "        shutil.copy2(whl, dst)\n"
        "cmd = [sys.executable, '-m', 'pip', 'download', '--dest', '/wheelhouse', '--find-links', '/wheelhouse']\n"
        "cmd.extend(data['core'])\n"
        "for name, content in data['reqs']:\n"
        "    p = os.path.join('/tmp/ezgha-reqs', name)\n"
        "    with open(p, 'w', encoding='utf-8') as fh:\n"
        "        fh.write(content)\n"
        "    cmd.extend(['-r', p])\n"
        "subprocess.run(cmd, check=True)\n"
    )
    docker_cmd = ["docker", "run", "--rm", "-i", "-v", f"{wheelhouse_path}:/wheelhouse"]
    if platform.system() == "Linux":
        docker_cmd.extend(["--user", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp"])
    docker_cmd.extend([image, "python3", "-c", container_script])

    log(f"refreshing wheelhouse via {image} (playwright=={pw_ver}, {len(req_files)} req files)")
    run_cmd(docker_cmd, timeout=900, env=docker_env, input_text=payload)

    chmod_a_rx(wheelhouse_path)
    with open(manifest_file, "w", encoding="utf-8") as fh:
        fh.write(f"{manifest_sha}\n")
    os.chmod(manifest_file, 0o644)
    new_count = sum(1 for fn in os.listdir(wheelhouse_path) if fn.endswith(".whl"))
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
    min_free_gb = int(limits_cfg.get("min_free_disk_gb", 30))

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

        required_gb = min_free_gb + 5
        free_gb = get_free_gb([git_mirror_path, wheelhouse_path])
        if free_gb < required_gb:
            warn(
                f"free disk {free_gb:.1f} GiB below safety floor+5 ({required_gb} GiB); skipping cache refresh"
            )
            return 0

        if git_mirror_path and not args.skip_git:
            refresh_git_mirrors(git_mirror_path)

        if wheelhouse_path and not args.skip_wheels:
            refresh_wheelhouse(wheelhouse_path, image)
    finally:
        lock_fh.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
