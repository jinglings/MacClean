import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  createSession, currentSession, destroyOtherSessions, destroySession, passwordFromEnv, passwordHash, storePassword,
} from '../auth.js';
import { audit, getSetting, setSetting, transaction } from '../db.js';
import { HttpError, enforceLimit, isEmail, sendJson, str } from '../http.js';
import { parseMultipart } from '../multipart.js';
import { randomToken, safeEqual, verifyPassword } from '../security.js';
import {
  DEFAULT_INSTRUCTIONS, adminLicense, adminOrder, adminRelease, cancelOrder, confirmOrder, getAdminLicense, getAdminOrder,
  getPlans, issueLicense, listLicenses, listOrders, noteOrder, orderCounts, qrPath, releaseActivation, sanitizePlans,
  setLicenseStatus, stats, updateLicense,
} from '../store.js';

const VERSION_RE = /^[0-9][0-9A-Za-z.+-]{0,31}$/;
const BUILD_RE = /^[0-9][0-9A-Za-z.]{0,31}$/;
const MINOS_RE = /^\d{1,2}(\.\d{1,2}){0,2}$/;
const SIGNATURE_RE = /^[A-Za-z0-9+/=]{20,200}$/;

/** UDIF disk images end with a 512-byte "koly" trailer. */
async function looksLikeDmg(file, size) {
  if (size < 512) return false;
  const fh = await fs.promises.open(file, 'r');
  try {
    const buf = Buffer.alloc(4);
    await fh.read(buf, 0, 4, size - 512);
    return buf.toString('latin1') === 'koly';
  } finally {
    await fh.close();
  }
}

