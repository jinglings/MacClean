import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export function loadConfig(env = process.env, overrides = {}) {
  const dataDir = path.resolve(overrides.dataDir ?? env.DATA_DIR ?? '/var/lib/macclean');
  const config = {
    port: Number(env.PORT) || 8787,
    host: env.HOST || '127.0.0.1',
    dataDir,
    filesDir: path.join(dataDir, 'files'),
    backupsDir: path.join(dataDir, 'backups'),
    dbPath: path.join(dataDir, 'macclean.db'),
    adminDir: path.resolve(here, '..', 'admin'),
    publicBaseUrl: (env.PUBLIC_BASE_URL || 'https://thulem.com').replace(/\/+$/, ''),
    adminPasswordHash: env.ADMIN_PASSWORD_HASH?.trim() || null,
    isDev: env.NODE_ENV === 'development',
    // Business day boundaries for "today" and the 30-day charts.
    timeZone: env.TIMEZONE || 'Asia/Shanghai',
    // Legacy orders remain readable; the free application no longer sells seats.
    salesEnabled: false,
    maxReleaseBytes: 500 * 1024 * 1024,
    maxQrBytes: 2 * 1024 * 1024,
    maxJsonBytes: 64 * 1024,
    sessionTtlMs: 7 * 24 * 3600 * 1000,
    backupKeep: 14,
    ...overrides,
  };
  return config;
}
