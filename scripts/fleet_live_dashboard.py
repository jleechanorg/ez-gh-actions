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
import inspect
import json
import math
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
import urllib.parse
from pathlib import Path

SCRIPT_DIR = str(Path(__file__).resolve().parent)
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import ci_latency_probe  # noqa: E402
import queue_probe  # noqa: E402

_LIVE_LATENCY_CACHE = {"key": None, "ts": 0.0, "attempt_ts": None, "data": None, "error": None}
_LIVE_LATENCY_TTL_S = 300.0
MAX_LIVE_REPOS = 3
DEFAULT_MIN_FREE_DISK_GB = 10
IDLE_STARVED_THRESHOLD_MIN = 5.0


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


def _reject_non_finite(token):
    raise ValueError(f"non-finite JSON constant: {token}")


def _parse_finite_float(token):
    val = float(token)
    if not math.isfinite(val):
        raise ValueError(f"non-finite JSON float: {token}")
    return val


def _load_json_checked(path, *, validator=None, invalid_reason="invalid fixture schema"):
    if not path:
        return None, None
    p = Path(path)
    try:
        if not p.is_file():
            return None, f"missing or non-file: {p}"
        data = json.loads(
            p.read_text(encoding="utf-8"),
            parse_constant=_reject_non_finite,
            parse_float=_parse_finite_float,
        )
        # Reject escaped lone surrogates (e.g. "\ud800") up front so UTF-8 responses fail closed.
        json.dumps(data, ensure_ascii=False, allow_nan=False).encode("utf-8")
        if not isinstance(data, dict):
            return None, f"expected JSON object in {p}"
        if validator is not None and not validator(data):
            return None, f"{invalid_reason} in {p}"
        return data, None
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return None, f"{type(exc).__name__} reading {p}"


def _is_valid_hosts_payload(data):
    return isinstance(data.get("hosts"), dict)


def _is_valid_cmux_payload(data):
    if data.get("ok") is False:
        return True
    raw_vms = data.get("cmux_vms") if "cmux_vms" in data else data.get("vms")
    if not isinstance(raw_vms, list):
        return False
    for vm in raw_vms:
        if not isinstance(vm, dict):
            return False
        vm_name = vm.get("short") or vm.get("slug") or vm.get("id") or vm.get("name") or vm.get("vm_id")
        if not isinstance(vm_name, str) or not vm_name.strip():
            return False
        if not isinstance(vm.get("slots"), list):
            return False
    return True


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


def _validate_normalized_latency_shape(data):
    if not isinstance(data.get("overall"), dict) or not isinstance(data.get("workflows"), list):
        return False
    for stat_k in ("queue_wait", "execution", "job_total", "e2e"):
        if data["overall"].get(stat_k) is not None and not isinstance(data["overall"].get(stat_k), dict):
            return False
    for dict_key in ("cohorts", "runner_classes", "step_categories", "cancellation", "pr_critical_path"):
        sec = data.get(dict_key)
        if sec is not None and not isinstance(sec, dict):
            return False
    cohorts = data.get("cohorts")
    if isinstance(cohorts, dict):
        for cv in cohorts.values():
            if not isinstance(cv, dict):
                return False
            for stat_k in ("queue_wait", "execution", "job_total", "e2e"):
                if cv.get(stat_k) is not None and not isinstance(cv.get(stat_k), dict):
                    return False
    runner_classes = data.get("runner_classes")
    if isinstance(runner_classes, dict):
        for rv in runner_classes.values():
            if not isinstance(rv, dict):
                return False
            rc = rv.get("cohorts")
            if rc is not None and (not isinstance(rc, dict) or not all(isinstance(v, dict) for v in rc.values())):
                return False
    step_categories = data.get("step_categories")
    if isinstance(step_categories, dict):
        if not all(isinstance(sv, dict) for sv in step_categories.values()):
            return False
    for wf in data["workflows"]:
        if not isinstance(wf, dict):
            return False
        w_coh = wf.get("cohorts")
        if w_coh is not None and (not isinstance(w_coh, dict) or not all(isinstance(v, dict) for v in w_coh.values())):
            return False
        for ck in ("queue_wait", "execution", "e2e", "success", "all_non_skipped", "failure", "cancelled"):
            if wf.get(ck) is not None and not isinstance(wf.get(ck), dict):
                return False
    return True


