import { h, s } from './dom.js';

// Hand-rolled SVG charts. Each chart re-renders at its container's pixel width so text stays crisp.

let gradientSeq = 0;

function niceMax(value) {
  if (value <= 0) return 4;
  const exp = 10 ** Math.floor(Math.log10(value));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * exp >= value) return m * exp;
  return 10 * exp;
}

function shortDay(day) {
  return day.slice(5).replace('-', '/');
}

/**
 * series: [{ day, ...values }]
 * kind: 'bar' | 'line'
 * keys: [{ key, label, color }]
 * format: value → string (tooltips / axis)
 */
export function chart({ series, kind = 'line', keys, format = String, height = 210 }) {
  const box = h('div', { class: 'chart-box' });
  const tip = h('div', { class: 'chart-tip' });
  box.append(tip);
  let svg = null;

  const draw = () => {
    const width = Math.max(280, Math.floor(box.clientWidth - 36));
    if (svg) svg.remove();
    const pad = { top: 14, right: 8, bottom: 26, left: 44 };
    const innerW = width - pad.left - pad.right;
    const innerH = height - pad.top - pad.bottom;
    const n = series.length;
    const maxVal = niceMax(Math.max(0, ...series.flatMap((d) => keys.map((k) => Number(d[k.key]) || 0))));
    const y = (v) => pad.top + innerH - (v / maxVal) * innerH;
    const step = innerW / n;
    const xCenter = (i) => pad.left + step * i + step / 2;

    svg = s('svg', { width, height, viewBox: `0 0 ${width} ${height}`, role: 'img' });
    const defs = s('defs');
    svg.append(defs);

    // Grid + y labels
    for (let i = 0; i <= 4; i++) {
      const v = (maxVal / 4) * i;
      const yy = y(v);
      svg.append(s('line', { class: 'chart-grid', x1: pad.left, x2: width - pad.right, y1: yy, y2: yy }));
      svg.append(s('text', { class: 'chart-axis', x: pad.left - 8, y: yy + 4, 'text-anchor': 'end' }, format(Math.round(v * 100) / 100, true)));
    }
    // X labels: about every 5th day plus the last one
    const every = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(innerW / 64))));
    series.forEach((d, i) => {
      if (i % every === 0 || i === n - 1) {
        if (i !== n - 1 && n - 1 - i < every / 2) return;
        svg.append(s('text', { class: 'chart-axis', x: xCenter(i), y: height - 6, 'text-anchor': 'middle' }, shortDay(d.day)));
      }
    });

    if (kind === 'bar') {
      const k = keys[0];
      const id = `g${++gradientSeq}`;
      defs.append(s('linearGradient', { id, x1: 0, y1: 0, x2: 0, y2: 1 },
        s('stop', { offset: '0%', 'stop-color': k.color }),
        s('stop', { offset: '100%', 'stop-color': k.color2 || k.color, 'stop-opacity': 0.85 })));
      const bw = Math.max(3, Math.min(22, step * 0.62));
      series.forEach((d, i) => {
        const v = Number(d[k.key]) || 0;
        const top = y(v);
        const hgt = pad.top + innerH - top;
        if (v > 0) {
          const r = Math.min(5, bw / 2, hgt);
          const x0 = xCenter(i) - bw / 2;
          const yb = pad.top + innerH;
          svg.append(s('path', {
            fill: `url(#${id})`,
            d: `M${x0},${yb} V${top + r} Q${x0},${top} ${x0 + r},${top} H${x0 + bw - r} Q${x0 + bw},${top} ${x0 + bw},${top + r} V${yb} Z`,
          }));
        } else {
          svg.append(s('rect', { x: xCenter(i) - bw / 2, y: pad.top + innerH - 2, width: bw, height: 2, rx: 1, fill: 'var(--border)' }));
        }
      });
    } else {
      keys.forEach((k, ki) => {
        const pts = series.map((d, i) => [xCenter(i), y(Number(d[k.key]) || 0)]);
        const line = pts.map(([px, py], i) => `${i ? 'L' : 'M'}${px.toFixed(1)},${py.toFixed(1)}`).join(' ');
        if (ki === 0) {
          const id = `g${++gradientSeq}`;
          defs.append(s('linearGradient', { id, x1: 0, y1: 0, x2: 0, y2: 1 },
            s('stop', { offset: '0%', 'stop-color': k.color, 'stop-opacity': 0.28 }),
            s('stop', { offset: '100%', 'stop-color': k.color, 'stop-opacity': 0 })));
          svg.append(s('path', { d: `${line} L${pts[n - 1][0]},${pad.top + innerH} L${pts[0][0]},${pad.top + innerH} Z`, fill: `url(#${id})` }));
        }
        svg.append(s('path', {
          d: line, fill: 'none', stroke: k.color, 'stroke-width': ki === 0 ? 2.2 : 1.8,
          'stroke-linejoin': 'round', 'stroke-linecap': 'round', 'stroke-dasharray': k.dashed ? '4 4' : null,
        }));
      });
    }

    // Hover cursor + tooltip
    const cursor = s('line', { class: 'chart-cursor', y1: pad.top, y2: pad.top + innerH, x1: 0, x2: 0, visibility: 'hidden' });
    const dots = keys.map((k) => s('circle', { r: 4, fill: 'var(--surface)', stroke: k.color, 'stroke-width': 2, cx: 0, cy: 0, visibility: 'hidden' }));
    const showCursor = (on) => [cursor, ...dots].forEach((el) => el.setAttribute('visibility', on ? 'visible' : 'hidden'));
    svg.append(cursor, ...(kind === 'line' ? dots : []));
    const hit = s('rect', { x: pad.left, y: pad.top, width: innerW, height: innerH, fill: 'transparent' });
    hit.addEventListener('mousemove', (e) => {
      const rect = svg.getBoundingClientRect();
      const i = Math.min(n - 1, Math.max(0, Math.floor((e.clientX - rect.left - pad.left) / step)));
      const d = series[i];
      const cx = xCenter(i);
      showCursor(true);
      cursor.setAttribute('x1', cx);
      cursor.setAttribute('x2', cx);
      keys.forEach((k, ki) => {
        dots[ki].setAttribute('cx', cx);
        dots[ki].setAttribute('cy', y(Number(d[k.key]) || 0));
      });
      tip.replaceChildren(
        h('div', { style: { fontWeight: 700, marginBottom: '2px' } }, d.day),
        ...keys.map((k) => h('div', h('span', { style: { color: k.color } }, '● '), `${k.label}：${format(Number(d[k.key]) || 0)}`)),
      );
      tip.style.left = `${cx + 18}px`;
      tip.style.top = `${Math.min(...keys.map((k) => y(Number(d[k.key]) || 0))) - 4}px`;
      tip.classList.add('show');
    });
    hit.addEventListener('mouseleave', () => {
      tip.classList.remove('show');
      showCursor(false);
    });
    svg.append(hit);
    box.insertBefore(svg, tip);
  };

  const ro = new ResizeObserver(() => draw());
  ro.observe(box);
  return box;
}

export function legend(keys) {
  return h('div', { class: 'chart-legend' }, keys.map((k) => h('span', h('i', { style: { background: k.color } }), k.label)));
}
