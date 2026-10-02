// Thin JSON client for the MacClean server (see web/SPEC.md).
import { t } from './i18n.js?v=20261002.1';

export class ApiError extends Error {
  constructor(kind, status = 0, message = '', data = null) {
    super(message || kind);
    this.kind = kind;       // network | timeout | rate | notfound | invalid | server | http
    this.status = status;
    this.data = data;
  }
}

export async function api(path, { method = 'GET', body, timeout = 15000 } = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  let res;
  try {
    res = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json', Accept: 'application/json' } : { Accept: 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: ctrl.signal,
      credentials: 'same-origin',
      cache: 'no-store',
    });
  } catch (e) {
    throw new ApiError(e.name === 'AbortError' ? 'timeout' : 'network');
  } finally {
    clearTimeout(timer);
  }

  let data = null;
  try { data = await res.json(); } catch { /* non-JSON body */ }

  if (!res.ok) {
    const msg = (data && typeof data.error === 'string') ? data.error : '';
    const kind =
      res.status === 429 ? 'rate' :
      res.status === 404 ? 'notfound' :
      res.status === 400 || res.status === 409 || res.status === 422 ? 'invalid' :
      res.status >= 500 ? 'server' : 'http';
    throw new ApiError(kind, res.status, msg, data);
  }
  if (data === null) throw new ApiError('server', res.status);
  return data;
}

// Error codes the server sends with 400s (POST /api/orders).
const ERROR_CODES = ['invalid_plan', 'invalid_email', 'invalid_pay_method'];

// Friendly, localized message for any error thrown by api().
export function errorMessage(err, notFoundKey = 'err.notfound') {
  if (!(err instanceof ApiError)) return t('err.unknown');
  const code = err.data && err.data.code;
  if (code && ERROR_CODES.includes(code)) return t('err.code.' + code);
  switch (err.kind) {
    case 'network': return t('err.network');
    case 'timeout': return t('err.timeout');
    case 'rate': return t('err.rate');
    case 'notfound': return t(notFoundKey);
    case 'invalid': return err.message ? t('err.invalidMsg', { msg: err.message }) : t('err.invalid');
    case 'server': return t('err.server');
    default: return t('err.http', { status: err.status });
  }
}