def _is_valid_latency_payload(data):
    if data.get("ok") is False:
        return True
    if "overall" in data and "workflows" in data:
        return _validate_normalized_latency_shape(data)
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
        "managed_pool": bool(slot_raw.get("managed_pool", False)),
        "kind": slot_raw.get("kind") if isinstance(slot_raw.get("kind"), str) and slot_raw.get("kind").strip() else None,
        "scope": slot_raw.get("scope") if isinstance(slot_raw.get("scope"), str) and slot_raw.get("scope").strip() else None,
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
    except (TypeError, ValueError, KeyError, AttributeError, IndexError, ArithmeticError) as exc:
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
                    {**s, "managed_pool": True, "kind": s.get("kind") or "container"},
                    gh_by_runner,
                    gh_by_run_job,
                    host_disk_paused=paused,
                    label=f"hosts.{host_key}.slots",
                    errors=errors,
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
        except (TypeError, ValueError, KeyError, AttributeError, IndexError, ArithmeticError) as exc:
            _record_norm_error(errors, f"hosts.{host_key}: {exc}")

    if isinstance(cmux_data, dict):
        vms_raw = cmux_data.get("cmux_vms") if cmux_data.get("cmux_vms") is not None else cmux_data.get("vms")
        vms = _as_dict_list(vms_raw, "cmux.vms", errors)
        for vm in vms:
            try:
                short = vm.get("short") or vm.get("slug") or vm.get("id") or vm.get("name") or vm.get("vm_id")
                if not isinstance(short, str) or not short.strip():
                    raise ValueError("cmux vm missing valid string name/short/id")
                if not isinstance(vm.get("slots"), list):
                    raise ValueError("cmux vm missing slots list")
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
                        {**s, "managed_pool": True, "kind": s.get("kind") or "container"},
                        gh_by_runner,
                        gh_by_run_job,
                        host_disk_paused=False,
                        label="cmux.vm.slots",
                        errors=errors,
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
            except (TypeError, ValueError, KeyError, AttributeError, IndexError, ArithmeticError) as exc:
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
                    _safe_enrich_slot(
                        {**s, "managed_pool": True, "kind": s.get("kind") or "container"},
                        gh_by_runner,
                        gh_by_run_job,
                        label="hosts.mac.container_slots",
                        errors=errors,
                    )
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
                            "managed_pool": False,
                            "kind": "native",
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
        except (TypeError, ValueError, KeyError, AttributeError, IndexError, ArithmeticError) as exc:
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
                "scope": sp.get("scope"),
                "managed_pool": False,
                "kind": sp.get("kind") or "special",
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


def _opt_nonneg_number(value, label, errors):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        _record_norm_error(errors, f"{label}: expected non-negative number, got {type(value).__name__}")
        return None
    return float(value)


def _is_general_purpose_managed_slot(slot):
    """Return True only for general-purpose managed fleet container slots eligible for IDLE-STARVED."""
    if slot.get("managed_pool") is not True:
        return False
    kind = (slot.get("kind") or "container").strip().lower()
    if kind != "container":
        return False
    scope = (slot.get("scope") or "").strip().lower()
    return scope in ("", "org")


