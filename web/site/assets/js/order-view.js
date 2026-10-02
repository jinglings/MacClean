// Renders an order (pending / paid / cancelled) for buy.html and order.html,
// and keeps it fresh by polling GET /api/orders/:no every 10 s.
import { api, errorMessage } from './api.js?v=20261002.1';
import { t, getLang } from './i18n.js?v=20261002.1';
import { getConfig, money, formatDate, escapeHTML, copyText, planName } from './common.js?v=20261002.1';

const STORE = 'mc.orders';
const POLL_MS = 10000;
const icon = id => `<svg class="i" aria-hidden="true"><use href="/assets/img/icons.svg#${id}"/></svg>`;

/* ---------- saved orders (localStorage) ---------- */

export function savedOrders() {
  try {
    const list = JSON.parse(localStorage.getItem(STORE) || '[]');
    return Array.isArray(list) ? list.filter(o => o && o.orderNo && o.token) : [];
  } catch { return []; }
}

export function saveOrder(entry) {
  const list = savedOrders().filter(o => o.orderNo !== entry.orderNo);
  const prev = savedOrders().find(o => o.orderNo === entry.orderNo) || {};
  list.unshift({ ...prev, ...entry });
  try { localStorage.setItem(STORE, JSON.stringify(list.slice(0, 10))); } catch { /* storage blocked */ }
}

export function orderLink(no, token) {
  return `${location.origin}/order.html?no=${encodeURIComponent(no)}&token=${encodeURIComponent(token)}`;
}

export function renderSavedOrders(box) {
  const list = savedOrders();
  if (!list.length) { box.hidden = true; return; }
  box.hidden = false;
  box.querySelector('.my-orders').innerHTML = list.map(o => `
    <a href="/order.html?no=${encodeURIComponent(o.orderNo)}&token=${encodeURIComponent(o.token)}">
      <span><b>${escapeHTML(o.orderNo)}</b>${o.amount ? ` · ${escapeHTML(money(o.amount))}` : ''}</span>
      <span class="muted">${escapeHTML(o.status === 'paid' ? t('order.st.paid') : o.createdAt ? formatDate(o.createdAt) : '')} ${icon('chev')}</span>
    </a>`).join('');
}

/* ---------- fetching ---------- */

export function fetchOrder(no, { token, email }) {
  const q = token ? `token=${encodeURIComponent(token)}` : `email=${encodeURIComponent(email)}`;
  return api(`/api/orders/${encodeURIComponent(no)}?${q}`);
}

/* ---------- rendering ---------- */

function statusPill(status) {
  return `<span class="status ${escapeHTML(status)}">${escapeHTML(t('order.st.' + status))}</span>`;
}

function displayPlan(order, cfg) {
  const p = cfg.plans.find(x => x.id === order.plan);
  if (p) return planName(p);
  return order.planName || order.plan || '';
}

function payMethodName(m) { return t(m === 'alipay' ? 'buy.alipay' : 'buy.wechat'); }

