import { del, get, patch, post, upload } from '../api.js';
import { append, clear, fmtBytes, fmtDate, fmtInt, h, icon } from '../dom.js';
import { badge, busy, confirmDialog, copyButton, emptyState, modal, pageHead, skeletonRows, toast, toastError } from '../ui.js';

const MAX_BYTES = 500 * 1024 * 1024;

function urlRow(label, url) {
  return h('div', { class: 'field' }, h('span', label),
    h('div', { class: 'url-row' }, icon('link', 15), h('span', { class: 'mono' }, url), copyButton(url),
      h('a', { class: 'btn sm icon-only', href: url, target: '_blank', rel: 'noopener', title: '打开' }, icon('external', 15))));
}

function editDialog(r, onDone) {
  const build = h('input', { class: 'input', value: r.build });
  const minOS = h('input', { class: 'input', value: r.minOS });
  const sig = h('input', { class: 'input mono', value: r.edSignature || '', placeholder: 'sign_update 输出的 sparkle:edSignature' });
  const notes = h('textarea', { class: 'textarea', value: r.notes, style: { minHeight: '160px' } });
  const error = h('div', { class: 'form-error' });
  modal({
    title: `编辑 ${r.version}`,
    wide: true,
    content: h('div', { class: 'stack' },
      h('div', { class: 'grid-2' }, h('label', { class: 'field' }, h('span', 'Build'), build), h('label', { class: 'field' }, h('span', '最低系统版本'), minOS)),
      h('label', { class: 'field' }, h('span', 'EdDSA 签名 ', h('span', { class: 'hint' }, '有签名的版本才会出现在 appcast.xml')), sig),
      h('label', { class: 'field' }, h('span', '更新说明 ', h('span', { class: 'hint' }, '支持 # 标题、- 列表、**粗体**')), notes),
      error),
    actions: [
      { label: '取消', onClick: (close) => close() },
      {
        label: '保存', kind: 'primary',
        onClick: async (close) => {
          try {
            await patch(`/api/admin/releases/${r.id}`, { build: build.value.trim(), minOS: minOS.value.trim(), edSignature: sig.value.trim(), notes: notes.value });
            close();
            toast('已保存');
            onDone();
          } catch (err) {
            error.textContent = err.message;
          }
        },
      },
    ],
  });
}

