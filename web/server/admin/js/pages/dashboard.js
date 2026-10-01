import { get } from '../api.js';
import { chart, legend } from '../charts.js';
import { append, clear, fmtInt, fmtMoney, fmtRelative, h, icon } from '../dom.js';
import { emptyState, pageHead, payMethod, toastError } from '../ui.js';

const MINT = '#10B981';
const TEAL = '#0891B2';

function kpi({ label, value, foot, iconName, tone = '', hot = false, href }) {
  return h('div', {
    class: ['card', 'kpi', hot && 'hot', href && 'clickable'],
    onclick: href ? () => { location.hash = href; } : null,
    role: href ? 'link' : null,
    tabindex: href ? 0 : null,
  },
  h('div', { class: 'kpi-label' }, h('span', { class: ['kpi-icon', tone] }, icon(iconName, 16)), label),
  h('div', { class: 'kpi-value' }, value),
  foot ? h('div', { class: 'kpi-foot' }, foot) : null);
}

function chartCard(title, sub, keys, node, wide = false) {
  return h('div', { class: ['card', wide && 'wide'] },
    h('div', { class: 'card-head' },
      h('div', h('h3', { class: 'card-title' }, title), h('div', { class: 'card-sub' }, sub)),
      legend(keys)),
    node);
}

export default {
  render(container) {
    const body = h('div', { class: 'stack', style: { gap: '20px' } },
      h('div', { class: 'kpis' }, Array.from({ length: 8 }, () => h('div', { class: 'card kpi' }, h('div', { class: 'skeleton', style: { height: '74px' } })))));
    const refresh = h('button', { class: 'btn sm', onclick: () => load() }, icon('refresh', 15), '刷新');
    append(container, pageHead('概览', '订单、收入、下载与激活一览', refresh), body);

    async function load() {
      try {
        const [{ totals: t, series }, summary] = await Promise.all([get('/api/admin/stats'), get('/api/admin/orders/summary')]);
        const sum = (key, days = 30) => series.slice(-days).reduce((n, d) => n + (Number(d[key]) || 0), 0);
        const revenueKeys = [{ key: 'revenue', label: '收入', color: MINT, color2: TEAL }];
        const dlKeys = [{ key: 'downloads', label: '下载次数', color: TEAL }, { key: 'uniqueDownloads', label: '独立 IP', color: MINT, dashed: true }];
        const actKeys = [{ key: 'activations', label: '新激活', color: MINT }];

        append(clear(body),
          h('div', { class: 'kpis' },
            kpi({
              label: '待确认订单', value: fmtInt(t.ordersPending), iconName: 'inbox', hot: t.ordersPending > 0, tone: 'warn',
              foot: t.ordersNotified ? `其中 ${t.ordersNotified} 位买家已点「我已付款」` : t.ordersPending ? '核对收款后点击确认' : '没有需要处理的订单', href: '#/orders?status=pending',
            }),
            kpi({ label: '今日收入', value: fmtMoney(t.revenueToday), iconName: 'yuan', foot: `近 30 天 ${fmtMoney(sum('revenue'))}` }),
            kpi({ label: '累计收入', value: fmtMoney(t.revenueTotal), iconName: 'yuan', tone: 'teal', foot: `${fmtInt(t.ordersPaid)} 笔已付款订单` }),
            kpi({ label: '已售许可证', value: fmtInt(t.licensesSold), iconName: 'key', foot: `共 ${fmtInt(t.licensesTotal)} 个（含手动签发）`, href: '#/licenses' }),
            kpi({ label: '活跃设备', value: fmtInt(t.activeDevices), iconName: 'laptop', tone: 'teal', foot: `近 7 天联网校验 ${fmtInt(t.devicesSeen7d)} 台` }),
            kpi({ label: '今日下载', value: fmtInt(t.downloadsToday), iconName: 'download', foot: `独立 IP ${fmtInt(t.uniqueDownloadsToday)}` }),
            kpi({ label: '近 7 日下载', value: fmtInt(t.downloads7d), iconName: 'download', tone: 'teal', foot: `近 30 天 ${fmtInt(sum('downloads'))}` }),
            kpi({ label: '累计下载', value: fmtInt(t.downloadsTotal), iconName: 'releases', foot: '统计 /download/latest 次数', href: '#/releases' })),
          h('div', { class: 'charts' },
            chartCard('收入', '近 30 天，按确认收款日期', revenueKeys,
              chart({ series, kind: 'bar', keys: revenueKeys, format: (v, axis) => (axis ? `¥${fmtInt(v)}` : fmtMoney(v)) })),
            pendingCard(summary.latest, t.ordersPending),
            chartCard('下载', '近 30 天', dlKeys, chart({ series, kind: 'line', keys: dlKeys, format: (v) => fmtInt(v) })),
            chartCard('激活', '近 30 天新激活的设备', actKeys, chart({ series, kind: 'line', keys: actKeys, format: (v) => fmtInt(v) }))),
        );
      } catch (err) {
        toastError(err);
      }
    }

    load();
    const onChange = () => load();
    window.addEventListener('mc:orders-changed', onChange);
    return () => window.removeEventListener('mc:orders-changed', onChange);
  },
};

function pendingCard(latest, total) {
  return h('div', { class: 'card' },
    h('div', { class: 'card-head' },
      h('div', h('h3', { class: 'card-title' }, '待确认订单'), h('div', { class: 'card-sub' }, total ? `共 ${total} 笔，最新 5 笔` : '全部处理完毕')),
      h('a', { class: 'btn sm', href: '#/orders?status=pending' }, '去处理')),
    latest.length
      ? h('div', { style: { padding: '6px 10px 10px' } }, latest.map((o) => h('a', {
        href: `#/orders?status=pending&q=${encodeURIComponent(o.orderNo)}`,
        class: 'row', style: { padding: '10px 12px', borderRadius: '10px', color: 'inherit', textDecoration: 'none' },
      },
      h('span', { class: 'paycode', style: { fontSize: '13px' } }, o.payCode),
      h('div', { class: 'grow', style: { minWidth: 0 } },
        h('div', { class: 'cell-main', style: { overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, o.email),
        h('div', { class: 'cell-sub' }, o.planName, ' · ', fmtRelative(o.createdAt), o.buyerNotifiedAt ? ' · 已点我已付款' : '')),
      payMethod(o.payMethod),
      h('span', { class: 'amount', style: { fontSize: '15px' } }, fmtMoney(o.amount)))))
      : emptyState('暂无待确认订单', 'check'));
}
