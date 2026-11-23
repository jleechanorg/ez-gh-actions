#!/usr/bin/env python3
"""Host-side npm _cacache staging, atomic publish, and reference-counted pruning."""

import base64
import binascii
import hashlib
import json
import os
import platform
import re
import subprocess
import time
import uuid

from ezgha_cache_common import (
    atomic_write_text,
    chmod_a_rx,
    inspect_docker_image_id,
    log,
    merge_env,
    oldest_running_runner_start_epoch,
    resolve_docker_env,
    run_cmd,
    validate_configured_host_path,
    warn,
)
from ezgha_git_mirrors import GIT_SANITARY_ENV, find_local_donor, parse_mirror_repos, resolve_seed_sha

CONTAINER_NPM_STAGE_SCRIPT = """\
import glob, json, os, platform, shutil, subprocess, sys
data = json.load(sys.stdin)
stage_root = "/tmp/ezgha-npm-stage"
stage_cc, mount_cc = os.path.join(stage_root, "_cacache"), "/npm-cache/_cacache"
os.makedirs(stage_cc, exist_ok=True)
env = {**os.environ, "NPM_CONFIG_UPDATE_NOTIFIER": "false", "NPM_CONFIG_LOGS_DIR": "/tmp/npm-logs"}
arch = "arm64" if platform.machine().lower() in ("aarch64", "arm64") else "x64"
for nb in sorted(glob.glob(f"/opt/hostedtoolcache/node/*/{arch}/bin")):
    if os.path.isdir(nb):
        env["PATH"] = nb + os.pathsep + env.get("PATH", "")

src_idx, dst_idx = os.path.join(mount_cc, "index-v5"), os.path.join(stage_cc, "index-v5")
if os.path.isdir(src_idx):
    shutil.copytree(src_idx, dst_idx, dirs_exist_ok=True)
    for root, _dirs, files in os.walk(dst_idx):
        os.chmod(root, 0o755)
        for fn in files: os.chmod(os.path.join(root, fn), 0o644)

src_cnt, dst_cnt = os.path.join(mount_cc, "content-v2"), os.path.join(stage_cc, "content-v2")
for root, _dirs, files in (os.walk(src_cnt) if os.path.isdir(src_cnt) else ()):
    rel = os.path.relpath(root, src_cnt)
    tdir = dst_cnt if rel == "." else os.path.join(dst_cnt, rel)
    os.makedirs(tdir, mode=0o755, exist_ok=True)
    for fn in files:
        sp, dp = os.path.join(root, fn), os.path.join(tdir, fn)
        if ".tmp." not in fn and not os.path.islink(sp) and os.path.isfile(sp) and not os.path.lexists(dp):
            os.symlink(sp, dp)

for idx, item in enumerate(data.get("sources", [])):
    wdir = f"/tmp/ezgha-npm-work/{idx}"
    os.makedirs(wdir, exist_ok=True)
    for name, key in (("package.json", "package_json"), ("package-lock.json", "package_lock")):
        with open(os.path.join(wdir, name), "w", encoding="utf-8") as fh: fh.write(item[key])
    subprocess.run(
        ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--prefer-offline", "--cache", stage_root],
        cwd=wdir, env=env, check=True,
    )

def publish_tree(subpath, overwrite):
    sroot, droot = os.path.join(stage_cc, subpath), os.path.join(mount_cc, subpath)
    for root, _dirs, files in (os.walk(sroot) if os.path.isdir(sroot) else ()):
        rel = os.path.relpath(root, sroot)
        tdir = droot if rel == "." else os.path.join(droot, rel)
        os.makedirs(tdir, exist_ok=True)
        for fn in files:
            sp, dp = os.path.join(root, fn), os.path.join(tdir, fn)
            if ".tmp." in fn or os.path.islink(sp) or not os.path.isfile(sp) or (not overwrite and os.path.exists(dp)):
                continue
            tmp_dp = f"{dp}.tmp.{os.getpid()}"
            shutil.copy2(sp, tmp_dp)
            os.chmod(tmp_dp, 0o644)
            os.replace(tmp_dp, dp)

publish_tree("content-v2", overwrite=False)
publish_tree("index-v5", overwrite=True)
"""


