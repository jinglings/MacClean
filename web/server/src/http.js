import { isIP } from 'node:net';

export class HttpError extends Error {
  constructor(status, message, extra = {}) {
    super(message);
    this.status = status;
    this.extra = extra;
  }
}

export function sendJson(res, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(payload);
}

export function sendText(res, status, text, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': Buffer.byteLength(text),
    ...headers,
  });
  res.end(text);
}

export function redirect(res, location, status = 302, headers = {}) {
  res.writeHead(status, { Location: location, 'Content-Length': 0, 'Cache-Control': 'no-store', ...headers });
  res.end();
}

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

export function isLoopback(address) {
  return LOOPBACK.has(address);
}

/**
 * Client IP. Proxy headers are only honoured when the TCP peer is loopback (Caddy on the same box):
 * CF-Connecting-IP first (Cloudflare's view of the client), then the last X-Forwarded-For hop
 * (the peer Caddy saw), then the socket address.
 */
export function clientIp(req) {
  const peer = req.socket.remoteAddress || '';
  if (!isLoopback(peer)) return peer.replace(/^::ffff:/, '');
  const cf = req.headers['cf-connecting-ip'];
  if (typeof cf === 'string' && isIP(cf.trim())) return cf.trim();
  const xff = req.headers['x-forwarded-for'];
  if (typeof xff === 'string') {
    const hops = xff.split(',').map((s) => s.trim()).filter(Boolean);
    const last = hops[hops.length - 1];
    if (last && isIP(last)) return last.replace(/^::ffff:/, '');
  }
  return peer.replace(/^::ffff:/, '');
}

/** True only for requests that reached us directly on loopback without passing through a proxy. */
export function isDirectLocal(req) {
  return isLoopback(req.socket.remoteAddress || '')
    && !req.headers['cf-connecting-ip'] && !req.headers['x-forwarded-for'];
}

export async function readRawBody(req, limit) {
  const declared = Number(req.headers['content-length']);
  if (Number.isFinite(declared) && declared > limit) throw new HttpError(413, 'Request body too large');
  const chunks = [];
  let size = 0;
  for await (const chunk of req.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new HttpError(413, 'Request body too large');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/** Parses an application/json or application/x-www-form-urlencoded body into a plain object. */
export async function readBody(req, limit = 64 * 1024) {
  const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  const raw = await readRawBody(req, limit);
  if (raw.length === 0) return {};
  const text = raw.toString('utf8');
  if (type === 'application/x-www-form-urlencoded') return parseForm(text);
  if (type === 'application/json' || type === '' || type === 'text/plain') {
    try {
      const value = JSON.parse(text);
      if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('not an object');
      return value;
    } catch {
      throw new HttpError(400, 'Invalid JSON body');
    }
  }
  throw new HttpError(415, 'Unsupported content type');
}

export function parseForm(text) {
  const out = Object.create(null);
  for (const [key, value] of new URLSearchParams(text)) out[key] = value;
  return { ...out };
}

export function parseCookies(header) {
  const out = {};
  if (typeof header !== 'string') return out;
  for (const part of header.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const name = part.slice(0, i).trim();
    if (!name || name in out) continue;
    try { out[name] = decodeURIComponent(part.slice(i + 1).trim()); } catch { /* ignore malformed */ }
  }
  return out;
}

/** Fixed-window in-memory limiter. One process serves everything, so memory is enough. */
export class RateLimiter {
  constructor(limit, windowMs, now = Date.now) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.buckets = new Map();
  }

  hit(key) {
    const t = this.now();
    let bucket = this.buckets.get(key);
    if (!bucket || bucket.resetAt <= t) {
      bucket = { count: 0, resetAt: t + this.windowMs };
      this.buckets.set(key, bucket);
    }
    bucket.count += 1;
    return { ok: bucket.count <= this.limit, retryAfter: Math.ceil((bucket.resetAt - t) / 1000) };
  }

  reset(key) {
    this.buckets.delete(key);
  }

  prune() {
    const t = this.now();
    for (const [key, bucket] of this.buckets) if (bucket.resetAt <= t) this.buckets.delete(key);
  }
}

export function enforceLimit(limiter, key, body = {}) {
  const result = limiter.hit(key);
  if (!result.ok) {
    throw new HttpError(429, 'Too many requests, please try again later.', {
      body, headers: { 'Retry-After': String(result.retryAfter) },
    });
  }
}

export function str(value, max = 1000) {
  if (value === undefined || value === null) return '';
  return String(value).trim().slice(0, max);
}

export const EMAIL_RE = /^[^\s@<>()",;:]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$/;

export function isEmail(value) {
  return typeof value === 'string' && value.length <= 254 && EMAIL_RE.test(value);
}
