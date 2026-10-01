import { get, qs } from '../api.js';
import { append, clear, debounce, fmtDate, h, icon } from '../dom.js';
import { badge, emptyState, pageHead, pager, skeletonRows, toastError } from '../ui.js';

const ACTIONS = {
  'admin.setup': ['初始化管理员', 'teal'],
  'admin.login': ['登录', ''],
  'admin.login_failed': ['登录失败', 'danger'],
  'admin.password_changed': ['修改密码', 'warn'],
  'admin.password_set_cli': ['命令行设置密码', 'warn'],
  'order.confirm': ['确认收款', 'ok'],
  'order.cancel': ['取消订单', 'danger'],
  'order.note': ['订单备注', ''],
  'license.issue': ['手动签发', 'ok'],
  'license.issue_cli': ['命令行签发', 'ok'],
  'license.update': ['修改许可证', ''],
  'license.disable': ['停用许可证', 'danger'],
  'license.enable': ['启用许可证', 'ok'],
  'license.release_device': ['解绑设备', 'warn'],
  'release.upload': ['发布版本', 'teal'],
  'release.update': ['编辑版本', ''],
  'release.set_latest': ['设为最新', 'teal'],
  'release.delete': ['删除版本', 'danger'],
  'settings.update': ['修改设置', ''],
  'settings.qr_upload': ['上传收款码', ''],
  'settings.qr_delete': ['删除收款码', 'danger'],
};

const DETAIL_LABELS = {
  amount: '金额', email: '邮箱', licenseKey: '许可证', plan: '套餐', devices: '设备数', note: '备注', activation: '设备',
  build: 'Build', size: '大小', latest: '设为最新', downloads: '下载', changed: '修改项',
};

function describe(detail) {
  if (!detail || typeof detail !== 'object') return detail ? String(detail) : '';
  return Object.entries(detail)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${DETAIL_LABELS[k] || k}：${Array.isArray(v) ? v.join('、') : typeof v === 'boolean' ? (v ? '是' : '否') : v}`)
    .join(' · ');
}

export default {
  render(container) {
    const state = { q: '', page: 1 };
    const listEl = h('div');
    const search = h('input', {
      class: 'input', type: 'search', placeholder: '搜索操作或对象（订单号、许可证…）',
      oninput: debounce(() => { state.q = search.value.trim(); state.page = 1; load(); }, 250),
    });
    append(container,
      pageHead('操作日志', '后台的每一次登录和修改都会记录在这里。', h('div', { class: 'search' }, icon('search', 16), search)),
      h('div', { class: 'card' }, listEl));

    async function load() {
      if (!listEl.firstChild) append(listEl, skeletonRows(8, 36));
      try {
        const data = await get(`/api/admin/audit${qs({ q: state.q, page: state.page, pageSize: 50 })}`);
        clear(listEl);
        if (!data.items.length) {
          append(listEl, emptyState('暂无记录', 'audit'));
          return;
        }
        append(listEl,
          h('div', { class: 'table-wrap' }, h('table', { class: 'table' },
            h('thead', h('tr', ['时间', '操作', '对象', '详情', 'IP'].map((t) => h('th', t)))),
            h('tbody', data.items.map((item) => {
              const [label, kind] = ACTIONS[item.action] || [item.action, ''];
              return h('tr',
                h('td', { class: 'nowrap muted' }, fmtDate(item.at)),
                h('td', badge(label, kind)),
                h('td', h('span', { class: 'mono' }, item.target || '—')),
                h('td', { class: 'small', style: { maxWidth: '420px', overflowWrap: 'anywhere' } }, describe(item.detail) || h('span', { class: 'muted' }, '—')),
                h('td', h('span', { class: 'mono small muted' }, item.ip || '—')));
            })))),
          data.total > data.pageSize ? pager({ ...data, onChange: (p) => { state.page = p; load(); } }) : null);
      } catch (err) {
        toastError(err);
      }
    }
    load();
  },
};
