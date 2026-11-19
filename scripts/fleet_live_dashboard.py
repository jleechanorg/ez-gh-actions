#!/usr/bin/env python3
"""Local unredacted operator Fleet + Queue + CI Latency Live Dashboard.

Modes:
  1. One-shot static HTML snapshot:
       python3 scripts/fleet_live_dashboard.py --audit-dir /path/to/audit --out-html /path/to/out.html
  2. Localhost live auto-refreshing server (127.0.0.1 only):
       python3 scripts/fleet_live_dashboard.py --serve --port 8790 [--audit-dir ...]
"""

import argparse
import datetime
import html as html_lib
import http.server
import json
import os
import platform
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path

SCRIPT_DIR = str(Path(__file__).resolve().parent)
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import ci_latency_probe  # noqa: E402
import queue_probe  # noqa: E402

_LIVE_LATENCY_CACHE = {"key": None, "ts": 0.0, "data": None}
_LIVE_LATENCY_TTL_S = 300.0
MAX_LIVE_REPOS = 3


def _cap_live_repos(repos):
    raw = list(repos or [*ci_latency_probe.DEFAULT_REPOS, "jleechanorg/ez-gh-actions"])
    dedup = list(dict.fromkeys(r for r in raw if isinstance(r, str) and r.strip()))
    if len(dedup) <= MAX_LIVE_REPOS:
        return dedup, None
    dropped = dedup[MAX_LIVE_REPOS:]
    return dedup[:MAX_LIVE_REPOS], (
        f"Live GitHub scope capped at {MAX_LIVE_REPOS} of {len(dedup)} requested repos "
        f"(omitted: {', '.join(dropped)}) to stay within REST rate limits."
    )


def _load_json_checked(path, *, validator=None, invalid_reason="invalid fixture schema"):
    if not path:
        return None, None
    p = Path(path)
    try:
        if not p.is_file():
            return None, f"missing or non-file: {p}"
        data = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return None, f"expected JSON object in {p}"
        if validator is not None and not validator(data):
            return None, f"{invalid_reason} in {p}"
        return data, None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, f"{type(exc).__name__} reading {p}"


def _is_valid_hosts_payload(data):
    return isinstance(data.get("hosts"), dict)


def _is_valid_cmux_payload(data):
    return (
        isinstance(data.get("cmux_vms"), list)
        or isinstance(data.get("vms"), list)
        or data.get("ok") is False
    )


def _is_valid_gh_payload(data):
    summary = data.get("summary")
    jobs = data.get("all_in_progress_jobs")
    errors = data.get("errors")
    if "summary" in data and summary is not None and not isinstance(summary, dict):
        return False
    if isinstance(summary, dict):
        for key in (
            "total_in_progress_runs_by_repo",
            "in_progress_jobs_by_repo",
            "total_queued_runs_by_repo",
            "queued_jobs_by_repo",
        ):
            val = summary.get(key)
            if val is not None:
                if not isinstance(val, dict) or not all(
                    isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool)
                    for k, v in val.items()
                ):
                    return False
        for key in (
            "q_unverified_runs",
            "expected_repos",
            "succeeded_repos",
            "ip_expected_repos",
            "ip_succeeded_repos",
            "q_expected_repos",
            "q_succeeded_repos",
            "fresh_queued_runs",
            "inert_ghosts",
            "total_in_progress_jobs_across_org",
            "total_queued_jobs_across_org",
        ):
            val = summary.get(key)
            if val is not None and (isinstance(val, bool) or not isinstance(val, int)):
                return False
    if "all_in_progress_jobs" in data and jobs is not None:
        if not isinstance(jobs, list) or not all(isinstance(j, dict) for j in jobs):
            return False
    if errors is not None and not isinstance(errors, list):
        return False
    return isinstance(summary, dict) or isinstance(jobs, list)


def _is_valid_latency_payload(data):
    if data.get("ok") is False:
        return True
    if "overall" in data and "workflows" in data:
        if not isinstance(data["overall"], dict) or not isinstance(data["workflows"], list):
            return False
        if not all(isinstance(w, dict) for w in data["workflows"]):
            return False
        for key in ("cohorts", "runner_classes", "step_categories"):
            if data.get(key) is not None and not isinstance(data.get(key), dict):
                return False
        return True
    audit_blocks = [
        v for v in data.values()
        if isinstance(v, dict) and any(k in v for k in ("recent_contiguous_runs", "recent_runs", "job_level_audit"))
    ]
    if not audit_blocks:
        return False
    for block in audit_blocks:
        for sec_key in ("recent_contiguous_runs", "recent_runs", "job_level_audit"):
            sec = block.get(sec_key)
            if sec is None:
                continue
            if not isinstance(sec, dict):
                return False
            for dict_key in ("cohorts", "job_cohorts"):
                sub = sec.get(dict_key)
                if sub is not None and (not isinstance(sub, dict) or not all(isinstance(v, dict) for v in sub.values())):
                    return False
            by_wf = sec.get("by_workflow")
            if by_wf is not None and (not isinstance(by_wf, list) or not all(isinstance(w, dict) for w in by_wf)):
                return False
    return True


def _load_json(path):
    data, _ = _load_json_checked(path)
    return data


def _full_repo(repo):
    if not isinstance(repo, str) or not repo.strip():
        return None
    return repo.strip()


def _short_repo(repo):
    if not isinstance(repo, str) or not repo.strip():
        return None
    return repo.strip().rsplit("/", 1)[-1]


def _extract_pr_info(repo, ref, branch=None):
    full = _full_repo(repo)
    if not full or "/" not in full:
        return None, None
    for candidate in (ref, branch):
        if not isinstance(candidate, str):
            continue
        m = re.match(r"^(?:refs/pull/)?(\d+)/merge$", candidate.strip())
        if m:
            num = m.group(1)
            return f"PR #{num}", f"https://github.com/{full}/pull/{num}"
    return None, None


def _infer_phase_badge(cmds, state, reason=None):
    for cmd in cmds or []:
        matched = ci_latency_probe.classify_phase(str(cmd))
        if matched:
            return matched
    st = (state or "").upper()
    if st == "PARKED":
        return "operator_disabled"
    if st == "CYCLING":
        return "respawning"
    if st == "DOWN":
        if isinstance(reason, str) and "disk" in reason.lower():
            return "disk_floor_paused"
        return "down"
    if st == "UNKNOWN":
        return "unknown"
    if st == "OFFLINE":
        return "offline"
    if st == "IDLE":
        return "listening"
    return "running" if st == "EXECUTING" else None


def _safe_http_url(url):
    if not isinstance(url, str):
        return None
    cleaned = url.strip()
    if not cleaned or any(ch.isspace() or ord(ch) < 32 for ch in cleaned):
        return None
    if re.match(r"^https?://", cleaned, re.IGNORECASE):
        return cleaned
    return None


def _build_gh_job_index(github_data):
    by_runner = {}
    by_run_job = {}
    if not isinstance(github_data, dict):
        return by_runner, by_run_job
    jobs = github_data.get("all_in_progress_jobs")
    if not isinstance(jobs, list):
        return by_runner, by_run_job
    for job in jobs:
        if not isinstance(job, dict):
            continue
        rname = job.get("runner_name")
        if isinstance(rname, str) and rname:
            by_runner[rname] = job
        rid = job.get("run_id")
        jname = job.get("job_name")
        if isinstance(rid, (int, str)) and not isinstance(rid, bool) and rid and isinstance(jname, str) and jname:
            by_run_job[(str(rid), jname)] = job
    return by_runner, by_run_job


def _enrich_slot(slot_raw, gh_by_runner, gh_by_run_job, host_disk_paused=False):
    if not isinstance(slot_raw, dict):
        raise ValueError(f"slot row must be object, got {type(slot_raw).__name__}")
    raw_name = slot_raw.get("name")
    if raw_name is not None and not isinstance(raw_name, str):
        raise ValueError(f"slot name must be string, got {type(raw_name).__name__}")
    raw_slot = slot_raw.get("slot")
    if raw_slot is not None and not isinstance(raw_slot, (str, int)):
        raise ValueError(f"slot identifier must be string/int, got {type(raw_slot).__name__}")
    name = raw_name if (isinstance(raw_name, str) and raw_name) else f"slot-{raw_slot if raw_slot is not None else '?'}"
    raw_state = slot_raw.get("state")
    if raw_state is not None and not isinstance(raw_state, str):
        raise ValueError(f"slot state must be string, got {type(raw_state).__name__}")
    state = (raw_state or "DOWN").upper()
    if state == "STARTING_OR_CYCLING":
        state = "CYCLING"
    gh_match = slot_raw.get("github_match") if isinstance(slot_raw.get("github_match"), dict) else None
    gh_live = gh_by_runner.get(name)

    repo = (
        slot_raw.get("repository")
        or slot_raw.get("repo")
        or (gh_match or {}).get("repo")
        or (gh_live or {}).get("repo")
    )
    full_repo = _full_repo(repo)
    raw_run_id = slot_raw.get("run_id") or (gh_live or {}).get("run_id")
    run_id = raw_run_id if isinstance(raw_run_id, (int, str)) and not isinstance(raw_run_id, bool) else None
    raw_job_display = (
        slot_raw.get("job_display_name")
        or (gh_match or {}).get("job_name")
        or (gh_live or {}).get("job_name")
    )
    job_display = raw_job_display if isinstance(raw_job_display, str) else None
    if not gh_live and run_id and job_display:
        gh_live = gh_by_run_job.get((str(run_id), job_display))

    workflow = (
        slot_raw.get("workflow")
        or (gh_match or {}).get("run_name")
        or (gh_live or {}).get("run_name")
    )
    if workflow is not None and not isinstance(workflow, str):
        workflow = str(workflow)
    run_url = _safe_http_url(
        slot_raw.get("run_url")
        or (gh_match or {}).get("run_html_url")
        or (gh_live or {}).get("run_html_url")
    )
    if not run_url and full_repo and run_id:
        run_url = _safe_http_url(f"https://github.com/{full_repo}/actions/runs/{run_id}")

    job_url = _safe_http_url(
        (gh_match or {}).get("html_url")
        or (gh_live or {}).get("html_url")
    )
    if not job_url and full_repo and run_id and isinstance((gh_live or {}).get("job_id"), (int, str)):
        job_url = _safe_http_url(f"https://github.com/{full_repo}/actions/runs/{run_id}/job/{gh_live['job_id']}")

    ref = slot_raw.get("ref") or slot_raw.get("head_ref")
    head_branch = (gh_live or {}).get("head_branch") or slot_raw.get("head_ref")
    pr_label, pr_url = _extract_pr_info(full_repo, ref, head_branch)
    pr_url = _safe_http_url(pr_url)

    raw_elapsed = slot_raw.get("elapsed_minutes")
    if raw_elapsed is not None:
        if isinstance(raw_elapsed, bool) or not isinstance(raw_elapsed, (int, float)):
            raise ValueError(f"slot elapsed_minutes must be numeric, got {type(raw_elapsed).__name__}")
        elapsed_min = raw_elapsed
    else:
        raw_etimes = slot_raw.get("worker_etimes_sec")
        if raw_etimes is not None:
            if isinstance(raw_etimes, bool) or not isinstance(raw_etimes, (int, float)):
                raise ValueError(f"slot worker_etimes_sec must be numeric, got {type(raw_etimes).__name__}")
            elapsed_min = round(raw_etimes / 60.0, 1)
        else:
            elapsed_min = None

    raw_cmds = (
        slot_raw.get("active_child_commands")
        or slot_raw.get("active_child_cmds")
        or slot_raw.get("interesting_child_cmds")
        or []
    )
    if not isinstance(raw_cmds, list):
        raw_cmds = []
    cmds = [
        c for c in raw_cmds
        if "run-helper.sh" not in str(c) and "run.sh --jitconfig" not in str(c) and "Runner.Listener" not in str(c)
    ]
    reason = slot_raw.get("down_reason") or slot_raw.get("reason") or slot_raw.get("note") or slot_raw.get("idle_note")
    if state == "DOWN" and host_disk_paused and not reason:
        reason = "respawn blocked by disk-floor admission pause"
    phase_badge = _infer_phase_badge(cmds, state, reason)

    alert_level = "ok"
    if state in ("DOWN", "OFFLINE"):
        alert_level = "critical"
    elif state in ("CYCLING", "IDLE"):
        alert_level = "warn"
    elif state == "PARKED":
        alert_level = "parked"

    return {
        "name": name,
        "slot": slot_raw.get("slot"),
        "state": state,
        "alert_level": alert_level,
        "phase_badge": phase_badge,
        "elapsed_minutes": elapsed_min,
        "repo": full_repo,
        "repo_short": _short_repo(full_repo),
        "workflow": workflow,
        "job_name": job_display,
        "run_id": run_id,
        "run_url": run_url,
        "job_url": job_url,
        "pr_label": pr_label,
        "pr_url": pr_url,
        "ref": head_branch or ref,
        "commands": [str(c)[:180] for c in cmds[:4]],
        "reason": reason,
        "labels": slot_raw.get("labels") if isinstance(slot_raw.get("labels"), list) else [],
    }


