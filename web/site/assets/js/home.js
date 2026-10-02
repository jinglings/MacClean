import { boot, reducedMotion, getConfig, planName, planFeatures, money, escapeHTML, updateShot } from './common.js?v=1.4';
import { t, getLang, onLangChange } from './i18n.js?v=1.4';

boot();

const motionOK = () => !reducedMotion.matches;
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

/* ================= hero ================= */

const hero = document.getElementById('hero');
requestAnimationFrame(() => requestAnimationFrame(() => hero.classList.add('ready')));

// Window straightens as you scroll; chips drift at different depths.
const tilt = document.getElementById('hero-tilt');
const chips = [...hero.querySelectorAll('.chip')];
let ticking = false;
function onHeroScroll() {
  ticking = false;
  if (!motionOK()) { tilt.style.setProperty('--t', 0); return; }
  const y = scrollY;
  const span = Math.max(1, tilt.getBoundingClientRect().top + y - innerHeight * .25);
  tilt.style.setProperty('--t', (1 - clamp(y / span, 0, 1)).toFixed(4));
  if (y < innerHeight * 1.5) chips.forEach(c => c.style.setProperty('--py', (-y * .18 * Number(c.dataset.depth || 1)).toFixed(1)));
}
addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(onHeroScroll); } }, { passive: true });
addEventListener('resize', onHeroScroll);
onHeroScroll();
reducedMotion.addEventListener('change', onHeroScroll);

// Four-point sparkles, echoing the app icon.
(function sparkles() {
  const canvas = document.getElementById('sparkles');
  if (!canvas || !motionOK()) return;
  const ctx = canvas.getContext('2d');
  let w = 0, h = 0, dpr = 1, stars = [], running = false, raf = 0, visible = true;

  function resize() {
    dpr = Math.min(devicePixelRatio || 1, 2);
    w = canvas.clientWidth; h = canvas.clientHeight;
    canvas.width = w * dpr; canvas.height = h * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const n = Math.round(clamp(w * h / 26000, 18, 60));
    stars = Array.from({ length: n }, () => ({
      x: Math.random() * w, y: Math.random() * h,
      r: 1.5 + Math.random() * Math.random() * 6,
      v: .05 + Math.random() * .18,
      p: Math.random() * Math.PI * 2,
      s: .4 + Math.random() * 1.2,
    }));
  }
  function star(x, y, r, a) {
    ctx.globalAlpha = a;
    ctx.beginPath();
    ctx.moveTo(x, y - r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.quadraticCurveTo(x, y, x, y + r);
    ctx.quadraticCurveTo(x, y, x - r, y);
    ctx.quadraticCurveTo(x, y, x, y - r);
    ctx.fill();
  }
  function frame(ts) {
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = '#E6FFF6';
    const time = ts / 1000;
    for (const s of stars) {
      s.y -= s.v;
      if (s.y < -10) { s.y = h + 10; s.x = Math.random() * w; }
      const tw = (Math.sin(time * s.s + s.p) + 1) / 2;
      star(s.x, s.y, s.r * (.6 + tw * .5), .12 + tw * .55);
    }
    raf = requestAnimationFrame(frame);
  }
  function update() {
    const want = visible && !document.hidden && motionOK();
    if (want && !running) { running = true; raf = requestAnimationFrame(frame); }
    if (!want && running) { running = false; cancelAnimationFrame(raf); }
  }
  resize();
  addEventListener('resize', resize);
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; update(); }).observe(hero);
  document.addEventListener('visibilitychange', update);
  reducedMotion.addEventListener('change', () => { update(); if (!motionOK()) ctx.clearRect(0, 0, w, h); });
})();

/* ================= storage ring ================= */

const RING = [
  { key: 'photos', color: '#F2709C', kids: [['photoLib', 168], ['movies', 46]] },
  { key: 'dev', color: '#F5B342', kids: [['derived', 48], ['sims', 39], ['nodeModules', 37], ['docker', 32]] },
  { key: 'docs', color: '#4C8DF6', kids: [['documents', 92], ['downloads', 41]] },
  { key: 'apps', color: '#8E7CFF', kids: [['xcode', 41], ['creative', 33], ['otherApps', 54]] },
  { key: 'system', color: '#9AA5B8', kids: [['macos', 68], ['snapshots', 28]] },
  { key: 'chat', color: '#1CC88A', kids: [['wechat', 44], ['qq', 18]] },
  { key: 'caches', color: '#4FC3D9', kids: [['appCache', 22], ['browserCache', 8], ['logs', 4]] },
];
const FREE = 171.7;
for (const c of RING) c.size = c.kids.reduce((a, [, s]) => a + s, 0);
const TOTAL = RING.reduce((a, c) => a + c.size, 0) + FREE;

