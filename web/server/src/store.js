import crypto from 'node:crypto';
import { getSetting, setSetting, transaction } from './db.js';
import { HttpError, isEmail, str } from './http.js';
import { KEY_ALPHABET, generateLicenseKey, normalizeLicenseKey, randomString, randomToken, safeEqual, sha256 } from './security.js';
import { dayKey, lastDays } from './time.js';
import { usageStats } from './usage.js';

export const STORE_ID = 1;
export const PRODUCT_ID = 1;
export const PRODUCT_NAME = 'MacClean';

export const DEFAULT_PLANS = [
  {
    id: 'lifetime', name: '终身版', nameEn: 'Lifetime', price: 98, currency: 'CNY', devices: 2, highlight: true,
    features: ['全部功能，一次买断', '可在 2 台 Mac 上使用', '含后续版本更新', '邮件支持'],
    featuresEn: ['Every feature, one-time purchase', 'Use on 2 Macs', 'Future updates included', 'Email support'],
  },
  {
    id: 'family', name: '家庭版', nameEn: 'Family', price: 168, currency: 'CNY', devices: 5, highlight: false,
    features: ['全部功能，一次买断', '可在 5 台 Mac 上使用', '含后续版本更新', '邮件支持'],
    featuresEn: ['Every feature, one-time purchase', 'Use on 5 Macs', 'Future updates included', 'Email support'],
  },
];

export const DEFAULT_INSTRUCTIONS = '请用微信或支付宝扫码支付订单金额，并在付款备注中填写 4 位付款码。'
  + '我们核对到账后会尽快发放许可证（通常 12 小时内），届时可在订单页面查看并复制许可证密钥。';

const now = () => new Date().toISOString();

// MARK: - Settings

export function getPlans(db) {
  const plans = getSetting(db, 'plans');
  return Array.isArray(plans) && plans.length ? plans : DEFAULT_PLANS;
}

export function findPlan(db, planId) {
  return getPlans(db).find((p) => p.id === planId) || null;
}

export function sanitizePlans(input) {
  if (!Array.isArray(input) || input.length === 0 || input.length > 10) throw new HttpError(400, '至少需要 1 个、最多 10 个套餐');
  const ids = new Set();
  return input.map((p, i) => {
    const id = str(p?.id, 32).toLowerCase();
    if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(id)) throw new HttpError(400, `第 ${i + 1} 个套餐的 ID 只能包含小写字母、数字、- 和 _`);
    if (ids.has(id)) throw new HttpError(400, `套餐 ID 重复：${id}`);
    ids.add(id);
    const name = str(p.name, 40);
    if (!name) throw new HttpError(400, `第 ${i + 1} 个套餐缺少名称`);
    const price = Math.round(Number(p.price) * 100) / 100;
    if (!Number.isFinite(price) || price <= 0 || price > 100000) throw new HttpError(400, `套餐「${name}」的价格无效`);
    const devices = Number(p.devices);
    if (!Number.isInteger(devices) || devices < 1 || devices > 100) throw new HttpError(400, `套餐「${name}」的设备数无效`);
    const list = (v) => (Array.isArray(v) ? v : []).map((f) => str(f, 120)).filter(Boolean).slice(0, 12);
    return {
      id, name, nameEn: str(p.nameEn, 40) || name, price, currency: 'CNY', devices,
      features: list(p.features), featuresEn: list(p.featuresEn), highlight: Boolean(p.highlight),
    };
  });
}

export function qrPath(db, kind) {
  const entry = getSetting(db, `qr_${kind}`);
  return entry?.file ? `/files/${entry.file}?v=${entry.version}` : null;
}

