import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from urllib.parse import urlencode


ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT / "scripts" / "job_outcome_monitor.py"


class JobOutcomeMonitorTest(unittest.TestCase):
    def test_completed_matching_jobs_above_threshold_are_healthy(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 2,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff},
                        {"id": 102, "status": "completed", "created_at": cutoff},
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 2,
                    "jobs": [
                        {
                            "id": 1001,
                            "status": "completed",
                            "conclusion": "success",
                            "runner_name": "ez-mac-runner-b-1",
                            "completed_at": "2026-07-18T10:00:00Z",
                        },
                        {
                            "id": 1002,
                            "status": "completed",
                            "conclusion": "failure",
                            "runner_name": "ez-mac-runner-bad-2",
                            "completed_at": "2026-07-18T10:00:00Z",
                        },
                    ],
                },
                "repos/acme/widgets/actions/runs/102/jobs?filter=all&per_page=100": {
                    "total_count": 1,
                    "jobs": [
                        {
                            "id": 1003,
                            "status": "completed",
                            "conclusion": "success",
                            "runner_name": "ez-mac-runner-b-2",
                            "completed_at": "2026-07-18T10:00:00Z",
                        }
                    ],
                },
            }
            if not MONITOR.exists():
                self.fail("job outcome monitor is missing")
            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "2",
                "--maximum-runs-per-repo",
                "10",
            )

            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "HEALTHY")
            self.assertEqual(payload["outcomes"]["completed_jobs"], 2)
            self.assertEqual(payload["outcomes"]["success"], 2)
            self.assertEqual(payload["outcomes"]["unsuccessful"], 0)
            self.assertEqual(payload["outcomes"]["sample_success_rate"], 1.0)
            self.assertTrue(payload["coverage"]["sample_sufficient"])
            self.assertTrue(payload["coverage"]["sample_target_met"])
            self.assertTrue(payload["coverage"]["eligible_run_population_complete"])
            self.assertNotIn("population_window_complete", payload["coverage"])
            self.assertEqual(
                payload["eligibility_window"]["population"],
                "jobs completed within window from completed runs created within same window",
            )
            self.assertEqual(
                payload["sample"]["selection"],
                "exact-prefix jobs from newest-created completed runs scanned before hard caps",
            )
            self.assertEqual(payload["sample"]["newest_completed_at"], "2026-07-18T10:00:00Z")
            self.assertEqual(payload["sample"]["oldest_completed_at"], "2026-07-18T10:00:00Z")
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(len(calls), 3)
            self.assertTrue(all(not call["stale_auth_present"] for call in calls))

    def test_run_cap_does_not_hide_a_sufficient_bounded_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 2,
                }
            )
            run = {"status": "completed", "created_at": cutoff}
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 3,
                    "workflow_runs": [
                        {"id": 101, **run},
                        {"id": 102, **run},
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 1,
                    "jobs": [self._job(1001, "success", "ez-mac-runner-b-1")],
                },
                "repos/acme/widgets/actions/runs/102/jobs?filter=all&per_page=100": {
                    "total_count": 1,
                    "jobs": [self._job(1002, "success", "ez-mac-runner-b-2")],
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "1",
                "--maximum-runs-per-repo",
                "2",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "HEALTHY")
            self.assertTrue(payload["coverage"]["sample_sufficient"])
            self.assertTrue(payload["coverage"]["sample_target_met"])
            self.assertFalse(payload["coverage"]["eligible_run_population_complete"])
            self.assertIn("acme/widgets", payload["coverage"]["run_caps_reached"])
            self.assertEqual(payload["outcomes"]["completed_jobs"], 2)
            self.assertFalse(payload["causal_attribution"]["determined"])

    def test_objective_non_success_conclusions_can_make_signal_unhealthy(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 1,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff}
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 5,
                    "jobs": [
                        self._job(1001, "success", "ez-mac-runner-b-1"),
                        self._job(1002, "success", "ez-mac-runner-b-2"),
                        self._job(1003, "success", "ez-mac-runner-b-3"),
                        self._job(1004, "failure", "ez-mac-runner-b-4"),
                        self._job(1005, "cancelled", "ez-mac-runner-b-5"),
                    ],
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "5",
                "--sample-target",
                "5",
                "--maximum-runs-per-repo",
                "10",
            )

            self.assertEqual(result.returncode, 1, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "UNHEALTHY")
            self.assertEqual(payload["outcomes"]["sample_success_rate"], 0.6)
            self.assertEqual(
                payload["outcomes"]["conclusions"],
                {"cancelled": 1, "failure": 1, "success": 3},
            )
            self.assertFalse(payload["causal_attribution"]["determined"])

    def test_known_thirteen_of_thirty_two_failure_incident_is_unhealthy(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            jobs = [
                self._job(1000 + index, "success", f"ez-mac-runner-b-{index % 6 + 1}")
                for index in range(19)
            ] + [
                self._job(2000 + index, "failure", f"ez-mac-runner-b-{index % 6 + 1}")
                for index in range(13)
            ]
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 1,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff}
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 32,
                    "jobs": jobs,
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "6",
                "--sample-target",
                "32",
                "--maximum-runs-per-repo",
                "10",
            )

            self.assertEqual(result.returncode, 1, result.stderr or result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "UNHEALTHY")
            self.assertEqual(payload["outcomes"]["completed_jobs"], 32)
            self.assertEqual(payload["outcomes"]["success"], 19)
            self.assertEqual(payload["outcomes"]["unsuccessful"], 13)
            self.assertAlmostEqual(payload["outcomes"]["sample_success_rate"], 19 / 32)

    def test_request_cap_still_allows_verdict_for_sufficient_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            run = {"status": "completed", "created_at": cutoff}
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 2,
                    "workflow_runs": [{"id": 101, **run}, {"id": 102, **run}],
                },
                "repos/acme/widgets/actions/runs/102/jobs?filter=all&per_page=100": {
                    "total_count": 1,
                    "jobs": [self._job(1001, "success", "ez-mac-runner-b-1")],
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "1",
                "--sample-target",
                "2",
                "--maximum-runs-per-repo",
                "10",
                "--maximum-api-requests",
                "2",
            )

            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "HEALTHY")
            self.assertTrue(payload["coverage"]["sample_sufficient"])
            self.assertFalse(payload["coverage"]["sample_target_met"])
            self.assertTrue(payload["coverage"]["api_request_cap_reached"])
            self.assertFalse(payload["coverage"]["eligible_run_population_complete"])

    def test_duplicate_repos_are_scanned_once(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 1,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff}
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 1,
                    "jobs": [self._job(1001, "success", "ez-mac-runner-b-1")],
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "1",
                "--sample-target",
                "1",
                "--maximum-runs-per-repo",
                "10",
                repos=["acme/widgets", "acme/widgets"],
            )

            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["repos"], ["acme/widgets"])
            self.assertEqual(len(log.read_text().splitlines()), 2)

    def test_all_rerun_attempts_contribute_objective_outcomes(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 1,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff}
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 2,
                    "jobs": [
                        self._job(1001, "failure", "ez-mac-runner-b-1"),
                        self._job(1002, "success", "ez-mac-runner-b-1"),
                    ],
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "2",
                "--sample-target",
                "2",
                "--maximum-runs-per-repo",
                "10",
            )

            self.assertEqual(result.returncode, 1, result.stderr or result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "UNHEALTHY")
            self.assertEqual(payload["outcomes"]["conclusions"], {"failure": 1, "success": 1})

    def test_whole_probe_deadline_exhaustion_is_explicitly_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 0,
                    "workflow_runs": [],
                }
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--maximum-wall-seconds",
                "0.05",
                "--minimum-jobs",
                "1",
                "--maximum-runs-per-repo",
                "10",
                fake_delay_seconds="0.2",
            )

            self.assertEqual(result.returncode, 2, result.stderr or result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "UNKNOWN")
            self.assertTrue(payload["coverage"]["probe_deadline_exhausted"])
            self.assertIn("probe_deadline_exhausted", payload["coverage"]["reasons"])

    def test_truncated_job_response_is_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 1,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff}
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 2,
                    "jobs": [self._job(1001, "success", "ez-mac-runner-b-1")],
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "1",
                "--maximum-runs-per-repo",
                "10",
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "UNKNOWN")
            self.assertIn(
                "job_list_truncated:acme/widgets:101",
                payload["coverage"]["reasons"],
            )

    def test_truncated_run_response_is_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 2,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff}
                    ],
                },
                "repos/acme/widgets/actions/runs/101/jobs?filter=all&per_page=100": {
                    "total_count": 1,
                    "jobs": [self._job(1001, "success", "ez-mac-runner-b-1")],
                },
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "1",
                "--maximum-runs-per-repo",
                "10",
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "UNKNOWN")
            self.assertIn(
                "run_list_truncated:acme/widgets",
                payload["coverage"]["reasons"],
            )

    def test_api_request_cap_and_insufficient_sample_are_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            config = work / "config.toml"
            config.write_text('[runner]\nname_prefix = "ez-mac-runner-b"\n')
            log = work / "calls.jsonl"
            cutoff = "2026-07-18T06:00:00Z"
            query = urlencode(
                {
                    "status": "completed",
                    "created": f">={cutoff}",
                    "per_page": 10,
                }
            )
            responses = {
                f"repos/acme/widgets/actions/runs?{query}": {
                    "total_count": 1,
                    "workflow_runs": [
                        {"id": 101, "status": "completed", "created_at": cutoff}
                    ],
                }
            }

            result = self._run_monitor(
                work,
                config,
                log,
                responses,
                "--minimum-jobs",
                "2",
                "--maximum-runs-per-repo",
                "10",
                "--maximum-api-requests",
                "1",
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["verdict"], "UNKNOWN")
            self.assertEqual(payload["coverage"]["api_requests"], 1)
            self.assertIn("insufficient_sample", payload["coverage"]["reasons"])
            self.assertTrue(payload["coverage"]["api_request_cap_reached"])

    @staticmethod
    def _job(job_id, conclusion, runner_name, completed_at="2026-07-18T10:00:00Z"):
        return {
            "id": job_id,
            "status": "completed",
            "conclusion": conclusion,
            "runner_name": runner_name,
            "completed_at": completed_at,
        }

    def _run_monitor(
        self,
        work,
        config,
        log,
        responses,
        *extra_args,
        repos=None,
        fake_delay_seconds="0",
    ):
        fake_bin = self._fake_gh(work)
        env = os.environ.copy()
        env.update(
            PATH=f"{fake_bin}:{env['PATH']}",
            FAKE_GH_RESPONSES=json.dumps(responses),
            FAKE_GH_LOG=str(log),
            FAKE_GH_DELAY_SECONDS=fake_delay_seconds,
            GH_TOKEN="stale-test-value",
            GH_TOKEN_AGENTF="stale-test-value",
            GITHUB_TOKEN="stale-test-value",
        )
        repo_args = []
        for repo in repos or ["acme/widgets"]:
            repo_args.extend(["--repo", repo])
        return subprocess.run(
            [
                str(MONITOR),
                "--config",
                str(config),
                *repo_args,
                "--now",
                "2026-07-18T12:00:00Z",
                "--maximum-api-requests",
                "20",
                "--sample-target",
                "2",
                *extra_args,
            ],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    @staticmethod
    def _fake_gh(work):
        fake_bin = work / "bin"
        fake_bin.mkdir()
        executable = fake_bin / "gh"
        executable.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import sys
                import time

                if len(sys.argv) != 3 or sys.argv[1] != "api":
                    raise SystemExit(64)
                path = sys.argv[2]
                with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as handle:
                    handle.write(json.dumps({
                        "path": path,
                        "stale_auth_present": any(
                            name in os.environ
                            for name in ("GH_TOKEN", "GH_TOKEN_AGENTF", "GITHUB_TOKEN")
                        ),
                    }) + "\\n")
                time.sleep(float(os.environ["FAKE_GH_DELAY_SECONDS"]))
                responses = json.loads(os.environ["FAKE_GH_RESPONSES"])
                if path not in responses:
                    print(f"unexpected path: {path}", file=sys.stderr)
                    raise SystemExit(1)
                print(json.dumps(responses[path]))
                """
            )
        )
        executable.chmod(0o755)
        return fake_bin


if __name__ == "__main__":
    unittest.main()
