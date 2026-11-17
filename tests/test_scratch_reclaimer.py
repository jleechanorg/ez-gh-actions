"""Hermetic acceptance checks: no GitHub, lsof or host cleanup calls."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('scratch_reclaimer', Path(__file__).parents[1] / 'scripts/scratch_reclaimer.py')
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)

class ReclaimerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'managed'
        sr.initialize(self.root)

    def lease(self):
        return sr.Lease.create(self.root, 'owner/repo', 123, scope_probe=lambda: {'path': '/synthetic', 'device': 1, 'inode': 2})

    def reclaim(self, **kwargs):
        return sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
                          terminal=lambda repo, job: True, unused=lambda path: True,
                          contained=lambda scope: True, apply=False, **kwargs)

    def test_active_lease_excluded_even_if_remote_job_completed(self):
        with self.lease() as lease:
            self.assertEqual(self.reclaim(), [])
            self.assertTrue(lease.path.exists())

    def test_terminal_job_required_not_idle(self):
        with self.lease() as lease:
            path = lease.path
        self.assertEqual(sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
                         terminal=lambda *a: False, unused=lambda p: True, contained=lambda scope: True, apply=False), [])
        self.assertTrue(path.exists())

    def test_pressure_required_and_dry_run_default(self):
        with self.lease() as lease:
            path = lease.path
        self.assertEqual(sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 100,
                         terminal=lambda *a: True, unused=lambda p: True, contained=lambda scope: True, apply=False), [])
        sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
                   terminal=lambda *a: True, unused=lambda p: True, contained=lambda scope: True)
        self.assertTrue(path.exists())

    def test_completed_unused_disposable_tree_reported_not_removed(self):
        with self.lease() as lease:
            path = lease.path
            (path / 'scratch').write_text('disposable')
        self.assertEqual(self.reclaim(), [path.name])
        self.assertTrue(path.exists())
        self.assertTrue((self.root / 'locks' / (path.name + '.lock')).exists())

    def test_probe_error_fails_closed(self):
        with self.lease() as lease:
            path = lease.path
        for probe in ('terminal', 'unused', 'contained'):
            options = dict(terminal=lambda *a: True, unused=lambda p: True, contained=lambda scope: True)
            options[probe] = lambda *a: (_ for _ in ()).throw(OSError('probe failed'))
            self.assertEqual(sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10, apply=False, **options), [])
            self.assertTrue(path.exists())

    def test_replaced_inode_not_removed(self):
        with self.lease() as lease:
            path = lease.path
        moved = path.with_name(path.name + '-old')
        path.rename(moved)
        path.mkdir()
        self.assertEqual(self.reclaim(), [])
        self.assertTrue(path.exists())

    def test_symlink_candidate_not_followed(self):
        with self.lease() as lease:
            path = lease.path
        moved = path.with_name(path.name + '-old')
        path.rename(moved)
        path.symlink_to(moved, target_is_directory=True)
        self.assertEqual(self.reclaim(), [])
        self.assertTrue(moved.exists())

    def test_reuse_cannot_acquire_claim_during_terminal_probe(self):
        with self.lease() as lease:
            identifier = lease.identifier
        def terminal(*args):
            with self.assertRaises(BlockingIOError):
                with sr.lock_lease(self.root, identifier):
                    pass
            return True
        removed = sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
                             terminal=terminal, unused=lambda p: True, contained=lambda scope: True, apply=False)
        self.assertEqual(removed, [identifier])

    def test_stop_when_pressure_recovers(self):
        with self.lease(): pass
        with self.lease(): pass
        readings = iter([10, 10, 100])
        self.assertEqual(len(sr.reclaim(self.root, low_bytes=100,
            free_bytes=lambda: next(readings), terminal=lambda *a: True,
            unused=lambda p: True, contained=lambda scope: True, apply=False)), 1)

    def test_unmarked_legacy_trees_untouched(self):
        path = self.root / 'trees' / 'session-scratch-legacy'
        path.mkdir()
        self.assertEqual(self.reclaim(), [])
        self.assertTrue(path.exists())

    def test_lsof_distinguishes_no_handles_from_errors(self):
        from subprocess import CompletedProcess
        for code, stdout, stderr, expected in [(1,b'',b'',True),(0,b'42\n',b'',False),(1,b'',b'permission denied',False),(2,b'',b'',False)]:
            with patch.object(sr.subprocess, 'run', return_value=CompletedProcess([],code,stdout,stderr)):
                self.assertEqual(sr.lsof_unused(Path('/unused')), expected)

    def test_probe_atime_change_is_not_directory_replacement(self):
        from types import SimpleNamespace
        with self.lease() as lease:
            path = lease.path
        original_lstat = Path.lstat
        probed = False
        def read_only_probe(candidate):
            nonlocal probed
            probed = True
            return True
        def stat_after_read(candidate, *args, **kwargs):
            info = original_lstat(candidate, *args, **kwargs)
            if candidate == path and probed:
                return SimpleNamespace(**{name: getattr(info, name) for name in
                    ('st_dev', 'st_ino', 'st_mode', 'st_mtime_ns', 'st_ctime_ns')},
                    st_atime_ns=info.st_atime_ns + 1000000)
            return info
        with patch.object(Path, 'lstat', stat_after_read):
            candidates = sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
                terminal=lambda *a: True, unused=read_only_probe, contained=lambda *a: True)
        self.assertEqual(candidates, [path.name])

    def test_missing_lock_is_not_recreated(self):
        with self.lease() as lease:
            path = lease.path
        lock = self.root / 'locks' / (path.name + '.lock')
        lock.unlink()  # Disposable test fixture only.
        self.assertEqual(self.reclaim(), [])
        self.assertFalse(lock.exists())

    def test_fifo_and_nonobject_markers_fail_closed(self):
        with self.lease() as lease:
            path = lease.path
        marker = self.root / 'owners' / (path.name + '.json')
        marker.write_text('[]')
        self.assertEqual(self.reclaim(), [])
        marker.unlink()  # Disposable test fixture only.
        os.mkfifo(marker, 0o600)
        self.assertEqual(self.reclaim(), [])

    def test_apply_hard_refused_before_any_probe(self):
        with self.lease() as lease:
            path = lease.path
        with self.assertRaisesRegex(ValueError, 'deletion unavailable'):
            sr.reclaim(self.root, low_bytes=100, apply=True,
                       free_bytes=lambda: self.fail('must not probe'))
        self.assertTrue(path.exists())

    def test_detached_descendants_not_eligible(self):
        with self.lease() as lease:
            path = lease.path
        self.assertEqual(sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
            terminal=lambda *a: True, unused=lambda *a: True, contained=lambda *a: False), [])
        self.assertTrue(path.exists())

    def test_mount_audit_refuses_same_device_directory_and_file_mounts(self):
        # Hermetic fdinfo model, not a privileged bind-mount integration test.
        for directory in (False, True):
            with self.subTest(directory=directory):
                with self.lease() as lease:
                    child = lease.path / 'nested'
                    child.mkdir() if directory else child.write_text('mounted')
                original = sr.mount_id
                def synthetic_mount(fd):
                    if os.fstat(fd).st_ino == child.stat().st_ino:
                        return original(fd) + 1
                    return original(fd)
                with patch.object(sr, 'mount_id', side_effect=synthetic_mount):
                    self.assertNotIn(lease.identifier, self.reclaim())
                self.assertTrue(child.exists())

    def test_mount_replacement_during_external_probe_is_excluded(self):
        with self.lease() as lease:
            child = lease.path / 'nested'
            child.mkdir()
        replaced = False
        original = sr.mount_id
        def synthetic_mount(fd):
            value = original(fd)
            return value + 1 if replaced and os.fstat(fd).st_ino == child.stat().st_ino else value
        def probe(*args):
            nonlocal replaced
            replaced = True
            return True
        with patch.object(sr, 'mount_id', side_effect=synthetic_mount):
            self.assertEqual(sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
                terminal=probe, unused=lambda *a: True, contained=lambda *a: True), [])
        self.assertTrue(child.exists())

    def test_symlink_ancestor_refused_by_descriptor_audit(self):
        with self.lease() as lease:
            path = lease.path
        alias = Path(self.tmp.name) / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        # Direct helper also rejects an ancestor above an otherwise real root.
        with self.assertRaises(OSError):
            sr.audit_mount_tree(alias / 'trees' / path.name, (path.stat().st_dev, path.stat().st_ino))

    def test_missing_mount_identity_fails_closed(self):
        with self.lease() as lease:
            path = lease.path
        with patch.object(sr, 'mount_id', side_effect=ValueError('missing fdinfo')):
            self.assertEqual(self.reclaim(), [])
        self.assertTrue(path.exists())

    def test_mount_scan_budget_is_bounded_and_nondestructive(self):
        with self.lease() as lease:
            path = lease.path
            (path / 'one').mkdir()
            (path / 'one' / 'two').mkdir()
        identity = (path.stat().st_dev, path.stat().st_ino)
        self.assertFalse(sr.audit_mount_tree(path, identity, max_entries=1))
        self.assertFalse(sr.audit_mount_tree(path, identity, max_depth=0))
        self.assertTrue((path / 'one' / 'two').is_dir())

    def test_nested_symlink_and_special_file_never_opened_for_io(self):
        with self.lease() as lease:
            path = lease.path
            os.mkfifo(path / 'pipe')
        self.assertEqual(self.reclaim(), [lease.identifier])
        (path / 'link').symlink_to(Path(self.tmp.name))
        self.assertEqual(self.reclaim(), [])
        self.assertTrue((path / 'pipe').exists())

    def test_lifecycle_observations_never_authorize_apply(self):
        # Hook exit, leader exit and empty-scope snapshots cannot prove closed
        # admission. Even all positive diagnostics retain the hard refusal.
        for observation in ('successful_job_completed_hook', 'leader_exited', 'scope_empty'):
            with self.subTest(observation=observation):
                with self.assertRaisesRegex(ValueError, 'deletion unavailable'):
                    sr.reclaim(self.root, low_bytes=100, apply=True,
                        terminal=lambda *a: True, unused=lambda *a: True,
                        contained=lambda *a: True,
                        free_bytes=lambda: self.fail('apply must refuse before probes'))

    def test_collected_scope_is_unknown_not_terminal(self):
        with self.lease() as lease:
            path = lease.path
        with patch.object(sr, '_scope_info', side_effect=FileNotFoundError('collected scope')):
            self.assertEqual(sr.reclaim(self.root, low_bytes=100, free_bytes=lambda: 10,
                terminal=lambda *a: True, unused=lambda *a: True), [])
        self.assertTrue(path.exists())

    def test_job_identity_and_terminal_status(self):
        from subprocess import CompletedProcess
        import json
        for doc, expected in [({'id': 123, 'status': 'completed'}, True),
                              ({'id': 999, 'status': 'completed'}, False),
                              ({'id': 123, 'status': 'in_progress'}, False)]:
            with patch.object(sr.subprocess, 'run', return_value=CompletedProcess([], 0, json.dumps(doc).encode(), b'')):
                self.assertEqual(sr.terminal_job('owner/repo', 123), expected)
        self.assertFalse(sr.terminal_job('owner/repo', 'build'))

if __name__ == '__main__': unittest.main()