def _normalize_reconciliation(hosts, cmux_data, gh_data, scope_note=None, hosts_partial=False, fixture_errors=None, errors=None):
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
    oldest_wait = _opt_nonneg_number(wa_q.get("oldest_fresh_wait_minutes"), "queued_breakdown.oldest_fresh_wait_minutes", errors)
    if oldest_wait is None:
        oldest_wait = _opt_nonneg_number(gh_summary.get("oldest_fresh_wait_minutes"), "github.summary.oldest_fresh_wait_minutes", errors)

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

    idle_starved_active = (
        not q_partial
        and q_unverified_runs == 0
        and isinstance(fresh_q, int)
        and fresh_q > 0
        and oldest_wait is not None
        and oldest_wait >= IDLE_STARVED_THRESHOLD_MIN
    )

    state_counts = {
        "EXECUTING": 0,
        "CYCLING": 0,
        "IDLE": 0,
        "IDLE-STARVED": 0,
        "DOWN": 0,
        "PARKED": 0,
        "OFFLINE": 0,
        "UNKNOWN": 0,
    }
    total_slots = 0
    for h in hosts:
        for s in h["slots"]:
            if idle_starved_active and s.get("state") == "IDLE" and _is_general_purpose_managed_slot(s):
                s["state"] = "IDLE-STARVED"
                s["alert_level"] = "critical"
                s["phase_badge"] = "idle_starved"
                if not s.get("reason"):
                    s["reason"] = (
                        f"idle-starved ({fresh_q} fresh queued run(s), oldest wait "
                        f"{round(oldest_wait, 1)}m >= {int(IDLE_STARVED_THRESHOLD_MIN)}m threshold)"
                    )
            total_slots += 1
            st = s["state"]
            state_counts[st] = state_counts.get(st, 0) + 1

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
        "oldest_fresh_wait_minutes": oldest_wait,
        "idle_starved": idle_starved_active,
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
            if not _validate_normalized_latency_shape(latency_raw):
                raise ValueError("normalized latency payload failed nested schema validation")
            out = latency_raw
        else:
            out = ci_latency_probe.from_audit_data(latency_raw)
        if not isinstance(out, dict):
            raise ValueError(f"latency normalizer returned {type(out).__name__}")
        if out.get("overall") is not None and not isinstance(out.get("overall"), dict):
            raise ValueError(f"latency.overall must be dict, got {type(out.get('overall')).__name__}")
        for dict_k in ("cohorts", "runner_classes", "step_categories"):
            val = out.get(dict_k)
            if val is not None and (not isinstance(val, dict) or not all(isinstance(v, dict) for v in val.values())):
                raise ValueError(f"latency.{dict_k} entries must be objects")
        wfs = out.get("workflows")
        if wfs is not None and (not isinstance(wfs, list) or not all(isinstance(w, dict) for w in wfs)):
            raise ValueError("latency.workflows must be list of objects")
        return out
    except (TypeError, ValueError, KeyError, AttributeError, IndexError, ArithmeticError) as exc:
        msg = f"latency fixture invalid schema: {exc}"
        _record_norm_error(errors, msg)
        return empty_err(msg)


def _read_local_ezgha_config(config_path=None):
    path = Path(config_path) if config_path else (Path.home() / ".config" / "ezgha" / "config.toml")
    out = {"count": None, "name_prefix": None, "min_free_disk_gb": DEFAULT_MIN_FREE_DISK_GB}
    if not path.is_file():
        return out
    try:
        import tomllib
    except ImportError:
        tomllib = None
    if tomllib is not None:
        try:
            with path.open("rb") as handle:
                cfg = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError):
            return out
        if isinstance(cfg, dict):
            runner = cfg.get("runner") if isinstance(cfg.get("runner"), dict) else {}
            limits = cfg.get("limits") if isinstance(cfg.get("limits"), dict) else {}
            cnt = runner.get("count")
            if type(cnt) is int and cnt > 0:
                out["count"] = cnt
            prefix = runner.get("name_prefix")
            if isinstance(prefix, str) and prefix:
                out["name_prefix"] = prefix
            floor = limits.get("min_free_disk_gb")
            if type(floor) is int and floor >= 0:
                out["min_free_disk_gb"] = floor
        return out
    section = None
    try:
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            if "=" not in line:
                continue
            key, val = [part.strip() for part in line.split("=", 1)]
            clean_int = val.replace("_", "")
            if section == "runner" and key == "count" and clean_int.isdigit():
                out["count"] = int(clean_int)
            elif section == "runner" and key == "name_prefix":
                out["name_prefix"] = val.strip().strip('"').strip("'")
            elif section == "limits" and key == "min_free_disk_gb" and clean_int.isdigit():
                out["min_free_disk_gb"] = int(clean_int)
    except OSError:
        pass
    return out


