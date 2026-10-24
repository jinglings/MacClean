import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { LICENSE_KEY_RE } from '../src/security.js';
import { admin, adminLogin, json, startServer } from './helpers.js';

describe('orders', () => {
  let srv;
  let api;
  before(async () => {
    // Preserve regression coverage for historical order and refund handling.
    srv = await startServer({ salesEnabled: true });
    api = admin(srv, await adminLogin(srv));
  });
  after(() => srv.close());

  const create = (body, ip) => srv.fetch('/api/orders', json(body, ip ? { 'cf-connecting-ip': ip } : {}));

  test('create → notify → confirm → key visible with token only', async () => {
    const res = await create({ plan: 'lifetime', email: 'Buyer@Example.com', payMethod: 'wechat', note: 'hi' }, '203.0.113.1');
    assert.equal(res.status, 201);
    const order = await res.json();
    assert.match(order.orderNo, /^MC\d{8}-[A-Z2-9]{4}$/);
    assert.equal(order.orderNo.slice(-4), order.payCode);
    assert.equal(order.amount, 98);
    assert.equal(order.status, 'pending');
    assert.equal(order.payMethod, 'wechat');
    assert.equal(order.accessToken.length, 24);

    let view = await (await srv.fetch(`/api/orders/${order.orderNo}?token=${order.accessToken}`)).json();
    assert.equal(view.status, 'pending');
    assert.equal(view.licenseKey, null);
    assert.equal(view.devices, 2);
    assert.equal(view.planName, '终身版');

    const notified = await srv.fetch(`/api/orders/${order.orderNo}/notify`, json({ token: order.accessToken }));
    assert.equal(notified.status, 200);
    const list = await api('GET', '/api/admin/orders?status=notified');
    assert.equal(list.body.items[0].orderNo, order.orderNo);
    assert.ok(list.body.items[0].buyerNotifiedAt);
    assert.equal(list.body.counts.pending, 1);

    const byCode = await api('GET', `/api/admin/orders?q=${order.payCode}`);
    assert.equal(byCode.body.total, 1);
    const byEmail = await api('GET', '/api/admin/orders?q=buyer@example');
    assert.equal(byEmail.body.total, 1);

    const confirmed = await api('POST', `/api/admin/orders/${order.orderNo}/confirm`);
    assert.equal(confirmed.status, 200);
    assert.match(confirmed.body.licenseKey, LICENSE_KEY_RE);
    assert.equal(confirmed.body.order.status, 'paid');

    // Confirming twice is idempotent.
    const again = await api('POST', `/api/admin/orders/${order.orderNo}/confirm`);
    assert.equal(again.body.licenseKey, confirmed.body.licenseKey);

    view = await (await srv.fetch(`/api/orders/${order.orderNo}?token=${order.accessToken}`)).json();
    assert.equal(view.status, 'paid');
    assert.equal(view.licenseKey, confirmed.body.licenseKey);
    assert.ok(view.paidAt);

    const byMail = await (await srv.fetch(`/api/orders/${order.orderNo}?email=buyer@example.com`)).json();
    assert.equal(byMail.licenseKey, confirmed.body.licenseKey);

    const lic = await api('GET', `/api/admin/licenses/${confirmed.body.licenseKey}`);
    assert.equal(lic.body.activationLimit, 2);
    assert.equal(lic.body.orderNo, order.orderNo);

    const cancel = await api('POST', `/api/admin/orders/${order.orderNo}/cancel`);
    assert.equal(cancel.status, 409);
  });

  test('wrong token or email → 404, same as a missing order', async () => {
    const order = await (await create({ plan: 'family', email: 'c@example.com', payMethod: 'alipay' }, '203.0.113.2')).json();
    assert.equal(order.amount, 168);
    for (const q of ['?token=wrong', '?email=other@example.com', '']) {
      const res = await srv.fetch(`/api/orders/${order.orderNo}${q}`);
      assert.equal(res.status, 404);
      assert.deepEqual(await res.json(), { error: 'Order not found' });
    }
    const missing = await srv.fetch(`/api/orders/MC20990101-AAAA?token=${order.accessToken}`);
    assert.equal(missing.status, 404);
    const notify = await srv.fetch(`/api/orders/${order.orderNo}/notify`, json({ token: 'nope' }));
    assert.equal(notify.status, 404);
  });

  test('cancel and note', async () => {
    const order = await (await create({ plan: 'lifetime', email: 'd@example.com', payMethod: 'wechat' }, '203.0.113.3')).json();
    const noted = await api('POST', `/api/admin/orders/${order.orderNo}/note`, { note: '金额不符' });
    assert.equal(noted.body.order.adminNote, '金额不符');
    const cancelled = await api('POST', `/api/admin/orders/${order.orderNo}/cancel`);
    assert.equal(cancelled.body.order.status, 'cancelled');
    const view = await (await srv.fetch(`/api/orders/${order.orderNo}?token=${order.accessToken}`)).json();
    assert.equal(view.status, 'cancelled');
    assert.equal(view.licenseKey, null);
  });

  test('validation: unknown plan, bad email, bad payMethod', async () => {
    const cases = [
      [{ plan: 'nope', email: 'a@example.com', payMethod: 'wechat' }, 'invalid_plan'],
      [{ plan: 'lifetime', email: 'not-an-email', payMethod: 'wechat' }, 'invalid_email'],
      [{ plan: 'lifetime', email: 'a@example.com', payMethod: 'paypal' }, 'invalid_pay_method'],
    ];
    for (const [body, code] of cases) {
      const res = await create(body, '203.0.113.4');
      assert.equal(res.status, 400);
      assert.equal((await res.json()).code, code);
    }
  });

  test('5 orders per IP per hour', async () => {
    const ip = '198.51.100.7';
    for (let i = 0; i < 5; i++) assert.equal((await create({ plan: 'lifetime', email: `r${i}@example.com`, payMethod: 'wechat' }, ip)).status, 201);
    const blocked = await create({ plan: 'lifetime', email: 'r9@example.com', payMethod: 'wechat' }, ip);
    assert.equal(blocked.status, 429);
    assert.ok(Number(blocked.headers.get('retry-after')) > 0);
    // A different client is unaffected.
    assert.equal((await create({ plan: 'lifetime', email: 'z@example.com', payMethod: 'wechat' }, '198.51.100.8')).status, 201);
  });

  test('JSON body over 64 KB is rejected', async () => {
    const res = await create({ plan: 'lifetime', email: 'a@example.com', payMethod: 'wechat', note: 'x'.repeat(70 * 1024) });
    assert.equal(res.status, 413);
  });

  test('stats reflect paid orders', async () => {
    const s = await api('GET', '/api/admin/stats');
    assert.equal(s.status, 200);
    assert.equal(s.body.series.length, 30);
    assert.equal(s.body.totals.ordersPaid, 1);
    assert.equal(s.body.totals.revenueTotal, 98);
    assert.equal(s.body.totals.revenueToday, 98);
    assert.equal(s.body.series.at(-1).revenue, 98);
  });

  test('public config lists plans and edited settings', async () => {
    const plans = [
      { id: 'lifetime', name: '终身版', nameEn: 'Lifetime', price: 88, devices: 3, features: ['a', ''], highlight: true },
    ];
    const put = await api('PUT', '/api/admin/settings', { plans, contactEmail: 'help@thulem.com', announcement: '国庆特惠' });
    assert.equal(put.status, 200);
    const cfg = await (await srv.fetch('/api/public/config')).json();
    assert.equal(cfg.plans.length, 1);
    assert.equal(cfg.plans[0].price, 88);
    assert.deepEqual(cfg.plans[0].features, ['a']);
    assert.equal(cfg.contactEmail, 'help@thulem.com');
    assert.equal(cfg.announcement, '国庆特惠');
    assert.deepEqual(Object.keys(cfg.payment).sort(), ['alipayQr', 'instructions', 'wechatQr']);
    const bad = await api('PUT', '/api/admin/settings', { plans: [{ id: 'X Y', name: 'a', price: 1, devices: 1 }] });
    assert.equal(bad.status, 400);
  });
});
