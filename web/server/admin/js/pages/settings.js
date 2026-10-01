import { del, get, post, put, upload } from '../api.js';
import { append, clear, h, icon } from '../dom.js';
import { busy, confirmDialog, pageHead, skeletonRows, toast, toastError } from '../ui.js';

const lines = (text) => text.split('\n').map((s) => s.trim()).filter(Boolean);

function section(title, sub, body, footer) {
  return h('div', { class: 'card section-gap' },
    h('div', { class: 'card-head' }, h('div', h('h3', { class: 'card-title' }, title), sub ? h('div', { class: 'card-sub' }, sub) : null), footer || null),
    h('div', { class: 'card-pad' }, body));
}

export default {
  render(container) {
    const body = h('div', skeletonRows(4, 80));
    append(container, pageHead('设置', '套餐价格、收款方式和官网信息。修改后官网最多 1 分钟内生效。'), body);

    async function load() {
      try {
        const s = await get('/api/admin/settings');
        append(clear(body), plansSection(s), paymentSection(s), siteSection(s), securitySection(s));
      } catch (err) {
        toastError(err);
      }
    }

    // ----- Plans -----
    function plansSection(s) {
      const plans = s.plans.map((p) => ({ ...p }));
      const grid = h('div', { class: 'plans-grid' });

      const planCard = (p, index) => {
        const bind = (key, transform = (v) => v) => (e) => { p[key] = transform(e.target.value); };
        const card = h('div', { class: ['plan-card', p.highlight && 'highlight'] },
          h('div', { class: 'stack', style: { gap: '12px' } },
            h('div', { class: 'row' },
              h('span', { class: 'badge teal plain mono' }, p.id || '新套餐'),
              h('div', { class: 'grow' }),
              h('label', { class: 'check small' }, h('input', {
                type: 'checkbox', checked: Boolean(p.highlight),
                onchange: (e) => { p.highlight = e.target.checked; card.classList.toggle('highlight', p.highlight); },
              }), '推荐'),
              h('button', {
                class: 'btn sm ghost icon-only', title: '删除套餐', 'aria-label': '删除套餐', disabled: plans.length <= 1,
                onclick: () => { plans.splice(index, 1); render(); },
              }, icon('trash', 15))),
            h('div', { class: 'grid-2' },
              h('label', { class: 'field' }, h('span', '名称'), h('input', { class: 'input', value: p.name, oninput: bind('name') })),
              h('label', { class: 'field' }, h('span', '英文名称'), h('input', { class: 'input', value: p.nameEn || '', oninput: bind('nameEn') }))),
            h('div', { class: 'grid-3' },
              h('label', { class: 'field' }, h('span', '价格（元）'), h('input', { class: 'input', type: 'number', min: 0.01, step: 0.01, value: String(p.price), oninput: bind('price', Number) })),
              h('label', { class: 'field' }, h('span', '设备数'), h('input', { class: 'input', type: 'number', min: 1, max: 100, value: String(p.devices), oninput: bind('devices', Number) })),
              h('label', { class: 'field' }, h('span', 'ID'), h('input', { class: 'input mono', value: p.id, readOnly: Boolean(p.persisted), title: p.persisted ? '已有订单引用，ID 不可修改' : '', oninput: bind('id', (v) => v.trim().toLowerCase()) }))),
            h('label', { class: 'field' }, h('span', '功能列表 ', h('span', { class: 'hint' }, '每行一条')),
              h('textarea', { class: 'textarea', value: (p.features || []).join('\n'), style: { minHeight: '96px' }, oninput: (e) => { p.features = lines(e.target.value); } })),
            h('label', { class: 'field' }, h('span', '功能列表（英文）'),
              h('textarea', { class: 'textarea', value: (p.featuresEn || []).join('\n'), style: { minHeight: '96px' }, oninput: (e) => { p.featuresEn = lines(e.target.value); } }))));
        return card;
      };

      plans.forEach((p) => { p.persisted = true; });
      const render = () => append(clear(grid), ...plans.map(planCard));
      render();

      const save = h('button', {
        class: 'btn primary',
        onclick: busy(async () => {
          const payload = plans.map(({ persisted, ...p }) => p);
          await put('/api/admin/settings', { plans: payload });
          toast('套餐已保存');
          load();
        }),
      }, '保存套餐');
      const add = h('button', {
        class: 'btn',
        onclick: () => {
          plans.push({ id: '', name: '', nameEn: '', price: 98, devices: 1, features: [], featuresEn: [], highlight: false });
          render();
        },
      }, icon('plus', 16), '添加套餐');
      return section('套餐', '修改价格只影响之后的新订单。', h('div', { class: 'stack' }, grid, h('div', { class: 'row' }, add, h('div', { class: 'grow' }), save)));
    }

    // ----- Payment -----
    function qrTile(kind, label, src) {
      const input = h('input', { type: 'file', accept: 'image/png,image/jpeg', class: 'hidden' });
      const status = h('div', { class: 'small muted' }, src ? '已上传' : '未上传，官网将不显示该支付方式');
      input.addEventListener('change', async () => {
        const file = input.files[0];
        input.value = '';
        if (!file) return;
        if (file.size > 2 * 1024 * 1024) { toastError(new Error('图片不能超过 2 MB')); return; }
        const data = new FormData();
        data.append('file', file, file.name);
        status.textContent = '上传中…';
        try {
          await upload(`/api/admin/settings/qr/${kind}`, data).promise;
          toast(`${label}收款码已更新`);
          load();
        } catch (err) {
          status.textContent = '';
          toastError(err);
        }
      });
      return h('div', { class: 'qr-tile' },
        h('div', { class: 'qr-preview' }, src ? h('img', { src, alt: `${label}收款码` }) : h('div', { class: 'stack', style: { alignItems: 'center', gap: '4px' } }, icon('image', 22), '暂无')),
        h('div', { class: 'stack', style: { gap: '8px' } },
          h('div', { class: ['pay', kind], style: { fontSize: '15px' } }, h('i'), `${label}收款码`),
          status,
          h('div', { class: 'row wrap' },
            h('button', { class: 'btn sm', onclick: () => input.click() }, icon('upload', 15), src ? '替换' : '上传'),
            src ? h('button', {
              class: 'btn sm danger',
              onclick: busy(async () => {
                if (!(await confirmDialog({ title: `删除${label}收款码`, message: '删除后官网下单页将不再提供这种支付方式。', danger: true, confirmText: '删除' }))) return;
                await del(`/api/admin/settings/qr/${kind}`);
                toast('已删除');
                load();
              }),
            }, '删除') : null),
          h('div', { class: 'small muted' }, 'PNG / JPG，≤ 2 MB'),
          input));
    }

    function paymentSection(s) {
      const instructions = h('textarea', { class: 'textarea', value: s.paymentInstructions, style: { minHeight: '100px' } });
      return section('收款方式', '买家扫码付款并在备注中填写付款码，你在「订单」中核对后确认。',
        h('div', { class: 'stack' },
          h('div', { class: 'qr-grid' }, qrTile('wechat', '微信', s.wechatQr), qrTile('alipay', '支付宝', s.alipayQr)),
          h('label', { class: 'field' }, h('span', '付款说明 ', h('span', { class: 'hint' }, '显示在官网下单页')), instructions),
          h('div', h('button', {
            class: 'btn primary',
            onclick: busy(async () => { await put('/api/admin/settings', { paymentInstructions: instructions.value }); toast('付款说明已保存'); }),
          }, '保存付款说明'))));
    }

    // ----- Site -----
    function siteSection(s) {
      const email = h('input', { class: 'input', type: 'email', value: s.contactEmail, placeholder: 'support@thulem.com' });
      const announcement = h('textarea', { class: 'textarea', value: s.announcement, placeholder: '留空则不显示', style: { minHeight: '70px' } });
      return section('官网信息', null,
        h('div', { class: 'stack' },
          h('label', { class: 'field' }, h('span', '联系邮箱'), email),
          h('label', { class: 'field' }, h('span', '站点公告 ', h('span', { class: 'hint' }, '显示在官网顶部，例如活动或维护通知')), announcement),
          h('div', h('button', {
            class: 'btn primary',
            onclick: busy(async () => {
              await put('/api/admin/settings', { contactEmail: email.value.trim(), announcement: announcement.value });
              toast('已保存');
            }),
          }, '保存'))));
    }

    // ----- Security -----
    function securitySection(s) {
      if (s.passwordFromEnv) {
        return section('管理员密码', null, h('div', { class: 'row muted' }, icon('shield', 18),
          '密码由服务器环境变量 ADMIN_PASSWORD_HASH 设置，如需修改请更新 /etc/macclean-server.env 后重启服务。'));
      }
      const current = h('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const next = h('input', { class: 'input', type: 'password', autocomplete: 'new-password', minlength: 10 });
      const confirm = h('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
      const error = h('div', { class: 'form-error' });
      return section('管理员密码', '修改后其他已登录的浏览器会被登出。',
        h('div', { class: 'stack', style: { maxWidth: '760px' } },
          h('div', { class: 'grid-3' },
            h('label', { class: 'field' }, h('span', '当前密码'), current),
            h('label', { class: 'field' }, h('span', '新密码（至少 10 位）'), next),
            h('label', { class: 'field' }, h('span', '确认新密码'), confirm)),
          error,
          h('div', h('button', {
            class: 'btn primary',
            onclick: busy(async () => {
              error.textContent = '';
              if (next.value !== confirm.value) { error.textContent = '两次输入的新密码不一致'; return; }
              try {
                await post('/api/admin/password', { current: current.value, next: next.value });
              } catch (err) {
                error.textContent = err.message;
                return;
              }
              current.value = next.value = confirm.value = '';
              toast('密码已修改');
            }),
          }, '修改密码'))));
    }

    load();
  },
};