function pendingHTML(o, cfg, { token, notified }) {
  const qr = o.payMethod === 'alipay' ? cfg.payment.alipayQr : cfg.payment.wechatQr;
  const link = token ? orderLink(o.orderNo, token) : '';
  return `
  <div class="order-grid">
    <div class="panel">
      <div style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
        <h2>${escapeHTML(t('order.no', { no: o.orderNo }))}</h2>${statusPill(o.status)}
      </div>
      <p class="muted small" style="margin-top:6px">${escapeHTML(displayPlan(o, cfg))} · ${escapeHTML(t('price.devices', { n: o.devices ?? '' }))} · ${escapeHTML(payMethodName(o.payMethod))}</p>
      <div style="margin-top:22px">
        <div class="muted small">${escapeHTML(t('order.payExact'))}</div>
        <div class="amount-big">${escapeHTML(money(o.amount))}</div>
      </div>
      <div class="paycode">
        <div class="muted small">${escapeHTML(t('order.codeLabel'))}</div>
        <div class="code" aria-label="${escapeHTML(o.payCode.split('').join(' '))}">${escapeHTML(o.payCode)}</div>
        <p>${t('order.codeNote', { code: `<b>${escapeHTML(o.payCode)}</b>` })}</p>
      </div>
      <div class="form-actions">
        ${token ? `<button class="btn btn-primary" type="button" data-act="notify" ${notified ? 'disabled' : ''}>${icon('check')}<span>${escapeHTML(t(notified ? 'order.notified' : 'order.notify'))}</span></button>` : ''}
        <button class="btn btn-ghost" type="button" data-act="refresh">${icon('refresh')}<span>${escapeHTML(t('order.refresh'))}</span></button>
      </div>
      <div data-slot="msg"></div>
      <p class="hint" style="margin-top:14px">${escapeHTML(t('order.polling'))}</p>
      ${link ? `<div class="bookmark">${escapeHTML(t('order.bookmark'))}<br><a href="${escapeHTML(link)}">${escapeHTML(link)}</a> <button class="btn btn-ghost btn-sm" type="button" data-act="copy-link" style="margin-left:4px">${icon('copy')}<span>${escapeHTML(t('common.copy'))}</span></button></div>` : ''}
    </div>
    <div class="panel" style="text-align:center">
      <h2>${escapeHTML(t(o.payMethod === 'alipay' ? 'order.scanAlipay' : 'order.scanWechat'))}</h2>
      <div style="margin-top:20px">
        ${qr
          ? `<div class="qr"><img src="${escapeHTML(qr)}" width="256" height="256" alt="${escapeHTML(t('order.qrAlt', { m: payMethodName(o.payMethod) }))}"></div>`
          : `<div class="qr qr-missing">${t('order.qrMissing', { email: `<a class="link" href="mailto:${escapeHTML(cfg.contactEmail)}">${escapeHTML(cfg.contactEmail)}</a>` })}</div>`}
      </div>
      ${cfg.payment.instructions ? `<p class="pay-instr">${escapeHTML(cfg.payment.instructions)}</p>` : ''}
      <p class="pay-instr">${t('order.steps', { amount: `<b>${escapeHTML(money(o.amount))}</b>`, code: `<b>${escapeHTML(o.payCode)}</b>` })}</p>
    </div>
  </div>`;
}

function paidHTML(o, cfg) {
  return `
  <div class="panel paid-burst">
    <div class="ok-ring">${icon('check')}</div>
    <h2 style="font-size:28px">${escapeHTML(t('order.paidH'))}</h2>
    <p class="muted" style="margin-top:8px">${escapeHTML(t('order.paidP', { plan: displayPlan(o, cfg), n: o.devices ?? '' }))}</p>
    <div class="license" style="max-width:640px;margin-left:auto;margin-right:auto;text-align:left">
      <code id="license-key">${escapeHTML(o.licenseKey || '')}</code>
      <button class="btn btn-primary btn-sm" type="button" data-act="copy-key">${icon('copy')}<span>${escapeHTML(t('order.copyKey'))}</span></button>
    </div>
    <ol class="howto" style="max-width:520px;margin:26px auto 0;text-align:left">
      <li>${escapeHTML(t('order.how1'))}</li>
      <li>${escapeHTML(t('order.how2'))}</li>
      <li>${escapeHTML(t('order.how3'))}</li>
      <li>${escapeHTML(t('order.how4'))}</li>
    </ol>
    <ul class="summary-list" style="max-width:520px;margin:28px auto 0;text-align:left">
      <li><span>${escapeHTML(t('order.noLabel'))}</span><span>${escapeHTML(o.orderNo)}</span></li>
      <li><span>${escapeHTML(t('buy.planLabel'))}</span><span>${escapeHTML(displayPlan(o, cfg))}</span></li>
      <li><span>${escapeHTML(t('order.amount'))}</span><span>${escapeHTML(money(o.amount))}</span></li>
      ${o.paidAt ? `<li><span>${escapeHTML(t('order.paidAt'))}</span><span>${escapeHTML(formatDate(o.paidAt))}</span></li>` : ''}
    </ul>
    <p class="hint" style="margin-top:20px">${escapeHTML(t('order.keepKey'))}</p>
    <div class="form-actions" style="justify-content:center"><a class="btn btn-ghost" href="/download.html">${icon('download')}<span>${escapeHTML(t('cta.download'))}</span></a></div>
  </div>`;
}

