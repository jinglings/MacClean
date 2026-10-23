import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { checkCsrf, currentSession, passwordHash, pruneSessions } from './auth.js';
import { backupIfDue, openDatabase } from './db.js';
import { HttpError, RateLimiter, clientIp, readBody, redirect, sendJson } from './http.js';
import { adminRoutes } from './routes/admin.js';
import { licenseRoutes } from './routes/license.js';
import { publicRoutes } from './routes/public.js';
import { randomToken } from './security.js';
import { safeJoin, serveFile } from './static.js';
import { dayKey } from './time.js';

const ADMIN_HEADERS = {
  'Content-Security-Policy': "default-src 'self'; img-src 'self' data: blob:; style-src 'self'; script-src 'self'; "
    + "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

function compile(pattern) {
  const names = [];
  const source = pattern
    .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
    .replace(/\/\*$/, () => { names.push('wild'); return '/(.+)'; })
    .replace(/:([a-zA-Z]+)/g, (_, name) => { names.push(name); return '([^/]+)'; });
  return { regex: new RegExp(`^${source}$`), names };
}

/**
 * Builds the HTTP server and its state. Nothing listens until `start()`; tests use port 0.
 */
export function createApp(config, { logger = console } = {}) {
  for (const dir of [config.dataDir, config.filesDir, path.join(config.filesDir, 'releases'), config.backupsDir]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const db = openDatabase(config.dbPath);
  const limiters = {
    orders: new RateLimiter(5, 3600_000),
    orderLookup: new RateLimiter(60, 600_000),
    notify: new RateLimiter(10, 3600_000),
    license: new RateLimiter(60, 3600_000),
    login: new RateLimiter(10, 900_000),
    usage: new RateLimiter(240, 3600_000),
  };
  const state = { setupToken: null };
  const ctx = { config, db, limiters, state, logger };

  const routes = [...publicRoutes(ctx), ...licenseRoutes(ctx), ...adminRoutes(ctx)].map(([method, pattern, handler, opts = {}]) => ({
    method, handler, opts, ...compile(pattern),
  }));

  if (!passwordHash(ctx)) {
    state.setupToken = randomToken(18);
    logger.log(`[macclean] No admin password is set. Open ${config.publicBaseUrl}/admin/ and enter this one-time setup token:`);
    logger.log(`[macclean] SETUP TOKEN: ${state.setupToken}`);
  }

  async function serveAdmin(req, res, pathname) {
    if (pathname === '/admin') return redirect(res, '/admin/', 301, ADMIN_HEADERS);
    const rel = pathname.slice('/admin/'.length);
    const file = rel ? safeJoin(config.adminDir, rel) : null;
    const headers = ADMIN_HEADERS;
    if (file && await serveFile(req, res, file, { cacheControl: 'no-cache', headers })) return;
    if (rel && /\.[a-z0-9]+$/i.test(rel)) throw new HttpError(404, 'Not found');
    await serveFile(req, res, path.join(config.adminDir, 'index.html'), { cacheControl: 'no-cache', headers });
  }

  async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const { pathname } = url;
    const method = req.method === 'HEAD' ? 'GET' : req.method;
    const isAdmin = pathname === '/admin' || pathname.startsWith('/admin/') || pathname.startsWith('/api/admin/');
    if (isAdmin) for (const [k, v] of Object.entries(ADMIN_HEADERS)) res.setHeader(k, v);

    if (method === 'GET' && (pathname === '/admin' || pathname.startsWith('/admin/'))) return serveAdmin(req, res, pathname);

    let matchedPath = false;
    for (const route of routes) {
      const m = route.regex.exec(pathname);
      if (!m) continue;
      matchedPath = true;
      if (route.method !== method) continue;
      const params = {};
      route.names.forEach((name, i) => {
        // `wild` stays encoded; safeJoin decodes it itself after checking for traversal tricks.
        if (name === 'wild') { params.wild = m[i + 1]; return; }
        try { params[name] = decodeURIComponent(m[i + 1]); } catch { params[name] = m[i + 1]; }
      });
      const c = { req, res, url, query: url.searchParams, params, ip: clientIp(req), ctx, route, body: {} };
      if (route.opts.auth || route.opts.csrf) {
        if (method !== 'GET') checkCsrf(req);
      }
      if (route.opts.auth) {
        c.session = currentSession(ctx, req);
        if (!c.session) throw new HttpError(401, '登录已过期，请重新登录');
      }
      if (!route.opts.raw && method !== 'GET') c.body = await readBody(req, config.maxJsonBytes);
      const result = await route.handler(c);
      if (result !== undefined && !res.headersSent) sendJson(res, 200, result);
      return;
    }
    throw new HttpError(matchedPath ? 405 : 404, matchedPath ? 'Method not allowed' : 'Not found');
  }

  const server = http.createServer((req, res) => {
    const started = Date.now();
    handle(req, res).catch((err) => {
      const status = err instanceof HttpError ? err.status : 500;
      if (status >= 500) logger.error(`[macclean] ${req.method} ${req.url} failed:`, err);
      if (res.headersSent) {
        res.destroy();
        return;
      }
      const headers = { ...(err.extra?.headers || {}) };
      // A body we rejected mid-stream: drain small remainders so the client can read our answer,
      // but hang up on big uploads rather than swallowing hundreds of MB.
      if (!req.complete) {
        const declared = Number(req.headers['content-length']);
        if (Number.isFinite(declared) && declared <= 16 * 1024 * 1024) {
          req.resume();
        } else {
          headers.Connection = 'close';
          res.on('finish', () => req.destroy());
        }
      }
      const message = status >= 500 ? 'Internal server error' : err.message;
      sendJson(res, status, { ...(err.extra?.body || {}), error: message }, headers);
    }).finally(() => {
      if (config.accessLog && req.url.startsWith('/api/')) logger.log(`${req.method} ${req.url.split('?')[0]} ${res.statusCode} ${Date.now() - started}ms`);
    });
  });
  // Large DMG uploads over slow links: allow up to an hour per request but keep header reads tight.
  server.requestTimeout = 3600_000;
  server.headersTimeout = 30_000;
  server.keepAliveTimeout = 65_000;

  let timer = null;
  function maintenance() {
    try {
      pruneSessions(db);
      for (const limiter of Object.values(limiters)) limiter.prune();
      const keepFrom = dayKey(new Date(Date.now() - 3 * 86400000), config.timeZone);
      db.prepare('DELETE FROM download_ips WHERE day < ?').run(keepFrom);
      const written = backupIfDue(db, config.backupsDir, dayKey(new Date(), config.timeZone), config.backupKeep);
      if (written) logger.log(`[macclean] backup written: ${written}`);
    } catch (err) {
      logger.error('[macclean] maintenance failed:', err);
    }
  }

  return {
    server,
    db,
    ctx,
    get setupToken() { return state.setupToken; },
    async start(port = config.port, host = config.host) {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, resolve);
      });
      if (config.maintenance !== false) {
        maintenance();
        timer = setInterval(maintenance, 3600_000);
        timer.unref();
      }
      return server.address();
    },
    async close() {
      clearInterval(timer);
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(() => resolve()));
      db.close();
    },
    maintenance,
  };
}
