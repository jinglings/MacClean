import { get, post, qs } from '../api.js';
import { append, clear, debounce, fmtDate, fmtMoney, fmtRelative, h, icon } from '../dom.js';
import {
  busy, confirmDialog, copyButton, copyText, drawer, emptyState, modal, orderStatusBadge, pageHead, pager, payMethod,
  promptDialog, skeletonRows, toast, toastError,
} from '../ui.js';

const TABS = [
  { id: 'pending', label: '待确认', countKey: 'pending', alert: true },
  { id: 'notified', label: '买家已付款', countKey: 'notified', alert: true },
  { id: 'paid', label: '已付款', countKey: 'paid' },
  { id: 'cancelled', label: '已取消', countKey: 'cancelled' },
  { id: '', label: '全部', countKey: 'all' },
];

/** Shows the freshly issued key with copy helpers. */
export function showIssuedKey({ title = '已生成许可证', licenseKey, email, planName, devices }) {
  const message = `您好，感谢购买 MacClean${planName ? `（${planName}）` : ''}！\n\n许可证密钥：${licenseKey}\n${devices ? `可激活 ${devices} 台 Mac。\n` : ''}\n激活方法：打开 MacClean →「设置」→「许可证」，粘贴密钥并点击「激活」。`;
  modal({
    title,
    content: h('div', { class: 'stack' },
      h('div', { class: 'keybox big' }, h('span', { class: 'mono' }, licenseKey), copyButton(licenseKey, { label: '复制', small: false })),
      email ? h('div', { class: 'muted small' }, `买家邮箱：${email}。买家在订单页面刷新即可看到密钥，也可以把下面的消息发给对方。`) : null,
      h('textarea', { class: 'textarea', readOnly: true, value: message, style: { minHeight: '150px' } })),
    actions: [
      { label: '复制发给买家的消息', icon: 'copy', onClick: () => copyText(message, '消息已复制') },
      { label: '完成', kind: 'primary', onClick: (close) => close() },
    ],
  });
}