def _record_norm_error(errors, msg):
    if errors is not None:
        errors.append(msg)


def _as_dict(val, label, errors):
    if val is None:
        return {}
    if isinstance(val, dict):
        return val
    _record_norm_error(errors, f"{label}: expected object, got {type(val).__name__}")
    return {}


def _as_list(val, label, errors):
    if val is None:
        return []
    if isinstance(val, list):
        return val
    _record_norm_error(errors, f"{label}: expected list, got {type(val).__name__}")
    return []


def _as_dict_list(val, label, errors):
    items = _as_list(val, label, errors)
    valid = [item for item in items if isinstance(item, dict)]
    if len(valid) != len(items):
        _record_norm_error(errors, f"{label}: ignored {len(items) - len(valid)} non-object row(s)")
    return valid


def _safe_enrich_slot(slot_raw, gh_by_runner, gh_by_run_job, *, host_disk_paused=False, label="slot", errors=None):
    try:
        return _enrich_slot(slot_raw, gh_by_runner, gh_by_run_job, host_disk_paused=host_disk_paused)
    except (TypeError, ValueError, KeyError, AttributeError, IndexError) as exc:
        _record_norm_error(errors, f"{label}: {exc}")
        return None


def _normalize_hosts(hosts_data, cmux_data, gh_data, errors=None):
    gh_by_runner, gh_by_run_job = _build_gh_job_index(gh_data)
    hosts = []
    seen_slot_names = set()

    raw_hosts = _as_dict((hosts_data or {}).get("hosts"), "hosts", errors)
    for host_key, ju in raw_hosts.items():
        if host_key == "mac":
            continue
        if not isinstance(ju, dict):
            _record_norm_error(errors, f"hosts.{host_key}: expected object, got {type(ju).__name__}")
            continue
        try:
            disk = _as_dict(ju.get("disk"), f"hosts.{host_key}.disk", errors)
            mem = _as_dict(ju.get("memory"), f"hosts.{host_key}.memory", errors)
            load = _as_list(ju.get("load_average"), f"hosts.{host_key}.load_average", errors)
            contributors = _as_list(ju.get("disk_pressure_contributors"), f"hosts.{host_key}.disk_pressure_contributors", errors)
            paused = "PAUSED" in str(ju.get("admission_status") or "").upper()
            slots = []
            for s in _as_dict_list(ju.get("slots"), f"hosts.{host_key}.slots", errors):
                enriched = _safe_enrich_slot(
                    s, gh_by_runner, gh_by_run_job, host_disk_paused=paused, label=f"hosts.{host_key}.slots", errors=errors
                )
                if enriched is not None:
                    slots.append(enriched)
                    seen_slot_names.add(enriched["name"])
            cfg_slots = ju.get("configured_slots")
            if not isinstance(cfg_slots, int) or isinstance(cfg_slots, bool):
                cfg_slots = len(slots)
            hosts.append({
                "id": str(host_key),
                "title": ju.get("display_name") or f"{host_key} (Bare-Metal Linux X64)",
                "group": ju.get("group") or "jeff-ubuntu",
                "status": ju.get("admission_status") or ju.get("ezgha_service_status") or "active",
                "alert_message": ju.get("admission_message"),
                "contributors": contributors,
                "vitals": {
                    "load": ", ".join(str(x) for x in load) if load else None,
                    "mem": f"{mem.get('used', '?')}/{mem.get('total', '?')} (swap {mem.get('swap_used', '?')})" if mem else None,
                    "disk": f"{disk.get('avail', '?')} free ({disk.get('use_pct', '?')} used, floor {disk.get('min_free_disk_gb_floor', '?')}G)" if disk else None,
                },
                "configured": cfg_slots,
                "slots": slots,
            })
        except (TypeError, ValueError, KeyError, AttributeError, IndexError) as exc:
            _record_norm_error(errors, f"hosts.{host_key}: {exc}")

    if isinstance(cmux_data, dict):
        vms_raw = cmux_data.get("cmux_vms") if cmux_data.get("cmux_vms") is not None else cmux_data.get("vms")
        vms = _as_dict_list(vms_raw, "cmux.vms", errors)
        for vm in vms:
            try:
                short = vm.get("short") or vm.get("slug") or vm.get("id")
                cfg_raw = vm.get("ezgha_config") if vm.get("ezgha_config") is not None else vm.get("config")
                cfg = _as_dict(cfg_raw, "cmux.vm.config", errors)
                disk = _as_dict(vm.get("disk"), "cmux.vm.disk", errors)
                mem = _as_dict(vm.get("memory"), "cmux.vm.memory", errors)
                disk_str = (
                    f"{disk.get('avail_gb', '?')}G/{disk.get('total_gb', '?')}G free ({disk.get('use_pct', '?')}, floor {cfg.get('min_free_disk_gb', '?')}G)"
                    if disk
                    else vm.get("df_root") or None
                )
                mem_str = (
                    f"{mem.get('used_mb', '?')}/{mem.get('total_mb', '?')} MiB"
                    if mem
                    else vm.get("mem") or None
                )
                slots = []
                for s in _as_dict_list(vm.get("slots"), "cmux.vm.slots", errors):
                    enriched = _safe_enrich_slot(
                        s, gh_by_runner, gh_by_run_job, host_disk_paused=False, label="cmux.vm.slots", errors=errors
                    )
                    if enriched is not None:
                        slots.append(enriched)
                        seen_slot_names.add(enriched["name"])
                raw_mem_mb = vm.get("memory_mb")
                mem_gib = (
                    round(raw_mem_mb / 1024, 1)
                    if isinstance(raw_mem_mb, (int, float)) and not isinstance(raw_mem_mb, bool)
                    else "?"
                )
                cfg_count = cfg.get("count")
                if not isinstance(cfg_count, int) or isinstance(cfg_count, bool):
                    cfg_count = len(slots)
                hosts.append({
                    "id": short if isinstance(short, (str, int)) else str(short),
                    "title": f"{short} ({vm.get('display_name') or vm.get('slug') or vm.get('id')})",
                    "group": "cmux",
                    "status": vm.get("status") or "running",
                    "alert_message": None,
                    "contributors": [],
                    "vitals": {
                        "load": vm.get("load_avg") or vm.get("uptime"),
                        "mem": mem_str,
                        "disk": disk_str,
                        "spec": f"{vm.get('vcpus', '?')} vCPU / {mem_gib} GiB",
                    },
                    "configured": cfg_count,
                    "slots": slots,
                })
            except (TypeError, ValueError, KeyError, AttributeError, IndexError) as exc:
                _record_norm_error(errors, f"cmux.vm: {exc}")

    mac_raw = raw_hosts.get("mac")
    if mac_raw is not None and not isinstance(mac_raw, dict):
        _record_norm_error(errors, f"hosts.mac: expected object, got {type(mac_raw).__name__}")
    elif isinstance(mac_raw, dict):
        try:
            mac = mac_raw
            disk = _as_dict(mac.get("disk"), "hosts.mac.disk", errors)
            load = _as_list(mac.get("load_average"), "hosts.mac.load_average", errors)
            c_slots = [
                enriched
                for s in _as_dict_list(mac.get("container_slots"), "hosts.mac.container_slots", errors)
                for enriched in [
                    _safe_enrich_slot(s, gh_by_runner, gh_by_run_job, label="hosts.mac.container_slots", errors=errors)
                ]
                if enriched is not None
            ]
            n_slots = [
                enriched
                for s in _as_dict_list(mac.get("native_runners"), "hosts.mac.native_runners", errors)
                for enriched in [
                    _safe_enrich_slot(
                        {
                            **s,
                            "slot": s.get("name"),
                            "down_reason": s.get("idle_note") or s.get("last_job"),
                        },
                        gh_by_runner,
                        gh_by_run_job,
                        label="hosts.mac.native_runners",
                        errors=errors,
                    )
                ]
                if enriched is not None
            ]
            all_mac_slots = c_slots + n_slots
            for s in all_mac_slots:
                seen_slot_names.add(s["name"])
            launchd_state = str(mac.get("ezgha_launchd_status") or "").lower()
            has_active_containers = any(s["state"] in ("EXECUTING", "IDLE", "CYCLING") for s in c_slots)
            explicit_parked = (
                mac.get("parked") is True
                or launchd_state == "parked"
                or (bool(c_slots) and all(s["state"] == "PARKED" for s in c_slots))
            )
            mac_parked = not has_active_containers and explicit_parked
            mac_unhealthy = not has_active_containers and not mac_parked
            mac_title = (
                "macOS (Containers PARKED + Native Runners)"
                if mac_parked
                else ("macOS (Containers DOWN / Unreachable + Native Runners)" if mac_unhealthy else "macOS (Containers Active + Native Runners)")
            )
            mac_status = (
                f"containers {mac.get('ezgha_launchd_status', 'disabled')} (PARKED)"
                if mac_parked
                else (
                    f"containers {mac.get('ezgha_launchd_status', 'inactive')} (UNHEALTHY/DOWN)"
                    if mac_unhealthy
                    else f"containers {mac.get('ezgha_launchd_status', 'active')}"
                )
            )
            mac_alert = (
                mac.get("parked_note") or "ezgha launchd container service disabled; native runners remain active."
                if mac_parked
                else (
                    "Mac container runners are inactive/down with MAC_RUNNER_DISABLED unset (unintended outage or Colima unreachable)."
                    if mac_unhealthy
                    else None
                )
            )
            cfg_mac_c = mac.get("configured_container_slots")
            if not isinstance(cfg_mac_c, int) or isinstance(cfg_mac_c, bool):
                cfg_mac_c = len(c_slots)
            hosts.append({
                "id": "mac",
                "title": mac_title,
                "group": "mac",
                "status": mac_status,
                "alert_message": mac_alert,
                "contributors": [],
                "vitals": {
                    "load": ", ".join(str(x) for x in load) if load else None,
                    "disk": f"{disk.get('root_avail', '?')} free (floor {disk.get('min_free_disk_gb_floor', '?')}G)" if disk else None,
                    "colima": mac.get("colima_status"),
                },
                "configured": cfg_mac_c + len(n_slots),
                "slots": all_mac_slots,
            })
        except (TypeError, ValueError, KeyError, AttributeError, IndexError) as exc:
            _record_norm_error(errors, f"hosts.mac: {exc}")

    # Include any special org runners (e.g. jeff-ubuntu-smtp-egress, mac-smtp-egress) not already listed
    fleet_summary = _as_dict((cmux_data or {}).get("fleet_summary") if isinstance(cmux_data, dict) else None, "cmux.fleet_summary", errors)
    special = _as_dict_list(fleet_summary.get("special_runners"), "cmux.fleet_summary.special_runners", errors)
    extra_slots = []
    for sp in special:
        name = sp.get("name")
        if not isinstance(name, str) or not name:
            _record_norm_error(errors, "cmux.fleet_summary.special_runners: invalid runner name")
            continue
        if name in seen_slot_names:
            continue
        enriched = _safe_enrich_slot(
            {
                "name": name,
                "slot": sp.get("host") or "special",
                "state": sp.get("state") or "OFFLINE",
                "job_display_name": sp.get("job"),
                "reason": sp.get("reason") or sp.get("scope"),
            },
            gh_by_runner,
            gh_by_run_job,
            label="cmux.fleet_summary.special_runners",
            errors=errors,
        )
        if enriched is not None:
            seen_slot_names.add(name)
            extra_slots.append(enriched)
    if extra_slots:
        hosts.append({
            "id": "special-runners",
            "title": "Special & Egress Runners",
            "group": "special",
            "status": "mixed",
            "alert_message": None,
            "contributors": [],
            "vitals": {},
            "configured": len(extra_slots),
            "slots": extra_slots,
        })

    return hosts


