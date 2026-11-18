import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

await import(pathToFileURL(path.resolve('dashboard/dashboard.js')));
const { classifyFreshness, classifySnapshot, render } =
  globalThis.RunnerStatusDashboard;

const NOW = Date.parse('2026-07-14T22:30:00Z');

function host(configured) {
  return {
    sources: Object.fromEntries(
      [
        'config',
        'service',
        'docker',
        'process_probe',
        'disk',
        'watchdog_state',
      ].map((key) => [key, { ok: true }]),
    ),
    fleet: {
      configured,
      executing: configured,
      idle: 0,
      cycling: 0,
      down: 0,
      reserved: configured,
    },
    disk: { status: 'healthy' },
    watchdog: { consecutive_misses: 0, restart_after: 3 },
  };
}

const HEALTHY = {
  schema_version: 1,
  published_at: '2026-07-14T22:29:00Z',
  observed_at: '2026-07-14T22:28:00Z',
  sources: { mac_host: { ok: true }, linux_host: { ok: true } },
  fleets: { mac: host(6), linux: host(10) },
};

test('freshness fails closed after 20 minutes and for future clocks', () => {
  assert.equal(classifyFreshness('2026-07-14T22:10:00Z', NOW).state, 'fresh');
  assert.equal(classifyFreshness('2026-07-14T22:09:59Z', NOW).state, 'stale');
  assert.equal(classifyFreshness('2026-07-14T22:31:00Z', NOW).state, 'stale');
});

test('healthy exact contract is live', () => {
  const status = classifySnapshot(HEALTHY, NOW);
  assert.equal(status.state, 'live');
  assert.match(status.detail, /local capacity/i);
  assert.match(status.detail, /queue health is not measured/i);
});

test('underconfigured capacity is unknown, never healthy', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.mac.fleet.configured = 5;
  snapshot.fleets.mac.fleet.executing = 4;
  snapshot.fleets.mac.fleet.reserved = 5;
  assert.equal(classifySnapshot(snapshot, NOW).state, 'stale');
});

test('cycling capacity is degraded, never healthy', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.linux.fleet.executing -= 1;
  snapshot.fleets.linux.fleet.cycling = 1;
  assert.equal(classifySnapshot(snapshot, NOW).state, 'degraded');
});

test('idle capacity is degraded without queue-health proof', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.mac.fleet.executing -= 1;
  snapshot.fleets.mac.fleet.idle = 1;
  const status = classifySnapshot(snapshot, NOW);
  assert.equal(status.state, 'degraded');
  assert.match(status.detail, /idle/i);
});

test('one down slot is degraded', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.linux.fleet.executing -= 1;
  snapshot.fleets.linux.fleet.down = 1;
  assert.equal(classifySnapshot(snapshot, NOW).state, 'degraded');
});

test('under-reserved fleet is degraded', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.linux.fleet.reserved -= 1;
  assert.equal(classifySnapshot(snapshot, NOW).state, 'degraded');
});

test('all slots down is critical', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.mac.fleet.executing = 0;
  snapshot.fleets.mac.fleet.idle = 0;
  snapshot.fleets.mac.fleet.down = 6;
  snapshot.fleets.mac.sources.disk.ok = false;
  snapshot.fleets.mac.disk.status = 'unknown';
  assert.equal(classifySnapshot(snapshot, NOW).state, 'critical');
});

test('disk floor breach and watchdog threshold are critical', () => {
  for (const mutate of [
    (snapshot) => {
      snapshot.fleets.mac.disk.status = 'critical';
    },
    (snapshot) => {
      snapshot.fleets.linux.watchdog.consecutive_misses = 3;
    },
  ]) {
    const snapshot = structuredClone(HEALTHY);
    mutate(snapshot);
    assert.equal(classifySnapshot(snapshot, NOW).state, 'critical');
  }
});

test("watchdog severity uses each host's published restart threshold", () => {
  const below = structuredClone(HEALTHY);
  below.fleets.linux.watchdog = {
    consecutive_misses: 4,
    restart_after: 5,
  };
  assert.equal(classifySnapshot(below, NOW).state, 'degraded');

  const reached = structuredClone(below);
  reached.fleets.linux.watchdog.consecutive_misses = 5;
  assert.equal(classifySnapshot(reached, NOW).state, 'critical');
});

test('inactive watchdog is degraded without hiding live fleet truth', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.mac.sources.watchdog_state.ok = false;
  snapshot.fleets.mac.watchdog = {
    consecutive_misses: null,
    restart_after: null,
  };
  const status = classifySnapshot(snapshot, NOW);
  assert.equal(status.state, 'degraded');
  assert.match(status.detail, /watchdog/i);
});

