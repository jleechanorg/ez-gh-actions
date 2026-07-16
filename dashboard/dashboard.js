(function () {
  'use strict';

  const STALE_AFTER_MS = 20 * 60 * 1000;
  const SOURCE_KEYS = ['linux_host', 'mac_host'];
  const EXPECTED_CONFIGURED = { mac: 6, linux: 10 };
  const FLEET_KEYS = [
    'configured',
    'executing',
    'idle',
    'cycling',
    'down',
    'reserved',
  ];

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
    const element = document.getElementById(id);
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

  function sourceContract(snapshot) {
    const keys = Object.keys(snapshot.sources || {}).sort();
    return (
      snapshot.schema_version === 1 &&
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
    const allDown =
      fleet.configured > 0 &&
      fleet.down === fleet.configured &&
      fleet.executing === 0 &&
      fleet.idle === 0 &&
      fleet.cycling === 0;
    const diskValid =
      (sources.disk?.ok === true &&
        ['healthy', 'critical'].includes(host?.disk?.status)) ||
      (allDown &&
        sources.disk?.ok === false &&
        host?.disk?.status === 'unknown');
    return (
      Object.keys(sources).sort().join(',') === sourceKeys.join(',') &&
      requiredSourceKeys
        .filter((key) => key !== 'disk')
        .every((key) => sources[key]?.ok === true) &&
      diskValid &&
      typeof sources.watchdog_state?.ok === 'boolean' &&
      FLEET_KEYS.every((key) => isCount(fleet[key])) &&
      fleet.configured === EXPECTED_CONFIGURED[fleetName] &&
      fleet.executing + fleet.idle + fleet.cycling + fleet.down ===
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
    return {
      state: 'live',
      kicker: 'LOCAL CAPACITY SNAPSHOT',
      detail:
        'Local capacity probes report 6 Mac and 10 Linux slots executing. Queue health is not measured by this dashboard.',
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
    document.getElementById('status-banner').dataset.state = 'stale';
    setText('status-kicker', 'STALE / UNKNOWN');
    setText('status-detail', reason);
    setText('last-observed', 'unavailable');
    setText('last-published', 'unavailable');
    announceStatus('stale');
  }

  function render(snapshot, nowMs = Date.now()) {
    const status = classifySnapshot(snapshot, nowMs);
    document.getElementById('status-banner').dataset.state = status.state;
    setText('status-kicker', status.kicker);
    setText('status-detail', status.detail);
    setText('last-observed', new Date(snapshot.observed_at).toLocaleString());
    setText('last-published', new Date(snapshot.published_at).toLocaleString());
    announceStatus(status.state);

    for (const fleetName of ['mac', 'linux']) {
      const host = snapshot.fleets?.[fleetName] || {};
      const fleet = host.fleet || {};
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
      setText(
        `${fleetName}-disk`,
        String(host.disk?.status || 'unknown').toUpperCase(),
      );
      setText(
        `${fleetName}-watchdog`,
        count(host.watchdog?.consecutive_misses),
      );
      const sourceKey = `${fleetName}_host`;
      setText(
        `${fleetName}-source`,
        snapshot.sources?.[sourceKey]?.ok === true ? 'VERIFIED' : 'UNKNOWN',
      );
    }
    setText(
      'watchdog-trip',
      `M ${count(snapshot.fleets?.mac?.watchdog?.restart_after)} / L ${count(
        snapshot.fleets?.linux?.watchdog?.restart_after,
      )}`,
    );
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
  };
  if (typeof document !== 'undefined') {
    window.addEventListener('DOMContentLoaded', () => {
      loadStatus();
      window.setInterval(loadStatus, 60 * 1000);
    });
  }
})();