function imageKind(head) {
  if (head.length >= 8 && head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'png';
  if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'jpg';
  return null;
}

function settingsPayload(ctx) {
  const { db, config } = ctx;
  return {
    plans: getPlans(db),
    paymentInstructions: getSetting(db, 'payment_instructions', DEFAULT_INSTRUCTIONS),
    wechatQr: qrPath(db, 'wechat'),
    alipayQr: qrPath(db, 'alipay'),
    contactEmail: getSetting(db, 'contact_email', ''),
    announcement: getSetting(db, 'announcement', ''),
    passwordFromEnv: passwordFromEnv(ctx),
    publicBaseUrl: config.publicBaseUrl,
    appcastUrl: `${config.publicBaseUrl}/appcast.xml`,
    downloadUrl: `${config.publicBaseUrl}/download/latest`,
  };
}

export function adminRoutes(ctx) {
  const { db, config, limiters, state } = ctx;
  const log = (c, action, target, detail) => audit(db, action, { target, detail, ip: c.ip });
  const auth = { auth: true };

  return [
    // MARK: Session

    ['GET', '/api/admin/session', ({ req }) => ({
      authenticated: Boolean(currentSession(ctx, req)),
      setupRequired: !passwordHash(ctx),
      passwordFromEnv: passwordFromEnv(ctx),
    })],

    ['POST', '/api/admin/setup', async (c) => {
      enforceLimit(limiters.login, c.ip);
      if (passwordHash(ctx)) throw new HttpError(409, '管理员密码已设置');
      if (!state.setupToken || !safeEqual(str(c.body.token, 200), state.setupToken)) {
        throw new HttpError(403, '初始化令牌不正确（请在服务器日志中查找 setup token）');
      }
      await storePassword(ctx, c.body.password);
      state.setupToken = null;
      log(c, 'admin.setup');
      createSession(ctx, c.req, c.res, c.ip);
      return { ok: true };
    }, { csrf: true }],

    ['POST', '/api/admin/login', async (c) => {
      enforceLimit(limiters.login, c.ip);
      const hash = passwordHash(ctx);
      if (!hash) throw new HttpError(409, '尚未设置管理员密码');
      if (!(await verifyPassword(str(c.body.password, 300), hash))) {
        log(c, 'admin.login_failed');
        throw new HttpError(401, '密码不正确');
      }
      limiters.login.reset(c.ip);
      createSession(ctx, c.req, c.res, c.ip);
      log(c, 'admin.login');
      return { ok: true };
    }, { csrf: true }],

    ['POST', '/api/admin/logout', (c) => {
      destroySession(ctx, c.req, c.res);
      return { ok: true };
    }, { csrf: true }],

    ['POST', '/api/admin/password', async (c) => {
      if (passwordFromEnv(ctx)) throw new HttpError(409, '密码由环境变量 ADMIN_PASSWORD_HASH 管理，请在服务器上修改');
      enforceLimit(limiters.login, c.ip);
      if (!(await verifyPassword(str(c.body.current, 300), passwordHash(ctx)))) throw new HttpError(400, '当前密码不正确');
      await storePassword(ctx, c.body.next);
      destroyOtherSessions(ctx, c.session.id_hash);
      log(c, 'admin.password_changed');
      return { ok: true };
    }, auth],

    // MARK: Dashboard

    ['GET', '/api/admin/stats', () => stats(db, config), auth],
    ['GET', '/api/admin/orders/summary', () => {
      const latest = db.prepare("SELECT * FROM orders WHERE status = 'pending' ORDER BY id DESC LIMIT 5").all().map(adminOrder);
      return { counts: orderCounts(db), latest };
    }, auth],

    // MARK: Orders

    ['GET', '/api/admin/orders', ({ query }) => listOrders(db, {
      status: query.get('status'), q: query.get('q'), page: query.get('page'), pageSize: query.get('pageSize'),
    }), auth],

    ['GET', '/api/admin/orders/:no', ({ params }) => adminOrder(getAdminOrder(db, params.no)), auth],

    ['POST', '/api/admin/orders/:no/confirm', (c) => {
      const { order, licenseKey, created } = confirmOrder(db, c.params.no);
      if (created) log(c, 'order.confirm', order.order_no, { amount: order.amount, email: order.email, licenseKey });
      return { order: adminOrder(order), licenseKey };
    }, auth],

    ['POST', '/api/admin/orders/:no/cancel', (c) => {
      const order = cancelOrder(db, c.params.no);
      log(c, 'order.cancel', order.order_no);
      return { order: adminOrder(order) };
    }, auth],

    ['POST', '/api/admin/orders/:no/note', (c) => {
      const order = noteOrder(db, c.params.no, c.body.note);
      log(c, 'order.note', order.order_no, { note: order.admin_note });
      return { order: adminOrder(order) };
    }, auth],

    // MARK: Licenses

    ['GET', '/api/admin/licenses', ({ query }) => listLicenses(db, {
      q: query.get('q'), status: query.get('status'), page: query.get('page'), pageSize: query.get('pageSize'),
    }), auth],

    ['POST', '/api/admin/licenses', (c) => {
      const lic = issueLicense(db, c.body);
      log(c, 'license.issue', lic.key, { email: lic.email, plan: lic.plan_id, devices: lic.activation_limit });
      return { license: adminLicense(db, lic, { withActivations: true }) };
    }, auth],

    ['GET', '/api/admin/licenses/:key', ({ params }) => adminLicense(db, getAdminLicense(db, params.key), { withActivations: true }), auth],

    ['PATCH', '/api/admin/licenses/:key', (c) => {
      const lic = updateLicense(db, c.params.key, c.body);
      log(c, 'license.update', lic.key, { devices: c.body.devices, note: c.body.note, email: c.body.email });
      return { license: adminLicense(db, lic, { withActivations: true }) };
    }, auth],

    ['POST', '/api/admin/licenses/:key/disable', (c) => {
      const lic = setLicenseStatus(db, c.params.key, 'disabled');
      log(c, 'license.disable', lic.key);
      return { license: adminLicense(db, lic, { withActivations: true }) };
    }, auth],

    ['POST', '/api/admin/licenses/:key/enable', (c) => {
      const lic = setLicenseStatus(db, c.params.key, 'active');
      log(c, 'license.enable', lic.key);
      return { license: adminLicense(db, lic, { withActivations: true }) };
    }, auth],

    ['DELETE', '/api/admin/licenses/:key/activations/:id', (c) => {
      const lic = releaseActivation(db, c.params.key, c.params.id);
      log(c, 'license.release_device', lic.key, { activation: c.params.id });
      return { license: adminLicense(db, lic, { withActivations: true }) };
    }, auth],

    // MARK: Releases

    ['GET', '/api/admin/releases', () => ({
      items: db.prepare('SELECT * FROM releases ORDER BY published_at DESC, id DESC').all().map((r) => adminRelease(r, config)),
      appcastUrl: `${config.publicBaseUrl}/appcast.xml`,
      downloadUrl: `${config.publicBaseUrl}/download/latest`,
    }), auth],

    ['POST', '/api/admin/releases', async (c) => {
      const dir = path.join(config.filesDir, 'releases');
      await fs.promises.mkdir(dir, { recursive: true });
      const tmp = path.join(dir, `.upload-${randomToken(9)}.part`);
      const { fields, files } = await parseMultipart(c.req, {
        maxTotalBytes: config.maxReleaseBytes + 1024 * 1024,
        onFile: (part, early) => {
          if (part.name !== 'file' || c.uploadStarted) return null;
          // The admin UI sends the text fields first, so a duplicate version fails before 500 MB goes over the wire.
          const v = str(early.version, 32);
          if (v && db.prepare('SELECT 1 FROM releases WHERE version = ?').get(v)) throw new HttpError(409, `版本 ${v} 已存在，请先删除旧记录`);
          c.uploadStarted = true;
          return { path: tmp, maxBytes: config.maxReleaseBytes, hash: crypto.createHash('sha256') };
        },
      });
      const discard = () => fs.rmSync(tmp, { force: true });
      try {
        const file = files[0];
        if (!file || file.size === 0) throw new HttpError(400, '请选择 DMG 文件');
        const version = str(fields.version, 32);
        const build = str(fields.build, 32);
        const minOS = str(fields.minOS, 10) || '14.0';
        const edSignature = str(fields.edSignature, 200) || null;
        if (!VERSION_RE.test(version)) throw new HttpError(400, '版本号格式不正确（例如 1.2.0）');
        if (!BUILD_RE.test(build)) throw new HttpError(400, 'Build 号格式不正确（例如 12）');
        if (!MINOS_RE.test(minOS)) throw new HttpError(400, '最低系统版本格式不正确（例如 14.0）');
        if (edSignature && !SIGNATURE_RE.test(edSignature)) throw new HttpError(400, 'edSignature 格式不正确（应为 base64）');
        if (!(await looksLikeDmg(file.path, file.size))) throw new HttpError(400, '文件不是有效的 DMG 磁盘映像');
        if (db.prepare('SELECT 1 FROM releases WHERE version = ?').get(version)) throw new HttpError(409, `版本 ${version} 已存在，请先删除旧记录`);

        const fileName = `MacClean-${version}.dmg`;
        await fs.promises.rename(file.path, path.join(dir, fileName));
        const makeLatest = ['1', 'true', 'on'].includes(String(fields.setLatest ?? 'true'));
        const release = transaction(db, () => {
          if (makeLatest) db.prepare('UPDATE releases SET is_latest = 0').run();
          const info = db.prepare(`INSERT INTO releases (version, build, min_os, notes, ed_signature, file_name, size, sha256, is_latest, published_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
            .run(version, build, minOS, str(fields.notes, 20000), edSignature, fileName, file.size, file.hash.digest('hex'),
              makeLatest ? 1 : 0, new Date().toISOString());
          return db.prepare('SELECT * FROM releases WHERE id = ?').get(info.lastInsertRowid);
        });
        log(c, 'release.upload', version, { build, size: file.size, latest: makeLatest });
        sendJson(c.res, 201, { release: adminRelease(release, config) });
      } finally {
        discard();
      }
    }, { auth: true, raw: true }],

    ['PATCH', '/api/admin/releases/:id', (c) => {
      const r = db.prepare('SELECT * FROM releases WHERE id = ?').get(Number(c.params.id));
      if (!r) throw new HttpError(404, '版本不存在');
      const b = c.body;
      const next = {
        notes: b.notes !== undefined ? str(b.notes, 20000) : r.notes,
        ed_signature: b.edSignature !== undefined ? (str(b.edSignature, 200) || null) : r.ed_signature,
        min_os: b.minOS !== undefined ? str(b.minOS, 10) : r.min_os,
        build: b.build !== undefined ? str(b.build, 32) : r.build,
      };
      if (next.ed_signature && !SIGNATURE_RE.test(next.ed_signature)) throw new HttpError(400, 'edSignature 格式不正确（应为 base64）');
      if (!MINOS_RE.test(next.min_os)) throw new HttpError(400, '最低系统版本格式不正确');
      if (!BUILD_RE.test(next.build)) throw new HttpError(400, 'Build 号格式不正确');
      db.prepare('UPDATE releases SET notes = ?, ed_signature = ?, min_os = ?, build = ? WHERE id = ?')
        .run(next.notes, next.ed_signature, next.min_os, next.build, r.id);
      log(c, 'release.update', r.version);
      return { release: adminRelease(db.prepare('SELECT * FROM releases WHERE id = ?').get(r.id), config) };
    }, auth],

    ['POST', '/api/admin/releases/:id/latest', (c) => {
      const r = db.prepare('SELECT * FROM releases WHERE id = ?').get(Number(c.params.id));
      if (!r) throw new HttpError(404, '版本不存在');
      transaction(db, () => {
        db.prepare('UPDATE releases SET is_latest = 0').run();
        db.prepare('UPDATE releases SET is_latest = 1 WHERE id = ?').run(r.id);
      });
      log(c, 'release.set_latest', r.version);
      return { ok: true };
    }, auth],

    ['DELETE', '/api/admin/releases/:id', (c) => {
      const r = db.prepare('SELECT * FROM releases WHERE id = ?').get(Number(c.params.id));
      if (!r) throw new HttpError(404, '版本不存在');
      db.prepare('DELETE FROM releases WHERE id = ?').run(r.id);
      fs.rmSync(path.join(config.filesDir, 'releases', r.file_name), { force: true });
      log(c, 'release.delete', r.version, { downloads: r.downloads });
      return { ok: true };
    }, auth],

    // MARK: Settings

    ['GET', '/api/admin/settings', () => settingsPayload(ctx), auth],

    ['PUT', '/api/admin/settings', (c) => {
      const b = c.body;
      const changed = [];
      if (b.plans !== undefined) {
        setSetting(db, 'plans', sanitizePlans(b.plans));
        changed.push('plans');
      }
      if (b.paymentInstructions !== undefined) {
        setSetting(db, 'payment_instructions', str(b.paymentInstructions, 2000));
        changed.push('paymentInstructions');
      }
      if (b.contactEmail !== undefined) {
        const email = str(b.contactEmail, 254);
        if (email && !isEmail(email)) throw new HttpError(400, '联系邮箱格式不正确');
        setSetting(db, 'contact_email', email);
        changed.push('contactEmail');
      }
      if (b.announcement !== undefined) {
        setSetting(db, 'announcement', str(b.announcement, 2000));
        changed.push('announcement');
      }
      log(c, 'settings.update', null, { changed });
      return settingsPayload(ctx);
    }, auth],

    ['POST', '/api/admin/settings/qr/:kind', async (c) => {
      const kind = c.params.kind;
      if (kind !== 'wechat' && kind !== 'alipay') throw new HttpError(404, 'Not found');
      await fs.promises.mkdir(config.filesDir, { recursive: true });
      const tmp = path.join(config.filesDir, `.qr-upload-${randomToken(9)}`);
      try {
        const { files } = await parseMultipart(c.req, {
          maxTotalBytes: config.maxQrBytes + 64 * 1024,
          onFile: (part) => (part.name === 'file' && !c.uploadStarted ? (c.uploadStarted = true, { path: tmp, maxBytes: config.maxQrBytes }) : null),
        });
        if (!files[0] || files[0].size === 0) throw new HttpError(400, '请选择图片');
        const head = Buffer.alloc(8);
        const fh = await fs.promises.open(tmp, 'r');
        try { await fh.read(head, 0, 8, 0); } finally { await fh.close(); }
        const ext = imageKind(head);
        if (!ext) throw new HttpError(400, '只支持 PNG 或 JPG 图片');
        const fileName = `qr-${kind}.${ext}`;
        for (const other of ['png', 'jpg']) if (other !== ext) fs.rmSync(path.join(config.filesDir, `qr-${kind}.${other}`), { force: true });
        await fs.promises.rename(tmp, path.join(config.filesDir, fileName));
        setSetting(db, `qr_${kind}`, { file: fileName, version: Date.now() });
        log(c, 'settings.qr_upload', kind, { size: files[0].size });
        return settingsPayload(ctx);
      } finally {
        fs.rmSync(tmp, { force: true });
      }
    }, { auth: true, raw: true }],

    ['DELETE', '/api/admin/settings/qr/:kind', (c) => {
      const kind = c.params.kind;
      if (kind !== 'wechat' && kind !== 'alipay') throw new HttpError(404, 'Not found');
      const entry = getSetting(db, `qr_${kind}`);
      if (entry?.file) fs.rmSync(path.join(config.filesDir, entry.file), { force: true });
      db.prepare('DELETE FROM settings WHERE key = ?').run(`qr_${kind}`);
      log(c, 'settings.qr_delete', kind);
      return settingsPayload(ctx);
    }, auth],

    // MARK: Audit

    ['GET', '/api/admin/audit', ({ query }) => {
      const size = Math.min(Math.max(Number(query.get('pageSize')) || 50, 1), 200);
      const page = Math.max(Number(query.get('page')) || 1, 1);
      const term = str(query.get('q'), 100);
      const where = term ? "WHERE action LIKE ? ESCAPE '\\' OR target LIKE ? ESCAPE '\\'" : '';
      const like = `%${term.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`;
      const params = term ? [like, like] : [];
      const total = db.prepare(`SELECT COUNT(*) AS n FROM audit_log ${where}`).get(...params).n;
      const items = db.prepare(`SELECT * FROM audit_log ${where} ORDER BY id DESC LIMIT ? OFFSET ?`).all(...params, size, (page - 1) * size)
        .map((row) => {
          let detail = null;
          try { detail = row.detail ? JSON.parse(row.detail) : null; } catch { detail = row.detail; }
          return { id: row.id, at: row.at, action: row.action, target: row.target, detail, ip: row.ip };
        });
      return { items, total, page, pageSize: size };
    }, auth],
  ];
}