def _opt_int(val, label, errors):
    if val is None:
        return None
    if isinstance(val, int) and not isinstance(val, bool):
        return val
    _record_norm_error(errors, f"{label}: expected int, got {type(val).__name__}")
    return None


def _clean_int_map(mapping, label, errors):
    if mapping is None:
        return {}
    if not isinstance(mapping, dict):
        _record_norm_error(errors, f"{label}: expected object, got {type(mapping).__name__}")
        return {}
    cleaned = {}
    for k, v in mapping.items():
        if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool):
            cleaned[k] = v
        else:
            _record_norm_error(errors, f"{label}.{k}: expected int count, got {type(v).__name__}")
    return cleaned


def _normalize_reconciliation(hosts, cmux_data, gh_data, scope_note=None, hosts_partial=False, fixture_errors=None, errors=None):
    state_counts = {
        "EXECUTING": 0,
        "CYCLING": 0,
        "IDLE": 0,
        "DOWN": 0,
        "PARKED": 0,
        "OFFLINE": 0,
        "UNKNOWN": 0,
    }
    total_slots = 0
    for h in hosts:
        for s in h["slots"]:
            total_slots += 1
            st = s["state"]
            state_counts[st] = state_counts.get(st, 0) + 1

    rec_raw = (cmux_data or {}).get("github_reconciliation") if isinstance(cmux_data, dict) else None
    rec = _as_dict(rec_raw, "cmux.github_reconciliation", errors)
    gh_summary_raw = (gh_data or {}).get("summary") if isinstance(gh_data, dict) else None
    gh_summary = _as_dict(gh_summary_raw, "github.summary", errors)

    def _pick_int_map(rec_key, gh_key):
        if rec.get(rec_key) is not None:
            cleaned = _clean_int_map(rec.get(rec_key), f"cmux.github_reconciliation.{rec_key}", errors)
            if cleaned:
                return cleaned
        if gh_summary.get(gh_key) is not None:
            return _clean_int_map(gh_summary.get(gh_key), f"github.summary.{gh_key}", errors)
        return {}

    ip_runs_by_repo = _pick_int_map("in_progress_runs_by_repo", "total_in_progress_runs_by_repo")
    ip_jobs_by_repo = _pick_int_map("in_progress_jobs_by_repo", "in_progress_jobs_by_repo")
    q_runs_by_repo = _pick_int_map("queued_runs_by_repo", "total_queued_runs_by_repo")
    q_jobs_by_repo = _pick_int_map("queued_jobs_by_repo", "queued_jobs_by_repo")
    wa_q_raw = rec.get("worldarchitect_queued_breakdown")
    if wa_q_raw is None:
        wa_q = next(
            (v for k, v in rec.items() if isinstance(k, str) and k.endswith("_queued_breakdown") and isinstance(v, dict)),
            {},
        )
    else:
        wa_q = _as_dict(wa_q_raw, "cmux.github_reconciliation.queued_breakdown", errors)

    def _sum_ints(mapping):
        vals = [v for v in mapping.values() if isinstance(v, int) and not isinstance(v, bool)]
        return sum(vals) if vals else None

    total_ip_runs = _sum_ints(ip_runs_by_repo) if ip_runs_by_repo else None
    total_ip_jobs = _sum_ints(ip_jobs_by_repo) if ip_jobs_by_repo else _opt_int(gh_summary.get("total_in_progress_jobs_across_org"), "github.summary.total_in_progress_jobs_across_org", errors)
    total_q_runs = _sum_ints(q_runs_by_repo) if q_runs_by_repo else None
    total_q_jobs = _sum_ints(q_jobs_by_repo) if q_jobs_by_repo else _opt_int(gh_summary.get("total_queued_jobs_across_org"), "github.summary.total_queued_jobs_across_org", errors)
    why_few = (cmux_data or {}).get("why_worldarchitect_shows_few_in_progress_runs") if isinstance(cmux_data, dict) else None
    fallback_headlines = why_few.get("headline_points") if isinstance(why_few, dict) and isinstance(why_few.get("headline_points"), list) else []
    headlines = next(
        (
            v.get("headline_points")
            for k, v in (cmux_data.items() if isinstance(cmux_data, dict) else ())
            if isinstance(k, str) and k.endswith("_in_progress_runs") and isinstance(v, dict) and isinstance(v.get("headline_points"), list)
        ),
        None,
    ) or fallback_headlines

    fresh_q = _opt_int(wa_q.get("queued_runs_with_jobs"), "queued_breakdown.queued_runs_with_jobs", errors)
    if fresh_q is None:
        fresh_q = _opt_int(gh_summary.get("fresh_queued_runs"), "github.summary.fresh_queued_runs", errors)
    ghost_q = _opt_int(wa_q.get("queued_runs_zero_jobs"), "queued_breakdown.queued_runs_zero_jobs", errors)
    if ghost_q is None:
        ghost_q = _opt_int(gh_summary.get("inert_ghosts"), "github.summary.inert_ghosts", errors)

    fresh_scope = None
    total_q_api = _opt_int(wa_q.get("total_queued_runs_api"), "queued_breakdown.total_queued_runs_api", errors)
    if total_q_api is not None and isinstance(total_q_runs, int) and total_q_api < total_q_runs:
        fresh_scope = f"subset ({total_q_api} of {total_q_runs} queued runs)"

    raw_gh_errors = (gh_data or {}).get("errors") if isinstance(gh_data, dict) else None
    gh_errors = list(raw_gh_errors) if isinstance(raw_gh_errors, list) else []
    if errors:
        gh_errors.extend(errors)
    if "ip_partial" in gh_summary:
        ip_partial = bool(gh_summary.get("ip_partial"))
        ip_exp = _opt_int(gh_summary.get("ip_expected_repos"), "github.summary.ip_expected_repos", errors)
        ip_succ = _opt_int(gh_summary.get("ip_succeeded_repos"), "github.summary.ip_succeeded_repos", errors)
    else:
        ip_exp = _opt_int(gh_summary.get("expected_repos"), "github.summary.expected_repos", errors)
        ip_succ = _opt_int(gh_summary.get("succeeded_repos"), "github.summary.succeeded_repos", errors)
        ip_partial = bool(gh_summary.get("partial") or gh_errors)
    if errors:
        ip_partial = True
    repos_covered = (
        f"{ip_succ}/{ip_exp}"
        if isinstance(ip_exp, int) and isinstance(ip_succ, int)
        else None
    )
    q_unverified_runs = _opt_int(gh_summary.get("q_unverified_runs"), "github.summary.q_unverified_runs", errors) or 0
    q_partial = bool(gh_summary.get("q_partial") or q_unverified_runs > 0 or errors)
    q_exp = _opt_int(gh_summary.get("q_expected_repos"), "github.summary.q_expected_repos", errors)
    q_succ = _opt_int(gh_summary.get("q_succeeded_repos"), "github.summary.q_succeeded_repos", errors)
    q_repos_covered = f"{q_succ}/{q_exp}" if isinstance(q_exp, int) and isinstance(q_succ, int) else None

    return {
        "total_slots": total_slots,
        "state_counts": state_counts,
        "active_workflow_runs": total_ip_runs,
        "active_github_jobs": total_ip_jobs,
        "active_runs_partial": ip_partial,
        "hosts_partial": bool(hosts_partial),
        "repos_covered": repos_covered,
        "queue_partial": q_partial,
        "q_repos_covered": q_repos_covered,
        "q_unverified_runs": q_unverified_runs,
        "fresh_queued_scope": fresh_scope,
        "scope_note": scope_note,
        "fixture_errors": list(fixture_errors or []),
        "queued_runs_total": total_q_runs,
        "queued_jobs_total": total_q_jobs,
        "fresh_queued_runs": fresh_q,
        "inert_ghosts": ghost_q,
        "queued_sample_note": gh_summary.get("queued_sample_note"),
        "in_progress_runs_by_repo": ip_runs_by_repo,
        "in_progress_jobs_by_repo": ip_jobs_by_repo,
        "queued_runs_by_repo": q_runs_by_repo,
        "queued_jobs_by_repo": q_jobs_by_repo,
        "headline_points": headlines,
        "api_runners_count": rec.get("github_org_runners_api_count") or (gh_data or {}).get("org_runners_api_count"),
        "api_blindspot_note": rec.get("github_api_blindspot_note"),
        "gh_errors": gh_errors,
    }


def _normalize_latency(latency_raw, errors=None):
    empty_err = lambda msg: {
        "schema_version": 1,
        "ok": False,
        "error": msg,
        "overall": {},
        "cohorts": {},
        "workflows": [],
        "runner_classes": {},
        "step_categories": {},
    }
    if not isinstance(latency_raw, dict):
        msg = f"latency fixture expected object, got {type(latency_raw).__name__}"
        _record_norm_error(errors, msg)
        return empty_err(msg)
    try:
        if "overall" in latency_raw and "workflows" in latency_raw:
            out = latency_raw
        else:
            out = ci_latency_probe.from_audit_data(latency_raw)
        if not isinstance(out, dict):
            raise ValueError(f"latency normalizer returned {type(out).__name__}")
        for dict_k in ("overall", "cohorts", "runner_classes", "step_categories"):
            val = out.get(dict_k)
            if val is not None and not isinstance(val, dict):
                raise ValueError(f"latency.{dict_k} must be dict, got {type(val).__name__}")
        wfs = out.get("workflows")
        if wfs is not None and (not isinstance(wfs, list) or not all(isinstance(w, dict) for w in wfs)):
            raise ValueError("latency.workflows must be list of objects")
        return out
    except (TypeError, ValueError, KeyError, AttributeError, IndexError) as exc:
        msg = f"latency fixture invalid schema: {exc}"
        _record_norm_error(errors, msg)
        return empty_err(msg)


def _read_local_ezgha_config(config_path=None):
    path = Path(config_path) if config_path else (Path.home() / ".config" / "ezgha" / "config.toml")
    if not path.is_file():
        return {"count": None, "name_prefix": None, "min_free_disk_gb": None}
    section = None
    out = {"count": None, "name_prefix": None, "min_free_disk_gb": None}
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            if "=" not in line:
                continue
            key, val = [part.strip() for part in line.split("=", 1)]
            if section == "runner" and key == "count" and val.isdigit():
                out["count"] = int(val)
            elif section == "runner" and key == "name_prefix":
                out["name_prefix"] = val.strip().strip('"').strip("'")
            elif section == "limits" and key == "min_free_disk_gb" and val.isdigit():
                out["min_free_disk_gb"] = int(val)
    except OSError:
        pass
    return out


def _probe_local_service_status(is_mac):
    try:
        if is_mac:
            proc = subprocess.run(["launchctl", "list"], capture_output=True, text=True, timeout=5)
            if proc.returncode != 0:
                return "unknown"
            for line in proc.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[2] == "org.jleechanorg.ezgha":
                    if parts[0].isdigit():
                        return "active"
                    return "failed" if parts[1].isdigit() and int(parts[1]) != 0 else "inactive"
            return "not-loaded"
        proc = subprocess.run(
            ["systemctl", "--user", "is-active", "ezgha.service"],
            capture_output=True, text=True, timeout=5,
        )
        return proc.stdout.strip() or ("active" if proc.returncode == 0 else "inactive")
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def _parse_ps_etime_minutes(raw):
    """Parse BSD/POSIX `ps -o etime` (`[[dd-]hh:]mm:ss`) or integer seconds into minutes."""
    text = str(raw or "").strip()
    if not text:
        return None
    if text.isdigit():
        return round(int(text) / 60.0, 1)
    days = 0
    if "-" in text:
        d_part, text = text.split("-", 1)
        if not d_part.isdigit():
            return None
        days = int(d_part)
    parts = text.split(":")
    if not all(p.isdigit() for p in parts):
        return None
    if len(parts) == 2:
        hours, mins, secs = 0, int(parts[0]), int(parts[1])
    elif len(parts) == 3:
        hours, mins, secs = int(parts[0]), int(parts[1]), int(parts[2])
    else:
        return None
    total_s = (((days * 24) + hours) * 60 + mins) * 60 + secs
    return round(total_s / 60.0, 1)


