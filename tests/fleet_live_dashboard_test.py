#!/usr/bin/env python3
"""Tests for scripts/fleet_live_dashboard.py -- local unredacted operator view."""

import importlib.util
import json
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "fleet_live_dashboard.py"


def load_module():
    spec = importlib.util.spec_from_file_location("fleet_live_dashboard", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_audit_dir(tmp: Path):
    hosts = {
        "generated_at_utc": "2026-11-18T09:13:10Z",
        "hosts": {
            "jeff-ubuntu": {
                "hostname": "Jeff-Ubuntu",
                "ezgha_service_status": "active",
                "uptime": "up 1 day, 9:53",
                "load_average": [77.39, 99.77, 100.04],
                "memory": {"total": "60Gi", "used": "41Gi", "available": "19Gi"},
                "disk": {"avail": "25G", "use_pct": "98%", "min_free_disk_gb_floor": 30},
                "admission_status": "PAUSED_DISK_FLOOR",
                "admission_message": "only 21-28 GB free (floor: 30 GB)",
                "configured_slots": 2,
                "executing_slots": 1,
                "idle_slots": 0,
                "down_slots": 1,
                "slots": [
                    {
                        "slot": 1,
                        "name": "ez-runner-c-1",
                        "state": "EXECUTING",
                        "repository": "jleechanorg/worldarchitect.ai",
                        "workflow": "Self-Hosted MVP Shards",
                        "job_display_name": "Directory tests (core-mvp-1)",
                        "run_id": 44268250231,
                        "run_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/44268250231",
                        "job_id": "31676b54-f9fb-512d-99d2-bfcae8112a0a",
                        "ref": "11320/merge",
                        "elapsed_minutes": 33.3,
                        "active_child_commands": ["python -m playwright install chromium"],
                    },
                    {
                        "slot": 2,
                        "name": "ez-runner-c-2",
                        "state": "DOWN",
                        "down_reason": "respawn blocked by disk-floor admission pause",
                    },
                ],
            },
            "mac": {
                "hostname": "jeffreys-macbook-pro",
                "ezgha_launchd_status": "disabled",
                "disk": {"root_avail": "29Gi", "min_free_disk_gb_floor": 30},
                "configured_container_slots": 1,
                "parked_container_slots": 1,
                "container_slots": [
                    {
                        "slot": 1,
                        "name": "ez-mac-runner-h-1",
                        "state": "PARKED",
                        "reason": "org.jleechanorg.ezgha disabled since Oct 29",
                    }
                ],
                "native_runners": [
                    {
                        "name": "worldai-testflight-native-mac",
                        "scope": "repo:jleechanorg/worldai_frontend",
                        "state": "IDLE",
                        "idle_note": "Listening for TestFlight",
                    }
                ],
            },
        },
    }
    cmux = {
        "captured_at_utc": "2026-11-18T09:15:24Z",
        "cmux_cloud_limits": {"plan_id": "pro", "max_active_vms": 5, "active_vms_running": 5},
        "cmux_vms": [
            {
                "id": "vm-1",
                "short": "cmux-dreamy",
                "display_name": "ci-runner-5",
                "vcpus": 4,
                "memory_mb": 8192,
                "load_avg": "4.96, 4.70, 3.62",
                "disk": {"total_gb": 32, "avail_gb": 12, "use_pct": "64%"},
                "ezgha_config": {"count": 1, "min_free_disk_gb": 10},
                "slots": [
                    {
                        "slot": 1,
                        "name": "cmux-dreamy-1",
                        "state": "EXECUTING",
                        "worker_etimes_sec": 1200,
                        "repo": "jleechanorg/worldai_frontend",
                        "workflow": "Mobile Check",
                        "job_display_name": "mobile-jest-shard (6)",
                        "active_child_cmds": ["node node_modules/jest/bin/jest.js --shard=6/6"],
                        "github_match": {
                            "job_id": 134678734727,
                            "html_url": "https://github.com/jleechanorg/worldai_frontend/actions/runs/44268453693/job/134678734727",
                            "run_html_url": "https://github.com/jleechanorg/worldai_frontend/actions/runs/44268453693",
                            "repo": "worldai_frontend",
                            "run_name": "Mobile Check",
                            "job_name": "mobile-jest-shard (6)",
                        },
                    }
                ],
            }
        ],
        "fleet_summary": {
            "special_runners": [
                {"name": "mac-smtp-egress", "host": "Mac", "scope": "org", "state": "OFFLINE", "reason": "offline in GH API"}
            ]
        },
        "github_reconciliation": {
            "in_progress_runs_by_repo": {"worldarchitect.ai": 9, "worldai_frontend": 4},
            "in_progress_jobs_by_repo": {"worldarchitect.ai": 12, "worldai_frontend": 18},
            "queued_runs_by_repo": {"worldarchitect.ai": 199, "worldai_frontend": 20},
            "queued_jobs_by_repo": {"worldarchitect.ai": 72, "worldai_frontend": 14},
            "worldarchitect_queued_breakdown": {
                "total_queued_runs_api": 199,
                "queued_runs_with_jobs": 50,
                "queued_runs_zero_jobs": 149,
            },
        },
    }
    gh = {
        "captured_at": "2026-11-18T09:13:06Z",
        "all_in_progress_jobs": [
            {
                "repo": "worldarchitect.ai",
                "run_id": 44268250231,
                "run_name": "Self-Hosted MVP Shards",
                "run_html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/44268250231",
                "job_id": 999888777,
                "job_name": "Directory tests (core-mvp-1(self hosted))",
                "runner_name": "ez-runner-c-1",
                "html_url": "https://github.com/jleechanorg/worldarchitect.ai/actions/runs/44268250231/job/999888777",
                "head_branch": "feat/cool-pr",
            }
        ],
    }
    latency = {
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
                        "workflow": "Self-Hosted MVP Shards",
                        "success": {
                            "queue_wait": {"n": 32, "avg_s": 339.0, "p50_s": 323.0, "p90_s": 637.0, "p99_s": 900.0, "max_s": 950.0},
                            "execution": {"n": 32, "avg_s": 413.0, "p50_s": 32.5, "p90_s": 1639.0, "p99_s": 2050.0, "max_s": 2078.0},
                            "total": {"n": 32, "avg_s": 752.0, "p50_s": 500.0, "p90_s": 1900.0, "p99_s": 2500.0, "max_s": 2581.0},
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
    (tmp / "ubuntu_mac_slots.json").write_text(json.dumps(hosts), encoding="utf-8")
    (tmp / "cmux_and_github_reconciliation.json").write_text(json.dumps(cmux), encoding="utf-8")
    (tmp / "github_live_snapshot.json").write_text(json.dumps(gh), encoding="utf-8")
    (tmp / "ci_latency_percentiles.json").write_text(json.dumps(latency), encoding="utf-8")


class FleetLiveDashboardTest(unittest.TestCase):
    def test_build_state_and_render_html_with_clickable_links(self):
        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            state = mod.build_operator_state(audit_dir=tmp)
            out_html = tmp / "out.html"
            html = mod.render_html(state)
            out_html.write_text(html, encoding="utf-8")

        self.assertIn("ez-runner-c-1", html)
        self.assertIn("ez-runner-c-2", html)
        self.assertIn("cmux-dreamy-1", html)
        self.assertIn("ez-mac-runner-h-1", html)
        self.assertIn("worldai-testflight-native-mac", html)
        self.assertIn("mac-smtp-egress", html)
        self.assertIn("https://github.com/jleechanorg/worldarchitect.ai/actions/runs/44268250231/job/999888777", html)
        self.assertIn("https://github.com/jleechanorg/worldarchitect.ai/pull/11320", html)
        self.assertIn("https://github.com/jleechanorg/worldai_frontend/actions/runs/44268453693/job/134678734727", html)
        self.assertIn("PAUSED_DISK_FLOOR", html)
        self.assertIn("PARKED", html)
        self.assertIn("p50", html)
        self.assertIn("p90", html)
        self.assertIn("p99", html)
        self.assertIn("playwright install", html)
        self.assertIn("jest", html)

    def test_serve_binds_loopback_and_serves_html_and_api(self):
        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            server = mod.create_server(host="127.0.0.1", port=0, audit_dir=tmp)
            self.assertEqual(server.server_address[0], "127.0.0.1")
            port = server.server_address[1]
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5) as resp:
                    self.assertEqual(resp.status, 200)
                    body = resp.read().decode("utf-8")
                    self.assertIn("ez-runner-c-1", body)
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5) as resp:
                    self.assertEqual(resp.status, 200)
                    payload = json.loads(resp.read().decode("utf-8"))
                    self.assertIn("hosts", payload)
                    self.assertIn("reconciliation", payload)
                    self.assertIn("latency", payload)
            finally:
                server.shutdown()
                server.server_close()

    def test_sanitizes_javascript_urls_and_escapes_script_json(self):
        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            hosts = json.loads((tmp / "ubuntu_mac_slots.json").read_text())
            hosts["hosts"]["jeff-ubuntu"]["slots"][0]["run_url"] = "javascript:alert(1)"
            hosts["hosts"]["jeff-ubuntu"]["slots"][0]["workflow"] = "</script><img onerror=1>"
            hosts["hosts"]["jeff-ubuntu"]["slots"][0]["job_display_name"] = "<!--<script>bad()"
            (tmp / "ubuntu_mac_slots.json").write_text(json.dumps(hosts), encoding="utf-8")

            gh = json.loads((tmp / "github_live_snapshot.json").read_text())
            gh["all_in_progress_jobs"][0]["run_html_url"] = "javascript:alert(2)"
            gh["all_in_progress_jobs"][0]["html_url"] = "data:text/html,<script>alert(3)</script>"
            (tmp / "github_live_snapshot.json").write_text(json.dumps(gh), encoding="utf-8")

            state = mod.build_operator_state(audit_dir=tmp)
            html = mod.render_html(state)

        self.assertNotIn("javascript:alert", html)
        self.assertNotIn("data:text/html", html)
        self.assertNotIn("</script><img", html)
        self.assertNotIn("<!--<script>", html)
        self.assertIn("\\u003c/script\\u003e\\u003cimg onerror=1\\u003e", html)
        self.assertIn("\\u003c!--\\u003cscript\\u003ebad()", html)

    def test_non_loopback_host_rejected_and_serve_ttl_cache(self):
        from unittest import mock

        mod = load_module()
        with self.assertRaises(ValueError):
            mod.create_server(host="0.0.0.0", port=0)

        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            calls = {"n": 0}
            orig_build = mod.build_operator_state

            def counting_build(**kwargs):
                calls["n"] += 1
                return orig_build(**kwargs)

            with mock.patch.object(mod, "build_operator_state", side_effect=counting_build):
                server = mod.create_server(host="127.0.0.1", port=0, audit_dir=tmp, cache_ttl_s=15.0)
                port = server.server_address[1]
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    for _ in range(3):
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5) as resp:
                            self.assertEqual(resp.status, 200)
                    self.assertEqual(calls["n"], 1)
                finally:
                    server.shutdown()
                    server.server_close()

    def test_custom_sanitized_host_and_latency_repo_keys(self):
        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            hosts = json.loads((tmp / "ubuntu_mac_slots.json").read_text())
            hosts["hosts"]["linux-host-1"] = hosts["hosts"].pop("jeff-ubuntu")
            hosts["hosts"]["linux-host-1"]["display_name"] = "linux-host-1 (Linux X64)"
            (tmp / "ubuntu_mac_slots.json").write_text(json.dumps(hosts), encoding="utf-8")

            lat = json.loads((tmp / "ci_latency_percentiles.json").read_text())
            lat["app_backend"] = lat.pop("worldarchitect_ai")
            lat["app_backend"]["repo"] = "org/app-backend"
            (tmp / "ci_latency_percentiles.json").write_text(json.dumps(lat), encoding="utf-8")

            state = mod.build_operator_state(audit_dir=tmp)
        host_ids = [h["id"] for h in state["hosts"]]
        self.assertIn("linux-host-1", host_ids)
        self.assertEqual(state["latency"]["workflows"][0]["repo"], "app-backend")


if __name__ == "__main__":
    unittest.main(verbosity=2)
