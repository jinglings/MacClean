import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { buildAppcast, cdata, notesToHtml } from '../src/appcast.js';
import { backupIfDue } from '../src/db.js';
import { MultipartTokenizer, boundaryFrom } from '../src/multipart.js';
import { parseRange } from '../src/static.js';
import { adminLogin, fakeDmg, startServer } from './helpers.js';

function multipartBody(boundary, fields, file) {
  const parts = [];
  for (const [name, value] of Object.entries(fields)) {
    parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`));
  }
  if (file) {
    parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${file.field || 'file'}"; filename="${file.name}"\r\nContent-Type: ${file.type || 'application/octet-stream'}\r\n\r\n`));
    parts.push(file.data, Buffer.from('\r\n'));
  }
  parts.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(parts);
}

function tokenize(body, boundary, chunkSize) {
  const t = new MultipartTokenizer(boundary);
  const parts = [];
  for (let i = 0; i < body.length; i += chunkSize) {
    for (const e of t.push(body.subarray(i, i + chunkSize))) {
      if (e.type === 'part') parts.push({ ...e.part, data: [] });
      else if (e.type === 'data') parts.at(-1).data.push(Buffer.from(e.data));
    }
  }
  t.end();
  return parts.map((p) => ({ name: p.name, filename: p.filename, data: Buffer.concat(p.data) }));
}

describe('multipart tokenizer', () => {
  const boundary = '----WebKitFormBoundaryAbC123';
  // Payload deliberately contains near-miss boundaries and CRLFs.
  const payload = Buffer.concat([
    Buffer.from(`\r\n--${boundary.slice(0, -1)}X\r\n--`), Buffer.alloc(3000, 0xaa), Buffer.from(`\r\n-${boundary}`), Buffer.from('end'),
  ]);
  const body = multipartBody(boundary, { version: '1.2.0', notes: '第一行\r\n第二行' }, { name: 'MacClean.dmg', data: payload });

  for (const size of [1, 2, 7, 64, 1000, body.length]) {
    test(`chunk size ${size} (boundary split across chunks)`, () => {
      const parts = tokenize(body, boundary, size);
      assert.equal(parts.length, 3);
      assert.deepEqual(parts.map((p) => p.name), ['version', 'notes', 'file']);
      assert.equal(parts[0].data.toString(), '1.2.0');
      assert.equal(parts[1].data.toString(), '第一行\r\n第二行');
      assert.equal(parts[2].filename, 'MacClean.dmg');
      assert.ok(parts[2].data.equals(payload));
    });
  }

  test('truncated body is an error', () => {
    const t = new MultipartTokenizer(boundary);
    t.push(body.subarray(0, body.length - 10));
    assert.throws(() => t.end(), /Unexpected end/);
  });

  test('boundary extraction', () => {
    assert.equal(boundaryFrom('multipart/form-data; boundary=abc'), 'abc');
    assert.equal(boundaryFrom('multipart/form-data; charset=utf-8; boundary="a b"'), 'a b');
    assert.equal(boundaryFrom('application/json'), null);
  });
});

test('parseRange', () => {
  assert.deepEqual(parseRange('bytes=0-99', 1000), { start: 0, end: 99 });
  assert.deepEqual(parseRange('bytes=900-', 1000), { start: 900, end: 999 });
  assert.deepEqual(parseRange('bytes=-100', 1000), { start: 900, end: 999 });
  assert.deepEqual(parseRange('bytes=990-5000', 1000), { start: 990, end: 999 });
  assert.equal(parseRange('bytes=1000-', 1000), 'unsatisfiable');
  assert.equal(parseRange('bytes=0-1,5-6', 1000), null);
  assert.equal(parseRange('items=0-1', 1000), null);
  assert.equal(parseRange(undefined, 1000), null);
});