test('invalid host contracts stay unknown before severity classification', () => {
  for (const mutate of [
    (snapshot) => {
      snapshot.sources.mac_host.ok = false;
      snapshot.fleets.mac.disk.status = 'critical';
    },
    (snapshot) => {
      snapshot.fleets.mac.fleet.down = snapshot.fleets.mac.fleet.configured;
    },
    (snapshot) => {
      snapshot.fleets.mac.watchdog = {
        consecutive_misses: 1,
        restart_after: 0,
      };
    },
  ]) {
    const snapshot = structuredClone(HEALTHY);
    mutate(snapshot);
    assert.equal(classifySnapshot(snapshot, NOW).state, 'stale');
  }
});

test('missing source and inconsistent classification are stale', () => {
  for (const mutate of [
    (snapshot) => {
      snapshot.sources.mac_host.ok = false;
    },
    (snapshot) => {
      snapshot.fleets.linux.fleet.idle = 1;
    },
    (snapshot) => {
      snapshot.fleets.mac.watchdog.consecutive_misses = null;
    },
  ]) {
    const snapshot = structuredClone(HEALTHY);
    mutate(snapshot);
    assert.equal(classifySnapshot(snapshot, NOW).state, 'stale');
  }
});

test('source contract rejects extra keys', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.sources.raw = { ok: true };
  assert.equal(classifySnapshot(snapshot, NOW).state, 'stale');
});

test('aria-live is limited to one concise announcement', async () => {
  const html = await readFile('dashboard/index.html', 'utf8');
  assert.equal((html.match(/aria-live=/g) || []).length, 1);
  assert.match(html, /id="status-announcement"[^>]*aria-live="polite"/);
  assert.doesNotMatch(html, /id="status-banner"[^>]*aria-live=/);
});

test('page copy limits its claim to local capacity', async () => {
  const html = (await readFile('dashboard/index.html', 'utf8')).replace(
    /\s+/g,
    ' ',
  );
  assert.match(html, /local capacity/i);
  assert.match(html, /does not assert queue health/i);
});

test('repeated refresh does not re-announce unchanged state', () => {
  let writes = 0;
  const elements = new Map();
  globalThis.document = {
    getElementById(id) {
      if (!elements.has(id)) {
        let value =
          id === 'status-announcement' ? 'Checking runner status.' : '';
        elements.set(id, {
          dataset: {},
          get textContent() {
            return value;
          },
          set textContent(next) {
            value = next;
            if (id === 'status-announcement') writes += 1;
          },
        });
      }
      return elements.get(id);
    },
  };
  render(HEALTHY, NOW);
  render(structuredClone(HEALTHY), NOW);
  assert.equal(writes, 1);
  assert.equal(elements.get('linux-target').textContent, '10');
  delete globalThis.document;
});

test('real 4-mac parked and 20-linux fleet classifies cleanly without false critical', () => {
  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.mac.fleet = {
    configured: 4,
    executing: 0,
    idle: 0,
    cycling: 0,
    down: 0,
    reserved: 0,
  };
  snapshot.fleets.mac.parked = true;
  snapshot.fleets.mac.parked_slots = 4;
  snapshot.fleets.mac.parked_reason = 'operator_disabled';
  snapshot.fleets.linux.fleet = {
    configured: 20,
    executing: 20,
    idle: 0,
    cycling: 0,
    down: 0,
    reserved: 20,
  };
  const status = classifySnapshot(snapshot, NOW);
  assert.notEqual(status.state, 'stale');
  assert.notEqual(status.state, 'critical');
  assert.match(status.detail, /parked/i);
});

