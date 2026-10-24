import assert from 'node:assert/strict';
import { test } from 'node:test';
import { loadConfig } from '../src/config.js';
import { json, startInProcessServer } from './helpers.js';
import { createOrder } from '../src/store.js';

test('free product hides checkout, rejects new paid orders and retains previous orders', async () => {
  assert.equal(loadConfig({ SALES_ENABLED: 'true' }).salesEnabled, false);
  const srv = await startInProcessServer();
  try {
    const old = createOrder(srv.app.db, srv.config, {
      plan: 'lifetime', email: 'previous@example.com', payMethod: 'wechat', ip: '127.0.0.1',
    });
    const cfg = await (await srv.fetch('/api/public/config')).json();
    assert.equal(cfg.salesEnabled, false);
    assert.deepEqual(cfg.plans, []);
    assert.equal(cfg.payment.wechatQr, null);
    assert.equal(cfg.payment.alipayQr, null);
    assert.equal(cfg.license.internalBusinessUse, 'free');
    assert.equal(cfg.license.commercialDistribution, 'separate-paid-agreement');
    assert.equal(cfg.license.sourcePublic, true);
    assert.equal(cfg.license.sourceUrl, 'https://github.com/jinglings/MacClean');
    const res = await srv.fetch('/api/orders', json({ plan: 'lifetime', email: 'new@example.com', payMethod: 'wechat' }));
    assert.equal(res.status, 410);
    assert.equal(srv.app.db.prepare('SELECT COUNT(*) AS n FROM orders').get().n, 1);
    const previous = await srv.fetch(`/api/orders/${old.orderNo}?token=${encodeURIComponent(old.accessToken)}`);
    assert.equal(previous.status, 200);
    assert.equal((await previous.json()).orderNo, old.orderNo);
  } finally { await srv.close(); }
});
