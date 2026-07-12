"""Unit tests for scripts/check_beads_no_regression.py.

Covers the core comparison logic (compare_beads) directly plus full
subprocess invocations against the on-disk fixture pairs in
scripts/tests/fixtures/bead_regression_guard/ so the exit-code contract
(0 = pass, 1 = guard tripped, 2 = usage/parse error) is proven end to end,
not just at the Python-function level.
"""
import os
import subprocess
import sys
import unittest

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'scripts')))
import check_beads_no_regression as guard

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
FIXTURE_DIR = os.path.join(REPO_ROOT, 'scripts', 'tests', 'fixtures', 'bead_regression_guard')
SCRIPT_PATH = os.path.join(REPO_ROOT, 'scripts', 'check_beads_no_regression.py')


class TestCompareBeadsUnit(unittest.TestCase):
    """Direct unit tests of the compare_beads() function."""

    def test_deletion_detected(self):
        parent = {"a": {"id": "a", "title": "t", "updated_at": "2026-07-12T01:00:00Z"}}
        head = {}
        deletions, regressions = guard.compare_beads(parent, head)
        self.assertEqual(len(deletions), 1)
        self.assertIn("a", deletions[0])
        self.assertEqual(regressions, [])

    def test_regression_detected(self):
        parent = {"a": {"id": "a", "updated_at": "2026-07-12T05:00:00Z"}}
        head = {"a": {"id": "a", "updated_at": "2026-07-12T01:00:00Z"}}
        deletions, regressions = guard.compare_beads(parent, head)
        self.assertEqual(deletions, [])
        self.assertEqual(len(regressions), 1)

    def test_forward_update_is_clean(self):
        parent = {"a": {"id": "a", "updated_at": "2026-07-12T01:00:00Z"}}
        head = {
            "a": {"id": "a", "updated_at": "2026-07-12T05:00:00Z"},
            "b": {"id": "b", "updated_at": "2026-07-12T05:00:00Z"},
        }
        deletions, regressions = guard.compare_beads(parent, head)
        self.assertEqual(deletions, [])
        self.assertEqual(regressions, [])

    def test_missing_updated_at_does_not_crash(self):
        parent = {"a": {"id": "a"}}
        head = {"a": {"id": "a"}}
        deletions, regressions = guard.compare_beads(parent, head)
        self.assertEqual(deletions, [])
        self.assertEqual(regressions, [])

    def test_z_suffix_and_offset_timestamps_comparable(self):
        # 'Z' suffix and explicit +00:00 offset must compare equal/orderable.
        parent = {"a": {"id": "a", "updated_at": "2026-07-12T01:00:00Z"}}
        head = {"a": {"id": "a", "updated_at": "2026-07-12T00:59:59+00:00"}}
        deletions, regressions = guard.compare_beads(parent, head)
        self.assertEqual(len(regressions), 1)


class TestFixtureSubprocess(unittest.TestCase):
    """Full end-to-end proof: invoke the script as a subprocess against the
    committed fixture pairs and assert on exit codes, exactly as CI will."""

    def _run(self, parent_name, head_name):
        return subprocess.run(
            [
                sys.executable,
                SCRIPT_PATH,
                "--parent-file", os.path.join(FIXTURE_DIR, parent_name),
                "--head-file", os.path.join(FIXTURE_DIR, head_name),
            ],
            capture_output=True,
            text=True,
        )

    def test_deletion_fixture_fails(self):
        result = self._run("deletion_parent.jsonl", "deletion_head.jsonl")
        self.assertEqual(result.returncode, 1, msg=f"stderr: {result.stderr}")
        self.assertIn("DELETED", result.stderr)
        self.assertIn("REGRESSED", result.stderr)
        self.assertIn("jleechan-dhuo", result.stderr)
        self.assertIn("jleechan-zp2i", result.stderr)

    def test_normal_update_fixture_passes(self):
        result = self._run("normal_parent.jsonl", "normal_head.jsonl")
        self.assertEqual(result.returncode, 0, msg=f"stderr: {result.stderr}")
        self.assertIn("OK", result.stdout)


if __name__ == '__main__':
    suite = unittest.TestLoader().loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
