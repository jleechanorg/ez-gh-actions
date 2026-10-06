#!/usr/bin/python3
"""Best-effort cleanup for this image's single-job, ephemeral Actions runner.

The production anchor is deliberately fixed; environment variables can only
identify a job within it, never choose an arbitrary cleanup root. Run only from
ACTIONS_RUNNER_HOOK_JOB_COMPLETED, after action post steps (including cache saves).
"""
import contextlib
import json
import os
from pathlib import Path
import re
import stat

WORK_ROOT = Path("/home/runner/_work")
MOUNTINFO = Path("/proc/self/mountinfo")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
CACHE_NAMES = ("_actions", "_temp", "_tool")
# The hook itself is still a runner step. Its environment-file processing and
# webhook context must survive until Runner.Worker has finished the hook.
TEMP_KEEP = {"_runner_file_commands", "_github_workflow"}


@contextlib.contextmanager
def open_directory(path):
    """Open every component without following a symlink, retaining the final fd."""
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in path.parts[1:]:
            next_fd = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


def mount_points():
    """Include bind mounts even when st_dev is the same as their parent."""
    mounts = {}
    for line in MOUNTINFO.read_text().splitlines():
        before, after = line.split(" - ", 1)
        fields, filesystem = before.split(), after.split()
        if len(fields) < 6 or len(filesystem) < 3:
            raise ValueError("invalid mountinfo")
        path = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), fields[4])
        if not path.startswith("/"):
            raise ValueError("invalid mount point")
        mount_id_value = int(fields[0])
        if mount_id_value <= 0 or mount_id_value in mounts:
            raise ValueError("invalid mount identity")
        mounts[mount_id_value] = (Path(path), filesystem[0], fields[3])
    if not any(path == Path("/") for path, _, _ in mounts.values()):
        raise ValueError("missing root mount")
    return mounts


def mount_id(fd):
    """Read the kernel mount identity of an open descriptor, including binds.

    Paths and st_dev alone are insufficient: a same-device bind mount can move
    with an ancestor after mountinfo was sampled. fdinfo follows the opened
    object, so a renamed or newly mounted descendant cannot escape this check.
    """
    for line in Path(f"/proc/self/fdinfo/{fd}").read_text().splitlines():
        if line.startswith("mnt_id:"):
            value = int(line.split(":", 1)[1])
            if value > 0:
                return value
    raise ValueError("missing descriptor mount identity")


def job_workspace(environ):
    """Refuse nonstandard/ambiguous layouts instead of guessing ownership."""
    repository = environ.get("GITHUB_REPOSITORY", "").split("/")
    if len(repository) != 2 or any(
        not re.fullmatch(r"[A-Za-z0-9_.-]+", part) or part in (".", "..")
        for part in repository
    ):
        raise ValueError("invalid repository")
    repo = repository[1]
    if repo in CACHE_NAMES or repo == "_PipelineMapping":
        raise ValueError("reserved directory")
    workspace = WORK_ROOT / repo / repo
    if environ.get("GITHUB_WORKSPACE") != str(workspace):
        raise ValueError("nonstandard workspace")
    if environ.get("RUNNER_TEMP") != str(WORK_ROOT / "_temp"):
        raise ValueError("nonstandard temporary directory")
    if not environ.get("GITHUB_JOB") or any(
        not re.fullmatch(r"[1-9][0-9]*", environ.get(key, ""))
        for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")
    ):
        raise ValueError("missing job identity")
    with open_directory(WORK_ROOT.parent) as home_fd:
        # Nonblocking open lets us reject a FIFO before it can stall cleanup.
        fd = os.open(
            ".runner", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
            dir_fd=home_fd,
        )
        with os.fdopen(fd) as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise ValueError("unknown runner configuration owner")
            settings = json.loads(stream.read(65537))
    # actions/runner writes PascalCase keys (RunnerSettings DataMembers) and
    # the live file stores Ephemeral as the string "True"; accept both shapes.
    if isinstance(settings, dict):
        settings = {str(key).lower(): value for key, value in settings.items()}
    ephemeral = settings.get("ephemeral") if isinstance(settings, dict) else None
    if not isinstance(settings, dict) or not (
        (ephemeral is True or (isinstance(ephemeral, str) and ephemeral.lower() == "true"))
        and settings.get("workfolder") == "_work"
        and settings.get("agentname")
        and settings["agentname"] == environ.get("RUNNER_NAME")
    ):
        raise ValueError("not this ephemeral runner")
    return workspace


