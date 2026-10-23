// Generate crawlable metadata from the visible Chinese HTML. Run after copy edits.
// --check verifies committed output without changing files.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const { EN } = await import('../assets/js/i18n.js');
const { buildGuides, guideFiles } = await import('./build-guides.mjs');
const root = new URL('../', import.meta.url);
const origin = 'https://thulem.com';
const pages = ['index.html', 'download.html', 'support.html', 'privacy.html', 'terms.html'];
const check = process.argv.includes('--check');
let stale = false;
const generated = new Map();
const read = name => generated.get(name) ?? readFileSync(new URL(name, root), 'utf8');
const queue = (name, value) => generated.set(name, value);
function output(name, value) {
  let previous;
  try { previous = readFileSync(new URL(name, root), 'utf8'); } catch { /* new output */ }
  if (value === previous) return;
  if (check) { console.error('SEO output needs regeneration:', name); stale = true; }
  else { mkdirSync(new URL('.', new URL(name, root)), { recursive: true }); writeFileSync(new URL(name, root), value); }
}
const text = html => html.replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ').trim();
const escape = value => value.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
const url = file => origin + '/' + file.replace(/(^|\/)index\.html$/, '$1');
for (const [file, html] of buildGuides(EN)) queue(file, html);
for (const file of pages) {
  let html = read(file).replace(/\n  <!-- @seo -->[\s\S]*?<!-- \/@seo -->/g, '');
  html = html.replace(/<html[^>]*>/, '<html lang="zh-CN" data-site-locale="zh">');
  html = html.replace(/(<a class="lang-btn" href=")[^"]+/, '$1' + new URL(url('en/' + file)).pathname);
  queue(file, html);
  const english = execFileSync('python3', [fileURLToPath(new URL('dev/render-language.py', root))], { input: JSON.stringify({ html, translations: EN, chinese_url: new URL(url(file)).pathname, public_paths: guideFiles.map(g => new URL(url(g)).pathname) }), encoding: 'utf8' });
  queue('en/' + file, english);
}
const chinesePages = [...pages, ...guideFiles];
const allPages = [...chinesePages, ...chinesePages.map(file => 'en/' + file)];
for (const file of allPages) {
  const isEnglish = file.startsWith('en/');
  const counterpart = isEnglish ? file.slice(3) : 'en/' + file;
  let html = read(file).replace(/\n  <!-- @seo -->[\s\S]*?<!-- \/@seo -->/g, '');
  // The SEO block owns page-specific Open Graph fields; shared image stays in head partial.
  html = html.replace(/^  <meta property="og:(?:title|description)"[^>]*>\n/gm, '');
  const titleMatch = html.match(/<title([^>]*)>(.*?)<\/title>/s);
  const descMatch = html.match(/<meta name="description" content="([^"]*)"([^>]*)>/);
  const title = text(titleMatch[2]);
  const description = text(descMatch[1]);
  const titleKey = titleMatch[1].match(/data-i18n="([^"]+)"/)?.[1];
  const descKey = descMatch[2].match(/content:([^" ,]+)/)?.[1];
  const graph = [{ '@type': 'WebSite', '@id': origin + '/#website', url: origin + '/', name: 'MacClean' }, {
    '@type': 'WebPage', '@id': url(file) + '#webpage', url: url(file), name: title,
    description, inLanguage: isEnglish ? 'en' : 'zh-CN', isPartOf: { '@id': origin + '/#website' }
  }];
  if (file === 'index.html' || file === 'en/index.html') graph.push({
    '@type': 'SoftwareApplication', '@id': origin + '/#software', name: 'MacClean',
    url: url(file), applicationCategory: 'UtilitiesApplication', operatingSystem: 'macOS 14.0 or later',
    description, downloadUrl: origin + (isEnglish ? '/en/download.html' : '/download.html'), image: origin + '/assets/img/icon-512.png',
    featureList: isEnglish ? ['WeChat, QQ and WeCom media cleanup', 'Disk space analysis and storage map', 'Developer cache and local AI model cleanup', 'App removal and leftover review', 'Duplicate files and similar photos'] : ['微信、QQ 与企业微信媒体清理', '磁盘空间分析与存储地图', '开发缓存与本地 AI 模型清理', '应用卸载与残留检查', '重复文件与相似照片整理'],
    mainEntityOfPage: { '@id': url(file) + '#webpage' }
  });
  const faqs = [...html.matchAll(/<details><summary[^>]*>([\s\S]*?)<\/summary><div class="ans">([\s\S]*?)<\/div><\/details>/g)].map(m => ({
      '@type': 'Question', name: text(m[1]), acceptedAnswer: { '@type': 'Answer', text: text(m[2]) }
    }));
  if (faqs.length) {
    graph[1]['@type'] = 'FAQPage';
    graph[1].mainEntity = faqs;
  }
  if (file.includes('guides/')) {
    const english = file.startsWith('en/');
    const hub = origin + (english ? '/en/guides/' : '/guides/');
    const crumbs = [{ '@type': 'ListItem', position: 1, name: english ? 'Home' : '首页', item: origin + (english ? '/en/' : '/') }, { '@type': 'ListItem', position: 2, name: english ? 'Cleanup guides' : '清理指南', item: hub }];
    if (url(file) !== hub) crumbs.push({ '@type': 'ListItem', position: 3, name: title, item: url(file) });
    const breadcrumb = { '@type': 'BreadcrumbList', '@id': url(file) + '#breadcrumb', itemListElement: crumbs };
    graph[1].breadcrumb = { '@id': breadcrumb['@id'] };
    graph.push(breadcrumb);
  }
  const fields = [
    `<link rel="canonical" href="${url(file)}">`,
    `<link rel="alternate" hreflang="zh-CN" href="${url(isEnglish ? counterpart : file)}">`,
    `<link rel="alternate" hreflang="en" href="${url(isEnglish ? file : counterpart)}">`,
    `<link rel="alternate" hreflang="x-default" href="${url(isEnglish ? counterpart : file)}">`,
    '<meta name="robots" content="index, follow, max-image-preview:large">',
    `<meta property="og:url" content="${url(file)}">`,
    '<meta property="og:type" content="website">',
    `<meta property="og:title" content="${escape(title)}"${titleKey ? ` data-i18n-attr="content:${titleKey}"` : ''}>`,
    `<meta property="og:description" content="${escape(description)}"${descKey ? ` data-i18n-attr="content:${descKey}"` : ''}>`,
    '<meta name="twitter:card" content="summary">',
    '<link rel="alternate" type="text/plain" href="/llms.txt" title="MacClean product information">',
    `<script type="application/ld+json">${JSON.stringify({ '@context': 'https://schema.org', '@graph': graph }).replace(/</g, '\\u003c')}</script>`
  ];
  html = html.replace('</head>', `  <!-- @seo -->\n${fields.map(f => '  ' + f).join('\n')}\n  <!-- /@seo -->\n</head>`);
  queue(file, html);
}
for (const [file, html] of generated) output(file, html);
output('sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${allPages.map(file => `  <url><loc>${url(file)}</loc></url>`).join('\n')}\n</urlset>\n`);
// One wildcard group also covers Googlebot, Bingbot and OAI-SearchBot.
// Do not add an AI-specific Allow group that bypasses these exclusions.
output('robots.txt', `User-agent: *\nAllow: /\nDisallow: /admin\nDisallow: /api/\nDisallow: /dev/\nDisallow: /files/\nDisallow: /download/\n\nSitemap: ${origin}/sitemap.xml\n`);
if (stale) process.exitCode = 1;
else console.log(check ? 'SEO output is current.' : 'SEO output generated.');