def _probe_local_service_status(is_mac, run_fn=None):
    run = run_fn or subprocess.run
    try:
        if is_mac:
            proc = run(["launchctl", "list"], capture_output=True, text=True, timeout=5, errors="replace")
            if proc.returncode != 0:
                return "unknown"
            for line in proc.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[2] == "org.jleechanorg.ezgha":
                    if parts[0].isdigit():
                        return "active"
                    return "failed" if parts[1].isdigit() and int(parts[1]) != 0 else "inactive"
            return "not-loaded"
        proc = run(
            ["systemctl", "--user", "is-active", "ezgha.service"],
            capture_output=True, text=True, timeout=5, errors="replace",
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


def _detect_native_runner_scope(root_dir):
    """Read local `.runner` metadata to distinguish org-wide vs repo-scoped/unknown native runners."""
    runner_meta = Path(root_dir) / ".runner"
    try:
        data = json.loads(runner_meta.read_text(encoding="utf-8-sig", errors="replace"))
    except (OSError, json.JSONDecodeError, ValueError):
        return "unknown"
    if not isinstance(data, dict):
        return "unknown"
    gh_url = data.get("gitHubUrl") or data.get("githubUrl")
    if not isinstance(gh_url, str) or not gh_url.strip():
        return "unknown"
    parts = [seg for seg in urllib.parse.urlparse(gh_url.strip()).path.split("/") if seg]
    if len(parts) >= 2:
        return f"repo:{parts[0]}/{parts[1]}"
    if len(parts) == 1:
        return "org"
    return "unknown"


def _collect_local_native_runners():
    """Discover non-Docker native GitHub Actions runner processes running on macOS/Linux."""
    native = []
    is_mac = platform.system().lower() == "darwin"
    cmd = ["ps", "-axo", "pid=,etime=,args="] if is_mac else ["ps", "-eo", "pid=,etimes=,args="]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5, errors="replace")
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
            entry = by_dir.setdefault(
                name,
                {
                    "name": name,
                    "kind": "native",
                    "scope": _detect_native_runner_scope(root_dir),
                    "state": "IDLE",
                    "elapsed_minutes": None,
                    "active_child_commands": [],
                },
            )
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


