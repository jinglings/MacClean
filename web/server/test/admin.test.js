import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { ADMIN_PASSWORD, adminLogin, json, startServer } from './helpers.js';
import { hashPassword, verifyPassword } from '../src/security.js';

const CSRF = { 'x-requested-with': 'macclean-admin' };

test('scrypt hashes verify and reject wrong passwords', async () => {
  const hash = await hashPassword('s3cret-password');
  assert.match(hash, /^[0-9a-f]{32}:[0-9a-f]{128}$/);
  assert.equal(await verifyPassword('s3cret-password', hash), true);
  assert.equal(await verifyPassword('s3cret-passworD', hash), false);
  assert.equal(await verifyPassword('x', 'garbage'), false);
});

describe('admin auth', () => {
  let srv;
  before(async () => { srv = await startServer(); });
  after(() => srv.close());

  test('first run: setup requires the printed token', async () => {
    const session = await (await srv.fetch('/api/admin/session')).json();
    assert.deepEqual(session, { authenticated: false, setupRequired: true, passwordFromEnv: false });
    assert.ok(srv.app.setupToken);

    const wrong = await srv.fetch('/api/admin/setup', json({ token: 'nope', password: 'long enough pw' }, CSRF));
    assert.equal(wrong.status, 403);
    const noCsrf = await srv.fetch('/api/admin/setup', json({ token: srv.app.setupToken, password: 'long enough pw' }));
    assert.equal(noCsrf.status, 403);
    const weak = await srv.fetch('/api/admin/setup', json({ token: srv.app.setupToken, password: 'short' }, CSRF));
    assert.equal(weak.status, 400);

    const ok = await srv.fetch('/api/admin/setup', json({ token: srv.app.setupToken, password: 'long enough pw' }, CSRF));
    assert.equal(ok.status, 200);
    const cookie = ok.headers.get('set-cookie');
    assert.match(cookie, /^mc_admin=/);
    assert.match(cookie, /HttpOnly/);
    assert.match(cookie, /SameSite=Strict/);
    assert.equal(srv.app.setupToken, null);

    const reuse = await srv.fetch('/api/admin/setup', json({ token: 'x', password: 'another long pw' }, CSRF));
    assert.equal(reuse.status, 409);
    const me = await (await srv.fetch('/api/admin/session', { headers: { cookie: cookie.split(';')[0] } })).json();
    assert.equal(me.authenticated, true);
  });

  test('login, wrong password, CSRF rejection, logout', async () => {
    const headers = await adminLogin(srv);
    const stats = await srv.fetch('/api/admin/stats', { headers: { cookie: headers.cookie } });
    assert.equal(stats.status, 200);
    assert.match(stats.headers.get('content-security-policy'), /frame-ancestors 'none'/);
    assert.equal(stats.headers.get('x-frame-options'), 'DENY');

    const noCookie = await srv.fetch('/api/admin/stats');
    assert.equal(noCookie.status, 401);

    // Mutation without the CSRF header is refused even with a valid cookie.
    const forged = await srv.fetch('/api/admin/licenses', json({ plan: 'lifetime' }, { cookie: headers.cookie }));
    assert.equal(forged.status, 403);
    // Wrong Origin is refused too.
    const crossSite = await srv.fetch('/api/admin/licenses', json({ plan: 'lifetime' }, { ...headers, origin: 'https://evil.example' }));
    assert.equal(crossSite.status, 403);
    const okIssue = await srv.fetch('/api/admin/licenses', json({ plan: 'lifetime', email: 'a@example.com' }, headers));
    assert.equal(okIssue.status, 200);

    const bad = await srv.fetch('/api/admin/login', json({ password: 'wrong' }, CSRF));
    assert.equal(bad.status, 401);

    const out = await srv.fetch('/api/admin/logout', { method: 'POST', headers });
    assert.equal(out.status, 200);
    assert.match(out.headers.get('set-cookie'), /Max-Age=0/);
    assert.equal((await srv.fetch('/api/admin/stats', { headers: { cookie: headers.cookie } })).status, 401);
  });

  test('expired sessions are rejected and removed', async () => {
    srv.app.db.prepare('DELETE FROM sessions').run();
    const headers = await adminLogin(srv);
    srv.app.db.prepare('UPDATE sessions SET expires_at = ?').run(Date.now() - 1000);
    const res = await srv.fetch('/api/admin/stats', { headers: { cookie: headers.cookie } });
    assert.equal(res.status, 401);
    assert.equal(srv.app.db.prepare('SELECT COUNT(*) AS n FROM sessions').get().n, 0);
  });

  test('password change signs out other sessions', async () => {
    const a = await adminLogin(srv);
    const b = await adminLogin(srv);
    const res = await srv.fetch('/api/admin/password', json({ current: ADMIN_PASSWORD, next: 'brand new password' }, a));
    assert.equal(res.status, 200);
    assert.equal((await srv.fetch('/api/admin/stats', { headers: { cookie: a.cookie } })).status, 200);
    assert.equal((await srv.fetch('/api/admin/stats', { headers: { cookie: b.cookie } })).status, 401);
    const login = await srv.fetch('/api/admin/login', json({ password: 'brand new password' }, CSRF));
    assert.equal(login.status, 200);
  });

  test('audit log records admin actions', async () => {
    const headers = await adminLogin(srv);
    const res = await (await srv.fetch('/api/admin/audit', { headers })).json();
    const actions = res.items.map((i) => i.action);
    assert.ok(actions.includes('admin.setup'));
    assert.ok(actions.includes('license.issue'));
    assert.ok(actions.includes('admin.login_failed'));
  });

  test('admin SPA is served with security headers', async () => {
    const redirect = await srv.fetch('/admin');
    assert.equal(redirect.status, 301);
    const page = await srv.fetch('/admin/');
    assert.equal(page.status, 200);
    assert.match(page.headers.get('content-type'), /text\/html/);
    assert.match(page.headers.get('content-security-policy'), /default-src 'self'/);
    assert.match(await page.text(), /<script type="module" src="js\/app\.js/);
    assert.equal((await srv.fetch('/admin/js/app.js')).status, 200);
    assert.equal((await srv.fetch('/admin/../src/app.js')).status, 404);
    assert.equal((await srv.fetch('/admin/missing.js')).status, 404);
  });
});

test('login is limited to 10 attempts per 15 minutes per IP', async () => {
  const srv = await startServer();
  try {
    await adminLogin(srv); // 1 attempt (succeeds, resets the counter)
    for (let i = 0; i < 10; i++) {
      const res = await srv.fetch('/api/admin/login', json({ password: `wrong-${i}` }, { ...CSRF, 'cf-connecting-ip': '192.0.2.9' }));
      assert.equal(res.status, 401);
    }
    const blocked = await srv.fetch('/api/admin/login', json({ password: ADMIN_PASSWORD }, { ...CSRF, 'cf-connecting-ip': '192.0.2.9' }));
    assert.equal(blocked.status, 429);
    const other = await srv.fetch('/api/admin/login', json({ password: ADMIN_PASSWORD }, { ...CSRF, 'cf-connecting-ip': '192.0.2.10' }));
    assert.equal(other.status, 200);
  } finally {
    await srv.close();
  }
});

test('ADMIN_PASSWORD_HASH from env wins and disables setup + in-app password change', async () => {
  const hash = await hashPassword('env password here');
  const srv = await startServer({}, { ADMIN_PASSWORD_HASH: hash });
  try {
    assert.equal(srv.app.setupToken, null);
    const s = await (await srv.fetch('/api/admin/session')).json();
    assert.equal(s.setupRequired, false);
    assert.equal(s.passwordFromEnv, true);
    const login = await srv.fetch('/api/admin/login', json({ password: 'env password here' }, CSRF));
    assert.equal(login.status, 200);
    const cookie = login.headers.get('set-cookie').split(';')[0];
    const change = await srv.fetch('/api/admin/password', json({ current: 'env password here', next: 'something else 1' }, { ...CSRF, cookie }));
    assert.equal(change.status, 409);
  } finally {
    await srv.close();
  }
});

test('production cookie uses __Host- prefix and Secure', async () => {
  const srv = await startServer({ isDev: false });
  try {
    const headers = await (async () => {
      const { storePassword } = await import('../src/auth.js');
      await storePassword(srv.app.ctx, ADMIN_PASSWORD);
      return CSRF;
    })();
    const res = await srv.fetch('/api/admin/login', json({ password: ADMIN_PASSWORD }, headers));
    const cookie = res.headers.get('set-cookie');
    assert.match(cookie, /^__Host-mc_admin=/);
    assert.match(cookie, /; Secure/);
  } finally {
    await srv.close();
  }
});

test('proxy headers are only trusted from loopback', async () => {
  const { clientIp } = await import('../src/http.js');
  const req = (remoteAddress, headers) => ({ socket: { remoteAddress }, headers });
  assert.equal(clientIp(req('127.0.0.1', { 'cf-connecting-ip': '1.2.3.4' })), '1.2.3.4');
  assert.equal(clientIp(req('127.0.0.1', { 'x-forwarded-for': '9.9.9.9, 5.6.7.8' })), '5.6.7.8');
  assert.equal(clientIp(req('10.0.0.5', { 'cf-connecting-ip': '1.2.3.4' })), '10.0.0.5');
  assert.equal(clientIp(req('127.0.0.1', { 'cf-connecting-ip': 'not-an-ip' })), '127.0.0.1');
});
