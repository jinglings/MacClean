// Local dev server: serves the static site and mocks the public API from web/SPEC.md.
// Not deployed. Usage:
//   node dev/mock-server.mjs            → http://localhost:8080
// Env switches:
//   PORT=8080
//   MOCK_RELEASE=none     latestRelease: null   (download page shows "coming soon")
//   MOCK_QR=none          no QR codes configured (both null)
//   MOCK_ANNOUNCE="…"     announcement banner text
//   MOCK_CONFIG=fail      /api/public/config returns 500 (site falls back to defaults)
//   MOCK_PAY_DELAY=15     seconds after "I've paid" before the order flips to paid (0 = never)
// Helpers:
//   POST /__mock/pay/:orderNo      mark an order paid now
//   POST /__mock/cancel/:orderNo   cancel an order
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname, normalize, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, randomInt } from 'node:crypto';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.PORT || 8080);
const PAY_DELAY = Number(process.env.MOCK_PAY_DELAY ?? 15);

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.webp': 'image/webp', '.jpg': 'image/jpeg', '.ico': 'image/x-icon', '.dmg': 'application/octet-stream',
};
const CSP = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'";

const plans = [
  { id: 'lifetime', name: '终身版', nameEn: 'Lifetime', price: 98, currency: 'CNY', devices: 2, features: ['全部功能，终身使用', '可激活 2 台 Mac', '30 天无理由退款'], featuresEn: ['Every feature, for life', 'Activate 2 Macs', '30-day refund, no questions asked'], highlight: true },
  { id: 'family', name: '家庭版', nameEn: 'Family', price: 168, currency: 'CNY', devices: 5, features: ['全部功能，终身使用', '可激活 5 台 Mac', '适合家庭共享', '30 天无理由退款'], featuresEn: ['Every feature, for life', 'Activate 5 Macs', 'Share with your household', '30-day refund, no questions asked'], highlight: false },
];
const config = () => ({
  plans,
  payment: process.env.MOCK_QR === 'none'
    ? { wechatQr: null, alipayQr: null, instructions: '' }
    : { wechatQr: '/files/qr-wechat.svg?v=1727770000', alipayQr: null, instructions: '请使用扫码付款，金额与订单一致。' },
  contactEmail: 'wjw599330@gmail.com',
  announcement: process.env.MOCK_ANNOUNCE || null,
  latestRelease: process.env.MOCK_RELEASE === 'none' ? null : {
    version: '1.2', build: '30', minOS: '14.0', size: 14_623_418,
    notes: '## 新增：安全中心\n- 检查 macOS 自带防护是否开启：FileVault、防火墙、SIP、Gatekeeper、XProtect 数据是否最新等\n- 查看哪些应用拿到了摄像头、麦克风、屏幕录制等权限\n- 标出签名有问题或来路不明的后台程序（只读，不改动）\n\n## 重复与相似\n- 新增「完全相同的文件」：任意类型，内容逐字节相同；每组始终保留一份\n- 「相似照片」保持不变',
    publishedAt: '2026-09-28T08:00:00Z', downloadUrl: '/download/latest',
  },
});

const orders = new Map();
const hits = new Map();
const ALPHA = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const code = n => Array.from({ length: n }, () => ALPHA[randomInt(ALPHA.length)]).join('');

function publicOrder(o) {
  const p = plans.find(x => x.id === o.plan);
  return { orderNo: o.orderNo, plan: o.plan, planName: p.name, amount: o.amount, payMethod: o.payMethod, payCode: o.payCode,
    status: o.status, createdAt: o.createdAt, paidAt: o.paidAt, licenseKey: o.status === 'paid' ? o.licenseKey : null, devices: p.devices };
}
function pay(o) {
  if (o.status !== 'pending') return;
  o.status = 'paid';
  o.paidAt = new Date().toISOString();
  o.licenseKey = `MCLN-${code(4)}-${code(4)}-${code(4)}-${code(4)}`;
  console.log(`  paid ${o.orderNo} → ${o.licenseKey}`);
}