test('renders reconciliation banner, slot chips, cmux pool, and latency panel', () => {
  const created = [];
  const elements = new Map();
  globalThis.document = {
    createElement(tag) {
      const node = {
        tagName: tag.toUpperCase(),
        className: '',
        textContent: '',
        dataset: {},
        children: [],
        appendChild(child) {
          this.children.push(child);
        },
        replaceChildren(...args) {
          this.children = args;
        },
      };
      created.push(node);
      return node;
    },
    getElementById(id) {
      if (!elements.has(id)) {
        elements.set(id, {
          dataset: {},
          textContent: '',
          children: [],
          classList: { add() {}, remove() {} },
          appendChild(child) {
            this.children.push(child);
          },
          replaceChildren(...args) {
            this.children = args;
          },
        });
      }
      return elements.get(id);
    },
  };

  const snapshot = structuredClone(HEALTHY);
  snapshot.fleets.mac.fleet = {
    configured: 4,
    executing: 0,
    idle: 0,
    cycling: 0,
    down: 0,
    reserved: 0,
  };
  snapshot.fleets.mac.parked = true;
  snapshot.fleets.mac.parked_slots = 4;
  snapshot.fleets.mac.slots = [
    { slot_id: 'mac-1', state: 'PARKED', phase_badge: 'operator_disabled' },
  ];
  snapshot.fleets.linux.fleet = {
    configured: 20,
    executing: 13,
    idle: 0,
    cycling: 0,
    down: 7,
    reserved: 20,
  };
  snapshot.fleets.linux.disk = { status: 'critical', free_gb: 25.0, floor_gb: 30 };
  snapshot.fleets.linux.pause_reason = 'disk_floor_paused';
  snapshot.fleets.linux.slots = [
    {
      slot_id: 'linux-1',
      state: 'EXECUTING',
      elapsed_minutes: 33.3,
      repo_short: 'worldarchitect.ai',
      phase_badge: 'playwright',
    },
    {
      slot_id: 'linux-6',
      state: 'DOWN',
      phase_badge: 'disk_floor_paused',
    },
  ];
  snapshot.cmux = {
    ok: true,
    configured: 25,
    executing: 21,
    idle: 0,
    cycling: 4,
    down: 0,
    vms: [
      {
        vm_id: 'cmux-dreamy',
        configured: 3,
        executing: 2,
        idle: 0,
        cycling: 1,
        down: 0,
        disk_free_gb: 12.0,
        disk_floor_gb: 10,
        slots: [{ slot_id: 'cmux-dreamy-2', state: 'EXECUTING', elapsed_minutes: 28, phase_badge: 'jest' }],
      },
    ],
  };
  snapshot.reconciliation = {
    active_workflow_runs: 15,
    active_job_slots_occupied: 34,
    idle_slots: 0,
    cycling_slots: 4,
    down_slots: 7,
    parked_slots: 4,
    fresh_queued_runs: 50,
    inert_ghosts: 149,
    explanation: '15 active workflow runs fan out across 34 occupied job slots.',
  };
  snapshot.latency = {
    ok: true,
    overall: {
      queue_wait: { n: 186, avg_s: 416, p50_s: 339.5, p90_s: 874.5, p99_s: 1502.4 },
      execution: { n: 186, avg_s: 197, p50_s: 47, p90_s: 505, p99_s: 1849.7 },
      e2e: { n: 174, avg_s: 697, p50_s: 453, p90_s: 1561.2, p99_s: 4198.2 },
    },
    cancellation: { cancelled_runs: 183, total_non_skipped_runs: 381, cancelled_rate_pct: 48.0 },
    workflows: [
      {
        workflow: 'Self-Hosted MVP Shards',
        queue_wait: { n: 32, p50_s: 323, p90_s: 637 },
        execution: { n: 32, avg_s: 413, p50_s: 32.5, p90_s: 1639, p99_s: 2050 },
        e2e: { n: 32, p50_s: 500, p90_s: 1900 },
      },
    ],
  };

  render(snapshot, NOW);
  assert.equal(elements.get('reconcile-runs').textContent, '15');
  assert.equal(elements.get('reconcile-slots').textContent, '34');
  assert.equal(elements.get('cmux-target').textContent, '25');
  assert.equal(elements.get('latency-queue-p50').textContent, '5m 40s');
  assert.equal(elements.get('latency-exec-p50').textContent, '47s');
  assert.ok(elements.get('linux-slots').children.length >= 2);
  assert.ok(elements.get('cmux-slots').children.length >= 1);
  assert.ok(elements.get('latency-workflows').children.length >= 1);

  // Honest skipped-probe provenance on parked host still classifies as degraded (parked), never stale,
  // and an unavailable host displays UNAVAILABLE badge rather than ONLINE.
  const parkedTruth = structuredClone(snapshot);
  parkedTruth.fleets.linux.disk = { status: 'healthy' };
  parkedTruth.fleets.mac.sources.service.ok = false;
  parkedTruth.fleets.mac.sources.docker.ok = false;
  parkedTruth.fleets.mac.sources.process_probe.ok = false;
  assert.equal(classifySnapshot(parkedTruth, NOW).state, 'degraded');

  const unavail = structuredClone(snapshot);
  unavail.sources.linux_host.ok = false;
  unavail.reconciliation = {};
  unavail.cmux = { ok: false };
  render(unavail, NOW);
  assert.equal(elements.get('linux-state-badge').textContent, 'UNAVAILABLE');
  delete globalThis.document;
});