def _scan_referenced_blobs(index_dir):
    referenced, walk_error = set(), None
    if not os.path.isdir(index_dir):
        return referenced, True

    def _on_err(exc):
        nonlocal walk_error
        walk_error = walk_error or exc

    for root, _dirs, files in os.walk(index_dir, onerror=_on_err):
        if walk_error is not None:
            break
        for fn in files:
            fp = os.path.join(root, fn)
            if os.path.islink(fp) or not os.path.isfile(fp):
                continue
            try:
                with open(fp, "r", encoding="utf-8", errors="replace") as fh:
                    lines = fh.read().splitlines()
            except OSError as exc:
                warn(f"could not read npm index-v5 file {fp} ({exc}); failing closed without deleting blobs")
                return set(), False
            for line in lines:
                if "\t" not in line:
                    continue
                try:
                    entry = json.loads(line.split("\t", 1)[1])
                except ValueError:
                    continue
                integrity = entry.get("integrity") if isinstance(entry, dict) else ""
                for tok in (integrity.split() if isinstance(integrity, str) else ()):
                    if tok.startswith("sha512-"):
                        try:
                            digest = base64.b64decode(tok[7:], validate=True).hex()
                            if len(digest) >= 6:
                                referenced.add(f"sha512/{digest[:2]}/{digest[2:4]}/{digest[4:]}")
                        except (binascii.Error, ValueError):
                            pass
    if walk_error is not None:
        warn(f"could not scan npm index-v5 ({walk_error}); failing closed without deleting blobs")
        return set(), False
    return referenced, True


def _load_unreferenced(unref_path):
    if not os.path.isfile(unref_path):
        return {}
    try:
        with open(unref_path, "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            return {
                k: float(v) for k, v in loaded.items()
                if isinstance(k, str) and isinstance(v, (int, float)) and not isinstance(v, bool)
            }
        warn(f"ignoring non-object npm unreferenced tracker {unref_path}")
    except (OSError, ValueError) as exc:
        warn(f"ignoring corrupt npm unreferenced tracker {unref_path}: {exc}")
    return {}


def prune_old_npm_cache(npm_cache_path, retention_min=None, oldest_runner_epoch=None):
    """Prune unreferenced npm content-v2 sha512 blobs past retention and container safety window."""
    retention_min = int(os.environ.get("EZGHA_NPM_RETENTION_MIN", "480")) if retention_min is None else int(retention_min)
    cacache_dir = os.path.join(npm_cache_path, "_cacache")
    if not os.path.isdir(cacache_dir):
        return 0
    referenced_blobs, scan_ok = _scan_referenced_blobs(os.path.join(cacache_dir, "index-v5"))
    if not scan_ok:
        return 0

    unref_path = os.path.join(npm_cache_path, ".unreferenced.json")
    unreferenced = _load_unreferenced(unref_path)
    now = time.time()
    cutoff = now - (retention_min * 60.0)
    if oldest_runner_epoch is not None:
        cutoff = min(cutoff, oldest_runner_epoch - 60.0)

    pruned, seen_blobs = 0, set()
    sha512_dir = os.path.join(cacache_dir, "content-v2", "sha512")
    for root, _dirs, files in (os.walk(sha512_dir) if os.path.isdir(sha512_dir) else ()):
        for fn in files:
            fp = os.path.join(root, fn)
            if os.path.islink(fp):
                continue
            if ".tmp." in fn:
                try:
                    if os.stat(fp).st_mtime < cutoff:
                        os.unlink(fp)
                except OSError:
                    pass
                continue
            if not os.path.isfile(fp):
                continue
            rel = "sha512/" + os.path.relpath(fp, sha512_dir).replace(os.sep, "/")
            if rel in referenced_blobs:
                unreferenced.pop(rel, None)
            elif rel not in unreferenced:
                unreferenced[rel] = now
            elif float(unreferenced[rel]) < cutoff:
                try:
                    os.unlink(fp)
                    pruned += 1
                    unreferenced.pop(rel, None)
                    continue
                except OSError as exc:
                    warn(f"could not prune npm blob {fp}: {exc}")
            seen_blobs.add(rel)

    unreferenced = {k: v for k, v in unreferenced.items() if k in seen_blobs}
    atomic_write_text(unref_path, json.dumps(unreferenced, sort_keys=True) + "\n")
    if pruned:
        log(f"pruned {pruned} unreferenced npm blob(s) from {npm_cache_path}")
    return pruned