export default {
  render(container) {
    let releases = [];
    let current = null; // in-flight upload
    const listEl = h('div');
    const urlsEl = h('div', { class: 'stack', style: { gap: '12px' } });

    // ----- Upload form -----
    const f = {
      version: h('input', { class: 'input', placeholder: '1.2.0', required: true }),
      build: h('input', { class: 'input', placeholder: '120', required: true }),
      minOS: h('input', { class: 'input', value: '14.0' }),
      edSignature: h('input', { class: 'input mono', placeholder: '可选：sign_update 输出的 sparkle:edSignature' }),
      notes: h('textarea', { class: 'textarea', placeholder: '# 新功能\n- …\n\n# 修复\n- …', style: { minHeight: '130px' } }),
      setLatest: h('input', { type: 'checkbox', checked: true }),
    };
    let file = null;
    const fileInput = h('input', { type: 'file', accept: '.dmg,application/x-apple-diskimage', class: 'hidden' });
    const dropLabel = h('div', { class: 'stack', style: { gap: '4px', alignItems: 'center' } });
    const drop = h('div', { class: 'dropzone', tabindex: 0, role: 'button', onclick: () => fileInput.click(), onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') fileInput.click(); } }, dropLabel);
    const progressBar = h('div');
    const progressText = h('span', { class: 'small muted' });
    const progress = h('div', { class: 'stack hidden', style: { gap: '6px' } },
      h('div', { class: 'progress' }, progressBar),
      h('div', { class: 'row' }, progressText, h('div', { class: 'grow' }),
        h('button', { class: 'btn sm', type: 'button', onclick: () => current?.abort() }, '取消上传')));
    const error = h('div', { class: 'form-error' });
    const submit = h('button', { class: 'btn primary', type: 'submit' }, icon('upload', 16), '上传并发布');

    const setFile = (picked) => {
      file = picked || null;
      error.textContent = '';
      drop.classList.toggle('has-file', Boolean(file));
      append(clear(dropLabel), file
        ? [icon('releases', 26), h('div', { style: { fontWeight: 650 } }, file.name), h('div', { class: 'small muted' }, `${fmtBytes(file.size)} · 点击更换`)]
        : [icon('upload', 26), h('div', { style: { fontWeight: 600 } }, '拖入 DMG 文件，或点击选择'), h('div', { class: 'small' }, '最大 500 MB')]);
      const m = file && /(\d+\.\d+(?:\.\d+)?)/.exec(file.name);
      if (m && !f.version.value) f.version.value = m[1];
    };
    setFile(null);
    fileInput.addEventListener('change', () => setFile(fileInput.files[0]));
    drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
    drop.addEventListener('dragleave', () => drop.classList.remove('over'));
    drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); setFile(e.dataTransfer.files[0]); });

    const form = h('form', {
      class: 'stack',
      onsubmit: async (e) => {
        e.preventDefault();
        error.textContent = '';
        const version = f.version.value.trim();
        if (!file) { error.textContent = '请选择 DMG 文件'; return; }
        if (!/\.dmg$/i.test(file.name)) { error.textContent = '只能上传 .dmg 文件'; return; }
        if (file.size > MAX_BYTES) { error.textContent = `文件超过 500 MB（${fmtBytes(file.size)}）`; return; }
        if (!version || !f.build.value.trim()) { error.textContent = '请填写版本号和 Build'; return; }
        if (releases.some((r) => r.version === version)) { error.textContent = `版本 ${version} 已存在，请先删除旧记录或换一个版本号`; return; }

        // Text fields go first so the server can reject a duplicate before the file streams.
        const data = new FormData();
        data.append('version', version);
        data.append('build', f.build.value.trim());
        data.append('minOS', f.minOS.value.trim() || '14.0');
        data.append('edSignature', f.edSignature.value.trim());
        data.append('notes', f.notes.value);
        data.append('setLatest', f.setLatest.checked ? '1' : '0');
        data.append('file', file, file.name);

        submit.disabled = true;
        progress.classList.remove('hidden');
        const started = performance.now();
        current = upload('/api/admin/releases', data, (loaded, total) => {
          const pct = (loaded / total) * 100;
          progressBar.style.width = `${pct.toFixed(1)}%`;
          const secs = (performance.now() - started) / 1000;
          const speed = loaded / Math.max(secs, 0.1);
          const eta = speed > 0 ? Math.max(0, (total - loaded) / speed) : 0;
          progressText.textContent = loaded >= total
            ? '上传完成，服务器正在校验文件…'
            : `${pct.toFixed(0)}% · ${fmtBytes(loaded)} / ${fmtBytes(total)} · ${fmtBytes(speed)}/s · 剩余约 ${Math.ceil(eta)} 秒`;
        });
        try {
          const { release } = await current.promise;
          toast(`版本 ${release.version} 已发布`);
          form.reset();
          f.minOS.value = '14.0';
          f.setLatest.checked = true;
          setFile(null);
          await load();
        } catch (err) {
          error.textContent = err.message;
        } finally {
          current = null;
          submit.disabled = false;
          progress.classList.add('hidden');
          progressBar.style.width = '0';
        }
      },
    },
    drop, fileInput,
    h('div', { class: 'grid-3' },
      h('label', { class: 'field' }, h('span', '版本号'), f.version),
      h('label', { class: 'field' }, h('span', 'Build ', h('span', { class: 'hint' }, 'CFBundleVersion')), f.build),
      h('label', { class: 'field' }, h('span', '最低系统版本'), f.minOS)),
    h('label', { class: 'field' }, h('span', 'EdDSA 签名 ', h('span', { class: 'hint' }, '没有签名的版本可以下载，但不会推送给 Sparkle 自动更新')), f.edSignature),
    h('label', { class: 'field' }, h('span', '更新说明'), f.notes),
    h('label', { class: 'check' }, f.setLatest, '设为最新版本（官网下载按钮指向它）'),
    progress, error,
    h('div', submit));

    append(container,
      pageHead('版本发布', '上传 DMG，自动生成 Sparkle appcast 和官网下载链接。'),
      h('div', { class: 'charts' },
        h('div', { class: 'card' }, h('div', { class: 'card-head' }, h('h3', { class: 'card-title' }, '上传新版本')), h('div', { class: 'card-pad' }, form)),
        h('div', { class: 'card' }, h('div', { class: 'card-head' }, h('h3', { class: 'card-title' }, '发布地址')),
          h('div', { class: 'card-pad stack' }, urlsEl,
            h('div', { class: 'small muted' }, '提示：用 Sparkle 的 ', h('span', { class: 'mono' }, 'bin/sign_update MacClean.dmg'),
              ' 生成 EdDSA 签名；App 的 SUFeedURL 应指向上面的 appcast 地址。')))),
      h('div', { class: 'card section-gap' }, h('div', { class: 'card-head' }, h('h3', { class: 'card-title' }, '全部版本')), listEl));

    function releaseRow(r) {
      return h('tr',
        h('td', h('div', { class: 'row' }, h('span', { class: 'release-version' }, r.version), r.isLatest ? badge('最新', 'ok') : null),
          h('div', { class: 'cell-sub' }, `Build ${r.build} · macOS ${r.minOS}+`)),
        h('td', { class: 'nowrap' }, fmtDate(r.publishedAt)),
        h('td', { class: 'nowrap' }, fmtBytes(r.size), h('div', { class: 'cell-sub mono', title: r.sha256 }, `sha256 ${r.sha256.slice(0, 10)}…`)),
        h('td', h('span', { class: 'amount', style: { fontSize: '15px' } }, fmtInt(r.downloads))),
        h('td', r.edSignature ? badge('已签名', 'ok') : badge('未签名', 'warn')),
        h('td', h('div', { class: 'actions' },
          r.isLatest ? null : h('button', {
            class: 'btn sm', title: '设为最新',
            onclick: busy(async () => { await post(`/api/admin/releases/${r.id}/latest`); toast(`${r.version} 已设为最新`); load(); }),
          }, icon('star', 15), '设为最新'),
          h('button', { class: 'btn sm icon-only', title: '编辑', 'aria-label': '编辑', onclick: () => editDialog(r, load) }, icon('edit', 15)),
          h('a', { class: 'btn sm icon-only', href: `/files/releases/${encodeURIComponent(r.fileName)}`, title: '下载', 'aria-label': '下载' }, icon('download', 15)),
          h('button', {
            class: 'btn sm danger icon-only', title: '删除', 'aria-label': '删除',
            onclick: busy(async () => {
              const ok = await confirmDialog({
                title: `删除 ${r.version}`, danger: true, confirmText: '删除',
                message: `会删除 DMG 文件和这条记录（已下载 ${r.downloads} 次）。${r.isLatest ? '这是当前最新版本，删除后官网会改为下载其余版本中最新发布的一个。' : ''}`,
              });
              if (!ok) return;
              await del(`/api/admin/releases/${r.id}`);
              toast('已删除');
              load();
            }),
          }, icon('trash', 15)))));
    }

    async function load() {
      if (!listEl.firstChild) append(listEl, skeletonRows(3));
      try {
        const data = await get('/api/admin/releases');
        releases = data.items;
        append(clear(urlsEl), urlRow('Sparkle appcast', data.appcastUrl), urlRow('官网下载（最新版）', data.downloadUrl));
        append(clear(listEl), releases.length
          ? h('div', { class: 'table-wrap' }, h('table', { class: 'table' },
            h('thead', h('tr', ['版本', '发布时间', '大小', '下载次数', 'Sparkle', ''].map((t) => h('th', t)))),
            h('tbody', releases.map(releaseRow))))
          : emptyState('还没有发布版本', 'releases', '上传第一个 DMG 后，官网下载按钮就会生效'));
      } catch (err) {
        toastError(err);
      }
    }
    load();
    return () => current?.abort();
  },
};