export function publicConfig(db, config = {}) {
  const latest = latestRelease(db);
  const announcement = str(getSetting(db, 'announcement', ''), 2000);
  return {
    salesEnabled: config.salesEnabled === true,
    license: { name: 'MacClean Community License 1.0', personalUse: 'free', internalBusinessUse: 'free', commercialDistribution: 'separate-paid-agreement', termsUrl: '/terms.html', sourcePublic: true, sourceUrl: 'https://github.com/jinglings/MacClean' },
    plans: config.salesEnabled === true ? getPlans(db).map(({ id, name, nameEn, price, currency, devices, features, featuresEn, highlight }) =>
      ({ id, name, nameEn, price, currency, devices, features, featuresEn, highlight })) : [],
    payment: config.salesEnabled === true ? {
      wechatQr: qrPath(db, 'wechat'),
      alipayQr: qrPath(db, 'alipay'),
      instructions: getSetting(db, 'payment_instructions', DEFAULT_INSTRUCTIONS),
    } : { wechatQr: null, alipayQr: null, instructions: '' },
    contactEmail: getSetting(db, 'contact_email', ''),
    announcement: announcement || null,
    latestRelease: latest ? {
      version: latest.version, build: latest.build, minOS: latest.min_os, size: latest.size,
      notes: latest.notes, publishedAt: latest.published_at, downloadUrl: '/download/latest',
    } : null,
  };
}

// MARK: - Orders

function orderDay(timeZone) {
  return dayKey(new Date(), timeZone).replaceAll('-', '');
}

export function createOrder(db, config, { plan, email, payMethod, note, ip }) {
  const planObj = findPlan(db, str(plan, 32));
  if (!planObj) throw new HttpError(400, 'Unknown plan', { body: { code: 'invalid_plan' } });
  const cleanEmail = str(email, 254).toLowerCase();
  if (!isEmail(cleanEmail)) throw new HttpError(400, 'Invalid email address', { body: { code: 'invalid_email' } });
  if (payMethod !== 'wechat' && payMethod !== 'alipay') throw new HttpError(400, 'payMethod must be wechat or alipay', { body: { code: 'invalid_pay_method' } });

  return transaction(db, () => {
    const prefix = `MC${orderDay(config.timeZone)}-`;
    let payCode;
    let orderNo;
    for (let attempt = 0; ; attempt++) {
      if (attempt > 50) throw new HttpError(503, 'Could not allocate an order number');
      payCode = randomString(4, KEY_ALPHABET);
      orderNo = prefix + payCode;
      // The pay code must be unambiguous among orders the admin may still be matching.
      const clash = db.prepare("SELECT 1 FROM orders WHERE order_no = ? OR (pay_code = ? AND status = 'pending')").get(orderNo, payCode);
      if (!clash) break;
    }
    const accessToken = randomToken(18);
    const createdAt = now();
    db.prepare(`INSERT INTO orders (order_no, plan_id, plan_name, amount, currency, devices, email, pay_method, pay_code,
        status, access_token, buyer_note, ip, created_at)
      VALUES (?, ?, ?, ?, 'CNY', ?, ?, ?, ?, 'pending', ?, ?, ?, ?)`)
      .run(orderNo, planObj.id, planObj.name, planObj.price, planObj.devices, cleanEmail, payMethod, payCode,
        accessToken, str(note, 500) || null, ip ?? null, createdAt);
    return { orderNo, amount: planObj.price, payMethod, payCode, status: 'pending', accessToken, plan: planObj.id, planName: planObj.name, createdAt };
  });
}

function orderByNo(db, orderNo) {
  if (typeof orderNo !== 'string' || orderNo.length > 40) return null;
  return db.prepare('SELECT * FROM orders WHERE order_no = ?').get(orderNo.toUpperCase()) || null;
}

/** Looks up an order for the buyer; any mismatch is a 404 so order numbers can't be probed. */
export function orderForBuyer(db, orderNo, { token, email }) {
  const order = orderByNo(db, orderNo);
  const tokenOk = order && token && safeEqual(String(token), order.access_token);
  const emailOk = order && email && safeEqual(String(email).trim().toLowerCase(), order.email);
  if (!tokenOk && !emailOk) throw new HttpError(404, 'Order not found');
  return order;
}

export function publicOrder(order) {
  return {
    orderNo: order.order_no,
    plan: order.plan_id,
    planName: order.plan_name,
    amount: order.amount,
    currency: order.currency,
    payMethod: order.pay_method,
    payCode: order.pay_code,
    status: order.status,
    createdAt: order.created_at,
    paidAt: order.paid_at,
    buyerNotifiedAt: order.buyer_notified_at,
    licenseKey: order.status === 'paid' ? order.license_key : null,
    devices: order.devices,
  };
}