def _synthesize_or_read_pkg_json(pkg_json_text_or_none, lock_text):
    if pkg_json_text_or_none is not None and pkg_json_text_or_none.strip():
        return pkg_json_text_or_none
    lock_data = json.loads(lock_text)
    packages = lock_data.get("packages") if isinstance(lock_data, dict) else {}
    root = packages.get("", {}) if isinstance(packages, dict) else {}
    if not isinstance(root, dict):
        root = {}
    return json.dumps({
        "name": root.get("name", "ezgha-npm-warm"),
        "version": root.get("version", "1.0.0"),
        "dependencies": root.get("dependencies", {}),
        "devDependencies": root.get("devDependencies", {}),
        "optionalDependencies": root.get("optionalDependencies", {}),
        "peerDependencies": root.get("peerDependencies", {}),
    })


def _git_show_optional(repo_dir, spec):
    proc = subprocess.run(
        ["git", "-C", repo_dir, "show", spec],
        env=merge_env(GIT_SANITARY_ENV), text=True, capture_output=True, timeout=30,
    )
    return proc.stdout if proc.returncode == 0 and proc.stdout.strip() else None


def _read_optional_file(path):
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def gather_npm_lock_sources(git_mirror_path=None):
    """Collect (source_id, package_json_text, package_lock_text) tuples to warm."""
    sources = []
    override = os.environ.get("EZGHA_NPM_LOCKFILES", "").strip()
    if override:
        for raw_p in re.split(r"[\s:]+", override):
            lp = os.path.expanduser(raw_p) if raw_p else ""
            lock_text = _read_optional_file(lp) if lp else None
            if lock_text:
                pkg_text = _read_optional_file(os.path.join(os.path.dirname(lp), "package.json"))
                sources.append((lp, _synthesize_or_read_pkg_json(pkg_text, lock_text), lock_text))
        return sources

    home = os.path.expanduser("~")
    for repo in parse_mirror_repos(os.environ.get("EZGHA_NPM_REPOS", "jleechanorg/worldai_frontend")):
        slug, short = repo.replace("/", "__"), repo.split("/")[-1]
        lock_text, pkg_text, source_id = None, None, None
        for tag, git_dir in (
            ("mirror", os.path.join(git_mirror_path, "active", slug) if git_mirror_path else ""),
            ("donor", find_local_donor(repo) or ""),
        ):
            if git_dir and os.path.isdir(git_dir):
                rev = resolve_seed_sha(git_dir) or "HEAD"
                lock_text = _git_show_optional(git_dir, f"{rev}:package-lock.json")
                if lock_text:
                    pkg_text = _git_show_optional(git_dir, f"{rev}:package.json")
                    source_id = f"{tag}:{repo}"
                    break
        if not lock_text:
            for base in ("projects", "projects_other"):
                proj_dir = os.path.join(home, base, short)
                cand_lock = _read_optional_file(os.path.join(proj_dir, "package-lock.json"))
                if cand_lock:
                    lock_text, source_id = cand_lock, os.path.join(proj_dir, "package-lock.json")
                    pkg_text = _read_optional_file(os.path.join(proj_dir, "package.json"))
                    break
        if lock_text:
            sources.append((source_id, _synthesize_or_read_pkg_json(pkg_text, lock_text), lock_text))
    return sources


def _has_any_sha512_blob(npm_cache_path):
    sha512_dir = os.path.join(npm_cache_path, "_cacache", "content-v2", "sha512")
    return os.path.isdir(sha512_dir) and any(
        ".tmp." not in fn for _r, _d, files in os.walk(sha512_dir) for fn in files
    )


