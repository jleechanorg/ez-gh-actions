import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "build_runner_dashboard_snapshot.py"
SPEC = importlib.util.spec_from_file_location("runner_dashboard_snapshot", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def host_payload(host_class, configured):
    return {
        "schema_version": 1,
        "host_class": host_class,
        "sources": {
            key: {"ok": True}
            for key in (
                "config",
                "service",
                "docker",
                "process_probe",
                "disk",
                "watchdog_state",
            )
        },
        "fleet": {
            "configured": configured,
            "executing": configured - 1,
            "idle": 1,
            "cycling": 0,
            "down": 0,
            "reserved": configured,
        },
        "disk": {"status": "healthy"},
        "watchdog": {"consecutive_misses": 0, "restart_after": 3},
        "secret_host": "must-not-publish",
        "raw": "must-not-publish",
    }


class SnapshotTest(unittest.TestCase):
    def test_exact_public_contract(self):
        snapshot = MODULE.build_snapshot(
            mac_payload=host_payload("mac", 4),
            linux_payload=host_payload("linux", 20),
            observed_at="2026-07-14T20:00:00Z",
            published_at="2026-07-14T20:00:05Z",
        )
        self.assertEqual(snapshot["sources"], {
            "mac_host": {"ok": True},
            "linux_host": {"ok": True},
        })
        self.assertEqual(snapshot["fleets"]["linux"]["fleet"]["configured"], 20)
        serialized = json.dumps(snapshot)
        self.assertNotIn("must-not-publish", serialized)
        self.assertNotIn("secret_host", serialized)
        self.assertNotIn("raw", serialized)

    def test_healthy_configured_linux_fleet_is_ok(self):
        # Regression for the EXPECTED_CONFIGURED["linux"] drift: the constant has
        # been wrong twice -- 16 while the real jeff-ubuntu fleet was 10, then 10
        # while it was 20 -- and each time a perfectly healthy fleet was permanently
        # reported STALE/UNKNOWN. The fixture is independent of the module's own
        # EXPECTED_CONFIGURED so it cannot silently re-mask a future drift.
        # Real shapes on 2026-11-17: mac 4 ("centralized to 4 Mac + 20 Linux"),
        # linux 20.
        snapshot = MODULE.build_snapshot(
            mac_payload=host_payload("mac", 4),
            linux_payload=host_payload("linux", 20),
            observed_at="2026-07-14T20:00:00Z",
            published_at="2026-07-14T20:00:05Z",
        )
        self.assertTrue(snapshot["sources"]["linux_host"]["ok"])
        self.assertEqual(snapshot["fleets"]["linux"]["fleet"]["configured"], 20)

    def test_inconsistent_slot_sum_fails_closed(self):
        linux = host_payload("linux", 20)
        linux["fleet"]["down"] = 1
        snapshot = MODULE.build_snapshot(
            mac_payload=host_payload("mac", 4),
            linux_payload=linux,
            observed_at="2026-07-14T20:00:00Z",
            published_at="2026-07-14T20:00:05Z",
        )
        self.assertFalse(snapshot["sources"]["linux_host"]["ok"])

    def test_underconfigured_host_fails_closed(self):
        for host_class, configured in (("mac", 3), ("linux", 19)):
            payloads = {
                "mac": host_payload("mac", 4),
                "linux": host_payload("linux", 20),
            }
            payloads[host_class] = host_payload(host_class, configured)
            snapshot = MODULE.build_snapshot(
                mac_payload=payloads["mac"],
                linux_payload=payloads["linux"],
                observed_at="2026-07-14T20:00:00Z",
                published_at="2026-07-14T20:00:05Z",
            )
            self.assertFalse(snapshot["sources"][f"{host_class}_host"]["ok"])

    def test_all_down_remains_valid_when_container_disk_is_unavailable(self):
        mac = host_payload("mac", 4)
        mac["fleet"].update(executing=0, idle=0, cycling=0, down=4)
        mac["sources"]["disk"]["ok"] = False
        mac["disk"]["status"] = "unknown"
        snapshot = MODULE.build_snapshot(
            mac_payload=mac,
            linux_payload=host_payload("linux", 20),
            observed_at="2026-07-14T20:00:00Z",
            published_at="2026-07-14T20:00:05Z",
        )
        self.assertTrue(snapshot["sources"]["mac_host"]["ok"])

    def test_missing_watchdog_is_explicit_degraded_telemetry(self):
        mac = host_payload("mac", 4)
        mac["sources"]["watchdog_state"]["ok"] = False
        mac["watchdog"] = {"consecutive_misses": None, "restart_after": None}
        snapshot = MODULE.build_snapshot(
            mac_payload=mac,
            linux_payload=host_payload("linux", 20),
            observed_at="2026-07-14T20:00:00Z",
            published_at="2026-07-14T20:00:05Z",
        )
        self.assertTrue(snapshot["sources"]["mac_host"]["ok"])
        self.assertFalse(
            snapshot["fleets"]["mac"]["sources"]["watchdog_state"]["ok"]
        )
        self.assertIsNone(
            snapshot["fleets"]["mac"]["watchdog"]["consecutive_misses"]
        )

    def test_dynamic_watchdog_threshold_is_preserved(self):
        linux = host_payload("linux", 20)
        linux["watchdog"] = {"consecutive_misses": 4, "restart_after": 5}
        snapshot = MODULE.build_snapshot(
            mac_payload=host_payload("mac", 4),
            linux_payload=linux,
            observed_at="2026-07-14T20:00:00Z",
            published_at="2026-07-14T20:00:05Z",
        )
        self.assertTrue(snapshot["sources"]["linux_host"]["ok"])
        self.assertEqual(
            snapshot["fleets"]["linux"]["watchdog"],
            {"consecutive_misses": 4, "restart_after": 5},
        )

    def test_cli_writes_atomically_parseable_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mac = root / "mac.json"
            linux = root / "linux.json"
            output = root / "status.json"
            mac.write_text(json.dumps(host_payload("mac", 4)))
            linux.write_text(json.dumps(host_payload("linux", 20)))
            args = [
                str(MODULE_PATH),
                "--mac-host", str(mac),
                "--linux-host", str(linux),
                "--observed-at", "2026-07-14T20:00:00Z",
                "--published-at", "2026-07-14T20:00:05Z",
                "--output", str(output),
            ]
            import subprocess

            subprocess.run(args, check=True)
            self.assertEqual(json.loads(output.read_text())["schema_version"], 1)

    def test_parked_mac_and_multi_host_slots_and_redaction(self):
        mac = host_payload("mac", 4)
        mac["fleet"].update(executing=0, idle=0, cycling=0, down=0, reserved=0)
        mac["parked"] = True
        mac["parked_slots"] = 4
        mac["parked_reason"] = "secret-suspension-bead-123"
        mac["sources"]["service"]["ok"] = False
        mac["sources"]["docker"]["ok"] = False
        mac["sources"]["process_probe"]["ok"] = False
        mac["disk"] = {"status": "healthy", "free_gb": 29.0, "floor_gb": 30}
        mac["slots"] = [
            {
                "slot_id": f"secret-mac-host-{i}",
                "slot": i,
                "state": "PARKED",
                "elapsed_minutes": None,
                "branch": "secret-branch-must-redact",
                "pr_title": "secret-pr-title",
                "actor": "secret-actor",
                "token": "ghp_secret",
                "phase_badge": "secret-freeform-phase",
            }
            for i in range(1, 5)
        ]

        linux = host_payload("linux", 20)
        linux["disk"] = {"status": "critical", "free_gb": 25.0, "floor_gb": 30}
        linux["pause_reason"] = "disk_floor_paused"
        linux["fleet"].update(executing=13, idle=0, cycling=0, down=7, reserved=20)
        linux["slots"] = [
            {
                "slot_id": f"jeff-ubuntu-slot-{i}",
                "slot": i,
                "state": "EXECUTING" if i <= 13 else "DOWN",
                "elapsed_minutes": 12.5 if i <= 13 else None,
                "repo_short": "worldarchitect.ai" if i <= 13 else None,
                "workflow_category": "tests" if i <= 13 else None,
                "phase_badge": "pytest" if i <= 13 else "disk_floor_paused",
                "head_branch": "private-branch-xyz",
            }
            for i in range(1, 21)
        ]

        cmux_payload = {
            "ok": True,
            "configured": 25,
            "executing": 21,
            "idle": 0,
            "cycling": 4,
            "down": 0,
            "vms": [
                {
                    "vm_id": "cmux-dreamy",
                    "configured": 3,
                    "executing": 2,
                    "idle": 0,
                    "cycling": 1,
                    "down": 0,
                    "disk_free_gb": 12.0,
                    "disk_floor_gb": 10,
                    "slots": [
                        {"slot_id": "cmux-dreamy-1", "state": "CYCLING", "phase_badge": "respawning"},
                        {"slot_id": "cmux-dreamy-2", "state": "EXECUTING", "elapsed_minutes": 28.0, "repo_short": "worldai_frontend", "phase_badge": "jest"},
                        {"slot_id": "cmux-dreamy-3", "state": "EXECUTING", "elapsed_minutes": 12.2, "repo_short": "worldai_frontend", "phase_badge": "jest"},
                    ],
                }
            ],
        }
        latency_payload = {
            "ok": True,
            "generated_at": "2026-11-18T09:11:59Z",
            "overall": {
                "queue_wait": {"n": 186, "avg_s": 416.0, "p50_s": 339.5, "p90_s": 874.5, "p99_s": 1502.4, "max_s": 1562.0},
                "execution": {"n": 186, "avg_s": 197.0, "p50_s": 47.0, "p90_s": 505.0, "p99_s": 1849.7, "max_s": 2078.0},
                "e2e": {"n": 174, "avg_s": 697.0, "p50_s": 453.0, "p90_s": 1561.2, "p99_s": 4198.2, "max_s": 6792.0},
            },
            "cancellation": {"cancelled_runs": 183, "total_non_skipped_runs": 381, "cancelled_rate_pct": 48.0},
            "workflows": [
                {
                    "repo": "jleechanorg/worldarchitect.ai",
                    "workflow": "Secret Project Tests",
                    "queue_wait": {"n": 32, "avg_s": 339.0, "p50_s": 323.0, "p90_s": 637.0, "p99_s": 900.0},
                    "execution": {"n": 32, "avg_s": 413.0, "p50_s": 32.5, "p90_s": 1639.0, "p99_s": 2050.0},
                    "e2e": {"n": 32, "avg_s": 752.0, "p50_s": 500.0, "p90_s": 1900.0, "p99_s": 2500.0},
                }
            ],
            "head_branch": "secret-latency-branch",
        }
        queue_payload = {
            "ok": True,
            "fresh": 50,
            "ghosts": 149,
            "oldest_fresh_wait_minutes": 42,
            "in_progress_runs": 15,
            "repos": [{"repo": "jleechanorg/worldai_frontend", "fresh": 50, "ghosts": 149}],
        }

        snapshot = MODULE.build_snapshot(
            mac_payload=mac,
            linux_payload=linux,
            observed_at="2026-11-18T09:15:00Z",
            published_at="2026-11-18T09:15:05Z",
            queue_payload=queue_payload,
            cmux_payload=cmux_payload,
            latency_payload=latency_payload,
        )
        self.assertTrue(snapshot["sources"]["mac_host"]["ok"])
        self.assertTrue(snapshot["sources"]["linux_host"]["ok"])
        self.assertTrue(snapshot["fleets"]["mac"]["parked"])
        self.assertEqual(snapshot["fleets"]["mac"]["parked_slots"], 4)
        self.assertEqual(snapshot["fleets"]["mac"]["parked_reason"], "operator_disabled")
        self.assertEqual(snapshot["fleets"]["linux"]["pause_reason"], "disk_floor_paused")
        self.assertNotIn("disk_free_gb", snapshot["fleets"]["linux"])
        self.assertNotIn("disk_free_gb", snapshot["cmux"]["vms"][0])
        self.assertEqual(snapshot["fleets"]["mac"]["slots"][0]["slot_id"], "mac-1")
        self.assertEqual(snapshot["fleets"]["linux"]["slots"][0]["slot_id"], "linux-1")
        self.assertEqual(len(snapshot["fleets"]["linux"]["slots"]), 20)
        self.assertEqual(snapshot["cmux"]["configured"], 25)
        self.assertEqual(snapshot["cmux"]["vms"][0]["vm_id"], "cloud-vm-1")
        self.assertEqual(snapshot["cmux"]["vms"][0]["slots"][0]["slot_id"], "cloud-vm-1-1")
        self.assertTrue(snapshot["latency"]["ok"])
        self.assertEqual(snapshot["latency"]["overall"]["queue_wait"]["p50_s"], 339.5)
        self.assertEqual(snapshot["latency"]["workflows"][0]["workflow"], "workflow-1")
        self.assertEqual(snapshot["reconciliation"]["active_job_slots_occupied"], 34)
        self.assertEqual(snapshot["reconciliation"]["parked_slots"], 4)
        self.assertEqual(snapshot["reconciliation"]["down_slots"], 7)
        self.assertEqual(snapshot["reconciliation"]["active_workflow_runs"], 15)

        serialized = json.dumps(snapshot)
        for secret in (
            "secret-branch-must-redact",
            "secret-pr-title",
            "secret-actor",
            "ghp_secret",
            "private-branch-xyz",
            "secret-latency-branch",
            "secret-suspension-bead-123",
            "secret-mac-host",
            "secret-freeform-phase",
            "jeff-ubuntu",
            "Secret Project Tests",
            "cmux-dreamy",
            "worldarchitect",
            "worldai_frontend",
            "disk_free_gb",
            "disk_floor_gb",
        ):
            self.assertNotIn(secret, serialized)

    def test_sanitize_rejects_non_iso_generated_at_malformed_types_and_preserves_unknown(self):
        mac = host_payload("mac", 4)
        linux = host_payload("linux", 20)
        linux["fleet"].update(configured=20, executing=19, idle=1, cycling=0, down=0, reserved=20)
        linux["slots"] = [
            {"slot": 1, "state": "BOGUS_UNKNOWN_STATE", "elapsed_minutes": 1.0},
            {"slot": 2, "state": "EXECUTING", "elapsed_minutes": 3.0},
        ]
        cmux_payload = {
            "ok": True,
            "configured": 2,
            "executing": 1,
            "idle": 1,
            "cycling": 0,
            "down": 0,
            "vms": [
                {
                    "vm_id": "cmux-bad",
                    "configured": 2,
                    "executing": 1,
                    "idle": 1,
                    "cycling": 0,
                    "down": 0,
                    "disk_status": ["unhashable"],
                    "slots": [{"slot": 1, "state": 123}],
                }
            ],
        }
        latency_payload = {
            "ok": True,
            "generated_at": "NOT_AN_ISO_TIMESTAMP secret-mac",
            "cohort": ["unhashable"],
            "overall": {},
            "cancellation": {},
            "workflows": [],
        }
        snapshot = MODULE.build_snapshot(
            mac_payload=mac,
            linux_payload=linux,
            observed_at="2026-11-18T09:15:00Z",
            published_at="2026-11-18T09:15:05Z",
            cmux_payload=cmux_payload,
            latency_payload=latency_payload,
        )
        self.assertEqual(snapshot["fleets"]["linux"]["slots"][0]["state"], "UNKNOWN")
        self.assertEqual(snapshot["cmux"]["vms"][0]["disk_status"], "unknown")
        self.assertEqual(snapshot["cmux"]["vms"][0]["slots"][0]["state"], "UNKNOWN")
        self.assertIsNone(snapshot["latency"]["generated_at"])
        self.assertIsNone(snapshot["latency"]["cohort"])
        self.assertEqual(snapshot["reconciliation"]["available_pools"], 3)
        self.assertEqual(snapshot["reconciliation"]["configured_slots"], 26)

        bad_types = MODULE.build_snapshot(
            mac_payload=mac,
            linux_payload=linux,
            observed_at="2026-11-18T09:15:00Z",
            published_at="2026-11-18T09:15:05Z",
            cmux_payload={"ok": True, "configured": 1, "executing": 0, "idle": 1, "cycling": 0, "down": 0, "vms": 5},
            latency_payload={"ok": True, "generated_at": "2026-11-18T09:15:00Z", "workflows": 5},
        )
        self.assertFalse(bad_types["cmux"]["ok"])
        self.assertEqual(bad_types["cmux"]["vms"], [])
        self.assertEqual(bad_types["reconciliation"]["available_pools"], 2)
        self.assertEqual(bad_types["reconciliation"]["configured_slots"], 24)
        self.assertEqual(bad_types["latency"]["workflows"], [])

        partial_snap = MODULE.build_snapshot(
            mac_payload=mac,
            linux_payload=linux,
            observed_at="2026-11-18T09:15:00Z",
            published_at="2026-11-18T09:15:05Z",
            queue_payload={
                "ok": True,
                "fresh": 3,
                "ghosts": 1,
                "oldest_fresh_wait_minutes": 4,
                "in_progress_runs": 2,
                "partial": True,
                "unverified_runs": 2,
            },
            latency_payload={
                "ok": True,
                "generated_at": "2026-11-18T09:15:00Z",
                "partial": True,
                "overall": {},
                "cancellation": {},
                "workflows": [],
            },
        )
        self.assertTrue(partial_snap["queue"]["partial"])
        self.assertEqual(partial_snap["queue"]["unverified_runs"], 2)
        self.assertTrue(partial_snap["latency"]["partial"])
        self.assertIn("(partial: 2 unverified)", partial_snap["reconciliation"]["explanation"])

    def test_invalid_utf8_optional_cmux_feed_degrades_gracefully(self):
        import subprocess
        import sys

        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            mac_p = tmp / "mac.json"
            linux_p = tmp / "linux.json"
            cmux_p = tmp / "cmux_bad.bin"
            out_p = tmp / "status.json"
            mac_p.write_text(json.dumps(host_payload("mac", 4)), encoding="utf-8")
            linux_p.write_text(json.dumps(host_payload("linux", 20)), encoding="utf-8")
            cmux_p.write_bytes(b"\xff\xfe\x00\x81")
            proc = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--mac-host", str(mac_p),
                    "--linux-host", str(linux_p),
                    "--observed-at", "2026-11-18T09:15:00Z",
                    "--published-at", "2026-11-18T09:15:05Z",
                    "--cmux", str(cmux_p),
                    "--output", str(out_p),
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            out = json.loads(out_p.read_text(encoding="utf-8"))
            self.assertFalse(out["cmux"]["ok"])
            self.assertEqual(out["fleets"]["linux"]["fleet"]["configured"], 20)

            # Non-finite 1e999 float and 10**309 huge-int overflow in optional feed or _opt_float must degrade cleanly with valid JSON.
            self.assertIsNone(MODULE._opt_float(float("inf")))
            self.assertIsNone(MODULE._opt_float(10**309))
            inf_cmux = tmp / "cmux_inf.json"
            inf_cmux.write_text('{"ok": true, "vms": [{"disk_free_gb": 1e999}]}', encoding="utf-8")
            out_inf = tmp / "status_inf.json"
            proc_inf = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--mac-host", str(mac_p),
                    "--linux-host", str(linux_p),
                    "--observed-at", "2026-11-18T09:15:00Z",
                    "--published-at", "2026-11-18T09:15:05Z",
                    "--cmux", str(inf_cmux),
                    "--output", str(out_inf),
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(proc_inf.returncode, 0, msg=proc_inf.stderr)
            parsed_inf = json.loads(out_inf.read_text(encoding="utf-8"))
            self.assertFalse(parsed_inf["cmux"]["ok"])

            huge_int_cmux = tmp / "cmux_huge_int.json"
            huge_int_cmux.write_text(f'{{"ok": true, "vms": [{{"disk_free_gb": {10**309}}}]}}', encoding="utf-8")
            out_huge = tmp / "status_huge.json"
            proc_huge = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--mac-host", str(mac_p),
                    "--linux-host", str(linux_p),
                    "--observed-at", "2026-11-18T09:15:00Z",
                    "--published-at", "2026-11-18T09:15:05Z",
                    "--cmux", str(huge_int_cmux),
                    "--output", str(out_huge),
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(proc_huge.returncode, 0, msg=proc_huge.stderr)
            parsed_huge = json.loads(out_huge.read_text(encoding="utf-8"))
            self.assertTrue(parsed_huge["cmux"]["ok"])
            self.assertEqual(parsed_huge["cmux"]["vms"][0]["disk_status"], "unknown")
            from unittest import mock
            with mock.patch.object(MODULE, "_opt_float", side_effect=TypeError("bad cmux shape")):
                degraded_cmux = MODULE._public_cmux({"ok": True, "vms": [{"disk_free_gb": 10}]})
            self.assertFalse(degraded_cmux["ok"])
            self.assertEqual(degraded_cmux["vms"], [])

            bad_vms_cmux = tmp / "cmux_bad_vms.json"
            bad_vms_cmux.write_text(
                '{"ok": true, "configured": 4, "executing": 0, "idle": 4, "cycling": 0, "down": 0, "vms": 5}',
                encoding="utf-8",
            )
            out_bad_vms = tmp / "status_bad_vms.json"
            proc_bad_vms = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--mac-host", str(mac_p),
                    "--linux-host", str(linux_p),
                    "--observed-at", "2026-11-18T09:15:00Z",
                    "--published-at", "2026-11-18T09:15:05Z",
                    "--cmux", str(bad_vms_cmux),
                    "--output", str(out_bad_vms),
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(proc_bad_vms.returncode, 0, msg=proc_bad_vms.stderr)
            parsed_bad_vms = json.loads(out_bad_vms.read_text(encoding="utf-8"))
            self.assertFalse(parsed_bad_vms["cmux"]["ok"])
            self.assertEqual(parsed_bad_vms["cmux"]["vms"], [])
            self.assertEqual(parsed_bad_vms["reconciliation"]["available_pools"], 2)
            self.assertEqual(parsed_bad_vms["reconciliation"]["configured_slots"], 24)


if __name__ == "__main__":
    unittest.main()