export function notifyPaid(db, orderNo, token) {
  const order = orderForBuyer(db, orderNo, { token });
  if (order.status === 'pending' && !order.buyer_notified_at) {
    db.prepare('UPDATE orders SET buyer_notified_at = ? WHERE id = ?').run(now(), order.id);
  }
  return orderByNo(db, order.order_no);
}

export function adminOrder(order) {
  return {
    id: order.id,
    orderNo: order.order_no,
    plan: order.plan_id,
    planName: order.plan_name,
    amount: order.amount,
    currency: order.currency,
    devices: order.devices,
    email: order.email,
    payMethod: order.pay_method,
    payCode: order.pay_code,
    status: order.status,
    buyerNote: order.buyer_note,
    adminNote: order.admin_note,
    ip: order.ip,
    createdAt: order.created_at,
    buyerNotifiedAt: order.buyer_notified_at,
    paidAt: order.paid_at,
    cancelledAt: order.cancelled_at,
    licenseKey: order.license_key,
  };
}

function likeTerm(q) {
  return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}

export function listOrders(db, { status, q, page = 1, pageSize = 20 }) {
  const where = [];
  const params = [];
  if (status === 'notified') where.push("status = 'pending' AND buyer_notified_at IS NOT NULL");
  else if (['pending', 'paid', 'cancelled'].includes(status)) { where.push('status = ?'); params.push(status); }
  const term = str(q, 100);
  if (term) {
    where.push("(email LIKE ? ESCAPE '\\' OR order_no LIKE ? ESCAPE '\\' OR pay_code = ? OR license_key = ?)");
    params.push(likeTerm(term.toLowerCase()), likeTerm(term.toUpperCase()), term.toUpperCase(), term.toUpperCase());
  }
  const clause = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const size = Math.min(Math.max(Number(pageSize) || 20, 1), 100);
  const pg = Math.max(Number(page) || 1, 1);
  const total = db.prepare(`SELECT COUNT(*) AS n FROM orders ${clause}`).get(...params).n;
  // Pending orders the buyer marked as paid float to the top.
  const rows = db.prepare(`SELECT * FROM orders ${clause}
    ORDER BY (status = 'pending' AND buyer_notified_at IS NOT NULL) DESC, id DESC LIMIT ? OFFSET ?`)
    .all(...params, size, (pg - 1) * size);
  return { items: rows.map(adminOrder), total, page: pg, pageSize: size, counts: orderCounts(db) };
}

export function orderCounts(db) {
  const row = db.prepare(`SELECT
      COUNT(*) AS all_count,
      SUM(status = 'pending') AS pending,
      SUM(status = 'pending' AND buyer_notified_at IS NOT NULL) AS notified,
      SUM(status = 'paid') AS paid,
      SUM(status = 'cancelled') AS cancelled,
      MAX(CASE WHEN status = 'pending' THEN id END) AS latest_pending_id
    FROM orders`).get();
  return {
    all: row.all_count || 0, pending: row.pending || 0, notified: row.notified || 0,
    paid: row.paid || 0, cancelled: row.cancelled || 0, latestPendingId: row.latest_pending_id || 0,
  };
}

export function getAdminOrder(db, orderNo) {
  const order = orderByNo(db, orderNo);
  if (!order) throw new HttpError(404, '订单不存在');
  return order;
}

export function confirmOrder(db, orderNo) {
  return transaction(db, () => {
    const order = getAdminOrder(db, orderNo);
    if (order.status === 'paid' && order.license_key) return { order: orderByNo(db, order.order_no), licenseKey: order.license_key, created: false };
    const license = insertLicense(db, {
      email: order.email, planId: order.plan_id, planName: order.plan_name, devices: order.devices,
      orderNo: order.order_no, source: 'order', note: null,
    });
    db.prepare("UPDATE orders SET status = 'paid', paid_at = ?, cancelled_at = NULL, license_key = ? WHERE id = ?")
      .run(now(), license.key, order.id);
    return { order: orderByNo(db, order.order_no), licenseKey: license.key, created: true };
  });
}

