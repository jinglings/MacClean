import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { migrate, schemaVersion } from '../src/db.js';
import { recordUsage } from '../src/usage.js';
import { dayKey } from '../src/time.js';
import { adminLogin, json, startInProcessServer as startServer } from './helpers.js';

const ID = '12345678-1234-4234-8234-123456789abc';
const OTHER_ID = '22345678-1234-4234-8234-123456789abc';
const event = (name, at = new Date()) => ({ name, occurredAt: at.toISOString(), appVersion: '1.2.0', osVersion: '26.0.1' });
const batch = (events, installationId = ID) => ({ installationId, events });

test('usage migration preserves existing v1 data and is idempotent', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec('CREATE TABLE schema_version (version INTEGER NOT NULL); INSERT INTO schema_version VALUES (1); CREATE TABLE existing (value TEXT); INSERT INTO existing VALUES (\'keep\')');
    migrate(db);
    migrate(db);
    assert.equal(schemaVersion(db), 2);
    assert.equal(db.prepare('SELECT value FROM existing').get().value, 'keep');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM usage_events').get().n, 0);
  } finally { db.close(); }
});

test('native endpoint accepts events, deduplicates retries and stores no raw ID or IP', async () => {
  const srv = await startServer();
  try {
    const payload = batch(['first_open', 'daily_active', 'first_scan'].map((name) => event(name)));
    let res = await srv.fetch('/api/usage/events', json(payload));
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true, inserted: 3 });
    res = await srv.fetch('/api/usage/events', json({ ...payload, installationId: ID.toUpperCase() }));
    assert.deepEqual(await res.json(), { ok: true, inserted: 0 });
    const rows = srv.app.db.prepare('SELECT * FROM usage_events').all();
    assert.equal(rows.length, 3);
    assert.match(rows[0].installation_hash, /^[a-f0-9]{64}$/);
    assert.ok(!JSON.stringify(rows).includes(ID));
    assert.ok(!Object.keys(rows[0]).includes('ip'));
    assert.ok(!Object.keys(rows[0]).includes('installation_id'));
    assert.equal((await srv.fetch('/api/admin/stats')).status, 401);
  } finally { await srv.close(); }
});

test('daily active follows Shanghai day boundary; first events deduplicate across dates and restarts', async () => {
  const srv = await startServer();
  const before = new Date('2026-10-22T15:59:59Z');
  const after = new Date('2026-10-22T16:00:01Z');
  try {
    const events = ['first_open', 'daily_active', 'first_scan'];
    assert.equal(recordUsage(srv.app.db, srv.config, batch(events.map((n) => event(n, before))), after).inserted, 3);
    assert.equal(recordUsage(srv.app.db, srv.config, batch(events.map((n) => event(n, after))), after).inserted, 1);
    const daily = srv.app.db.prepare("SELECT day FROM usage_events WHERE event = 'daily_active' ORDER BY day").all();
    assert.deepEqual(daily.map((r) => r.day), ['2026-10-22', '2026-10-23']);
    migrate(srv.app.db);
    assert.equal(recordUsage(srv.app.db, srv.config, batch(events.map((n) => event(n, after))), after).inserted, 0);
  } finally { await srv.close(); }
});

test('usage totals separate downloads, first opens, distinct active installations and first scans', async () => {
  const srv = await startServer();
  try {
    const now = new Date();
    const yesterday = new Date(+now - 86400000);
    recordUsage(srv.app.db, srv.config, batch(['first_open', 'daily_active', 'first_scan'].map((n) => event(n, yesterday))), now);
    recordUsage(srv.app.db, srv.config, batch([event('daily_active', now)]), now);
    recordUsage(srv.app.db, srv.config, batch([event('first_open', now), event('daily_active', now)], OTHER_ID), now);
    const auth = await adminLogin(srv);
    const stats = await (await srv.fetch('/api/admin/stats', { headers: auth })).json();
    assert.deepEqual(stats.usage, { firstOpensTotal: 2, firstScansTotal: 1, firstOpensToday: 1,
      firstScansToday: 0, dailyActiveToday: 2, active7d: 2 });
    const today = stats.series.find((r) => r.day === dayKey(now, srv.config.timeZone));
    assert.equal(today.firstOpens, 1);
    assert.equal(today.dailyActive, 2);
    assert.equal(today.firstScans, 0);
    assert.equal(stats.totals.downloadsTotal, 0);
    assert.equal(stats.totals.activeDevices, 0);
  } finally { await srv.close(); }
});

test('invalid, oversized, extra-field and stale batches are rejected atomically', async () => {
  const srv = await startServer();
  try {
    const valid = event('first_open');
    const invalid = [
      batch([valid], 'not-a-uuid'), batch([]), batch(Array(41).fill(valid)),
      batch([valid, event('file_path')]), batch([{ ...valid, filePath: '/secret' }]),
      { ...batch([valid]), email: 'private@example.com' },
      batch([event('first_open', new Date(Date.now() - 36 * 86400000))]),
      batch([event('first_open', new Date(Date.now() + 600000))]),
      batch([{ ...valid, appVersion: '<script>' }]), batch([{ ...valid, osVersion: 'computer-name' }]),
      batch([null]), batch([{ ...valid, occurredAt: 'not-a-date' }]),
    ];
    for (const payload of invalid) {
      assert.equal((await srv.fetch('/api/usage/events', json(payload))).status, 400);
    }
    assert.equal(srv.app.db.prepare('SELECT COUNT(*) AS n FROM usage_events').get().n, 0);
  } finally { await srv.close(); }
});

test('usage endpoint is rate limited independently of licensing', async () => {
  const srv = await startServer();
  try {
    srv.app.ctx.limiters.usage.limit = 1;
    assert.equal((await srv.fetch('/api/usage/events', json(batch([event('first_open')])))).status, 200);
    assert.equal((await srv.fetch('/api/usage/events', json(batch([event('first_open')])))).status, 429);
    assert.equal((await srv.fetch('/api/health')).status, 200);
  } finally { await srv.close(); }
});
