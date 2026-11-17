#!/usr/bin/env python3
"""Build the public, aggregate-only ezgha runner dashboard snapshot."""

import argparse
import json
import os
import tempfile
from pathlib import Path

SOURCE_KEYS = ("config", "service", "docker", "process_probe", "disk", "watchdog_state")
FLEET_KEYS = ("configured", "executing", "idle", "cycling", "down", "reserved")
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
    disk_status = payload.get("disk", {}).get("status")
    if disk_status not in {"healthy", "critical"}:
        disk_status = "unknown"
    consecutive = _count(payload.get("watchdog", {}).get("consecutive_misses"))
    restart_after = _count(payload.get("watchdog", {}).get("restart_after"))

    valid_counts = all(fleet[key] is not None for key in FLEET_KEYS)
    if valid_counts:
        classified = sum(
            fleet[key] for key in ("executing", "idle", "cycling", "down")
        )
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
    return {
        "sources": sources,
        "fleet": fleet,
        "disk": {"status": disk_status},
        "watchdog": {
            "consecutive_misses": consecutive,
            "restart_after": restart_after,
        },
    }, valid


def _public_queue(payload):
    """Reduce a queue probe payload to the aggregate-only public shape.

    The whole point of this section is to keep zero-job ghosts OUT of the number a
    human reads as backlog. A ghost is a queued run that owns no jobs and that GitHub
    refuses to transition (409 on cancel/force-cancel, 403 on delete), so it can never
    start and can never be cleaned up from our side. Counting it as queue depth makes
    the backlog look several times larger than the work actually waiting.

    Only aggregate counts are emitted -- no run ids, branch names, or actor names --
    because this snapshot is published to a public Pages site.
    """
    # The queue probe emits its fields at the top level; accept either that shape or
    # a nested {"queue": {...}} so a caller wrapping the payload still works.
    raw = payload.get("queue") if isinstance(payload.get("queue"), dict) else payload
    if not isinstance(raw, dict):
        return {"ok": False, "fresh": None, "ghosts": None,
                "oldest_fresh_wait_minutes": None, "repos": []}

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
        "repos": repos,
    }


def num_in(mapping, key):
    value = mapping.get(key)
    return value if type(value) is int and value >= 0 else None


def build_snapshot(*, mac_payload, linux_payload, observed_at, published_at,
                   queue_payload=None):
    mac, mac_ok = _public_host(mac_payload, "mac")
    linux, linux_ok = _public_host(linux_payload, "linux")
    queue = _public_queue(queue_payload or {})
    # NOTE: `sources` deliberately stays the two-host trust contract. The queue is a
    # separate, publicly-visible signal with its own `ok`, so a queue probe failure
    # degrades only the queue block and never invalidates host capacity. Folding it
    # into `sources` would make a queue outage fail the entire snapshot.
    return {
        # Kept at 1: the queue block is purely additive and old consumers ignore
        # unknown keys, so bumping would churn a published contract for no gain.
        # The renderer accepts 1 or 2 so a bumped snapshot would still work.
        "schema_version": 1,
        "observed_at": observed_at,
        "published_at": published_at,
        "sources": {
            "mac_host": {"ok": mac_ok},
            "linux_host": {"ok": linux_ok},
        },
        "fleets": {"mac": mac, "linux": linux},
        "queue": queue,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mac-host", required=True)
    parser.add_argument("--linux-host", required=True)
    parser.add_argument("--observed-at", required=True)
    parser.add_argument("--published-at", required=True)
    parser.add_argument("--queue", default=None,
                        help="Optional queue probe payload; omit to publish queue as unavailable")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    snapshot = build_snapshot(
        mac_payload=_load_object(args.mac_host),
        linux_payload=_load_object(args.linux_host),
        observed_at=args.observed_at,
        published_at=args.published_at,
        queue_payload=_load_object(args.queue) if args.queue else None,
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
