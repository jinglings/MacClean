import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { parseForm } from '../src/http.js';
import { KEY_ALPHABET, LICENSE_KEY_RE, generateLicenseKey, normalizeLicenseKey } from '../src/security.js';
import { issueLicense } from '../src/store.js';
import { admin, adminLogin, form, json, startServer } from './helpers.js';

test('license keys use the MCLN-XXXX-XXXX-XXXX-XXXX format and alphabet', () => {
  const seen = new Set();
  for (let i = 0; i < 2000; i++) {
    const key = generateLicenseKey();
    assert.match(key, LICENSE_KEY_RE);
    for (const ch of key.slice(5).replaceAll('-', '')) assert.ok(KEY_ALPHABET.includes(ch));
    seen.add(key);
  }
  assert.equal(seen.size, 2000);
  assert.ok(!/[01IO]/.test([...seen].join('').replaceAll('MCLN', '')));
});

test('normalizeLicenseKey tolerates case, spaces and missing dashes', () => {
  assert.equal(normalizeLicenseKey(' mcln-abcd-efgh-jkmn-pqrs '), 'MCLN-ABCD-EFGH-JKMN-PQRS');
  assert.equal(normalizeLicenseKey('MCLNABCDEFGHJKMNPQRS'), 'MCLN-ABCD-EFGH-JKMN-PQRS');
  assert.equal(normalizeLicenseKey('nope'), null);
  assert.equal(normalizeLicenseKey(undefined), null);
});

test('form-urlencoded parsing handles escapes and plus signs', () => {
  assert.deepEqual(parseForm('license_key=MCLN-AAAA&instance_name=Wang%E2%80%99s+MacBook%20Pro&x=a%26b'),
    { license_key: 'MCLN-AAAA', instance_name: 'Wang’s MacBook Pro', x: 'a&b' });
});

