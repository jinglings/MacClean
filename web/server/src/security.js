import crypto from 'node:crypto';

export const KEY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const LICENSE_KEY_RE = /^MCLN(-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}){4}$/;

/** Uniformly random string over `alphabet` (rejection sampling, no modulo bias). */
export function randomString(length, alphabet = KEY_ALPHABET) {
  const out = [];
  const max = 256 - (256 % alphabet.length);
  while (out.length < length) {
    for (const byte of crypto.randomBytes(length * 2)) {
      if (byte < max) out.push(alphabet[byte % alphabet.length]);
      if (out.length === length) break;
    }
  }
  return out.join('');
}

export function generateLicenseKey() {
  const groups = Array.from({ length: 4 }, () => randomString(4));
  return `MCLN-${groups.join('-')}`;
}

/** Uppercases, trims and re-inserts dashes so "mcln xxxx…" pasted sloppily still matches. */
export function normalizeLicenseKey(input) {
  if (typeof input !== 'string') return null;
  const compact = input.toUpperCase().replace(/[\s-]/g, '');
  if (!/^MCLN[A-Z0-9]{16}$/.test(compact)) return null;
  const body = compact.slice(4);
  return `MCLN-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 12)}-${body.slice(12, 16)}`;
}

/** 24 URL-safe characters (144 bits). */
export function randomToken(bytes = 18) {
  return crypto.randomBytes(bytes).toString('base64url');
}

export function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

/** Constant-time string compare that does not leak length through early exit. */
export function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb) && a.length === b.length;
}

const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 64 };

function scryptAsync(password, salt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, SCRYPT.keylen, { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p, maxmem: 64 * 1024 * 1024 },
      (err, key) => (err ? reject(err) : resolve(key)));
  });
}

/** Returns `salt:hash` (both hex), the format ADMIN_PASSWORD_HASH expects. */
export async function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const key = await scryptAsync(password, salt);
  return `${salt}:${key.toString('hex')}`;
}

export async function verifyPassword(password, stored) {
  if (typeof password !== 'string' || typeof stored !== 'string') return false;
  const [salt, hashHex] = stored.split(':');
  if (!salt || !hashHex || !/^[0-9a-f]+$/i.test(hashHex)) return false;
  const expected = Buffer.from(hashHex, 'hex');
  const actual = await scryptAsync(password, salt);
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

export function isValidPasswordHash(value) {
  return typeof value === 'string' && /^[^:]+:[0-9a-f]{128}$/i.test(value);
}