test('appcast XML follows the Sparkle 2 format and escapes', () => {
  const xml = buildAppcast([
    { version: '1.1', build: '11', min_os: '14.0', notes: '# 新功能\n- 修复 <bug> & 崩溃\n- **加速** 扫描\n\n结尾 ]]> 段落', ed_signature: 'abc+/=sig==',
      file_name: 'MacClean-1.1.dmg', size: 123456, published_at: '2026-10-01T08:00:00.000Z' },
    { version: '1.0', build: '10', min_os: '14.0', notes: '', ed_signature: null, file_name: 'MacClean-1.0.dmg', size: 1, published_at: '2026-09-01T08:00:00.000Z' },
  ], { publicBaseUrl: 'https://thulem.com' });
  assert.match(xml, /^<\?xml version="1.0" encoding="utf-8"\?>/);
  assert.match(xml, /xmlns:sparkle="http:\/\/www\.andymatuschak\.org\/xml-namespaces\/sparkle"/);
  assert.equal((xml.match(/<item>/g) || []).length, 1, 'unsigned releases are skipped');
  assert.match(xml, /<title>Version 1\.1<\/title>/);
  assert.match(xml, /<pubDate>Thu, 01 Oct 2026 08:00:00 \+0000<\/pubDate>/);
  assert.match(xml, /<sparkle:version>11<\/sparkle:version>/);
  assert.match(xml, /<sparkle:shortVersionString>1\.1<\/sparkle:shortVersionString>/);
  assert.match(xml, /<sparkle:minimumSystemVersion>14\.0<\/sparkle:minimumSystemVersion>/);
  assert.match(xml, /<enclosure url="https:\/\/thulem\.com\/files\/releases\/MacClean-1\.1\.dmg" length="123456" type="application\/octet-stream" sparkle:edSignature="abc\+\/=sig=="\/>/);
  assert.match(xml, /<description><!\[CDATA\[<h3>新功能<\/h3>/);
  assert.match(xml, /<li>修复 &lt;bug&gt; &amp; 崩溃<\/li>/);
  assert.match(xml, /<strong>加速<\/strong>/);
  assert.ok(!xml.includes('结尾 ]]> 段落'));
  assert.equal(cdata('a]]>b'), '<![CDATA[a]]]]><![CDATA[>b]]>');
  assert.equal(notesToHtml('<script>'), '<p>&lt;script&gt;</p>');
});

describe('releases, downloads, files', () => {
  let srv;
  let headers;
  before(async () => {
    srv = await startServer();
    headers = await adminLogin(srv);
  });
  after(() => srv.close());

  const upload = (fields, file) => {
    const boundary = `----mc${Math.random().toString(16).slice(2)}`;
    return srv.fetch('/api/admin/releases', {
      method: 'POST',
      headers: { ...headers, 'content-type': `multipart/form-data; boundary=${boundary}` },
      body: multipartBody(boundary, fields, file),
    });
  };

  test('upload a release, download/latest, Range, appcast', async () => {
    const dmg = fakeDmg(3 * 1024 * 1024 + 17);
    const res = await upload({ version: '1.0.0', build: '100', minOS: '14.0', notes: '- 首个版本', edSignature: 'Zm9vYmFyYmF6cXV4cXV1eA==' },
      { name: 'whatever.dmg', data: dmg });
    assert.equal(res.status, 201, await res.clone().text());
    const { release } = await res.json();
    assert.equal(release.size, dmg.length);
    assert.equal(release.fileName, 'MacClean-1.0.0.dmg');
    assert.equal(release.isLatest, true);
    assert.equal(fs.readdirSync(path.join(srv.dataDir, 'files', 'releases')).join(','), 'MacClean-1.0.0.dmg');

    const dup = await upload({ version: '1.0.0', build: '101' }, { name: 'x.dmg', data: dmg });
    assert.equal(dup.status, 409);
    const notDmg = await upload({ version: '1.0.1', build: '101' }, { name: 'x.dmg', data: Buffer.alloc(4096) });
    assert.equal(notDmg.status, 400);
    assert.equal(fs.readdirSync(path.join(srv.dataDir, 'files', 'releases')).length, 1, 'rejected uploads leave no files');

    const cfg = await (await srv.fetch('/api/public/config')).json();
    assert.equal(cfg.latestRelease.version, '1.0.0');
    assert.equal(cfg.latestRelease.size, dmg.length);
    assert.equal(cfg.latestRelease.downloadUrl, '/download/latest');

    const ipA = { 'cf-connecting-ip': '203.0.113.50' };
    const r1 = await srv.fetch('/download/latest', { headers: ipA });
    assert.equal(r1.status, 302);
    assert.equal(r1.headers.get('location'), '/files/releases/MacClean-1.0.0.dmg');
    await srv.fetch('/download/latest', { headers: ipA });
    await srv.fetch('/download/latest', { headers: { 'cf-connecting-ip': '203.0.113.51' } });
    const daily = srv.app.db.prepare('SELECT * FROM downloads_daily').get();
    assert.equal(daily.count, 3);
    assert.equal(daily.unique_count, 2);

    const full = await srv.fetch('/files/releases/MacClean-1.0.0.dmg');
    assert.equal(full.status, 200);
    assert.equal(full.headers.get('content-type'), 'application/x-apple-diskimage');
    assert.equal(Number(full.headers.get('content-length')), dmg.length);
    assert.equal(full.headers.get('accept-ranges'), 'bytes');
    assert.ok(Buffer.from(await full.arrayBuffer()).equals(dmg));

    const part = await srv.fetch('/files/releases/MacClean-1.0.0.dmg', { headers: { range: 'bytes=100-199' } });
    assert.equal(part.status, 206);
    assert.equal(part.headers.get('content-range'), `bytes 100-199/${dmg.length}`);
    assert.ok(Buffer.from(await part.arrayBuffer()).equals(dmg.subarray(100, 200)));

    const tail = await srv.fetch('/files/releases/MacClean-1.0.0.dmg', { headers: { range: 'bytes=-512' } });
    assert.equal(tail.status, 206);
    assert.equal(Buffer.from(await tail.arrayBuffer()).subarray(0, 4).toString(), 'koly');

    const bad = await srv.fetch('/files/releases/MacClean-1.0.0.dmg', { headers: { range: `bytes=${dmg.length}-` } });
    assert.equal(bad.status, 416);
    assert.equal(bad.headers.get('content-range'), `bytes */${dmg.length}`);

    const head = await srv.fetch('/files/releases/MacClean-1.0.0.dmg', { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(Number(head.headers.get('content-length')), dmg.length);

    const etag = full.headers.get('etag');
    assert.equal((await srv.fetch('/files/releases/MacClean-1.0.0.dmg', { headers: { 'if-none-match': etag } })).status, 304);

    for (const p of ['/files/../macclean.db', '/files/%2e%2e/macclean.db', '/files/releases/.upload-x.part', '/files/nope.png']) {
      assert.equal((await srv.fetch(p)).status, 404, p);
    }

    const appcast = await srv.fetch('/appcast.xml');
    assert.match(appcast.headers.get('content-type'), /application\/xml/);
    const xml = await appcast.text();
    assert.match(xml, /<sparkle:version>100<\/sparkle:version>/);
    assert.match(xml, new RegExp(`length="${dmg.length}"`));
    assert.match(xml, /url="https:\/\/thulem\.com\/files\/releases\/MacClean-1\.0\.0\.dmg"/);

    const list = await (await srv.fetch('/api/admin/releases', { headers })).json();
    assert.equal(list.items[0].downloads, 3);
    assert.equal(list.appcastUrl, 'https://thulem.com/appcast.xml');

    const del = await srv.fetch(`/api/admin/releases/${release.id}`, { method: 'DELETE', headers });
    assert.equal(del.status, 200);
    assert.equal((await srv.fetch('/download/latest')).status, 404);
    assert.equal((await srv.fetch('/files/releases/MacClean-1.0.0.dmg')).status, 404);
  });

  test('upload without auth or CSRF is refused before reading the body', async () => {
    const res = await srv.fetch('/api/admin/releases', {
      method: 'POST', headers: { cookie: headers.cookie, 'content-type': 'multipart/form-data; boundary=x' }, body: '--x--\r\n',
    });
    assert.equal(res.status, 403);
  });

  test('QR upload validates magic bytes and size', async () => {
    const send = (kind, data) => {
      const boundary = 'qrboundary';
      return srv.fetch(`/api/admin/settings/qr/${kind}`, {
        method: 'POST',
        headers: { ...headers, 'content-type': `multipart/form-data; boundary=${boundary}` },
        body: multipartBody(boundary, {}, { name: 'qr.png', type: 'image/png', data }),
      });
    };
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(100)]);
    const ok = await send('wechat', png);
    assert.equal(ok.status, 200);
    const settings = await ok.json();
    assert.match(settings.wechatQr, /^\/files\/qr-wechat\.png\?v=\d+$/);
    const img = await srv.fetch(settings.wechatQr);
    assert.equal(img.status, 200);
    assert.equal(img.headers.get('content-type'), 'image/png');

    const jpg = await send('alipay', Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(50)]));
    assert.match((await jpg.json()).alipayQr, /qr-alipay\.jpg/);

    assert.equal((await send('wechat', Buffer.from('<svg onload=alert(1)>'))).status, 400);
    assert.equal((await send('wechat', Buffer.concat([png, Buffer.alloc(2 * 1024 * 1024)]))).status, 413);
    assert.equal((await send('paypal', png)).status, 404);

    const cfg = await (await srv.fetch('/api/public/config')).json();
    assert.match(cfg.payment.wechatQr, /qr-wechat\.png/);
    assert.match(cfg.payment.alipayQr, /qr-alipay\.jpg/);
  });
});