const svg = document.getElementById('ring-svg');
const ringBox = document.getElementById('ring');
const legend = document.getElementById('ring-legend');
const rcSize = document.getElementById('rc-size');
const rcName = document.getElementById('rc-name');
const rcHint = document.getElementById('rc-hint');
const NS = 'http://www.w3.org/2000/svg';
const segs = [];

const gb = v => `${v.toFixed(1).replace(/\.0$/, '')} GB`;

function arcPath(r0, r1, a0, a1) {
  if (a1 - a0 < .0005) return '';
  const large = a1 - a0 > Math.PI ? 1 : 0;
  const p = (r, a) => `${(r * Math.cos(a)).toFixed(2)} ${(r * Math.sin(a)).toFixed(2)}`;
  return `M${p(r1, a0)}A${r1} ${r1} 0 ${large} 1 ${p(r1, a1)}L${p(r0, a1)}A${r0} ${r0} 0 ${large} 0 ${p(r0, a0)}Z`;
}

function buildRing() {
  const start = -Math.PI / 2, gap = .006;
  let a = start;
  const add = (cfg) => {
    const el = document.createElementNS(NS, 'path');
    el.setAttribute('fill', cfg.fill);
    if (cfg.opacity) el.setAttribute('fill-opacity', cfg.opacity);
    if (cfg.interactive) {
      el.setAttribute('tabindex', '0');
      el.setAttribute('role', 'img');
    }
    svg.append(el);
    segs.push({ el, ...cfg });
    return segs[segs.length - 1];
  };
  for (const c of RING) {
    const span = c.size / TOTAL * Math.PI * 2;
    add({ r0: 96, r1: 142, a0: a + gap, a1: a + span - gap, fill: c.color, interactive: true, cat: c, nameKey: `ring.c.${c.key}`, size: c.size });
    let b = a;
    c.kids.forEach(([k, s], i) => {
      const ks = s / TOTAL * Math.PI * 2;
      add({ r0: 148, r1: 196, a0: b + gap, a1: b + ks - gap, fill: c.color, opacity: i % 2 ? .62 : .82, interactive: true, cat: c, nameKey: `ring.k.${k}`, size: s, kid: true });
      b += ks;
    });
    a += span;
  }
  // free space: a quiet track
  add({ r0: 96, r1: 142, a0: a + gap, a1: start + Math.PI * 2 - gap, fill: 'currentColor', opacity: .08, interactive: true, nameKey: 'ring.c.free', size: FREE, free: true });
  svg.style.color = 'var(--text)';

  for (const s of segs) {
    if (!s.interactive) continue;
    const on = () => focusSeg(s);
    s.el.addEventListener('pointerenter', on);
    s.el.addEventListener('focus', on);
    s.el.addEventListener('pointerleave', clearSeg);
    s.el.addEventListener('blur', clearSeg);
  }
  svg.addEventListener('keydown', e => {
    if (!['ArrowRight', 'ArrowLeft', 'ArrowDown', 'ArrowUp'].includes(e.key)) return;
    const list = segs.filter(s => s.interactive);
    const i = list.findIndex(s => s.el === document.activeElement);
    const next = list[(i + (e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : -1) + list.length) % list.length];
    next.el.focus();
    e.preventDefault();
  });
}

function drawRing(progress) {
  const start = -Math.PI / 2;
  const ease = 1 - Math.pow(1 - progress, 3);
  for (const s of segs) {
    const a0 = start + (s.a0 - start) * ease, a1 = start + (s.a1 - start) * ease;
    s.el.setAttribute('d', arcPath(s.r0, s.r1, a0, a1));
  }
}