function cancelledHTML(o, cfg) {
  return `
  <div class="panel" style="text-align:center">
    ${statusPill('cancelled')}
    <h2 style="margin-top:16px">${escapeHTML(t('order.cancelledH', { no: o.orderNo }))}</h2>
    <p class="muted" style="margin-top:10px">${t('order.cancelledP', { email: `<a class="link" href="mailto:${escapeHTML(cfg.contactEmail)}">${escapeHTML(cfg.contactEmail)}</a>` })}</p>
    <div class="form-actions" style="justify-content:center"><a class="btn btn-primary" href="/buy.html">${escapeHTML(t('order.newOrder'))}</a></div>
  </div>`;
}

/* ---------- controller ---------- */

// Mounts an order view in `box` and keeps it updated. Returns { stop }.
export function mountOrder(box, order, { token, email } = {}) {
  let current = order;
  let timer = 0, stopped = false;

  async function draw() {
    const cfg = await getConfig();
    const saved = savedOrders().find(o => o.orderNo === current.orderNo);
    if (token) saveOrder({ orderNo: current.orderNo, token, amount: current.amount, status: current.status, createdAt: current.createdAt || saved?.createdAt || new Date().toISOString() });
    box.innerHTML =
      current.status === 'paid' ? paidHTML(current, cfg) :
      current.status === 'cancelled' ? cancelledHTML(current, cfg) :
      pendingHTML(current, cfg, { token, notified: !!saved?.notified });
    box.dataset.lang = getLang();
  }

  function message(kind, text) {
    const slot = box.querySelector('[data-slot="msg"]');
    if (slot) slot.innerHTML = text ? `<div class="alert ${kind}" role="alert">${icon(kind === 'err' ? 'alert' : 'check')}<span>${escapeHTML(text)}</span></div>` : '';
  }

  async function refresh(manual = false) {
    try {
      const next = await fetchOrder(current.orderNo, { token, email });
      const changed = next.status !== current.status || next.licenseKey !== current.licenseKey;
      current = next;
      if (changed) { await draw(); if (current.status === 'paid') box.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
      else if (manual) message('info', t('order.stillPending'));
    } catch (err) {
      if (manual) message('err', errorMessage(err, 'err.orderNotFound'));
    }
    schedule();
  }

  function schedule() {
    clearTimeout(timer);
    if (stopped || current.status !== 'pending') return;
    timer = setTimeout(() => { document.hidden ? schedule() : refresh(); }, POLL_MS);
  }

  box.addEventListener('click', async e => {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const act = btn.dataset.act;
    if (act === 'copy-key') copyText(current.licenseKey || '');
    if (act === 'copy-link') copyText(orderLink(current.orderNo, token));
    if (act === 'refresh') { btn.classList.add('loading'); await refresh(true); btn.classList.remove('loading'); }
    if (act === 'notify') {
      btn.classList.add('loading');
      try {
        await api(`/api/orders/${encodeURIComponent(current.orderNo)}/notify`, { method: 'POST', body: { token } });
        saveOrder({ orderNo: current.orderNo, token, notified: true });
        btn.disabled = true;
        btn.querySelector('span').textContent = t('order.notified');
        message('info', t('order.notifiedMsg'));
      } catch (err) {
        message('err', errorMessage(err, 'err.orderNotFound'));
      }
      btn.classList.remove('loading');
    }
  });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && current.status === 'pending') refresh(); });

  draw();
  schedule();
  return { stop() { stopped = true; clearTimeout(timer); }, redraw: draw };
}
