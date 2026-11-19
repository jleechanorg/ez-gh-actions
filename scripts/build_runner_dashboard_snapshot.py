#!/usr/bin/env python3
"""Build the public, aggregate-only ezgha runner dashboard snapshot."""

import argparse
import datetime
import json
import math
import os
import tempfile
from pathlib import Path

SOURCE_KEYS = ("config", "service", "docker", "process_probe", "disk", "watchdog_state")
FLEET_KEYS = ("configured", "executing", "idle", "cycling", "down", "reserved")
ALLOWED_SLOT_STATES = frozenset({"EXECUTING", "IDLE", "CYCLING", "DOWN", "PARKED", "OFFLINE", "UNKNOWN"})
ALLOWED_PUBLIC_PHASES = frozenset({
    "playwright",
    "playwright install",
    "jest",
    "pytest",
    "git index-pack",
    "git fetch",
    "gh api tarball",
    "npm ci",
    "pip",
    "cargo",
    "gcloud",
    "mypy",
    "shellcheck",
    "setup-python",
    "respawning",
    "operator_disabled",
    "disk_floor_paused",
    "disk_critical_with_down",
    "ci-check",
})
ALLOWED_PUBLIC_CATEGORIES = frozenset({"ci-check", "tests", "build", "deploy", "lint"})
ALLOWED_PAUSE_REASONS = frozenset({"disk_floor_paused", "disk_floor_pause", "disk_critical_with_down"})
# Must match the real fleet shapes. Stale values here make a healthy fleet render as
# STALE/UNKNOWN, which is exactly the failure the snapshot test documents as the
# EXPECTED_CONFIGURED["linux"] drift regression (16 vs the real 10).
# Current truth (2026-11-17): the Mac host config states "centralized to 4 Mac + 20
# Linux per user direction", and jeff-ubuntu runs count = 20.
EXPECTED_CONFIGURED = {"mac": 4, "linux": 20}


def _reject_non_finite(token):
    raise ValueError(f"non-finite JSON constant: {token}")


def _parse_finite_float(token):
    val = float(token)
    if not math.isfinite(val):
        raise ValueError(f"non-finite JSON float: {token}")
    return val