export function cancelOrder(db, orderNo) {
  const order = getAdminOrder(db, orderNo);
  if (order.status === 'paid') throw new HttpError(409, '已付款的订单不能取消；如需退款请停用对应许可证');
  if (order.status !== 'cancelled') db.prepare("UPDATE orders SET status = 'cancelled', cancelled_at = ? WHERE id = ?").run(now(), order.id);
  return orderByNo(db, order.order_no);
}

export function noteOrder(db, orderNo, note) {
  const order = getAdminOrder(db, orderNo);
  db.prepare('UPDATE orders SET admin_note = ? WHERE id = ?').run(str(note, 1000) || null, order.id);
  return orderByNo(db, order.order_no);
}

// MARK: - Licenses

function insertLicense(db, { email, planId, planName, devices, orderNo, source, note }) {
  for (let attempt = 0; attempt < 20; attempt++) {
    const key = generateLicenseKey();
    if (db.prepare('SELECT 1 FROM licenses WHERE key = ?').get(key)) continue;
    const info = db.prepare(`INSERT INTO licenses (key, email, plan_id, plan_name, activation_limit, status, order_no, note, source, created_at)
      VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)`)
      .run(key, email || null, planId || null, planName, devices, orderNo || null, note || null, source, now());
    return db.prepare('SELECT * FROM licenses WHERE id = ?').get(info.lastInsertRowid);
  }
  throw new HttpError(503, 'Could not generate a unique license key');
}

export function issueLicense(db, { email, plan, devices, note }) {
  const planObj = findPlan(db, str(plan, 32));
  if (!planObj) throw new HttpError(400, '套餐不存在');
  const cleanEmail = str(email, 254).toLowerCase();
  if (cleanEmail && !isEmail(cleanEmail)) throw new HttpError(400, '邮箱格式不正确');
  const limit = devices === undefined || devices === null || devices === '' ? planObj.devices : Number(devices);
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new HttpError(400, '设备数需为 1–1000 的整数');
  return insertLicense(db, {
    email: cleanEmail, planId: planObj.id, planName: planObj.name, devices: limit,
    orderNo: null, source: 'manual', note: str(note, 1000),
  });
}

export function licenseByKey(db, rawKey) {
  const key = normalizeLicenseKey(rawKey);
  if (!key) return null;
  return db.prepare('SELECT * FROM licenses WHERE key = ?').get(key) || null;
}

export function activationUsage(db, licenseId) {
  return db.prepare('SELECT COUNT(*) AS n FROM activations WHERE license_id = ? AND deactivated_at IS NULL').get(licenseId).n;
}

export function adminLicense(db, lic, { withActivations = false } = {}) {
  const usage = activationUsage(db, lic.id);
  const out = {
    id: lic.id, key: lic.key, email: lic.email, plan: lic.plan_id, planName: lic.plan_name,
    activationLimit: lic.activation_limit, activationUsage: usage, status: lic.status,
    orderNo: lic.order_no, note: lic.note, source: lic.source, createdAt: lic.created_at, disabledAt: lic.disabled_at,
  };
  if (withActivations) {
    out.activations = db.prepare('SELECT * FROM activations WHERE license_id = ? ORDER BY deactivated_at IS NOT NULL, created_at DESC')
      .all(lic.id).map((a) => ({
        id: a.id, name: a.name, appVersion: a.app_version, ip: a.ip, createdAt: a.created_at,
        lastSeenAt: a.last_seen_at, deactivatedAt: a.deactivated_at, deactivatedBy: a.deactivated_by,
      }));
  }
  return out;
}

export function listLicenses(db, { q, status, page = 1, pageSize = 20 }) {
  const where = [];
  const params = [];
  if (status === 'active' || status === 'disabled') { where.push('status = ?'); params.push(status); }
  const term = str(q, 100);
  if (term) {
    where.push("(key LIKE ? ESCAPE '\\' OR email LIKE ? ESCAPE '\\' OR order_no LIKE ? ESCAPE '\\' OR note LIKE ? ESCAPE '\\')");
    params.push(likeTerm(term.toUpperCase()), likeTerm(term.toLowerCase()), likeTerm(term.toUpperCase()), likeTerm(term));
  }
  const clause = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const size = Math.min(Math.max(Number(pageSize) || 20, 1), 100);
  const pg = Math.max(Number(page) || 1, 1);
  const total = db.prepare(`SELECT COUNT(*) AS n FROM licenses ${clause}`).get(...params).n;
  const rows = db.prepare(`SELECT * FROM licenses ${clause} ORDER BY id DESC LIMIT ? OFFSET ?`).all(...params, size, (pg - 1) * size);
  return { items: rows.map((l) => adminLicense(db, l)), total, page: pg, pageSize: size };
}

