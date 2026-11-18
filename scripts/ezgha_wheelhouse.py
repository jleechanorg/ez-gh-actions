#!/usr/bin/env python3
"""Host-side pip wheelhouse staging, PEP 427 build-tag symlinks, and pruning."""

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import time

from ezgha_cache_common import chmod_a_rx, log, merge_env, resolve_docker_env, run_cmd, warn

BUILD_TAG_MARKER = "999999ezgha"
DEFAULT_CORE_PACKAGES = [
    "pip", "setuptools", "wheel", "pytest", "pytest-xdist", "pytest-cov",
    "pytest-testmon", "coverage", "pydantic", "ruff", "mypy",
]
_PRE_RANKS = {"dev": 0, "a": 1, "alpha": 1, "b": 2, "beta": 2, "c": 3, "rc": 3, "pre": 3, "preview": 3}

CONTAINER_STAGE_SCRIPT = """\
import glob, json, os, shutil, subprocess, sys

data = json.load(sys.stdin)
wheelhouse_dir = os.environ.get("EZGHA_WHEELHOUSE_MOUNT", "/wheelhouse")
baked_dir = os.environ.get("EZGHA_BAKED_WHEELS_DIR", "/opt/baked-wheels")
wheel_stage = os.environ.get("EZGHA_WHEEL_STAGE", "/tmp/ezgha-wheel-stage")
stage_root = os.environ.get("EZGHA_STAGE_ROOT", "/tmp/ezgha-reqs")

os.makedirs(wheel_stage, exist_ok=True)
for src_dir in (wheelhouse_dir, baked_dir):
    for whl in glob.glob(os.path.join(src_dir, "*.whl")):
        if os.path.islink(whl) or not os.path.isfile(whl):
            continue
        dst = os.path.join(wheel_stage, os.path.basename(whl))
        if not os.path.exists(dst):
            try:
                os.link(whl, dst)
            except OSError:
                shutil.copy2(whl, dst)

for rel, content in data.get("staged_files", []):
    dst = os.path.normpath(os.path.join(stage_root, rel))
    if not dst.startswith(stage_root.rstrip("/") + "/"):
        raise ValueError(f"unsafe staged path: {rel}")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(content)

base_cmd = [sys.executable, "-m", "pip", "download", "--dest", wheel_stage, "--find-links", wheel_stage]
subprocess.run(base_cmd + data["core"], check=True)
if data["req_paths"]:
    req_cmd = list(base_cmd)
    for p in data["req_paths"]:
        req_cmd.extend(["-r", p])
    subprocess.run(req_cmd, check=True)

for whl in glob.glob(os.path.join(wheel_stage, "*.whl")):
    if os.path.islink(whl) or not os.path.isfile(whl):
        continue
    dst = os.path.join(wheelhouse_dir, os.path.basename(whl))
    if not os.path.exists(dst):
        dst_tmp = f"{dst}.tmp.{os.getpid()}"
        shutil.copy2(whl, dst_tmp)
        os.replace(dst_tmp, dst)
"""


def parse_wheel_filename(fn):
    """Parse PEP 427 wheel filename into (dist, version, build, py, abi, plat) or None."""
    if not fn.endswith(".whl") or f"-{BUILD_TAG_MARKER}-" in fn:
        return None
    parts = fn[:-4].split("-")
    if len(parts) < 5:
        return None
    py_tag, abi_tag, plat_tag = parts[-3], parts[-2], parts[-1]
    head = parts[:-3]
    if len(head) == 2:
        dist_key, version, build_or_none = head[0], head[1], None
    elif len(head) >= 3 and head[-1][:1].isdigit() and "." not in head[-1]:
        dist_key, version, build_or_none = "-".join(head[:-2]), head[-2], head[-1]
    else:
        dist_key, version, build_or_none = "-".join(head[:-1]), head[-1], None
    if not dist_key or not version:
        return None
    return (dist_key, version, build_or_none, py_tag, abi_tag, plat_tag)


def version_key(version):
    """Deterministic natural numeric/string version ordering tuple (stdlib-only)."""
    key = []
    for tok in re.findall(r"[0-9]+|[a-z]+", version.lower()):
        if tok.isdigit():
            key.append((2, int(tok), ""))
        elif tok in ("post", "rev", "r"):
            key.append((3, 0, tok))
        elif tok in _PRE_RANKS:
            key.append((0, _PRE_RANKS[tok], ""))
        else:
            key.append((0, 4, tok))
    key.append((1, 0, ""))
    return tuple(key)


def _sync_aliases(wheelhouse_path, desired_aliases):
    for fn in list(os.listdir(wheelhouse_path)):
        full = os.path.join(wheelhouse_path, fn)
        if not os.path.islink(full):
            continue
        if f"-{BUILD_TAG_MARKER}-" in fn:
            expected = desired_aliases.get(fn)
            try:
                cur_target = os.readlink(full)
            except OSError:
                cur_target = None
            if not expected or cur_target != expected or not os.path.exists(full):
                try:
                    os.unlink(full)
                except OSError:
                    pass
        elif not os.path.exists(full):
            try:
                os.unlink(full)
            except OSError:
                pass

    for alias, target_fn in sorted(desired_aliases.items()):
        alias_path = os.path.join(wheelhouse_path, alias)
        if not os.path.lexists(alias_path):
            os.symlink(target_fn, alias_path)