def _load_object(path):
    try:
        value = json.loads(
            Path(path).read_text(encoding="utf-8"),
            parse_constant=_reject_non_finite,
            parse_float=_parse_finite_float,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _count(value):
    return value if type(value) is int and value >= 0 else None


def _opt_float(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        try:
            finite = math.isfinite(value)
        except OverflowError:
            return None
        if finite and value >= 0:
            return round(float(value), 2)
    return None


def _allowlisted_str(value, allowed):
    if isinstance(value, str):
        cleaned = value.strip().lower()
        return cleaned if cleaned in allowed else None
    return None


def _anon_label(raw_value, mapping, prefix):
    if not isinstance(raw_value, str) or not raw_value.strip():
        return None
    key = raw_value.strip()
    if key not in mapping:
        mapping[key] = f"{prefix}-{len(mapping) + 1}"
    return mapping[key]


def _sanitize_slots(raw_slots, *, slot_prefix="slot"):
    if not isinstance(raw_slots, list):
        return []
    slots = []
    for idx, entry in enumerate(raw_slots, start=1):
        if not isinstance(entry, dict):
            continue
        raw_state = entry.get("state")
        state = raw_state.strip().upper() if isinstance(raw_state, str) else ""
        if state not in ALLOWED_SLOT_STATES:
            state = "UNKNOWN"
        slot_num = _count(entry.get("slot")) or idx
        slots.append({
            "slot_id": f"{slot_prefix}-{slot_num}",
            "slot": slot_num,
            "state": state,
            "elapsed_minutes": _opt_float(entry.get("elapsed_minutes")),
            "workflow_category": _allowlisted_str(entry.get("workflow_category"), ALLOWED_PUBLIC_CATEGORIES),
            "phase_badge": _allowlisted_str(entry.get("phase_badge"), ALLOWED_PUBLIC_PHASES),
        })
    return slots


def _public_host(payload, expected_class):
    raw_sources = payload.get("sources")
    sources = {
        key: {"ok": raw_sources.get(key, {}).get("ok") is True}
        for key in SOURCE_KEYS
    } if isinstance(raw_sources, dict) else {
        key: {"ok": False} for key in SOURCE_KEYS
    }
    raw_fleet = payload.get("fleet")
    fleet = {
        key: _count(raw_fleet.get(key)) for key in FLEET_KEYS
    } if isinstance(raw_fleet, dict) else {
        key: None for key in FLEET_KEYS
    }
    disk_raw = payload.get("disk") if isinstance(payload.get("disk"), dict) else {}
    disk_status = disk_raw.get("status")
    if disk_status not in {"healthy", "critical"}:
        disk_status = "unknown"

    consecutive = _count(payload.get("watchdog", {}).get("consecutive_misses"))
    restart_after = _count(payload.get("watchdog", {}).get("restart_after"))

    parked = payload.get("parked") is True
    parked_slots = _count(payload.get("parked_slots"))
    if parked and parked_slots is None:
        parked_slots = fleet["configured"] if fleet["configured"] is not None else 0
    if not parked:
        parked_slots = 0

    valid_counts = all(fleet[key] is not None for key in FLEET_KEYS)
    if valid_counts:
        classified = sum(
            fleet[key] for key in ("executing", "idle", "cycling", "down")
        ) + (parked_slots if parked else 0)
        valid_counts = (
            fleet["configured"] == EXPECTED_CONFIGURED[expected_class]
            and classified == fleet["configured"]
            and fleet["reserved"] <= fleet["configured"]
        )
    all_down = (
        valid_counts
        and fleet["configured"] > 0
        and fleet["down"] == fleet["configured"]
        and all(fleet[key] == 0 for key in ("executing", "idle", "cycling"))
    )
    parked_ok = (
        parked
        and valid_counts
        and parked_slots == fleet["configured"]
        and fleet["down"] == 0
        and all(fleet[key] == 0 for key in ("executing", "idle", "cycling"))
    )
    disk_valid = (
        sources["disk"]["ok"] and disk_status != "unknown"
    ) or (
        all_down and not sources["disk"]["ok"] and disk_status == "unknown"
    ) or (
        parked_ok
    )
    probes_ok = all(
        sources[key]["ok"]
        for key in SOURCE_KEYS
        if key not in {"disk", "watchdog_state"}
    ) or (
        parked_ok and sources["config"]["ok"]
    )
    valid = (
        payload.get("schema_version") == 1
        and payload.get("host_class") == expected_class
        and set(sources) == set(SOURCE_KEYS)
        and probes_ok
        and valid_counts
        and disk_valid
        and (
            (
                sources["watchdog_state"]["ok"]
                and consecutive is not None
                and restart_after is not None
                and restart_after > 0
            )
            or (
                not sources["watchdog_state"]["ok"]
                and consecutive is None
                and restart_after is None
            )
        )
    )
    raw_pause = _allowlisted_str(payload.get("pause_reason"), ALLOWED_PAUSE_REASONS)
    pause_reason = "disk_floor_paused" if raw_pause == "disk_floor_pause" else raw_pause
    host_out = {
        "sources": sources,
        "fleet": fleet,
        "disk": {"status": disk_status},
        "watchdog": {
            "consecutive_misses": consecutive,
            "restart_after": restart_after,
        },
        "parked": parked,
        "parked_slots": parked_slots,
        "parked_reason": "operator_disabled" if parked else None,
        "pause_reason": pause_reason,
        "slots": _sanitize_slots(payload.get("slots"), slot_prefix=expected_class),
    }
    return host_out, valid


def _public_queue(payload, repo_map):
    """Reduce a queue probe payload to the anonymized aggregate-only public shape."""
    raw = payload.get("queue") if isinstance(payload.get("queue"), dict) else payload
    if not isinstance(raw, dict):
        return {"ok": False, "fresh": None, "ghosts": None,
                "oldest_fresh_wait_minutes": None, "in_progress_runs": None, "repos": []}

    def num(key):
        value = raw.get(key)
        return value if type(value) is int and value >= 0 else None

    repos = []
    for entry in raw.get("repos") or []:
        if not isinstance(entry, dict):
            continue
        repos.append({
            "repo": _anon_label(entry.get("repo"), repo_map, "repo"),
            "fresh": num_in(entry, "fresh"),
            "ghosts": num_in(entry, "ghosts"),
        })
    return {
        "ok": raw.get("ok") is True,
        "partial": raw.get("partial") is True,
        "unverified_runs": num("unverified_runs"),
        "fresh": num("fresh"),
        "ghosts": num("ghosts"),
        "oldest_fresh_wait_minutes": num("oldest_fresh_wait_minutes"),
        "in_progress_runs": num("in_progress_runs"),
        "repos": repos,
    }


def _empty_cmux():
    return {
        "ok": False,
        "configured": None,
        "executing": None,
        "idle": None,
        "cycling": None,
        "down": None,
        "vms": [],
    }


def _public_cmux(payload):
    """Sanitize optional cmux Cloud VM pool payload (multi-host slots)."""
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        return _empty_cmux()
    try:
        vms = []
        raw_vms = payload.get("vms")
        for idx, vm in enumerate(raw_vms if isinstance(raw_vms, list) else [], start=1):
            if not isinstance(vm, dict):
                continue
            anon_vm_id = f"cloud-vm-{idx}"
            free_gb = _opt_float(vm.get("disk_free_gb"))
            floor_gb = _count(vm.get("disk_floor_gb"))
            raw_disk_status = vm.get("disk_status")
            disk_status = (
                raw_disk_status
                if isinstance(raw_disk_status, str) and raw_disk_status in {"healthy", "critical"}
                else "unknown"
            )
            if disk_status == "unknown" and free_gb is not None and floor_gb is not None:
                disk_status = "critical" if free_gb < floor_gb else "healthy"
            vms.append({
                "vm_id": anon_vm_id,
                "configured": _count(vm.get("configured")),
                "executing": _count(vm.get("executing")),
                "idle": _count(vm.get("idle")),
                "cycling": _count(vm.get("cycling")),
                "down": _count(vm.get("down")),
                "disk_status": disk_status,
                "slots": _sanitize_slots(vm.get("slots"), slot_prefix=anon_vm_id),
            })
        return {
            "ok": True,
            "configured": _count(payload.get("configured")),
            "executing": _count(payload.get("executing")),
            "idle": _count(payload.get("idle")),
            "cycling": _count(payload.get("cycling")),
            "down": _count(payload.get("down")),
            "vms": vms,
        }
    except (TypeError, ValueError, KeyError, AttributeError, IndexError, OverflowError, ArithmeticError):
        return _empty_cmux()


def _sanitize_stat_block(block):
    if not isinstance(block, dict):
        return {"n": 0, "avg_s": None, "p50_s": None, "p90_s": None, "p99_s": None, "max_s": None}
    return {
        "n": _count(block.get("n")) or 0,
        "avg_s": _opt_float(block.get("avg_s")),
        "p50_s": _opt_float(block.get("p50_s")),
        "p90_s": _opt_float(block.get("p90_s")),
        "p99_s": _opt_float(block.get("p99_s")),
        "max_s": _opt_float(block.get("max_s")),
    }


def _parse_iso_utc(raw):
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if not text or ("T" not in text and " " not in text):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _public_latency(payload, repo_map):
    """Sanitize CI latency telemetry payload (avg / p50 / p90 / p99 only)."""
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        return {"ok": False, "generated_at": None, "cohort": None, "overall": {}, "cancellation": {}, "workflows": []}

    raw_overall = payload.get("overall") if isinstance(payload.get("overall"), dict) else {}
    overall = {
        key: _sanitize_stat_block(raw_overall.get(key))
        for key in ("queue_wait", "execution", "e2e")
    }
    raw_cancel = payload.get("cancellation") if isinstance(payload.get("cancellation"), dict) else {}
    cancellation = {
        "cancelled_runs": _count(raw_cancel.get("cancelled_runs")),
        "total_non_skipped_runs": _count(raw_cancel.get("total_non_skipped_runs")),
        "cancelled_rate_pct": _opt_float(raw_cancel.get("cancelled_rate_pct")),
    }
    raw_cohort = payload.get("cohort") or raw_overall.get("cohort")
    cohort = (
        raw_cohort
        if isinstance(raw_cohort, str) and raw_cohort in {"success", "all_non_skipped", "failure", "cancelled"}
        else None
    )
    wf_map = {}
    workflows = []
    raw_workflows = payload.get("workflows")
    for wf in (raw_workflows if isinstance(raw_workflows, list) else []):
        if not isinstance(wf, dict) or not isinstance(wf.get("workflow"), str):
            continue
        anon_repo = _anon_label(wf.get("repo"), repo_map, "repo")
        anon_wf = _anon_label(f"{anon_repo or ''}//{wf.get('workflow')}", wf_map, "workflow")
        workflows.append({
            "repo": anon_repo,
            "workflow": anon_wf,
            "queue_wait": _sanitize_stat_block(wf.get("queue_wait")),
            "execution": _sanitize_stat_block(wf.get("execution")),
            "e2e": _sanitize_stat_block(wf.get("e2e")),
        })
    return {
        "ok": True,
        "partial": payload.get("partial") is True,
        "generated_at": _parse_iso_utc(payload.get("generated_at")),
        "cohort": cohort,
        "overall": overall,
        "cancellation": cancellation,
        "workflows": workflows[:15],
    }


def _build_reconciliation(mac, mac_ok, linux, linux_ok, cmux, queue):
    pools = []
    if mac_ok:
        pools.append(mac["fleet"])
    if linux_ok:
        pools.append(linux["fleet"])
    if cmux.get("ok"):
        pools.append(cmux)

    def total_of(key):
        vals = [p.get(key) for p in pools if type(p.get(key)) is int]
        return sum(vals) if vals and len(vals) == len(pools) else None

    occupied = total_of("executing")
    idle = total_of("idle")
    cycling = total_of("cycling")
    down = total_of("down")
    parked = (
        ((mac.get("parked_slots") or 0) if mac_ok else 0)
        + ((linux.get("parked_slots") or 0) if linux_ok else 0)
        if (mac_ok or linux_ok)
        else None
    )
    active_runs = queue.get("in_progress_runs")
    fresh = queue.get("fresh")
    ghosts = queue.get("ghosts")
    unverified = queue.get("unverified_runs")
    q_partial = queue.get("partial") is True

    parts = []
    if isinstance(active_runs, int) and isinstance(occupied, int):
        parts.append(f"{active_runs} active GitHub workflow runs | {occupied} occupied local runner slots")
    elif isinstance(occupied, int):
        parts.append(f"{occupied} local runner slots actively executing")
    if isinstance(down, int) and down > 0:
        parts.append(f"{down} down")
    if isinstance(parked, int) and parked > 0:
        parts.append(f"{parked} parked")
    if isinstance(cycling, int) and cycling > 0:
        parts.append(f"{cycling} cycling")
    unverified_note = (
        f"partial: {unverified} unverified"
        if isinstance(unverified, int) and unverified > 0
        else "partial"
    )
    if isinstance(fresh, int) and isinstance(ghosts, int):
        suffix = f" ({unverified_note})" if q_partial else ""
        parts.append(f"{fresh} fresh queued / {ghosts} inert ghosts{suffix}")
    elif q_partial:
        parts.append(f"queue {unverified_note}")

    return {
        "available_pools": len(pools),
        "configured_slots": total_of("configured"),
        "active_workflow_runs": active_runs,
        "active_job_slots_occupied": occupied,
        "idle_slots": idle,
        "cycling_slots": cycling,
        "down_slots": down,
        "parked_slots": parked,
        "fresh_queued_runs": fresh,
        "inert_ghosts": ghosts,
        "explanation": "; ".join(parts) + "." if parts else "Reconciliation unavailable.",
    }


def num_in(mapping, key):
    value = mapping.get(key)
    return value if type(value) is int and value >= 0 else None


def build_snapshot(*, mac_payload, linux_payload, observed_at, published_at,
                   queue_payload=None, cmux_payload=None, latency_payload=None):
    repo_map = {}
    mac, mac_ok = _public_host(mac_payload, "mac")
    linux, linux_ok = _public_host(linux_payload, "linux")
    queue = _public_queue(queue_payload or {}, repo_map)
    cmux = _public_cmux(cmux_payload or {})
    latency = _public_latency(latency_payload or {}, repo_map)
    reconciliation = _build_reconciliation(mac, mac_ok, linux, linux_ok, cmux, queue)
    # NOTE: `sources` deliberately stays the two-host trust contract. Queue, cmux, and
    # latency carry their own `ok` so an outage in one additive probe never blanks out
    # local host capacity.
    return {
        "schema_version": 1,
        "observed_at": observed_at,
        "published_at": published_at,
        "sources": {
            "mac_host": {"ok": mac_ok},
            "linux_host": {"ok": linux_ok},
        },
        "fleets": {"mac": mac, "linux": linux},
        "cmux": cmux,
        "queue": queue,
        "latency": latency,
        "reconciliation": reconciliation,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mac-host", required=True)
    parser.add_argument("--linux-host", required=True)
    parser.add_argument("--observed-at", required=True)
    parser.add_argument("--published-at", required=True)
    parser.add_argument("--queue", default=None,
                        help="Optional queue probe payload; omit to publish queue as unavailable")
    parser.add_argument("--cmux", default=None,
                        help="Optional cmux pool probe payload")
    parser.add_argument("--latency", default=None,
                        help="Optional CI latency probe payload")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    snapshot = build_snapshot(
        mac_payload=_load_object(args.mac_host),
        linux_payload=_load_object(args.linux_host),
        observed_at=args.observed_at,
        published_at=args.published_at,
        queue_payload=_load_object(args.queue) if args.queue else None,
        cmux_payload=_load_object(args.cmux) if args.cmux else None,
        latency_payload=_load_object(args.latency) if args.latency else None,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=output.parent, delete=False) as handle:
        json.dump(snapshot, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")
        temporary = handle.name
    os.replace(temporary, output)


if __name__ == "__main__":
    main()
