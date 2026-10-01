// Verifies every data-i18n / data-i18n-attr key has English, and every t('…') key
// used in JS has both languages (Chinese from ZH or from some page's HTML).
//   node dev/check-i18n.mjs
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

globalThis.localStorage = { getItem: () => null, setItem() {} };
if (!globalThis.navigator) globalThis.navigator = { language: 'zh-CN' };
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const { EN, ZH } = await import(join(root, 'assets/js/i18n.js'));

const htmlKeys = new Set();
for (const f of readdirSync(root).filter(f => f.endsWith('.html'))) {
  const h = readFileSync(join(root, f), 'utf8');
  for (const m of h.matchAll(/data-i18n="([^"]+)"/g)) htmlKeys.add(m[1]);
  for (const m of h.matchAll(/data-i18n-attr="([^"]+)"/g)) for (const p of m[1].split(',')) htmlKeys.add(p.split(':')[1].trim());
}
const jsKeys = new Set();
const dir = join(root, 'assets/js');
for (const f of readdirSync(dir).filter(f => f.endsWith('.js'))) {
  const s = readFileSync(join(dir, f), 'utf8');
  for (const m of s.matchAll(/\bt\('([\w.]*\w)'/g)) jsKeys.add(m[1]);
}
// keys built from templates in JS
for (const k of ['pending', 'paid', 'cancelled']) jsKeys.add('order.st.' + k);
for (const k of Object.keys(ZH)) jsKeys.add(k);

let bad = 0;
for (const k of htmlKeys) if (!(k in EN)) { console.log('missing EN for HTML key', k); bad++; }
for (const k of jsKeys) {
  if (!(k in EN)) { console.log('missing EN for JS key', k); bad++; }
  if (!(k in ZH) && !htmlKeys.has(k)) { console.log('missing ZH for JS key', k); bad++; }
}
for (const k of Object.keys(EN)) if (!htmlKeys.has(k) && !jsKeys.has(k)) console.log('unused EN key', k);
console.log(bad ? `${bad} problem(s)` : `ok: ${htmlKeys.size} HTML keys, ${jsKeys.size} JS keys`);
process.exit(bad ? 1 : 0);
