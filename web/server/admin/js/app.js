import { get, onUnauthorized, post } from './api.js';
import { clear, h, icon } from './dom.js';
import { busy, toast } from './ui.js';
import audit from './pages/audit.js';
import dashboard from './pages/dashboard.js';
import licenses from './pages/licenses.js';
import orders from './pages/orders.js';
import releases from './pages/releases.js';
import settings from './pages/settings.js';

const PAGES = [
  { id: 'dashboard', label: '概览', icon: 'dashboard', page: dashboard },
  { id: 'orders', label: '订单', icon: 'orders', page: orders },
  { id: 'licenses', label: '许可证', icon: 'key', page: licenses },
  { id: 'releases', label: '版本发布', icon: 'releases', page: releases },
  { id: 'settings', label: '设置', icon: 'settings', page: settings },
  { id: 'audit', label: '操作日志', icon: 'audit', page: audit },
];

const BASE_TITLE = 'MacClean 管理后台';
const root = document.getElementById('app');
const state = { session: null, cleanup: null, poll: null, lastPendingId: null, lastNotified: null, counts: null, badges: {} };

// ---------- Theme ----------

const THEMES = ['system', 'light', 'dark'];
function currentThemePref() {
  try { return localStorage.getItem('mc-admin-theme') || 'system'; } catch { return 'system'; }
}
function applyTheme(pref) {
  const dark = pref === 'dark' || (pref === 'system' && matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => applyTheme(currentThemePref()));

function themeButton() {
  const pref = currentThemePref();
  const names = { system: ['monitor', '跟随系统'], light: ['sun', '浅色'], dark: ['moon', '深色'] };
  const [ic, label] = names[pref];
  return h('button', {
    class: 'btn ghost sm icon-only', title: `主题：${label}（点击切换）`, 'aria-label': `主题：${label}`,
    onclick: (e) => {
      const next = THEMES[(THEMES.indexOf(pref) + 1) % THEMES.length];
      try { localStorage.setItem('mc-admin-theme', next); } catch { /* ignore */ }
      applyTheme(next);
      e.currentTarget.replaceWith(themeButton());
    },
  }, icon(ic, 17));
}

function brand(sub = '管理后台') {
  return h('div', { class: 'brand' },
    h('div', { class: 'brand-mark' }, icon('logo', 18)),
    h('div', { class: 'brand-text' }, h('div', { class: 'brand-name' }, 'MacClean'), h('div', { class: 'brand-sub' }, sub)));
}

// ---------- Auth screens ----------

function authScreen({ title, desc, fields, submitLabel, onSubmit }) {
  stopPolling();
  document.title = BASE_TITLE;
  const error = h('div', { class: 'form-error', role: 'alert' });
  const button = h('button', { class: 'btn primary lg', type: 'submit', style: { width: '100%' } }, submitLabel);
  const form = h('form', {
    class: 'stack',
    onsubmit: async (e) => {
      e.preventDefault();
      error.textContent = '';
      button.disabled = true;
      try {
        await onSubmit(Object.fromEntries(new FormData(form)));
      } catch (err) {
        error.textContent = err.message;
      } finally {
        button.disabled = false;
      }
    },
  }, fields, error, button);
  clear(root).append(h('div', { class: 'auth' },
    h('div', { class: 'card auth-card' }, brand(), h('h1', title), h('p', desc), form),
    h('div', { style: { position: 'fixed', top: '16px', right: '16px' } }, themeButton())));
  form.querySelector('input')?.focus();
}

const pwField = (name, label, autocomplete, extra = {}) => h('label', { class: 'field' }, h('span', label),
  h('input', { class: 'input', type: 'password', name, required: true, autocomplete, ...extra }));

function showLogin() {
  authScreen({
    title: '登录',
    desc: '输入管理员密码以继续。',
    fields: [pwField('password', '密码', 'current-password')],
    submitLabel: '登录',
    onSubmit: async ({ password }) => {
      await post('/api/admin/login', { password });
      await boot();
    },
  });
}

function showSetup() {
  authScreen({
    title: '初始化管理员',
    desc: '首次使用：请输入服务器日志中打印的一次性初始化令牌（journalctl -u macclean-server | grep "SETUP TOKEN"），并设置管理员密码。',
    fields: [
      h('label', { class: 'field' }, h('span', '初始化令牌'), h('input', { class: 'input mono', name: 'token', required: true, autocomplete: 'off', spellcheck: 'false' })),
      pwField('password', '新密码（至少 10 位）', 'new-password', { minlength: 10 }),
      pwField('confirm', '确认密码', 'new-password', { minlength: 10 }),
    ],
    submitLabel: '设置密码并进入后台',
    onSubmit: async ({ token, password, confirm }) => {
      if (password !== confirm) throw new Error('两次输入的密码不一致');
      await post('/api/admin/setup', { token: token.trim(), password });
      toast('管理员密码已设置');
      await boot();
    },
  });
}

// ---------- Shell ----------

let shell = null;

function buildShell() {
  const navLinks = {};
  const nav = h('nav', { class: 'stack', style: { gap: '2px' } }, PAGES.map((p) => {
    const count = h('span', { class: 'count hidden' });
    state.badges[p.id] = count;
    const link = h('a', { class: 'nav-item', href: `#/${p.id}` }, icon(p.icon, 18), h('span', { class: 'label' }, p.label), count);
    navLinks[p.id] = link;
    return link;
  }));
  const main = h('main', { class: 'main' });
  const logout = h('button', {
    class: 'btn ghost sm', title: '退出登录',
    onclick: busy(async () => {
      await post('/api/admin/logout');
      showLogin();
    }),
  }, icon('logout', 16), h('span', { class: 'label' }, '退出'));
  const el = h('div', { class: 'shell' },
    h('aside', { class: 'sidebar' }, brand(), nav, h('div', { class: 'sidebar-foot' }, themeButton(), h('div', { class: 'grow' }), logout)),
    main);
  clear(root).append(el);
  shell = { main, navLinks };
}

function route() {
  if (!shell) return;
  const id = (location.hash.match(/^#\/([a-z]+)/) || [])[1] || 'dashboard';
  const entry = PAGES.find((p) => p.id === id) || PAGES[0];
  for (const [pid, link] of Object.entries(shell.navLinks)) link.classList.toggle('active', pid === entry.id);
  state.cleanup?.();
  state.cleanup = null;
  const container = h('div', { class: 'page' });
  clear(shell.main).append(container);
  const params = new URLSearchParams(location.hash.split('?')[1] || '');
  const result = entry.page.render(container, { params, refreshCounts: pollOrders, counts: () => state.counts });
  if (typeof result === 'function') state.cleanup = result;
  window.scrollTo(0, 0);
}

// ---------- Order polling (badge + toast) ----------

async function pollOrders() {
  try {
    const { counts, latest } = await get('/api/admin/orders/summary');
    state.counts = counts;
    const badge = state.badges.orders;
    badge.textContent = counts.pending > 99 ? '99+' : String(counts.pending);
    badge.classList.toggle('hidden', counts.pending === 0);
    document.title = counts.pending ? `(${counts.pending}) ${BASE_TITLE}` : BASE_TITLE;

    if (state.lastPendingId !== null && counts.latestPendingId > state.lastPendingId) {
      const fresh = latest.filter((o) => o.id > state.lastPendingId);
      for (const o of fresh.slice(0, 3)) {
        toast(`新订单 ${o.orderNo} · ¥${o.amount} · 付款码 ${o.payCode}`, { type: 'order', timeout: 8000, onClick: () => { location.hash = '#/orders?status=pending'; } });
      }
    }
    if (state.lastNotified !== null && counts.notified > state.lastNotified) {
      toast('有买家点击了「我已付款」，请核对收款', { type: 'order', timeout: 8000, onClick: () => { location.hash = '#/orders?status=notified'; } });
    }
    const changed = state.lastPendingId !== counts.latestPendingId || state.lastNotified !== counts.notified;
    state.lastPendingId = counts.latestPendingId;
    state.lastNotified = counts.notified;
    if (changed) window.dispatchEvent(new CustomEvent('mc:orders-changed', { detail: counts }));
  } catch {
    // Offline or logged out; the 401 handler takes care of the latter.
  }
}

function startPolling() {
  stopPolling();
  pollOrders();
  state.poll = setInterval(pollOrders, 20_000);
}

function stopPolling() {
  clearInterval(state.poll);
  state.poll = null;
}

// ---------- Boot ----------

async function boot() {
  let session;
  try {
    session = await get('/api/admin/session');
  } catch (err) {
    clear(root).append(h('div', { class: 'auth' }, h('div', { class: 'card auth-card' }, brand(), h('h1', '无法连接服务器'), h('p', err.message),
      h('button', { class: 'btn primary', onclick: boot }, '重试'))));
    return;
  }
  state.session = session;
  if (session.setupRequired) return showSetup();
  if (!session.authenticated) return showLogin();
  state.lastPendingId = null;
  state.lastNotified = null;
  buildShell();
  route();
  startPolling();
}

let handlingUnauthorized = false;
onUnauthorized(() => {
  if (handlingUnauthorized || !shell) return;
  handlingUnauthorized = true;
  shell = null;
  state.cleanup?.();
  toast('登录已过期，请重新登录', { type: 'error' });
  showLogin();
  setTimeout(() => { handlingUnauthorized = false; }, 500);
});

window.addEventListener('hashchange', route);
boot();
