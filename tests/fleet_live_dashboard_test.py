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
        self.assertEqual(state["latency"]["workflows"][0]["repo"], "org/app-backend")

    def test_rejects_non_loopback_host_header_and_concurrent_cache(self):
        import time
        import urllib.error
        from unittest import mock

        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            calls = {"n": 0}
            orig_build = mod.build_operator_state

            def slow_build(**kwargs):
                calls["n"] += 1
                time.sleep(0.15)
                return orig_build(**kwargs)

            with mock.patch.object(mod, "build_operator_state", side_effect=slow_build):
                server = mod.create_server(host="127.0.0.1", port=0, audit_dir=tmp, cache_ttl_s=15.0)
                port = server.server_address[1]
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    # Non-loopback Host header (DNS rebinding attempt) must be rejected 403
                    req = urllib.request.Request(
                        f"http://127.0.0.1:{port}/api/state",
                        headers={"Host": "evil.example:8790"},
                    )
                    with self.assertRaises(urllib.error.HTTPError) as ctx:
                        urllib.request.urlopen(req, timeout=5)
                    self.assertEqual(ctx.exception.code, 403)

                    # Concurrent /api/state requests share single-flight build (calls == 1)
                    results = []
                    def fetch_state():
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5) as resp:
                            results.append(resp.status)
                    workers = [threading.Thread(target=fetch_state) for _ in range(4)]
                    for w in workers:
                        w.start()
                    for w in workers:
                        w.join(timeout=5)
                    self.assertEqual(results, [200, 200, 200, 200])
                    self.assertEqual(calls["n"], 1)
                finally:
                    server.shutdown()
                    server.server_close()

    def test_active_mac_not_mislabeled_parked_and_default_local_collect(self):
        from unittest import mock

        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            hosts = json.loads((tmp / "ubuntu_mac_slots.json").read_text())
            hosts["hosts"]["mac"]["ezgha_launchd_status"] = "active"
            hosts["hosts"]["mac"]["container_slots"] = [{"slot": 1, "name": "ez-mac-runner-h-1", "state": "EXECUTING"}]
            (tmp / "ubuntu_mac_slots.json").write_text(json.dumps(hosts), encoding="utf-8")

            state = mod.build_operator_state(audit_dir=tmp)
            mac_host = next(h for h in state["hosts"] if h["id"] == "mac")
            self.assertNotIn("PARKED", mac_host["status"])
            self.assertIsNone(mac_host["alert_message"])

        # Default live path without --audit-dir collects local hosts
        with mock.patch.object(mod, "_collect_local_host_slots", return_value={
            "generated_at_utc": "2026-11-18T10:00:00Z",
            "hosts": {"local-test": {"slots": [{"slot": 1, "name": "local-slot-1", "state": "IDLE"}]}},
        }), mock.patch.object(mod, "_collect_live_github_snapshot", return_value={"captured_at": "2026-11-18T10:00:00Z", "summary": {}}), \
           mock.patch.object(mod.ci_latency_probe, "probe_latency", return_value={"ok": False, "overall": {}, "workflows": []}):
            live_state = mod.build_operator_state()
        self.assertEqual(live_state["source_mode"], "LIVE PROBE")
        self.assertEqual(live_state["hosts"][0]["slots"][0]["name"], "local-slot-1")

    def test_inactive_mac_without_opt_out_is_unhealthy_and_missing_slots_are_down_and_top_fail_is_unknown(self):
        import os
        import subprocess
        from unittest import mock

        mod = load_module()
        # 1) Inactive Mac without explicit opt-out must NEVER report PARKED
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            hosts = json.loads((tmp / "ubuntu_mac_slots.json").read_text())
            hosts["hosts"]["mac"]["ezgha_launchd_status"] = "inactive"
            hosts["hosts"]["mac"]["container_slots"] = [{"slot": 1, "name": "ez-mac-runner-h-1", "state": "DOWN"}]
            (tmp / "ubuntu_mac_slots.json").write_text(json.dumps(hosts), encoding="utf-8")
            state = mod.build_operator_state(audit_dir=tmp)
            mac_host = next(h for h in state["hosts"] if h["id"] == "mac")
            self.assertNotIn("PARKED", mac_host["status"])
            self.assertIn("DOWN", mac_host["status"])
            self.assertIn("MAC_RUNNER_DISABLED", mac_host["alert_message"])

        # 2) Local collection synthesizes missing configured slots as DOWN and docker-top failure as UNKNOWN
        def fake_run(cmd, **kwargs):
            if cmd[:2] == ["docker", "ps"]:
                return subprocess.CompletedProcess(cmd, 0, stdout="ez-runner-c-1\tUp 5 minutes\n", stderr="")
            if cmd[:2] == ["docker", "top"]:
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="top failed")
            if cmd[:2] == ["systemctl", "--user"] or cmd[:2] == ["launchctl", "list"]:
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
            raise AssertionError(f"unexpected cmd: {cmd}")

        with mock.patch.object(mod.platform, "system", return_value="Linux"), \
             mock.patch.object(mod, "_read_local_ezgha_config", return_value={"count": 2, "name_prefix": "ez-runner-c", "min_free_disk_gb": 25}), \
             mock.patch.object(mod.subprocess, "run", side_effect=fake_run):
            local = mod._collect_local_host_slots()
        host = next(iter(local["hosts"].values()))
        self.assertEqual([s["name"] for s in host["slots"]], ["ez-runner-c-1", "ez-runner-c-2"])
        self.assertEqual(host["slots"][0]["state"], "UNKNOWN")
        self.assertEqual(host["slots"][1]["state"], "DOWN")
        self.assertEqual(host["slots"][1]["reason"], "container missing")

        # 3) Live Mac unreachable Docker without MAC_RUNNER_DISABLED must not emit parked=True
        with mock.patch.dict(os.environ, {}, clear=False), \
             mock.patch.object(mod.platform, "system", return_value="Darwin"), \
             mock.patch.object(mod, "_read_local_ezgha_config", return_value={"count": 2, "name_prefix": "ez-mac-runner-h", "min_free_disk_gb": 15}), \
             mock.patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess(["docker"], 1, stdout="", stderr="unreachable")):
            os.environ.pop("MAC_RUNNER_DISABLED", None)
            os.environ.pop("EZGHA_DASHBOARD_MAC_DISABLED", None)
            mac_local = mod._collect_local_host_slots()
        self.assertFalse(mac_local["hosts"]["mac"]["parked"])
        self.assertEqual([s["state"] for s in mac_local["hosts"]["mac"]["container_slots"]], ["DOWN", "DOWN"])

    def test_live_github_snapshot_populates_fresh_and_ghosts_via_queue_probe(self):
        from unittest import mock

        mod = load_module()

        def fake_gh(args, timeout=20):
            joined = " ".join(args)
            if "status=in_progress" in joined:
                return {"total_count": 0, "workflow_runs": []}
            raise AssertionError(f"unexpected gh call: {args}")

        fake_q = {
            "repo": "org/r1",
            "ok": True,
            "fresh": 3,
            "ghosts": 2,
            "oldest_fresh_wait_minutes": 4,
            "in_progress_runs": 0,
            "queued_total": 5,
            "sample_capped": False,
            "sampled_fresh": 3,
            "sampled_ghosts": 2,
            "error": None,
        }
        with mock.patch.object(mod.ci_latency_probe, "gh_json", side_effect=fake_gh), \
             mock.patch.object(mod.queue_probe, "probe_repo", return_value=fake_q):
            snap = mod._collect_live_github_snapshot(repos=["org/r1"])
        self.assertEqual(snap["summary"]["fresh_queued_runs"], 3)
        self.assertEqual(snap["summary"]["inert_ghosts"], 2)
        rec = mod._normalize_reconciliation([], None, snap)
        self.assertEqual(rec["fresh_queued_runs"], 3)
        self.assertEqual(rec["inert_ghosts"], 2)

    def test_partial_repo_failure_sets_partial_flag_and_renders_scope_note(self):
        from unittest import mock

        mod = load_module()

        # Queue-only failure must NOT mislabel complete active_runs as partial
        def fake_gh_ok(args, timeout=20):
            joined = " ".join(args)
            if "status=in_progress" in joined:
                return {"total_count": 0, "workflow_runs": []}
            raise RuntimeError("unexpected")

        def fake_q_fail(repo, *, max_job_checks=None):
            return {
                "repo": repo, "ok": False, "fresh": None, "ghosts": None,
                "oldest_fresh_wait_minutes": None, "in_progress_runs": None,
                "queued_total": None, "sample_capped": False,
                "sampled_fresh": None, "sampled_ghosts": None, "error": "rate limited",
            }

        with mock.patch.object(mod.ci_latency_probe, "gh_json", side_effect=fake_gh_ok), \
             mock.patch.object(mod.queue_probe, "probe_repo", side_effect=fake_q_fail):
            q_only_snap = mod._collect_live_github_snapshot(repos=["org/only"])
        q_only_rec = mod._normalize_reconciliation([], None, q_only_snap)
        self.assertFalse(q_only_rec["active_runs_partial"])
        self.assertTrue(q_only_rec["queue_partial"])
        self.assertEqual(q_only_rec["repos_covered"], "1/1")
        self.assertEqual(q_only_rec["q_repos_covered"], "0/1")

        def fake_gh(args, timeout=20):
            joined = " ".join(args)
            if "org/good" in joined and "status=in_progress" in joined:
                return {"total_count": 3, "workflow_runs": []}
            raise RuntimeError("API error for org/bad")

        def fake_q(repo, *, max_job_checks=None):
            if repo == "org/good":
                return {
                    "repo": repo, "ok": True, "fresh": 2, "ghosts": 3,
                    "oldest_fresh_wait_minutes": 1, "in_progress_runs": 3,
                    "queued_total": 5, "sample_capped": False,
                    "sampled_fresh": 2, "sampled_ghosts": 3, "error": None,
                }
            return fake_q_fail(repo)

        with mock.patch.object(mod.ci_latency_probe, "gh_json", side_effect=fake_gh), \
             mock.patch.object(mod.queue_probe, "probe_repo", side_effect=fake_q):
            snap = mod._collect_live_github_snapshot(repos=["org/good", "org/bad"])
        rec = mod._normalize_reconciliation([], None, snap, scope_note="Live single-host scope: remote-linux unprobed")
        self.assertTrue(rec["active_runs_partial"])
        self.assertEqual(rec["repos_covered"], "1/2")
        html = mod.render_html({"generated_at_utc": "2026-11-18T10:00:00Z", "hosts": [], "reconciliation": rec, "latency": {"ok": False, "cohorts": {}, "workflows": []}})
        self.assertIn("active_runs_partial", html)
        self.assertIn("remote-linux unprobed", html)

    def test_macos_bsd_ps_native_runners_and_remote_linux_ssh_probe(self):
        import subprocess
        from unittest import mock

        mod = load_module()
        bsd_ps = (
            " 1234    12:34 /Users/op/actions-runner/bin/Runner.Worker\n"
            " 5678 1-02:03:04 /Users/op/actions-runner-macos-ci/bin/Runner.Listener\n"
            " 8888    00:12 grep Runner.Worker /Users/op/actions-runner-idle/bin/Runner.Listener\n"
            " 8889    05:00 /Users/op/actions-runner-idle/bin/Runner.Listener\n"
            " 9012    03:15 /Users/op/actions-runner-macos-ci/bin.2.338.2/Runner.Worker\n"
        )
        with mock.patch.object(mod.platform, "system", return_value="Darwin"), \
             mock.patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess(["ps"], 0, stdout=bsd_ps, stderr="")) as mrun:
            native = mod._collect_local_native_runners()
        self.assertIn("etime=", " ".join(mrun.call_args[0][0]))
        self.assertEqual(len(native), 3)
        by_name = {n["name"]: n for n in native}
        self.assertEqual(by_name["actions-runner"]["state"], "EXECUTING")
        self.assertEqual(by_name["actions-runner"]["elapsed_minutes"], 12.6)
        self.assertEqual(by_name["actions-runner-macos-ci"]["state"], "EXECUTING")
        self.assertEqual(by_name["actions-runner-macos-ci"]["elapsed_minutes"], 3.2)
        self.assertEqual(by_name["actions-runner-idle"]["state"], "IDLE")

        remote_payload = {
            "ok": True,
            "configured_slots": 3,
            "slots": [
                {"slot": 1, "name": "ez-runner-c-1", "state": "EXECUTING", "elapsed_minutes": 4.5, "active_child_commands": ["pytest"]},
                {"slot": 2, "name": "ez-runner-c-2", "state": "IDLE", "elapsed_minutes": None, "active_child_commands": []},
                {"slot": 3, "name": "ez-runner-c-3", "state": "DOWN", "elapsed_minutes": None, "active_child_commands": [], "reason": "container missing"},
            ],
        }
        with mock.patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess(["ssh"], 0, stdout=json.dumps(remote_payload), stderr="")):
            remote = mod._collect_remote_linux_slot_payload("jeff-ubuntu")
        self.assertEqual(remote["configured_slots"], 3)
        self.assertEqual([s["state"] for s in remote["slots"]], ["EXECUTING", "IDLE", "DOWN"])

    def test_concurrent_cold_error_does_not_return_200_null(self):
        import time
        import urllib.error
        from unittest import mock

        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            orig_build = mod.build_operator_state
            calls = {"n": 0}
            err_gate = threading.Event()

            def flaky_build(**kwargs):
                calls["n"] += 1
                if calls["n"] == 1:
                    err_gate.wait(timeout=2.0)
                    raise RuntimeError("boom on cold #1")
                time.sleep(0.25)
                return orig_build(**kwargs)

            with mock.patch.object(mod, "build_operator_state", side_effect=flaky_build):
                server = mod.create_server(host="127.0.0.1", port=0, audit_dir=tmp, wait_timeout_s=2.0)
                port = server.server_address[1]
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    statuses = []
                    def hit_first():
                        try:
                            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5) as resp:
                                statuses.append((resp.status, resp.read().decode()))
                        except urllib.error.HTTPError as e:
                            statuses.append((e.code, None))
                    t1 = threading.Thread(target=hit_first)
                    t1.start()
                    time.sleep(0.05)
                    err_gate.set()
                    t1.join(timeout=5)
                    self.assertEqual(statuses, [(500, None)])
                    # Subsequent retry succeeds with valid JSON object (never null)
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5) as resp:
                        self.assertEqual(resp.status, 200)
                        body = json.loads(resp.read().decode())
                        self.assertIsInstance(body, dict)
                finally:
                    err_gate.set()
                    server.shutdown()
                    server.server_close()

    def test_slow_probe_cold_504_and_warm_stale_while_revalidate(self):
        import time
        import urllib.error
        from unittest import mock

        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            orig_build = mod.build_operator_state
            calls = {"n": 0}
            gate = threading.Event()

            def controlled_build(**kwargs):
                calls["n"] += 1
                if calls["n"] == 1:
                    gate.wait(timeout=2.0)
                elif calls["n"] == 2:
                    time.sleep(0.5)
                return orig_build(**kwargs)

            with mock.patch.object(mod, "build_operator_state", side_effect=controlled_build):
                server = mod.create_server(host="127.0.0.1", port=0, audit_dir=tmp, cache_ttl_s=0.01, wait_timeout_s=0.1)
                port = server.server_address[1]
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    # Cold slow request times out cleanly at wait_timeout_s (504)
                    with self.assertRaises(urllib.error.HTTPError) as ctx:
                        urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5)
                    self.assertEqual(ctx.exception.code, 504)
                    gate.set()
                    time.sleep(0.15)
                    # Warm request returns immediately even when cache expired during slow refresh
                    t0 = time.monotonic()
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5) as resp:
                        self.assertEqual(resp.status, 200)
                    time.sleep(0.05)
                    t1 = time.monotonic()
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5) as resp:
                        self.assertEqual(resp.status, 200)
                    self.assertLess(time.monotonic() - t1, 0.25)
                finally:
                    gate.set()
                    server.shutdown()
                    server.server_close()

    def test_disabled_launchd_string_without_parked_flag_is_not_parked(self):
        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            hosts = json.loads((tmp / "ubuntu_mac_slots.json").read_text())
            hosts["hosts"]["mac"]["ezgha_launchd_status"] = "disabled"
            hosts["hosts"]["mac"]["container_slots"] = [{"slot": 1, "name": "ez-mac-runner-h-1", "state": "DOWN"}]
            (tmp / "ubuntu_mac_slots.json").write_text(json.dumps(hosts), encoding="utf-8")
            state = mod.build_operator_state(audit_dir=tmp)
            mac_host = next(h for h in state["hosts"] if h["id"] == "mac")
            self.assertNotIn("PARKED", mac_host["status"])
            self.assertIn("DOWN", mac_host["status"])

    def test_remote_probe_py_docker_top_timeout_marks_unknown_and_q_unverified_propagates(self):
        import os
        import subprocess
        from unittest import mock

        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            cfg_dir = tmp / ".config" / "ezgha"
            cfg_dir.mkdir(parents=True)
            (cfg_dir / "config.toml").write_text('[runner]\ncount = 3\nname_prefix = "ez-runner-c"\n', encoding="utf-8")
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            fake_docker = bin_dir / "docker"
            fake_docker.write_text(
                "#!/usr/bin/env python3\n"
                "import sys, time\n"
                "args = sys.argv[1:]\n"
                "if args[:1] == ['ps']:\n"
                "    print('ez-runner-c-1\\tUp 5 minutes')\n"
                "    print('ez-runner-c-2\\tUp 5 minutes')\n"
                "elif args[:1] == ['top']:\n"
                "    name = args[1]\n"
                "    if name == 'ez-runner-c-1':\n"
                "        print('PID ELAPSED COMMAND')\n"
                "        print('101 120 Runner.Worker /home/runner/bin/Runner.Worker')\n"
                "        print('102 65 python3 pytest tests/x.py')\n"
                "    elif name == 'ez-runner-c-2':\n"
                "        time.sleep(2)\n"
                "elif args[:1] == ['inspect']:\n"
                "    print('2026-11-18T10:00:00Z')\n",
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)
            probe_script = mod._REMOTE_PROBE_PY.replace('pid,etimes,comm,args"], capture_output=True, text=True, timeout=10', 'pid,etimes,comm,args"], capture_output=True, text=True, timeout=0.5')
            self.assertIn("timeout=0.5", probe_script)
            env = dict(os.environ, HOME=str(tmp), PATH=f"{bin_dir}:{os.environ.get('PATH', '')}")
            proc = subprocess.run(
                ["python3", "-c", probe_script],
                capture_output=True, text=True, check=True, env=env,
            )
            payload = json.loads(proc.stdout)
        self.assertEqual([s["state"] for s in payload["slots"]], ["EXECUTING", "UNKNOWN", "DOWN"])
        self.assertEqual(payload["slots"][1]["reason"], "docker top timeout")

        with mock.patch.object(mod.ci_latency_probe, "gh_json", return_value={"total_count": 1, "workflow_runs": [{"id": 1, "name": "CI", "html_url": "https://github.com/o/r/actions/runs/1", "head_branch": "main"}]}), \
             mock.patch.object(mod.queue_probe, "probe_repo", return_value={"repo": "org/repo", "ok": True, "fresh": 2, "ghosts": 0, "oldest_fresh_wait_minutes": 3, "in_progress_runs": 1, "queued_total": 2, "sample_capped": False, "sampled_fresh": 2, "sampled_ghosts": 0, "partial": True, "unverified_runs": 2, "error": None}):
            gh_data = mod._collect_live_github_snapshot(repos=["org/repo"])
        self.assertTrue(gh_data["summary"]["q_partial"])
        self.assertEqual(gh_data["summary"]["q_unverified_runs"], 2)
        rec = mod._normalize_reconciliation([], {}, gh_data)
        self.assertTrue(rec["queue_partial"])
        self.assertEqual(rec["q_unverified_runs"], 2)

        # Also verify full avg/p50/p90/p99 workflow table columns across Q, Exec, and Run + cohort runner_classes rendering.
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            state = mod.build_operator_state(audit_dir=tmp)
            rendered = mod.render_html(state)
            for col in ("q_avg", "q_p50", "q_p90", "q_p99", "e_avg", "e_p50", "e_p90", "e_p99", "e2e_avg", "e2e_p50", "e2e_p90", "e2e_p99"):
                self.assertIn(f'data-sort="{col}"', rendered)
            self.assertIn("data.cohorts[currentCohort]", rendered)
            self.assertIn("Latency Probe Unavailable:", rendered)
            self.assertIn("Partial Latency Sample:", rendered)

        # Real queue_probe logic through _collect_live_github_snapshot for short listings (total=8/1 row and total=101/1 row).
        for reported_total, expected_unverified in ((8, 7), (101, 100)):
            def fake_gh(args, timeout=20, _total=reported_total):
                joined = " ".join(args)
                if "status=in_progress" in joined and "per_page=50" in joined:
                    return {"total_count": 0, "workflow_runs": []}
                if "status=in_progress" in joined and "per_page=1" in joined:
                    return 0
                if "status=queued" in joined:
                    return {"total_count": _total, "workflow_runs": [{"id": 9001, "created_at": "2026-11-18T10:00:00Z"}]}
                if "/jobs" in joined:
                    return 1
                raise AssertionError(args)

            with mock.patch.object(mod.ci_latency_probe, "gh_json", side_effect=fake_gh), \
                 mock.patch.object(mod.queue_probe, "gh_json", side_effect=fake_gh):
                gh_snap = mod._collect_live_github_snapshot(repos=["org/repo"])
            self.assertTrue(gh_snap["summary"]["q_partial"])
            self.assertEqual(gh_snap["summary"]["q_unverified_runs"], expected_unverified)
            self.assertIsNone(gh_snap["summary"]["fresh_queued_runs"])
            self.assertIn(f"{expected_unverified} of {reported_total} queued run(s) unverified", gh_snap["summary"]["queued_sample_note"] or "")

        # Active in-progress short run listing (8 reported, 1 returned) and truncated job listing (120 reported, 1 returned) must both mark ip_partial=True.
        def fake_ip_short_runs(args, timeout=20):
            joined = " ".join(args)
            if "status=in_progress" in joined and "per_page=50" in joined:
                return {"total_count": 8, "workflow_runs": [{"id": 701, "name": "CI", "html_url": "https://github.com/o/r/actions/runs/701", "head_branch": "main"}]}
            if "status=in_progress" in joined and "per_page=1" in joined:
                return 8
            if "/jobs?per_page=100" in joined:
                return {"total_count": 1, "jobs": [{"id": 801, "status": "in_progress", "name": "j1", "runner_name": "ez-runner-c-1", "html_url": "https://github.com/o/r/actions/runs/701/job/801"}]}
            if "status=queued" in joined:
                return {"total_count": 0, "workflow_runs": []}
            raise AssertionError(args)

        with mock.patch.object(mod.ci_latency_probe, "gh_json", side_effect=fake_ip_short_runs), \
             mock.patch.object(mod.queue_probe, "gh_json", side_effect=fake_ip_short_runs):
            gh_ip_runs = mod._collect_live_github_snapshot(repos=["org/repo"])
        self.assertTrue(gh_ip_runs["summary"]["ip_partial"])
        self.assertEqual(mod._normalize_reconciliation([], {}, gh_ip_runs)["active_runs_partial"], True)
        self.assertTrue(any("1 of 8 returned" in e for e in gh_ip_runs["errors"]))

        def fake_ip_short_jobs(args, timeout=20):
            joined = " ".join(args)
            if "status=in_progress" in joined and "per_page=50" in joined:
                return {"total_count": 1, "workflow_runs": [{"id": 702, "name": "CI", "html_url": "https://github.com/o/r/actions/runs/702", "head_branch": "main"}]}
            if "status=in_progress" in joined and "per_page=1" in joined:
                return 1
            if "/jobs?per_page=100" in joined:
                return {"total_count": 120, "jobs": [{"id": 802, "status": "in_progress", "name": "j1", "runner_name": "ez-runner-c-1", "html_url": "https://github.com/o/r/actions/runs/702/job/802"}]}
            if "status=queued" in joined:
                return {"total_count": 0, "workflow_runs": []}
            raise AssertionError(args)

        with mock.patch.object(mod.ci_latency_probe, "gh_json", side_effect=fake_ip_short_jobs), \
             mock.patch.object(mod.queue_probe, "gh_json", side_effect=fake_ip_short_jobs):
            gh_ip_jobs = mod._collect_live_github_snapshot(repos=["org/repo"])
        self.assertTrue(gh_ip_jobs["summary"]["ip_partial"])
        self.assertEqual(mod._normalize_reconciliation([], {}, gh_ip_jobs)["active_runs_partial"], True)
        self.assertTrue(any("1 of 120 returned" in e for e in gh_ip_jobs["errors"]))

    def test_unrelated_args_mentioning_runner_worker_stay_idle_in_local_and_ssh_probes(self):
        import os
        import subprocess
        from unittest import mock

        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            cfg_dir = tmp / ".config" / "ezgha"
            cfg_dir.mkdir(parents=True)
            (cfg_dir / "config.toml").write_text('[runner]\ncount = 2\nname_prefix = "ez-runner-c"\n', encoding="utf-8")
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            fake_docker = bin_dir / "docker"
            fake_docker.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "args = sys.argv[1:]\n"
                "if args[:1] == ['ps']:\n"
                "    print('ez-runner-c-1\\tUp 5 minutes')\n"
                "    print('ez-runner-c-2\\tUp 5 minutes')\n"
                "elif args[:1] == ['top']:\n"
                "    print('PID ELAPSED COMMAND')\n"
                "    if args[1] == 'ez-runner-c-1':\n"
                "        print('101 120 Runner.Listener /home/runner/bin/Runner.Listener')\n"
                "        print('102 30 grep grep Runner.Worker /var/log/runner.log')\n"
                "    elif args[1] == 'ez-runner-c-2':\n"
                "        print('201 90 Runner.Worker /home/runner/bin/Runner.Worker')\n"
                "elif args[:1] == ['inspect']:\n"
                "    print('2026-11-18T10:00:00Z')\n",
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)
            env = dict(os.environ, HOME=str(tmp), PATH=f"{bin_dir}:{os.environ.get('PATH', '')}")
            proc = subprocess.run(
                ["python3", "-c", mod._REMOTE_PROBE_PY],
                capture_output=True, text=True, check=True, env=env,
            )
            remote_payload = json.loads(proc.stdout)
            self.assertEqual([s["state"] for s in remote_payload["slots"]], ["IDLE", "EXECUTING"])

            orig_path = os.environ.get("PATH", "")
            orig_home = os.environ.get("HOME", "")
            os.environ["PATH"] = f"{bin_dir}:{orig_path}"
            os.environ["HOME"] = str(tmp)
            try:
                with mock.patch.object(mod.platform, "system", return_value="Linux"), \
                     mock.patch.object(mod, "_probe_local_service_status", return_value="active"):
                    local_payload = mod._collect_local_host_slots()
            finally:
                os.environ["PATH"] = orig_path
                os.environ["HOME"] = orig_home
            host_entry = next(iter(local_payload["hosts"].values()))
            self.assertEqual([s["state"] for s in host_entry["slots"]], ["IDLE", "EXECUTING"])

    def test_partial_hosts_json_uses_live_120s_cadence_and_full_fixtures_use_15s_zero_gh_calls(self):
        from unittest import mock

        mod = load_module()
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fixture_audit_dir(tmp)
            hosts_only = tmp / "ubuntu_mac_slots.json"
            with mock.patch.object(mod, "_collect_live_github_snapshot", return_value={"captured_at": "2026-11-18T10:00:00Z", "all_in_progress_jobs": [], "errors": [], "summary": {}}) as m_gh, \
                 mock.patch.object(mod, "_cached_live_latency", return_value={"ok": True, "cohorts": {}, "workflows": []}) as m_lat:
                partial_state = mod.build_operator_state(hosts_json=hosts_only)
            self.assertEqual(partial_state["source_mode"], "LIVE PROBE")
            self.assertEqual(m_gh.call_count, 1)
            self.assertEqual(m_lat.call_count, 1)

            with mock.patch.object(mod, "_collect_live_github_snapshot", side_effect=AssertionError("should not poll GH")), \
                 mock.patch.object(mod, "_cached_live_latency", side_effect=AssertionError("should not poll latency")):
                audit_state = mod.build_operator_state(audit_dir=tmp)
            self.assertEqual(audit_state["source_mode"], "AUDIT SNAPSHOT")

            srv_partial = mod.create_server(port=0, hosts_json=hosts_only)
            try:
                with mock.patch.object(mod, "build_operator_state", return_value=partial_state):
                    # Verify server picked 120000ms refresh when --hosts-json is used without GH/latency fixtures.
                    import threading
                    import urllib.request
                    port_p = srv_partial.server_address[1]
                    t = threading.Thread(target=srv_partial.serve_forever, daemon=True)
                    t.start()
                    body = urllib.request.urlopen(f"http://127.0.0.1:{port_p}/", timeout=5).read().decode("utf-8")
                    self.assertIn("const AUTO_REFRESH_MS = 120000;", body)
            finally:
                srv_partial.shutdown()
                srv_partial.server_close()

            srv_full = mod.create_server(port=0, audit_dir=tmp)
            try:
                import threading
                import urllib.request
                port_f = srv_full.server_address[1]
                t2 = threading.Thread(target=srv_full.serve_forever, daemon=True)
                t2.start()
                body_full = urllib.request.urlopen(f"http://127.0.0.1:{port_f}/", timeout=5).read().decode("utf-8")
                self.assertIn("const AUTO_REFRESH_MS = 15000;", body_full)
            finally:
                srv_full.shutdown()
                srv_full.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