export function getAdminLicense(db, key) {
  const lic = licenseByKey(db, key);
  if (!lic) throw new HttpError(404, '许可证不存在');
  return lic;
}

export function setLicenseStatus(db, key, status) {
  const lic = getAdminLicense(db, key);
  db.prepare('UPDATE licenses SET status = ?, disabled_at = ? WHERE id = ?').run(status, status === 'disabled' ? now() : null, lic.id);
  return db.prepare('SELECT * FROM licenses WHERE id = ?').get(lic.id);
}

export function updateLicense(db, key, { devices, note, email }) {
  const lic = getAdminLicense(db, key);
  if (devices !== undefined) {
    const n = Number(devices);
    if (!Number.isInteger(n) || n < 1 || n > 1000) throw new HttpError(400, '设备数需为 1–1000 的整数');
    db.prepare('UPDATE licenses SET activation_limit = ? WHERE id = ?').run(n, lic.id);
  }
  if (note !== undefined) db.prepare('UPDATE licenses SET note = ? WHERE id = ?').run(str(note, 1000) || null, lic.id);
  if (email !== undefined) {
    const e = str(email, 254).toLowerCase();
    if (e && !isEmail(e)) throw new HttpError(400, '邮箱格式不正确');
    db.prepare('UPDATE licenses SET email = ? WHERE id = ?').run(e || null, lic.id);
  }
  return db.prepare('SELECT * FROM licenses WHERE id = ?').get(lic.id);
}

export function releaseActivation(db, key, activationId) {
  const lic = getAdminLicense(db, key);
  const info = db.prepare(`UPDATE activations SET deactivated_at = ?, deactivated_by = 'admin'
    WHERE id = ? AND license_id = ? AND deactivated_at IS NULL`).run(now(), String(activationId), lic.id);
  if (info.changes === 0) throw new HttpError(404, '设备不存在或已解绑');
  return lic;
}

// MARK: - LemonSqueezy-compatible license API

function keyStatus(lic, usage) {
  if (lic.status === 'disabled') return 'disabled';
  return usage > 0 ? 'active' : 'inactive';
}

function licenseKeyJson(lic, usage) {
  return {
    id: lic.id,
    status: keyStatus(lic, usage),
    key: lic.key,
    activation_limit: lic.activation_limit,
    activation_usage: usage,
    created_at: lic.created_at,
    expires_at: null,
  };
}

function metaJson(db, lic) {
  const plans = getPlans(db);
  const index = plans.findIndex((p) => p.id === lic.plan_id);
  const order = lic.order_no ? db.prepare('SELECT id FROM orders WHERE order_no = ?').get(lic.order_no) : null;
  return {
    store_id: STORE_ID,
    order_id: order?.id ?? null,
    order_item_id: null,
    product_id: PRODUCT_ID,
    product_name: PRODUCT_NAME,
    variant_id: index >= 0 ? index + 1 : null,
    variant_name: lic.plan_name,
    customer_id: null,
    customer_name: null,
    customer_email: lic.email,
  };
}

function instanceJson(a) {
  return { id: a.id, name: a.name, created_at: a.created_at };
}

const NOT_FOUND = 'license_key not found';
const DISABLED = 'This license key is disabled.';
const LIMIT = 'This license key has reached the activation limit.';

