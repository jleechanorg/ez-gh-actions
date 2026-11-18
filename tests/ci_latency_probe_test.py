#!/usr/bin/env python3
"""Tests for scripts/ci_latency_probe.py -- avg/p50/p90/p99 CI latency telemetry."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "ci_latency_probe.py"


def load_module():
    spec = importlib.util.spec_from_file_location("ci_latency_probe", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PercentileMathTest(unittest.TestCase):
    def test_linear_interpolation_percentiles(self):
        mod = load_module()
        stats = mod.compute_stats([10.0, 20.0, 30.0, 40.0, 100.0])
        self.assertEqual(stats["n"], 5)
        self.assertEqual(stats["avg_s"], 40.0)
        self.assertEqual(stats["p50_s"], 30.0)
        self.assertEqual(stats["p90_s"], 76.0)
        self.assertAlmostEqual(stats["p99_s"], 97.6, places=2)
        self.assertEqual(stats["max_s"], 100.0)

    def test_empty_values_return_nulls(self):
        mod = load_module()
        stats = mod.compute_stats([])
        self.assertEqual(
            stats,
            {"n": 0, "avg_s": None, "p50_s": None, "p90_s": None, "p99_s": None, "max_s": None},
        )


class ProbeAndRedactionTest(unittest.TestCase):
    def test_probe_computes_queue_exec_e2e_and_redacts_private_fields(self):
        mod = load_module()
        runs = [
            {
                "id": 1001,
                "name": "Self-Hosted MVP Shards",
                "status": "completed",
                "conclusion": "success",
                "created_at": "2026-11-18T08:00:00Z",
                "run_started_at": "2026-11-18T08:02:00Z",
                "updated_at": "2026-11-18T08:10:00Z",
                "head_branch": "secret-private-branch-name",
                "display_title": "SECRET PR TITLE DO NOT LEAK",
                "actor": {"login": "secret-actor"},
            },
            {
                "id": 1002,
                "name": "Visual Findings Gate",
                "status": "completed",
                "conclusion": "cancelled",
                "created_at": "2026-11-18T08:00:00Z",
                "run_started_at": "2026-11-18T08:01:00Z",
                "updated_at": "2026-11-18T08:05:00Z",
                "head_branch": "secret-branch-2",
                "display_title": "SECRET TITLE 2",
                "actor": {"login": "secret-actor-2"},
            },
            {
                "id": 1003,
                "name": "Skipped Run",
                "status": "completed",
                "conclusion": "skipped",
                "created_at": "2026-11-18T08:00:00Z",
                "updated_at": "2026-11-18T08:00:02Z",
            },
        ]
        jobs_by_run = {
            1001: [
                {
                    "id": 11,
                    "name": "core-mvp-1",
                    "status": "completed",
                    "conclusion": "success",
                    "created_at": "2026-11-18T08:00:00Z",
                    "started_at": "2026-11-18T08:02:00Z",
                    "completed_at": "2026-11-18T08:10:00Z",
                }
            ],
            1002: [
                {
                    "id": 22,
                    "name": "stage5-visual-findings",
                    "status": "completed",
                    "conclusion": "cancelled",
                    "created_at": "2026-11-18T08:00:00Z",
                    "started_at": "2026-11-18T08:01:00Z",
                    "completed_at": "2026-11-18T08:05:00Z",
                }
            ],
        }

        def fake_gh(args):
            joined = " ".join(args)
            if "/jobs" in joined:
                rid = int(joined.split("/actions/runs/")[1].split("/")[0])
                return {"jobs": jobs_by_run.get(rid, [])}
            if "/actions/runs" in joined:
                return {"workflow_runs": runs}
            raise AssertionError(f"unexpected call: {args}")

        orig = mod.gh_json
        mod.gh_json = fake_gh
        try:
            payload = mod.probe_latency(["jleechanorg/worldarchitect.ai"], limit=10)
        finally:
            mod.gh_json = orig

        self.assertTrue(payload["ok"])
        overall = payload["overall"]
        self.assertEqual(overall["queue_wait"]["p50_s"], 120.0)
        self.assertEqual(overall["execution"]["p50_s"], 480.0)
        self.assertEqual(overall["e2e"]["p50_s"], 600.0)
        self.assertEqual(payload["cancellation"]["cancelled_runs"], 1)
        self.assertEqual(payload["cancellation"]["total_non_skipped_runs"], 2)
        self.assertAlmostEqual(payload["cancellation"]["cancelled_rate_pct"], 50.0, places=1)
        self.assertTrue(any(w["workflow"] == "Self-Hosted MVP Shards" for w in payload["workflows"]))

        serialized = json.dumps(payload)
        for forbidden in ("secret-private-branch-name", "SECRET PR TITLE DO NOT LEAK", "secret-actor"):
            self.assertNotIn(forbidden, serialized)

    def test_rate_limit_degrades_gracefully(self):
        mod = load_module()

        def boom(args):
            raise RuntimeError("HTTP 403: API rate limit exceeded")

        orig = mod.gh_json
        mod.gh_json = boom
        try:
            payload = mod.probe_latency(["jleechanorg/worldarchitect.ai"], limit=10)
        finally:
            mod.gh_json = orig

        self.assertFalse(payload["ok"])
        self.assertIn("rate limit", payload["error"])

    def test_subprocess_timeout_degrades_gracefully(self):
        import subprocess
        from unittest import mock

        mod = load_module()
        with mock.patch.object(
            subprocess, "run", side_effect=subprocess.TimeoutExpired(cmd=["gh"], timeout=20)
        ):
            payload = mod.probe_latency(["jleechanorg/worldarchitect.ai"], limit=5)

        self.assertFalse(payload["ok"])
        self.assertIn("timed out", payload["error"])

    def test_from_audit_json_normalizes_real_schema(self):
        mod = load_module()
        audit_sample = {
            "generated_at_utc": "2026-11-18T09:11:59Z",
            "worldarchitect_ai": {
                "recent_contiguous_runs": {
                    "total_runs": 500,
                    "skipped_or_neutral_runs": 119,
                    "cohorts": {
                        "success": {"n": 174, "avg_s": 697.0, "p50_s": 453.0, "p90_s": 1561.2, "p99_s": 4198.2, "max_s": 6792.0},
                        "cancelled": {"n": 183, "avg_s": 707.2, "p50_s": 326.0, "p90_s": 2189.8, "p99_s": 4226.7, "max_s": 4364.0},
                        "all_non_skipped": {"n": 381, "avg_s": 738.3, "p50_s": 434.0, "p90_s": 1782.0, "p99_s": 4228.0, "max_s": 6792.0},
                    },
                },
                "job_level_audit": {
                    "job_cohorts": {
                        "success": {
                            "queue_wait": {"n": 186, "avg_s": 416.0, "p50_s": 339.5, "p90_s": 874.5, "p99_s": 1502.4, "max_s": 1562.0},
                            "execution": {"n": 186, "avg_s": 197.0, "p50_s": 47.0, "p90_s": 505.0, "p99_s": 1849.7, "max_s": 2078.0},
                            "total": {"n": 186, "avg_s": 613.0, "p50_s": 475.0, "p90_s": 1358.5, "p99_s": 2134.5, "max_s": 2581.0},
                        }
                    },
                    "by_workflow": [
                        {
                            "workflow": "Presubmit Checks",
                            "success": {
                                "queue_wait": {"n": 41, "avg_s": 700.0, "p50_s": 676.0, "p90_s": 1241.0, "p99_s": 1400.0, "max_s": 1450.0},
                                "execution": {"n": 41, "avg_s": 127.0, "p50_s": 47.0, "p90_s": 363.0, "p99_s": 650.0, "max_s": 691.0},
                                "total": {"n": 41, "avg_s": 827.0, "p50_s": 750.0, "p90_s": 1500.0, "p99_s": 1800.0, "max_s": 1900.0},
                            },
                        }
                    ],
                    "p90_slow_success_job_step_breakdown": {
                        "category_summaries_s": {
                            "checkout_hydrate": {"n": 20, "avg_s": 178.5, "p50_s": 76.5, "p90_s": 526.5, "p99_s": 747.1, "max_s": 764.0},
                        }
                    },
                },
            },
        }
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "audit.json"
            p.write_text(json.dumps(audit_sample), encoding="utf-8")
            normalized = mod.from_audit_json(p)
        self.assertTrue(normalized["ok"])
        self.assertEqual(normalized["overall"]["queue_wait"]["p50_s"], 339.5)
        self.assertEqual(normalized["overall"]["execution"]["p50_s"], 47.0)
        self.assertEqual(normalized["overall"]["e2e"]["p50_s"], 453.0)
        self.assertEqual(normalized["workflows"][0]["workflow"], "Presubmit Checks")

    def test_from_audit_json_supports_custom_sanitized_repo_keys(self):
        mod = load_module()
        audit_sample = {
            "generated_at_utc": "2026-11-18T00:00:00Z",
            "app_backend": {
                "repo": "org/app-backend",
                "recent_contiguous_runs": {
                    "skipped_or_neutral_runs": 1,
                    "cohorts": {
                        "success": {"n": 3, "avg_s": 120.0, "p50_s": 100.0, "p90_s": 200.0, "p99_s": 240.0, "max_s": 250.0},
                        "all_non_skipped": {"n": 4, "avg_s": 130.0, "p50_s": 110.0, "p90_s": 210.0, "p99_s": 250.0, "max_s": 260.0},
                    },
                    "by_workflow": [{"workflow": "CI", "success": {"n": 3, "avg_s": 120.0, "p50_s": 100.0, "p90_s": 200.0, "p99_s": 240.0, "max_s": 250.0}}],
                },
                "job_level_audit": {
                    "job_cohorts": {
                        "success": {
                            "queue_wait": {"n": 3, "avg_s": 5.0, "p50_s": 4.0, "p90_s": 8.0, "p99_s": 9.0, "max_s": 10.0},
                            "execution": {"n": 3, "avg_s": 90.0, "p50_s": 85.0, "p90_s": 150.0, "p99_s": 180.0, "max_s": 190.0},
                        }
                    },
                    "by_workflow": [
                        {
                            "workflow": "CI",
                            "success": {
                                "queue_wait": {"n": 3, "avg_s": 5.0, "p50_s": 4.0, "p90_s": 8.0, "p99_s": 9.0, "max_s": 10.0},
                                "execution": {"n": 3, "avg_s": 90.0, "p50_s": 85.0, "p90_s": 150.0, "p99_s": 180.0, "max_s": 190.0},
                            },
                        }
                    ],
                },
            },
        }
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "sanitized_audit.json"
            p.write_text(json.dumps(audit_sample), encoding="utf-8")
            normalized = mod.from_audit_json(p)
        self.assertTrue(normalized["ok"])
        self.assertEqual(normalized["workflows"][0]["repo"], "org/app-backend")
        self.assertEqual(normalized["overall"]["execution"]["p50_s"], 85.0)
        self.assertEqual(normalized["workflows"][0]["cohorts"]["failure"]["execution"]["n"], 0)

    def test_same_workflow_name_across_repos_does_not_collide_and_timeout_sets_partial(self):
        mod = load_module()

        def fake_gh(args, timeout=20):
            joined = " ".join(args)
            if "/jobs" in joined:
                rid = int(joined.split("/actions/runs/")[1].split("/")[0])
                if rid == 2:
                    raise RuntimeError("gh timed out after 20s")
                return {
                    "jobs": [{
                        "id": rid * 10,
                        "conclusion": "success",
                        "created_at": "2026-11-18T08:00:00Z",
                        "started_at": "2026-11-18T08:01:00Z",
                        "completed_at": "2026-11-18T08:02:00Z",
                    }]
                }
            if "repo-a" in joined:
                return {"workflow_runs": [{
                    "id": 1, "name": "CI", "conclusion": "success",
                    "created_at": "2026-11-18T08:00:00Z", "updated_at": "2026-11-18T08:03:00Z",
                }]}
            return {"workflow_runs": [{
                "id": 2, "name": "CI", "conclusion": "success",
                "created_at": "2026-11-18T08:00:00Z", "updated_at": "2026-11-18T08:04:00Z",
            }]}

        orig = mod.gh_json
        mod.gh_json = fake_gh
        try:
            payload = mod.probe_latency(["org/repo-a", "org/repo-b"], limit=10)
        finally:
            mod.gh_json = orig

        self.assertTrue(payload["ok"])
        self.assertTrue(payload["partial"])
        self.assertEqual(payload["timed_out_runs"], 1)
        repos = {w["repo"] for w in payload["workflows"]}
        self.assertEqual(repos, {"org/repo-a", "org/repo-b"})

    def test_classify_phase_ignores_flag_paths_and_zero_runs_returns_none_cancel_rate(self):
        mod = load_module()
        self.assertEqual(mod.classify_phase("pytest --junitxml=/tmp/playwright/report.xml"), "pytest")
        self.assertEqual(mod.classify_phase("python3 -m pytest -k playwright tests/"), "pytest")
        self.assertIsNone(mod.classify_phase("cat /tmp/playwright/trace.zip"))
        self.assertEqual(mod.classify_phase("npx playwright install chromium"), "playwright install")
        self.assertEqual(mod.classify_phase("npx playwright test --grep jest"), "playwright")
        self.assertEqual(mod.classify_phase("gh api repos/org/repo/tarball/main"), "gh api tarball")

        orig = mod.gh_json
        mod.gh_json = lambda args, timeout=20: {"workflow_runs": []}
        try:
            payload = mod.probe_latency(["org/repo"], limit=5)
        finally:
            mod.gh_json = orig
        self.assertTrue(payload["ok"])
        self.assertIsNone(payload["cancellation"]["cancelled_rate_pct"])
        self.assertIn("runner_classes", payload)


if __name__ == "__main__":
    unittest.main(verbosity=2)
