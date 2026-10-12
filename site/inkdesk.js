/* InkDesk：文夹 Inkpeg 界面的网页重绘（示意）。几何参数取自源码 LineView.swift / PeggedView.swift：
   绳子从屏幕两端外 20pt 起呈抛物线，下垂 min(30, 宽×1.8%)；卡片宽 150、间距 174；小红段位于 61.8% 处、长 34pt；
   挂入时卡片从上方 46pt 落下并以 16° 起摆。运动全部是时间的解析函数，网页交互与视频逐帧渲染共用。 */
(function (G) {
  'use strict';
  const L = { ropeTop: 24, panelH: 210, spacing: 174, cardW: 150, pinAbove: 9.5 };
  const sag = W => Math.min(30, W * 0.018);
  const ropeY = (x, W) => { const f = (x + 20) / (W + 40); return L.ropeTop + 4 * sag(W) * f * (1 - f); };
  const ropePath = (W, a = -20, b = W + 20) => { const y1 = ropeY(a, W), y2 = ropeY(b, W), m = (a + b) / 2, cy = 2 * ropeY(m, W) - (y1 + y2) / 2; return `M${a} ${y1.toFixed(2)}Q${m} ${cy.toFixed(2)} ${b} ${y2.toFixed(2)}`; };
  const redCenter = W => W * 0.6180339887498949;
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const svgURI = s => 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(s);
  function rng(seed) { let s = seed >>> 0 || 1; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }

  /* 原创示意缩略图（与上游演示图无关） */
  const THUMBS = {
    contract: [400, 300, `<rect width="400" height="300" fill="#fbfaf6"/><rect x="0" y="0" width="400" height="34" fill="#eceae3"/><circle cx="18" cy="17" r="5" fill="#d2cfc6"/><circle cx="34" cy="17" r="5" fill="#d2cfc6"/><rect x="120" y="11" width="160" height="12" rx="6" fill="#dcd9d0"/><rect x="40" y="58" width="170" height="14" rx="3" fill="#2a2c33"/><g fill="#c8c6bf"><rect x="40" y="88" width="320" height="8" rx="4"/><rect x="40" y="104" width="300" height="8" rx="4"/></g><rect x="34" y="122" width="332" height="44" rx="6" fill="#ffe58a" opacity=".75"/><g fill="#6d6a60"><rect x="40" y="130" width="310" height="8" rx="4"/><rect x="40" y="148" width="250" height="8" rx="4"/></g><path d="M40 172h240" stroke="#ff3b30" stroke-width="3" stroke-linecap="round"/><g fill="#c8c6bf"><rect x="40" y="192" width="320" height="8" rx="4"/><rect x="40" y="208" width="290" height="8" rx="4"/><rect x="40" y="224" width="310" height="8" rx="4"/><rect x="40" y="240" width="200" height="8" rx="4"/></g><text x="300" y="70" font-family="sans-serif" font-size="14" fill="#9b988e">第 7 条</text>`],
    chart: [400, 250, `<rect width="400" height="250" fill="#ffffff"/><rect x="24" y="22" width="120" height="12" rx="6" fill="#2a2c33"/><rect x="24" y="42" width="70" height="8" rx="4" fill="#c9cbd1"/><g stroke="#eceef2"><path d="M24 90h352M24 130h352M24 170h352M24 210h352"/></g><path d="M24 196L70 180 116 186 162 150 208 158 254 120 300 128 346 92 376 100V210H24Z" fill="#2f7cf6" opacity=".14"/><path d="M24 196L70 180 116 186 162 150 208 158 254 120 300 128 346 92 376 100" fill="none" stroke="#2f7cf6" stroke-width="4" stroke-linejoin="round"/><path d="M24 204L70 200 116 192 162 190 208 178 254 176 300 166 346 160 376 150" fill="none" stroke="#ff9f0a" stroke-width="3" stroke-dasharray="7 6"/><circle cx="346" cy="92" r="7" fill="#fff" stroke="#2f7cf6" stroke-width="4"/>`],
    photo: [320, 320, `<defs><linearGradient id="a" x2="0" y2="1"><stop stop-color="#f3e7cf"/><stop offset="1" stop-color="#e7c9a8"/></linearGradient></defs><rect width="320" height="320" fill="url(#a)"/><circle cx="222" cy="104" r="34" fill="#e2543c"/><path d="M0 214C60 168 92 120 140 150S220 120 260 146 300 150 320 160V320H0Z" fill="#8c8a7e" opacity=".7"/><path d="M0 250C70 214 120 236 170 214S260 210 320 226V320H0Z" fill="#4c4e4a"/><path d="M0 290Q160 262 320 292V320H0Z" fill="#26282a"/>`],
    ui: [400, 280, `<rect width="400" height="280" fill="#f4f5f7"/><rect width="92" height="280" fill="#e7e9ee"/><g fill="#c3c7cf"><rect x="16" y="24" width="58" height="9" rx="4"/><rect x="16" y="48" width="48" height="9" rx="4"/><rect x="16" y="72" width="54" height="9" rx="4"/></g><rect x="12" y="92" width="68" height="18" rx="5" fill="#2f7cf6" opacity=".2"/><rect x="112" y="24" width="140" height="14" rx="4" fill="#2a2c33"/><g><rect x="112" y="56" width="268" height="40" rx="8" fill="#fff"/><rect x="112" y="104" width="268" height="40" rx="8" fill="#fff"/><rect x="112" y="152" width="268" height="40" rx="8" fill="#fff"/></g><g fill="#c9ccd3"><rect x="126" y="71" width="120" height="9" rx="4"/><rect x="126" y="119" width="150" height="9" rx="4"/><rect x="126" y="167" width="100" height="9" rx="4"/></g><g fill="#34c759"><rect x="330" y="68" width="36" height="16" rx="8"/></g><rect x="330" y="116" width="36" height="16" rx="8" fill="#ff9f0a"/><rect x="330" y="164" width="36" height="16" rx="8" fill="#34c759"/><rect x="290" y="216" width="90" height="30" rx="8" fill="#2f7cf6"/>`],
    flow: [400, 260, `<rect width="400" height="260" fill="#fbfbf8"/><g fill="#fff" stroke="#2a2c33" stroke-width="3"><rect x="24" y="96" width="92" height="56" rx="10"/><rect x="156" y="40" width="92" height="56" rx="10"/><rect x="156" y="160" width="92" height="56" rx="10"/><rect x="288" y="96" width="92" height="56" rx="28"/></g><g stroke="#8b8b8f" stroke-width="3" fill="none"><path d="M116 116L156 72M116 132L156 184M248 72L288 112M248 184L288 136"/></g><rect x="300" y="116" width="68" height="10" rx="5" fill="#e2543c"/><g fill="#c3c3bd"><rect x="40" y="118" width="60" height="9" rx="4"/><rect x="172" y="62" width="60" height="9" rx="4"/><rect x="172" y="182" width="60" height="9" rx="4"/></g>`],
    board: [360, 300, `<rect width="360" height="300" fill="#3b4a44"/><rect x="10" y="10" width="340" height="280" rx="6" fill="#455850"/><g transform="rotate(-4 90 90)"><rect x="40" y="40" width="110" height="100" fill="#ffe17a"/><g stroke="#6b5a1e" stroke-width="4" stroke-linecap="round"><path d="M56 70h70M56 92h56M56 114h64"/></g></g><g transform="rotate(5 250 100)"><rect x="196" y="50" width="110" height="100" fill="#ffb3a6"/><g stroke="#7b3328" stroke-width="4" stroke-linecap="round"><path d="M212 80h70M212 102h44"/></g></g><g transform="rotate(-2 150 220)"><rect x="100" y="170" width="120" height="96" fill="#b8e6c9"/><g stroke="#2c5b3e" stroke-width="4" stroke-linecap="round"><path d="M116 200h80M116 222h60"/></g></g>`],
    receipt: [300, 380, `<rect width="300" height="380" fill="#f6f6f2"/><rect x="40" y="30" width="220" height="320" fill="#fff" stroke="#e1e1da"/><rect x="100" y="54" width="100" height="14" rx="4" fill="#2a2c33"/><g fill="#cfcfc8"><rect x="64" y="96" width="120" height="8" rx="4"/><rect x="64" y="120" width="96" height="8" rx="4"/><rect x="64" y="144" width="130" height="8" rx="4"/><rect x="64" y="168" width="84" height="8" rx="4"/></g><g fill="#9a9a92"><rect x="204" y="96" width="32" height="8" rx="4"/><rect x="204" y="120" width="32" height="8" rx="4"/><rect x="204" y="144" width="32" height="8" rx="4"/><rect x="204" y="168" width="32" height="8" rx="4"/></g><path d="M64 200h172" stroke="#2a2c33" stroke-dasharray="5 5" stroke-width="2"/><rect x="64" y="218" width="60" height="12" rx="4" fill="#2a2c33"/><rect x="180" y="218" width="56" height="12" rx="4" fill="#e2543c"/><circle cx="150" cy="290" r="26" fill="none" stroke="#e2543c" stroke-width="4" opacity=".75"/>`]
  };
  const thumb = (name) => { const [w, h, body] = THUMBS[name] || THUMBS.photo; return { src: svgURI(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}">${body}</svg>`), w, h }; };
  const FILE_COLORS = { pdf: '#e5483b', docx: '#2f6fe4', xlsx: '#1f9d55', key: '#f08c00', zip: '#7d7f86', txt: '#7d7f86', png: '#7a5cf0', md: '#3d3f46' };
  function fileIcon(ext, w = 46) {
    const c = FILE_COLORS[ext] || '#7d7f86', h = Math.round(w * 1.25);
    return `<svg viewBox="0 0 48 60" width="${w}" height="${h}" aria-hidden="true"><path d="M5 1h26l14 14v42a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2z" fill="#fff" stroke="#c9ccd2"/><path d="M31 1v12a2 2 0 0 0 2 2h12" fill="#eceef2" stroke="#c9ccd2"/><path d="M11 26h24M11 32h24M11 38h16" stroke="#d3d6dc" stroke-width="2" stroke-linecap="round"/><rect x="3" y="44" width="34" height="13" rx="3" fill="${c}"/><text x="20" y="53.6" text-anchor="middle" fill="#fff" font-size="8.5" font-weight="700" font-family="-apple-system,Helvetica,Arial,sans-serif">${esc(ext.toUpperCase())}</text></svg>`;
  }
  const ICON = {
    paperclip: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M8 12.5l6.2-6.2a3.3 3.3 0 0 1 4.7 4.7l-7.6 7.6a5 5 0 0 1-7.1-7.1L12 3.7"/></svg>',
    x: '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M2 2l6 6M8 2L2 8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
    check: '<svg viewBox="0 0 12 12" width="11" height="11" aria-hidden="true"><path d="M2 6.4l2.6 2.6L10 3.4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    apple: '<svg class="apple" viewBox="0 0 14 17" aria-hidden="true"><path fill="currentColor" d="M11.6 9c0-2 1.6-2.9 1.7-3-1-1.4-2.4-1.6-2.9-1.6-1.2-.1-2.4.7-3 .7s-1.6-.7-2.6-.7C3.4 4.4 2.1 5.2 1.4 6.5c-1.4 2.5-.4 6.1 1 8.1.7 1 1.5 2 2.5 2s1.4-.6 2.6-.6 1.5.6 2.6.6 1.7-1 2.4-2c.8-1.1 1.1-2.2 1.1-2.3 0 0-2-.8-2-3.3zM9.6 3c.5-.7.9-1.6.8-2.5-.8 0-1.8.5-2.3 1.2-.5.6-1 1.5-.8 2.4.9.1 1.8-.4 2.3-1.1z"/></svg>',
    cursor: '<svg viewBox="0 0 22 28" aria-hidden="true"><path d="M2 2v21l5.2-5 3.6 8 3.4-1.5-3.5-7.8H17z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>'
  };

  /* 运动：全部为时间 t（秒）的函数 */
  const M = {
    arriveY: dt => dt < 0 ? -46 : -46 * Math.exp(-10.77 * dt) * Math.cos(10.38 * dt),
    swingArrive: (amp, dt) => dt < 0 ? 0 : amp * Math.exp(-1.3 * dt) * Math.cos(6.66 * dt),
    swingNudge: (amp, dt) => { if (dt < 0) return 0; if (dt < 0.3) { const p = dt / 0.3; return amp * (1 - (1 - p) * (1 - p)); } const d = dt - 0.3; return amp * Math.exp(-1.2 * d) * Math.cos(6.1 * d); },
    spring: (from, to, dt, decay = 8.9, wd = 7.14) => { if (dt <= 0) return from; const e = Math.exp(-decay * dt) * (Math.cos(wd * dt) + decay / wd * Math.sin(wd * dt)); return to + (from - to) * e; },
    ease: p => p <= 0 ? 0 : p >= 1 ? 1 : (p < .5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2),
    out: p => p <= 0 ? 0 : p >= 1 ? 1 : 1 - Math.pow(1 - p, 3)
  };

  function cardHTML(item) {
    let photo, ph = 104;
    if (item.kind === 'image') {
      const t = item.img || thumb(item.thumb || 'photo');
      const s = Math.min(136 / t.w, 104 / t.h); const w = Math.round(t.w * s); ph = Math.round(t.h * s);
      photo = `<div class="ik-photo img" style="width:${w}px;height:${ph}px"><img alt="" draggable="false" src="${t.src}"></div>`;
    } else if (item.kind === 'text' || item.kind === 'note') {
      photo = `<div class="ik-photo text">${esc(item.text || '')}</div>`;
    } else {
      photo = `<div class="ik-photo file">${fileIcon(item.ext || 'pdf', 44)}<span>${esc(item.title || '')}</span></div>`;
    }
    return `<div class="ik-clip"></div><div class="ik-card">${photo}<button class="ik-x" tabindex="-1" aria-label="取下">${ICON.x}</button><div class="ik-copied">${ICON.check}已复制</div></div>`;
  }

  class InkLine {
    constructor(root, o = {}) {
      this.root = root; this.o = o; this.W = o.W || 1280; this.cards = []; this.reduced = !!o.reduced;
      this.scroll = { from: 0, to: 0, t: 0, instant: true }; this.events = [];
      root.classList.add('ik-line');
      root.innerHTML = `<div class="ik-dropzone"></div><svg class="ik-rope" aria-hidden="true"><path class="shadow"/><path class="core"/><path class="hi"/></svg><div class="ik-track"></div><svg class="ik-rope ik-rope-red" style="z-index:3" aria-hidden="true"><path class="red"/></svg><button class="ik-red-hit" aria-label="新建记事（小红段）。右键或长按打开菜单"></button><span class="ik-tip">点击记事 · 右键菜单</span><div class="ik-hint">点红绳记事 · 右键粘贴或设置 · 拖入文件</div><div class="ik-feedback" aria-live="polite"></div><div class="ik-pager" hidden><button class="prev" aria-label="向左查看材料">‹</button><span class="count">0</span><button class="next" aria-label="向右查看材料">›</button></div>`;
      this.track = root.querySelector('.ik-track'); this.hint = root.querySelector('.ik-hint'); this.pager = root.querySelector('.ik-pager');
      this.redHit = root.querySelector('.ik-red-hit'); this.tip = root.querySelector('.ik-tip'); this.feedbackEl = root.querySelector('.ik-feedback');
      this.setWidth(this.W);
    }
    setWidth(W) {
      this.W = W; const r = this.root;
      r.querySelectorAll('.ik-rope').forEach(s => { s.setAttribute('viewBox', `0 0 ${W} 80`); s.setAttribute('width', W); s.setAttribute('height', 80); });
      const d = ropePath(W); r.querySelectorAll('.ik-rope:not(.ik-rope-red) path').forEach(p => p.setAttribute('d', d));
      const c = redCenter(W); r.querySelector('.ik-rope .red').setAttribute('d', ropePath(W, c - 17, c + 17));
      const ry = ropeY(c, W); Object.assign(this.redHit.style, { left: (c - 34) + 'px', top: (ry - 18) + 'px' });
      Object.assign(this.tip.style, { left: c + 'px', top: (ry + 14) + 'px' });
      Object.assign(this.hint.style, { left: (W / 2) + 'px', top: (ropeY(W / 2, W) + 22) + 'px' });
    }
    get live() { return this.cards.filter(c => c.fall == null); }
    contentWidth() { const n = this.live.length, span = Math.max(0, n - 1) * L.spacing; return span + L.cardW <= this.W ? this.W : span + L.cardW + 80; }
    maxScroll() { return Math.max(0, this.contentWidth() - this.W); }
    targetX(i, n, extent) { const total = Math.max(n - 1, 0) * L.spacing; return extent / 2 - total / 2 + i * L.spacing; }
    scrollAt(t) { const s = this.scroll; return (s.instant || this.reduced) ? s.to : M.spring(s.from, s.to, t - s.t, 9.5, 6.5); }
    scrollTo(v, t, instant) { const cur = this.scrollAt(t); this.scroll = { from: cur, to: Math.min(this.maxScroll(), Math.max(0, v)), t, instant: !!instant }; }
    scrollBy(d, t, instant) { this.scrollTo(this.scroll.to + d, t, instant); }
    page(fwd, t) { this.scrollBy((fwd ? 1 : -1) * Math.max(L.spacing, this.W * 0.75), t); }
    xAt(c, t) { return (this.reduced) ? c.xTo : M.spring(c.xFrom, c.xTo, t - c.xt); }
    relayout(t) {
      const live = this.live, ext = this.contentWidth();
      live.forEach((c, i) => { const nx = this.targetX(i, live.length, ext); if (c.xTo !== nx) { const cur = c.xt == null ? nx : this.xAt(c, t); c.xFrom = c.xt == null ? nx : cur; c.xTo = nx; c.xt = t; } });
      this.scroll.to = Math.min(this.scroll.to, this.maxScroll());
    }
    find(id) { return this.cards.find(c => c.item.id === id); }
    add(item, t, o = {}) {
      const el = document.createElement('div'); el.className = 'ik-peg'; el.dataset.id = item.id; el.innerHTML = cardHTML(item);
      el.tabIndex = this.o.interactive ? 0 : -1; el.setAttribute('role', 'button');
      el.setAttribute('aria-label', (item.kind === 'note' ? '记事卡：' : '材料卡：') + (item.title || item.text || '').slice(0, 40) + (item.kind === 'note' ? '。单击继续记事' : '。单击复制，右键查看更多操作'));
      this.track.appendChild(el);
      const c = { item, el, born: t, imp: [], fall: null, copiedAt: -9, xt: null, tilt: item.tilt ?? 0 };
      this.cards.push(c); this.relayout(t);
      if (c.xt === t) { c.xFrom = c.xTo; }
      if (!o.quiet) c.imp.push({ t, a: 16, k: 'arrive' }); else c.born = t - 10;
      // 新卡片进入可见范围
      const cx = c.xTo, s = this.scroll.to;
      if (cx - 75 < s) this.scrollTo(Math.max(0, cx - 75 - 40), t, o.quiet);
      if (cx + 75 > s + this.W) this.scrollTo(Math.min(this.maxScroll(), cx + 75 + 40 - this.W), t, o.quiet);
      return c;
    }
    nudge(id, a, t) { const c = this.find(id); if (c) c.imp.push({ t, a, k: 'nudge' }); }
    gust(t, r = Math.random) { this.live.forEach(c => c.imp.push({ t: t + r() * 0.35, a: 1.6 + r() * 1.8, k: 'nudge' })); }
    copy(id, t) { const c = this.find(id); if (!c) return; c.copiedAt = t; this.nudge(id, 3, t); }
    takeDown(id, t) { const c = this.find(id); if (!c || c.fall != null) return; c.fall = t; c.fallX = this.xAt(c, t) - this.scrollAt(t); c.el.style.pointerEvents = 'none'; this.relayout(t); }
    feedback(text) { this.feedbackEl.textContent = text || ''; }
    frame(t) {
      const sc = this.scrollAt(t), W = this.W, live = this.live;
      this.hint.style.opacity = live.length ? 0 : 1;
      const ms = this.maxScroll();
      this.pager.hidden = !(ms > 0);
      if (ms > 0) { this.pager.querySelector('.count').textContent = live.length; this.pager.querySelector('.prev').disabled = this.scroll.to <= 0.5; this.pager.querySelector('.next').disabled = this.scroll.to >= ms - 0.5; }
      for (let i = this.cards.length - 1; i >= 0; i--) {
        const c = this.cards[i];
        let x, y, a = c.tilt, op = 1;
        if (c.fall != null) {
          const d = t - c.fall; if (d > 1.0) { c.el.remove(); this.cards.splice(i, 1); continue; }
          x = c.fallX; y = ropeY(Math.min(W, Math.max(0, x)), W) - L.pinAbove + 1300 * d * d; a += (c.tilt >= 0 ? 1 : -1) * 70 * d; op = d < .35 ? 1 : Math.max(0, 1 - (d - .35) / .5);
        } else {
          x = this.xAt(c, t) - sc;
          const rx = Math.min(W, Math.max(0, x)); y = ropeY(rx, W) - L.pinAbove;
          if (!this.reduced) {
            const da = t - c.born; y += M.arriveY(da); if (da < 0.12) op = Math.max(0, da / 0.12);
            for (const m of c.imp) { const dt = t - m.t; if (dt > 6) continue; a += m.k === 'arrive' ? M.swingArrive(m.a, dt) : M.swingNudge(m.a, dt); }
          }
          c.el.classList.toggle('copied', t >= c.copiedAt && t < c.copiedAt + 1.4);
          c.el.setAttribute('aria-hidden', x < 0 || x > W ? 'true' : 'false');
        }
        c.el.style.transform = `translate(${(x - 75).toFixed(2)}px,${y.toFixed(2)}px) rotate(${a.toFixed(3)}deg)`;
        c.el.style.opacity = op;
        c.imp = c.imp.filter(m => t - m.t < 6);
      }
    }
    cardAt(px, py, t) { // 视口坐标 → 卡片
      for (let i = this.cards.length - 1; i >= 0; i--) { const c = this.cards[i]; if (c.fall != null) continue; const x = this.xAt(c, t) - this.scrollAt(t), top = ropeY(Math.min(this.W, Math.max(0, x)), this.W) - L.pinAbove + 14; if (Math.abs(px - x) < 72 && py > top && py < top + 116) return c; }
      return null;
    }
  }

  function menuHTML(items) { // [['文字', 'kbd'], '-', ...]
    return items.map(it => it === '-' ? '<hr>' : `<button type="button" role="menuitem" data-act="${esc(it[2] || '')}" ${it[3] ? 'class="dim"' : ''}><span>${esc(it[0])}</span>${it[1] ? `<kbd>${esc(it[1])}</kbd>` : ''}</button>`).join('');
  }
  const MENUS = {
    rope: [['新建记事', '', 'note'], ['粘贴挂入', '', 'paste'], ['挂入文件…', '', 'files'], '-', ['设置…', '⌘,', 'settings'], ['隐藏材料架', '', 'toggle']],
    clip: [['隐藏材料架', '', 'toggle'], ['取下未固定材料', '', 'clear'], '-', ['新建记事', '', 'note'], ['粘贴挂入', '', 'paste'], ['挂入文件…', '⌘O', 'files'], ['设置…', '', 'settings'], '-', ['剪贴板自动接收已暂停', '', '', 1], ['选择截图目录…', '', 'capture'], '-', ['声音', '', 'sound'], ['退出文夹', '⌘Q', 'quit']],
    card: (kind) => [['复制', '', 'copy'], ...(kind === 'text' ? [['复制并附来源', '', 'copysrc']] : []), ['材料详情…', '', 'details'], ...(kind === 'note' ? [['继续记事', '', 'edit']] : kind === 'image' ? [['标注副本', '', 'markup']] : kind === 'text' ? [['编辑文字副本…', '', 'markup']] : []), ['在 Finder 中显示副本', '', 'finder'], '-', ['取下', '', 'down']]
  };
  function noteHTML() {
    return `<div class="ik-bar"><span class="ik-lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="title">记事</span></div>
    <div class="ik-note-body"><label class="sr-only" for="ik-note-ta">记事内容</label><textarea id="ik-note-ta" data-r="ta" maxlength="2000" placeholder="记下此刻的想法…&#10;第一行会成为卡片标题。"></textarea></div>
    <div class="ik-note-foot"><span class="st" data-r="st" aria-live="polite">边写边存本地草稿</span><button class="ik-btn" data-r="dismiss" type="button">收起</button><button class="ik-btn primary" data-r="hang" type="button">挂上去<kbd>⌘↩</kbd></button></div>`;
  }
  function settingsHTML() {
    return `<div class="ik-bar"><span class="ik-lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="title">挂入设置</span></div>
    <div class="ik-seg" role="tablist"><button role="tab" data-tab="intake" aria-selected="false" type="button">挂入</button><button role="tab" data-tab="storage" aria-selected="true" type="button">存储</button></div>
    <div class="ik-set" data-pane="intake" hidden>
      <h4>手动挂入</h4><div class="ik-group"><div class="ik-row"><div>把图片、文字或普通文件拖到绳子上，也可从绳子右键菜单或回形针菜单选择“粘贴挂入”。<small>保存副本，原件保留。</small></div></div></div>
      <h4>剪贴板自动接收</h4><div class="ik-group"><div class="ik-row"><div>复制后自动挂入<small>开启后会将选定类型的剪贴板内容保存到本地；可以随时暂停。</small></div><button class="ik-toggle" role="switch" aria-checked="false" aria-label="复制后自动挂入" data-r="auto" type="button"></button></div>
      <div class="ik-row"><div>接收类型<div class="ik-check"><i>✓</i>接收图片</div><div class="ik-check"><i>✓</i>接收文字</div><div class="ik-check"><i class="off"></i>接收文件</div><small>关闭自动接收后，仍可预设类型。</small></div></div></div>
      <h4>截图目录监听</h4><div class="ik-group"><div class="ik-row"><div>自动接收选定目录中的新截图<small>桌面仅接收带系统截图标记的新文件；已有图片不补挂，不改变系统截图设置。</small></div><button class="ik-toggle" role="switch" aria-checked="false" aria-label="截图目录监听" type="button"></button></div></div>
      <p style="text-align:center;color:var(--ik-text2);font-size:11px;margin:12px 0 0">更改会自动保存</p>
    </div>
    <div class="ik-set" data-pane="storage">
      <div class="ik-big" data-r="total">53.8 MiB</div><div style="color:var(--ik-text2);font-size:11.5px">存储占用 · 原始文件保留在原处</div>
      <div class="ik-bar-usage" aria-hidden="true"><i style="width:88%;background:var(--ik-blue)"></i><i style="width:7%;background:#ff9f0a"></i><i style="width:2%;background:#8e8e93"></i></div>
      <h4>资料库位置</h4><div class="ik-group"><div class="ik-row"><div>Inkpeg<small>~/Library/Application Support/Inkpeg</small></div><button class="ik-btn ghost" data-r="finder" type="button">在 Finder 中显示</button></div></div>
      <h4>存储占用</h4><div class="ik-group"><div class="ik-row"><span>托管材料与版本</span><span class="num" data-r="mat">47.6 MiB</span></div><div class="ik-row"><span>导出临时副本</span><span class="num" data-r="exp">5.1 MiB</span></div><div class="ik-row"><span>草稿与恢复记录</span><span class="num">1.1 MiB</span></div>
      <div class="ik-row"><div>清理副本<small>清理已取下且未固定的资料，以及超过 24 小时的临时导出。绳上资料、固定资料和编辑草稿会保留。</small></div><button class="ik-btn ghost" data-r="preview" type="button">预览清理…</button></div></div>
      <p style="color:var(--ik-text2);font-size:11px;margin:12px 0 0" data-r="msg">材料保存为独立副本，原始文件保留。取下卡片后，资料库中的副本仍会保留。</p>
    </div>
    <div class="ik-sheet" data-r="sheet" hidden><div role="alertdialog" aria-label="确认清理副本"><h5>确认清理副本</h5><p data-r="sum">已取下资料 3 项 · 临时导出 2 项\n将从资料库移出 6.2 MiB</p><p>这些副本将移入废纸篓，原始文件保留。可以从废纸篓找回文件后重新挂入。\n真正释放磁盘空间需要自行清空废纸篓；应用不会自动清空。</p><div class="acts"><button class="ik-btn ghost" data-r="cancel" type="button">取消</button><button class="ik-btn primary" data-r="confirm" type="button">移到废纸篓</button></div></div></div>`;
  }
  G.InkDesk = { L, sag, ropeY, ropePath, redCenter, thumb, THUMBS, fileIcon, ICON, M, InkLine, cardHTML, menuHTML, MENUS, noteHTML, settingsHTML, esc, rng };
})(window);
