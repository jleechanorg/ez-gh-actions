#!/usr/bin/env python3
"""Shared stdlib helpers for ezgha runner cache warming."""

import os
import platform
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
