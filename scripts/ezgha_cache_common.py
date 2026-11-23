#!/usr/bin/env python3
"""Shared stdlib helpers for ezgha runner cache warming."""

from datetime import datetime, timezone
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time


def log(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[cache-warm {ts}] {msg}", flush=True)


def warn(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[cache-warm {ts}] WARNING: {msg}", file=sys.stderr, flush=True)


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


def resolve_docker_env():
    """Select the Docker endpoint matching ezgha's service configuration."""
    env = {}
    sysname = platform.system()
    if sysname == "Darwin":
        plist = os.path.expanduser("~/Library/LaunchAgents/org.jleechanorg.ezgha.plist")
        if os.path.isfile(plist) and shutil.which("plutil"):
            try:
                proc = subprocess.run(
                    [
                        "plutil",
                        "-extract",
                        "EnvironmentVariables.DOCKER_HOST",
                        "raw",
                        "-o",
                        "-",
                        plist,
                    ],
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
        if os.environ.get("DOCKER_HOST", "").strip():
            env["DOCKER_CONTEXT"] = None
            return env
        if not os.path.exists("/var/run/docker.sock"):
            colima_sock = os.path.expanduser("~/.colima/default/docker.sock")
            if os.path.exists(colima_sock):
                env["DOCKER_HOST"] = f"unix://{colima_sock}"
                env["DOCKER_CONTEXT"] = None
        return env

    if os.environ.get("DOCKER_HOST", "").strip():
        env["DOCKER_CONTEXT"] = None
        return env

    if sysname == "Linux":
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
    """Return earliest StartedAt epoch of running ezgha containers, None if none, or 0.0 on error."""
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


def validate_configured_host_path(field, raw_val):
    """Match Rust Config::validate(): explicit host paths must be non-empty and absolute without '~'."""
    if raw_val is None:
        return None
    if not isinstance(raw_val, str) or not raw_val.strip():
        raise ValueError(f"{field} must not be empty when configured")
    if raw_val != raw_val.strip() or raw_val.startswith("~") or not os.path.isabs(raw_val):
        raise ValueError(f"{field} must be an absolute path without leading '~' (got {raw_val!r})")
    return raw_val


def atomic_write_text(path, text, mode=0o644):
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(tmp_path, mode)
    os.replace(tmp_path, path)


def inspect_docker_image_id(image, docker_proc_env, stage_label):
    if not shutil.which("docker"):
        warn(f"docker CLI not found; skipping {stage_label} refresh")
        return None
    try:
        info_proc = subprocess.run(["docker", "info"], env=docker_proc_env, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        warn(f"docker info timed out after 30s; skipping {stage_label} refresh")
        return None
    if info_proc.returncode != 0:
        warn(f"docker daemon unreachable; skipping {stage_label} refresh")
        return None
    try:
        inspect_proc = subprocess.run(
            ["docker", "image", "inspect", "--format", "{{.Id}}", image],
            env=docker_proc_env, text=True, capture_output=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        warn(f"docker image inspect timed out after 30s for {image}; skipping {stage_label} refresh")
        return None
    if inspect_proc.returncode != 0:
        warn(f"runner image {image} not present locally; skipping {stage_label} refresh")
        return None
    return inspect_proc.stdout.strip()
