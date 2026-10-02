// Shared behavior for every page: nav, language, config, screenshots, motion helpers.
import { initI18n, getLang, setLang, onLangChange, t } from './i18n.js?v=1.4';
import { api } from './api.js?v=1.4';

export const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
export const darkScheme = matchMedia('(prefers-color-scheme: dark)');

/* ---------- site config (GET /api/public/config) ---------- */

export const DEFAULT_CONFIG = {
  plans: [
    { id: 'lifetime', name: '终身版', nameEn: 'Lifetime', price: 98, currency: 'CNY', devices: 2, features: [], highlight: true },
    { id: 'family', name: '家庭版', nameEn: 'Family', price: 168, currency: 'CNY', devices: 5, features: [], highlight: false },
  ],
  payment: { wechatQr: null, alipayQr: null, instructions: '' },
  contactEmail: 'wjw599330@gmail.com',
  announcement: null,
  latestRelease: null,
};

let configPromise;
// Resolves to { ...config, live: true } from the server, or the defaults with live: false.
export function getConfig() {
  configPromise ??= api('/api/public/config', { timeout: 8000 })
    .then(c => ({
      ...DEFAULT_CONFIG, ...c,
      plans: Array.isArray(c.plans) && c.plans.length ? c.plans : DEFAULT_CONFIG.plans,
      payment: { ...DEFAULT_CONFIG.payment, ...(c.payment || {}) },
      contactEmail: c.contactEmail || DEFAULT_CONFIG.contactEmail,
      live: true,
    }))
    .catch(() => ({ ...DEFAULT_CONFIG, live: false }));
  return configPromise;
}

/* ---------- formatting ---------- */

export function planName(plan) {
  return getLang() === 'en' ? (plan.nameEn || plan.name) : (plan.name || plan.nameEn);
}

const PLAN_FEATURES = {
  lifetime: ['price.lifetime.f1', 'price.lifetime.f2', 'price.lifetime.f3', 'price.f.refund'],
  family: ['price.family.f1', 'price.family.f2', 'price.family.f3', 'price.f.refund'],
};

export function planFeatures(plan) {
  const known = PLAN_FEATURES[plan.id];
  const list = getLang() === 'en' ? plan.featuresEn : plan.features;
  const fromServer = Array.isArray(list) ? list.filter(Boolean) : [];
  // Server lists come from admin settings (features in Chinese, featuresEn in English).
  if (fromServer.length) return fromServer;
  if (known) return known.map(k => t(k, { n: plan.devices }));
  return fromServer.length ? fromServer : [t('price.f.devices', { n: plan.devices }), t('price.f.refund')];
}

export function money(amount, currency = 'CNY') {
  const n = Number(amount);
  const digits = Number.isInteger(n) ? 0 : 2;
  try {
    return new Intl.NumberFormat(getLang() === 'en' ? 'en-US' : 'zh-CN', {
      style: 'currency', currency, minimumFractionDigits: digits, maximumFractionDigits: 2,
    }).format(n).replace('CN¥', '¥');
  } catch {
    return '¥' + n;
  }
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let i = 0, v = bytes;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}

export function formatDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleString(getLang() === 'en' ? 'en-US' : 'zh-CN', { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export function escapeHTML(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ---------- screenshots ----------
   Files live at /assets/img/screens/{light|dark}-{zh|en}-{tab}.webp (1600w)
   plus a -900 variant. Regenerate with dev/make-screens.sh. */

export const SHOT_DIR = '/assets/img/screens/';
export const SHOT_EXT = '.webp';

export function shotURL(tab, { scheme, lang = getLang(), small = false } = {}) {
  scheme ??= darkScheme.matches ? 'dark' : 'light';
  return `${SHOT_DIR}${scheme}-${lang}-${tab}${small ? '-900' : ''}${SHOT_EXT}`;
}

export function updateShot(img) {
  const tab = img.dataset.shot;
  const scheme = img.dataset.scheme && img.dataset.scheme !== 'auto' ? img.dataset.scheme : undefined;
  const big = shotURL(tab, { scheme });
  const small = shotURL(tab, { scheme, small: true });
  img.srcset = `${small} 900w, ${big} 1600w`;
  img.sizes = img.dataset.sizes || '(max-width: 900px) 92vw, 60vw';
  img.src = big;
}

export function updateShots(root = document) {
  root.querySelectorAll('img[data-shot]').forEach(updateShot);
}

/* ---------- toast ---------- */

let toastTimer;
export function toast(msg) {
  const el = document.getElementById('toast');
  if (!el) return;
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2400);
}

export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = Object.assign(document.createElement('textarea'), { value: text });
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;opacity:0';
    document.body.append(ta);
    ta.select();
    try { document.execCommand('copy'); } catch { /* nothing else to try */ }
    ta.remove();
  }
  toast(t('common.copied'));
}

