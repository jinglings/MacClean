import { del, get, patch, post, qs } from '../api.js';
import { append, clear, debounce, fmtDate, fmtRelative, h, icon } from '../dom.js';
import {
  badge, busy, confirmDialog, copyButton, drawer, emptyState, modal, pageHead, pager, skeletonRows, toast, toastError,
} from '../ui.js';
import { showIssuedKey } from './orders.js';

function usage(l) {
  const pct = Math.min(100, (l.activationUsage / Math.max(1, l.activationLimit)) * 100);
  return h('div', { class: 'usage' },
    h('div', { class: ['usage-bar', l.activationUsage >= l.activationLimit && 'full'] }, h('div', { style: { width: `${pct}%` } })),
    h('span', { class: 'small', style: { fontVariantNumeric: 'tabular-nums' } }, `${l.activationUsage} / ${l.activationLimit}`));
}

const statusBadge = (l) => (l.status === 'disabled' ? badge('已停用', 'danger') : badge('有效', 'ok'));

async function issueDialog(onDone) {
  const settings = await get('/api/admin/settings');
  const plans = settings.plans;
  const email = h('input', { class: 'input', type: 'email', placeholder: 'buyer@example.com（可留空）', autofocus: true });
  const plan = h('select', { class: 'select' }, plans.map((p) => h('option', { value: p.id }, `${p.name}（${p.devices} 台）`)));
  const devices = h('input', { class: 'input', type: 'number', min: 1, max: 1000, value: String(plans[0]?.devices ?? 2) });
  plan.addEventListener('change', () => { devices.value = String(plans.find((p) => p.id === plan.value)?.devices ?? 2); });
  const note = h('textarea', { class: 'textarea', placeholder: '例如：赠送给测试者 / 补发 / 线下付款', style: { minHeight: '70px' } });
  const error = h('div', { class: 'form-error' });
  modal({
    title: '手动签发许可证',
    content: h('div', { class: 'stack' },
      h('label', { class: 'field' }, h('span', '邮箱'), email),
      h('div', { class: 'grid-2' }, h('label', { class: 'field' }, h('span', '套餐'), plan), h('label', { class: 'field' }, h('span', '可激活设备数'), devices)),
      h('label', { class: 'field' }, h('span', '备注'), note),
      error),
    actions: [
      { label: '取消', onClick: (close) => close() },
      {
        label: '签发', kind: 'primary', icon: 'key',
        onClick: async (close) => {
          error.textContent = '';
          try {
            const { license } = await post('/api/admin/licenses', { email: email.value.trim(), plan: plan.value, devices: Number(devices.value), note: note.value });
            close();
            showIssuedKey({ title: '许可证已签发', licenseKey: license.key, email: license.email, planName: license.planName, devices: license.activationLimit });
            onDone();
          } catch (err) {
            error.textContent = err.message;
          }
        },
      },
    ],
  });
}

export function openLicense(key, onChange) {
  let lic = null;
  const d = drawer({
    title: '许可证详情',
    render: (body) => {
      if (!lic) {
        append(body, skeletonRows(4, 56));
        return;
      }
      const active = lic.activations.filter((a) => !a.deactivatedAt);
      const past = lic.activations.filter((a) => a.deactivatedAt);
      const limitInput = h('input', { class: 'input', type: 'number', min: 1, max: 1000, value: String(lic.activationLimit) });
      const emailInput = h('input', { class: 'input', type: 'email', value: lic.email || '' });
      const noteInput = h('textarea', { class: 'textarea', value: lic.note || '', style: { minHeight: '64px' } });

      const device = (a) => h('div', { class: ['device', a.deactivatedAt && 'off'] },
        h('div', { class: 'device-icon' }, icon('laptop', 18)),
        h('div', { class: 'grow', style: { minWidth: 0 } },
          h('div', { class: 'cell-main' }, a.name, a.appVersion ? h('span', { class: 'muted small', style: { fontWeight: 400 } }, `  ·  v${a.appVersion}`) : null),
          h('div', { class: 'cell-sub' },
            `首次激活 ${fmtDate(a.createdAt)} · 最近联网 ${fmtRelative(a.lastSeenAt)}`,
            a.ip ? ` · ${a.ip}` : '',
            a.deactivatedAt ? ` · ${a.deactivatedBy === 'admin' ? '管理员解绑' : '用户停用'}于 ${fmtDate(a.deactivatedAt)}` : '')),
        a.deactivatedAt ? null : h('button', {
          class: 'btn sm danger',
          onclick: busy(async () => {
            const ok = await confirmDialog({
              title: '解绑设备', danger: true, confirmText: '解绑',
              message: `解绑「${a.name}」后会释放一个激活名额；该设备下次联网校验时会变回未激活状态。`,
            });
            if (!ok) return;
            ({ license: lic } = await del(`/api/admin/licenses/${encodeURIComponent(lic.key)}/activations/${encodeURIComponent(a.id)}`));
            toast('设备已解绑');
            d.refresh();
            onChange?.();
          }),
        }, '解绑'));

      append(body,
        h('div', { class: 'keybox big' }, h('span', { class: 'mono' }, lic.key), copyButton(lic.key, { label: '复制', small: false })),
        h('div', { class: 'row wrap' },
          statusBadge(lic),
          badge(lic.planName, 'teal', { plain: true }),
          badge(lic.source === 'manual' ? '手动签发' : '订单购买', '', { plain: true }),
          h('div', { class: 'grow' }),
          lic.status === 'disabled'
            ? h('button', { class: 'btn sm', onclick: busy(() => setStatus('enable')) }, icon('check', 15), '重新启用')
            : h('button', { class: 'btn sm danger', onclick: busy(() => setStatus('disable')) }, icon('ban', 15), '停用')),
        h('dl', { class: 'kv' },
          h('dt', '设备'), h('dd', usage(lic)),
          h('dt', '订单号'), h('dd', lic.orderNo ? h('a', { class: 'mono', href: `#/orders?status=&q=${encodeURIComponent(lic.orderNo)}` }, lic.orderNo) : '—'),
          h('dt', '签发时间'), h('dd', fmtDate(lic.createdAt)),
          lic.disabledAt ? [h('dt', '停用时间'), h('dd', fmtDate(lic.disabledAt))] : null),
        h('div', { class: 'stack', style: { gap: '10px' } },
          h('div', { class: 'card-title' }, `已激活设备（${active.length}）`),
          active.length ? active.map(device) : h('div', { class: 'muted small' }, '还没有设备激活这个许可证。'),
          past.length ? [h('div', { class: 'card-sub', style: { marginTop: '6px' } }, '历史设备'), past.map(device)] : null),
        h('div', { class: 'stack', style: { gap: '12px' } },
          h('div', { class: 'card-title' }, '编辑'),
          h('div', { class: 'grid-2' }, h('label', { class: 'field' }, h('span', '可激活设备数'), limitInput), h('label', { class: 'field' }, h('span', '邮箱'), emailInput)),
          h('label', { class: 'field' }, h('span', '备注'), noteInput),
          h('div', h('button', {
            class: 'btn primary',
            onclick: busy(async () => {
              ({ license: lic } = await patch(`/api/admin/licenses/${encodeURIComponent(lic.key)}`, {
                devices: Number(limitInput.value), email: emailInput.value.trim(), note: noteInput.value,
              }));
              toast('已保存');
              d.refresh();
              onChange?.();
            }),
          }, '保存修改'))),
      );
    },
  });

  async function setStatus(action) {
    if (action === 'disable') {
      const ok = await confirmDialog({
        title: '停用许可证', danger: true, confirmText: '停用',
        message: '停用后，所有已激活的设备会在下次联网校验时失去授权（通常在 7 天内），也不能再激活新设备。可以随时重新启用。',
      });
      if (!ok) return;
    }
    ({ license: lic } = await post(`/api/admin/licenses/${encodeURIComponent(lic.key)}/${action}`));
    toast(action === 'disable' ? '许可证已停用' : '许可证已启用');
    d.refresh();
    onChange?.();
  }

  get(`/api/admin/licenses/${encodeURIComponent(key)}`).then((data) => { lic = data; d.refresh(); }).catch((err) => { d.close(); toastError(err); });
}

