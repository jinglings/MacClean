import { clear, h, icon } from './dom.js';

// ---------- Toasts ----------

export function toast(message, { type = 'ok', timeout = 3200, onClick } = {}) {
  const host = document.getElementById('toasts');
  const iconName = type === 'error' ? 'x' : type === 'order' ? 'bell' : 'check';
  const el = h('div', { class: `toast ${type}`, role: 'status', onclick: () => { onClick?.(); dismiss(); } }, icon(iconName, 18), h('span', message));
  host.append(el);
  let timer = setTimeout(dismiss, timeout);
  el.addEventListener('mouseenter', () => clearTimeout(timer));
  el.addEventListener('mouseleave', () => { timer = setTimeout(dismiss, 1500); });
  function dismiss() {
    clearTimeout(timer);
    el.classList.add('leaving');
    setTimeout(() => el.remove(), 200);
  }
}

export const toastError = (err) => toast(err?.message || String(err), { type: 'error', timeout: 5000 });

// ---------- Modals ----------

/** Opens a modal. `content` is a Node; returns `{ close, root }`. */
export function modal({ title, content, actions = [], wide = false, onClose }) {
  const previouslyFocused = document.activeElement;
  const close = () => {
    overlay.remove();
    document.removeEventListener('keydown', onKey);
    onClose?.();
    previouslyFocused?.focus?.();
  };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  const box = h('div', { class: ['modal', wide && 'wide'], role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
    h('div', { class: 'modal-head' },
      h('h2', { class: 'modal-title' }, title),
      h('button', { class: 'btn ghost sm icon-only', 'aria-label': '关闭', onclick: close }, icon('x', 16))),
    h('div', { class: 'modal-body' }, content),
    actions.length ? h('div', { class: 'modal-foot' }, actions.map((a) => (a instanceof Node ? a : h('button', {
      class: ['btn', a.kind], onclick: () => a.onClick?.(close), type: 'button',
    }, a.icon && icon(a.icon, 16), a.label)))) : null);
  const overlay = h('div', { class: 'overlay', onmousedown: (e) => { if (e.target === overlay) close(); } }, box);
  document.body.append(overlay);
  document.addEventListener('keydown', onKey);
  setTimeout(() => (box.querySelector('[autofocus], input, textarea, select, .btn.primary') || box).focus?.(), 30);
  return { close, root: box };
}

/** Resolves true when confirmed. */
export function confirmDialog({ title, message, confirmText = '确定', danger = false, details }) {
  return new Promise((resolve) => {
    let decided = false;
    const m = modal({
      title,
      content: h('div', { class: 'stack' }, h('p', { style: { margin: 0, color: 'var(--text-2)' } }, message), details || null),
      actions: [
        { label: '取消', onClick: (close) => close() },
        { label: confirmText, kind: danger ? 'danger solid' : 'primary', onClick: (close) => { decided = true; close(); } },
      ],
      onClose: () => resolve(decided),
    });
    return m;
  });
}

/** Text prompt in a modal. Resolves the string or null. */
export function promptDialog({ title, label, value = '', multiline = false, placeholder = '', confirmText = '保存' }) {
  return new Promise((resolve) => {
    let result = null;
    const input = multiline
      ? h('textarea', { class: 'textarea', placeholder, value, autofocus: true })
      : h('input', { class: 'input', placeholder, value, autofocus: true });
    modal({
      title,
      content: h('label', { class: 'field' }, h('span', label), input),
      actions: [
        { label: '取消', onClick: (close) => close() },
        { label: confirmText, kind: 'primary', onClick: (close) => { result = input.value; close(); } },
      ],
      onClose: () => resolve(result),
    });
  });
}

/** Side drawer; `render(body, close)` fills it and may be called again to refresh. */
export function drawer({ title, render }) {
  const titleEl = h('h2', { class: 'modal-title' }, title);
  const body = h('div', { class: 'drawer-body' });
  const close = () => {
    overlay.remove();
    document.removeEventListener('keydown', onKey);
  };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  const overlay = h('div', { class: 'overlay drawer-overlay', onmousedown: (e) => { if (e.target === overlay) close(); } },
    h('aside', { class: 'drawer', role: 'dialog', 'aria-modal': 'true' },
      h('div', { class: 'drawer-head' }, titleEl, h('button', { class: 'btn ghost sm icon-only', 'aria-label': '关闭', onclick: close }, icon('x', 16))),
      body));
  document.body.append(overlay);
  document.addEventListener('keydown', onKey);
  const refresh = () => render(clear(body), close);
  refresh();
  return { close, refresh, setTitle: (t) => { titleEl.textContent = t; } };
}

// ---------- Bits ----------

export async function copyText(text, label = '已复制') {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = h('textarea', { value: text, style: { position: 'fixed', opacity: '0' } });
    document.body.append(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  toast(label);
}

export function copyButton(text, { label, small = true, title = '复制' } = {}) {
  return h('button', {
    class: ['btn', small && 'sm', !label && 'icon-only'], type: 'button', title, 'aria-label': title,
    onclick: (e) => { e.stopPropagation(); copyText(text); },
  }, icon('copy', 15), label || null);
}

export function emptyState(text, iconName = 'inbox', sub) {
  return h('div', { class: 'empty' }, h('div', { class: 'empty-icon' }, icon(iconName, 22)), h('div', { style: { fontWeight: 600, color: 'var(--text-2)' } }, text), sub ? h('div', { class: 'small', style: { marginTop: '4px' } }, sub) : null);
}

export function skeletonRows(n = 5, height = 44) {
  return h('div', { style: { padding: '16px 22px', display: 'grid', gap: '10px' } },
    Array.from({ length: n }, () => h('div', { class: 'skeleton', style: { height: `${height}px` } })));
}

export function pager({ page, pageSize, total, onChange }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  return h('div', { class: 'pager' },
    h('span', `共 ${total} 条 · 第 ${page} / ${pages} 页`),
    h('div', { class: 'row' },
      h('button', { class: 'btn sm', disabled: page <= 1, onclick: () => onChange(page - 1) }, '上一页'),
      h('button', { class: 'btn sm', disabled: page >= pages, onclick: () => onChange(page + 1) }, '下一页')));
}

export function badge(text, kind = '', { pulse = false, plain = false } = {}) {
  return h('span', { class: ['badge', kind, pulse && 'pulse', plain && 'plain'] }, text);
}

export const ORDER_STATUS = {
  pending: ['待确认', 'warn'],
  paid: ['已付款', 'ok'],
  cancelled: ['已取消', ''],
};

export function orderStatusBadge(order) {
  if (order.status === 'pending' && order.buyerNotifiedAt) return badge('买家已付款', 'teal', { pulse: true });
  const [label, kind] = ORDER_STATUS[order.status] || [order.status, ''];
  return badge(label, kind);
}

export function payMethod(method) {
  return h('span', { class: ['pay', method] }, h('i'), method === 'wechat' ? '微信' : method === 'alipay' ? '支付宝' : method);
}

/** Wraps an async click handler: disables the button while it runs and toasts errors. */
export function busy(fn) {
  return async (e) => {
    const btn = e?.currentTarget;
    if (btn) btn.disabled = true;
    try {
      await fn(e);
    } catch (err) {
      toastError(err);
    } finally {
      if (btn) btn.disabled = false;
    }
  };
}

export function pageHead(title, desc, ...right) {
  return h('div', { class: 'page-head' },
    h('div', h('h1', { class: 'page-title' }, title), desc ? h('p', { class: 'page-desc' }, desc) : null),
    h('div', { class: 'row wrap' }, right));
}
