#!/usr/bin/env python3
"""Lease-owned scratch eligibility audit only. Production deletion is unavailable.

A trusted same-UID controller protocol, not a sandbox against malicious same-UID
processes. An empty cgroup snapshot is diagnostic only, not proof of permanently closed
containment. An idle process or empty lsof snapshot is never terminal evidence.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid

ID = re.compile(r'^[0-9a-f]{32}$')
REPO = re.compile(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
CGROUP_ROOT = Path('/sys/fs/cgroup')


def _private_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('controller directory must be real, owner-only and owned by this user')
    return info


def initialize(root):
    root = Path(root).absolute()
    if root.is_symlink():
        raise ValueError('symlink controller root refused')
    root.mkdir(mode=0o700, parents=False, exist_ok=True)
    _private_directory(root)
    for name in ('trees', 'locks', 'owners', 'quarantine'):
        path = root / name
        path.mkdir(mode=0o700, exist_ok=True)
        _private_directory(path)


@contextmanager
def lock_lease(root, identifier, *, create=False):
    if not ID.fullmatch(identifier):
        raise ValueError('invalid lease ID')
    _private_directory(root)
    _private_directory(root / 'locks')
    fd = os.open(root / 'locks' / (identifier + '.lock'), os.O_RDWR | (os.O_CREAT if create else 0) | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_nlink != 1:
            raise ValueError('unsafe lease lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        named = (root / 'locks' / (identifier + '.lock')).lstat()
        if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError('lock identity changed')
        # Never unlink lock files: recreating a lock would split ownership.
        yield fd
    finally:
        os.close(fd)


def _scope_info(path):
    path = Path(path)
    if '..' in path.parts:
        raise ValueError('noncanonical cgroup path refused')
    if path == CGROUP_ROOT or not path.is_relative_to(CGROUP_ROOT):
        raise ValueError('dedicated cgroup-v2 scope required')
    for entry in [path, *path.parents]:
        if not entry.is_relative_to(CGROUP_ROOT):
            break
        info = entry.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('cgroup containment must be root-owned and non-delegated')
        procs = (entry / 'cgroup.procs').lstat()
        if not stat.S_ISREG(procs.st_mode) or procs.st_uid != 0 or procs.st_mode & 0o022:
            raise ValueError('writable cgroup migration path refused')
    return path.stat()


def current_scope():
    if os.geteuid() == 0:
        raise ValueError('scratch workloads must run as a non-root user')
    status = Path('/proc/self/status').read_text()
    caps = next(line.split()[1] for line in status.splitlines() if line.startswith('CapEff:'))
    if int(caps, 16):
        raise ValueError('privileged scratch workload refused')
    rows = Path('/proc/self/cgroup').read_text().splitlines()
    unified = [row[3:] for row in rows if row.startswith('0::')]
    if len(unified) != 1 or unified[0] == '/':
        raise ValueError('dedicated host-visible unified cgroup required')
    path = CGROUP_ROOT / unified[0].lstrip('/')
    info = _scope_info(path)
    return {'path': str(path), 'device': info.st_dev, 'inode': info.st_ino}


def scope_empty(scope):
    path = Path(scope['path'])
    info = _scope_info(path)
    if (info.st_dev, info.st_ino) != (scope['device'], scope['inode']):
        return False
    fields = dict(line.split() for line in (path / 'cgroup.events').read_text().splitlines())
    return fields.get('populated') == '0'


class Lease:
    def __init__(self, root, identifier, scope):
        self.root, self.identifier, self.scope = root, identifier, scope
        self.path = root / 'trees' / identifier

    @classmethod
    def create(cls, root, repository, job_id, *, scope_probe=current_scope):
        if not REPO.fullmatch(repository) or type(job_id) is not int or job_id <= 0:
            raise ValueError('exact repository and positive Actions job ID required')
        root = Path(root).absolute()
        initialize(root)
        lease = cls(root, uuid.uuid4().hex, scope_probe())
        lease.repository, lease.job_id = repository, job_id
        return lease

    def __enter__(self):
        self.claim = lock_lease(self.root, self.identifier, create=True)
        self.claim.__enter__()
        try:
            self.path.mkdir(mode=0o700)  # UUID paths are never reused.
            info = self.path.stat()
            self.marker = {'version': 1, 'disposable': True, 'lease_id': self.identifier,
                'repository': self.repository, 'job_id': self.job_id,
                'device': info.st_dev, 'inode': info.st_ino, 'scope': self.scope}
            marker = self.root / 'owners' / (self.identifier + '.json')
            fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as out:
                json.dump(self.marker, out, sort_keys=True)
                out.flush()
                os.fsync(out.fileno())
            return self
        except BaseException:
            self.claim.__exit__(*sys.exc_info())
            raise

    def __exit__(self, *exc):
        self.claim.__exit__(*exc)


def terminal_job(repository, job_id):
    if not REPO.fullmatch(repository) or type(job_id) is not int or job_id <= 0:
        return False
    result = subprocess.run(['gh', 'api', f'repos/{repository}/actions/jobs/{job_id}'],
                            capture_output=True, timeout=20, check=True)
    job = json.loads(result.stdout)
    return type(job.get('id')) is int and job['id'] == job_id and job.get('status') == 'completed'


def lsof_unused(path):
    result = subprocess.run(['lsof', '-nP', '-t', '+D', str(path)], capture_output=True, timeout=20)
    # lsof uses 1 for no matches, but also for errors. Any output/diagnostic
    # or other exit status is unknown/busy, never permission to delete.
    return result.returncode == 1 and not result.stdout and not result.stderr


def _marker(root, identifier):
    path = root / 'owners' / (identifier + '.json')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_size > 8192:
            raise ValueError('unsafe owner marker')
        marker = json.load(source)
    if not isinstance(marker, dict):
        raise ValueError('owner marker must be an object')
    if marker.get('version') != 1 or marker.get('disposable') is not True or marker.get('lease_id') != identifier:
        raise ValueError('not an explicitly disposable lease')
    return marker


def reclaim(root, *, low_bytes, free_bytes=None, terminal=terminal_job,
            unused=lsof_unused, contained=scope_empty, apply=False):
    if apply:
        raise ValueError('deletion unavailable: closed containment and mount-safe controller integration required')
    root = Path(root).absolute()
    for path in (root, *(root / name for name in ('trees', 'locks', 'owners', 'quarantine'))):
        _private_directory(path)
    if low_bytes <= 0:
        raise ValueError('positive pressure threshold required')
    free_bytes = free_bytes or (lambda: shutil.disk_usage(root).free)
    if free_bytes() >= low_bytes:
        return []
    candidates = []
    for path in sorted((root / 'trees').iterdir()):
        if free_bytes() >= low_bytes:
            break
        identifier = path.name
        if not ID.fullmatch(identifier):
            continue
        try:
            with lock_lease(root, identifier):
                marker = _marker(root, identifier)
                info = path.lstat()
                if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != (marker['device'], marker['inode']):
                    continue
                if not terminal(marker['repository'], marker['job_id']) or not contained(marker['scope']) or not unused(path):
                    continue
                # Revalidate identities after external probes while still owning
                # the retained lease lock. Scope emptiness remains diagnostic, not lifecycle closure.
                latest = path.lstat()
                if (latest.st_dev, latest.st_ino, latest.st_mode, latest.st_mtime_ns, latest.st_ctime_ns) != (info.st_dev, info.st_ino, info.st_mode, info.st_mtime_ns, info.st_ctime_ns) or _marker(root, identifier) != marker or not contained(marker['scope']):
                    continue
                # Candidate only: no rename, unlink or deletion implementation.
                # A controller must still prove lifetime closure and mount safety.
                candidates.append(identifier)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            # Unknown state remains on disk. No fail-open fallback and no scan
            # of old arbitrary /tmp/session-* trees.
            continue
    return candidates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    commands = parser.add_subparsers(dest='action', required=True)
    run = commands.add_parser('run')
    run.add_argument('--repository', required=True)
    run.add_argument('--job-id', type=int, required=True)
    run.add_argument('command', nargs=argparse.REMAINDER)
    clean = commands.add_parser('reclaim')
    clean.add_argument('--low-bytes', type=int, required=True)
    clean.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.action == 'run':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('run requires a command')
        with Lease.create(args.root, args.repository, args.job_id) as lease:
            return subprocess.run(command, env={**os.environ, 'TMPDIR': str(lease.path)}).returncode
    print(json.dumps({'candidates_not_deletion_authority': reclaim(args.root, low_bytes=args.low_bytes, apply=args.apply), 'apply': args.apply}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