export default {
  render(container, { params }) {
    const state = { q: params.get('q') || '', status: '', page: 1 };
    const listEl = h('div');
    const search = h('input', {
      class: 'input', type: 'search', placeholder: '搜索许可证 / 邮箱 / 订单号 / 备注', value: state.q,
      oninput: debounce(() => { state.q = search.value.trim(); state.page = 1; load(); }, 250),
    });
    const tabs = h('div', { class: 'tabs' });
    const renderTabs = () => append(clear(tabs), ...[['', '全部'], ['active', '有效'], ['disabled', '已停用']].map(([id, label]) =>
      h('button', { class: ['tab', state.status === id && 'active'], onclick: () => { state.status = id; state.page = 1; renderTabs(); load(); } }, label)));
    renderTabs();

    append(container,
      pageHead('许可证', '查看激活设备、解绑、停用，或手动签发。',
        h('div', { class: 'search' }, icon('search', 16), search),
        h('button', { class: 'btn primary', onclick: busy(() => issueDialog(load)) }, icon('plus', 16), '手动签发')),
      tabs,
      h('div', { class: 'card section-gap' }, listEl));

    let seq = 0;
    async function load() {
      const mine = ++seq;
      if (!listEl.firstChild) append(listEl, skeletonRows());
      try {
        const data = await get(`/api/admin/licenses${qs({ q: state.q, status: state.status, page: state.page, pageSize: 20 })}`);
        if (mine !== seq) return;
        clear(listEl);
        if (!data.items.length) {
          append(listEl, emptyState(state.q ? '没有匹配的许可证' : '还没有许可证', 'key', state.q ? null : '确认订单收款或手动签发后会出现在这里'));
          return;
        }
        append(listEl,
          h('div', { class: 'table-wrap' }, h('table', { class: 'table' },
            h('thead', h('tr', ['许可证', '邮箱', '套餐', '设备', '状态', '签发', ''].map((t) => h('th', t)))),
            h('tbody', data.items.map((l) => h('tr',
              h('td', h('button', { class: 'linkish', onclick: () => openLicense(l.key, load) }, h('div', { class: 'cell-main mono' }, l.key),
                h('div', { class: 'cell-sub' }, l.source === 'manual' ? '手动签发' : l.orderNo || ''))),
              h('td', l.email || h('span', { class: 'muted' }, '—'), l.note ? h('div', { class: 'cell-sub' }, l.note) : null),
              h('td', l.planName),
              h('td', usage(l)),
              h('td', statusBadge(l)),
              h('td', { class: 'nowrap' }, fmtDate(l.createdAt, { time: false })),
              h('td', h('div', { class: 'actions' }, copyButton(l.key), h('button', { class: 'btn sm', onclick: () => openLicense(l.key, load) }, '详情')))))))),
          data.total > data.pageSize ? pager({ ...data, onChange: (p) => { state.page = p; load(); } }) : null);
      } catch (err) {
        toastError(err);
      }
    }
    load();
    if (state.q && /^MCLN-/i.test(state.q)) openLicense(state.q, load);
  },
};
