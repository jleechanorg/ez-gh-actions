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
  fleets: { mac: host(6), linux: host(16) },
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
  assert.equal(elements.get('linux-target').textContent, '16');
  delete globalThis.document;
});