/* ---------- nav ---------- */

function initNav() {
  const nav = document.getElementById('nav');
  if (!nav) return;
  const main = document.getElementById('main');
  if (main?.classList.contains('force-dark') || main?.firstElementChild?.classList.contains('force-dark')) nav.classList.add('on-dark');

  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  const btn = document.getElementById('menu-btn');
  const close = () => { nav.classList.remove('open'); btn?.setAttribute('aria-expanded', 'false'); };
  btn?.addEventListener('click', () => {
    const open = !nav.classList.contains('open');
    nav.classList.toggle('open', open);
    btn.setAttribute('aria-expanded', String(open));
  });
  nav.querySelectorAll('.nav-links a').forEach(a => a.addEventListener('click', close));
  addEventListener('keydown', e => { if (e.key === 'Escape') close(); });

  const path = location.pathname.replace(/\/index\.html$/, '/');
  nav.querySelectorAll('.nav-links a').forEach(a => {
    const href = a.getAttribute('href');
    if (!href.includes('#') && href === path) a.setAttribute('aria-current', 'page');
  });

  document.getElementById('lang-btn')?.addEventListener('click', () => setLang(getLang() === 'zh' ? 'en' : 'zh'));
}

/* ---------- magnetic, glowing buttons ---------- */

function initMagnetic() {
  if (reducedMotion.matches || !matchMedia('(hover: hover)').matches) return;
  document.querySelectorAll('[data-magnetic]').forEach(el => {
    el.addEventListener('pointermove', e => {
      const r = el.getBoundingClientRect();
      const x = e.clientX - r.left, y = e.clientY - r.top;
      el.style.setProperty('--mx', `${((x / r.width) - .5) * 8}px`);
      el.style.setProperty('--my', `${((y / r.height) - .5) * 6}px`);
      el.style.setProperty('--gx', `${x}px`);
      el.style.setProperty('--gy', `${y}px`);
    });
    el.addEventListener('pointerleave', () => {
      el.style.setProperty('--mx', '0px');
      el.style.setProperty('--my', '0px');
    });
  });
}

/* ---------- reveal on scroll ---------- */

export function initReveal(root = document) {
  const els = root.querySelectorAll('[data-reveal]:not(.in)');
  if (reducedMotion.matches || !('IntersectionObserver' in window)) {
    els.forEach(el => el.classList.add('in'));
    return;
  }
  const io = new IntersectionObserver(entries => {
    for (const e of entries) {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }
  }, { rootMargin: '0px 0px -12% 0px', threshold: .12 });
  els.forEach(el => io.observe(el));
}

/* ---------- config-driven bits present on every page ---------- */

async function applySiteConfig() {
  const cfg = await getConfig();
  document.querySelectorAll('[data-contact-email]').forEach(a => {
    a.href = 'mailto:' + cfg.contactEmail;
    if (a.hasAttribute('data-show-email')) a.textContent = cfg.contactEmail;
  });
  document.querySelectorAll('[data-email-text]').forEach(el => { el.textContent = cfg.contactEmail; });
  const bar = document.getElementById('announce');
  if (bar && cfg.announcement) {
    bar.textContent = cfg.announcement;
    bar.hidden = false;
  }
}

/* ---------- boot ---------- */

export function boot() {
  initI18n();
  initNav();
  initMagnetic();
  initReveal();
  updateShots();
  darkScheme.addEventListener('change', () => updateShots());
  onLangChange(() => { updateShots(); applySiteConfig(); });
  applySiteConfig();
}
