// Stamps dev/partials/{head,nav,footer}.html into every page between
// <!-- @name --> ... <!-- /@name --> markers. Run after editing a partial:
//   node dev/sync-partials.mjs
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const parts = ['head', 'nav', 'footer'];
const src = Object.fromEntries(parts.map(p => [p, readFileSync(join(root, 'dev/partials', p + '.html'), 'utf8').trim()]));

for (const file of readdirSync(root).filter(f => f.endsWith('.html'))) {
  let html = readFileSync(join(root, file), 'utf8');
  for (const p of parts) {
    const re = new RegExp(`([ \\t]*)<!-- @${p} -->[\\s\\S]*?<!-- /@${p} -->`);
    html = html.replace(re, (_, indent) =>
      `${indent}<!-- @${p} -->\n${src[p].split('\n').map(l => l ? indent + l : l).join('\n')}\n${indent}<!-- /@${p} -->`);
  }
  writeFileSync(join(root, file), html);
  console.log('synced', file);
}
