/* itmz-studio web UI - plain JavaScript, no build step, no dependencies.
 *
 * Data model: the JSON produced by itmz/model.py `to_json()`:
 *   doc.topics = [{attrs:{uuid,text,note,position,...}, children:[...]}]
 * Attribute names are the original iThoughts ones.  The UI only edits
 * text/note/link/color/icon1/folded/position and the tree structure; the
 * server preserves everything else when saving.
 *
 * Sections:  1 state & helpers  2 data access  3 rendering  4 layout
 *            5 edges  6 interaction  7 editing  8 inspector/outline
 *            9 files & server  10 boot
 */
(function () {
  'use strict';
  const MD = window.ItmzMarkdown;
  const EMBED = window.ITMZ_EMBED || null;
  const $ = s => document.querySelector(s);
  const $$ = s => Array.from(document.querySelectorAll(s));

  // ------------------------------------------------------------ 1. state
  const S = {
    path: null, mtime: null, doc: null, readonly: !!(EMBED && EMBED.readonly),
    sel: null, zoom: 1, panX: 0, panY: 0, layout: 'original',
    dirty: false, undo: [], redo: [], icons: {}, iconsDir: false,
    search: { q: '', hits: [], i: -1 },
  };
  const META = new Map();     // node -> {parent, depth, el, w, h, ax, ay, side}
  const BYID = new Map();     // uuid -> node
  const PARENT = new Map();   // node -> parent node | null
  const PALETTE = ['FFB2B2', 'FFD9B2', 'FFFFB2', 'B2FFB2', 'B2FFFF', 'B2D9FF', 'D9B2FF', 'E5E5E5', 'DC322F', '268BD2'];

  const nodesEl = $('#nodes'), linksEl = $('#links'), canvas = $('#canvas'), world = $('#world');

  function toast(msg, isErr) {
    const t = $('#toast');
    t.textContent = msg; t.className = 'show' + (isErr ? ' err' : '');
    clearTimeout(toast._t); toast._t = setTimeout(() => (t.className = ''), isErr ? 6000 : 2600);
  }
  const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16);
  })).toUpperCase();
  const parsePos = s => { const m = /\{\s*([-+0-9.eE]+)\s*,\s*([-+0-9.eE]+)\s*\}/.exec(s || ''); return m ? [+m[1], +m[2]] : [0, 0]; };
  const fmtNum = v => (Math.abs(v - Math.round(v)) < 1e-6 ? String(Math.round(v)) : v.toFixed(3).replace(/0+$/, '').replace(/\.$/, ''));
  const fmtPos = (x, y) => `{${fmtNum(x)}, ${fmtNum(y)}}`;
  const escHtml = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  function normalizeLink(l) {                 // same rules as exporters/common.py
    l = (l || '').trim();
    if (/^[a-z][a-z0-9+.-]*:/i.test(l)) return l;
    if (/^[^@\s/]+@[^@\s/]+\.[^@\s/]+$/.test(l)) return 'mailto:' + l;
    const m = /^([\w-]+(?:\.[\w-]+)+)(\/\S*)?$/.exec(l);
    if (m && (l.startsWith('www.') || m[1].split('.').length > 2 || m[2] || /\.(com|org|net|edu|ch|de|uk|io)$/.test(m[1]))) return 'http://' + l;
    return l;
  }

  function hexToRgb(h) { h = (h || '').replace('#', ''); if (h.length !== 6) return null; return [0, 2, 4].map(i => parseInt(h.substr(i, 2), 16)); }
  function luminance(h) { const c = hexToRgb(h); return c ? (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255 : 1; }
  function shade(h, f) { const c = hexToRgb(h); if (!c) return null; return '#' + c.map(v => Math.max(0, Math.min(255, Math.round(v * f)))).map(v => v.toString(16).padStart(2, '0')).join(''); }

  // ------------------------------------------------------------ 2. data access
  function indexTree() {
    BYID.clear(); PARENT.clear();
    const walk = (list, parent) => list.forEach(n => {
      n.children = n.children || []; n.attrs = n.attrs || {};
      BYID.set(n.attrs.uuid, n); PARENT.set(n, parent); walk(n.children, n);
    });
    walk(S.doc.topics, null);
  }
  const siblings = n => (PARENT.get(n) ? PARENT.get(n).children : S.doc.topics);
  const depthOf = n => { let d = 0; while ((n = PARENT.get(n))) d++; return d; };
  const isFolded = n => n.attrs.folded === '1';
  const ancestors = n => { const a = []; while ((n = PARENT.get(n))) a.push(n); return a; };
  const styleLevels = () => (S.doc.style && S.doc.style.levels) || {};
  const styleAttr = k => S.doc.style && S.doc.style.attrs ? S.doc.style.attrs[k] : undefined;
  function levelValue(depth, key) {               // iThoughts: a level inherits from the nearest defined level above
    const L = styleLevels();
    for (let d = depth; d >= 0; d--) if (L[d] && L[d][key] != null && L[d][key] !== '') return L[d][key];
    return undefined;
  }
  function effColor(n) {
    if (n.attrs.color) return n.attrs.color;
    const inherit = styleAttr('inheritColor') !== '0';
    if (inherit) for (const a of ancestors(n)) if (a.attrs.color) return a.attrs.color;
    const L = styleLevels()[depthOf(n)];              // level colours apply to that level only
    return (L && L.topicColor) || '';
  }
  function topicImage(n) {
    const id = n.attrs['att-id'];
    if (!id) return null;
    const want = n.attrs['att-name'] && `assets/${id}/${n.attrs['att-name']}`;
    const files = S.doc.files || [];
    if (want && files.includes(want)) return want;
    return files.find(f => f.startsWith(`assets/${id}/`)) || null;
  }
  function fileUrl(name) {
    if (EMBED) return (EMBED.assets || {})[name] || '';
    return `/api/file?path=${encodeURIComponent(S.path)}&name=${encodeURIComponent(name)}`;
  }
  function noteResolver(n) {
    const prefix = `notes/${n.attrs.uuid}/`;
    return url => ((S.doc.files || []).includes(prefix + url) ? fileUrl(prefix + url) : url);
  }

  // ------------------------------------------------------------ 3. rendering
  function iconHtml(name) {
    const info = S.icons[name] || { label: name, emoji: '🔹' };
    if (S.iconsDir && !EMBED) {
      return `<img src="/api/icon?name=${encodeURIComponent(name)}" alt="${escHtml(info.emoji)}" title="${escHtml(info.label)}" ` +
             `onerror="this.replaceWith(document.createTextNode(this.alt))">`;
    }
    return `<span title="${escHtml(info.label)}">${info.emoji}</span>`;
  }

  function buildTopic(n, depth) {
    const a = n.attrs, el = document.createElement('div');
    const col = effColor(n), shapeCode = a.shape != null ? a.shape : (levelValue(depth, 'topicShape') || '0');
    el.className = `topic lvl-${Math.min(depth, 3)} shape-${shapeCode}` + (a.callout === '1' ? ' callout' : '') +
      (a['text-alignment'] === '1' ? ' align-left' : a['text-alignment'] === '3' ? ' align-center' : '');
    el.dataset.id = a.uuid;
    if (col) {
      el.style.setProperty('--c', '#' + col);
      el.style.setProperty('--b', shade(col, 0.72));
      el.style.setProperty('--fg', luminance(col) < 0.5 ? '#fff' : '#1f2328');
    }
    const size = a['text-size'] || levelValue(depth, 'textFontSize') || (depth === 0 ? 20 : 14);
    el.style.fontSize = Math.max(8, Math.min(+size, 72)) + 'px';
    if (a['text-width']) { el.style.width = (+a['text-width'] + 22) + 'px'; el.style.maxWidth = 'none'; }
    else if (depth === 0) el.style.maxWidth = '360px';
    const font = (a['text-font'] || '').split('|').map(s => s.trim());
    if (font[1]) el.style.fontFamily = `"${font[1]}", var(--font)`;
    if (font[2] === 'bold') el.style.fontWeight = 600;

    let html = '';
    const img = topicImage(n);
    if (img) html += `<img class="timg" src="${fileUrl(img)}" style="width:${Math.min(+(a['image-width'] || 160), 600)}px" alt="">`;
    const icons = ['icon1', 'icon2'].filter(k => a[k]).map(k => iconHtml(a[k])).join('');
    let text = MD.render(a.text || '', { resolve: noteResolver(n) });
    if (icons) {
      const ic = `<span class="icons">${icons}</span>`;
      text = /^<(p|h\d)>/.test(text) ? text.replace(/^<(p|h\d)>/, `<$1>${ic}`) : `<p>${ic}</p>` + text;
    }
    html += `<div class="ttext">${text}</div>`;
    const badges = [];
    if (a.note) badges.push(`<span data-act="note" title="${escHtml(MD.plain(a.note).slice(0, 300))}">📝</span>`);
    if (a.link) badges.push(`<span data-act="link" title="${escHtml(a.link)}">🔗</span>`);
    if (a['task-progress']) { const p = +a['task-progress']; badges.push(`<span class="task">${p > 100 ? '✓ 完成' : p + '%'}</span>`); }
    if (a['task-due']) badges.push(`<span class="task">⏰ ${escHtml(a['task-due'].slice(0, 10))}</span>`);
    html += `<div class="badges">${badges.join('')}</div>`;
    el.innerHTML = html;
    if (n.children.length) {
      const b = document.createElement('button');
      b.className = 'fold' + (isFolded(n) ? ' closed' : '');
      b.dataset.act = 'fold';
      b.textContent = isFolded(n) ? String(countDesc(n)) : '−';
      b.title = isFolded(n) ? '展开' : '折叠';
      el.appendChild(b);
    }
    return el;
  }
  const countDesc = n => n.children.reduce((s, c) => s + 1 + countDesc(c), 0);

  function render(keepView) {
    if (!S.doc) return;
    document.body.classList.add('has-doc');
    nodesEl.textContent = ''; META.clear();
    const visit = (list, parent, depth) => list.forEach(n => {
      const el = buildTopic(n, depth);
      nodesEl.appendChild(el);
      META.set(n, { parent, depth, el, w: 0, h: 0, ax: 0, ay: 0 });
      if (!isFolded(n)) visit(n.children, n, depth + 1);
    });
    visit(S.doc.topics, null, 0);
    for (const m of META.values()) { m.w = m.el.offsetWidth; m.h = m.el.offsetHeight; }
    layoutAndDraw();
    applySelection();
    renderOutline();
    if (!keepView) fit();
    // images change size after loading: re-measure once they arrive
    nodesEl.querySelectorAll('img').forEach(img => { if (!img.complete) img.addEventListener('load', remeasure, { once: true }); });
  }
  let remeasureT = 0;
  function remeasure() {
    clearTimeout(remeasureT);
    remeasureT = setTimeout(() => { for (const m of META.values()) { m.w = m.el.offsetWidth; m.h = m.el.offsetHeight; } layoutAndDraw(); }, 60);
  }

  function layoutAndDraw() {
    if (S.layout === 'auto') autoLayout(); else originalLayout();
    for (const [n, m] of META) {
      m.el.style.transform = `translate(${m.ax - m.w / 2}px, ${m.ay - m.h / 2}px)`;
      const fb = m.el.querySelector(':scope > .fold');
      if (fb) fb.className = 'fold ' + (m.side < 0 ? 'l' : 'r') + (isFolded(n) ? ' closed' : '');
    }
    drawLinks();
  }

  // ------------------------------------------------------------ 4. layout
  function originalLayout() {
    // iThoughts stores each topic's centre relative to its parent's centre.
    for (const [n, m] of META) {
      const [x, y] = parsePos(n.attrs.position);
      const pm = m.parent ? META.get(m.parent) : null;
      m.ax = (pm ? pm.ax : 0) + x;
      m.ay = (pm ? pm.ay : 0) + y;
      m.side = pm ? (x < 0 ? -1 : 1) : 1;
      if (pm && pm.parent && n.attrs.floating !== '1') m.side = Math.abs(x) < 1 ? pm.side : m.side;
    }
  }

  function autoLayout() {
    // Display-only tidy tree: keeps each branch on the side it was on.
    const HG = 46, VG = 10;
    const kids = n => (isFolded(n) ? [] : n.children.filter(c => META.has(c)));
    const free = c => c.attrs.floating === '1' || c.attrs.callout === '1';
    const memo = new Map();
    const height = n => {
      if (memo.has(n)) return memo.get(n);
      const ks = kids(n).filter(c => !free(c));
      const sum = ks.reduce((s, c) => s + height(c), 0) + Math.max(0, ks.length - 1) * VG;
      const h = Math.max(META.get(n).h, sum); memo.set(n, h); return h;
    };
    const place = (n, x, y, side) => {
      const m = META.get(n); m.ax = x; m.ay = y; m.side = side;
      const ks = kids(n);
      const groups = side === 0 ? [[1, ks.filter(c => !free(c) && parsePos(c.attrs.position)[0] >= 0)],
                                   [-1, ks.filter(c => !free(c) && parsePos(c.attrs.position)[0] < 0)]]
                                : [[side, ks.filter(c => !free(c))]];
      for (const [s, list] of groups) {
        const total = list.reduce((t, c) => t + height(c), 0) + Math.max(0, list.length - 1) * VG;
        let cy = y - total / 2;
        for (const c of list) {
          const ch = height(c), cm = META.get(c);
          place(c, x + s * (m.w / 2 + HG + cm.w / 2), cy + ch / 2, s);
          cy += ch + VG;
        }
      }
      for (const c of ks.filter(free)) {                 // floating/callouts keep their stored offset
        const [fx, fy] = parsePos(c.attrs.position);
        place(c, x + fx, y + fy, c.attrs.callout === '1' ? side || 1 : 0);
      }
    };
    for (const t of S.doc.topics) { const [x, y] = parsePos(t.attrs.position); place(t, x, y, 0); }
    for (const m of META.values()) if (m.side === 0) m.side = 1;
  }

  // ------------------------------------------------------------ 5. edges, boundaries, relationships
  const NS = 'http://www.w3.org/2000/svg';
  function svg(tag, attrs, parent) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    (parent || linksEl).appendChild(e); return e;
  }
  function subtreeBox(n, pad) {
    let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
    const go = k => { const m = META.get(k); if (!m) return; x1 = Math.min(x1, m.ax - m.w / 2); y1 = Math.min(y1, m.ay - m.h / 2);
      x2 = Math.max(x2, m.ax + m.w / 2); y2 = Math.max(y2, m.ay + m.h / 2); if (!isFolded(k)) k.children.forEach(go); };
    go(n);
    return { x: x1 - pad, y: y1 - pad, w: x2 - x1 + 2 * pad, h: y2 - y1 + 2 * pad };
  }

  function drawLinks() {
    linksEl.textContent = '';
    const defs = svg('defs', {});
    const marker = svg('marker', { id: 'arrow', viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
    svg('path', { d: 'M0,0 L10,5 L0,10 z', fill: 'context-stroke' }, marker);
    const markerFb = svg('marker', { id: 'arrowfb', viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
    svg('path', { d: 'M0,0 L10,5 L0,10 z', fill: '#c0392b' }, markerFb);

    // boundaries (topic attr) and groups
    for (const [n] of META) {
      if (n.attrs.boundary === '1') {
        const b = subtreeBox(n, 10), c = effColor(n) || '8899AA';
        svg('rect', { class: 'boundary', x: b.x, y: b.y, width: b.w, height: b.h, rx: 14, fill: shade(c, 1) + '22', stroke: shade(c, 0.75) });
      }
    }
    for (const g of S.doc.groups || []) {
      const members = Object.keys(g).filter(k => /^member\d+$/.test(k)).map(k => BYID.get(g[k])).filter(n => n && META.has(n));
      if (!members.length) continue;
      const boxes = members.map(n => subtreeBox(n, 12));
      const x = Math.min(...boxes.map(b => b.x)), y = Math.min(...boxes.map(b => b.y));
      const x2 = Math.max(...boxes.map(b => b.x + b.w)), y2 = Math.max(...boxes.map(b => b.y + b.h));
      const c = g.color || '8899AA';
      svg('rect', { class: 'boundary', x, y, width: x2 - x, height: y2 - y, rx: 16, fill: '#' + c + '18', stroke: '#' + c, 'stroke-dasharray': '7 5' });
    }

    // parent -> child connectors
    for (const [n, m] of META) {
      const p = m.parent; if (!p) continue;
      if (n.attrs.floating === '1') continue;
      const pm = META.get(p);
      if (n.attrs.callout === '1') {
        svg('path', { class: 'callout-edge', d: `M${pm.ax},${pm.ay} L${m.ax},${m.ay}` });
        continue;
      }
      const dx = m.ax - pm.ax, dy = m.ay - pm.ay;
      const col = shade(effColor(n), 0.7) || '#9aa3ad';
      const wdt = m.depth === 1 ? 3 : 1.6;
      let d;
      if (Math.abs(dx) >= Math.abs(dy) * 0.5 || Math.abs(dx) > pm.w / 2) {       // horizontal-ish
        const s = Math.sign(dx) || 1;
        const x1 = pm.ax + s * pm.w / 2, y1 = pm.ay, x2 = m.ax - s * m.w / 2, y2 = m.ay;
        const cx = (x1 + x2) / 2;
        d = `M${x1},${y1} C${cx},${y1} ${cx},${y2} ${x2},${y2}`;
      } else {                                                                     // vertical layouts
        const s = Math.sign(dy) || 1;
        const x1 = pm.ax, y1 = pm.ay + s * pm.h / 2, x2 = m.ax, y2 = m.ay - s * m.h / 2;
        const cy = (y1 + y2) / 2;
        d = `M${x1},${y1} C${x1},${cy} ${x2},${cy} ${x2},${y2}`;
      }
      svg('path', { class: 'edge', d, stroke: col, 'stroke-width': wdt });
    }

    // relationships (cross links)
    for (const r of S.doc.relationships || []) {
      const a = findNode(r['end1-uuid']), b = findNode(r['end2-uuid']);
      const ma = a && META.get(a), mb = b && META.get(b);
      if (!ma || !mb) continue;
      const col = '#' + (r.color || '7A8794');
      const p1 = edgePoint(ma, mb.ax, mb.ay), p2 = edgePoint(mb, ma.ax, ma.ay);
      let d;
      if (r.type === '1') d = `M${p1[0]},${p1[1]} L${p2[0]},${p2[1]}`;
      else if (r.type === '2') d = `M${p1[0]},${p1[1]} L${p2[0]},${p1[1]} L${p2[0]},${p2[1]}`;
      else {
        const mx = (p1[0] + p2[0]) / 2, my = (p1[1] + p2[1]) / 2, len = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) || 1;
        const nx = -(p2[1] - p1[1]) / len, ny = (p2[0] - p1[0]) / len, k = Math.min(120, len * 0.25);
        d = `M${p1[0]},${p1[1]} Q${mx + nx * k},${my + ny * k} ${p2[0]},${p2[1]}`;
      }
      const attrs = { class: 'rel', d, stroke: col };
      if (r.dashed === '1') attrs['stroke-dasharray'] = '6 4';
      if (r['end2-style'] === '1') attrs['marker-end'] = 'url(#arrow)';
      if (r['end1-style'] === '1') attrs['marker-start'] = 'url(#arrow)';
      svg('path', attrs);
      if (r['center-text']) {
        const t = svg('text', { class: 'rel-label', x: (p1[0] + p2[0]) / 2, y: (p1[1] + p2[1]) / 2 - 6, 'text-anchor': 'middle', fill: col });
        t.textContent = r['center-text'];
      }
    }
  }
  function findNode(id) { if (!id) return null; return BYID.get(id) || BYID.get(id.toUpperCase()) || BYID.get(id.toLowerCase()) || null; }
  function edgePoint(m, tx, ty) {          // where the line from the centre towards (tx,ty) leaves the box
    const dx = tx - m.ax, dy = ty - m.ay;
    if (!dx && !dy) return [m.ax, m.ay];
    const sx = Math.abs(dx) ? (m.w / 2) / Math.abs(dx) : Infinity, sy = Math.abs(dy) ? (m.h / 2) / Math.abs(dy) : Infinity;
    const s = Math.min(sx, sy);
    return [m.ax + dx * s, m.ay + dy * s];
  }

  // ------------------------------------------------------------ 6. viewport & interaction
  function applyView() {
    world.style.transform = `translate(${S.panX}px, ${S.panY}px) scale(${S.zoom})`;
    $('#zoomLabel').textContent = Math.round(S.zoom * 100) + '%';
  }
  function setZoom(z, cx, cy) {
    z = Math.max(0.1, Math.min(4, z));
    const r = canvas.getBoundingClientRect();
    cx = cx == null ? r.width / 2 : cx; cy = cy == null ? r.height / 2 : cy;
    S.panX = cx - (cx - S.panX) * (z / S.zoom); S.panY = cy - (cy - S.panY) * (z / S.zoom); S.zoom = z;
    applyView();
  }
  function fit() {
    if (!META.size) return;
    let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
    for (const m of META.values()) { x1 = Math.min(x1, m.ax - m.w / 2); y1 = Math.min(y1, m.ay - m.h / 2); x2 = Math.max(x2, m.ax + m.w / 2); y2 = Math.max(y2, m.ay + m.h / 2); }
    const r = canvas.getBoundingClientRect(), pad = 40;
    S.zoom = Math.max(0.1, Math.min(1, (r.width - 2 * pad) / (x2 - x1 || 1), (r.height - 2 * pad) / (y2 - y1 || 1)));
    S.panX = (r.width - (x2 - x1) * S.zoom) / 2 - x1 * S.zoom;
    S.panY = (r.height - (y2 - y1) * S.zoom) / 2 - y1 * S.zoom;
    applyView();
  }
  function centerOn(n, onlyIfHidden) {
    const m = META.get(n); if (!m) return;
    const r = canvas.getBoundingClientRect();
    const sx = m.ax * S.zoom + S.panX, sy = m.ay * S.zoom + S.panY;
    if (onlyIfHidden && sx > 60 && sx < r.width - 60 && sy > 40 && sy < r.height - 40) return;
    S.panX = r.width / 2 - m.ax * S.zoom; S.panY = r.height / 2 - m.ay * S.zoom; applyView();
  }

  let drag = null;
  canvas.addEventListener('pointerdown', e => {
    if (e.button !== 0 || e.target.closest('#inlineEdit')) return;
    const tEl = e.target.closest('.topic');
    canvas.focus({ preventScroll: true });
    if (e.target.closest('[data-act]')) return;                    // handled on click
    if (tEl) {
      const n = BYID.get(tEl.dataset.id);
      select(n);
      if (!S.readonly && S.layout === 'original') drag = { kind: 'node', n, x: e.clientX, y: e.clientY, moved: false, start: parsePos(n.attrs.position) };
    } else {
      drag = { kind: 'pan', x: e.clientX, y: e.clientY, px: S.panX, py: S.panY };
      canvas.classList.add('panning');
    }
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener('pointermove', e => {
    if (!drag) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (drag.kind === 'pan') { S.panX = drag.px + dx; S.panY = drag.py + dy; applyView(); return; }
    if (!drag.moved && Math.hypot(dx, dy) < 4) return;
    if (!drag.moved) { snapshot(); drag.moved = true; META.get(drag.n) && META.get(drag.n).el.classList.add('dragging'); }
    drag.n.attrs.position = fmtPos(drag.start[0] + dx / S.zoom, drag.start[1] + dy / S.zoom);
    layoutAndDraw();
  });
  const endDrag = () => {
    if (drag && drag.kind === 'node' && drag.moved) { markDirty(); const m = META.get(drag.n); m && m.el.classList.remove('dragging'); }
    drag = null; canvas.classList.remove('panning');
  };
  canvas.addEventListener('pointerup', endDrag);
  canvas.addEventListener('pointercancel', endDrag);
  canvas.addEventListener('click', e => {
    const act = e.target.closest('[data-act]'); if (!act) return;
    const n = BYID.get(e.target.closest('.topic').dataset.id);
    if (act.dataset.act === 'fold') toggleFold(n);
    else if (act.dataset.act === 'link') window.open(normalizeLink(n.attrs.link), '_blank', 'noopener');
    else if (act.dataset.act === 'note') { select(n); $('#vNote').scrollIntoView({ block: 'nearest' }); }
  });
  canvas.addEventListener('dblclick', e => {
    const tEl = e.target.closest('.topic');
    if (tEl && !e.target.closest('[data-act]') && !S.readonly) startInlineEdit(BYID.get(tEl.dataset.id));
  });
  canvas.addEventListener('wheel', e => {
    e.preventDefault();
    const r = canvas.getBoundingClientRect();
    if (e.ctrlKey || e.metaKey) setZoom(S.zoom * Math.exp(-e.deltaY * 0.01), e.clientX - r.left, e.clientY - r.top);
    else { S.panX -= e.deltaX; S.panY -= e.deltaY; applyView(); }
  }, { passive: false });
  window.addEventListener('resize', () => applyView());

  function select(n) {
    S.sel = n || null;
    applySelection(); fillInspector();
    $$('#outline .oi').forEach(el => el.classList.toggle('sel', !!n && el.dataset.id === n.attrs.uuid));
    const oi = n && $(`#outline .oi[data-id="${n.attrs.uuid}"]`);
    if (oi) oi.scrollIntoView({ block: 'nearest' });
  }
  function applySelection() {
    nodesEl.querySelectorAll('.topic.sel').forEach(e => e.classList.remove('sel'));
    const m = S.sel && META.get(S.sel);
    if (m) m.el.classList.add('sel');
    const hits = new Set(S.search.hits);
    for (const [n, mm] of META) mm.el.classList.toggle('hit', hits.has(n));
  }

  function revealAndSelect(n) {
    let changed = false;
    for (const a of ancestors(n)) if (isFolded(a)) { delete a.attrs.folded; changed = true; }
    if (changed) { render(true); }
    select(n); centerOn(n, true);
  }

  // keyboard
  document.addEventListener('keydown', e => {
    if (e.isComposing || e.keyCode === 229) return;
    const mod = e.metaKey || e.ctrlKey;
    const inField = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); if (!S.readonly) save(); return; }
    if (mod && e.key.toLowerCase() === 'o') { e.preventDefault(); if (!S.readonly) openPicker(); return; }
    if (mod && e.key.toLowerCase() === 'f') { e.preventDefault(); $('#search').focus(); $('#search').select(); return; }
    if (inField) return;
    if (!S.doc) return;
    if (mod && e.key.toLowerCase() === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); return; }
    if (mod && (e.key === '=' || e.key === '+')) { e.preventDefault(); setZoom(S.zoom * 1.2); return; }
    if (mod && e.key === '-') { e.preventDefault(); setZoom(S.zoom / 1.2); return; }
    if (mod && e.key === '0') { e.preventDefault(); fit(); return; }
    const n = S.sel;
    if (e.key === 'Escape') { select(null); return; }
    if (!n) { if (e.key.startsWith('Arrow') || e.key === 'Enter') { select(S.doc.topics[0]); e.preventDefault(); } return; }
    const editable = !S.readonly;
    if (mod && e.key.startsWith('Arrow') && editable) { e.preventDefault(); moveCmd(n, e.key); return; }
    switch (e.key) {
      case 'Tab': e.preventDefault(); if (editable) addChild(n); break;
      case 'Enter': e.preventDefault(); if (editable) addSibling(n); break;
      case 'F2': e.preventDefault(); if (editable) startInlineEdit(n); break;
      case 'Delete': case 'Backspace': e.preventDefault(); if (editable) removeNode(n); break;
      case ' ': e.preventDefault(); toggleFold(n); break;
      case 'ArrowUp': case 'ArrowDown': { e.preventDefault(); navVertical(n, e.key === 'ArrowUp' ? -1 : 1); break; }
      case 'ArrowLeft': case 'ArrowRight': { e.preventDefault(); navHorizontal(n, e.key === 'ArrowLeft' ? -1 : 1); break; }
      default:
        if (editable && e.key.length === 1 && !mod && !e.altKey) { startInlineEdit(n, true); }
    }
  });
  function navVertical(n, dir) {
    const sib = siblings(n), i = sib.indexOf(n);
    const t = sib[i + dir]; if (t) { select(t); centerOn(t, true); }
  }
  function navHorizontal(n, dir) {
    const m = META.get(n), side = PARENT.get(n) ? m.side : 0;
    const towardsChild = side === 0 ? true : dir === side;
    if (towardsChild) {
      if (isFolded(n) && n.children.length) { toggleFold(n); }
      let kids = n.children.filter(c => META.has(c));
      if (side === 0) kids = kids.filter(c => (META.get(c).side || 1) === dir);
      if (kids.length) { select(kids[0]); centerOn(kids[0], true); }
    } else if (PARENT.get(n)) { select(PARENT.get(n)); centerOn(PARENT.get(n), true); }
  }

  // ------------------------------------------------------------ 7. editing
  function snapshot() {
    S.undo.push(JSON.stringify({ t: S.doc.topics, s: S.sel && S.sel.attrs.uuid }));
    if (S.undo.length > 200) S.undo.shift();
    S.redo = [];
  }
  function restore(json) {
    const o = JSON.parse(json);
    S.doc.topics = o.t; indexTree(); S.sel = o.s ? BYID.get(o.s) : null;
    render(true); fillInspector(); markDirty();
  }
  function undo() { if (!S.undo.length) return; S.redo.push(JSON.stringify({ t: S.doc.topics, s: S.sel && S.sel.attrs.uuid })); restore(S.undo.pop()); }
  function redo() { if (!S.redo.length) return; S.undo.push(JSON.stringify({ t: S.doc.topics, s: S.sel && S.sel.attrs.uuid })); restore(S.redo.pop()); }
  function markDirty() { if (S.readonly) return; S.dirty = true; document.body.classList.add('dirty'); }
  function mutate(fn, keepView = true) { snapshot(); fn(); indexTree(); markDirty(); render(keepView); fillInspector(); }

  function newTopic(text, position) {
    return { attrs: { uuid: uuid(), position, text: text || '' }, children: [] };
  }
  function childSide(n) {
    if (!PARENT.get(n) || n.attrs.floating === '1') {
      const last = n.children[n.children.length - 1];
      if (!last) return 1;
      const r = n.children.filter(c => parsePos(c.attrs.position)[0] >= 0).length;
      return r <= n.children.length - r ? 1 : -1;            // balance a root's two sides
    }
    return parsePos(n.attrs.position)[0] < 0 ? -1 : 1;
  }
  function addChild(n) {
    let created;
    mutate(() => {
      delete n.attrs.folded;
      const m = META.get(n) || { w: 120, h: 30 }, side = childSide(n);
      const same = n.children.filter(c => c.attrs.floating !== '1' && c.attrs.callout !== '1' && Math.sign(parsePos(c.attrs.position)[0] || 1) === side);
      const last = same[same.length - 1];
      const x = last ? parsePos(last.attrs.position)[0] : side * (m.w / 2 + 50 + 55);
      const y = last ? parsePos(last.attrs.position)[1] + Math.max(36, (META.get(last) ? META.get(last).h : 30) + 12) : 0;
      created = newTopic('新主题', fmtPos(x, y));
      n.children.push(created);
    });
    select(created); centerOn(created, true); startInlineEdit(created, false, true);
  }
  function addSibling(n) {
    const p = PARENT.get(n);
    if (!p) return addChild(n);
    let created;
    mutate(() => {
      const [x, y] = parsePos(n.attrs.position), m = META.get(n) || { h: 30 };
      const sib = p.children, i = sib.indexOf(n);
      for (const s of sib.slice(i + 1)) {                       // make room below
        if (s.attrs.floating === '1' || s.attrs.callout === '1') continue;
        const [sx, sy] = parsePos(s.attrs.position); if (Math.sign(sx || 1) === Math.sign(x || 1)) s.attrs.position = fmtPos(sx, sy + m.h + 12);
      }
      created = newTopic('新主题', fmtPos(x, y + m.h + 12));
      sib.splice(i + 1, 0, created);
    });
    select(created); centerOn(created, true); startInlineEdit(created, false, true);
  }
  function removeNode(n) {
    const p = PARENT.get(n), sib = siblings(n);
    if (!p && S.doc.topics.length === 1) { toast('不能删除唯一的中心主题', true); return; }
    const cnt = countDesc(n);
    if (cnt > 0 && !confirm(`删除该主题及其 ${cnt} 个子主题？（可撤销）`)) return;
    const i = sib.indexOf(n);
    mutate(() => sib.splice(i, 1));
    select(sib[i] || sib[i - 1] || p);
  }
  function toggleFold(n) {
    if (!n.children.length) return;
    snapshot();
    if (isFolded(n)) delete n.attrs.folded; else n.attrs.folded = '1';
    markDirty(); render(true);
    if (S.sel && !META.has(S.sel)) select(n); else select(S.sel);
  }
  function setAllFold(fold) {
    snapshot();
    const walk = (list, d) => list.forEach(n => {
      if (n.children.length) { if (fold && d >= 1) n.attrs.folded = '1'; else delete n.attrs.folded; }
      walk(n.children, d + 1);
    });
    walk(S.doc.topics, 0); markDirty(); render(false);
  }
  function moveCmd(n, key) {
    const p = PARENT.get(n), sib = siblings(n), i = sib.indexOf(n);
    if (key === 'ArrowUp' || key === 'ArrowDown') {
      const j = i + (key === 'ArrowUp' ? -1 : 1); if (j < 0 || j >= sib.length) return;
      mutate(() => { const o = sib[j]; const pa = n.attrs.position; n.attrs.position = o.attrs.position; o.attrs.position = pa; sib[i] = o; sib[j] = n; });
    } else if (key === 'ArrowLeft') {                           // outdent: become sibling after parent
      if (!p || !PARENT.get(p)) return;
      const gp = PARENT.get(p);
      mutate(() => { sib.splice(i, 1); gp.children.splice(gp.children.indexOf(p) + 1, 0, n);
        const [px, py] = parsePos(p.attrs.position); n.attrs.position = fmtPos(px, py + 40); });
    } else if (key === 'ArrowRight') {                          // indent: become last child of previous sibling
      if (i === 0) return;
      const ns = sib[i - 1];
      mutate(() => { sib.splice(i, 1); delete ns.attrs.folded; const last = ns.children[ns.children.length - 1];
        const [lx, ly] = last ? parsePos(last.attrs.position) : [childSide(ns) * 150, -40];
        n.attrs.position = fmtPos(lx, ly + 40); ns.children.push(n); });
    }
    select(n);
  }

  function setAttr(n, key, val) {
    if (val === '' || val == null) delete n.attrs[key]; else n.attrs[key] = val;
  }

  // inline editor
  function startInlineEdit(n, typed, isNew) {
    const m = META.get(n); if (!m) return;
    const old = $('#inlineEdit'); if (old) old.blur();
    const r = m.el.getBoundingClientRect(), cr = canvas.getBoundingClientRect();
    const ta = document.createElement('textarea');
    ta.id = 'inlineEdit';
    ta.value = typed ? '' : (n.attrs.text || '');
    const fs = parseFloat(m.el.style.fontSize) || 14;
    Object.assign(ta.style, { left: (r.left - cr.left - 4) + 'px', top: (r.top - cr.top - 4) + 'px',
      width: Math.max(r.width + 8, 200) + 'px', height: Math.max(r.height + 8, 44) + 'px', fontSize: fs * S.zoom + 'px' });
    canvas.appendChild(ta);
    ta.focus(); if (!typed) ta.select();
    let done = false;
    const finish = commit => {
      if (done) return; done = true;
      const v = ta.value; ta.remove();
      if (commit && v !== (n.attrs.text || '')) {
        if (isNew) setAttr(n, 'text', v); else mutate(() => setAttr(n, 'text', v));
        if (isNew) { markDirty(); render(true); }
      }
      canvas.focus({ preventScroll: true }); select(n);
    };
    ta.addEventListener('keydown', e => {
      e.stopPropagation();
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); finish(true); }
      else if (e.key === 'Escape') { e.preventDefault(); finish(false); }
      else if (e.key === 'Tab') { e.preventDefault(); finish(true); addChild(n); }
    });
    ta.addEventListener('blur', () => finish(true));
    ta.addEventListener('input', () => { ta.style.height = 'auto'; ta.style.height = Math.max(ta.scrollHeight + 4, 44) + 'px'; });
  }

  // ------------------------------------------------------------ 8. inspector & outline
  const fText = $('#fText'), fNote = $('#fNote'), fLink = $('#fLink'), fColor = $('#fColor'), fIcon = $('#fIcon');
  let notePreview = false, fieldSnap = false;
  function fillInspector() {
    const n = S.sel;
    $('#insEmpty').hidden = !!n; $('#insBody').hidden = !n;
    if (!n) return;
    const a = n.attrs;
    if (document.activeElement !== fText) fText.value = a.text || '';
    if (document.activeElement !== fNote) fNote.value = a.note || '';
    if (document.activeElement !== fLink) fLink.value = a.link || '';
    $('#fLinkOpen').href = a.link ? (MD.safeUrl(normalizeLink(a.link)) || '#') : '#';
    $('#fLinkOpen').style.visibility = a.link ? 'visible' : 'hidden';
    fColor.value = a.color ? '#' + a.color.toLowerCase() : '#ffffff';
    fIcon.value = a.icon1 || '';
    if (a.icon1 && fIcon.value !== a.icon1) {
      const o = document.createElement('option'); o.value = a.icon1; o.textContent = a.icon1; fIcon.appendChild(o); fIcon.value = a.icon1;
    }
    $('#vText').innerHTML = MD.render(a.text || '', { resolve: noteResolver(n) });
    const link = a.link ? MD.safeUrl(normalizeLink(a.link)) : null;
    $('#vLink').innerHTML = a.link ? `🔗 <a href="${escHtml(link || '#')}" target="_blank" rel="noopener noreferrer">${escHtml(a.link)}</a>` : '';
    const showNote = S.readonly || notePreview;
    fNote.hidden = showNote;
    $('#fNotePreview').textContent = notePreview ? '编辑' : '预览';
    $('#vNote').innerHTML = showNote && a.note ? MD.render(a.note, { resolve: noteResolver(n) }) : '';
    const skip = new Set(['text', 'note', 'link', 'color', 'icon1']);
    $('#metaTable').innerHTML = Object.keys(a).filter(k => !skip.has(k)).sort()
      .map(k => `<tr><td>${escHtml(k)}</td><td>${escHtml(a[k])}</td></tr>`).join('');
  }
  function bindField(el, key, live) {
    el.addEventListener('focus', () => { fieldSnap = false; });
    el.addEventListener('input', () => {
      if (!S.sel) return;
      if (!fieldSnap) { snapshot(); fieldSnap = true; }
      let v = el.value;
      if (key === 'color') v = v.replace('#', '').toUpperCase();
      setAttr(S.sel, key, v); markDirty();
      if (live) { clearTimeout(bindField.t); bindField.t = setTimeout(() => { render(true); }, key === 'text' ? 150 : 0); }
      if (key === 'link') fillInspector();
    });
    el.addEventListener('blur', () => { fieldSnap = false; });
  }
  bindField(fText, 'text', true); bindField(fNote, 'note', true); bindField(fLink, 'link', true); bindField(fColor, 'color', true);
  fIcon.addEventListener('change', () => { if (S.sel) mutate(() => setAttr(S.sel, 'icon1', fIcon.value)); });
  $('#fColorClear').addEventListener('click', () => { if (S.sel) mutate(() => setAttr(S.sel, 'color', '')); });
  $('#fNotePreview').addEventListener('click', () => { notePreview = !notePreview; fillInspector(); });
  $('#swatches').innerHTML = PALETTE.map(c => `<span data-c="${c}" style="background:#${c}" title="#${c}"></span>`).join('');
  $('#swatches').addEventListener('click', e => { const c = e.target.dataset.c; if (c && S.sel) mutate(() => setAttr(S.sel, 'color', c)); });

  function fillIconSelect() {
    const opts = ['<option value="">（无图标）</option>'];
    for (const [k, v] of Object.entries(S.icons)) opts.push(`<option value="${escHtml(k)}">${v.emoji}  ${escHtml(v.label)}</option>`);
    fIcon.innerHTML = opts.join('');
  }

  function renderOutline() {
    const box = $('#outline'); if (box.hidden || !S.doc) return;
    const rows = [];
    const walk = (list, d) => list.forEach(n => {
      const has = n.children.length, f = isFolded(n);
      const txt = MD.plain(n.attrs.text || '').split('\n')[0] || (topicImage(n) ? '🖼' : '·');
      rows.push(`<div class="oi${S.sel === n ? ' sel' : ''}" data-id="${escHtml(n.attrs.uuid)}" style="padding-left:${6 + d * 14}px">` +
        `<span class="tw" data-tw>${has ? (f ? '▸' : '▾') : ''}</span><span class="ot">${escHtml(txt)}</span></div>`);
      if (!f) walk(n.children, d + 1);
    });
    walk(S.doc.topics, 0);
    box.innerHTML = rows.join('');
  }
  $('#outline').addEventListener('click', e => {
    const row = e.target.closest('.oi'); if (!row) return;
    const n = BYID.get(row.dataset.id);
    if (e.target.closest('[data-tw]') && n.children.length) { toggleFold(n); return; }
    revealAndSelect(n);
  });

  // search
  function runSearch(q) {
    S.search.q = q = q.trim().toLowerCase();
    S.search.hits = []; S.search.i = -1;
    if (q && S.doc) for (const n of BYID.values()) {
      const hay = (MD.plain(n.attrs.text) + '\n' + (n.attrs.note || '') + '\n' + (n.attrs.link || '')).toLowerCase();
      if (hay.includes(q)) S.search.hits.push(n);
    }
    $('#searchInfo').textContent = q ? `${S.search.hits.length} 个` : '';
    applySelection();
  }
  $('#search').addEventListener('input', e => runSearch(e.target.value));
  $('#search').addEventListener('keydown', e => {
    if (e.key !== 'Enter' || !S.search.hits.length) return;
    e.preventDefault();
    S.search.i = (S.search.i + (e.shiftKey ? -1 : 1) + S.search.hits.length) % S.search.hits.length;
    $('#searchInfo').textContent = `${S.search.i + 1}/${S.search.hits.length}`;
    revealAndSelect(S.search.hits[S.search.i]); applySelection();
  });

  // ------------------------------------------------------------ 9. files & server
  async function api(path, body) {
    const opt = body ? { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Itmz': '1' }, body: JSON.stringify(body) } : {};
    const r = await fetch(path, opt);
    const data = await r.json().catch(() => ({ error: r.statusText }));
    if (!r.ok) { const err = new Error(data.error || r.statusText); err.status = r.status; throw err; }
    return data;
  }
  function loadDoc(map, path, mtime) {
    S.doc = map; S.path = path; S.mtime = mtime; S.sel = null; S.undo = []; S.redo = []; S.dirty = false;
    document.body.classList.remove('dirty');
    indexTree();
    const title = (S.doc.topics[0] && MD.plain(S.doc.topics[0].attrs.text).split('\n')[0]) || 'Untitled';
    $('#docTitle').textContent = path ? path : title;
    document.title = (path ? path.split('/').pop() : title) + ' – itmz-studio';
    runSearch($('#search').value);
    render(false); fillInspector();
  }
  async function openPath(path) {
    if (S.dirty && !confirm('当前导图有未保存的修改，确定放弃并打开其它文件？')) return;
    try {
      const r = await api('/api/map?path=' + encodeURIComponent(path));
      loadDoc(r.map, r.path, r.mtime);
      history.replaceState(null, '', '#' + encodeURIComponent(r.path));
      closeModal();
    } catch (e) { toast('打开失败：' + e.message, true); }
  }
  async function save(saveAs, force) {
    if (!S.doc || !S.path) return;
    try {
      const r = await api('/api/save', { path: S.path, mtime: S.mtime, topics: S.doc.topics, saveAs: saveAs || undefined, force: !!force });
      S.path = r.path; S.mtime = r.mtime; S.dirty = false; document.body.classList.remove('dirty');
      $('#docTitle').textContent = r.path; history.replaceState(null, '', '#' + encodeURIComponent(r.path));
      toast('已保存 ' + r.path + (r.backup ? `（原文件已备份到 ${r.backup}）` : ''));
    } catch (e) {
      if (e.status === 409 && confirm(e.message + '\n\n仍要覆盖吗？')) return save(saveAs, true);
      toast('保存失败：' + e.message, true);
    }
  }
  async function saveAsPrompt() {
    if (!S.path) return;
    const def = S.path.replace(/\.itmz$/i, ' 副本.itmz');
    const p = prompt('另存为（相对于导图根目录的路径）：', def);
    if (p) save(/\.itmz$/i.test(p) ? p : p + '.itmz');
  }
  async function newMap() {
    if (S.dirty && !confirm('当前导图有未保存的修改，确定新建？')) return;
    const dir = S.path && S.path.includes('/') ? S.path.slice(0, S.path.lastIndexOf('/') + 1) : '';
    const p = prompt('新导图保存位置（相对于导图根目录）：', dir + '新导图.itmz');
    if (!p) return;
    try {
      const r = await api('/api/new', { path: /\.itmz$/i.test(p) ? p : p + '.itmz', title: p.split('/').pop().replace(/\.itmz$/i, '') });
      S.dirty = false; openPath(r.path);
    } catch (e) { toast('新建失败：' + e.message, true); }
  }
  function exportFmt(fmt) {
    if (!S.path) return;
    if (S.dirty && !confirm('导出的是磁盘上“已保存”的版本，当前有未保存修改。继续导出？')) return;
    const a = document.createElement('a');
    a.href = `/api/export?path=${encodeURIComponent(S.path)}&fmt=${fmt}`; a.download = '';
    document.body.appendChild(a); a.click(); a.remove();
  }

  // file picker
  let fileCache = [];
  async function openPicker() {
    $('#modal').hidden = false; $('#fileFilter').value = ''; $('#fileFilter').focus();
    try {
      const r = await api('/api/files');
      fileCache = r.files; $('#fileRoot').textContent = '根目录：' + r.root + `（${r.files.length} 个导图）`;
      drawFileList();
    } catch (e) { toast('无法列出文件：' + e.message, true); }
  }
  function drawFileList() {
    const q = $('#fileFilter').value.trim().toLowerCase();
    const list = fileCache.filter(f => !q || f.path.toLowerCase().includes(q)).slice(0, 500);
    $('#fileList').innerHTML = list.map(f => {
      const i = f.path.lastIndexOf('/');
      return `<li data-path="${escHtml(f.path)}"><span><span class="dir">${escHtml(f.path.slice(0, i + 1))}</span>${escHtml(f.path.slice(i + 1))}</span>` +
             `<span class="size">${(f.size / 1024).toFixed(0)} KB</span></li>`;
    }).join('');
  }
  const closeModal = () => { $('#modal').hidden = true; };
  $('#fileFilter').addEventListener('input', drawFileList);
  $('#fileFilter').addEventListener('keydown', e => { if (e.key === 'Enter') { const li = $('#fileList li'); if (li) openPath(li.dataset.path); } if (e.key === 'Escape') closeModal(); });
  $('#fileList').addEventListener('click', e => { const li = e.target.closest('li'); if (li) openPath(li.dataset.path); });
  $('#modal').addEventListener('click', e => { if (e.target.id === 'modal' || e.target.closest('[data-close]')) closeModal(); });

  // toolbar
  const CMDS = {
    open: openPicker, new: newMap, save: () => save(), saveAs: saveAsPrompt,
    addChild: () => S.sel && addChild(S.sel), addSibling: () => S.sel && addSibling(S.sel), remove: () => S.sel && removeNode(S.sel),
    undo, redo, expandAll: () => S.doc && setAllFold(false), collapseAll: () => S.doc && setAllFold(true),
    zoomIn: () => setZoom(S.zoom * 1.2), zoomOut: () => setZoom(S.zoom / 1.2), zoomReset: () => setZoom(1), fit,
    toggleLayout: () => { S.layout = S.layout === 'original' ? 'auto' : 'original'; $('#layoutBtn').textContent = '布局：' + (S.layout === 'auto' ? '自动整理' : '原始'); if (S.doc) { layoutAndDraw(); fit(); } },
    toggleOutline: () => { const o = $('#outline'); o.hidden = !o.hidden; renderOutline(); },
  };
  document.addEventListener('click', e => {
    const b = e.target.closest('[data-cmd]'); if (b && CMDS[b.dataset.cmd]) { CMDS[b.dataset.cmd](); return; }
    const f = e.target.closest('[data-fmt]'); if (f) exportFmt(f.dataset.fmt);
  });
  window.addEventListener('beforeunload', e => { if (S.dirty) { e.preventDefault(); e.returnValue = ''; } });

  // ------------------------------------------------------------ 10. boot
  async function boot() {
    if (S.readonly) document.body.classList.add('readonly');
    if (EMBED) {
      S.icons = EMBED.icons || {}; fillIconSelect();
      loadDoc(EMBED.map, null, null);
      $('#docTitle').textContent = EMBED.title || '';
      return;
    }
    try {
      const info = await api('/api/info');
      S.icons = info.icons; S.iconsDir = !!info.iconsDir; fillIconSelect();
    } catch (e) { toast('无法连接本地服务：' + e.message, true); return; }
    const want = decodeURIComponent(location.hash.slice(1));
    if (want) openPath(want); else openPicker();
    window.addEventListener('hashchange', () => {
      const p = decodeURIComponent(location.hash.slice(1));
      if (p && p !== S.path) openPath(p);
    });
  }
  boot();

  // tiny debug/automation handle (used by tests; harmless)
  window.itmzStudio = { state: S, meta: META, byId: BYID, render, select, save };
})();