def _probe_docker_host_core(*, is_mac=False, mac_disabled=False, cfg=None, service_status=None,
                            hostname=None, run_fn=None, disk_usage_fn=None, loadavg_fn=None):
    """Shared local/SSH Docker runner + disk-floor + load probe."""
    run = run_fn or subprocess.run
    disk_usage = disk_usage_fn or shutil.disk_usage
    get_loadavg = loadavg_fn or os.getloadavg
    cfg = cfg if isinstance(cfg, dict) else _read_local_ezgha_config()
    if service_status is None:
        service_status = _probe_local_service_status(is_mac, run_fn=run)
    host_name = hostname or socket.gethostname()

    raw_floor = cfg.get("min_free_disk_gb")
    floor_gb = raw_floor if isinstance(raw_floor, int) and not isinstance(raw_floor, bool) else None
    disk_info = {}
    free_bytes = None
    free_gb_str = None
    try:
        usage = disk_usage("/")
        free_bytes = usage.free
        raw_gib = usage.free / (1024 ** 3)
        free_gb_floor = math.floor(raw_gib * 100) / 100.0
        free_gb_str = f"{free_gb_floor:.2f}".rstrip("0").rstrip(".") or "0"
        total_gb = round(usage.total / (1024 ** 3), 1)
        use_pct = f"{round((usage.used / usage.total) * 100)}%" if usage.total else "?"
        disk_info = {
            "avail": f"{free_gb_str}G",
            "avail_bytes": usage.free,
            "total": f"{total_gb}G",
            "use_pct": use_pct,
            "min_free_disk_gb_floor": floor_gb if floor_gb is not None else "unknown",
        }
        if is_mac:
            disk_info["root_avail"] = f"{free_gb_str}G"
    except OSError:
        pass

    load_vals = []
    try:
        load_vals = [round(x, 2) for x in get_loadavg()]
    except OSError:
        pass

    floor_bytes = floor_gb * (1024 ** 3) if floor_gb is not None else None
    disk_paused = (
        not is_mac
        and not mac_disabled
        and isinstance(free_bytes, int)
        and floor_bytes is not None
        and free_bytes < floor_bytes
    )

    observed_by_name = {}
    ordered_names = []
    docker_ok = True
    try:
        proc = run(
            ["docker", "ps", "-a", "--filter", "label=ezgha=managed", "--format", "{{.Names}}\t{{.Status}}"],
            capture_output=True, text=True, timeout=10, errors="replace",
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
                    top = None
                    top_timed_out = False
                    try:
                        top = run(["docker", "top", cname, "-eo", "pid,etimes,comm,args"], capture_output=True, text=True, timeout=10, errors="replace")
                    except subprocess.TimeoutExpired:
                        top_timed_out = True
                    except OSError:
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
                        reason = "docker top timeout" if top_timed_out else "docker top probe failed"
                else:
                    if mac_disabled:
                        state = "PARKED"
                        reason = (
                            f"operator disabled (MAC_RUNNER_DISABLED=1; {cstatus})"
                            if cstatus
                            else "operator disabled (MAC_RUNNER_DISABLED=1)"
                        )
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
    if cfg.get("count") and cfg.get("name_prefix"):
        expected_names = [f"{cfg['name_prefix']}-{i}" for i in range(1, cfg["count"] + 1)]
        for idx, cname in enumerate(expected_names, start=1):
            if cname in observed_by_name:
                entry = dict(observed_by_name[cname])
                entry["slot"] = idx
                slots.append(entry)
            else:
                if mac_disabled:
                    miss_reason = "operator disabled (MAC_RUNNER_DISABLED=1)"
                elif disk_paused:
                    miss_reason = f"respawn blocked by disk-floor admission pause ({free_gb_str}G free < {floor_gb}G floor)"
                elif not docker_ok:
                    miss_reason = "docker daemon unreachable"
                else:
                    miss_reason = "container missing"
                slots.append({
                    "slot": idx,
                    "name": cname,
                    "state": "PARKED" if mac_disabled else "DOWN",
                    "elapsed_minutes": None,
                    "active_child_commands": [],
                    "reason": miss_reason,
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

    configured_count = cfg.get("count") if cfg.get("count") is not None else len(slots)
    if disk_paused:
        admission_status = "PAUSED_DISK_FLOOR"
        admission_message = f"runner admission paused: host free disk {free_gb_str}G < {floor_gb}G floor"
    elif not docker_ok:
        admission_status = f"service {service_status} / docker_unreachable"
        admission_message = None
    else:
        admission_status = service_status
        admission_message = None

    return {
        "ok": docker_ok,
        "hostname": host_name,
        "service_status": service_status,
        "disk": disk_info,
        "load_average": load_vals,
        "admission_status": admission_status,
        "admission_message": admission_message,
        "configured_slots": configured_count,
        "slots": slots,
    }


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
    probed = _probe_docker_host_core(
        is_mac=is_mac,
        mac_disabled=mac_disabled,
        cfg=cfg,
        service_status=service_status,
        hostname=hostname,
        run_fn=subprocess.run,
        disk_usage_fn=shutil.disk_usage,
        loadavg_fn=os.getloadavg,
    )
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
                    "colima_status": "running" if probed["ok"] else "unreachable",
                    "disk": probed["disk"],
                    "load_average": probed["load_average"],
                    "configured_slots": probed["configured_slots"],
                    "configured_container_slots": probed["configured_slots"],
                    "container_slots": probed["slots"],
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
                "admission_status": probed["admission_status"],
                "admission_message": probed["admission_message"],
                "disk": probed["disk"],
                "load_average": probed["load_average"],
                "configured_slots": probed["configured_slots"],
                "slots": probed["slots"],
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
    oldest_fresh_wait_min = None
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
                    ow = q_probe.get("oldest_fresh_wait_minutes")
                    if isinstance(ow, (int, float)) and not isinstance(ow, bool) and math.isfinite(ow) and ow >= 0:
                        oldest_fresh_wait_min = ow if oldest_fresh_wait_min is None else max(oldest_fresh_wait_min, ow)
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
            "oldest_fresh_wait_minutes": oldest_fresh_wait_min if fresh_complete else None,
            "queued_sample_note": "; ".join(sample_notes) if sample_notes else None,
        },
    }


def _cached_live_latency(repos):
    capped, _ = _cap_live_repos(repos or ci_latency_probe.DEFAULT_REPOS)
    target = tuple(capped)
    now = time.monotonic()
    attempt_ts = _LIVE_LATENCY_CACHE.get("attempt_ts")
    if (
        _LIVE_LATENCY_CACHE["key"] == target
        and attempt_ts is not None
        and (now - attempt_ts) < _LIVE_LATENCY_TTL_S
    ):
        if _LIVE_LATENCY_CACHE["data"] is not None:
            return _LIVE_LATENCY_CACHE["data"]
        if _LIVE_LATENCY_CACHE.get("error") is not None:
            return _LIVE_LATENCY_CACHE["error"]
    data = None
    err_payload = None
    try:
        data = ci_latency_probe.probe_latency(list(target), limit=15, job_run_limit=8)
    except Exception as exc:
        err_payload = {
            "schema_version": 1,
            "ok": False,
            "partial": True,
            "error": f"live latency probe failed: {type(exc).__name__}: {str(exc)[:160]}",
            "overall": {},
            "cancellation": {},
            "workflows": [],
            "repos": [],
        }
    finally:
        done_ts = time.monotonic()
        _LIVE_LATENCY_CACHE.update({
            "key": target,
            "ts": done_ts,
            "attempt_ts": done_ts,
            "data": data,
            "error": err_payload,
        })
    return data if data is not None else err_payload


_REMOTE_PROBE_PY = "\n".join([
    "import json, math, os, re, shutil, socket, subprocess",
    "from pathlib import Path",
    f"DEFAULT_MIN_FREE_DISK_GB = {DEFAULT_MIN_FREE_DISK_GB}",
    inspect.getsource(_read_local_ezgha_config),
    inspect.getsource(_probe_local_service_status),
    inspect.getsource(_probe_docker_host_core),
    "print(json.dumps(_probe_docker_host_core(is_mac=False)))",
])


def _collect_remote_linux_slot_payload(ssh_host):
    if not ssh_host:
        return None
    try:
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", ssh_host, "python3", "-"],
            input=_REMOTE_PROBE_PY,
            capture_output=True, text=True, timeout=25, errors="replace",
        )
        if proc.returncode == 0:
            raw = json.loads(
                proc.stdout,
                parse_constant=_reject_non_finite,
                parse_float=_parse_finite_float,
            )
            if isinstance(raw, dict) and raw.get("ok"):
                slots = raw.get("slots") if isinstance(raw.get("slots"), list) else []
                cfg_slots = raw.get("configured_slots")
                if not isinstance(cfg_slots, int) or isinstance(cfg_slots, bool):
                    cfg_slots = len(slots)
                return {
                    "display_name": f"{ssh_host} (Remote Linux Host)",
                    "group": "jeff-ubuntu",
                    "admission_status": raw.get("admission_status") or "ssh_probed",
                    "admission_message": raw.get("admission_message"),
                    "disk": raw.get("disk") if isinstance(raw.get("disk"), dict) else None,
                    "load_average": raw.get("load_average") if isinstance(raw.get("load_average"), list) else None,
                    "configured_slots": cfg_slots,
                    "slots": slots,
                }
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, ValueError):
        pass
    return None