export default {
  render(container, { params, refreshCounts }) {
    const state = { status: params.get('status') ?? 'pending', q: params.get('q') || '', page: 1, data: null };
    const tabsEl = h('div', { class: 'tabs', role: 'tablist' });
    const listEl = h('div');
    const search = h('input', {
      class: 'input', type: 'search', placeholder: '搜索邮箱 / 订单号 / 付款码 / 许可证', value: state.q,
      oninput: debounce(() => { state.q = search.value.trim(); state.page = 1; load(); }, 250),
    });
    append(container,
      pageHead('订单', '核对收款后点击「确认收款」，系统会自动生成许可证。',
        h('div', { class: 'search' }, icon('search', 16), search),
        h('button', { class: 'btn icon-only', title: '刷新', onclick: () => load() }, icon('refresh', 16))),
      tabsEl,
      h('div', { class: 'card section-gap' }, listEl),
    );

    function renderTabs(counts = {}) {
      append(clear(tabsEl), ...TABS.map((t) => {
        const n = counts[t.countKey] ?? 0;
        return h('button', {
          class: ['tab', state.status === t.id && 'active'], role: 'tab', 'aria-selected': String(state.status === t.id),
          onclick: () => { state.status = t.id; state.page = 1; renderTabs(counts); load(); },
        }, t.label, n || t.alert ? h('span', { class: ['pill', t.alert && n > 0 && 'alert'] }, String(n)) : null);
      }));
    }

    async function act(order, action) {
      if (action === 'confirm') {
        const ok = await confirmDialog({
          title: '确认收款',
          message: '请确认已在微信 / 支付宝收到这笔付款，并且备注中的付款码一致。确认后会立即生成许可证。',
          confirmText: '已收到，生成许可证',
          details: h('dl', { class: 'kv' },
            h('dt', '金额'), h('dd', h('span', { class: 'amount' }, fmtMoney(order.amount))),
            h('dt', '付款码'), h('dd', h('span', { class: 'paycode' }, order.payCode)),
            h('dt', '支付方式'), h('dd', payMethod(order.payMethod)),
            h('dt', '套餐'), h('dd', `${order.planName} · ${order.devices} 台设备`),
            h('dt', '邮箱'), h('dd', order.email)),
        });
        if (!ok) return;
        const res = await post(`/api/admin/orders/${encodeURIComponent(order.orderNo)}/confirm`);
        showIssuedKey({ licenseKey: res.licenseKey, email: order.email, planName: order.planName, devices: order.devices });
      } else if (action === 'cancel') {
        const ok = await confirmDialog({
          title: '取消订单', danger: true, confirmText: '取消订单',
          message: `确定取消订单 ${order.orderNo}？买家在订单页会看到「已取消」。如果之后又收到了付款，仍可以再确认收款。`,
        });
        if (!ok) return;
        await post(`/api/admin/orders/${encodeURIComponent(order.orderNo)}/cancel`);
        toast('订单已取消');
      } else if (action === 'note') {
        const note = await promptDialog({ title: `备注 · ${order.orderNo}`, label: '内部备注（买家看不到）', value: order.adminNote || '', multiline: true });
        if (note === null) return;
        await post(`/api/admin/orders/${encodeURIComponent(order.orderNo)}/note`, { note });
        toast('备注已保存');
      }
      await Promise.all([load(), refreshCounts()]);
    }

    function details(order) {
      drawer({
        title: `订单 ${order.orderNo}`,
        render: (body) => append(body,
          h('div', { class: 'row', style: { justifyContent: 'space-between' } },
            h('div', h('div', { class: 'amount', style: { fontSize: '28px' } }, fmtMoney(order.amount)), h('div', { class: 'muted' }, `${order.planName} · ${order.devices} 台设备`)),
            h('div', { class: 'stack', style: { alignItems: 'flex-end', gap: '8px' } }, orderStatusBadge(order), h('span', { class: 'paycode' }, order.payCode))),
          h('dl', { class: 'kv' },
            h('dt', '订单号'), h('dd', h('span', { class: 'mono' }, order.orderNo)),
            h('dt', '邮箱'), h('dd', order.email, ' ', copyButton(order.email)),
            h('dt', '支付方式'), h('dd', payMethod(order.payMethod)),
            h('dt', '下单时间'), h('dd', fmtDate(order.createdAt)),
            h('dt', '买家已付款'), h('dd', order.buyerNotifiedAt ? `${fmtDate(order.buyerNotifiedAt)}（${fmtRelative(order.buyerNotifiedAt)}）` : '—'),
            h('dt', '确认收款'), h('dd', fmtDate(order.paidAt)),
            order.cancelledAt ? [h('dt', '取消时间'), h('dd', fmtDate(order.cancelledAt))] : null,
            h('dt', '买家留言'), h('dd', order.buyerNote || '—'),
            h('dt', '内部备注'), h('dd', order.adminNote || '—'),
            h('dt', '下单 IP'), h('dd', h('span', { class: 'mono' }, order.ip || '—'))),
          order.licenseKey ? h('div', { class: 'stack', style: { gap: '8px' } },
            h('div', { class: 'card-title' }, '许可证'),
            h('div', { class: 'keybox' }, h('a', { class: 'mono', href: `#/licenses?q=${encodeURIComponent(order.licenseKey)}` }, order.licenseKey), copyButton(order.licenseKey))) : null,
        ),
      });
    }

    function row(o) {
      const flagged = o.status === 'pending' && o.buyerNotifiedAt;
      return h('tr', { class: flagged ? 'flag' : null },
        h('td', h('button', { class: 'linkish', onclick: () => details(o) },
          h('div', { class: 'cell-main mono' }, o.orderNo),
          h('div', { class: 'cell-sub' }, fmtDate(o.createdAt), ' · ', fmtRelative(o.createdAt)))),
        h('td', h('div', { class: 'cell-main' }, o.planName), h('div', { class: 'cell-sub' }, `${o.devices} 台设备`)),
        h('td', h('span', { class: 'amount' }, fmtMoney(o.amount))),
        h('td', h('span', { class: 'paycode' }, o.payCode)),
        h('td', payMethod(o.payMethod)),
        h('td', h('div', { class: 'cell-main', style: { fontWeight: 500 } }, o.email),
          o.adminNote ? h('div', { class: 'cell-sub' }, `备注：${o.adminNote}`) : o.buyerNote ? h('div', { class: 'cell-sub' }, `留言：${o.buyerNote}`) : null),
        h('td', orderStatusBadge(o), flagged ? h('div', { class: 'cell-sub' }, fmtRelative(o.buyerNotifiedAt)) : null),
        h('td', h('div', { class: 'actions' },
          o.status !== 'paid' ? h('button', { class: 'btn primary sm', onclick: busy(() => act(o, 'confirm')) }, icon('check', 15), '确认收款') : null,
          o.status === 'paid' && o.licenseKey ? copyButton(o.licenseKey, { title: '复制许可证' }) : null,
          h('button', { class: 'btn sm icon-only', title: '备注', 'aria-label': '备注', onclick: busy(() => act(o, 'note')) }, icon('note', 15)),
          o.status === 'pending' ? h('button', { class: 'btn sm danger icon-only', title: '取消订单', 'aria-label': '取消订单', onclick: busy(() => act(o, 'cancel')) }, icon('x', 15)) : null)));
    }

    let seq = 0;
    async function load() {
      const mine = ++seq;
      if (!state.data) append(clear(listEl), skeletonRows());
      try {
        const data = await get(`/api/admin/orders${qs({ status: state.status, q: state.q, page: state.page, pageSize: 20 })}`);
        if (mine !== seq) return;
        state.data = data;
        renderTabs(data.counts);
        clear(listEl);
        if (!data.items.length) {
          append(listEl, emptyState(state.q ? '没有匹配的订单' : state.status === 'pending' ? '暂无待确认订单' : '暂无订单', state.status === 'pending' ? 'check' : 'inbox',
            state.status === 'pending' && !state.q ? '新订单会每 20 秒自动刷新并提醒' : null));
          return;
        }
        append(listEl,
          h('div', { class: 'table-wrap' }, h('table', { class: 'table' },
            h('thead', h('tr', ['订单', '套餐', '金额', '付款码', '方式', '邮箱', '状态', ''].map((t) => h('th', t)))),
            h('tbody', data.items.map(row)))),
          data.total > data.pageSize ? pager({ ...data, onChange: (p) => { state.page = p; load(); } }) : null);
      } catch (err) {
        toastError(err);
      }
    }

    renderTabs();
    load();
    const onChange = () => load();
    window.addEventListener('mc:orders-changed', onChange);
    return () => window.removeEventListener('mc:orders-changed', onChange);
  },
};