def _build_key(build):
    if not build:
        return (0, 0, "")
    m = re.match(r"^([0-9]+)(.*)$", build)
    return (1, int(m.group(1)), m.group(2)) if m else (1, 0, build)


def _scan_real_wheels(wheelhouse_path):
    entries = []
    for fn in os.listdir(wheelhouse_path):
        full = os.path.join(wheelhouse_path, fn)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        parsed = parse_wheel_filename(fn)
        if parsed is None:
            continue
        dist_key, version, build, py_tag, abi_tag, plat_tag = parsed
        try:
            mtime_ns = os.stat(full).st_mtime_ns
        except OSError:
            continue
        entries.append(((version_key(version), _build_key(build), mtime_ns, fn), dist_key, version, py_tag, abi_tag, plat_tag, fn))
    return entries


def sync_wheelhouse_build_tag_symlinks(wheelhouse_path, clear_only=False):
    """Ensure relative PEP 427 -999999ezgha- symlinks exist for retained wheels."""
    if not os.path.isdir(wheelhouse_path):
        return
    if clear_only:
        _sync_aliases(wheelhouse_path, {})
        return
    entries = _scan_real_wheels(wheelhouse_path)
    entries.sort(key=lambda it: it[0])
    desired = {
        f"{d}-{v}-{BUILD_TAG_MARKER}-{py}-{abi}-{pl}.whl": fn
        for _skey, d, v, py, abi, pl, fn in entries
    }
    _sync_aliases(wheelhouse_path, desired)


def prune_old_wheels(wheelhouse_path, keep_versions=None):
    """Keep newest `keep_versions` distinct versions per (dist, py, abi, plat) group and sync symlinks."""
    if not os.path.isdir(wheelhouse_path):
        return 0
    if keep_versions is None:
        raw_keep = os.environ.get("EZGHA_WHEELHOUSE_KEEP_VERSIONS", "2").strip()
        try:
            keep_versions = max(1, int(raw_keep))
        except ValueError:
            warn(f"invalid EZGHA_WHEELHOUSE_KEEP_VERSIONS={raw_keep!r}; defaulting to 2")
            keep_versions = 2
    else:
        keep_versions = max(1, int(keep_versions))

    groups = {}
    for item in _scan_real_wheels(wheelhouse_path):
        _skey, dist_key, _version, py_tag, abi_tag, plat_tag, _fn = item
        gkey = (dist_key.lower().replace("-", "_"), py_tag, abi_tag, plat_tag)
        groups.setdefault(gkey, []).append(item)

    pruned = 0
    desired_aliases = {}
    for _gkey, items in sorted(groups.items()):
        items.sort(key=lambda it: it[0])
        ordered_versions = []
        seen_versions = set()
        for item in items:
            v = item[2]
            if v not in seen_versions:
                seen_versions.add(v)
                ordered_versions.append(v)
        kept_versions = set(ordered_versions[-keep_versions:])
        for _skey, d, v, py, abi, pl, fn in items:
            if v not in kept_versions:
                try:
                    os.unlink(os.path.join(wheelhouse_path, fn))
                    pruned += 1
                except OSError as exc:
                    warn(f"could not prune old wheel {fn}: {exc}")
            else:
                desired_aliases[f"{d}-{v}-{BUILD_TAG_MARKER}-{py}-{abi}-{pl}.whl"] = fn

    _sync_aliases(wheelhouse_path, desired_aliases)
    if pruned:
        log(f"pruned {pruned} old wheel(s) from {wheelhouse_path} (keep_versions={keep_versions})")
    return pruned


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


def _iter_logical_req_lines(path):
    with open(path, "r", encoding="utf-8") as fh:
        buf = ""
        for raw_line in fh:
            stripped = raw_line.rstrip("\r\n")
            if stripped.endswith("\\"):
                buf += stripped[:-1] + " "
                continue
            yield buf + stripped
            buf = ""
        if buf:
            yield buf


def collect_req_closure(req_files):
    """Resolve top-level requirement files and recursive -r/-c local includes."""
    entries, all_files = [], set()
    for rf in req_files:
        rf_real = os.path.realpath(rf)
        closure, queue = set(), [rf_real]
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
                        tok, ref = tokens[i], None
                        if tok in ("-r", "--requirement", "-c", "--constraint") and i + 1 < len(tokens):
                            ref, i = tokens[i + 1], i + 2
                        elif tok.startswith(("--requirement=", "--constraint=")):
                            ref, i = tok.split("=", 1)[1], i + 1
                        elif (tok.startswith("-r") or tok.startswith("-c")) and len(tok) > 2:
                            ref, i = tok[2:], i + 1
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


def _count_real_wheels(wheelhouse_path):
    return len(_scan_real_wheels(wheelhouse_path))