const send = (res, status, body, headers = {}) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
  res.end(JSON.stringify(body));
};
const readBody = req => new Promise(resolve => {
  let s = '';
  req.on('data', c => { s += c; });
  req.on('end', () => { try { resolve(JSON.parse(s || '{}')); } catch { resolve(null); } });
});
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function apiRoute(req, res, url) {
  await sleep(250 + Math.random() * 300);
  const path = url.pathname;

  if (req.method === 'GET' && path === '/api/public/config') {
    if (process.env.MOCK_CONFIG === 'fail') return send(res, 500, { error: 'internal error' });
    return send(res, 200, config());
  }

  if (req.method === 'POST' && path === '/api/orders') {
    const ip = req.socket.remoteAddress;
    const recent = (hits.get(ip) || []).filter(t => Date.now() - t < 3600_000);
    if (recent.length >= 5) return send(res, 429, { error: 'too many orders, try again later' }, { 'Retry-After': '3600' });
    const b = await readBody(req);
    if (!b) return send(res, 400, { error: 'invalid JSON' });
    if (!plans.some(p => p.id === b.plan)) return send(res, 400, { error: 'unknown plan', code: 'invalid_plan' });
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(b.email || '')) return send(res, 400, { error: 'invalid email', code: 'invalid_email' });
    if (!['wechat', 'alipay'].includes(b.payMethod)) return send(res, 400, { error: 'invalid payMethod', code: 'invalid_pay_method' });
    recent.push(Date.now());
    hits.set(ip, recent);
    const d = new Date();
    const o = {
      orderNo: `MC${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}-${code(4)}`,
      plan: b.plan, email: b.email.toLowerCase(), payMethod: b.payMethod, payCode: code(4),
      amount: plans.find(p => p.id === b.plan).price, status: 'pending', createdAt: d.toISOString(), paidAt: null,
      token: randomBytes(18).toString('base64url').slice(0, 24),
    };
    orders.set(o.orderNo, o);
    console.log(`  order ${o.orderNo} (${o.plan}, ${o.payMethod}) code ${o.payCode}`);
    return send(res, 201, { orderNo: o.orderNo, plan: o.plan, planName: plans.find(p => p.id === o.plan).name, createdAt: o.createdAt, amount: o.amount, payMethod: o.payMethod, payCode: o.payCode, status: o.status, accessToken: o.token });
  }

  let m = path.match(/^\/api\/orders\/([^/]+)$/);
  if (req.method === 'GET' && m) {
    const o = orders.get(decodeURIComponent(m[1]));
    const token = url.searchParams.get('token'), email = url.searchParams.get('email');
    if (!o || !((token && token === o.token) || (email && email.toLowerCase() === o.email))) return send(res, 404, { error: 'not found' });
    return send(res, 200, publicOrder(o));
  }

  m = path.match(/^\/api\/orders\/([^/]+)\/notify$/);
  if (req.method === 'POST' && m) {
    const o = orders.get(decodeURIComponent(m[1]));
    const b = await readBody(req);
    if (!o || !b || b.token !== o.token) return send(res, 404, { error: 'not found' });
    o.buyerNotifiedAt = new Date().toISOString();
    if (PAY_DELAY > 0) setTimeout(() => pay(o), PAY_DELAY * 1000);
    return send(res, 200, { ok: true });
  }

  return send(res, 404, { error: 'not found' });
}

const QR_SVG = (() => {
  // A fake, deterministic QR-looking pattern. Not scannable.
  let cells = '';
  for (let y = 0; y < 25; y++) for (let x = 0; x < 25; x++) {
    const finder = (x < 7 && y < 7) || (x > 17 && y < 7) || (x < 7 && y > 17);
    const on = finder ? (x % 6 === 0 || y % 6 === 0 || (x % 18 > 1 && x % 18 < 5 && y % 18 > 1 && y % 18 < 5)) : ((x * 7 + y * 13 + x * y) % 3 === 0);
    if (on) cells += `<rect x="${x}" y="${y}" width="1" height="1"/>`;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 29 29" shape-rendering="crispEdges"><rect x="-2" y="-2" width="29" height="29" fill="#fff"/><g fill="#111">${cells}</g></svg>`;
})();

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const path = url.pathname;
  console.log(req.method, path + url.search);

  if (path.startsWith('/api/')) return apiRoute(req, res, url);

  let m = path.match(/^\/__mock\/(pay|cancel)\/([^/]+)$/);
  if (req.method === 'POST' && m) {
    const o = orders.get(decodeURIComponent(m[2]));
    if (!o) return send(res, 404, { error: 'not found' });
    if (m[1] === 'pay') pay(o); else o.status = 'cancelled';
    return send(res, 200, publicOrder(o));
  }
  if (path === '/download/latest') {
    if (process.env.MOCK_RELEASE === 'none') return send(res, 404, { error: 'no release' });
    res.writeHead(302, { Location: '/files/releases/MacClean-1.2.dmg' });
    return res.end();
  }
  if (path === '/files/releases/MacClean-1.2.dmg') {
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="MacClean-1.2.dmg"' });
    return res.end('fake dmg for local testing\n');
  }
  if (path === '/files/qr-wechat.svg') {
    res.writeHead(200, { 'Content-Type': 'image/svg+xml' });
    return res.end(QR_SVG);
  }

  // static files
  let file = normalize(join(root, decodeURIComponent(path)));
  if (!file.startsWith(root) || file.includes('/dev/')) file = join(root, '404.html');
  try {
    if ((await stat(file)).isDirectory()) file = join(file, 'index.html');
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream', 'Content-Security-Policy': CSP, 'Cache-Control': 'no-cache' });
    res.end(body);
  } catch {
    res.writeHead(404, { 'Content-Type': TYPES['.html'], 'Content-Security-Policy': CSP });
    res.end(await readFile(join(root, '404.html')));
  }
}).listen(PORT, () => console.log(`MacClean site + mock API on http://localhost:${PORT}`));