describe('License API (LemonSqueezy-compatible)', () => {
  let srv;
  let key;
  before(async () => {
    srv = await startServer();
    key = issueLicense(srv.app.db, { email: 'buyer@example.com', plan: 'lifetime', devices: 2 }).key;
  });
  after(() => srv.close());

  const call = async (endpoint, params, encoding = 'form') => {
    const res = await srv.fetch(`/api/licenses/${endpoint}`, encoding === 'form' ? form(params) : json(params));
    return { status: res.status, body: await res.json() };
  };

  test('activate → validate → deactivate round trip, form-encoded', async () => {
    const a = await call('activate', { license_key: key, instance_name: 'Studio Mac' });
    assert.equal(a.status, 200);
    assert.equal(a.body.activated, true);
    assert.equal(a.body.error, null);
    assert.deepEqual(Object.keys(a.body).sort(), ['activated', 'error', 'instance', 'license_key', 'meta']);
    assert.equal(a.body.license_key.status, 'active');
    assert.equal(a.body.license_key.activation_limit, 2);
    assert.equal(a.body.license_key.activation_usage, 1);
    assert.match(a.body.instance.id, /^[0-9a-f-]{36}$/);
    assert.equal(a.body.instance.name, 'Studio Mac');
    assert.equal(a.body.meta.store_id, 1);
    assert.equal(a.body.meta.product_id, 1);
    assert.equal(a.body.meta.product_name, 'MacClean');
    assert.equal(a.body.meta.variant_name, '终身版');
    const instanceId = a.body.instance.id;

    const v = await call('validate', { license_key: key.toLowerCase(), instance_id: instanceId, app_version: '1.2' });
    assert.equal(v.status, 200);
    assert.equal(v.body.valid, true);
    assert.equal(v.body.error, null);
    assert.equal(v.body.instance.id, instanceId);
    assert.ok('store_id' in v.body.meta && 'variant_name' in v.body.meta);
    const row = srv.app.db.prepare('SELECT app_version FROM activations WHERE id = ?').get(instanceId);
    assert.equal(row.app_version, '1.2');

    const d = await call('deactivate', { license_key: key, instance_id: instanceId });
    assert.equal(d.status, 200);
    assert.equal(d.body.deactivated, true);
    assert.equal(d.body.error, null);
    assert.equal(d.body.license_key.activation_usage, 0);
    assert.equal(d.body.license_key.status, 'inactive');

    const again = await call('validate', { license_key: key, instance_id: instanceId });
    assert.equal(again.status, 404);
    assert.deepEqual(again.body, { valid: false, error: 'instance not found' });
  });

  test('JSON bodies work too', async () => {
    const a = await call('activate', { license_key: key, instance_name: 'JSON Mac' }, 'json');
    assert.equal(a.body.activated, true);
    const d = await call('deactivate', { license_key: key, instance_id: a.body.instance.id }, 'json');
    assert.equal(d.body.deactivated, true);
  });

  test('activation limit is enforced', async () => {
    const lic = issueLicense(srv.app.db, { email: 'x@example.com', plan: 'lifetime', devices: 1 });
    const first = await call('activate', { license_key: lic.key, instance_name: 'A' });
    assert.equal(first.body.activated, true);
    const second = await call('activate', { license_key: lic.key, instance_name: 'B' });
    assert.equal(second.status, 400);
    assert.equal(second.body.activated, false);
    assert.equal(second.body.error, 'This license key has reached the activation limit.');
    assert.equal(second.body.license_key.activation_usage, 1);
    assert.equal(second.body.license_key.activation_limit, 1);
  });

  test('unknown keys return 404 with the LemonSqueezy error', async () => {
    const a = await call('activate', { license_key: 'MCLN-AAAA-BBBB-CCCC-DDDD', instance_name: 'x' });
    assert.equal(a.status, 404);
    assert.deepEqual(a.body, { activated: false, error: 'license_key not found' });
    const v = await call('validate', { license_key: 'garbage', instance_id: 'x' });
    assert.equal(v.status, 404);
    assert.deepEqual(v.body, { valid: false, error: 'license_key not found' });
    const d = await call('deactivate', { license_key: 'MCLN-AAAA-BBBB-CCCC-DDDD', instance_id: 'x' });
    assert.equal(d.status, 404);
    assert.equal(d.body.deactivated, false);
  });

  test('disabled keys: activate 400, validate 200 valid:false; re-enable restores', async () => {
    const lic = issueLicense(srv.app.db, { email: 'y@example.com', plan: 'family' });
    const a = await call('activate', { license_key: lic.key, instance_name: 'A' });
    assert.equal(a.body.meta.variant_name, '家庭版');
    assert.equal(a.body.license_key.activation_limit, 5);

    const api = admin(srv, await adminLogin(srv));
    assert.equal((await api('POST', `/api/admin/licenses/${lic.key}/disable`)).status, 200);

    const v = await call('validate', { license_key: lic.key, instance_id: a.body.instance.id });
    assert.equal(v.status, 200);
    assert.equal(v.body.valid, false);
    assert.equal(v.body.license_key.status, 'disabled');

    const b = await call('activate', { license_key: lic.key, instance_name: 'B' });
    assert.equal(b.status, 400);
    assert.equal(b.body.activated, false);
    assert.equal(b.body.error, 'This license key is disabled.');
    assert.equal(b.body.license_key.status, 'disabled');

    await api('POST', `/api/admin/licenses/${lic.key}/enable`);
    const v2 = await call('validate', { license_key: lic.key, instance_id: a.body.instance.id });
    assert.equal(v2.body.valid, true);
  });

  test('admin freeing a device revokes that instance and frees the slot', async () => {
    const lic = issueLicense(srv.app.db, { plan: 'lifetime', devices: 1 });
    const a = await call('activate', { license_key: lic.key, instance_name: 'Old Mac' });
    const api = admin(srv, await adminLogin(srv));
    const detail = await api('GET', `/api/admin/licenses/${lic.key}`);
    assert.equal(detail.body.activations.length, 1);
    assert.equal(detail.body.activations[0].name, 'Old Mac');
    const freed = await api('DELETE', `/api/admin/licenses/${lic.key}/activations/${a.body.instance.id}`);
    assert.equal(freed.status, 200);
    assert.equal(freed.body.license.activationUsage, 0);
    assert.equal((await call('validate', { license_key: lic.key, instance_id: a.body.instance.id })).status, 404);
    assert.equal((await call('activate', { license_key: lic.key, instance_name: 'New Mac' })).body.activated, true);
  });

  test('missing instance_name is rejected', async () => {
    const r = await call('activate', { license_key: key });
    assert.equal(r.status, 400);
    assert.equal(r.body.activated, false);
  });
});

describe('license endpoint rate limit', () => {
  test('61st call within an hour from one IP gets 429 with the endpoint flag', async () => {
    const srv = await startServer();
    try {
      for (let i = 0; i < 60; i++) {
        const res = await srv.fetch('/api/licenses/validate', form({ license_key: 'x' }));
        assert.equal(res.status, 404);
        await res.arrayBuffer();
      }
      const res = await srv.fetch('/api/licenses/validate', form({ license_key: 'x' }));
      assert.equal(res.status, 429);
      assert.ok(res.headers.get('retry-after'));
      const body = await res.json();
      assert.equal(body.valid, false);
      assert.ok(body.error);
    } finally {
      await srv.close();
    }
  });
});