def refresh_wheelhouse(wheelhouse_path, image, reap_only=False):
    if not wheelhouse_path or wheelhouse_path.startswith("~") or not os.path.isabs(wheelhouse_path):
        raise ValueError(f"wheelhouse_path must be an absolute path without leading '~' (got {wheelhouse_path!r})")
    wheelhouse_path = os.path.abspath(wheelhouse_path)
    if reap_only:
        if os.path.isdir(wheelhouse_path):
            prune_old_wheels(wheelhouse_path)
        return

    os.makedirs(wheelhouse_path, exist_ok=True)
    chmod_a_rx(wheelhouse_path)
    if not shutil.which("docker"):
        warn("docker CLI not found; skipping wheelhouse refresh")
        return

    docker_env = resolve_docker_env()
    docker_proc_env = merge_env(docker_env)
    try:
        info_proc = subprocess.run(["docker", "info"], env=docker_proc_env, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        warn("docker info timed out after 30s; skipping wheelhouse refresh")
        return
    if info_proc.returncode != 0:
        warn("docker daemon unreachable; skipping wheelhouse refresh")
        return

    try:
        inspect_proc = subprocess.run(
            ["docker", "image", "inspect", "--format", "{{.Id}}", image],
            env=docker_proc_env, text=True, capture_output=True, timeout=30,
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
            ["docker", "run", "--rm", "--entrypoint", "bash", image, "-lc", "cat /ms-playwright/PLAYWRIGHT_VERSION 2>/dev/null || echo 1.65.2"],
            env=docker_proc_env, text=True, capture_output=True, timeout=60,
        )
        pw_ver = pw_proc.stdout.strip() if pw_proc.returncode == 0 and pw_proc.stdout.strip() else "1.65.2"
    except subprocess.TimeoutExpired:
        warn(f"timed out querying PLAYWRIGHT_VERSION from {image}; skipping wheelhouse refresh")
        return

    req_files = gather_req_files()
    req_entries, all_req_files = collect_req_closure(req_files)
    core_pkgs = DEFAULT_CORE_PACKAGES + [f"playwright=={pw_ver}"]
    date_bucket = os.environ.get("EZGHA_WHEELHOUSE_DATE_BUCKET") or time.strftime("%Y-%m-%d", time.gmtime())

    hasher = hashlib.sha256()
    for kv in (f"image={image_id}\n", f"playwright={pw_ver}\n", f"date_bucket={date_bucket}\n", f"core={' '.join(core_pkgs)}\n"):
        hasher.update(kv.encode("utf-8"))
    for fp in all_req_files:
        with open(fp, "rb") as fh:
            hasher.update(f"file={fp}\n".encode("utf-8"))
            hasher.update(fh.read())
    manifest_sha = hasher.hexdigest()

    manifest_file = os.path.join(wheelhouse_path, ".manifest.sha256")
    if os.path.isfile(manifest_file):
        with open(manifest_file, "r", encoding="utf-8") as fh:
            prev_sha = fh.read().strip()
        if prev_sha == manifest_sha and _count_real_wheels(wheelhouse_path) >= 10:
            prune_old_wheels(wheelhouse_path)
            log(f"wheelhouse up-to-date ({_count_real_wheels(wheelhouse_path)} wheels, manifest {manifest_sha[:12]})")
            return

    staged_files, req_container_paths = [], []
    for idx, (req_real, common_dir, closure_files) in enumerate(req_entries):
        for fp in closure_files:
            rel_fp = os.path.relpath(fp, common_dir).replace(os.sep, "/")
            with open(fp, "r", encoding="utf-8", errors="replace") as fh:
                staged_files.append((f"{idx}/{rel_fp}", fh.read()))
        req_container_paths.append(f"/tmp/ezgha-reqs/{idx}/{os.path.relpath(req_real, common_dir).replace(os.sep, '/')}")

    payload = json.dumps({"core": core_pkgs, "staged_files": staged_files, "req_paths": req_container_paths})
    docker_cmd = ["docker", "run", "--rm", "-i", "-v", f"{wheelhouse_path}:/wheelhouse"]
    if platform.system() == "Linux":
        docker_cmd.extend(["--user", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp"])
    docker_cmd.extend([image, "python3", "-c", CONTAINER_STAGE_SCRIPT])

    log(f"refreshing wheelhouse via {image} (playwright=={pw_ver}, {len(req_files)} req files)")
    try:
        run_cmd(docker_cmd, timeout=900, env=docker_env, input_text=payload)
    finally:
        prune_old_wheels(wheelhouse_path)
        chmod_a_rx(wheelhouse_path)

    manifest_tmp = f"{manifest_file}.tmp.{os.getpid()}"
    with open(manifest_tmp, "w", encoding="utf-8") as fh:
        fh.write(f"{manifest_sha}\n")
    os.chmod(manifest_tmp, 0o644)
    os.replace(manifest_tmp, manifest_file)
    log(f"wheelhouse refreshed ({_count_real_wheels(wheelhouse_path)} wheels, manifest {manifest_sha[:12]})")