def empty_directory(fd, expected_mount, keep=()):
    """Delete entries relative to pinned directories, never following symlinks.

    Do not chmod/chown, follow a mount into persistent data, or remove the target
    root (the cache roots can themselves be tmpfs mount points). A failed entry
    is preserved and reported; the runner must still be able to complete.
    """
    complete = True
    device = os.fstat(fd).st_dev
    with os.scandir(fd) as entries:
        for entry in entries:
            if entry.name in keep:
                continue
            try:
                metadata = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
                if stat.S_ISDIR(metadata.st_mode):
                    child_fd = os.open(entry.name, DIR_FLAGS, dir_fd=fd)
                    try:
                        opened = os.fstat(child_fd)
                        if (
                            (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)
                            or opened.st_dev != device
                            or mount_id(child_fd) != expected_mount
                        ):
                            complete = False
                            continue
                        child_complete = empty_directory(child_fd, expected_mount)
                    finally:
                        os.close(child_fd)
                    if child_complete:
                        os.rmdir(entry.name, dir_fd=fd)
                    else:
                        complete = False
                else:
                    # Unlink symlinks themselves; never traverse their targets.
                    os.unlink(entry.name, dir_fd=fd)
            except FileNotFoundError:
                continue
            except (OSError, ValueError):
                complete = False
    return complete


def clean_target(path, mounts, work_mount, *, cache=False, keep=()):
    try:
        with open_directory(path) as fd:
            target_mount = mount_id(fd)
            # Work-root bind mounts are supported. Below that root, only the
            # exact tmpfs cache mounts already identified in mountinfo may be
            # emptied, and only when root is "/" (a fresh tmpfs, not a bind of a
            # shared tmpfs subtree). Unknown/replaced mounts fail closed,
            # including mounts arriving between the snapshot and this open.
            if target_mount != work_mount and not (
                cache and mounts.get(target_mount) == (path, "tmpfs", "/")
            ):
                return False
            return empty_directory(fd, target_mount, keep)
    except FileNotFoundError:
        return True
    except (OSError, ValueError):
        return False


def main():
    try:
        workspace = job_workspace(os.environ)
        # Pin the known work-root mount before sampling mountinfo. This avoids
        # trusting a new mount merely because it was first observed at a target.
        with open_directory(WORK_ROOT) as work_fd:
            work_mount = mount_id(work_fd)
            mounts = mount_points()
            if work_mount not in mounts:
                raise ValueError("unknown workspace mount")
        # Validate all default workspace ancestors before performing deletion.
        with open_directory(workspace):
            pass
    except (OSError, ValueError):
        print("ezgha post-job cleanup: skipped (workspace ownership or layout unverified)")
        return 0

    try:
        # GITHUB_WORKSPACE is the inner <repo>/<repo> checkout. The runner's
        # pipeline directory also owns custom checkouts and sibling artifacts.
        complete = clean_target(workspace.parent, mounts, work_mount)
        for name in CACHE_NAMES:
            path = WORK_ROOT / name
            if name == "_tool" and os.environ.get("RUNNER_TOOL_CACHE") != str(path):
                complete = False
                continue
            cleaned = clean_target(
                path, mounts, work_mount, cache=True,
                keep=TEMP_KEEP if name == "_temp" else (),
            )
            complete = cleaned and complete
        status = "completed" if complete else "partial (protected or inaccessible entries retained)"
        print(f"ezgha post-job cleanup: {status}")
    except (OSError, RecursionError):
        print("ezgha post-job cleanup: partial (filesystem traversal interrupted)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
