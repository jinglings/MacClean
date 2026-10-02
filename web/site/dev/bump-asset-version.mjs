// 给所有 JS/CSS 引用加上版本号（?v=…），让 Cloudflare 等缓存在发布后立刻取到新文件。
// 用法：node dev/bump-asset-version.mjs 1.4
// 会改写：HTML 里的 /assets/js/*.js、/assets/css/*.css，以及 JS 模块之间的 import './x.js'。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const version = process.argv[2];
if (!version || !/^[\w.-]+$/.test(version)) {
  console.error('usage: node dev/bump-asset-version.mjs <version>');
  process.exit(1);
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = [
  ...fs.readdirSync(root).filter((f) => f.endsWith('.html')).map((f) => path.join(root, f)),
  ...fs.readdirSync(path.join(root, 'assets/js')).filter((f) => f.endsWith('.js')).map((f) => path.join(root, 'assets/js', f)),
  ...fs.readdirSync(path.join(root, 'dev/partials')).filter((f) => f.endsWith('.html')).map((f) => path.join(root, 'dev/partials', f)),
];

const v = `?v=${version}`;
let changed = 0;
for (const file of files) {
  const before = fs.readFileSync(file, 'utf8');
  const after = before
    // HTML: src="/assets/js/x.js" / href="/assets/css/x.css"（替换已有的 ?v=）
    .replace(/((?:src|href)="\/assets\/(?:js|css)\/[\w.-]+\.(?:js|css))(?:\?v=[\w.-]+)?"/g, `$1${v}"`)
    // JS: import … from './x.js'  /  import('./x.js')
    .replace(/(from\s+'\.\/[\w.-]+\.js)(?:\?v=[\w.-]+)?'/g, `$1${v}'`)
    .replace(/(import\(\s*'\.\/[\w.-]+\.js)(?:\?v=[\w.-]+)?'/g, `$1${v}'`);
  if (after !== before) {
    fs.writeFileSync(file, after);
    changed++;
  }
}
console.log(`asset version ${version}: updated ${changed} file(s)`);
