import { boot, getConfig, formatBytes, formatDate, escapeHTML } from './common.js?v=1.4';
import { t, onLangChange } from './i18n.js?v=1.4';

boot();

// Release notes are plain text or light Markdown: headings, bullets, **bold**, `code`.
export function renderNotes(src) {
  const inline = s => escapeHTML(s)
    .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    .replace(/`([^`]+)`/g, '<code>$1</code>');
  const out = [];
  let list = false;
  for (const raw of String(src || '').split(/\r?\n/)) {
    const line = raw.trim();
    const bullet = line.match(/^[-*•]\s+(.*)$/);
    if (bullet) {
      if (!list) { out.push('<ul>'); list = true; }
      out.push(`<li>${inline(bullet[1])}</li>`);
      continue;
    }
    if (list) { out.push('</ul>'); list = false; }
    const h = line.match(/^#{1,6}\s+(.*)$/);
    if (h) out.push(`<h4>${inline(h[1])}</h4>`);
    else if (line) out.push(`<p>${inline(line)}</p>`);
  }
  if (list) out.push('</ul>');
  return out.join('');
}

const btn = document.getElementById('dl-btn');
const label = document.getElementById('dl-label');
const meta = document.getElementById('dl-meta');
const box = document.getElementById('changelog-box');

btn.addEventListener('click', () => {
  if (btn.getAttribute('aria-disabled') === 'true') return;
  setTimeout(() => { document.getElementById('dl-after').hidden = false; }, 600);
});

async function render() {
  const cfg = await getConfig();
  const rel = cfg.latestRelease;

  if (cfg.live && !rel) {
    // Server reachable but nothing published yet.
    label.textContent = t('dl.soon');
    btn.setAttribute('aria-disabled', 'true');
    btn.removeAttribute('href');
    meta.innerHTML = `<span>${escapeHTML(t('dl.soonSub'))}</span>`;
    box.innerHTML = `<p class="muted">${escapeHTML(t('dl.noNotes'))}</p>`;
    return;
  }
  if (!rel) {
    meta.innerHTML = '';
    box.innerHTML = `<p class="muted">${escapeHTML(t('dl.notesFail'))}</p>`;
    return;
  }

  label.textContent = t('dl.btnVer', { v: rel.version });
  btn.href = rel.downloadUrl || '/download/latest';
  const icon = id => `<svg class="i" aria-hidden="true"><use href="/assets/img/icons.svg#${id}"/></svg>`;
  meta.innerHTML = [
    `<span>${icon('download')}${escapeHTML(t('dl.version', { v: rel.version, b: rel.build ?? '' }))}</span>`,
    rel.size ? `<span>${icon('large')}${escapeHTML(formatBytes(rel.size))}</span>` : '',
    `<span>${icon('menubar')}${escapeHTML(t('dl.minOS', { v: rel.minOS || '14.0' }))}</span>`,
    rel.publishedAt ? `<span>${icon('clock')}${escapeHTML(formatDate(rel.publishedAt))}</span>` : '',
  ].join('');
  box.innerHTML = `
    <h3>${escapeHTML(t('dl.version', { v: rel.version, b: rel.build ?? '' }))}${rel.publishedAt ? `<small>${escapeHTML(formatDate(rel.publishedAt))}</small>` : ''}</h3>
    <div class="notes">${rel.notes ? renderNotes(rel.notes) : `<p class="muted">${escapeHTML(t('dl.noNotes'))}</p>`}</div>`;
}

render();
onLangChange(render);
