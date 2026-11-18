#!/usr/bin/env python3
"""Build the public, aggregate-only ezgha runner dashboard snapshot."""

import argparse
import json
import os
import tempfile
from pathlib import Path

SOURCE_KEYS = ("config", "service", "docker", "process_probe", "disk", "watchdog_state")
FLEET_KEYS = ("configured", "executing", "idle", "cycling", "down", "reserved")
ALLOWED_SLOT_STATES = frozenset({"EXECUTING", "IDLE", "CYCLING", "DOWN", "PARKED", "OFFLINE"})
# Must match the real fleet shapes. Stale values here make a healthy fleet render as
# STALE/UNKNOWN, which is exactly the failure the snapshot test documents as the
# EXPECTED_CONFIGURED["linux"] drift regression (16 vs the real 10).
# Current truth (2026-11-17): the Mac host config states "centralized to 4 Mac + 20
# Linux per user direction", and jeff-ubuntu runs count = 20.
EXPECTED_CONFIGURED = {"mac": 4, "linux": 20}


def _load_object(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _count(value):
    return value if type(value) is int and value >= 0 else None


def _opt_float(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and value >= 0:
        return round(float(value), 2)
    return None


def _opt_str(value, max_len=64):
    if isinstance(value, str):
        cleaned = value.strip()
        return cleaned[:max_len] if cleaned else None
    return None


def _sanitize_slots(raw_slots, *, slot_prefix=None):
    if not isinstance(raw_slots, list):
        return []
    slots = []
    for idx, entry in enumerate(raw_slots, start=1):
        if not isinstance(entry, dict):
            continue
        state = str(entry.get("state") or "").upper()
        if state not in ALLOWED_SLOT_STATES:
            state = "DOWN"
        slot_num = _count(entry.get("slot")) or idx
        slot_id = f"{slot_prefix}-{slot_num}" if slot_prefix else (_opt_str(entry.get("slot_id"), 48) or f"slot-{slot_num}")
        slots.append({
            "slot_id": slot_id,
            "slot": slot_num,
            "state": state,
            "elapsed_minutes": _opt_float(entry.get("elapsed_minutes")),
            "workflow_category": _opt_str(entry.get("workflow_category"), 48),
            "phase_badge": _opt_str(entry.get("phase_badge"), 48),
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
    disk_free_gb = _opt_float(payload.get("disk_free_gb") if payload.get("disk_free_gb") is not None else disk_raw.get("free_gb"))
    disk_floor_gb = _count(payload.get("disk_floor_gb") if payload.get("disk_floor_gb") is not None else disk_raw.get("floor_gb"))

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
    disk_valid = (
        sources["disk"]["ok"] and disk_status != "unknown"
    ) or (
        all_down and not sources["disk"]["ok"] and disk_status == "unknown"
    )
    valid = (
        payload.get("schema_version") == 1
        and payload.get("host_class") == expected_class
        and set(sources) == set(SOURCE_KEYS)
        and all(
            sources[key]["ok"]
            for key in SOURCE_KEYS
            if key not in {"disk", "watchdog_state"}
        )
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
        "parked_reason": _opt_str(payload.get("parked_reason"), 48) if parked else None,
        "pause_reason": _opt_str(payload.get("pause_reason"), 48),
        "disk_free_gb": disk_free_gb,
        "disk_floor_gb": disk_floor_gb,
        "slots": _sanitize_slots(payload.get("slots")),
    }
    return host_out, valid


def _public_queue(payload):
    """Reduce a queue probe payload to the aggregate-only public shape.

    The whole point of this section is to keep zero-job ghosts OUT of the number a
    human reads as backlog. A ghost is a queued run that owns no jobs and that GitHub
    refuses to transition (409 on cancel/force-cancel, 403 on delete), so it can never
    start and can never be cleaned up from our side. Counting them as queue depth makes
    the backlog look several times larger than the work actually waiting.

    Only aggregate counts are emitted -- no run ids, branch names, or actor names --
    because this snapshot is published to a public Pages site.
    """
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
            "repo": entry.get("repo") if isinstance(entry.get("repo"), str) else None,
            "fresh": num_in(entry, "fresh"),
            "ghosts": num_in(entry, "ghosts"),
        })
    return {
        "ok": raw.get("ok") is True,
        "fresh": num("fresh"),
        "ghosts": num("ghosts"),
        "oldest_fresh_wait_minutes": num("oldest_fresh_wait_minutes"),
        "in_progress_runs": num("in_progress_runs"),
        "repos": repos,
    }


def _public_cmux(payload):
    """Sanitize optional cmux Cloud VM pool payload (multi-host slots)."""
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        return {
            "ok": False,
            "configured": None,
            "executing": None,
            "idle": None,
            "cycling": None,
            "down": None,
            "vms": [],
        }
    vms = []
    for idx, vm in enumerate(payload.get("vms") or [], start=1):
        if not isinstance(vm, dict):
            continue
        anon_vm_id = f"cloud-vm-{idx}"
        vms.append({
            "vm_id": anon_vm_id,
            "configured": _count(vm.get("configured")),
            "executing": _count(vm.get("executing")),
            "idle": _count(vm.get("idle")),
            "cycling": _count(vm.get("cycling")),
            "down": _count(vm.get("down")),
            "disk_free_gb": _opt_float(vm.get("disk_free_gb")),
            "disk_floor_gb": _count(vm.get("disk_floor_gb")),
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


def _public_latency(payload):
    """Sanitize CI latency telemetry payload (avg / p50 / p90 / p99 only)."""
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        return {"ok": False, "generated_at": None, "overall": {}, "cancellation": {}, "workflows": []}

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
    workflows = []
    for wf in payload.get("workflows") or []:
        if not isinstance(wf, dict) or not isinstance(wf.get("workflow"), str):
            continue
        workflows.append({
            "repo": _opt_str(wf.get("repo"), 64),
            "workflow": _opt_str(wf.get("workflow"), 80),
            "queue_wait": _sanitize_stat_block(wf.get("queue_wait")),
            "execution": _sanitize_stat_block(wf.get("execution")),
            "e2e": _sanitize_stat_block(wf.get("e2e")),
        })
    return {
        "ok": True,
        "generated_at": _opt_str(payload.get("generated_at"), 48),
        "overall": overall,
        "cancellation": cancellation,
        "workflows": workflows[:15],
    }


def _build_reconciliation(mac, linux, cmux, queue):
    pools = [mac["fleet"], linux["fleet"]]
    if cmux.get("ok"):
        pools.append(cmux)

    def total_of(key):
        vals = [p.get(key) for p in pools if type(p.get(key)) is int]
        return sum(vals) if vals else None

    occupied = total_of("executing")
    idle = total_of("idle")
    cycling = total_of("cycling")
    down = total_of("down")
    parked = (mac.get("parked_slots") or 0) + (linux.get("parked_slots") or 0)
    active_runs = queue.get("in_progress_runs")
    fresh = queue.get("fresh")
    ghosts = queue.get("ghosts")
    fanout = (
        round(occupied / active_runs, 2)
        if isinstance(occupied, int) and isinstance(active_runs, int) and active_runs > 0
        else None
    )

    parts = []
    if isinstance(active_runs, int) and isinstance(occupied, int):
        parts.append(f"{active_runs} active workflow runs fan out across {occupied} occupied job slots")
    elif isinstance(occupied, int):
        parts.append(f"{occupied} job slots actively executing")
    if isinstance(down, int) and down > 0:
        parts.append(f"{down} down")
    if parked > 0:
        parts.append(f"{parked} parked")
    if isinstance(cycling, int) and cycling > 0:
        parts.append(f"{cycling} cycling")
    if isinstance(fresh, int) and isinstance(ghosts, int):
        parts.append(f"{fresh} fresh queued / {ghosts} inert ghosts")

    return {
        "active_workflow_runs": active_runs,
        "active_job_slots_occupied": occupied,
        "idle_slots": idle,
        "cycling_slots": cycling,
        "down_slots": down,
        "parked_slots": parked,
        "fresh_queued_runs": fresh,
        "inert_ghosts": ghosts,
        "fanout_ratio": fanout,
        "explanation": "; ".join(parts) + "." if parts else "Reconciliation unavailable.",
    }


def num_in(mapping, key):
    value = mapping.get(key)
    return value if type(value) is int and value >= 0 else None


def build_snapshot(*, mac_payload, linux_payload, observed_at, published_at,
                   queue_payload=None, cmux_payload=None, latency_payload=None):
    mac, mac_ok = _public_host(mac_payload, "mac")
    linux, linux_ok = _public_host(linux_payload, "linux")
    queue = _public_queue(queue_payload or {})
    cmux = _public_cmux(cmux_payload or {})
    latency = _public_latency(latency_payload or {})
    reconciliation = _build_reconciliation(mac, linux, cmux, queue)
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
        json.dump(snapshot, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temporary = handle.name
    os.replace(temporary, output)


if __name__ == "__main__":
    main()
