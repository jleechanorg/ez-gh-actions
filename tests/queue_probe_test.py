#!/usr/bin/env python3
"""Tests for scripts/queue_probe.py -- the fresh-vs-ghost queue split.

The behaviour under test is the one that made a 99-run queue unreadable: a queued
run that owns ZERO jobs can never start (GitHub returns 409 on cancel/force-cancel
and 403 on delete), so counting it as backlog overstates waiting work. Job count is
the only reliable discriminator -- verified live 2026-11-16 that `created_at ==
updated_at` is ALSO true for legitimate runs still queued, and that some ghosts do
carry a pull_requests entry.

Run: python3 tests/queue_probe_test.py
"""

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "queue_probe", ROOT / "scripts" / "queue_probe.py"
)
queue_probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(queue_probe)


class FakeGH:
    """Replacement for gh_json that serves scripted responses."""

    def __init__(self, runs, job_counts, fail_jobs_for=(), fail_message=None, in_progress_count=0, fail_in_progress=False):
        self.runs = list(runs)
        self.job_counts = dict(job_counts)
        self.fail_jobs_for = set(fail_jobs_for)
        # None means "use the rate-limit message", which is the branch that must
        # mark the whole pass unavailable rather than guess.
        self.fail_message = fail_message
        self.in_progress_count = in_progress_count
        self.fail_in_progress = fail_in_progress
        self.calls = []

    def __call__(self, args):
        self.calls.append(list(args))
        joined = " ".join(args)
        if "/jobs" in joined:
            run_id = int(joined.split("/actions/runs/")[1].split("/")[0])
            if run_id in self.fail_jobs_for:
                raise RuntimeError(
                    self.fail_message or "HTTP 403: API rate limit exceeded"
                )
            return self.job_counts.get(run_id, 0)
        if "status=queued" in joined:
            return {"workflow_runs": self.runs}
        if "status=in_progress" in joined:
            if self.fail_in_progress:
                raise RuntimeError(self.fail_message or "HTTP 403: API rate limit exceeded")
            return self.in_progress_count
        raise AssertionError(f"unexpected gh call: {args}")


def run_against(fake):
    original = queue_probe.gh_json
    queue_probe.gh_json = fake
    try:
        return queue_probe.probe_repo("org/repo")
    finally:
        queue_probe.gh_json = original


def queued_run(run_id, created="2026-11-11T20:00:00Z", prs=None):
    return {
        "id": run_id,
        "created_at": created,
        "updated_at": created,
        "pull_requests": prs or [],
    }


class GhostClassification(unittest.TestCase):
    def test_zero_job_run_counts_as_ghost_not_backlog(self):
        fake = FakeGH([queued_run(1)], {1: 0})
        result = run_against(fake)
        self.assertTrue(result["ok"])
        self.assertEqual(result["ghosts"], 1)
        self.assertEqual(result["fresh"], 0)

    def test_run_with_jobs_counts_as_fresh(self):
        fake = FakeGH([queued_run(2)], {2: 3})
        result = run_against(fake)
        self.assertEqual(result["fresh"], 1)
        self.assertEqual(result["ghosts"], 0)

    def test_ghost_with_pull_request_is_still_a_ghost(self):
        # A ghost may carry a PR association; PR presence must not reclassify it.
        fake = FakeGH([queued_run(3, prs=[{"number": 42}])], {3: 0})
        result = run_against(fake)
        self.assertEqual(result["ghosts"], 1)
        self.assertEqual(result["fresh"], 0)

    def test_identical_created_and_updated_is_not_used(self):
        # Both a ghost and a legitimately-just-queued run have created == updated.
        fake = FakeGH([queued_run(4), queued_run(5)], {4: 0, 5: 2})
        result = run_against(fake)
        self.assertEqual(result["ghosts"], 1)
        self.assertEqual(result["fresh"], 1)

    def test_mixed_population(self):
        runs = [queued_run(i) for i in (10, 11, 12, 13)]
        fake = FakeGH(runs, {10: 0, 11: 0, 12: 1, 13: 4})
        result = run_against(fake)
        self.assertEqual(result["ghosts"], 2)
        self.assertEqual(result["fresh"], 2)


