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


if __name__ == "__main__":
    unittest.main()