function labelRing() {
  for (const s of segs) if (s.interactive) s.el.setAttribute('aria-label', `${t(s.nameKey)}: ${gb(s.size)}`);
  legend.innerHTML = '';
  for (const c of RING) {
    const li = document.createElement('li');
    li.innerHTML = `<i style="background:${c.color}"></i><span>${escapeHTML(t(`ring.c.${c.key}`))}</span><em>${gb(c.size)}</em>`;
    li.addEventListener('pointerenter', () => focusSeg(segs.find(s => s.cat === c && !s.kid)));
    li.addEventListener('pointerleave', clearSeg);
    c.li = li;
    legend.append(li);
  }
  const li = document.createElement('li');
  li.innerHTML = `<i style="background:var(--line-2)"></i><span>${escapeHTML(t('ring.c.free'))}</span><em>${gb(FREE)}</em>`;
  legend.append(li);
  clearSeg();
}

function focusSeg(s) {
  if (!s) return;
  ringBox.classList.add('hovering');
  for (const o of segs) o.el.classList.toggle('hot', o === s || (!s.kid && !s.free && o.cat === s.cat));
  for (const c of RING) c.li?.classList.toggle('hot', c === s.cat);
  rcSize.textContent = gb(s.size);
  rcName.textContent = s.kid ? `${t(`ring.c.${s.cat.key}`)} › ${t(s.nameKey)}` : t(s.nameKey);
  rcHint.textContent = `${Math.round(s.size / TOTAL * 1000) / 10}%`;
}
function clearSeg() {
  ringBox.classList.remove('hovering');
  for (const o of segs) o.el.classList.remove('hot');
  for (const c of RING) c.li?.classList.remove('hot');
  rcSize.textContent = gb(TOTAL);
  rcName.textContent = 'Macintosh HD';
  rcHint.textContent = t('ring.hint');
}