/** Each returns `{ status, body }` exactly as LemonSqueezy would. */
export function licenseActivate(db, { license_key: rawKey, instance_name: rawName, app_version: appVersion }, ip) {
  const name = str(rawName, 200);
  const lic = licenseByKey(db, rawKey);
  if (!lic) return { status: 404, body: { activated: false, error: NOT_FOUND } };
  if (!name) return { status: 400, body: { activated: false, error: 'The instance name field is required.' } };
  return transaction(db, () => {
    const usage = activationUsage(db, lic.id);
    if (lic.status === 'disabled') {
      return { status: 400, body: { activated: false, error: DISABLED, license_key: licenseKeyJson(lic, usage), meta: metaJson(db, lic) } };
    }
    if (usage >= lic.activation_limit) {
      return { status: 400, body: { activated: false, error: LIMIT, license_key: licenseKeyJson(lic, usage), meta: metaJson(db, lic) } };
    }
    const id = crypto.randomUUID();
    const t = now();
    db.prepare('INSERT INTO activations (id, license_id, name, app_version, ip, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
      .run(id, lic.id, name, str(appVersion, 40) || null, ip ?? null, t, t);
    const activation = db.prepare('SELECT * FROM activations WHERE id = ?').get(id);
    return {
      status: 200,
      body: { activated: true, error: null, license_key: licenseKeyJson(lic, usage + 1), instance: instanceJson(activation), meta: metaJson(db, lic) },
    };
  });
}

function findActivation(db, lic, instanceId) {
  if (!instanceId) return null;
  return db.prepare('SELECT * FROM activations WHERE id = ? AND license_id = ? AND deactivated_at IS NULL').get(String(instanceId), lic.id) || null;
}

function touch(db, activation, appVersion, ip) {
  db.prepare('UPDATE activations SET last_seen_at = ?, app_version = COALESCE(?, app_version), ip = COALESCE(?, ip) WHERE id = ?')
    .run(now(), str(appVersion, 40) || null, ip ?? null, activation.id);
}

export function licenseValidate(db, { license_key: rawKey, instance_id: instanceId, app_version: appVersion }, ip) {
  const lic = licenseByKey(db, rawKey);
  if (!lic) return { status: 404, body: { valid: false, error: NOT_FOUND } };
  let activation = null;
  if (instanceId) {
    activation = findActivation(db, lic, instanceId);
    if (!activation) return { status: 404, body: { valid: false, error: 'instance not found' } };
    touch(db, activation, appVersion, ip);
  }
  const usage = activationUsage(db, lic.id);
  const body = {
    valid: lic.status !== 'disabled',
    error: lic.status === 'disabled' ? DISABLED : null,
    license_key: licenseKeyJson(lic, usage),
    instance: activation ? instanceJson(activation) : null,
    meta: metaJson(db, lic),
  };
  return { status: 200, body };
}

export function licenseDeactivate(db, { license_key: rawKey, instance_id: instanceId }, ip) {
  const lic = licenseByKey(db, rawKey);
  if (!lic) return { status: 404, body: { deactivated: false, error: NOT_FOUND } };
  const activation = findActivation(db, lic, instanceId);
  if (!activation) return { status: 404, body: { deactivated: false, error: 'instance not found' } };
  db.prepare("UPDATE activations SET deactivated_at = ?, deactivated_by = 'user', ip = COALESCE(?, ip) WHERE id = ?")
    .run(now(), ip ?? null, activation.id);
  const usage = activationUsage(db, lic.id);
  return { status: 200, body: { deactivated: true, error: null, license_key: licenseKeyJson(lic, usage), meta: metaJson(db, lic) } };
}

// MARK: - Releases & downloads

export function latestRelease(db) {
  return db.prepare('SELECT * FROM releases WHERE is_latest = 1').get()
    || db.prepare('SELECT * FROM releases ORDER BY published_at DESC, id DESC LIMIT 1').get()
    || null;
}

export function adminRelease(r, config) {
  return {
    id: r.id, version: r.version, build: r.build, minOS: r.min_os, notes: r.notes, edSignature: r.ed_signature,
    fileName: r.file_name, size: r.size, sha256: r.sha256, isLatest: Boolean(r.is_latest), downloads: r.downloads,
    publishedAt: r.published_at, url: `${config.publicBaseUrl}/files/releases/${r.file_name}`,
  };
}

export function recordDownload(db, config, release, ip) {
  const day = dayKey(new Date(), config.timeZone);
  // Salted with the day so the stored hash can't be joined across days or reversed with a rainbow table.
  const ipHash = sha256(`${day}|${ip}|${getDownloadSalt(db)}`);
  transaction(db, () => {
    const fresh = db.prepare('INSERT OR IGNORE INTO download_ips (day, ip_hash) VALUES (?, ?)').run(day, ipHash).changes;
    db.prepare(`INSERT INTO downloads_daily (day, count, unique_count) VALUES (?, 1, ?)
      ON CONFLICT(day) DO UPDATE SET count = count + 1, unique_count = unique_count + excluded.unique_count`).run(day, fresh);
    db.prepare('UPDATE releases SET downloads = downloads + 1 WHERE id = ?').run(release.id);
  });
}

function getDownloadSalt(db) {
  let salt = getSetting(db, 'download_salt');
  if (!salt) {
    salt = randomToken(16);
    setSetting(db, 'download_salt', salt);
  }
  return salt;
}

// MARK: - Stats

export function stats(db, config) {
  const tz = config.timeZone;
  const days = lastDays(30, tz);
  const today = days[days.length - 1];
  const since = new Date(Date.now() - 32 * 86400000).toISOString();
  const series = new Map(days.map((d) => [d, { day: d, orders: 0, paidOrders: 0, revenue: 0, downloads: 0, uniqueDownloads: 0, activations: 0 }]));
  const usage = usageStats(db, days);
  for (const [day, values] of usage.series) Object.assign(series.get(day), values);

  for (const o of db.prepare('SELECT created_at FROM orders WHERE created_at >= ?').all(since)) {
    const s = series.get(dayKey(o.created_at, tz));
    if (s) s.orders += 1;
  }
  let revenueToday = 0;
  for (const o of db.prepare("SELECT paid_at, amount FROM orders WHERE status = 'paid' AND paid_at >= ?").all(since)) {
    const d = dayKey(o.paid_at, tz);
    const s = series.get(d);
    if (s) { s.paidOrders += 1; s.revenue += o.amount; }
    if (d === today) revenueToday += o.amount;
  }
  for (const a of db.prepare('SELECT created_at FROM activations WHERE created_at >= ?').all(since)) {
    const s = series.get(dayKey(a.created_at, tz));
    if (s) s.activations += 1;
  }
  for (const d of db.prepare('SELECT * FROM downloads_daily WHERE day >= ?').all(days[0])) {
    const s = series.get(d.day);
    if (s) { s.downloads = d.count; s.uniqueDownloads = d.unique_count; }
  }

  const counts = orderCounts(db);
  const revenueTotal = db.prepare("SELECT COALESCE(SUM(amount), 0) AS n FROM orders WHERE status = 'paid'").get().n;
  const licenseRow = db.prepare(`SELECT COUNT(*) AS total, SUM(source = 'order') AS sold, SUM(status = 'active') AS active FROM licenses`).get();
  const activeDevices = db.prepare(`SELECT COUNT(*) AS n FROM activations a JOIN licenses l ON l.id = a.license_id
    WHERE a.deactivated_at IS NULL AND l.status = 'active'`).get().n;
  const seen7d = db.prepare('SELECT COUNT(*) AS n FROM activations WHERE deactivated_at IS NULL AND last_seen_at >= ?')
    .get(new Date(Date.now() - 7 * 86400000).toISOString()).n;
  const dl = db.prepare('SELECT COALESCE(SUM(count), 0) AS total FROM downloads_daily').get().total;
  const seriesList = [...series.values()].map((s) => ({ ...s, revenue: Math.round(s.revenue * 100) / 100 }));
  const last7 = seriesList.slice(-7);

  return {
    totals: {
      ordersPending: counts.pending,
      ordersNotified: counts.notified,
      ordersPaid: counts.paid,
      ordersCancelled: counts.cancelled,
      revenueToday: Math.round(revenueToday * 100) / 100,
      revenueTotal: Math.round(revenueTotal * 100) / 100,
      licensesTotal: licenseRow.total || 0,
      licensesSold: licenseRow.sold || 0,
      licensesActive: licenseRow.active || 0,
      activeDevices,
      devicesSeen7d: seen7d,
      downloadsToday: series.get(today)?.downloads ?? 0,
      uniqueDownloadsToday: series.get(today)?.uniqueDownloads ?? 0,
      downloads7d: last7.reduce((n, s) => n + s.downloads, 0),
      downloadsTotal: dl,
    },
    usage: usage.totals,
    series: seriesList,
    today,
    timeZone: tz,
  };
}
