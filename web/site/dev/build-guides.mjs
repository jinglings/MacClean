// Guide copy is reviewed in seo-guides.json; public pages contain no source paths.
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);
const esc = value => String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const paragraph = value => `<p>${esc(value)}</p>`;
export const guides = JSON.parse(readFileSync(new URL('dev/seo-guides.json', root), 'utf8'));
export const guideFiles = ['guides/index.html', ...guides.map(g => `guides/${g.slug}.html`)];
const shots = { 'mac-system-data-cleanup': 'disk_analysis', 'wechat-storage-cleanup': 'chat_cleanup', 'xcode-cache-cleanup': 'developer_tools' };

export function buildGuides(translations) {
  const outputs = new Map();
  const partial = name => readFileSync(new URL(`dev/partials/${name}.html`, root), 'utf8').trim();
  const publicPaths = guideFiles.map(file => '/' + file.replace(/index\.html$/, ''));
  const shell = (file, locale, copy, body) => {
    let html = `<!doctype html>
<html lang="${locale === 'en' ? 'en' : 'zh-CN'}" data-site-locale="${locale}">
<head>
  <meta charset="utf-8">
  <title>${esc(copy.title)}</title>
  <meta name="description" content="${esc(copy.description)}">
${partial('head')}
</head>
<body>
${partial('nav')}
<main id="main">${body}</main>
${partial('footer')}
<script type="module" src="/assets/js/page.js?v=20261007.1"></script>
</body>
</html>
`;
    if (locale === 'en') html = execFileSync('python3', [fileURLToPath(new URL('dev/render-language.py', root))], {
      input: JSON.stringify({html, translations, chinese_url: '/' + file.replace(/index\.html$/, ''), public_paths: publicPaths}), encoding: 'utf8'
    });
    else html = html.replace(/(<a class="lang-btn" href=")[^"]+/, '$1/en/' + file.replace(/index\.html$/, ''));
    return html;
  };
  for (const locale of ['zh', 'en']) {
    const english = locale === 'en';
    const label = english ? {home:'Home', hub:'Cleanup guides', contents:'On this page', related:'Related guides', faq:'Questions about cleanup', sources:'References', download:'Download MacClean', support:'Installation and common questions', note:'MacClean interface. File sizes shown are illustrative; your scan results will differ.'} : {home:'首页', hub:'清理指南', contents:'本页内容', related:'继续阅读', faq:'常见问题', sources:'参考资料', download:'下载 MacClean', support:'安装说明与常见问题', note:'MacClean 界面示例。图中大小仅作界面展示，以你的实际扫描结果为准。'};
    const prefix = english ? 'en/' : '';
    const copy = english ? {title:'Mac Cleanup Guides: System Data, WeChat & Xcode | MacClean', description:'Practical Mac storage guides: understand System Data, review WeChat media and clean Xcode caches. Steps, screenshots and recovery limits before you delete.', h1:'Mac storage cleanup guides', intro:'Start with the problem you see. Each guide explains what to inspect, how to review it in MacClean and which data to keep.'} : {title:'Mac 清理指南：系统数据、微信空间与 Xcode 缓存 - MacClean', description:'Mac 空间不足先查什么？查看系统数据、微信媒体与 Xcode 缓存的清理步骤、界面示例和恢复限制，确认文件用途后再删除。', h1:'Mac 磁盘空间与清理指南', intro:'从你遇到的问题开始。每篇指南说明先查什么、如何在 MacClean 中查看，以及哪些数据应该保留。'};
    const list = guides.map(g => `<li><h2><a href="/guides/${g.slug}.html">${esc(g[locale].h1)}</a></h2>${paragraph(g[locale].description)}</li>`).join('\n');
    const hubBody = `<section class="page-hero"><div class="wrap"><h1>${esc(copy.h1)}</h1>${paragraph(copy.intro)}</div></section><div class="wrap"><div class="doc guide"><ul class="guide-list">${list}</ul><p><a href="/download.html">${label.download}</a> · <a href="/support.html">${label.support}</a></p></div></div>`;
    outputs.set(prefix + 'guides/index.html', shell('guides/index.html', locale, copy, hubBody));
    for (const g of guides) {
      const c = g[locale];
      const contents = c.sections.map(s => `<li><a href="#${esc(s.id)}">${esc(s.title)}</a></li>`).join('');
      const sections = c.sections.map(s => `<section id="${esc(s.id)}"><h2>${esc(s.title)}</h2>${s.paragraphs.map(paragraph).join('\n')}${s.steps?.length ? '<ol>' + s.steps.map(step => '<li>' + esc(step) + '</li>').join('') + '</ol>' : ''}</section>`).join('\n');
      const faq = c.faq.map(q => `<details><summary>${esc(q.q)}</summary><div class="ans">${paragraph(q.a)}</div></details>`).join('\n');
      const related = guides.filter(other => other.slug !== g.slug).map(other => `<li><a href="/guides/${other.slug}.html">${esc(other[locale].h1)}</a></li>`).join('');
      const sources = c.sources?.length ? `<section><h2>${label.sources}</h2><ul>${c.sources.map(s => `<li><a href="${esc(s.url)}">${esc(s.label)}</a></li>`).join('')}</ul></section>` : '';
      const body = `<section class="page-hero guide-hero"><div class="wrap"><nav class="breadcrumbs" aria-label="${english ? 'Breadcrumb' : '当前位置'}"><a href="/">${label.home}</a><span>/</span><a href="/guides/">${label.hub}</a></nav><h1>${esc(c.h1)}</h1>${paragraph(c.intro)}</div></section>
<div class="wrap"><article class="doc guide"><nav class="guide-toc" aria-label="${label.contents}"><strong>${label.contents}</strong><ol>${contents}</ol></nav>
<figure class="guide-shot"><img src="/assets/img/screens/native/light-${locale}-${shots[g.slug]}.webp" width="1600" height="1030" alt="${esc(c.h1)} — MacClean" decoding="async" loading="lazy"><figcaption>${label.note}</figcaption></figure>
${sections}<section><h2>${label.faq}</h2><div class="faq">${faq}</div></section>${sources}
<section class="guide-cta"><h2>${label.download}</h2>${paragraph(c.cta)}<p><a class="btn btn-primary" href="/download.html">${label.download}</a></p><p><a href="/support.html">${label.support}</a></p></section>
<aside><h2>${label.related}</h2><ul>${related}</ul></aside></article></div>`;
      const file = `guides/${g.slug}.html`;
      outputs.set(prefix + file, shell(file, locale, c, body));
    }
  }
  return outputs;
}
