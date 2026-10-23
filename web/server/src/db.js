import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

/** Each entry runs once, in order, inside a transaction; never edit a shipped migration, append a new one. */
const MIGRATIONS = [
  `
  CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE orders (
    id INTEGER PRIMARY KEY,
    order_no TEXT NOT NULL UNIQUE,
    plan_id TEXT NOT NULL,
    plan_name TEXT NOT NULL,
    amount REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY',
    devices INTEGER NOT NULL,
    email TEXT NOT NULL,
    pay_method TEXT NOT NULL,
    pay_code TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    access_token TEXT NOT NULL,
    buyer_note TEXT,
    admin_note TEXT,
    ip TEXT,
    created_at TEXT NOT NULL,
    buyer_notified_at TEXT,
    paid_at TEXT,
    cancelled_at TEXT,
    license_key TEXT
  );
  CREATE INDEX orders_status ON orders(status, created_at);
  CREATE INDEX orders_email ON orders(email);
  CREATE INDEX orders_pay_code ON orders(pay_code);

  CREATE TABLE licenses (
    id INTEGER PRIMARY KEY,
    key TEXT NOT NULL UNIQUE,
    email TEXT,
    plan_id TEXT,
    plan_name TEXT NOT NULL,
    activation_limit INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    order_no TEXT,
    note TEXT,
    source TEXT NOT NULL DEFAULT 'order',
    created_at TEXT NOT NULL,
    disabled_at TEXT
  );
  CREATE INDEX licenses_email ON licenses(email);

  -- Rows are kept after deactivation (deactivated_at set) so history and charts survive.
  CREATE TABLE activations (
    id TEXT PRIMARY KEY,
    license_id INTEGER NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    app_version TEXT,
    ip TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    deactivated_at TEXT,
    deactivated_by TEXT
  );
  CREATE INDEX activations_license ON activations(license_id, deactivated_at);
  CREATE INDEX activations_created ON activations(created_at);

  CREATE TABLE releases (
    id INTEGER PRIMARY KEY,
    version TEXT NOT NULL UNIQUE,
    build TEXT NOT NULL,
    min_os TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    ed_signature TEXT,
    file_name TEXT NOT NULL,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    is_latest INTEGER NOT NULL DEFAULT 0,
    downloads INTEGER NOT NULL DEFAULT 0,
    published_at TEXT NOT NULL
  );

  CREATE TABLE downloads_daily (
    day TEXT PRIMARY KEY,
    count INTEGER NOT NULL DEFAULT 0,
    unique_count INTEGER NOT NULL DEFAULT 0
  );

  -- One row per (day, hashed IP); pruned after a few days.
  CREATE TABLE download_ips (
    day TEXT NOT NULL,
    ip_hash TEXT NOT NULL,
    PRIMARY KEY (day, ip_hash)
  );

  CREATE TABLE sessions (
    id_hash TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    ip TEXT,
    user_agent TEXT
  );

  CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY,
    at TEXT NOT NULL,
    action TEXT NOT NULL,
    target TEXT,
    detail TEXT,
    ip TEXT
  );
  CREATE INDEX audit_at ON audit_log(at);
  `,
  `
  -- Voluntary usage events. No raw installation UUID, IP, file data or license linkage.
  CREATE TABLE usage_events (
    installation_hash TEXT NOT NULL,
    event TEXT NOT NULL CHECK(event IN ('first_open', 'daily_active', 'first_scan')),
    dedupe_day TEXT NOT NULL,
    day TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    received_at TEXT NOT NULL,
    app_version TEXT NOT NULL,
    os_version TEXT NOT NULL,
    PRIMARY KEY (installation_hash, event, dedupe_day)
  );
  CREATE INDEX usage_events_day ON usage_events(day, event);
  `,
];

export function openDatabase(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA synchronous = NORMAL');
  db.exec('PRAGMA foreign_keys = ON');
  db.exec('PRAGMA busy_timeout = 5000');
  migrate(db);
  return db;
}

export function migrate(db) {
  db.exec('CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)');
  let row = db.prepare('SELECT version FROM schema_version').get();
  if (!row) {
    db.prepare('INSERT INTO schema_version (version) VALUES (0)').run();
    row = { version: 0 };
  }
  for (let v = row.version; v < MIGRATIONS.length; v++) {
    transaction(db, () => {
      db.exec(MIGRATIONS[v]);
      db.prepare('UPDATE schema_version SET version = ?').run(v + 1);
    });
  }
}

export function schemaVersion(db) {
  return db.prepare('SELECT version FROM schema_version').get().version;
}

export function transaction(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

export function getSetting(db, key, fallback = null) {
  const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
  if (!row) return fallback;
  try { return JSON.parse(row.value); } catch { return fallback; }
}

export function setSetting(db, key, value) {
  db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .run(key, JSON.stringify(value));
}

export function audit(db, action, { target = null, detail = null, ip = null } = {}) {
  db.prepare('INSERT INTO audit_log (at, action, target, detail, ip) VALUES (?, ?, ?, ?, ?)')
    .run(new Date().toISOString(), action, target, detail == null ? null : JSON.stringify(detail), ip);
}

/** `VACUUM INTO` a dated copy once per day; keeps the newest `keep` files. Returns the path written, if any. */
export function backupIfDue(db, backupsDir, day, keep = 14) {
  fs.mkdirSync(backupsDir, { recursive: true });
  const target = path.join(backupsDir, `macclean-${day}.db`);
  let written = null;
  if (!fs.existsSync(target)) {
    const tmp = `${target}.tmp`;
    fs.rmSync(tmp, { force: true });
    db.prepare('VACUUM INTO ?').run(tmp);
    fs.renameSync(tmp, target);
    written = target;
  }
  const backups = fs.readdirSync(backupsDir)
    .filter((name) => /^macclean-\d{4}-\d{2}-\d{2}\.db$/.test(name))
    .sort()
    .reverse();
  for (const old of backups.slice(keep)) fs.rmSync(path.join(backupsDir, old), { force: true });
  return written;
}