def refresh_npm_cache(npm_cache_path, image, git_mirror_path=None, reap_only=False):
    """Warm and prune the host-side npm _cacache directory via a disposable container."""
    if validate_configured_host_path("npm_cache_path", npm_cache_path) is None:
        raise ValueError(f"npm_cache_path must be an absolute path without leading '~' (got {npm_cache_path!r})")
    npm_cache_path = os.path.abspath(npm_cache_path)
    cacache_dir = os.path.join(npm_cache_path, "_cacache")
    if reap_only:
        if os.path.isdir(cacache_dir):
            prune_old_npm_cache(npm_cache_path, oldest_runner_epoch=oldest_running_runner_start_epoch(resolve_docker_env()))
        return

    os.makedirs(npm_cache_path, exist_ok=True)
    chmod_a_rx(npm_cache_path)
    sources = gather_npm_lock_sources(git_mirror_path=git_mirror_path)
    if not sources:
        if os.path.isdir(cacache_dir):
            prune_old_npm_cache(npm_cache_path, oldest_runner_epoch=oldest_running_runner_start_epoch(resolve_docker_env()))
        log("no npm lockfiles found to warm; skipping npm cache download")
        return

    docker_env = resolve_docker_env()
    image_id = inspect_docker_image_id(image, merge_env(docker_env), "npm cache")
    if not image_id:
        return

    hasher = hashlib.sha256()
    hasher.update(f"image={image_id}\n".encode("utf-8"))
    for sid, pkg_json, lock_json in sources:
        hasher.update(f"source={sid}\npkg={pkg_json}\nlock={lock_json}\n".encode("utf-8"))
    manifest_sha = hasher.hexdigest()

    manifest_file = os.path.join(npm_cache_path, ".manifest.sha256")
    if os.path.isfile(manifest_file) and (_read_optional_file(manifest_file) or "").strip() == manifest_sha and _has_any_sha512_blob(npm_cache_path):
        prune_old_npm_cache(npm_cache_path, oldest_runner_epoch=oldest_running_runner_start_epoch(docker_env))
        log(f"npm cache up-to-date (manifest {manifest_sha[:12]})")
        return

    payload = json.dumps({"sources": [{"source": s, "package_json": p, "package_lock": lck} for s, p, lck in sources]})
    container_name = f"ezgha-npm-warm-{os.getpid()}-{uuid.uuid4().hex[:12]}"
    docker_cmd = ["docker", "run", "--rm", "--name", container_name, "-i", "-v", f"{npm_cache_path}:/npm-cache"]
    if platform.system() == "Linux":
        docker_cmd.extend(["--user", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp"])
    docker_cmd.extend(["--entrypoint", "python3", image, "-c", CONTAINER_NPM_STAGE_SCRIPT])

    log(f"refreshing npm cache via {image} ({len(sources)} lockfile source(s))")
    warm_completed = False
    try:
        run_cmd(docker_cmd, timeout=900, env=docker_env, input_text=payload)
        warm_completed = True
    finally:
        if not warm_completed:
            try:
                rm_proc = subprocess.run(
                    ["docker", "rm", "-f", container_name],
                    env=merge_env(docker_env),
                    text=True,
                    capture_output=True,
                    timeout=30,
                )
                if rm_proc.returncode != 0 and "no such container" not in (rm_proc.stderr or "").lower():
                    warn(f"could not remove npm cache warming container {container_name}: {(rm_proc.stderr or '').strip()}")
            except (OSError, subprocess.TimeoutExpired) as exc:
                warn(f"could not remove npm cache warming container {container_name}: {exc}")
        prune_old_npm_cache(npm_cache_path, oldest_runner_epoch=oldest_running_runner_start_epoch(docker_env))
        chmod_a_rx(npm_cache_path)

    atomic_write_text(manifest_file, f"{manifest_sha}\n")
    log(f"npm cache refreshed (manifest {manifest_sha[:12]})")
