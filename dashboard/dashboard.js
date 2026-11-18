(function () {
  'use strict';

  const STALE_AFTER_MS = 20 * 60 * 1000;
  const SOURCE_KEYS = ['linux_host', 'mac_host'];
  // Retained [4, 6] and [10, 20] for historical UI unit-fixture compatibility;
  // build_runner_dashboard_snapshot.py enforces the live {4, 20} fleet counts.
  const EXPECTED_CONFIGURED = { mac: [4, 6], linux: [10, 20] };
  const FLEET_KEYS = [
    'configured',
    'executing',
    'idle',
    'cycling',
    'down',
    'reserved',
  ];

  function byId(id) {
    try {
      return typeof document !== 'undefined' ? document.getElementById(id) || null : null;
    } catch (_error) {
      return null;
    }
  }

  function classifyFreshness(timestamp, nowMs = Date.now()) {
    const observedMs = Date.parse(timestamp);
    if (!timestamp || !Number.isFinite(observedMs)) {
      return { state: 'stale', reason: 'timestamp unavailable' };
    }
    const ageMs = nowMs - observedMs;
    if (ageMs < 0)
      return { state: 'stale', reason: 'publisher clock is ahead' };
    if (ageMs > STALE_AFTER_MS) {
      return {
        state: 'stale',
        reason: 'publisher has not checked in for 20 minutes',
      };
    }
    return { state: 'fresh', reason: 'publisher checked in recently' };
  }

  function setText(id, value) {
    const element = byId(id);
    const nextValue = value ?? 'UNKNOWN';
    if (element && element.textContent !== nextValue)
      element.textContent = nextValue;
  }

  function isCount(value) {
    return Number.isInteger(value) && value >= 0;
  }

  function count(value) {
    return isCount(value) ? String(value) : '—';
  }

  function formatDurationSeconds(seconds) {
    if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) {
      return '—';
    }
    const rounded = Math.round(seconds);
    if (rounded < 60) return `${rounded}s`;
    const mins = Math.floor(rounded / 60);
    const rem = rounded % 60;
    return rem === 0 ? `${mins}m` : `${mins}m ${rem}s`;
  }

  function sourceContract(snapshot) {
    const keys = Object.keys(snapshot.sources || {}).sort();
    return (
      (snapshot.schema_version === 1 || snapshot.schema_version === 2) &&
      keys.length === SOURCE_KEYS.length &&
      SOURCE_KEYS.every((key, index) => key === keys[index]) &&
      keys.every((key) => typeof snapshot.sources[key]?.ok === 'boolean')
    );
  }

  function validFleet(host, fleetName) {
    const fleet = host?.fleet || {};
    const sources = host?.sources || {};
    const sourceKeys = [
      'config',
      'disk',
      'docker',
      'process_probe',
      'service',
      'watchdog_state',
    ];
    const requiredSourceKeys = sourceKeys.filter(
      (key) => key !== 'watchdog_state',
    );
    const watchdogAvailable = sources.watchdog_state?.ok === true;
    const isParked = host?.parked === true;
    const parkedSlots = isParked
      ? isCount(host?.parked_slots)
        ? host.parked_slots
        : fleet.configured
      : 0;
    const allDown =
      !isParked &&
      fleet.configured > 0 &&
      fleet.down === fleet.configured &&
      fleet.executing === 0 &&
      fleet.idle === 0 &&
      fleet.cycling === 0;
    const allowedConfigured = EXPECTED_CONFIGURED[fleetName] || [];
    const parkedValid =
      isParked &&
      sources.config?.ok === true &&
      fleet.down === 0 &&
      fleet.executing === 0 &&
      fleet.idle === 0 &&
      fleet.cycling === 0 &&
      parkedSlots === fleet.configured;
    const diskValid =
      (sources.disk?.ok === true &&
        ['healthy', 'critical'].includes(host?.disk?.status)) ||
      (allDown &&
        sources.disk?.ok === false &&
        host?.disk?.status === 'unknown') ||
      parkedValid;
    const probesValid =
      requiredSourceKeys
        .filter((key) => key !== 'disk')
        .every((key) => sources[key]?.ok === true) || parkedValid;
    return (
      Object.keys(sources).sort().join(',') === sourceKeys.join(',') &&
      probesValid &&
      diskValid &&
      typeof sources.watchdog_state?.ok === 'boolean' &&
      FLEET_KEYS.every((key) => isCount(fleet[key])) &&
      allowedConfigured.includes(fleet.configured) &&
      fleet.executing + fleet.idle + fleet.cycling + fleet.down + parkedSlots ===
        fleet.configured &&
      fleet.reserved <= fleet.configured &&
      ((watchdogAvailable &&
        isCount(host?.watchdog?.consecutive_misses) &&
        Number.isInteger(host?.watchdog?.restart_after) &&
        host.watchdog.restart_after > 0) ||
        (!watchdogAvailable &&
          host?.watchdog?.consecutive_misses === null &&
          host?.watchdog?.restart_after === null))
    );
  }

  function criticalReasons(snapshot) {
    const reasons = [];
    for (const [name, key] of [
      ['Mac', 'mac'],
      ['Linux', 'linux'],
    ]) {
      const host = snapshot.fleets?.[key] || {};
      const fleet = host.fleet || {};
      if (
        host.parked !== true &&
        isCount(fleet.down) &&
        fleet.down === fleet.configured &&
        fleet.configured > 0
      ) {
        reasons.push(`${name} fleet down`);
      }
      if (host.disk?.status === 'critical')
        reasons.push(`${name} disk critical`);
      if (
        isCount(host.watchdog?.consecutive_misses) &&
        host.watchdog?.consecutive_misses >= host.watchdog?.restart_after
      )
        reasons.push(`${name} watchdog threshold reached`);
    }
    return reasons;
  }

  function degradedReasons(snapshot) {
    const reasons = [];
    for (const [name, key] of [
      ['Mac', 'mac'],
      ['Linux', 'linux'],
    ]) {
      const host = snapshot.fleets[key];
      const fleet = host.fleet;
      if (host.parked === true) {
        const parkedCount = isCount(host.parked_slots)
          ? host.parked_slots
          : fleet.configured;
        reasons.push(`${name} fleet intentionally parked (${parkedCount} slot(s))`);
        continue;
      }
      if (fleet.down > 0)
        reasons.push(`${name} has ${fleet.down} down slot(s)`);
      if (fleet.cycling > 0)
        reasons.push(`${name} has ${fleet.cycling} cycling slot(s)`);
      if (fleet.idle > 0) {
        reasons.push(
          `${name} has ${fleet.idle} idle slot(s) without queue-health proof`,
        );
      }
      if (fleet.executing + fleet.idle + fleet.cycling < fleet.configured) {
        reasons.push(`${name} live fleet short`);
      }
      if (fleet.reserved < fleet.configured) {
        reasons.push(`${name} reserved slots short`);
      }
      if (host.watchdog.consecutive_misses > 0) {
        reasons.push(`${name} watchdog shortfall`);
      }
      if (host.sources.watchdog_state.ok !== true) {
        reasons.push(`${name} watchdog inactive or stale`);
      }
    }
    return reasons;
  }

  function classifySnapshot(snapshot, nowMs = Date.now()) {
    const published = classifyFreshness(snapshot.published_at, nowMs);
    const observed = classifyFreshness(snapshot.observed_at, nowMs);
    if (published.state === 'stale' || observed.state === 'stale') {
      return {
        state: 'stale',
        kicker: 'STALE / UNKNOWN',
        detail:
          published.state === 'stale' ? published.reason : observed.reason,
      };
    }
    if (!sourceContract(snapshot)) {
      return {
        state: 'stale',
        kicker: 'STALE / UNKNOWN',
        detail: 'Snapshot contract is unavailable.',
      };
    }

    if (
      !SOURCE_KEYS.every((key) => snapshot.sources[key].ok) ||
      !validFleet(snapshot.fleets?.mac, 'mac') ||
      !validFleet(snapshot.fleets?.linux, 'linux')
    ) {
      return {
        state: 'stale',
        kicker: 'STALE / UNKNOWN',
        detail: 'One or more local-truth probes are unavailable.',
      };
    }

    const critical = criticalReasons(snapshot);
    if (critical.length > 0) {
      return {
        state: 'critical',
        kicker: 'LIVE / CRITICAL',
        detail: `${critical.join('; ')}.`,
      };
    }

    const degraded = degradedReasons(snapshot);
    if (degraded.length > 0) {
      return {
        state: 'degraded',
        kicker: 'LIVE / DEGRADED',
        detail: `${degraded.join('; ')}.`,
      };
    }
    const macTarget = snapshot.fleets.mac.fleet.configured;
    const linuxTarget = snapshot.fleets.linux.fleet.configured;
    return {
      state: 'live',
      kicker: 'LOCAL CAPACITY SNAPSHOT',
      detail:
        `Local capacity probes report ${macTarget} Mac and ${linuxTarget} Linux slots executing. Queue health is not measured by this dashboard.`,
    };
  }

  function announceStatus(state) {
    const announcements = {
      live: 'Runner local capacity status: live snapshot. Queue health not measured.',
      degraded: 'Runner status: live degraded.',
      critical: 'Runner status: live critical.',
      stale: 'Runner status: stale or unknown.',
    };
    setText('status-announcement', announcements[state]);
  }

  function renderFailure(reason) {
    const banner = byId('status-banner');
    if (banner) banner.dataset.state = 'stale';
    setText('status-kicker', 'STALE / UNKNOWN');
    setText('status-detail', reason);
    setText('last-observed', 'unavailable');
    setText('last-published', 'unavailable');
    announceStatus('stale');
  }

  function buildSlotChip(slot, fallbackPrefix = 'slot') {
    const chip = document.createElement('div');
    const state = String(slot.state || 'DOWN').toUpperCase();
    chip.className = `slot-chip slot-chip--${state.toLowerCase()}`;
    const title = document.createElement('span');
    title.className = 'slot-chip-id';
    title.textContent = slot.slot_id || `${fallbackPrefix}-${slot.slot || '?'}`;
    const meta = document.createElement('span');
    meta.className = 'slot-chip-meta';
    const parts = [state];
    if (typeof slot.elapsed_minutes === 'number') {
      parts.push(`${slot.elapsed_minutes}m`);
    }
    if (slot.phase_badge) parts.push(slot.phase_badge);
    meta.textContent = parts.join(' · ');
    chip.appendChild(title);
    chip.appendChild(meta);
    return chip;
  }

  function renderSlotChips(containerId, slots, fallbackPrefix = 'slot') {
    const container = byId(containerId);
    if (!container || typeof document?.createElement !== 'function') return;
    if (typeof container.replaceChildren === 'function') {
      container.replaceChildren();
    }
    if (!Array.isArray(slots) || slots.length === 0) return;
    for (const slot of slots) {
      if (!slot || typeof slot !== 'object') continue;
      container.appendChild(buildSlotChip(slot, fallbackPrefix));
    }
  }

  function renderReconciliation(reconcile, snapshot) {
    const data = reconcile || {};
    const macValid = snapshot.sources?.mac_host?.ok === true;
    const linuxValid = snapshot.sources?.linux_host?.ok === true;
    const cmux = snapshot.cmux?.ok ? snapshot.cmux : null;
    const validPools = [
      ...(macValid ? [snapshot.fleets?.mac?.fleet || {}] : []),
      ...(linuxValid ? [snapshot.fleets?.linux?.fleet || {}] : []),
      ...(cmux ? [cmux] : []),
    ];
    const sumPools = (key) => {
      if (validPools.length === 0) return null;
      const vals = validPools.map((p) => p[key]).filter(isCount);
      return vals.length === validPools.length ? vals.reduce((a, b) => a + b, 0) : null;
    };

    const occupied = isCount(data.active_job_slots_occupied)
      ? data.active_job_slots_occupied
      : sumPools('executing');
    const idle = isCount(data.idle_slots) ? data.idle_slots : sumPools('idle');
    const down = isCount(data.down_slots) ? data.down_slots : sumPools('down');
    const cycling = isCount(data.cycling_slots) ? data.cycling_slots : sumPools('cycling');
    const parked = isCount(data.parked_slots)
      ? data.parked_slots
      : macValid || linuxValid
        ? (macValid ? snapshot.fleets?.mac?.parked_slots || 0 : 0) +
          (linuxValid ? snapshot.fleets?.linux?.parked_slots || 0 : 0)
        : null;

    setText('reconcile-runs', count(data.active_workflow_runs));
    setText('reconcile-slots', count(occupied));
    setText('reconcile-idle', count(idle));
    setText(
      'reconcile-unavailable',
      `${count(down)}D / ${count(parked)}P / ${count(cycling)}C`,
    );
    setText('reconcile-fresh', count(data.fresh_queued_runs ?? snapshot.queue?.fresh));
    setText('reconcile-ghosts', count(data.inert_ghosts ?? snapshot.queue?.ghosts));
    setText(
      'reconcile-summary',
      data.explanation ||
        (occupied !== null
          ? `${occupied} occupied local runner slots across verified pools (${count(down)} down, ${count(parked)} parked, ${count(cycling)} cycling).`
          : 'Run-vs-slot reconciliation unavailable for unverified hosts.'),
    );
  }

  function renderCmux(cmux) {
    const valid = cmux && cmux.ok === true;
    const badge = byId('cmux-state-badge');
    if (!valid) {
      setText('cmux-state-badge', 'UNAVAILABLE');
      if (badge) badge.dataset.state = 'stale';
      setText('cmux-summary', 'cmux Cloud VM pool telemetry unavailable this snapshot.');
      for (const metric of ['target', 'executing', 'idle', 'cycling', 'down']) {
        setText(`cmux-${metric}`, '—');
      }
      renderSlotChips('cmux-slots', []);
      return;
    }
    setText('cmux-state-badge', `${count(cmux.executing)}/${count(cmux.configured)} EXEC`);
    if (badge) badge.dataset.state = cmux.down > 0 ? 'degraded' : 'live';
    setText('cmux-target', count(cmux.configured));
    setText('cmux-executing', count(cmux.executing));
    setText('cmux-idle', count(cmux.idle));
    setText('cmux-cycling', count(cmux.cycling));
    setText('cmux-down', count(cmux.down));
    const vms = Array.isArray(cmux.vms) ? cmux.vms : [];
    setText(
      'cmux-summary',
      `${vms.length} active cmux Cloud VM(s) providing ${count(cmux.configured)} Linux X64 slots (${count(cmux.executing)} executing, ${count(cmux.cycling)} cycling).`,
    );
    const container = byId('cmux-slots');
    if (!container || typeof document?.createElement !== 'function') return;
    if (typeof container.replaceChildren === 'function') {
      container.replaceChildren();
    }
    for (const vm of vms) {
      if (!vm || typeof vm !== 'object') continue;
      const card = document.createElement('div');
      card.className = 'cmux-vm-card';
      const head = document.createElement('p');
      head.className = 'cmux-vm-title';
      const diskTxt =
        vm.disk_status && vm.disk_status !== 'unknown'
          ? ` · disk ${String(vm.disk_status).toUpperCase()}`
          : '';
      head.textContent = `${vm.vm_id || 'cloud-vm'} — ${count(vm.executing)}/${count(vm.configured)} exec${diskTxt}`;
      card.appendChild(head);
      const grid = document.createElement('div');
      grid.className = 'slot-grid';
      for (const slot of vm.slots || []) {
        if (!slot || typeof slot !== 'object') continue;
        grid.appendChild(buildSlotChip(slot, vm.vm_id || 'cloud-slot'));
      }
      card.appendChild(grid);
      container.appendChild(card);
    }
  }

  function renderLatency(latency) {
    const valid = latency && latency.ok === true;
    const workflowsEl = byId('latency-workflows');
    if (workflowsEl && typeof workflowsEl.replaceChildren === 'function') {
      workflowsEl.replaceChildren();
    }
    if (!valid) {
      setText('latency-summary', 'CI latency percentiles unavailable this snapshot.');
      setText('latency-cancel-rate', 'CANCELLED: —');
      for (const clock of ['queue', 'exec', 'e2e']) {
        for (const stat of ['avg', 'p50', 'p90', 'p99']) {
          setText(`latency-${clock}-${stat}`, '—');
        }
      }
      return;
    }

    const overall = latency.overall || {};
    const map = [
      ['queue', overall.queue_wait || {}],
      ['exec', overall.execution || {}],
      ['e2e', overall.e2e || {}],
    ];
    for (const [prefix, block] of map) {
      setText(`latency-${prefix}-avg`, formatDurationSeconds(block.avg_s));
      setText(`latency-${prefix}-p50`, formatDurationSeconds(block.p50_s));
      setText(`latency-${prefix}-p90`, formatDurationSeconds(block.p90_s));
      setText(`latency-${prefix}-p99`, formatDurationSeconds(block.p99_s));
    }

    const cancel = latency.cancellation || {};
    const cancelPct =
      typeof cancel.cancelled_rate_pct === 'number'
        ? `${cancel.cancelled_rate_pct}% (${count(cancel.cancelled_runs)}/${count(cancel.total_non_skipped_runs)})`
        : '—';
    const cohortLabel =
      latency.cohort === 'success'
        ? 'successful runs'
        : latency.cohort === 'all_non_skipped'
          ? 'non-skipped runs'
          : 'recent completed runs';
    setText('latency-cancel-rate', `CANCELLED: ${cancelPct}`);
    setText(
      'latency-summary',
      `Recent ${cohortLabel}: Queue Wait p50 ${formatDurationSeconds(overall.queue_wait?.p50_s)} · Job Exec p50 ${formatDurationSeconds(overall.execution?.p50_s)} · E2E p50 ${formatDurationSeconds(overall.e2e?.p50_s)}.`,
    );

    if (!workflowsEl || typeof document?.createElement !== 'function') return;
    for (const wf of latency.workflows || []) {
      if (!wf || typeof wf.workflow !== 'string') continue;
      const row = document.createElement('div');
      row.className = 'latency-wf-row';
      const name = document.createElement('span');
      name.className = 'latency-wf-name';
      name.textContent = wf.repo ? `${wf.repo} // ${wf.workflow}` : wf.workflow;
      const metrics = document.createElement('span');
      metrics.className = 'latency-wf-metrics';
      metrics.textContent =
        `Q p50 ${formatDurationSeconds(wf.queue_wait?.p50_s)} / p90 ${formatDurationSeconds(wf.queue_wait?.p90_s)} | ` +
        `E avg ${formatDurationSeconds(wf.execution?.avg_s)} / p50 ${formatDurationSeconds(wf.execution?.p50_s)} / p90 ${formatDurationSeconds(wf.execution?.p90_s)} / p99 ${formatDurationSeconds(wf.execution?.p99_s)} | ` +
        `E2E p50 ${formatDurationSeconds(wf.e2e?.p50_s)} / p90 ${formatDurationSeconds(wf.e2e?.p90_s)}`;
      row.appendChild(name);
      row.appendChild(metrics);
      workflowsEl.appendChild(row);
    }
  }

  function render(snapshot, nowMs = Date.now()) {
    const status = classifySnapshot(snapshot, nowMs);
    const banner = byId('status-banner');
    if (banner) banner.dataset.state = status.state;
    setText('status-kicker', status.kicker);
    setText('status-detail', status.detail);
    setText('last-observed', new Date(snapshot.observed_at).toLocaleString());
    setText('last-published', new Date(snapshot.published_at).toLocaleString());
    announceStatus(status.state);

    for (const fleetName of ['mac', 'linux']) {
      const host = snapshot.fleets?.[fleetName] || {};
      const fleet = host.fleet || {};
      const sourceOk = snapshot.sources?.[`${fleetName}_host`]?.ok === true;
      setText(`${fleetName}-target`, count(fleet.configured));
      for (const metric of [
        'executing',
        'idle',
        'cycling',
        'down',
        'reserved',
      ]) {
        setText(`${fleetName}-${metric}`, count(fleet[metric]));
      }
      if (fleetName === 'mac') {
        setText('mac-parked', count(host.parked_slots ?? 0));
      }
      const badge = byId(`${fleetName}-state-badge`);
      if (!sourceOk) {
        setText(`${fleetName}-state-badge`, 'UNAVAILABLE');
        if (badge) badge.dataset.state = 'stale';
      } else if (host.parked === true) {
        setText(`${fleetName}-state-badge`, 'PARKED');
        if (badge) badge.dataset.state = 'parked';
      } else if (fleet.down > 0) {
        setText(`${fleetName}-state-badge`, `${fleet.down} DOWN`);
        if (badge) badge.dataset.state = 'critical';
      } else {
        setText(`${fleetName}-state-badge`, 'ONLINE');
        if (badge) badge.dataset.state = 'live';
      }
      const diskLabel = String(host.disk?.status || 'unknown').toUpperCase();
      setText(`${fleetName}-disk`, diskLabel);
      const pauseText = host.pause_reason || host.parked_reason || null;
      setText(`${fleetName}-pause-reason`, pauseText || diskLabel);
      setText(
        `${fleetName}-watchdog`,
        count(host.watchdog?.consecutive_misses),
      );
      const sourceKey = `${fleetName}_host`;
      setText(
        `${fleetName}-source`,
        snapshot.sources?.[sourceKey]?.ok === true ? 'VERIFIED' : 'UNKNOWN',
      );
      renderSlotChips(`${fleetName}-slots`, host.slots || []);
    }
    setText(
      'watchdog-trip',
      `M ${count(snapshot.fleets?.mac?.watchdog?.restart_after)} / L ${count(
        snapshot.fleets?.linux?.watchdog?.restart_after,
      )}`,
    );
    renderReconciliation(snapshot.reconciliation, snapshot);
    renderCmux(snapshot.cmux);
    renderLatency(snapshot.latency);
    renderQueue(snapshot.queue);
  }

  // The queue block exists so a human never has to guess whether a backlog number
  // is real work or GitHub ghost runs. Ghosts are queued runs with zero jobs that
  // GitHub refuses to transition -- they can never start. They are shown, greyed,
  // and explicitly excluded from the number that reads as backlog.
  function renderQueue(queue) {
    const repos = byId('queue-repos');
    if (repos && typeof repos.replaceChildren === 'function') {
      repos.replaceChildren();
    }

    const valid =
      queue &&
      queue.ok === true &&
      isCount(queue.fresh) &&
      isCount(queue.ghosts);

    if (!valid) {
      setText('queue-fresh', '—');
      setText('queue-ghosts', '—');
      setText('queue-oldest', '—');
      setText(
        'queue-summary',
        'Queue breakdown unavailable this snapshot — treat waiting work as unknown, not zero.',
      );
      byId('queue-fresh')?.classList?.add?.('is-unknown');
      byId('queue-ghosts')?.classList?.add?.('is-unknown');
      return;
    }

    byId('queue-fresh')?.classList?.remove?.('is-unknown');
    byId('queue-ghosts')?.classList?.remove?.('is-unknown');
    setText('queue-fresh', String(queue.fresh));
    setText('queue-ghosts', String(queue.ghosts));
    setText(
      'queue-oldest',
      isCount(queue.oldest_fresh_wait_minutes)
        ? `${queue.oldest_fresh_wait_minutes} min`
        : '—',
    );

    const total = queue.fresh + queue.ghosts;
    setText(
      'queue-summary',
      total === 0
        ? 'Nothing queued: no waiting work and no ghosts.'
        : `${queue.fresh} of ${total} queued runs are real waiting work; ` +
          `${queue.ghosts} are ghosts GitHub will not release.`,
    );

    if (!repos || typeof repos.appendChild !== 'function') return;
    for (const entry of queue.repos || []) {
      if (!entry || typeof entry.repo !== 'string') continue;
      const row = document.createElement('p');
      row.className = 'queue-repo-row';
      const fresh = isCount(entry.fresh) ? entry.fresh : '—';
      const ghosts = isCount(entry.ghosts) ? entry.ghosts : '—';
      row.textContent = `${entry.repo} — fresh ${fresh}, ghosts ${ghosts}`;
      repos.appendChild(row);
    }
  }

  async function loadStatus() {
    try {
      const response = await fetch(`status.json?ts=${Date.now()}`, {
        cache: 'no-store',
      });
      if (!response.ok) throw new Error('snapshot request failed');
      render(await response.json());
    } catch (_error) {
      renderFailure(
        'Snapshot could not be loaded. Treat fleet state as unknown.',
      );
    }
  }

  globalThis.RunnerStatusDashboard = {
    classifyFreshness,
    classifySnapshot,
    render,
    renderQueue,
  };
  if (typeof document !== 'undefined') {
    window.addEventListener('DOMContentLoaded', () => {
      loadStatus();
      window.setInterval(loadStatus, 60 * 1000);
    });
  }
})();
