import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createApp } from '../src/app.js';
import { storePassword } from '../src/auth.js';
import { loadConfig } from '../src/config.js';

export const ADMIN_PASSWORD = 'correct horse battery';
const quiet = { log() {}, error() {} };

/** Boots a server on a random port with its own temp DATA_DIR. */
export async function startServer(overrides = {}, env = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'macclean-test-'));
  const config = loadConfig({ NODE_ENV: 'development', ...env }, { dataDir, maintenance: false, ...overrides });
  const app = createApp(config, { logger: quiet });
  const { port } = await app.start(0, '127.0.0.1');
  const base = `http://127.0.0.1:${port}`;
  return {
    app, config, dataDir, base,
    fetch: (p, init = {}) => fetch(base + p, { redirect: 'manual', ...init }),
    async close() {
      await app.close();
      fs.rmSync(dataDir, { recursive: true, force: true });
    },
  };
}

export const json = (body, headers = {}) => ({
  method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body),
});

export const form = (params) => ({
  method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(params).toString(),
});

/** Sets a password and logs in; returns headers to use for admin calls. */
export async function adminLogin(srv) {
  await storePassword(srv.app.ctx, ADMIN_PASSWORD);
  const res = await srv.fetch('/api/admin/login', json({ password: ADMIN_PASSWORD }, { 'x-requested-with': 'macclean-admin' }));
  if (res.status !== 200) throw new Error(`login failed: ${res.status}`);
  const cookie = res.headers.get('set-cookie').split(';')[0];
  return { cookie, 'x-requested-with': 'macclean-admin' };
}

export function admin(srv, headers) {
  return async (method, p, body) => {
    const init = { method, headers: { ...headers } };
    if (body !== undefined) {
      init.headers['content-type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    const res = await srv.fetch(p, init);
    return { status: res.status, body: await res.json() };
  };
}

/** Minimal DMG-looking buffer: a "koly" trailer 512 bytes from the end. */
export function fakeDmg(size) {
  const buf = Buffer.alloc(size, 7);
  buf.write('koly', size - 512, 'latin1');
  return buf;
}