test('backups: one per day, newest 14 kept', async () => {
  const srv = await startServer();
  try {
    const dir = srv.config.backupsDir;
    for (let d = 1; d <= 20; d++) fs.writeFileSync(path.join(dir, `macclean-2026-01-${String(d).padStart(2, '0')}.db`), '');
    const written = backupIfDue(srv.app.db, dir, '2026-02-01', 14);
    assert.ok(written && fs.statSync(written).size > 0);
    assert.equal(backupIfDue(srv.app.db, dir, '2026-02-01', 14), null);
    const files = fs.readdirSync(dir).sort();
    assert.equal(files.length, 14);
    assert.equal(files.at(-1), 'macclean-2026-02-01.db');
    assert.equal(files[0], 'macclean-2026-01-08.db');
  } finally {
    await srv.close();
  }
});

test('migrations record schema_version and are idempotent', async () => {
  const { openDatabase, schemaVersion } = await import('../src/db.js');
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR || '/tmp', 'mc-db-'));
  try {
    const file = path.join(dir, 'x.db');
    const db1 = openDatabase(file);
    const v = schemaVersion(db1);
    assert.ok(v >= 1);
    assert.equal(db1.prepare('PRAGMA journal_mode').get().journal_mode, 'wal');
    db1.close();
    const db2 = openDatabase(file);
    assert.equal(schemaVersion(db2), v);
    db2.close();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
