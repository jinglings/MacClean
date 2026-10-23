import crypto from 'node:crypto';
import { getSetting, setSetting, transaction } from './db.js';
import { HttpError } from './http.js';
import { dayKey } from './time.js';

const EVENTS = new Set(['first_open', 'daily_active', 'first_scan']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const VERSION = /^[0-9][0-9A-Za-z.+() -]{0,63}$/;
const DAY_MS = 86400000;

/** Validate the entire batch before writing, and deduplicate retries independently of batch order. */
export function recordUsage(db, config, body, now = new Date()) {
  const bad = () => { throw new HttpError(400, 'Invalid usage event payload'); };
  if (Object.keys(body).some((k) => !['installationId', 'events'].includes(k))) bad();
  if (typeof body.installationId !== 'string' || !UUID.test(body.installationId)) bad();
  if (!Array.isArray(body.events) || !body.events.length || body.events.length > 40) bad();
  const events = body.events.map((e) => {
    if (!e || typeof e !== 'object' || Array.isArray(e)
      || Object.keys(e).some((k) => !['name', 'occurredAt', 'appVersion', 'osVersion'].includes(k))) bad();
    if (!EVENTS.has(e.name) || typeof e.occurredAt !== 'string'
      || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/.test(e.occurredAt)
      || typeof e.appVersion !== 'string' || !VERSION.test(e.appVersion)
      || typeof e.osVersion !== 'string' || !/^\d{1,3}(\.\d{1,3}){1,2}$/.test(e.osVersion)) bad();
    const at = new Date(e.occurredAt);
    if (!Number.isFinite(at.getTime()) || at < new Date(+now - 35 * DAY_MS) || at > new Date(+now + 300000)) bad();
    return { ...e, at, day: dayKey(at, config.timeZone) };
  }).sort((a, b) => a.at - b.at);

  return transaction(db, () => {
    let salt = getSetting(db, 'usage_salt');
    if (!salt) {
      salt = crypto.randomBytes(32).toString('hex');
      setSetting(db, 'usage_salt', salt);
    }
    const hash = crypto.createHmac('sha256', salt).update(body.installationId.toLowerCase()).digest('hex');
    const insert = db.prepare(`INSERT OR IGNORE INTO usage_events
      (installation_hash, event, dedupe_day, day, occurred_at, received_at, app_version, os_version)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);
    let inserted = 0;
    for (const e of events) {
      inserted += insert.run(hash, e.name, e.name === 'daily_active' ? e.day : '', e.day,
        e.at.toISOString(), now.toISOString(), e.appVersion, e.osVersion).changes;
    }
    return { ok: true, inserted };
  });
}

export function usageStats(db, days) {
  const [today] = days.slice(-1);
  const firstOpensTotal = db.prepare("SELECT COUNT(*) AS n FROM usage_events WHERE event = 'first_open'").get().n;
  const firstScansTotal = db.prepare("SELECT COUNT(*) AS n FROM usage_events WHERE event = 'first_scan'").get().n;
  const active7d = db.prepare(`SELECT COUNT(DISTINCT installation_hash) AS n FROM usage_events
    WHERE event = 'daily_active' AND day >= ? AND day <= ?`).get(days.at(-7), today).n;
  const series = new Map(days.map((day) => [day, { firstOpens: 0, dailyActive: 0, firstScans: 0 }]));
  const keys = { first_open: 'firstOpens', daily_active: 'dailyActive', first_scan: 'firstScans' };
  for (const r of db.prepare(`SELECT day, event, COUNT(*) AS n FROM usage_events
    WHERE day >= ? AND day <= ? GROUP BY day, event`).all(days[0], today)) {
    series.get(r.day)[keys[r.event]] = r.n;
  }
  const t = series.get(today);
  return { totals: { firstOpensTotal, firstScansTotal, firstOpensToday: t.firstOpens,
    firstScansToday: t.firstScans, dailyActiveToday: t.dailyActive, active7d }, series };
}