def _collect_local_native_runners():
    """Discover non-Docker native GitHub Actions runner processes running on macOS/Linux."""
    native = []
    is_mac = platform.system().lower() == "darwin"
    cmd = ["ps", "-axo", "pid=,etime=,args="] if is_mac else ["ps", "-eo", "pid=,etimes=,args="]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if proc.returncode != 0:
            return native
        by_dir = {}
        for line in proc.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 3:
                continue
            elapsed_raw, argv_str = parts[1], parts[2]
            if "/home/runner/" in argv_str:
                continue
            m = re.match(r"(/[^\s]+?)/bin(?:\.[\d.]+)?/(Runner\.(?:Listener|Worker))(?:\s|$)", argv_str.strip())
            if not m:
                continue
            root_dir, runner_proc = m.group(1), m.group(2)
            name = Path(root_dir).name or "mac-native-runner"
            entry = by_dir.setdefault(name, {"name": name, "state": "IDLE", "elapsed_minutes": None, "active_child_commands": []})
            if runner_proc == "Runner.Worker":
                entry["state"] = "EXECUTING"
                parsed_min = _parse_ps_etime_minutes(elapsed_raw)
                if parsed_min is not None:
                    entry["elapsed_minutes"] = parsed_min
            entry["active_child_commands"].append(argv_str[:160])
        native = list(by_dir.values())
    except (OSError, subprocess.TimeoutExpired):
        pass
    return native