buildRing();
labelRing();
onLangChange(labelRing);
if (!motionOK() || !('IntersectionObserver' in window)) {
  drawRing(1);
} else {
  drawRing(0);
  const io = new IntersectionObserver(([e]) => {
    if (!e.isIntersecting) return;
    io.disconnect();
    const t0 = performance.now();
    const step = now => {
      const p = clamp((now - t0) / 1500, 0, 1);
      drawRing(p);
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }, { threshold: .3 });
  io.observe(ringBox);
}

/* ================= feature showcase ================= */

(function showcase() {
  const steps = [...document.querySelectorAll('#sc-steps > .sc-step')];
  const stack = document.getElementById('sc-stack');
  const wrap = document.getElementById('sc-wrap');
  const picture = tab => {
    const img = document.createElement('img');
    img.dataset.shot = tab;
    img.dataset.sizes = '(max-width: 900px) 0px, 60vw';
    img.loading = 'lazy';
    img.decoding = 'async';
    img.width = 1600; img.height = 1030;
    img.alt = '';
    updateShot(img);
    const pic = document.createElement('picture');
    pic.append(img);
    stack.append(pic);
    return pic;
  };
  // A step may name a second screenshot (data-alt); the stage alternates between the two.
  const pics = steps.map(step => [step.dataset.tab, step.dataset.alt].filter(Boolean).map(picture));
  let active = -1, shown = 0, timer = 0;
  const show = (i, k) => {
    shown = k;
    pics.forEach((list, j) => list.forEach((p, n) => p.classList.toggle('active', j === i && n === k)));
  };
  const activate = i => {
    if (i === active) return;
    active = i;
    steps.forEach((s, j) => s.classList.toggle('active', j === i));
    show(i, 0);
    clearInterval(timer);
    if (pics[i].length > 1 && motionOK()) timer = setInterval(() => show(i, (shown + 1) % pics[i].length), 4500);
    wrap.style.setProperty('--g', getComputedStyle(steps[i]).getPropertyValue('--g'));
  };
  activate(0);
  const io = new IntersectionObserver(entries => {
    for (const e of entries) if (e.isIntersecting) activate(steps.indexOf(e.target));
  }, { rootMargin: '-45% 0px -45% 0px' });
  steps.forEach(s => io.observe(s));
})();

/* ================= developer scan log ================= */

(function terminal() {
  const el = document.getElementById('term');
  const rows = [
    ['~/Library/Developer/Xcode/DerivedData', '18.4 GB'],
    ['~/Library/Developer/CoreSimulator/Devices', '11.2 GB'],
    ['~/.gradle/caches', '4.8 GB'],
    ['~/.npm/_cacache', '3.6 GB'],
    ['~/Library/Caches/Homebrew', '2.1 GB'],
    ['~/.cargo/registry', '1.9 GB'],
    ['~/Projects/demo-app/node_modules', '1.2 GB', 'dev.idle210'],
  ];
  // Local AI models are never preselected.
  const models = [
    ['Ollama · llama3.1:8b', '4.9 GB'],
    ['Hugging Face · whisper-large-v3', '3.1 GB'],
  ];
  const lines = () => [
    [['c', t('dev.l0')]],
    [],
    ...rows.map(([p, s, note]) => [['p', '✓ '], ['', p.padEnd(44)], ['s', s.padStart(8)], ...(note ? [['c', '  ' + t(note)]] : [])]),
    [],
    [['c', t('dev.aiHead')]],
    ...models.map(([p, s]) => [['c', '○ '], ['', p.padEnd(44)], ['s', s.padStart(8)], ['c', '  ' + t('dev.aiNote')]]),
    [],
    [['t', t('dev.total')]],
    [['ok', t('dev.done')]],
  ];
  const html = segs => segs.map(([c, s]) => c ? `<span class="${c}">${escapeHTML(s)}</span>` : escapeHTML(s)).join('');
  const renderAll = () => { el.innerHTML = lines().map(html).join('\n') + ' <span class="cursor"></span>'; };

  let typing = false, started = false;
  async function type() {
    typing = true;
    const ls = lines();
    el.innerHTML = '';
    const wait = ms => new Promise(r => setTimeout(r, ms));
    for (let li = 0; li < ls.length; li++) {
      const done = ls.slice(0, li).map(html).join('\n');
      let cur = [];
      for (const [c, s] of ls[li]) {
        const fast = c === '' || c === 's';
        for (let k = 1; k <= s.length; k += fast ? 3 : 1) {
          el.innerHTML = done + (li ? '\n' : '') + html([...cur, [c, s.slice(0, k)]]) + '<span class="cursor"></span>';
          await wait(fast ? 8 : 18);
          if (!typing) return;
        }
        cur.push([c, s]);
      }
      await wait(li < 2 ? 260 : 140);
    }
    renderAll();
    typing = false;
  }
  if (!motionOK() || !('IntersectionObserver' in window)) { renderAll(); started = true; }
  else {
    el.style.minHeight = '';
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting && !started) { started = true; io.disconnect(); type(); }
    }, { threshold: .4 });
    io.observe(el);
  }
  onLangChange(() => { typing = false; if (started) renderAll(); });
})();

/* ================= menu bar clock ================= */

(function clock() {
  const el = document.getElementById('mb-clock');
  const tick = () => {
    el.textContent = new Date().toLocaleTimeString(getLang() === 'en' ? 'en-US' : 'zh-CN', { hour: 'numeric', minute: '2-digit' });
  };
  tick();
  setInterval(tick, 30000);
  onLangChange(tick);
})();

/* ================= pricing ================= */

async function renderPlans() {
  const box = document.getElementById('plans');
  const cfg = await getConfig();
  box.innerHTML = cfg.plans.map(p => `
    <article class="plan${p.highlight ? ' hl' : ''}">
      ${p.highlight ? `<span class="badge">${escapeHTML(t('price.badge'))}</span>` : ''}
      <h3>${escapeHTML(planName(p))}</h3>
      <p class="devices">${escapeHTML(t('price.devices', { n: p.devices }))}</p>
      <div class="price"><span class="amt">${escapeHTML(money(p.price, p.currency || 'CNY'))}</span><span class="once">${escapeHTML(t('price.once'))}</span></div>
      <ul>${planFeatures(p).map(f => `<li><svg class="i" aria-hidden="true"><use href="/assets/img/icons.svg#check"/></svg><span>${escapeHTML(f)}</span></li>`).join('')}</ul>
      <a class="btn ${p.highlight ? 'btn-primary' : 'btn-ghost'}" href="/buy.html?plan=${encodeURIComponent(p.id)}">${escapeHTML(t('price.buy', { name: planName(p) }))}</a>
    </article>`).join('');
}
renderPlans();
onLangChange(renderPlans);