def _collect_live_cmux(cmux_cmd):
    if not cmux_cmd:
        return None
    try:
        proc = subprocess.run(
            cmux_cmd, shell=True, capture_output=True, text=True, timeout=30, errors="replace"
        )
        if proc.returncode != 0:
            return {"ok": False, "error": f"exit {proc.returncode}"}
        data = json.loads(
            proc.stdout,
            parse_constant=_reject_non_finite,
            parse_float=_parse_finite_float,
        )
        if not isinstance(data, dict):
            return {"ok": False, "error": f"expected JSON object, got {type(data).__name__}"}
        if data.get("ok") is False:
            return data
        if not _is_valid_cmux_payload(data):
            return {"ok": False, "error": "cmux payload missing vms list"}
        return data
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, ValueError) as exc:
        return {"ok": False, "error": type(exc).__name__}


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
    cmux_fixture_errors = []
    hosts_partial = False
    if (hosts_json is not None or base is not None) and hosts_data is None:
        hosts_partial = True
        fixture_errors.append(f"hosts fixture missing or unreadable ({hosts_err or hosts_path})")
        hosts_data = {"hosts": {}}
    if (cmux_json is not None and cmux_data is None) or (base is not None and cmux_data is None and cmux_err is not None):
        hosts_partial = True
        cmux_err_msg = f"cmux fixture missing or unreadable ({cmux_err or cmux_json})"
        fixture_errors.append(cmux_err_msg)
        cmux_fixture_errors.append(cmux_err_msg)
        cmux_data = {"ok": False, "error": f"cmux fixture missing or unreadable: {cmux_err or cmux_json}"}
    elif isinstance(cmux_data, dict) and cmux_data.get("ok") is False:
        hosts_partial = True
        err_detail = str(cmux_data.get("error") or "ok=false").strip()
        cmux_err_msg = f"cmux fixture probe failed ({err_detail})"
        fixture_errors.append(cmux_err_msg)
        cmux_fixture_errors.append(cmux_err_msg)
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
    live_probe_errors = []
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
                hosts_partial = True
                missing_pools.append(f"remote-linux ({eff_linux} unreachable)")
                live_probe_errors.append(f"remote-linux SSH probe failed ({eff_linux})")
        else:
            missing_pools.append("remote-linux")
        if eff_cmux and cmux_json is None and cmux_data is None:
            cmux_data = _collect_live_cmux(eff_cmux)
            if not isinstance(cmux_data, dict) or cmux_data.get("ok") is False:
                err_detail = (
                    str(cmux_data.get("error") or "").strip()
                    if isinstance(cmux_data, dict)
                    else ""
                )
                label = f"cmux-cloud (probe failed: {err_detail})" if err_detail else "cmux-cloud (probe failed)"
                missing_pools.append(label)
                hosts_partial = True
                live_probe_errors.append(f"cmux live probe failed ({err_detail or 'ok=false'})")
                cmux_data = {"ok": False, "error": err_detail or "cmux live probe failed"}
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
    if live_probe_errors:
        if isinstance(gh_data, dict):
            existing_errs = gh_data.get("errors")
            merged_errs = list(existing_errs) if isinstance(existing_errs, list) else []
            merged_errs.extend(live_probe_errors)
            gh_data = {**gh_data, "errors": merged_errs}
        else:
            gh_data = {"errors": list(live_probe_errors)}
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
    extra_gh_errors = list(cmux_fixture_errors) + list(norm_errors)
    if extra_gh_errors:
        existing_gh_errs = list(reconciliation.get("gh_errors") or [])
        for msg in extra_gh_errors:
            if msg not in existing_gh_errs:
                existing_gh_errs.append(msg)
        reconciliation["gh_errors"] = existing_gh_errs
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
    raw = json.dumps(state, ensure_ascii=True, allow_nan=False)
    return (
        raw.replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


_TEMPLATE_PATH = Path(__file__).resolve().parent / "fleet_live_dashboard_template.html"
_TEMPLATE_TOKEN_RE = re.compile(r"__(GENERATED_AT|AUTO_REFRESH_MS|STATE_JSON)__")
_HTML_TEMPLATE_CACHE = None


def _load_html_template():
    global _HTML_TEMPLATE_CACHE
    if _HTML_TEMPLATE_CACHE is None:
        _HTML_TEMPLATE_CACHE = _TEMPLATE_PATH.read_text(encoding="utf-8")
    return _HTML_TEMPLATE_CACHE


def render_html(state, *, auto_refresh_ms=0):
    """Render a standalone, self-contained HTML dashboard with embedded state JSON."""
    replacements = {
        "GENERATED_AT": html_lib.escape(str(state.get("generated_at_utc") or "")),
        "AUTO_REFRESH_MS": str(int(auto_refresh_ms)),
        "STATE_JSON": _escape_embedded_json(state),
    }
    return _TEMPLATE_TOKEN_RE.sub(lambda match: replacements[match.group(1)], _load_html_template())

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
    cache_state = {"ts": 0.0, "attempt_ts": 0.0, "data": None, "last_error": None, "building": None}

    def _spawn_refresh_locked():
        box = {"event": threading.Event(), "data": None, "error": None}
        cache_state["attempt_ts"] = time.monotonic()
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
                    now_done = time.monotonic()
                    cache_state["data"] = fresh
                    cache_state["last_error"] = None
                    cache_state["ts"] = now_done
                    cache_state["attempt_ts"] = now_done
                    if cache_state["building"] is box:
                        cache_state["building"] = None
            except Exception as exc:
                box["error"] = exc
                with cache_lock:
                    now_fail = time.monotonic()
                    cache_state["last_error"] = exc
                    cache_state["attempt_ts"] = now_fail
                    if cache_state["data"] is not None or uses_live_github:
                        cache_state["ts"] = now_fail
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
                if (now - cache_state["attempt_ts"]) >= effective_ttl_s and cache_state["building"] is None:
                    _spawn_refresh_locked()
                return cached
            if (
                uses_live_github
                and cache_state["last_error"] is not None
                and (now - cache_state["attempt_ts"]) < effective_ttl_s
                and cache_state["building"] is None
            ):
                raise cache_state["last_error"]
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
                    payload = json.dumps(load_state(), allow_nan=False).encode("utf-8")
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
                    body = render_html(load_state(), auto_refresh_ms=effective_refresh_ms).encode(
                        "utf-8", errors="replace"
                    )
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
        out.write_text(render_html(state, auto_refresh_ms=0), encoding="utf-8", errors="replace")
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
