import path from 'node:path';
import { buildAppcast } from '../appcast.js';
import { HttpError, enforceLimit, redirect, sendJson, sendText } from '../http.js';
import { safeJoin, serveFile } from '../static.js';
import {
  createOrder, latestRelease, notifyPaid, orderForBuyer, publicConfig, publicOrder, recordDownload,
} from '../store.js';

export function publicRoutes({ db, config, limiters }) {
  return [
    ['GET', '/api/health', () => ({ ok: true })],

    ['GET', '/api/public/config', ({ res }) => {
      // Short shared cache: Cloudflare/browsers can hold it briefly, edits show up within a minute.
      sendJson(res, 200, publicConfig(db), { 'Cache-Control': 'public, max-age=60' });
    }],

    ['POST', '/api/orders', ({ res, body, ip }) => {
      enforceLimit(limiters.orders, ip);
      const order = createOrder(db, config, {
        plan: body.plan, email: body.email, payMethod: body.payMethod, note: body.note, ip,
      });
      sendJson(res, 201, order);
    }],

    ['GET', '/api/orders/:orderNo', ({ params, query, ip }) => {
      enforceLimit(limiters.orderLookup, ip);
      const order = orderForBuyer(db, params.orderNo, { token: query.get('token'), email: query.get('email') });
      return publicOrder(order);
    }],

    ['POST', '/api/orders/:orderNo/notify', ({ params, body, query, ip }) => {
      enforceLimit(limiters.notify, ip);
      return publicOrder(notifyPaid(db, params.orderNo, body.token ?? query.get('token')));
    }],

    ['GET', '/download/latest', ({ res, ip }) => {
      const release = latestRelease(db);
      if (!release) throw new HttpError(404, 'No release has been published yet');
      recordDownload(db, config, release, ip);
      redirect(res, `/files/releases/${encodeURIComponent(release.file_name)}`, 302);
    }],

    ['GET', '/appcast.xml', ({ res }) => {
      const latest = latestRelease(db);
      // If an older build is marked latest (rollback), don't advertise anything newer than it.
      const releases = latest
        ? db.prepare('SELECT * FROM releases WHERE published_at <= ? ORDER BY published_at DESC, id DESC').all(latest.published_at)
        : [];
      const xml = buildAppcast(releases, { publicBaseUrl: config.publicBaseUrl });
      sendText(res, 200, xml, { 'Content-Type': 'application/xml; charset=utf-8', 'Cache-Control': 'public, max-age=300' });
    }],

    ['GET', '/files/*', async ({ req, res, params }) => {
      const file = safeJoin(config.filesDir, params.wild);
      if (!file) throw new HttpError(404, 'Not found');
      const isRelease = file.startsWith(path.join(config.filesDir, 'releases') + path.sep);
      const served = await serveFile(req, res, file, {
        cacheControl: isRelease ? 'public, max-age=86400' : 'public, max-age=300',
        headers: isRelease ? { 'Content-Disposition': `attachment; filename="${path.basename(file)}"` } : {},
      });
      if (!served) throw new HttpError(404, 'Not found');
    }],
  ];
}