class UnknownHandling(unittest.TestCase):
    def test_unreadable_job_count_is_treated_as_fresh_not_hidden(self):
        # A non-rate-limit read failure must never silently suppress real work:
        # an unknown count is treated as fresh, not as a ghost.
        fake = FakeGH(
            [queued_run(20)], {}, fail_jobs_for=(20,),
            fail_message="HTTP 404: Not Found",
        )
        result = run_against(fake)
        self.assertTrue(result["ok"])
        self.assertEqual(result["fresh"], 1)
        self.assertEqual(result["ghosts"], 0)
        self.assertTrue(result["partial"])
        self.assertEqual(result["unverified_runs"], 1)

    def test_readable_job_counts_set_partial_false_and_zero_unverified(self):
        fake = FakeGH([queued_run(22), queued_run(23)], {22: 1, 23: 0})
        result = run_against(fake)
        self.assertTrue(result["ok"])
        self.assertFalse(result["partial"])
        self.assertEqual(result["unverified_runs"], 0)

    def test_null_job_count_and_short_listing_preserve_partial_uncertainty(self):
        orig = queue_probe.gh_json
        try:
            # 1) job_count returning null without raising still marks partial + unverified_runs=1.
            def null_job_gh(args):
                joined = " ".join(args)
                if "status=queued" in joined:
                    return {"total_count": 1, "workflow_runs": [queued_run(70)]}
                if "status=in_progress" in joined:
                    return 0
                if "/jobs" in joined:
                    return None
                raise AssertionError(args)

            queue_probe.gh_json = null_job_gh
            res_null = queue_probe.probe_repo("org/repo")
            self.assertTrue(res_null["ok"])
            self.assertEqual(res_null["fresh"], 1)
            self.assertTrue(res_null["partial"])
            self.assertEqual(res_null["unverified_runs"], 1)

            # 2) Scheduled path (max_job_checks=None) receiving total_count=101 with 1 returned run
            #    preserves uncertainty instead of reporting a complete 1-run queue.
            def short_list_gh(args):
                joined = " ".join(args)
                if "status=queued" in joined:
                    return {"total_count": 101, "workflow_runs": [queued_run(71)]}
                if "status=in_progress" in joined:
                    return 2
                if "/jobs" in joined:
                    return 1
                raise AssertionError(args)

            queue_probe.gh_json = short_list_gh
            res_short = queue_probe.probe_repo("org/repo")
            self.assertTrue(res_short["ok"])
            self.assertEqual(res_short["queued_total"], 101)
            self.assertTrue(res_short["partial"])
            self.assertEqual(res_short["unverified_runs"], 100)
            self.assertIsNone(res_short["fresh"])
            self.assertIsNone(res_short["ghosts"])
        finally:
            queue_probe.gh_json = orig

    def test_rate_limited_pass_reports_not_ok(self):
        fake = FakeGH([queued_run(21)], {}, fail_jobs_for=(21,))
        result = run_against(fake)
        self.assertFalse(result["ok"], "rate-limited pass must not report a clean queue")

    def test_run_list_failure_reports_not_ok(self):
        def boom(args):
            raise RuntimeError("HTTP 403: rate limit")

        original = queue_probe.gh_json
        queue_probe.gh_json = boom
        try:
            result = queue_probe.probe_repo("org/repo")
        finally:
            queue_probe.gh_json = original
        self.assertFalse(result["ok"])
        self.assertIsNone(result["fresh"])


class OldestFreshWait(unittest.TestCase):
    def test_ghost_age_does_not_drive_oldest_wait(self):
        # A 5-day-old ghost must not make waiting work look 5 days stale.
        fake = FakeGH(
            [
                queued_run(30, created="2026-11-11T00:00:00Z"),
                queued_run(31, created="2020-01-01T00:00:00Z"),
            ],
            {30: 0, 31: 1},
        )
        result = run_against(fake)
        self.assertEqual(result["ghosts"], 1)
        # The only fresh run is 31, so oldest must reflect that, not the ghost.
        self.assertIsNotNone(result["oldest_fresh_wait_minutes"])
        self.assertGreater(result["oldest_fresh_wait_minutes"], 1000)

    def test_in_progress_runs_emitted_and_rate_limit_fails_closed(self):
        fake = FakeGH([queued_run(40)], {40: 1}, in_progress_count=12)
        result = run_against(fake)
        self.assertTrue(result["ok"])
        self.assertEqual(result["in_progress_runs"], 12)

        rate_limited = FakeGH([queued_run(40)], {40: 1}, fail_in_progress=True)
        bad = run_against(rate_limited)
        self.assertFalse(bad["ok"])
        self.assertIsNone(bad["in_progress_runs"])

    def test_max_job_checks_caps_queued_pagination_to_one_page(self):
        calls = []

        def fake_gh(args):
            calls.append(list(args))
            joined = " ".join(args)
            if "status=queued" in joined:
                self.assertIn("page=1", joined)
                return {
                    "total_count": 301,
                    "workflow_runs": [queued_run(i) for i in range(1, 101)],
                }
            if "status=in_progress" in joined:
                return 4
            if "/jobs" in joined:
                return 1
            raise AssertionError(f"unexpected call: {args}")

        original = queue_probe.gh_json
        queue_probe.gh_json = fake_gh
        try:
            result = queue_probe.probe_repo("org/repo", max_job_checks=10)
        finally:
            queue_probe.gh_json = original
        self.assertTrue(result["ok"])
        self.assertTrue(result["sample_capped"])
        self.assertEqual(result["queued_total"], 301)
        self.assertIsNone(result["fresh"])
        self.assertEqual(result["sampled_fresh"], 10)
        self.assertLessEqual(len(calls), 12)

    def test_queued_row_without_id_counts_toward_upper_bound_fresh_and_unverified(self):
        def fake_gh(args):
            joined = " ".join(args)
            if "status=queued" in joined:
                return {
                    "total_count": 1,
                    "workflow_runs": [{"created_at": "2020-01-01T00:00:00Z"}],
                }
            if "status=in_progress" in joined:
                return 0
            raise AssertionError(f"unexpected call: {args}")

        original = queue_probe.gh_json
        queue_probe.gh_json = fake_gh
        try:
            result = queue_probe.probe_repo("org/repo")
        finally:
            queue_probe.gh_json = original
        self.assertTrue(result["ok"])
        self.assertEqual(result["fresh"], 1)
        self.assertEqual(result["ghosts"], 0)
        self.assertTrue(result["partial"])
        self.assertEqual(result["unverified_runs"], 1)
        self.assertIsNotNone(result["oldest_fresh_wait_minutes"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
