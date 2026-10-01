import { getSetting, setSetting } from './db.js';
import { HttpError, parseCookies } from './http.js';
import { hashPassword, randomToken, sha256 } from './security.js';

export const CSRF_HEADER = 'x-requested-with';
export const CSRF_VALUE = 'macclean-admin';

export function cookieName(config) {
  // The __Host- prefix pins the cookie to this exact host over HTTPS; browsers reject it on plain http.
  return config.isDev ? 'mc_admin' : '__Host-mc_admin';
}

export function passwordHash(ctx) {
  return ctx.config.adminPasswordHash || getSetting(ctx.db, 'admin_password_hash');
}

export function passwordFromEnv(ctx) {
  return Boolean(ctx.config.adminPasswordHash);
}

export async function storePassword(ctx, password) {
  validateNewPassword(password);
  setSetting(ctx.db, 'admin_password_hash', await hashPassword(password));
}

export function validateNewPassword(password) {
  if (typeof password !== 'string' || password.length < 10) throw new HttpError(400, '密码至少 10 位');
  if (password.length > 200) throw new HttpError(400, '密码过长');
}

export function createSession(ctx, req, res, ip) {
  const token = randomToken(32);
  const t = Date.now();
  ctx.db.prepare('INSERT INTO sessions (id_hash, created_at, expires_at, ip, user_agent) VALUES (?, ?, ?, ?, ?)')
    .run(sha256(token), t, t + ctx.config.sessionTtlMs, ip, String(req.headers['user-agent'] || '').slice(0, 300));
  setSessionCookie(ctx, res, token, Math.floor(ctx.config.sessionTtlMs / 1000));
  return token;
}

export function setSessionCookie(ctx, res, value, maxAge) {
  const parts = [`${cookieName(ctx.config)}=${value}`, 'Path=/', 'HttpOnly', 'SameSite=Strict', `Max-Age=${maxAge}`];
  if (!ctx.config.isDev) parts.push('Secure');
  res.setHeader('Set-Cookie', parts.join('; '));
}

/** Returns the session row (with `token`) or null. Expired rows are deleted on sight. */
export function currentSession(ctx, req) {
  const token = parseCookies(req.headers.cookie)[cookieName(ctx.config)];
  if (!token || token.length > 100) return null;
  const idHash = sha256(token);
  const row = ctx.db.prepare('SELECT * FROM sessions WHERE id_hash = ?').get(idHash);
  if (!row) return null;
  if (row.expires_at <= Date.now()) {
    ctx.db.prepare('DELETE FROM sessions WHERE id_hash = ?').run(idHash);
    return null;
  }
  return { ...row, token };
}

export function destroySession(ctx, req, res) {
  const session = currentSession(ctx, req);
  if (session) ctx.db.prepare('DELETE FROM sessions WHERE id_hash = ?').run(session.id_hash);
  setSessionCookie(ctx, res, '', 0);
}

/** Logs out every other browser, e.g. after a password change. */
export function destroyOtherSessions(ctx, keepIdHash) {
  ctx.db.prepare('DELETE FROM sessions WHERE id_hash != ?').run(keepIdHash ?? '');
}

export function pruneSessions(db) {
  db.prepare('DELETE FROM sessions WHERE expires_at <= ?').run(Date.now());
}

/**
 * CSRF: browsers can't add a custom header cross-origin without a CORS preflight (which we never
 * grant), so requiring it blocks forged form posts. A present Origin must also match our Host.
 */
export function checkCsrf(req) {
  if (req.headers[CSRF_HEADER] !== CSRF_VALUE) throw new HttpError(403, 'CSRF check failed');
  const origin = req.headers.origin;
  if (origin && origin !== 'null') {
    let host;
    try { host = new URL(origin).host; } catch { throw new HttpError(403, 'CSRF check failed'); }
    if (host !== req.headers.host) throw new HttpError(403, 'CSRF check failed');
  } else if (origin === 'null') {
    throw new HttpError(403, 'CSRF check failed');
  }
}