def _collect_local_host_slots():
    """Collect real local ezgha runner slots via docker ps/top when no audit-dir is supplied."""
    now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    hostname = socket.gethostname()
    is_mac = platform.system().lower() == "darwin"
    host_key = "mac" if is_mac else hostname
    cfg = _read_local_ezgha_config()
    service_status = _probe_local_service_status(is_mac)
    mac_disabled = is_mac and (
        os.environ.get("MAC_RUNNER_DISABLED") == "1"
        or os.environ.get("EZGHA_DASHBOARD_MAC_DISABLED") == "1"
    )

    disk_info = {}
    try:
        usage = shutil.disk_usage("/")
        free_gb = round(usage.free / (1024 ** 3), 1)
        total_gb = round(usage.total / (1024 ** 3), 1)
        use_pct = f"{round((usage.used / usage.total) * 100)}%" if usage.total else "?"
        disk_info = {
            "avail": f"{free_gb}G",
            "total": f"{total_gb}G",
            "use_pct": use_pct,
            "min_free_disk_gb_floor": cfg["min_free_disk_gb"] if cfg["min_free_disk_gb"] is not None else "unknown",
        }
        if is_mac:
            disk_info["root_avail"] = f"{free_gb}G"
    except OSError:
        pass

    load_vals = []
    try:
        load_vals = [round(x, 2) for x in os.getloadavg()]
    except OSError:
        pass

    observed_by_name = {}
    ordered_names = []
    docker_ok = True
    try:
        proc = subprocess.run(
            ["docker", "ps", "-a", "--filter", "label=ezgha=managed", "--format", "{{.Names}}\t{{.Status}}"],
            capture_output=True, text=True, timeout=5,
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.split("\t", 1)
                cname = parts[0].strip()
                cstatus = parts[1].strip() if len(parts) > 1 else ""
                state = "DOWN"
                cmds = []
                elapsed_min = None
                reason = None
                if cstatus.lower().startswith("up"):
                    try:
                        top = subprocess.run(
                            ["docker", "top", cname, "-eo", "pid,etimes,comm,args"],
                            capture_output=True, text=True, timeout=5,
                        )
                    except (OSError, subprocess.TimeoutExpired):
                        top = None
                    if top is not None and top.returncode == 0:
                        has_worker = False
                        has_listener = False
                        for tline in top.stdout.splitlines()[1:]:
                            tparts = tline.strip().split(None, 3)
                            if len(tparts) < 3:
                                continue
                            proc_name = tparts[2].rsplit("/", 1)[-1]
                            if proc_name == "Runner.Worker":
                                has_worker = True
                                if tparts[1].isdigit():
                                    elapsed_min = round(int(tparts[1]) / 60.0, 1)
                            elif proc_name == "Runner.Listener":
                                has_listener = True
                            rest = tparts[3] if len(tparts) == 4 else tparts[2]
                            cmds.append(rest)
                        state = "EXECUTING" if has_worker else ("IDLE" if has_listener else "CYCLING")
                    else:
                        state = "UNKNOWN"
                        reason = "docker top probe failed"
                else:
                    reason = cstatus or "container not running"
                ordered_names.append(cname)
                observed_by_name[cname] = {
                    "name": cname,
                    "state": state,
                    "elapsed_minutes": elapsed_min,
                    "active_child_commands": cmds,
                    "reason": reason,
                }
        else:
            docker_ok = False
    except (OSError, subprocess.TimeoutExpired):
        docker_ok = False

    slots = []
    if cfg["count"] and cfg["name_prefix"]:
        expected_names = [f"{cfg['name_prefix']}-{i}" for i in range(1, cfg["count"] + 1)]
        for idx, cname in enumerate(expected_names, start=1):
            if cname in observed_by_name:
                entry = dict(observed_by_name[cname])
                entry["slot"] = idx
                slots.append(entry)
            else:
                slots.append({
                    "slot": idx,
                    "name": cname,
                    "state": "PARKED" if mac_disabled else "DOWN",
                    "elapsed_minutes": None,
                    "active_child_commands": [],
                    "reason": "operator disabled (MAC_RUNNER_DISABLED=1)"
                    if mac_disabled
                    else ("docker daemon unreachable" if not docker_ok else "container missing"),
                })
        for cname in ordered_names:
            if cname not in expected_names:
                entry = dict(observed_by_name[cname])
                entry["slot"] = len(slots) + 1
                slots.append(entry)
    else:
        for idx, cname in enumerate(ordered_names, start=1):
            entry = dict(observed_by_name[cname])
            entry["slot"] = idx
            slots.append(entry)

    configured_count = cfg["count"] if cfg["count"] is not None else len(slots)
    if is_mac:
        effective_launchd = "disabled" if mac_disabled else service_status
        native_runners = _collect_local_native_runners()
        return {
            "generated_at_utc": now_utc,
            "hosts": {
                "mac": {
                    "hostname": hostname,
                    "parked": mac_disabled,
                    "ezgha_launchd_status": effective_launchd,
                    "colima_status": "running" if docker_ok else "unreachable",
                    "disk": disk_info,
                    "load_average": load_vals,
                    "configured_slots": configured_count,
                    "configured_container_slots": configured_count,
                    "container_slots": slots,
                    "native_runners": native_runners,
                }
            },
        }
    return {
        "generated_at_utc": now_utc,
        "hosts": {
            host_key: {
                "display_name": f"{host_key} (Local Linux Host)",
                "group": "jeff-ubuntu",
                "admission_status": (
                    f"service {service_status} / docker_unreachable"
                    if not docker_ok
                    else service_status
                ),
                "disk": disk_info,
                "load_average": load_vals,
                "configured_slots": configured_count,
                "slots": slots,
            }
        },
    }


def _collect_live_github_snapshot(repos=None):
    """Fallback bounded live GitHub query when no audit-dir is supplied."""
    target_repos, cap_note = _cap_live_repos(repos)
    all_ip_jobs = []
    ip_runs_by_repo = {}
    ip_jobs_by_repo = {}
    q_runs_by_repo = {}
    total_fresh = 0
    total_ghosts = 0
    fresh_complete = True
    ip_failed_repos = set()
    ip_capped = bool(cap_note)
    q_failed_repos = set()
    q_unverified_runs = 0
    sample_notes = []
    errors = [cap_note] if cap_note else []
    for repo in target_repos:
        short = _short_repo(repo)
        try:
            ip = ci_latency_probe.gh_json(["api", f"repos/{repo}/actions/runs?status=in_progress&per_page=50"], timeout=20)
            ip_runs = (ip or {}).get("workflow_runs") or []
            ip_count = (ip or {}).get("total_count") if isinstance((ip or {}).get("total_count"), int) else len(ip_runs)
            ip_runs_by_repo[repo] = ip_count
            if ip_count > len(ip_runs):
                ip_capped = True
                errors.append(f"{repo}: in-progress runs truncated ({len(ip_runs)} of {ip_count} returned)")
            if len(ip_runs) > 10:
                ip_capped = True
                errors.append(f"{repo}: in-progress job attribution capped at 10 of {len(ip_runs)} runs")
            job_cnt = 0
            for run in ip_runs[:10]:
                jdata = ci_latency_probe.gh_json(["api", f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100"], timeout=20)
                j_list = (jdata or {}).get("jobs") or []
                j_total = (jdata or {}).get("total_count")
                if isinstance(j_total, int) and j_total > len(j_list):
                    ip_capped = True
                    errors.append(f"{repo}: run {run['id']} jobs truncated ({len(j_list)} of {j_total} returned)")
                for j in j_list:
                    if j.get("status") == "in_progress":
                        job_cnt += 1
                        all_ip_jobs.append({
                            "repo": repo,
                            "run_id": run["id"],
                            "run_name": run.get("name"),
                            "run_html_url": run.get("html_url"),
                            "head_branch": run.get("head_branch"),
                            "job_id": j.get("id"),
                            "job_name": j.get("name"),
                            "runner_name": j.get("runner_name"),
                            "html_url": j.get("html_url"),
                        })
            ip_jobs_by_repo[repo] = job_cnt
        except Exception as exc:
            ip_failed_repos.add(repo)
            errors.append(f"{repo}: in_progress probe failed: {str(exc)[:120]}")

        try:
            q_probe = queue_probe.probe_repo(repo, max_job_checks=10)
            if not q_probe.get("ok"):
                fresh_complete = False
                q_failed_repos.add(repo)
                if q_probe.get("error"):
                    errors.append(f"{repo}: {q_probe['error']}")
            else:
                if q_probe.get("queued_total") is not None:
                    q_runs_by_repo[repo] = q_probe["queued_total"]
                q_unverified_runs += q_probe.get("unverified_runs") or 0
                if q_probe.get("unverified_runs"):
                    sample_notes.append(
                        f"{short}: {q_probe['unverified_runs']} of {q_probe.get('queued_total')} queued run(s) unverified"
                    )
                if q_probe.get("sample_capped") or q_probe.get("fresh") is None or q_probe.get("ghosts") is None:
                    fresh_complete = False
                    if q_probe.get("sample_capped"):
                        sample_notes.append(
                            f"{short}: sampled {q_probe['sampled_fresh']} fresh / {q_probe['sampled_ghosts']} ghosts of {q_probe['queued_total']} (>10 cap)"
                        )
                else:
                    total_fresh += q_probe["fresh"]
                    total_ghosts += q_probe["ghosts"]
        except Exception as exc:
            fresh_complete = False
            q_failed_repos.add(repo)
            errors.append(f"{repo}: queue probe failed: {str(exc)[:120]}")
    q_partial = bool(q_failed_repos or q_unverified_runs > 0 or not fresh_complete)
    return {
        "captured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "all_in_progress_jobs": all_ip_jobs,
        "errors": errors,
        "summary": {
            "partial": bool(errors or ip_failed_repos or q_partial),
            "ip_partial": bool(ip_failed_repos or ip_capped),
            "ip_expected_repos": len(target_repos),
            "ip_succeeded_repos": len(target_repos) - len(ip_failed_repos),
            "q_partial": q_partial,
            "q_unverified_runs": q_unverified_runs,
            "q_expected_repos": len(target_repos),
            "q_succeeded_repos": len(target_repos) - len(q_failed_repos),
            "total_in_progress_runs_by_repo": ip_runs_by_repo,
            "in_progress_jobs_by_repo": ip_jobs_by_repo,
            "total_queued_runs_by_repo": q_runs_by_repo,
            "queued_jobs_by_repo": {},
            "fresh_queued_runs": total_fresh if fresh_complete else None,
            "inert_ghosts": total_ghosts if fresh_complete else None,
            "queued_sample_note": "; ".join(sample_notes) if sample_notes else None,
        },
    }


def _cached_live_latency(repos):
    capped, _ = _cap_live_repos(repos or ci_latency_probe.DEFAULT_REPOS)
    target = tuple(capped)
    now = time.monotonic()
    if (
        _LIVE_LATENCY_CACHE["data"] is not None
        and _LIVE_LATENCY_CACHE["key"] == target
        and (now - _LIVE_LATENCY_CACHE["ts"]) < _LIVE_LATENCY_TTL_S
    ):
        return _LIVE_LATENCY_CACHE["data"]
    data = ci_latency_probe.probe_latency(list(target), limit=15, job_run_limit=8)
    _LIVE_LATENCY_CACHE.update({"key": target, "ts": now, "data": data})
    return data


_REMOTE_PROBE_PY = r"""
import json, pathlib, subprocess
cfg_path = pathlib.Path.home() / ".config" / "ezgha" / "config.toml"
count = None
prefix = None
if cfg_path.is_file():
    sec = None
    for raw in cfg_path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line: continue
        if line.startswith("[") and line.endswith("]"): sec = line[1:-1].strip(); continue
        if "=" not in line: continue
        k, v = [x.strip() for x in line.split("=", 1)]
        if sec == "runner" and k == "count" and v.isdigit(): count = int(v)
        elif sec == "runner" and k == "name_prefix": prefix = v.strip().strip('"').strip("'")
ps = subprocess.run(["docker", "ps", "-a", "--filter", "label=ezgha=managed", "--format", "{{.Names}}\t{{.Status}}"], capture_output=True, text=True, timeout=10)
if ps.returncode != 0:
    print(json.dumps({"ok": False}))
    raise SystemExit(0)
obs = {}
order = []
for line in ps.stdout.splitlines():
    if not line.strip(): continue
    parts = line.split("\t", 1)
    cname = parts[0].strip()
    cstatus = parts[1].strip() if len(parts) > 1 else ""
    st = "DOWN"; cmds = []; el = None; reason = None
    if cstatus.lower().startswith("up"):
        try:
            top = subprocess.run(["docker", "top", cname, "-eo", "pid,etimes,comm,args"], capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            top = None
            st = "UNKNOWN"; reason = "docker top timeout"
        if top is not None:
            if top.returncode == 0:
                hw = hl = False
                for tl in top.stdout.splitlines()[1:]:
                    tp = tl.strip().split(None, 3)
                    if len(tp) < 3: continue
                    proc_name = tp[2].rsplit("/", 1)[-1]
                    if proc_name == "Runner.Worker":
                        hw = True
                        if tp[1].isdigit(): el = round(int(tp[1]) / 60.0, 1)
                    elif proc_name == "Runner.Listener":
                        hl = True
                    cmds.append(tp[3] if len(tp) == 4 else tp[2])
                st = "EXECUTING" if hw else ("IDLE" if hl else "CYCLING")
            else:
                st = "UNKNOWN"; reason = "docker top probe failed"
    else:
        reason = cstatus or "container not running"
    order.append(cname)
    obs[cname] = {"name": cname, "state": st, "elapsed_minutes": el, "active_child_commands": cmds, "reason": reason}
slots = []
if count and prefix:
    exp = [f"{prefix}-{i}" for i in range(1, count + 1)]
    for i, cname in enumerate(exp, 1):
        slots.append({"slot": i, **(obs[cname] if cname in obs else {"name": cname, "state": "DOWN", "elapsed_minutes": None, "active_child_commands": [], "reason": "container missing"})})
    for cname in order:
        if cname not in exp: slots.append({"slot": len(slots) + 1, **obs[cname]})
else:
    for i, cname in enumerate(order, 1): slots.append({"slot": i, **obs[cname]})
print(json.dumps({"ok": True, "configured_slots": count if count is not None else len(slots), "slots": slots}))
"""


def _collect_remote_linux_slot_payload(ssh_host):
    if not ssh_host:
        return None
    try:
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", ssh_host, "python3", "-"],
            input=_REMOTE_PROBE_PY,
            capture_output=True, text=True, timeout=25,
        )
        if proc.returncode == 0:
            raw = json.loads(proc.stdout)
            if raw.get("ok"):
                slots = raw.get("slots") or []
                return {
                    "display_name": f"{ssh_host} (Remote Linux Host)",
                    "group": "jeff-ubuntu",
                    "admission_status": "ssh_probed",
                    "configured_slots": raw.get("configured_slots") or len(slots),
                    "slots": slots,
                }
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return None


def _collect_live_cmux(cmux_cmd):
    if not cmux_cmd:
        return None
    try:
        proc = subprocess.run(cmux_cmd, shell=True, capture_output=True, text=True, timeout=30)
        if proc.returncode == 0:
            data = json.loads(proc.stdout)
            return data if isinstance(data, dict) else None
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return None


def _uses_live_github(*, audit_dir=None, github_json=None, latency_json=None):
    return audit_dir is None and (github_json is None or latency_json is None)


def _is_fully_file_backed(*, audit_dir=None, hosts_json=None, github_json=None, latency_json=None):
    return audit_dir is not None or (
        hosts_json is not None and github_json is not None and latency_json is not None
    )


def build_operator_state(*, audit_dir=None, hosts_json=None, cmux_json=None, github_json=None,
                         latency_json=None, repos=None, linux_host=None, cmux_cmd=None):
    base = Path(audit_dir) if audit_dir else None
    hosts_path = hosts_json or (base / "ubuntu_mac_slots.json" if base else None)
    hosts_data, hosts_err = _load_json_checked(
        hosts_path, validator=_is_valid_hosts_payload, invalid_reason="hosts fixture missing hosts dict"
    )

    cmux_err = None
    if cmux_json is not None:
        cmux_data, cmux_err = _load_json_checked(
            cmux_json, validator=_is_valid_cmux_payload, invalid_reason="cmux fixture missing vms list"
        )
    elif base is not None:
        cmux_data, cmux_err = _load_json_checked(
            base / "cmux_and_github_reconciliation.json",
            validator=_is_valid_cmux_payload,
            invalid_reason="cmux fixture missing vms list",
        )
        if cmux_data is None:
            alt_data, alt_err = _load_json_checked(
                base / "cmux_parsed.json",
                validator=_is_valid_cmux_payload,
                invalid_reason="cmux fixture missing vms list",
            )
            if alt_data is not None:
                cmux_data, cmux_err = alt_data, None
            elif cmux_err and cmux_err.startswith("missing or non-file:") and alt_err and alt_err.startswith("missing or non-file:"):
                # Optional cmux feed omitted in audit_dir is fine; PermissionError/corrupt JSON is not.
                cmux_err = None
    else:
        cmux_data = None

    gh_path = github_json or (base / "github_live_snapshot.json" if base else None)
    gh_data, gh_err = _load_json_checked(
        gh_path, validator=_is_valid_gh_payload, invalid_reason="github fixture missing summary dict"
    )
    lat_path = latency_json or (base / "ci_latency_percentiles.json" if base else None)
    latency_raw, lat_err = _load_json_checked(
        lat_path, validator=_is_valid_latency_payload, invalid_reason="latency fixture missing cohorts/workflows"
    )

    fixture_errors = []
    hosts_partial = False
    if (hosts_json is not None or base is not None) and hosts_data is None:
        hosts_partial = True
        fixture_errors.append(f"hosts fixture missing or unreadable ({hosts_err or hosts_path})")
        hosts_data = {"hosts": {}}
    if (cmux_json is not None and cmux_data is None) or (base is not None and cmux_data is None and cmux_err is not None):
        hosts_partial = True
        fixture_errors.append(f"cmux fixture missing or unreadable ({cmux_err or cmux_json})")
        cmux_data = {"ok": False, "error": f"cmux fixture missing or unreadable: {cmux_err or cmux_json}"}
    if (github_json is not None or base is not None) and gh_data is None:
        err = f"github fixture missing or unreadable: {gh_err or gh_path}"
        fixture_errors.append(err)
        gh_data = {"errors": [err], "summary": {"ip_partial": True, "q_partial": True}}
    if (latency_json is not None or base is not None) and latency_raw is None:
        err = f"latency fixture missing or unreadable: {lat_err or lat_path}"
        fixture_errors.append(err)
        latency_raw = {"ok": False, "error": err, "overall": {}, "cohorts": {}, "workflows": []}

    is_fully_file_backed = _is_fully_file_backed(
        audit_dir=base,
        hosts_json=hosts_json,
        github_json=github_json,
        latency_json=latency_json,
    )
    scope_note = None
    if base is None and hosts_json is None and hosts_data is None:
        hosts_data = _collect_local_host_slots()
        eff_linux = linux_host or os.environ.get("EZGHA_OPERATOR_LINUX_HOST")
        eff_cmux = cmux_cmd or os.environ.get("EZGHA_DASHBOARD_CMUX_PROBE_CMD")
        missing_pools = []
        if eff_linux:
            remote_linux = _collect_remote_linux_slot_payload(eff_linux)
            if remote_linux:
                hosts_data.setdefault("hosts", {})[eff_linux] = remote_linux
            else:
                missing_pools.append(f"remote-linux ({eff_linux} unreachable)")
        else:
            missing_pools.append("remote-linux")
        if eff_cmux and cmux_json is None and cmux_data is None:
            cmux_data = _collect_live_cmux(eff_cmux)
            if cmux_data is None:
                missing_pools.append("cmux-cloud (probe failed)")
        elif cmux_json is None and cmux_data is None:
            missing_pools.append("cmux-cloud")
        if missing_pools:
            scope_note = (
                "Live single-host scope: showing local host slots + GitHub state; "
                + ", ".join(missing_pools)
                + " unprobed (pass --linux-host / --cmux-cmd or --audit-dir for full multi-host fleet)."
            )
    if base is None and github_json is None and gh_data is None:
        gh_data = _collect_live_github_snapshot(repos=repos)
    if base is None and latency_json is None and latency_raw is None:
        latency_raw = _cached_live_latency(repos)

    norm_errors = []
    hosts = _normalize_hosts(hosts_data, cmux_data, gh_data, errors=norm_errors)
    if norm_errors:
        hosts_partial = True
        fixture_errors.extend(norm_errors)
    rec_errors = []
    reconciliation = _normalize_reconciliation(
        hosts,
        cmux_data,
        gh_data,
        scope_note=scope_note,
        hosts_partial=hosts_partial,
        fixture_errors=fixture_errors,
        errors=rec_errors,
    )
    lat_errors = []
    latency = _normalize_latency(latency_raw, errors=lat_errors)
    extra_errors = rec_errors + lat_errors
    if extra_errors:
        fixture_errors.extend(extra_errors)
        reconciliation["fixture_errors"] = list(fixture_errors)
    if fixture_errors:
        fixture_note = "Fixture error: " + "; ".join(fixture_errors)
        scope_note = f"{scope_note} | {fixture_note}" if scope_note else fixture_note
        reconciliation["scope_note"] = scope_note
    source_timestamps = {
        "hosts": (hosts_data or {}).get("generated_at_utc"),
        "cmux": (cmux_data or {}).get("captured_at_utc"),
        "github": (gh_data or {}).get("captured_at"),
        "latency": latency.get("generated_at"),
    }

    return {
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_mode": "AUDIT SNAPSHOT" if is_fully_file_backed else "LIVE PROBE",
        "source_timestamps": source_timestamps,
        "hosts": hosts,
        "reconciliation": reconciliation,
        "latency": latency,
    }


def _escape_embedded_json(state):
    """Escape HTML/script-significant characters inside embedded JSON."""
    raw = json.dumps(state, ensure_ascii=False)
    return (
        raw.replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def render_html(state, *, auto_refresh_ms=0):
    """Render a standalone, self-contained HTML dashboard with embedded state JSON."""
    safe_json = _escape_embedded_json(state)
    generated_at = html_lib.escape(str(state.get("generated_at_utc") or ""))
    refresh_attr = str(int(auto_refresh_ms))
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="dark" />
  <title>ezgha Operator Live Fleet + CI Latency Inspector</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #0c0f0e;
      --panel: #151917;
      --panel-2: #1b211e;
      --line: #2e3732;
      --ink: #f3f1ea;
      --muted: #9da8a1;
      --green: #69e27d;
      --amber: #f4c95d;
      --red: #ff6b57;
      --blue: #7ab3ef;
      --mono: 'SFMono-Regular', 'Cascadia Mono', 'Liberation Mono', monospace;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0 auto;
      max-width: 96rem;
      padding: clamp(0.75rem, 2vw, 1.75rem);
      background: var(--bg);
      color: var(--ink);
      font-family: var(--mono);
      font-size: 13px;
      line-height: 1.45;
    }}
    a {{ color: var(--blue); text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
    h1, h2, h3, p {{ margin: 0; }}
    .topbar {{
      display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end;
      gap: 0.75rem; padding-bottom: 1rem; border-bottom: 1px solid var(--line);
    }}
    .eyebrow {{ color: var(--amber); font-size: 11px; letter-spacing: 0.12em; text-transform: uppercase; }}
    h1 {{ font-size: clamp(1.5rem, 3vw, 2.3rem); letter-spacing: -0.04em; }}
    .badge {{
      display: inline-block; padding: 2px 7px; border-radius: 3px; font-size: 11px;
      font-weight: 700; text-transform: uppercase; border: 1px solid var(--line);
    }}
    .badge-EXECUTING {{ color: var(--green); border-color: var(--green); background: rgb(105 226 125 / 0.1); }}
    .badge-DOWN, .badge-OFFLINE, .badge-CRITICAL {{ color: var(--red); border-color: var(--red); background: rgb(255 107 87 / 0.14); }}
    .badge-CYCLING, .badge-IDLE, .badge-WARN {{ color: var(--amber); border-color: var(--amber); background: rgb(244 201 93 / 0.12); }}
    .badge-PARKED {{ color: var(--blue); border-color: var(--blue); background: rgb(122 179 239 / 0.12); }}
    .badge-UNKNOWN {{ color: var(--muted); border-color: var(--muted); background: rgb(157 168 161 / 0.12); }}
    .phase-pill {{
      display: inline-block; padding: 1px 6px; border-radius: 3px; font-size: 10px;
      background: #242b27; color: #d5ded8; border: 1px solid var(--line);
    }}
    .section {{
      margin-top: 1rem; padding: 1rem; background: var(--panel); border: 1px solid var(--line);
    }}
    .section-head {{
      display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center;
      gap: 0.75rem; padding-bottom: 0.7rem; margin-bottom: 0.75rem; border-bottom: 1px solid var(--line);
    }}
    .kpi-grid {{
      display: grid; gap: 0.65rem;
      grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
    }}
    .kpi {{
      padding: 0.7rem; background: var(--panel-2); border: 1px solid var(--line);
    }}
    .kpi-label {{ color: var(--muted); font-size: 11px; text-transform: uppercase; }}
    .kpi-val {{ font-size: 1.55rem; font-weight: 800; margin-top: 0.2rem; font-variant-numeric: tabular-nums; }}
    .kpi-sub {{ color: var(--muted); font-size: 11px; margin-top: 0.2rem; }}
    .alert-box {{
      margin-top: 0.75rem; padding: 0.75rem; border-left: 4px solid var(--red);
      background: rgb(255 107 87 / 0.08);
    }}
    .alert-box.warn {{ border-left-color: var(--amber); background: rgb(244 201 93 / 0.08); }}
    .controls {{
      display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; margin-bottom: 0.75rem;
    }}
    .controls input, .controls select, .controls button {{
      background: var(--panel-2); color: var(--ink); border: 1px solid var(--line);
      padding: 0.35rem 0.6rem; font-family: var(--mono); font-size: 12px; cursor: pointer;
    }}
    .controls button.active {{ border-color: var(--green); color: var(--green); }}
    .host-card {{ margin-top: 0.9rem; border: 1px solid var(--line); background: var(--panel-2); }}
    .host-header {{
      display: flex; flex-wrap: wrap; justify-content: space-between; gap: 0.5rem;
      padding: 0.65rem 0.85rem; border-bottom: 1px solid var(--line); background: #19201d;
    }}
    .vitals {{ color: var(--muted); font-size: 11px; display: flex; flex-wrap: wrap; gap: 0.85rem; }}
    .table-wrap {{ overflow-x: auto; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 12px; }}
    th, td {{
      padding: 0.48rem 0.6rem; border-bottom: 1px solid #242c28; text-align: left; vertical-align: top;
    }}
    th {{ color: var(--muted); font-size: 11px; text-transform: uppercase; user-select: none; }}
    th.sortable {{ cursor: pointer; }}
    th.sortable:hover {{ color: var(--ink); }}
    tr.row-critical {{ background: rgb(255 107 87 / 0.09); }}
    tr.row-warn {{ background: rgb(244 201 93 / 0.06); }}
    tr.row-parked {{ background: rgb(122 179 239 / 0.05); }}
    td.col-slot {{ white-space: nowrap; }}
    .cmd-line {{
      color: var(--muted); font-size: 11px; max-width: 34rem;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }}
    .links {{ display: flex; flex-wrap: wrap; gap: 0.45rem; }}
    .links a {{
      padding: 1px 5px; border: 1px solid #2c4763; border-radius: 3px; font-size: 11px;
      background: rgb(122 179 239 / 0.08);
    }}
    .headline-list {{ margin: 0.6rem 0 0; padding-left: 1.2rem; color: var(--muted); }}
    .headline-list li {{ margin-bottom: 0.3rem; }}
    @media (max-width: 48rem) {{
      .kpi-grid {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
    }}
  </style>
</head>
<body>
  <header class="topbar">
    <div>
      <p class="eyebrow">EZ GH ACTIONS // UNREDACTED OPERATOR LIVE VIEW</p>
      <h1>Fleet + Queue + CI Latency Inspector</h1>
    </div>
    <div>
      <span class="badge badge-EXECUTING" id="live-stamp">UPDATED {generated_at}</span>
      <button type="button" id="manual-refresh-btn" style="margin-left:0.5rem; background:var(--panel-2); color:var(--ink); border:1px solid var(--line); padding:2px 8px; font-family:var(--mono); font-size:11px; cursor:pointer;">Refresh Now</button>
      <div class="vitals" id="source-stamps" style="margin-top:0.35rem; justify-content:flex-end;"></div>
    </div>
  </header>

  <section class="section" id="reconcile-section">
    <div class="section-head">
      <h2>Why Does GitHub Show N Runs In Progress? — Run-vs-Slot Reconciliation</h2>
      <span class="badge" id="slot-total-badge">— SLOTS</span>
    </div>
    <div class="kpi-grid" id="reconcile-kpis"></div>
    <div id="reconcile-alerts"></div>
    <ul class="headline-list" id="reconcile-headlines"></ul>
  </section>

  <section class="section" id="latency-section">
    <div class="section-head">
      <h2>CI Latency Telemetry (avg / p50 / p90 / p99)</h2>
      <div class="controls" id="cohort-controls">
        <button data-cohort="success" class="active">Success</button>
        <button data-cohort="all_non_skipped">All Non-Skipped</button>
        <button data-cohort="failure">Failure</button>
        <button data-cohort="cancelled">Cancelled</button>
      </div>
    </div>
    <div id="latency-alerts" style="margin-bottom:0.65rem;"></div>
    <div class="kpi-grid" id="latency-kpis"></div>
    <div class="kpi-grid" id="latency-extra-kpis" style="margin-top:0.65rem;"></div>
    <div class="controls" style="margin-top:0.85rem;">
      <label>Repo:
        <select id="latency-repo-filter">
          <option value="ALL">All Repos</option>
        </select>
      </label>
    </div>
    <div class="table-wrap">
      <table id="latency-table">
        <thead>
          <tr>
            <th class="sortable" data-sort="repo">Repo</th>
            <th class="sortable" data-sort="workflow">Workflow</th>
            <th class="sortable" data-sort="n">N</th>
            <th class="sortable" data-sort="q_avg">Q avg</th>
            <th class="sortable" data-sort="q_p50">Q p50</th>
            <th class="sortable" data-sort="q_p90">Q p90</th>
            <th class="sortable" data-sort="q_p99">Q p99</th>
            <th class="sortable" data-sort="e_avg">Exec avg</th>
            <th class="sortable" data-sort="e_p50">Exec p50</th>
            <th class="sortable" data-sort="e_p90">Exec p90</th>
            <th class="sortable" data-sort="e_p99">Exec p99</th>
            <th class="sortable" data-sort="e2e_avg">Run avg</th>
            <th class="sortable" data-sort="e2e_p50">Run p50</th>
            <th class="sortable" data-sort="e2e_p90">Run p90</th>
            <th class="sortable" data-sort="e2e_p99">Run p99</th>
          </tr>
        </thead>
        <tbody id="latency-tbody"></tbody>
      </table>
    </div>
  </section>

  <section class="section" id="fleet-section">
    <div class="section-head">
      <h2>Per-Host &amp; Per-Runner-Slot Live Truth</h2>
      <div class="controls">
        <input type="search" id="slot-search" placeholder="Filter slot, repo, PR, job, cmd…" />
        <select id="slot-state-filter">
          <option value="ALL">All States</option>
          <option value="EXECUTING">EXECUTING</option>
          <option value="DOWN">DOWN</option>
          <option value="CYCLING">CYCLING</option>
          <option value="IDLE">IDLE</option>
          <option value="PARKED">PARKED</option>
          <option value="OFFLINE">OFFLINE</option>
          <option value="UNKNOWN">UNKNOWN</option>
        </select>
        <select id="slot-group-filter">
          <option value="ALL">All Hosts</option>
          <option value="jeff-ubuntu">Linux Host</option>
          <option value="cmux">Cloud VMs</option>
          <option value="mac">macOS</option>
          <option value="special">Special</option>
        </select>
      </div>
    </div>
    <div id="hosts-container"></div>
  </section>

  <script id="initial-state" type="application/json">{safe_json}</script>
  <script>
  (function () {{
    const AUTO_REFRESH_MS = {refresh_attr};
    let state = JSON.parse(document.getElementById('initial-state').textContent);
    let currentCohort = 'success';
    let sortKey = 'e_p90';
    let sortAsc = false;
    let refreshCount = 0;

    function esc(v) {{
      return String(v ?? '').replace(/[&<>"']/g, (c) => ({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
    }}

    function safeHttpUrl(u) {{
      if (typeof u !== 'string') return null;
      const trimmed = u.trim();
      if (!trimmed || /\\s/.test(trimmed)) return null;
      try {{
        const parsed = new URL(trimmed);
        return (parsed.protocol === 'http:' || parsed.protocol === 'https:') ? trimmed : null;
      }} catch (_e) {{
        return null;
      }}
    }}

    function fmtSec(s) {{
      if (typeof s !== 'number' || !Number.isFinite(s) || s < 0) return '—';
      const r = Math.round(s);
      if (r < 60) return r + 's';
      const m = Math.floor(r / 60), rem = r % 60;
      return rem === 0 ? m + 'm' : m + 'm ' + rem + 's';
    }}

    function renderReconciliation() {{
      const rec = state.reconciliation || {{}};
      const sc = rec.state_counts || {{}};
      document.getElementById('slot-total-badge').textContent = (rec.total_slots || 0) + ' TOTAL SLOTS';
      const downHosts = (state.hosts || []).filter((h) => (h.slots || []).some((s) => s.state === 'DOWN')).map((h) => h.id);
      const downSub = downHosts.length ? downHosts.join(', ') + ' down/paused slots' : 'No DOWN slots';
      const idleSub = (sc.IDLE || 0) + ' idle slot(s) across hosts';
      const qSub = rec.queued_sample_note
        ? rec.queued_sample_note
        : (rec.queue_partial
            ? 'Partial queue coverage (' + (rec.q_repos_covered || 'some repos failed')
              + (rec.q_unverified_runs > 0 ? ', ' + rec.q_unverified_runs + ' unverified job check(s)' : '')
              + ')'
            : (rec.fresh_queued_scope
                ? 'Scope: ' + rec.fresh_queued_scope
                : (rec.queued_runs_total !== null && rec.queued_runs_total !== undefined
                    ? 'Total queued runs: ' + rec.queued_runs_total
                    : 'Queue breakdown unavailable')));
      const qVal = rec.fresh_queued_runs !== null && rec.fresh_queued_runs !== undefined
        ? rec.fresh_queued_runs + ' / ' + (rec.inert_ghosts ?? '—')
        : (rec.queued_runs_total !== null && rec.queued_runs_total !== undefined
            ? rec.queued_runs_total + (rec.queued_sample_note ? ' runs (sample only)' : ' runs (no ghost split)')
            : '— / —');
      const partialTag = rec.active_runs_partial ? ' (partial' + (rec.repos_covered ? ': ' + rec.repos_covered + ' repos' : '') + ')' : '';
      const activeRunsVal = rec.active_workflow_runs !== null && rec.active_workflow_runs !== undefined
        ? rec.active_workflow_runs + (rec.active_runs_partial ? '*' : '')
        : '—';
      const activeJobsVal = rec.active_github_jobs !== null && rec.active_github_jobs !== undefined
        ? rec.active_github_jobs + (rec.active_runs_partial ? '*' : '')
        : '—';
      const cards = [
        ['Active GH Runs' + (rec.active_runs_partial ? ' (Partial)' : ''), activeRunsVal, rec.active_runs_partial ? 'Partial' + partialTag + ' — see error banner' : 'Workflow rows showing in_progress'],
        ['Active GH Jobs' + (rec.active_runs_partial ? ' (Partial)' : ''), activeJobsVal, rec.active_runs_partial ? 'Partial' + partialTag + ' — see error banner' : 'Observed in_progress jobs'],
        ['Executing Slots', sc.EXECUTING || 0, 'Docker + native + special executing'],
        ['Cycling / Idle', (sc.CYCLING || 0) + 'C / ' + (sc.IDLE || 0) + 'I', idleSub],
        ['Down / Offline / Unknown', (sc.DOWN || 0) + 'D / ' + (sc.OFFLINE || 0) + 'O / ' + (sc.UNKNOWN || 0) + 'U', downSub],
        ['Parked (Mac)', sc.PARKED || 0, 'Intentionally disabled'],
        ['Queued (Fresh / Ghosts)' + (rec.queue_partial ? ' (Partial)' : ''), qVal, qSub],
      ];
      document.getElementById('reconcile-kpis').innerHTML = cards.map(([k, v, sub]) =>
        `<div class="kpi"><div class="kpi-label">${{esc(k)}}</div><div class="kpi-val">${{esc(v)}}</div><div class="kpi-sub">${{esc(sub)}}</div></div>`
      ).join('');

      const alerts = [];
      if (rec.scope_note) {{
        alerts.push(`<div class="alert-box warn"><strong>Fleet Scope:</strong> ${{esc(rec.scope_note)}}</div>`);
      }}
      for (const h of state.hosts || []) {{
        if (h.alert_message) {{
          const isWarn = h.group === 'mac';
          alerts.push(`<div class="alert-box ${{isWarn ? 'warn' : ''}}"><strong>${{esc(h.id)}} (${{esc(h.status)}}):</strong> ${{esc(h.alert_message)}}</div>`);
        }}
      }}
      for (const err of rec.gh_errors || []) {{
        alerts.push(`<div class="alert-box warn"><strong>GitHub API partial/error:</strong> ${{esc(err)}}</div>`);
      }}
      document.getElementById('reconcile-alerts').innerHTML = alerts.join('');
      const hl = rec.headline_points || [];
      document.getElementById('reconcile-headlines').innerHTML = hl.map((p) => `<li>${{esc(p)}}</li>`).join('');
    }}

    function renderLatency() {{
      const lat = state.latency || {{}};
      const latAlerts = [];
      if (lat.ok !== true) {{
        latAlerts.push(`<div class="alert-box"><strong>Latency Probe Unavailable:</strong> ${{esc(lat.error || 'latency telemetry probe failed or returned no samples')}}</div>`);
      }} else if (lat.partial === true) {{
        const parts = [];
        if (lat.timed_out_runs) parts.push(`${{lat.timed_out_runs}} timed-out run(s)`);
        if (lat.failed_job_fetches) parts.push(`${{lat.failed_job_fetches}} failed job fetch(es)`);
        if (lat.truncated_job_fetches) parts.push(`${{lat.truncated_job_fetches}} run(s) with truncated jobs`);
        if (lat.truncated_run_lists) parts.push(`${{lat.truncated_run_lists}} repo(s) with truncated runs`);
        const detail = lat.error || (parts.length ? `${{parts.join(', ')}} — showing remaining samples only` : 'partial latency sample — some runs/jobs failed to fetch');
        latAlerts.push(`<div class="alert-box warn"><strong>Partial Latency Sample:</strong> ${{esc(detail)}}</div>`);
      }}
      document.getElementById('latency-alerts').innerHTML = latAlerts.join('');
      const cohorts = lat.cohorts || {{}};
      const cData = cohorts[currentCohort] || {{}};
      const q = cData.queue_wait || {{}};
      const e = cData.execution || {{}};
      const jt = cData.job_total || {{}};
      const e2e = cData.e2e || {{}};
      const cancel = lat.cancellation || {{}};

      const cards = [
        ['Queue Wait (' + currentCohort + ')', `p50 ${{fmtSec(q.p50_s)}} | p90 ${{fmtSec(q.p90_s)}}`, `avg ${{fmtSec(q.avg_s)}} · p99 ${{fmtSec(q.p99_s)}} · n=${{q.n ?? 0}}`],
        ['Job Execution (' + currentCohort + ')', `p50 ${{fmtSec(e.p50_s)}} | p90 ${{fmtSec(e.p90_s)}}`, `avg ${{fmtSec(e.avg_s)}} · p99 ${{fmtSec(e.p99_s)}} · n=${{e.n ?? 0}}`],
        ['Total Job Wall', `p50 ${{fmtSec(jt.p50_s)}} | p90 ${{fmtSec(jt.p90_s)}}`, `avg ${{fmtSec(jt.avg_s)}} · p99 ${{fmtSec(jt.p99_s)}}`],
        ['E2E Run Wall', `p50 ${{fmtSec(e2e.p50_s)}} | p90 ${{fmtSec(e2e.p90_s)}}`, `avg ${{fmtSec(e2e.avg_s)}} · p99 ${{fmtSec(e2e.p99_s)}} · n=${{e2e.n ?? 0}}`],
        ['Cancelled Waste', cancel.cancelled_rate_pct !== null && cancel.cancelled_rate_pct !== undefined ? `${{cancel.cancelled_rate_pct}}%` : '—', `${{cancel.cancelled_runs ?? 0}} / ${{cancel.total_non_skipped_runs ?? 0}} non-skipped runs`],
      ];
      document.getElementById('latency-kpis').innerHTML = cards.map(([k, v, sub]) =>
        `<div class="kpi"><div class="kpi-label">${{esc(k)}}</div><div class="kpi-val" style="font-size:1.15rem">${{esc(v)}}</div><div class="kpi-sub">${{esc(sub)}}</div></div>`
      ).join('');

      const extraCards = [];
      for (const [cls, data] of Object.entries(lat.runner_classes || {{}})) {{
        const cs = (data.cohorts && data.cohorts[currentCohort]) || data[currentCohort] || ((data.queue_wait || data.execution) ? (currentCohort === 'success' ? data : {{}}) : {{}});
        const cq = cs.queue_wait || {{}}, ce = cs.execution || {{}};
        extraCards.push([`Runner: ${{cls}}`, `Q ${{fmtSec(cq.p50_s)}} | E ${{fmtSec(ce.p50_s)}}`, `E p90 ${{fmtSec(ce.p90_s)}} · E avg ${{fmtSec(ce.avg_s)}} (n=${{ce.n ?? 0}})`]);
      }}
      for (const [cat, st] of Object.entries(lat.step_categories || {{}})) {{
        extraCards.push([`Step: ${{cat}}`, `p50 ${{fmtSec(st.p50_s)}} | p90 ${{fmtSec(st.p90_s)}}`, `avg ${{fmtSec(st.avg_s)}} · max ${{fmtSec(st.max_s)}}`]);
      }}
      document.getElementById('latency-extra-kpis').innerHTML = extraCards.map(([k, v, sub]) =>
        `<div class="kpi"><div class="kpi-label">${{esc(k)}}</div><div class="kpi-val" style="font-size:1.05rem">${{esc(v)}}</div><div class="kpi-sub">${{esc(sub)}}</div></div>`
      ).join('');

      const repoSelect = document.getElementById('latency-repo-filter');
      const existingRepos = new Set(Array.from(repoSelect.options).map((o) => o.value));
      for (const wf of lat.workflows || []) {{
        if (wf.repo && !existingRepos.has(wf.repo)) {{
          existingRepos.add(wf.repo);
          const opt = document.createElement('option');
          opt.value = wf.repo;
          opt.textContent = wf.repo;
          repoSelect.appendChild(opt);
        }}
      }}
      const repoFilter = repoSelect.value;

      const rows = (lat.workflows || []).filter((wf) => repoFilter === 'ALL' || wf.repo === repoFilter).map((wf) => {{
        const block = (wf.cohorts && wf.cohorts[currentCohort]) || wf[currentCohort] || {{}};
        const qw = block.queue_wait || {{}}, ex = block.execution || {{}}, e2 = block.e2e || {{}};
        return {{
          repo: wf.repo || '—',
          workflow: wf.workflow || '—',
          n: ex.n ?? qw.n ?? 0,
          q_avg: qw.avg_s ?? -1,
          q_p50: qw.p50_s ?? -1,
          q_p90: qw.p90_s ?? -1,
          q_p99: qw.p99_s ?? -1,
          e_avg: ex.avg_s ?? -1,
          e_p50: ex.p50_s ?? -1,
          e_p90: ex.p90_s ?? -1,
          e_p99: ex.p99_s ?? -1,
          e2e_avg: e2.avg_s ?? -1,
          e2e_p50: e2.p50_s ?? -1,
          e2e_p90: e2.p90_s ?? -1,
          e2e_p99: e2.p99_s ?? -1,
        }};
      }});
      rows.sort((a, b) => {{
        const va = a[sortKey], vb = b[sortKey];
        if (typeof va === 'string') return sortAsc ? va.localeCompare(vb) : vb.localeCompare(va);
        return sortAsc ? va - vb : vb - va;
      }});
      document.getElementById('latency-tbody').innerHTML = rows.map((r) => `
        <tr>
          <td>${{esc(r.repo)}}</td>
          <td><strong>${{esc(r.workflow)}}</strong></td>
          <td>${{esc(r.n)}}</td>
          <td>${{fmtSec(r.q_avg)}}</td>
          <td>${{fmtSec(r.q_p50)}}</td>
          <td>${{fmtSec(r.q_p90)}}</td>
          <td>${{fmtSec(r.q_p99)}}</td>
          <td>${{fmtSec(r.e_avg)}}</td>
          <td>${{fmtSec(r.e_p50)}}</td>
          <td><strong>${{fmtSec(r.e_p90)}}</strong></td>
          <td>${{fmtSec(r.e_p99)}}</td>
          <td>${{fmtSec(r.e2e_avg)}}</td>
          <td>${{fmtSec(r.e2e_p50)}}</td>
          <td>${{fmtSec(r.e2e_p90)}}</td>
          <td>${{fmtSec(r.e2e_p99)}}</td>
        </tr>
      `).join('');
    }}

    function renderHosts() {{
      const q = (document.getElementById('slot-search').value || '').trim().toLowerCase();
      const stateFilter = document.getElementById('slot-state-filter').value;
      const groupFilter = document.getElementById('slot-group-filter').value;

      const html = (state.hosts || []).filter((h) => groupFilter === 'ALL' || h.group === groupFilter).map((h) => {{
        const slots = (h.slots || []).filter((s) => {{
          if (stateFilter !== 'ALL' && s.state !== stateFilter) return false;
          if (!q) return true;
          const hay = [s.name, s.state, s.repo, s.workflow, s.job_name, s.pr_label, s.ref, s.reason, s.phase_badge, ...(s.commands || [])].join(' ').toLowerCase();
          return hay.includes(q);
        }});
        if (slots.length === 0 && (q || stateFilter !== 'ALL')) return '';
        const vitals = Object.entries(h.vitals || {{}}).filter(([, v]) => v).map(([k, v]) => `<span><strong>${{esc(k)}}:</strong> ${{esc(v)}}</span>`).join('');
        const rowsHtml = slots.map((s) => {{
          const rowClass = s.alert_level === 'critical' ? 'row-critical' : s.alert_level === 'warn' ? 'row-warn' : s.alert_level === 'parked' ? 'row-parked' : '';
          const links = [];
          const runUrl = safeHttpUrl(s.run_url);
          const jobUrl = safeHttpUrl(s.job_url);
          const prUrl = safeHttpUrl(s.pr_url);
          if (runUrl) links.push(`<a href="${{esc(runUrl)}}" target="_blank" rel="noopener">Run ${{esc(s.run_id || '')}}</a>`);
          if (jobUrl) links.push(`<a href="${{esc(jobUrl)}}" target="_blank" rel="noopener">Job</a>`);
          if (prUrl) links.push(`<a href="${{esc(prUrl)}}" target="_blank" rel="noopener">${{esc(s.pr_label)}}</a>`);
          const detail = s.reason ? esc(s.reason) : (s.commands || []).map((c) => `<div class="cmd-line" title="${{esc(c)}}">${{esc(c)}}</div>`).join('');
          return `
            <tr class="${{rowClass}}">
              <td class="col-slot"><strong>${{esc(s.name)}}</strong></td>
              <td><span class="badge badge-${{esc(s.state)}}">${{esc(s.state)}}</span></td>
              <td>${{s.phase_badge ? `<span class="phase-pill">${{esc(s.phase_badge)}}</span>` : '—'}}</td>
              <td>${{typeof s.elapsed_minutes === 'number' ? esc(s.elapsed_minutes) + 'm' : '—'}}</td>
              <td>${{esc(s.repo_short || s.repo || '—')}}${{s.ref ? `<div class="cmd-line">${{esc(s.ref)}}</div>` : ''}}</td>
              <td><strong>${{esc(s.workflow || '—')}}</strong><div>${{esc(s.job_name || '')}}</div></td>
              <td><div class="links">${{links.join('') || '—'}}</div></td>
              <td>${{detail || '—'}}</td>
            </tr>
          `;
        }}).join('');
        return `
          <div class="host-card">
            <div class="host-header">
              <div><strong>${{esc(h.title)}}</strong> <span class="badge">${{esc(h.status)}}</span></div>
              <div class="vitals">${{vitals}}</div>
            </div>
            <div class="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Slot</th><th>State</th><th>Phase</th><th>Elapsed</th><th>Repo / Ref</th><th>Workflow / Job</th><th>Links</th><th>Active Process / Reason</th>
                  </tr>
                </thead>
                <tbody>${{rowsHtml}}</tbody>
              </table>
            </div>
          </div>
        `;
      }}).join('');
      document.getElementById('hosts-container').innerHTML = html || '<p class="kpi-sub">No matching runner slots.</p>';
    }}

    function renderAll() {{
      const mode = state.source_mode || 'LIVE PROBE';
      const refreshTag = refreshCount > 0 ? ' (refresh #' + refreshCount + ')' : '';
      document.getElementById('live-stamp').textContent = mode + ' · RENDERED ' + (state.generated_at_utc || '') + refreshTag;
      const stamps = Object.entries(state.source_timestamps || {{}})
        .filter(([, v]) => v)
        .map(([k, v]) => `<span><strong>${{esc(k)}}:</strong> ${{esc(v)}}</span>`);
      document.getElementById('source-stamps').innerHTML = stamps.join('') || '<span>No source timestamps</span>';
      renderReconciliation();
      renderLatency();
      renderHosts();
    }}

    document.querySelectorAll('#cohort-controls button').forEach((btn) => {{
      btn.addEventListener('click', () => {{
        document.querySelectorAll('#cohort-controls button').forEach((b) => b.classList.remove('active'));
        btn.classList.add('active');
        currentCohort = btn.dataset.cohort;
        renderLatency();
      }});
    }});
    document.querySelectorAll('#latency-table th.sortable').forEach((th) => {{
      th.addEventListener('click', () => {{
        const key = th.dataset.sort;
        if (sortKey === key) sortAsc = !sortAsc;
        else {{ sortKey = key; sortAsc = false; }}
        renderLatency();
      }});
    }});
    ['slot-search', 'slot-state-filter', 'slot-group-filter'].forEach((id) => {{
      document.getElementById(id).addEventListener('input', renderHosts);
      document.getElementById(id).addEventListener('change', renderHosts);
    }});
    document.getElementById('latency-repo-filter').addEventListener('change', renderLatency);

    async function refreshNow() {{
      const opts = {{ cache: 'no-store' }};
      if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {{
        opts.signal = AbortSignal.timeout(15000);
      }}
      const r = await fetch('/api/state?ts=' + Date.now(), opts);
      if (r.ok) {{ refreshCount += 1; state = await r.json(); renderAll(); }}
    }}
    const manualBtn = document.getElementById('manual-refresh-btn');
    if (manualBtn) {{
      manualBtn.addEventListener('click', async () => {{
        manualBtn.disabled = true;
        try {{ await refreshNow(); }} catch (_e) {{}} finally {{ manualBtn.disabled = false; }}
      }});
    }}
    renderAll();
    if (AUTO_REFRESH_MS > 0) {{
      const schedulePoll = () => {{
        window.setTimeout(async () => {{
          try {{ await refreshNow(); }} catch (_e) {{}}
          schedulePoll();
        }}, AUTO_REFRESH_MS);
      }};
      schedulePoll();
    }}
  }})();
  </script>
</body>
</html>
"""


def _is_loopback_host_header(host_header):
    if not isinstance(host_header, str) or not host_header.strip():
        return False
    raw = host_header.strip().lower()
    if raw.startswith("["):
        if "]" not in raw:
            return False
        host_part, rest = raw[1:].split("]", 1)
        if rest and not re.match(r"^:\d+$", rest):
            return False
        return host_part == "::1"
    if ":" in raw:
        host_part, port_part = raw.rsplit(":", 1)
        if not port_part.isdigit():
            return False
    else:
        host_part = raw
    return host_part in ("127.0.0.1", "localhost")


def create_server(*, host="127.0.0.1", port=8790, audit_dir=None, hosts_json=None,
                  cmux_json=None, github_json=None, latency_json=None, repos=None,
                  linux_host=None, cmux_cmd=None, refresh_ms=None, cache_ttl_s=None,
                  wait_timeout_s=10.0):
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("Refusing to bind operator dashboard outside loopback")

    uses_live_github = _uses_live_github(
        audit_dir=audit_dir,
        github_json=github_json,
        latency_json=latency_json,
    )
    effective_refresh_ms = refresh_ms if refresh_ms is not None else (120000 if uses_live_github else 15000)
    effective_ttl_s = cache_ttl_s if cache_ttl_s is not None else (120.0 if uses_live_github else 15.0)

    cache_lock = threading.Lock()
    cache_state = {"ts": 0.0, "data": None, "building": None}

    def _spawn_refresh_locked():
        box = {"event": threading.Event(), "data": None, "error": None}
        cache_state["building"] = box

        def _worker():
            try:
                fresh = build_operator_state(
                    audit_dir=audit_dir,
                    hosts_json=hosts_json,
                    cmux_json=cmux_json,
                    github_json=github_json,
                    latency_json=latency_json,
                    repos=repos,
                    linux_host=linux_host,
                    cmux_cmd=cmux_cmd,
                )
                box["data"] = fresh
                with cache_lock:
                    cache_state["data"] = fresh
                    cache_state["ts"] = time.monotonic()
                    if cache_state["building"] is box:
                        cache_state["building"] = None
            except Exception as exc:
                box["error"] = exc
                with cache_lock:
                    if cache_state["building"] is box:
                        cache_state["building"] = None
            finally:
                box["event"].set()

        threading.Thread(target=_worker, daemon=True).start()
        return box

    def load_state():
        with cache_lock:
            now = time.monotonic()
            cached = cache_state["data"]
            if cached is not None:
                if (now - cache_state["ts"]) >= effective_ttl_s and cache_state["building"] is None:
                    _spawn_refresh_locked()
                return cached
            box = cache_state["building"] or _spawn_refresh_locked()
        if not box["event"].wait(timeout=wait_timeout_s):
            raise TimeoutError("Timed out waiting for initial operator state")
        if box["error"] is not None:
            raise box["error"]
        return box["data"]

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            return

        def do_GET(self):
            if not _is_loopback_host_header(self.headers.get("Host")):
                self.send_response(403)
                self.end_headers()
                return
            path = self.path.split("?", 1)[0]
            if path == "/api/state":
                try:
                    payload = json.dumps(load_state()).encode("utf-8")
                except TimeoutError:
                    self.send_response(504)
                    self.end_headers()
                    return
                except Exception:
                    self.send_response(500)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(payload)
                return
            if path in ("/", "/index.html"):
                try:
                    body = render_html(load_state(), auto_refresh_ms=effective_refresh_ms).encode("utf-8")
                except TimeoutError:
                    self.send_response(504)
                    self.end_headers()
                    return
                except Exception:
                    self.send_response(500)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.end_headers()

    class ReusableTCPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        allow_reuse_address = True
        address_family = socket.AF_INET6 if host == "::1" else socket.AF_INET

    return ReusableTCPServer((host, port), Handler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit-dir", default=None, help="Directory with live audit JSONs")
    parser.add_argument("--hosts-json", default=None)
    parser.add_argument("--cmux-json", default=None)
    parser.add_argument("--github-json", default=None)
    parser.add_argument("--latency-json", default=None)
    parser.add_argument("--linux-host", default=None, help="Optional remote Linux SSH host for live mode")
    parser.add_argument("--cmux-cmd", default=None, help="Optional cmux probe command for live mode")
    parser.add_argument("--repo", action="append", default=None, help="org/repo to query in live mode")
    parser.add_argument("--out-html", default=None, help="Write standalone static HTML snapshot")
    parser.add_argument("--serve", action="store_true", help="Run localhost live operator server")
    parser.add_argument("--port", type=int, default=8790)
    args = parser.parse_args()
    if args.repo and _uses_live_github(
        audit_dir=args.audit_dir,
        github_json=args.github_json,
        latency_json=args.latency_json,
    ):
        unique_repos = list(dict.fromkeys(r for r in args.repo if r and r.strip()))
        if len(unique_repos) > MAX_LIVE_REPOS:
            parser.error(f"--repo accepts at most {MAX_LIVE_REPOS} repositories in live mode to preserve GitHub REST headroom")

    if args.out_html:
        state = build_operator_state(
            audit_dir=args.audit_dir,
            hosts_json=args.hosts_json,
            cmux_json=args.cmux_json,
            github_json=args.github_json,
            latency_json=args.latency_json,
            repos=args.repo,
            linux_host=args.linux_host,
            cmux_cmd=args.cmux_cmd,
        )
        out = Path(args.out_html)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render_html(state, auto_refresh_ms=0), encoding="utf-8")
        print(f"Wrote operator dashboard: {out}")
        if not args.serve:
            return 0

    if args.serve:
        server = create_server(
            host="127.0.0.1",
            port=args.port,
            audit_dir=args.audit_dir,
            hosts_json=args.hosts_json,
            cmux_json=args.cmux_json,
            github_json=args.github_json,
            latency_json=args.latency_json,
            repos=args.repo,
            linux_host=args.linux_host,
            cmux_cmd=args.cmux_cmd,
        )
        print(f"Serving operator live dashboard on http://127.0.0.1:{server.server_address[1]}/")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.shutdown()
            server.server_close()
        return 0

    if not args.out_html and not args.serve:
        parser.error("Specify --out-html <path> and/or --serve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
