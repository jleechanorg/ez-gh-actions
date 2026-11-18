#!/usr/bin/env python3
"""CLI entrypoint for warming ezgha git mirrors and pip wheelhouses."""

import argparse
import fcntl
import os
import platform
import sys
import tomllib

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from ezgha_cache_common import log, resolve_docker_env, warn  # noqa: E402
from ezgha_git_mirrors import refresh_git_mirrors  # noqa: E402
from ezgha_wheelhouse import refresh_wheelhouse  # noqa: E402

__all__ = [
    "get_free_gb",
    "load_config",
    "main",
    "resolve_config_path",
    "resolve_docker_env",
    "validate_configured_host_path",
]


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


def validate_configured_host_path(field, raw_val):
    """Match Rust Config::validate(): explicit host paths must be non-empty and absolute without '~'."""
    if raw_val is None:
        return None
    if not isinstance(raw_val, str) or not raw_val.strip():
        raise ValueError(f"{field} must not be empty when configured")
    if raw_val != raw_val.strip() or raw_val.startswith("~") or not os.path.isabs(raw_val):
        raise ValueError(
            f"{field} must be an absolute path without leading '~' (got {raw_val!r})"
        )
    return raw_val


def load_config(path):
    with open(path, "rb") as fh:
        cfg = tomllib.load(fh)
    runner_cfg = cfg.get("runner", {})
    if not isinstance(runner_cfg, dict):
        raise ValueError("[runner] must be a TOML table")
    limits_cfg = cfg.get("limits", {})
    if not isinstance(limits_cfg, dict):
        raise ValueError("[limits] must be a TOML table")

    git_mirror_path = validate_configured_host_path(
        "runner.git_mirror_host_path", runner_cfg.get("git_mirror_host_path")
    )
    wheelhouse_path = validate_configured_host_path(
        "runner.wheelhouse_host_path", runner_cfg.get("wheelhouse_host_path")
    )
    raw_image = runner_cfg.get("image")
    image = str(raw_image).strip() if raw_image is not None else ""
    if not image:
        image = "ezgha-runner:latest"

    raw_min_free = limits_cfg.get("min_free_disk_gb", 10)
    if isinstance(raw_min_free, bool) or not isinstance(raw_min_free, (int, float)):
        raise ValueError(f"limits.min_free_disk_gb must be numeric (got {raw_min_free!r})")
    min_free_gb = float(raw_min_free)
    if min_free_gb < 1:
        raise ValueError(f"limits.min_free_disk_gb must be at least 1 (got {raw_min_free!r})")

    return {
        "git_mirror_host_path": git_mirror_path,
        "wheelhouse_host_path": wheelhouse_path,
        "image": image,
        "min_free_disk_gb": min_free_gb,
    }


def nearest_existing_dir(path):
    cur = os.path.abspath(path)
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


def main(argv=None):
    parser = argparse.ArgumentParser(description="Refresh ezgha runner git mirrors and wheelhouse.")
    parser.add_argument("--config", help="Path to ezgha config.toml")
    parser.add_argument("--skip-git", action="store_true", help="Skip git mirror refresh")
    parser.add_argument("--skip-wheels", action="store_true", help="Skip wheelhouse refresh")
    args = parser.parse_args(argv)

    cfg_path, explicit = resolve_config_path(args.config)
    if not os.path.isfile(cfg_path):
        if explicit:
            warn(f"config file not found: {cfg_path}")
            return 1
        log(f"config file not found ({cfg_path}); nothing to warm")
        return 0

    try:
        parsed_cfg = load_config(cfg_path)
    except (tomllib.TOMLDecodeError, ValueError, TypeError, OSError) as exc:
        warn(f"invalid config {cfg_path}: {exc}")
        return 1

    git_mirror_path = parsed_cfg["git_mirror_host_path"]
    wheelhouse_path = parsed_cfg["wheelhouse_host_path"]
    image = parsed_cfg["image"]
    min_free_gb = parsed_cfg["min_free_disk_gb"]

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

        buffer_gb = float(os.environ.get("EZGHA_CACHE_MIN_FREE_BUFFER_GB", "5.0"))
        required_gb = min_free_gb + buffer_gb

        stage_errors = []
        if git_mirror_path and not args.skip_git:
            git_free_gb = get_free_gb([git_mirror_path])
            reap_only_git = git_free_gb < required_gb
            if reap_only_git:
                warn(
                    f"free disk {git_free_gb:.1f} GiB below safety floor+{buffer_gb:g} ({required_gb:g} GiB); "
                    "skipping new git mirror clones and reaping retired generations only"
                )
            try:
                refresh_git_mirrors(git_mirror_path, reap_only=reap_only_git)
            except Exception as exc:
                warn(f"git mirror {'reap-only ' if reap_only_git else ''}stage encountered error: {exc}")
                stage_errors.append("git")

        if wheelhouse_path and not args.skip_wheels:
            wheel_free_gb = get_free_gb([wheelhouse_path])
            reap_only_wheels = wheel_free_gb < required_gb
            if reap_only_wheels:
                warn(
                    f"free disk {wheel_free_gb:.1f} GiB below safety floor+{buffer_gb:g} ({required_gb:g} GiB); "
                    "skipping wheelhouse downloads and pruning old wheels only"
                )
            try:
                refresh_wheelhouse(wheelhouse_path, image, reap_only=reap_only_wheels)
            except Exception as exc:
                warn(f"wheelhouse {'reap-only ' if reap_only_wheels else ''}stage encountered error: {exc}")
                stage_errors.append("wheelhouse")

        if stage_errors:
            return 1
    finally:
        lock_fh.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
