/* 文夹 Inkpeg 产品页交互。所有演示都在浏览器内存中完成，不读取访客的文件、剪贴板或本机应用。 */
(() => {
  'use strict';
  const D = window.InkDesk; if (!D) return;
  const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const root = document.documentElement, Q = new URLSearchParams(location.search);
  const mq = matchMedia('(prefers-reduced-motion: reduce)');
  const reduced = () => mq.matches || root.classList.contains('reduce-motion');
  const now = () => performance.now() / 1000;
  const sleep = ms => new Promise(r => setTimeout(r, reduced() ? Math.min(ms, 30) : ms));
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const theme = () => root.dataset.theme;

  /* ---------- 通用：主题、提示、头部 ---------- */
  const toastEl = $('#site-toast'); let toastT;
  function toast(msg) { toastEl.textContent = msg; toastEl.classList.add('show'); clearTimeout(toastT); toastT = setTimeout(() => toastEl.classList.remove('show'), 2600); }
  function applyTheme(t, save) { root.dataset.theme = t; $$('.ik-screen').forEach(s => s.dataset.theme = t); if (save) try { localStorage.setItem('inkpeg-theme', t); } catch (e) {} }
  $('#theme-toggle').addEventListener('click', () => applyTheme(theme() === 'dark' ? 'light' : 'dark', true));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', e => { let s = null; try { s = localStorage.getItem('inkpeg-theme'); } catch (_) {} if (!s && !Q.get('theme')) applyTheme(e.matches ? 'dark' : 'light'); });
  const header = $('.site-header'); addEventListener('scroll', () => header.classList.toggle('scrolled', scrollY > 8), { passive: true });

  /* ---------- 动画主循环 ---------- */
  const lines = new Set(); // {line, active}
  const tickers = new Set();
  function loop() { const t = now(); lines.forEach(o => { if (o.active) o.line.frame(t); }); tickers.forEach(f => f(t)); requestAnimationFrame(loop); }
  requestAnimationFrame(loop);
  function watch(el, o) { new IntersectionObserver(es => es.forEach(e => { o.active = e.isIntersecting; if (o.onVis) o.onVis(e.isIntersecting); }), { rootMargin: '120px' }).observe(el); }
  function makeScreen(W, H, cls = '') { const s = document.createElement('div'); s.className = 'ik-screen ' + cls; s.dataset.theme = theme(); s.style.setProperty('--ik-w', W); s.style.setProperty('--ik-h', H); return s; }

  /* ---------- 首屏：产品示意（真实尺寸，指针掠过会晃） ---------- */
  (function heroShot() {
    const host = $('#hero-shot'); if (!host) return;
    let line, scr, o = { line: null, active: true }; lines.add(o); watch(host, o);
    function build() {
      const cw = host.clientWidth || 560, W = 560, sc = cw / W, H = 400; host.style.height = Math.round(H * sc) + 'px';
      scr = makeScreen(W, H); scr.style.setProperty('--ik-scale', sc); scr.setAttribute('aria-hidden', 'true');
      scr.innerHTML = `<div class="ik-menubar"><div class="l">${D.ICON.apple}<b>预览</b><span>文件</span><span>编辑</span><span>显示</span></div><div class="r"><span class="ik-status on">${D.ICON.paperclip}</span><span>周一 14:30</span></div></div>
        <div class="ik-panel" style="left:150px;top:236px;width:330px;border-radius:16px"><div class="ik-bar" style="height:30px"><span class="ik-lights"><i></i><i></i><i></i></span><span class="title">记事</span></div><div style="padding:12px 18px;font-size:13.5px;line-height:1.8;white-space:pre-wrap">下周沟通准备
周二前整理会议记录，把待确认的问题单独列出。</div><div class="ik-note-foot" style="padding:8px 12px"><span class="st">${D.ICON.check}草稿已保存到本机</span><span class="ik-btn">收起</span><span class="ik-btn primary">挂上去<kbd>⌘↩</kbd></span></div></div>
        <div data-r="line"></div><div class="ik-cursor" style="transform:translate(330px,96px)">${D.ICON.cursor}</div>`;
      host.innerHTML = ''; host.appendChild(scr);
      line = new D.InkLine($('[data-r=line]', scr), { W, reduced: reduced() }); o.line = line; line.redHit.tabIndex = -1;
      const t = now(); [{ kind: 'image', thumb: 'contract', tilt: -1.6 }, { kind: 'text', text: '“先把思路留住，\n再决定放到哪里。”', tilt: 1.2 }, { kind: 'pdf', ext: 'pdf', title: '项目资料.pdf', tilt: -1.4 }]
        .forEach((it, i) => line.add(Object.assign({ id: 'h' + i }, it), reduced() ? t - 10 : t + .35 + i * .18, { quiet: reduced() }));
      if (!reduced()) setTimeout(() => line.copy('h0', now()), 1900);
    }
    build(); let w0 = host.clientWidth; new ResizeObserver(() => { if (Math.abs(host.clientWidth - w0) > 2) { w0 = host.clientWidth; build(); } }).observe(host);
    let lastG = 0; host.addEventListener('pointermove', e => { const t = now(); if (reduced() || t - lastG < .9) return; lastG = t; line.gust(t); }, { passive: true });
    host.addEventListener('click', () => { if (!reduced()) line.copy('h' + Math.floor(Math.random() * 3), now()); });
    setInterval(() => { if (o.active && !reduced() && document.visibilityState === 'visible') line.gust(now()); }, 9000);
  })();

  /* ---------- 交互桌面 ---------- */
  const tasksEl = $('#tasks'), progressEl = $('#task-progress'); const doneTasks = new Set();
  function task(k) { if (doneTasks.has(k)) return; doneTasks.add(k); const li = $(`[data-task="${k}"]`, tasksEl); if (li) { li.classList.add('done', 'flash'); setTimeout(() => li.classList.remove('flash'), 900); } progressEl.textContent = `${doneTasks.size} / 8`; }

  const SOURCES = {
    shot: { kind: 'image', thumb: 'contract', title: '合同条款截图.png', file: '合同条款截图.png' },
    chart: { kind: 'image', thumb: 'chart', title: '季度数据.png', file: '季度数据.png' },
    pdf: { kind: 'pdf', ext: 'pdf', title: '项目资料.pdf', file: '项目资料.pdf' },
    quote: { kind: 'text', title: '好的工具，让注意力回到事情本身。', text: '好的工具，让注意力回到事情本身。\n——读书摘录' }
  };
  const EXTRA = [
    { kind: 'image', thumb: 'ui', title: '设置页截图.png' }, { kind: 'text', text: '周三 10:00 约见客户\n带上补充协议第二稿' }, { kind: 'file', ext: 'docx', title: '会议纪要.docx' },
    { kind: 'image', thumb: 'flow', title: '流程图.png' }, { kind: 'image', thumb: 'photo', title: '现场照片.jpg' }, { kind: 'file', ext: 'xlsx', title: '报价对比.xlsx' },
    { kind: 'text', text: '“先把思路留住，\n再决定放到哪里。”' }, { kind: 'image', thumb: 'board', title: '白板.png' }, { kind: 'image', thumb: 'receipt', title: '发票.png' }, { kind: 'file', ext: 'zip', title: '附件包.zip' }
  ];
  let uid = 0; const nid = () => 'c' + (++uid);
  const tilt = () => +(Math.random() * 5 - 2.5).toFixed(2);

  function Playground() {
    const scaler = $('#stage-scaler'); if (!scaler) return null;
    let W = 900, H = 572, scale = 1, screen, line, lineEl, hidden = false;
    const S = { clip: null, taken: [], exports: 2, note: { open: false, draft: '', editing: null }, settings: false, writer: [], folder: 0, demo: false };

    function build() {
      const cw = scaler.clientWidth || 900; W = Math.max(620, Math.round(cw)); scale = cw / W; const narrow = W < 760;
      H = narrow ? 720 : clamp(Math.round(W * .64), 610, 660);
      scaler.style.height = Math.round(H * scale) + 'px';
      screen = makeScreen(W, H, 'pg-screen'); screen.style.setProperty('--ik-scale', scale); screen.setAttribute('role', 'application'); screen.setAttribute('aria-label', '文夹交互桌面（示意）');
      const rw = narrow ? 360 : Math.min(410, Math.round(W * .44)), wx = narrow ? 16 : Math.round(W * .5) - 20, ww = narrow ? 360 : Math.min(330, W - 140 - wx);
      const ix = W - 106, iy = 228;
      screen.innerHTML = `
        <div class="ik-menubar"><div class="l">${D.ICON.apple}<b>访达</b><span>文件</span><span>编辑</span><span>显示</span><span class="hide-n">前往</span><span class="hide-n">窗口</span><span class="hide-n">帮助</span></div>
        <div class="r"><button class="ik-status" data-r="clip" aria-label="文夹菜单（回形针）" aria-haspopup="menu">${D.ICON.paperclip}</button><span class="hide-n">周一 14:30</span></div></div>
        <div class="ik-win reader" style="left:${narrow ? 16 : 28}px;top:${iy}px;width:${rw}px;height:${narrow ? 222 : 252}px"><div class="ik-bar"><span class="ik-lights"><i></i><i></i><i></i></span><span class="title">阅读器 — 行业报告</span></div>
          <div style="padding:14px 18px;font-size:12.5px;line-height:1.75;color:var(--ik-text2)"><div style="font-weight:700;color:var(--ik-text);font-size:15px;margin-bottom:6px">第三章 · 工作方式</div>看文章、截个图、找文件。桌面越堆越满，真正要用的那几份材料，却总要重新找一遍。<br>
          <span class="sel" data-src="quote" tabindex="0" role="button" aria-label="拖动选中的文字：好的工具，让注意力回到事情本身。按回车挂到绳上" style="background:var(--ik-sel);color:var(--ik-text);border-radius:3px;padding:1px 0;cursor:grab;touch-action:none">好的工具，让注意力回到事情本身。</span>
          <span style="display:block;margin-top:8px;font-size:11px;color:var(--ik-blue)">↑ 选中的文字，可以直接拖到绳上</span></div></div>
        <div class="ik-win writer" data-r="writer" style="left:${wx}px;top:${narrow ? 470 : iy + 92}px;width:${ww}px;height:${narrow ? 206 : 228}px"><div class="ik-bar"><span class="ik-lights"><i></i><i></i><i></i></span><span class="title">写作 — 周报.txt</span></div>
          <div class="wbody" style="padding:12px 16px;font-size:12.5px;line-height:1.7;height:calc(100% - 74px);overflow:auto"><div style="font-weight:700">本周进展</div><div data-r="wlist" style="color:var(--ik-text)"></div><div data-r="wph" style="color:var(--ik-text2);margin-top:6px;border:1.5px dashed var(--ik-hair);border-radius:8px;padding:10px;text-align:center">从绳上拖一张卡片到这里</div></div>
          <div style="position:absolute;left:0;right:0;bottom:0;height:44px;display:flex;align-items:center;justify-content:space-between;padding:0 12px;border-top:.5px solid var(--ik-hair);font-size:11px;color:var(--ik-text2)"><span>文字带着换行，文件带着副本</span><button class="ik-btn ghost" data-r="paste" type="button">⌘V 粘贴</button></div></div>
        ${[['shot', D.thumb('contract').src, '合同条款截图.png', 'img'], ['chart', D.thumb('chart').src, '季度数据.png', 'img'], ['pdf', '', '项目资料.pdf', 'pdf']].map(([k, src, nm, t], i) =>
          `<div class="ik-icon" data-src="${k}" tabindex="0" role="button" aria-label="${nm}：拖到绳子附近挂入，或按回车挂入" style="left:${ix}px;top:${iy + i * 94}px"><div class="pic">${t === 'img' ? `<img src="${src}" alt="" draggable="false" style="width:60px;height:44px;object-fit:cover;border:2px solid #fff;border-radius:3px">` : D.fileIcon('pdf', 40)}</div><span class="nm">${nm}</span></div>`).join('')}
        <div class="ik-icon folder" data-r="folder" aria-label="导出文件夹：把卡片拖到这里得到副本" style="left:${ix}px;top:${iy + 3 * 94}px;cursor:default"><div class="pic"><svg viewBox="0 0 64 50" width="58" aria-hidden="true"><path d="M2 8a4 4 0 0 1 4-4h17l6 6h29a4 4 0 0 1 4 4v30a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4z" fill="#5aa2f7"/><path d="M2 16h60v28a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4z" fill="#7cb8ff"/></svg><b data-r="fcount" style="position:absolute;margin:-30px 0 0 44px;min-width:18px;height:18px;border-radius:9px;background:#ff3b30;font-size:10px;line-height:18px;display:none">0</b></div><span class="nm">导出</span></div>
        <div data-r="line"></div>
        <div class="ik-cursor" data-r="cursor" hidden>${D.ICON.cursor}</div>`;
      if (narrow) $$('.hide-n', screen).forEach(e => e.remove());
      scaler.innerHTML = ''; scaler.appendChild(screen);
      lineEl = $('[data-r=line]', screen);
      line = new D.InkLine(lineEl, { W, interactive: true, reduced: reduced() });
      lineEl.classList.toggle('hidden', hidden);
      lo.line = line;
      wire();
      renderWriter();
    }
    const lo = { line: null, active: true }; lines.add(lo); watch(scaler, lo);

    /* 坐标换算 */
    const pt = e => { const r = screen.getBoundingClientRect(); return { x: (e.clientX - r.left) / scale, y: (e.clientY - r.top) / scale }; };
    const box = el => { const r = el.getBoundingClientRect(), s = screen.getBoundingClientRect(); return { x: (r.left - s.left) / scale, y: (r.top - s.top) / scale, w: r.width / scale, h: r.height / scale }; };
    const inBox = (p, b) => p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h;
    const near = p => p.y < 200 && p.x > 30 && p.x < W - 30;

    function feedback(msg, ms = 1800) { line.feedback(msg); clearTimeout(feedback.t); if (msg) feedback.t = setTimeout(() => line.feedback(''), ms); }
    function hang(src, o = {}) {
      const item = Object.assign({ id: nid(), tilt: tilt() }, src); delete item.file;
      if (!o.force && src.srcKey && line.live.some(c => c.item.srcKey === src.srcKey)) { feedback('没有新增材料：内容为空、重复或不支持', 2400); return null; }
      line.add(item, now(), o); if (!o.quiet) feedback('已挂入'); return item;
    }
    function hangSource(k) { if (hidden) setHidden(false); const it = hang(Object.assign({ srcKey: k }, SOURCES[k])); if (it) task('hang'); return it; }

    /* 菜单 */
    let menuEl = null;
    function closeMenu() { if (menuEl) { menuEl.remove(); menuEl = null; $$('.ik-status.on', screen).forEach(b => b.classList.remove('on')); } }
    function openMenu(items, x, y, onAct, anchor) {
      closeMenu(); menuEl = document.createElement('div'); menuEl.className = 'ik-menu'; menuEl.setAttribute('role', 'menu'); menuEl.innerHTML = D.menuHTML(items);
      screen.appendChild(menuEl); const mw = menuEl.offsetWidth, mh = menuEl.offsetHeight;
      menuEl.style.left = clamp(x, 6, W - mw - 6) + 'px'; menuEl.style.top = clamp(y, 26, H - mh - 6) + 'px';
      menuEl.addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; const a = b.dataset.act; closeMenu(); if (a) onAct(a); if (anchor) anchor.focus(); });
      menuEl.addEventListener('keydown', e => { const bs = $$('button:not(.dim)', menuEl); const i = bs.indexOf(document.activeElement); if (e.key === 'ArrowDown') { e.preventDefault(); bs[(i + 1) % bs.length].focus(); } if (e.key === 'ArrowUp') { e.preventDefault(); bs[(i - 1 + bs.length) % bs.length].focus(); } if (e.key === 'Escape') { closeMenu(); if (anchor) anchor.focus(); } });
      const first = $('button', menuEl); if (first) first.focus({ preventScroll: true });
      task('menu');
    }
    function ropeAct(a) {
      if (a === 'note') openNote();
      else if (a === 'paste') pasteHang();
      else if (a === 'files') { const k = ['shot', 'chart', 'pdf'].find(k => !line.live.some(c => c.item.srcKey === k)); if (k) hangSource(k); else feedback('没有新增材料：内容为空、重复或不支持', 2400); }
      else if (a === 'settings') openSettings();
      else if (a === 'toggle') setHidden(!hidden);
      else if (a === 'clear') { line.live.slice().forEach((c, i) => setTimeout(() => takeDown(c.item.id), i * 60)); }
      else if (a === 'details') toast('材料详情：标题、来源名称、网址、页码，可手工补录；不会凭空生成出处。');
      else toast('演示页不执行这一项；在 App 中它会照常工作。');
    }
    function pasteHang() {
      if (!S.clip) { feedback('没有新增材料：内容为空、重复或不支持', 2400); return; }
      const c = Object.assign({}, S.clip); delete c.id; delete c.srcKey; hang(c, { force: true }); task('hang');
    }

    /* 卡片动作 */
    function copyCard(c, viaMenu) {
      const it = c.item; if (it.kind === 'note' && !viaMenu) { openNote(it.id); return; }
      line.copy(it.id, now()); S.clip = it; task('copy');
      if ((it.kind === 'text' || it.kind === 'note') && navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(it.text).catch(() => {});
    }
    function takeDown(id) { const c = line.find(id); if (!c) return; if (S.note.editing === id) closeNote(); line.takeDown(id, now()); S.taken.push(c.item); refreshStorage(); }
    function cardMenu(c, x, y) {
      openMenu(D.MENUS.card(c.item.kind), x, y, a => {
        if (a === 'copy') copyCard(c, true);
        else if (a === 'copysrc') { line.copy(c.item.id, now()); S.clip = Object.assign({}, c.item, { text: c.item.text + '\n\n来源： 未登记来源' }); task('copy'); }
        else if (a === 'edit') openNote(c.item.id);
        else if (a === 'down') takeDown(c.item.id);
        else if (a === 'markup') toast('在副本上标注／编辑，原件与原始摘录保留（演示页不打开编辑器）。');
        else if (a === 'finder') toast('在 Finder 中显示的是导出副本，不是原件（演示页不打开 Finder）。');
        else ropeAct(a);
      }, c.el);
    }

    /* 写作窗口（拖出与粘贴的目标） */
    function renderWriter() {
      const list = $('[data-r=wlist]', screen), ph = $('[data-r=wph]', screen); if (!list) return;
      list.innerHTML = S.writer.map(it => it.kind === 'text' || it.kind === 'note' ? `<div style="white-space:pre-wrap;margin-top:4px">${D.esc(it.text)}</div>` : it.kind === 'image' ? `<div style="margin-top:6px;display:flex;align-items:center;gap:8px"><img src="${D.thumb(it.thumb).src}" alt="" style="width:64px;border-radius:4px;box-shadow:0 0 0 .5px var(--ik-hair)"><span style="font-size:11px;color:var(--ik-text2)">图片（PNG／TIFF 与独立副本）</span></div>` : `<div style="margin-top:6px;display:inline-flex;align-items:center;gap:6px;padding:4px 8px;border-radius:7px;background:rgba(127,127,135,.12)">${D.fileIcon(it.ext || 'pdf', 16)}<span>${D.esc(it.title)}</span><span style="font-size:10.5px;color:var(--ik-text2)">可读取副本</span></div>`).join('');
      ph.style.display = S.writer.length ? 'none' : ''; const b = $('.wbody', screen); b.scrollTop = b.scrollHeight;
    }
    function deliver(it, where) {
      if (where === 'writer') { S.writer.push(it); renderWriter(); const w = $('[data-r=writer]', screen); w.animate([{ boxShadow: '0 0 0 3px var(--ik-blue),0 18px 50px rgba(0,0,0,.22)' }, { boxShadow: '0 0 0 0 transparent,0 18px 50px rgba(0,0,0,.22)' }], { duration: 700 }); }
      else { S.folder++; S.exports++; const f = $('[data-r=fcount]', screen); f.textContent = S.folder; f.style.display = 'block'; feedback('导出副本：' + (it.title || '文字') , 2000); refreshStorage(); }
    }

    /* 记事窗口 */
    let noteEl = null, saveT;
    function openNote(editId) {
      closeMenu(); if (hidden) setHidden(false);
      if (!noteEl) { noteEl = document.createElement('div'); noteEl.className = 'ik-panel note'; noteEl.setAttribute('role', 'dialog'); noteEl.setAttribute('aria-label', '记事'); noteEl.innerHTML = D.noteHTML(); screen.appendChild(noteEl); wireNote(); }
      const nw = Math.min(488, W - 32); Object.assign(noteEl.style, { width: nw + 'px', left: clamp(D.redCenter(W) - nw / 2, 16, W - nw - 16) + 'px', top: '64px' }); noteEl.hidden = false;
      const ta = $('[data-r=ta]', noteEl);
      if (editId) { const c = line.find(editId); S.note.editing = editId; ta.value = c ? c.item.text : ''; $('.title', noteEl).textContent = '继续记事'; }
      else { S.note.editing = null; ta.value = S.note.draft; $('.title', noteEl).textContent = '记事'; }
      setSt(ta.value ? '草稿已保存到本机' : '边写边存本地草稿', !!ta.value);
      if (!reduced()) noteEl.animate([{ opacity: 0, transform: 'translateY(-8px) scale(.98)' }, { opacity: 1, transform: 'none' }], { duration: 280, easing: 'cubic-bezier(.2,.9,.3,1)' });
      ta.focus({ preventScroll: true }); S.note.open = true;
    }
    function setSt(t, ok, err) { const st = $('[data-r=st]', noteEl); st.innerHTML = (ok ? D.ICON.check : '') + `<span class="${err ? 'ik-err' : ''}">${D.esc(t)}</span>`; }
    function closeNote(focusRed) { if (!noteEl || noteEl.hidden) return; const ta = $('[data-r=ta]', noteEl); if (!S.note.editing) S.note.draft = ta.value; noteEl.hidden = true; S.note.open = false; S.note.editing = null; if (focusRed) line.redHit.focus({ preventScroll: true }); }
    function hangNote() {
      const ta = $('[data-r=ta]', noteEl), text = ta.value.replace(/\s+$/, '');
      if (!text.trim()) { setSt('记事为空，请先写正文。', false, true); ta.focus(); return; }
      if (S.note.editing) { const c = line.find(S.note.editing); if (c) { c.item.text = text; c.item.title = text.split('\n')[0]; c.el.querySelector('.ik-photo').textContent = text; line.nudge(c.item.id, 3, now()); } S.note.editing = null; }
      else { hang({ kind: 'note', text, title: text.split('\n')[0] }, { force: true }); S.note.draft = ''; ta.value = ''; }
      noteEl.hidden = true; S.note.open = false; task('note'); line.redHit.focus({ preventScroll: true });
    }
    function wireNote() {
      const ta = $('[data-r=ta]', noteEl);
      ta.addEventListener('input', () => { setSt('正在保存草稿…'); clearTimeout(saveT); saveT = setTimeout(() => { if (!S.note.editing) S.note.draft = ta.value; setSt('草稿已保存到本机', true); }, 450); });
      ta.addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && !e.isComposing) { e.preventDefault(); hangNote(); } if (e.key === 'Escape') { e.preventDefault(); closeNote(true); } e.stopPropagation(); });
      $('[data-r=hang]', noteEl).addEventListener('click', hangNote);
      $('[data-r=dismiss]', noteEl).addEventListener('click', () => closeNote(true));
    }

    /* 设置面板 */
    let setEl = null;
    function openSettings(tab = 'storage') {
      closeMenu();
      if (!setEl) { setEl = document.createElement('div'); setEl.className = 'ik-panel settings'; setEl.setAttribute('role', 'dialog'); setEl.setAttribute('aria-label', '挂入设置'); setEl.innerHTML = D.settingsHTML(); screen.appendChild(setEl); wireSettings(setEl, () => S, refreshStorage, () => task('clean')); const x = document.createElement('button'); x.className = 'ik-btn ghost'; x.textContent = '关闭'; x.type = 'button'; x.style.cssText = 'position:absolute;right:10px;top:7px;padding:4px 10px'; x.addEventListener('click', () => { setEl.hidden = true; }); setEl.appendChild(x); }
      const sw = Math.min(440, W - 32); Object.assign(setEl.style, { width: sw + 'px', left: (W - sw - 20) + 'px', top: '34px', maxHeight: (H - 44) + 'px', overflow: 'auto' });
      setEl.hidden = false; selectTab(setEl, tab); refreshStorage();
      if (!reduced()) setEl.animate([{ opacity: 0, transform: 'translateY(-8px) scale(.98)' }, { opacity: 1, transform: 'none' }], { duration: 280, easing: 'cubic-bezier(.2,.9,.3,1)' });
      $('[aria-selected=true]', setEl).focus({ preventScroll: true });
    }
    function refreshStorage() { if (setEl) storageNumbers(setEl, S); }

    function setHidden(h) { hidden = h; lineEl.classList.toggle('hidden', h); if (h) { closeNote(); } task('toggle'); }

    /* 拖拽：来源 → 绳；卡片 → 外部 */
    let drag = null, ghost = null;
    function makeGhost(html, p, cls) { ghost = document.createElement('div'); ghost.className = 'ik-ghost ' + (cls || ''); ghost.innerHTML = html; screen.appendChild(ghost); moveGhost(p); }
    function moveGhost(p) { if (ghost) ghost.style.transform = `translate(${p.x - drag.ox}px,${p.y - drag.oy}px) rotate(${drag.kind === 'out' ? -3 : 0}deg)`; }
    function endGhost(to, cb) {
      if (!ghost) { cb && cb(); return; } const g = ghost; ghost = null;
      if (to && !reduced()) { const a = g.animate([{ transform: g.style.transform, opacity: 1 }, { transform: `translate(${to.x}px,${to.y}px) scale(.6)`, opacity: 0 }], { duration: 260, easing: 'cubic-bezier(.3,.7,.3,1)' }); a.onfinish = () => { g.remove(); cb && cb(); }; }
      else { g.remove(); cb && cb(); }
    }
    function wire() {
      screen.addEventListener('contextmenu', e => {
        const p = pt(e); const peg = e.target.closest('.ik-peg');
        if (peg) { e.preventDefault(); const c = line.find(peg.dataset.id); if (c) cardMenu(c, p.x, p.y); return; }
        if (e.target.closest('.ik-red-hit')) { e.preventDefault(); openMenu(D.MENUS.rope.map(m => m !== '-' && m[2] === 'toggle' ? [hidden ? '显示材料架' : '隐藏材料架', '', 'toggle'] : m), p.x, p.y, ropeAct, line.redHit); return; }
      });
      screen.addEventListener('pointerdown', e => {
        if (e.button !== 0 || S.demo && !e.isTrusted) return;
        if (S.demo && e.isTrusted) stopDemo();
        if (menuEl && !e.target.closest('.ik-menu')) closeMenu();
        const p = pt(e);
        const src = e.target.closest('[data-src]'); const peg = e.target.closest('.ik-peg');
        if (e.target.closest('.ik-x')) { e.preventDefault(); const pg = e.target.closest('.ik-peg'); takeDown(pg.dataset.id); return; }
        if (src) { e.preventDefault(); const b = box(src); drag = { kind: 'in', key: src.dataset.src, el: src, start: p, ox: p.x - b.x, oy: p.y - b.y, moved: false, id: e.pointerId }; screen.setPointerCapture(e.pointerId); return; }
        if (peg) { const c = line.find(peg.dataset.id); if (!c) return; peg.classList.add('pressed'); const b = box(peg.querySelector('.ik-card')); drag = { kind: 'out', c, el: peg, start: p, ox: p.x - b.x, oy: p.y - b.y, moved: false, id: e.pointerId, t: now() }; screen.setPointerCapture(e.pointerId);
          if (e.pointerType !== 'mouse') drag.lp = setTimeout(() => { if (drag && !drag.moved) { peg.classList.remove('pressed'); const cc = drag.c; drag = null; cardMenu(cc, p.x, p.y); } }, 550);
          return; }
        if (hidden && p.y < 30) setHidden(false);
      });
      screen.addEventListener('pointermove', e => {
        const p = pt(e);
        if (hidden && p.y < 12 && !drag) setHidden(false);
        $$('.ik-peg.hover', screen).forEach(x => x.classList.remove('hover'));
        if (!drag) { const h = e.target.closest('.ik-peg'); if (h && e.pointerType === 'mouse') h.classList.add('hover'); return; }
        if (!drag.moved && Math.hypot(p.x - drag.start.x, p.y - drag.start.y) > 5) {
          drag.moved = true; clearTimeout(drag.lp);
          if (drag.kind === 'in') { const it = SOURCES[drag.key]; makeGhost(it.kind === 'text' ? `<div style="padding:6px 10px;border-radius:8px;background:var(--ik-glass-strong);box-shadow:0 8px 24px var(--ik-shadow);font-size:12px;max-width:220px">${D.esc(it.text.split('\n')[0])}</div>` : drag.el.querySelector('.pic').outerHTML, p); drag.el.style.opacity = .5; }
          else { drag.el.classList.remove('pressed'); drag.el.classList.add('dragging'); makeGhost(`<div class="ik-card" style="box-shadow:0 18px 40px var(--ik-shadow)">${drag.el.querySelector('.ik-photo').outerHTML}</div>`, p); }
        }
        if (!drag.moved) return;
        moveGhost(p);
        if (drag.kind === 'in') { const n = near(p) && !hidden; lineEl.classList.toggle('drop-near', n); line.feedback(n ? '松开挂入 1 项材料' : '把材料拖到绳子附近，松开挂入'); }
        else { const w = $('[data-r=writer]', screen), f = $('[data-r=folder]', screen); w.style.outline = inBox(p, box(w)) ? '3px solid var(--ik-blue)' : ''; f.classList.toggle('sel', inBox(p, box(f))); }
      });
      const up = e => {
        if (!drag) return; const d = drag; drag = null; clearTimeout(d.lp); const p = pt(e);
        if (d.kind === 'in') {
          d.el.style.opacity = ''; lineEl.classList.remove('drop-near');
          if (!d.moved) { d.el.focus({ preventScroll: true }); return; }
          if (near(p) && !hidden) { endGhost({ x: p.x - 30, y: 40 }, () => {}); hangSource(d.key); } else { line.feedback(''); endGhost({ x: box(d.el).x, y: box(d.el).y }); }
        } else {
          d.el.classList.remove('pressed', 'dragging');
          const w = $('[data-r=writer]', screen), f = $('[data-r=folder]', screen); w.style.outline = ''; f.classList.remove('sel');
          if (!d.moved) { if (!e.target.closest('.ik-x')) copyCard(d.c); return; }
          if (inBox(p, box(w))) { endGhost(null); deliver(d.c.item, 'writer'); task('dragout'); }
          else if (inBox(p, box(f))) { endGhost(null); deliver(d.c.item, 'folder'); task('dragout'); }
          else endGhost(null);
        }
      };
      screen.addEventListener('pointerup', up);
      screen.addEventListener('pointercancel', () => {
        if (!drag) return;
        clearTimeout(drag.lp);
        drag.el.style.opacity = '';
        drag.el.classList.remove('pressed', 'dragging');
        lineEl.classList.remove('drop-near'); line.feedback('');
        $('[data-r=writer]', screen).style.outline = '';
        $('[data-r=folder]', screen).classList.remove('sel');
        drag = null; endGhost(null);
      });
      screen.addEventListener('keydown', e => {
        const src = e.target.closest('[data-src]');
        if (src && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); hangSource(src.dataset.src); return; }
        const peg = e.target.closest('.ik-peg');
        if (peg) { const c = line.find(peg.dataset.id); if (!c) return;
          if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); copyCard(c); }
          else if (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) { e.preventDefault(); const b = box(peg); cardMenu(c, b.x + 40, b.y + 60); }
          else if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); const live = line.live; const i = live.indexOf(c); takeDown(c.item.id); const nx = live[i + 1] || live[i - 1]; if (nx) nx.el.focus({ preventScroll: true }); }
          else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); const live = line.live, i = live.indexOf(c), j = clamp(i + (e.key === 'ArrowRight' ? 1 : -1), 0, live.length - 1); const nc = live[j]; const s = line.scroll.to; if (nc.xTo - 75 < s || nc.xTo + 75 > s + W) { line.scrollTo(nc.xTo - W / 2, now()); task('scroll'); } nc.el.focus({ preventScroll: true }); }
        }
        if (e.key === 'Escape') closeMenu();
      });
      line.redHit.addEventListener('click', () => { if (S.note.open) { closeNote(true); return; } openNote(); });
      line.redHit.addEventListener('keydown', e => { if (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) { e.preventDefault(); openMenu(D.MENUS.rope, D.redCenter(W) - 20, 60, ropeAct, line.redHit); } });
      screen.addEventListener('wheel', e => { if (line.maxScroll() <= 0 || hidden || pt(e).y > 215) return; const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : (e.shiftKey ? e.deltaY : 0); if (!d) return; e.preventDefault(); line.scrollBy(d / scale, now(), true); task('scroll'); }, { passive: false });
      line.pager.querySelector('.prev').addEventListener('click', () => { line.page(false, now()); task('scroll'); });
      line.pager.querySelector('.next').addEventListener('click', () => { line.page(true, now()); task('scroll'); });
      $('[data-r=clip]', screen).addEventListener('click', e => { const b = box(e.currentTarget); e.currentTarget.classList.add('on'); openMenu(D.MENUS.clip.map(m => m !== '-' && m[2] === 'toggle' ? [hidden ? '显示材料架' : '隐藏材料架', '', 'toggle'] : m), b.x - 150, 26, ropeAct, e.currentTarget); });
      $('[data-r=paste]', screen).addEventListener('click', () => { if (S.clip) { deliver(S.clip, 'writer'); } else toast('剪贴板里还没有内容：先单击绳上的一张卡片。'); });
    }
    document.addEventListener('keydown', e => {
      if (e.ctrlKey && e.altKey && (e.key === 't' || e.key === 'T' || e.code === 'KeyT')) { const r = scaler.getBoundingClientRect(); if (r.bottom > 0 && r.top < innerHeight) { e.preventDefault(); setHidden(!hidden); } }
    });
    document.addEventListener('pointerdown', e => { if (menuEl && !screen.contains(e.target)) closeMenu(); });

    /* 初始状态、满绳、重置 */
    function seed() {
      const t = now(); [{ kind: 'image', thumb: 'photo', title: '午后.jpg' }, { kind: 'text', text: '下周沟通准备\n周二前整理会议记录，把待确认的问题单独列出。' }, { kind: 'file', ext: 'key', title: '方案演示.key' }].forEach((it, i) => line.add(Object.assign({ id: nid(), tilt: tilt() }, it), t - 10 + i, { quiet: true }));
    }
    function fill() { if (hidden) setHidden(false); EXTRA.forEach((it, i) => setTimeout(() => hang(Object.assign({}, it), { force: true }), reduced() ? 0 : i * 90)); setTimeout(() => feedback('满绳后保留全部卡片 · 左右滚动查看', 2600), reduced() ? 0 : 1000); }
    function reset() { stopDemo(); clearTimeout(saveT); closeMenu(); S.clip = null; S.taken = []; S.exports = 2; S.note = { open: false, draft: '', editing: null }; S.writer = []; S.folder = 0; noteEl = null; setEl = null; hidden = false; build(); seed(); doneTasks.clear(); $$('li', tasksEl).forEach(l => l.classList.remove('done')); progressEl.textContent = '0 / 8'; }
    $('#demo-fill').addEventListener('click', fill);
    $('#demo-reset').addEventListener('click', reset);

    /* 自动演示：用模拟光标走一遍主要动作 */
    let demoRun = 0; const playBtn = $('#demo-play');
    function stopDemo() { if (!S.demo) return; S.demo = false; demoRun++; playBtn.setAttribute('aria-pressed', 'false'); $('.lbl', playBtn).textContent = '自动演示'; $('.ico', playBtn).textContent = '▶'; const c = $('[data-r=cursor]', screen); if (c) c.hidden = true; }
    async function demo() {
      const run = ++demoRun; S.demo = true; playBtn.setAttribute('aria-pressed', 'true'); $('.lbl', playBtn).textContent = '停止演示'; $('.ico', playBtn).textContent = '■';
      const cur = $('[data-r=cursor]', screen); cur.hidden = false; let cx = W * .5, cy = H * .7;
      const ok = () => run === demoRun && S.demo;
      const move = (x, y, ms = 650) => new Promise(res => { const x0 = cx, y0 = cy, t0 = performance.now(); const d = reduced() ? 1 : ms; (function st() { const p = Math.min(1, (performance.now() - t0) / d), e = D.M.ease(p); cx = x0 + (x - x0) * e; cy = y0 + (y - y0) * e; cur.style.transform = `translate(${cx - 3}px,${cy - 2}px)`; if (ghost && drag) moveGhost({ x: cx, y: cy }); if (p < 1 && ok()) requestAnimationFrame(st); else res(); })(); });
      const click = async () => { cur.animate([{ transform: cur.style.transform + ' scale(1)' }, { transform: cur.style.transform + ' scale(.85)' }, { transform: cur.style.transform + ' scale(1)' }], { duration: 220 }); await sleep(160); };
      try {
        if (hidden) setHidden(false);
        const icon = $('[data-src=chart]', screen), b = box(icon); await move(b.x + 46, b.y + 30); if (!ok()) return; await click();
        drag = { kind: 'in', key: 'chart', el: icon, start: { x: cx, y: cy }, ox: 30, oy: 26, moved: true }; makeGhost(icon.querySelector('.pic').outerHTML, { x: cx, y: cy }); icon.style.opacity = .5;
        await move(W * .3, 110, 900); lineEl.classList.add('drop-near'); line.feedback('松开挂入 1 项材料'); await sleep(450); if (!ok()) return;
        lineEl.classList.remove('drop-near'); icon.style.opacity = ''; endGhost({ x: cx - 30, y: 40 }); drag = null; if (line.live.some(c => c.item.srcKey === 'chart')) feedback('没有新增材料：内容为空、重复或不支持'); else hangSource('chart'); await sleep(1300); if (!ok()) return;
        let c = line.live.find(c => c.item.kind === 'image') || line.live[0]; let bx = box(c.el.querySelector('.ik-card')); await move(bx.x + bx.w / 2, bx.y + bx.h / 2); await click(); copyCard(c); await sleep(1200); if (!ok()) return;
        const w = $('[data-r=paste]', screen), wb = box(w); await move(wb.x + wb.w / 2, wb.y + wb.h / 2); await click(); deliver(S.clip, 'writer'); await sleep(900); if (!ok()) return;
        const rc = D.redCenter(W); await move(rc, D.ropeY(rc, W) - 2); await click(); openNote(); const ta = $('[data-r=ta]', noteEl); ta.value = '';
        for (const ch of '明早 9 点前\n把补充协议发给客户') { if (!ok()) return; ta.value += ch; ta.dispatchEvent(new Event('input')); await sleep(60); }
        await sleep(700); const hb = box($('[data-r=hang]', noteEl)); await move(hb.x + hb.w / 2, hb.y + hb.h / 2, 500); await click(); hangNote(); await sleep(1100); if (!ok()) return;
        fill(); await sleep(1500); if (!ok()) return; const nb = box(line.pager.querySelector('.next')); await move(nb.x + 6, nb.y + 8); await click(); line.page(true, now()); task('scroll'); await sleep(900); await click(); line.page(true, now()); await sleep(1100); if (!ok()) return;
        c = line.live.filter(c => { const x = line.xAt(c, now()) - line.scrollAt(now()); return x > 80 && x < W - 80; })[0]; if (c) { bx = box(c.el.querySelector('.ik-card')); await move(bx.x + bx.w / 2, bx.y + bx.h / 2); drag = { kind: 'out', c, el: c.el, ox: bx.w / 2, oy: bx.h / 2, moved: true }; c.el.classList.add('dragging'); makeGhost(`<div class="ik-card">${c.el.querySelector('.ik-photo').outerHTML}</div>`, { x: cx, y: cy }); const wr = box($('[data-r=writer]', screen)); await move(wr.x + wr.w / 2, wr.y + wr.h / 2, 1000); c.el.classList.remove('dragging'); endGhost(null); drag = null; deliver(c.item, 'writer'); task('dragout'); await sleep(900); }
        if (!ok()) return; const cb = box($('[data-r=clip]', screen)); await move(cb.x + 12, cb.y + 10); await click(); openSettings('storage'); await sleep(1200); if (!ok()) return;
        const pv = box($('[data-r=preview]', setEl)); await move(pv.x + pv.w / 2, pv.y + pv.h / 2); await click(); $('[data-r=preview]', setEl).click(); await sleep(1600);
      } finally { if (run === demoRun) stopDemo(); }
    }
    playBtn.addEventListener('click', () => S.demo ? stopDemo() : demo());

    build(); seed();
    let rw = scaler.clientWidth; new ResizeObserver(() => {
      const w = scaler.clientWidth; if (Math.abs(w - rw) <= 2) return;
      rw = w; const keep = line.live.map(c => c.item);
      const wasOpen = noteEl && !noteEl.hidden, editId = S.note.editing;
      const text = noteEl ? $('[data-r=ta]', noteEl).value : S.note.draft;
      clearTimeout(saveT); if (!editId) S.note.draft = text;
      noteEl = null; setEl = null; S.note.open = false; build();
      const t = now(); keep.forEach(it => line.add(it, t - 10, { quiet: true }));
      if (wasOpen) { openNote(editId); $('[data-r=ta]', noteEl).value = text; }
    }).observe(scaler);
    mq.addEventListener('change', () => { line.reduced = reduced(); });
    return { get line() { return line; }, S, hangSource, fill, openNote, openSettings, cardMenu: (i) => { const c = line.live[i]; const b = box(c.el); cardMenu(c, b.x + 90, b.y + 70); }, setHidden, deliver, copyCard, takeDown, screen: () => screen, W: () => W };
  }

  /* 设置面板公共逻辑（桌面与隐私区共用） */
  function selectTab(el, tab) { $$('[data-tab]', el).forEach(b => b.setAttribute('aria-selected', b.dataset.tab === tab)); $$('[data-pane]', el).forEach(p => p.hidden = p.dataset.pane !== tab); }
  function fmt(m) { return m.toFixed(1) + ' MiB'; }
  function storageNumbers(el, S) {
    const takenMiB = S.taken.reduce((a, it) => a + (it.kind === 'image' ? 1.6 : it.kind === 'text' || it.kind === 'note' ? 0.1 : 2.4), 0);
    const mat = 47.6 + (S.extraMat || 0), exp = S.exports * 1.3;
    $('[data-r=mat]', el).textContent = fmt(mat); $('[data-r=exp]', el).textContent = fmt(exp); $('[data-r=total]', el).textContent = fmt(mat + exp + 1.1);
    S._pending = { n: S.taken.length, e: S.exports, size: takenMiB + S.exports * 1.3 };
  }
  function wireSettings(el, getS, refresh, onDone) {
    $$('[data-tab]', el).forEach(b => b.addEventListener('click', () => selectTab(el, b.dataset.tab)));
    $$('[role=tablist]', el).forEach(tl => tl.addEventListener('keydown', e => { if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { const bs = $$('[data-tab]', tl); const i = bs.indexOf(document.activeElement); const n = bs[(i + 1) % 2]; n.focus(); n.click(); } }));
    $$('.ik-toggle', el).forEach(t => t.addEventListener('click', () => t.setAttribute('aria-checked', t.getAttribute('aria-checked') !== 'true')));
    const sheet = $('[data-r=sheet]', el), msg = $('[data-r=msg]', el);
    $('[data-r=finder]', el).addEventListener('click', () => toast('在 Finder 中显示：~/Library/Application Support/Inkpeg/（演示页不打开 Finder）'));
    $('[data-r=preview]', el).addEventListener('click', () => {
      const S = getS(); refresh(); const p = S._pending;
      if (!p.n && !p.e) { msg.textContent = '暂无可清理内容。最近 24 小时的导出和含编辑草稿的资料会保留。'; return; }
      $('[data-r=sum]', el).textContent = `已取下资料 ${p.n} 项 · 临时导出 ${p.e} 项\n将从资料库移出 ${fmt(p.size)}`; sheet.hidden = false; $('[data-r=confirm]', el).focus({ preventScroll: true });
    });
    $('[data-r=cancel]', el).addEventListener('click', () => { sheet.hidden = true; $('[data-r=preview]', el).focus({ preventScroll: true }); });
    $('[data-r=confirm]', el).addEventListener('click', () => { const S = getS(), p = S._pending; sheet.hidden = true; msg.textContent = `已将 ${p.n + p.e} 项（${fmt(p.size)}）移入废纸篓。真正释放空间需要自行清空废纸篓。`; S.taken = []; S.exports = 0; refresh(); onDone && onDone(); });
    sheet.addEventListener('keydown', e => { if (e.key === 'Escape') { sheet.hidden = true; } });
  }

  const PG = Playground(); window.__inkpeg = PG;

  /* ---------- 隐私区：独立的设置面板 ---------- */
  (function privacyPanel() {
    const host = $('#panel-scaler'); if (!host) return;
    const S = { taken: [{ kind: 'image' }, { kind: 'file' }, { kind: 'text' }], exports: 2 };
    let el;
    function build() {
      const cw = host.clientWidth, W = Math.max(560, cw), sc = Math.min(1, cw / W), H = 610; host.style.height = Math.round(H * sc) + 'px';
      const scr = makeScreen(W, H); scr.style.setProperty('--ik-scale', sc); scr.style.background = 'none'; host.innerHTML = ''; host.appendChild(scr);
      el = document.createElement('div'); el.className = 'ik-panel'; el.setAttribute('role', 'region'); el.setAttribute('aria-label', '设置面板示意'); el.style.cssText = `left:${(W - 480) / 2}px;top:28px;width:480px`; el.innerHTML = D.settingsHTML(); scr.appendChild(el);
      wireSettings(el, () => S, () => storageNumbers(el, S)); storageNumbers(el, S);
    }
    build(); let w0 = host.clientWidth; new ResizeObserver(() => { if (Math.abs(host.clientWidth - w0) > 2) { w0 = host.clientWidth; build(); } }).observe(host);
  })();

  /* ---------- 故事：滚动驱动 ---------- */
  (function story() {
    const stage = $('#story-stage'), steps = $$('#story-steps li'); if (!stage) return;
    let W, H, scr, line, lo = { line: null, active: true }; lines.add(lo); watch(stage, lo);
    const shots = ['15.02.11', '15.04.37', '15.09.02', '15.11.48', '15.20.13', '15.26.55', '15.31.07', '15.42.30', '15.47.19'];
    const thumbs = ['contract', 'chart', 'ui', 'flow', 'photo', 'board', 'receipt', 'contract', 'chart'];
    let items = [], cap, clipBox, wins = [], cur = -1;
    function build() {
      W = stage.clientWidth; H = stage.clientHeight; scr = makeScreen(W, H); scr.style.background = 'none'; stage.innerHTML = ''; stage.appendChild(scr);
      const r = D.rng(7);
      items = shots.map((s, i) => { const d = document.createElement('div'); d.className = 's-item s-file'; d.innerHTML = `<img alt="" src="${D.thumb(thumbs[i]).src}"><span>截屏2026-10-12<br>${s}.png</span>`; const cols = W < 460 ? 3 : 3, gx = (W - 40) / cols, gy = (H - 150) / 3; d._home = { x: 20 + (i % cols) * gx + r() * (gx - 96), y: 60 + Math.floor(i / cols) * gy + r() * (gy - 80), a: r() * 14 - 7 }; scr.appendChild(d); return d; });
      clipBox = document.createElement('div'); clipBox.className = 's-item s-clip'; clipBox.innerHTML = '<div class="h"><span>剪贴板</span><span>只有 1 个位置</span></div><div class="slot"><span class="a">“第一段：合同第 7 条的违约责任……”</span><span class="b" style="opacity:0">“第二段：补充协议的生效条件……”</span></div>'; scr.appendChild(clipBox);
      wins = [0, 1, 2].map(i => { const w = document.createElement('div'); w.className = 's-item s-win'; w.innerHTML = `<div class="bar"><i></i><i></i><i></i><span style="margin-left:6px">${['聊天记录', '浏览器 · 12 个标签', '访达 · 下载'][i]}</span></div><div class="ln"></div><div class="ln" style="width:60%"></div><div class="ln" style="width:75%"></div>`; scr.appendChild(w); return w; });
      cap = document.createElement('div'); cap.className = 'story-cap'; scr.appendChild(cap);
      const le = document.createElement('div'); scr.appendChild(le); line = new D.InkLine(le, { W, reduced: reduced() }); le.style.opacity = 0; lo.line = line; line.hint.remove(); line.redHit.tabIndex = -1;
      cur = -1; go(Math.max(0, steps.findIndex(s => s.classList.contains('active'))), true);
    }
    const G = window.gsap;
    function go(i, instant) {
      if (i === cur) return; cur = i; steps.forEach((s, k) => s.classList.toggle('active', k === i));
      const d = (instant || reduced() || !G) ? 0 : .7, set = (el, v) => G ? G.to(el, Object.assign({ duration: d, ease: 'power3.out', overwrite: true }, v)) : Object.assign(el.style, { opacity: v.opacity ?? '', transform: `translate(${v.x || 0}px,${v.y || 0}px) rotate(${v.rotation || 0}deg) scale(${v.scale ?? 1})` });
      const lineEl = line.root;
      cap.textContent = ['桌面上的第 9 张截图，是哪一张？', '复制第二段，第一段就没了。', '⌘Tab 一下午按了几十次。', '挂在绳上：单击复制，拖出副本。'][i];
      items.forEach((it, k) => { const h = it._home; if (i === 0) set(it, { x: h.x, y: h.y, rotation: h.a, opacity: 1, scale: 1 }); else if (i < 3) set(it, { x: h.x, y: h.y + 20, rotation: h.a, opacity: .22, scale: .9 }); else set(it, { x: W / 2 - 44 + (k - 4) * 26, y: 70, rotation: 0, opacity: 0, scale: .4 }); });
      set(clipBox, i === 1 ? { opacity: 1, y: 0, scale: 1 } : { opacity: 0, y: 30, scale: .96 });
      if (i === 1 && G && !reduced()) { const a = $('.a', clipBox), b = $('.b', clipBox); G.fromTo(a, { opacity: 1, y: 0 }, { opacity: 0, y: -26, delay: 1, duration: .5 }); G.fromTo(b, { opacity: 0, y: 26 }, { opacity: 1, y: 0, delay: 1, duration: .5 }); }
      else if (i === 1) { $('.a', clipBox).style.opacity = 0; $('.b', clipBox).style.opacity = 1; }
      wins.forEach((w, k) => { const pos = [[.08, .2], [.3, .38], [.5, .16]][k]; if (i === 2) { set(w, { x: pos[0] * W, y: pos[1] * H, opacity: 1, rotation: 0, scale: 1 }); if (G && !reduced()) G.to(w, { x: [.5, .08, .3][k] * W, y: [.16, .2, .38][k] * H, duration: .6, delay: 1 + k * .15, repeat: -1, yoyo: true, repeatDelay: .8, ease: 'power2.inOut' }); } else set(w, { x: pos[0] * W, y: pos[1] * H + 30, opacity: 0, scale: .96 }); });
      lineEl.style.transition = 'opacity .5s'; lineEl.style.opacity = i === 3 ? 1 : 0;
      if (i === 3) { const t = now(); line.live.forEach(c => line.takeDown(c.item.id, t - 5)); line.frame(t); [{ kind: 'image', thumb: 'contract' }, { kind: 'text', text: '第一段：合同第 7 条的违约责任……' }, { kind: 'image', thumb: 'chart' }, { kind: 'text', text: '第二段：补充协议的生效条件……' }, { kind: 'file', ext: 'pdf', title: '项目资料.pdf' }].slice(0, W < 520 ? 3 : W < 700 ? 4 : 5).forEach((it, k) => setTimeout(() => line.add(Object.assign({ id: nid(), tilt: tilt() }, it), now(), { quiet: reduced() }), reduced() ? 0 : 250 + k * 160)); }
    }
    build();
    if (window.ScrollTrigger && G) { G.registerPlugin(ScrollTrigger); steps.forEach((s, i) => ScrollTrigger.create({ trigger: s, start: 'top 62%', end: 'bottom 38%', onEnter: () => go(i), onEnterBack: () => go(i) })); }
    else steps.forEach((s, i) => s.addEventListener('click', () => go(i)));
    steps.forEach((s, i) => { s.tabIndex = 0; s.addEventListener('focus', () => go(i)); });
    let w0 = stage.clientWidth; new ResizeObserver(() => { if (Math.abs(stage.clientWidth - w0) > 2) { w0 = stage.clientWidth; build(); } }).observe(stage);
  })();

  /* ---------- 功能格：小型活体示意 ---------- */
  (function bento() {
    const tiles = $$('#bento .tile'); if (!tiles.length) return;
    const mk = (tile, fn) => { const viz = $('.viz', tile); if (!viz || viz.classList.contains('viz-key')) return; const W = viz.clientWidth, H = viz.clientHeight; const scr = makeScreen(W, H); viz.appendChild(scr); const le = document.createElement('div'); scr.appendChild(le); const line = new D.InkLine(le, { W, reduced: reduced() }); line.hint.remove(); line.redHit.tabIndex = -1; line.redHit.setAttribute('aria-hidden', 'true'); const o = { line, active: false }; lines.add(o); watch(viz, o); fn({ W, H, scr, line, o }); };
    const every = (o, ms, f) => { let t = null; o.onVis = v => { clearInterval(t); if (v && !reduced()) { f(); t = setInterval(f, ms); } }; };
    const item = (it) => Object.assign({ id: nid(), tilt: tilt() }, it);
    mk($('.t-drop'), ({ W, scr, line, o }) => {
      const gh = document.createElement('div'); gh.className = 'ik-ghost'; scr.appendChild(gh); const pool = [{ kind: 'image', thumb: 'contract' }, { kind: 'text', text: '一段摘录\n带着换行' }, { kind: 'pdf', ext: 'pdf', title: '项目资料.pdf' }, { kind: 'image', thumb: 'flow' }, { kind: 'file', ext: 'docx', title: '会议纪要.docx' }]; let k = 0;
      line.add(item(pool[0]), now(), { quiet: true }); line.add(item(pool[2]), now(), { quiet: true });
      every(o, 2600, () => {
        const it = pool[k++ % pool.length]; gh.innerHTML = it.kind === 'image' ? `<img src="${D.thumb(it.thumb).src}" style="width:70px;border:2px solid #fff;border-radius:4px;box-shadow:0 8px 20px rgba(0,0,0,.25)">` : D.fileIcon(it.ext || 'txt', 40);
        const a = gh.animate([{ transform: `translate(${W * .72}px,170px)`, opacity: 0 }, { transform: `translate(${W * .7}px,150px)`, opacity: 1, offset: .15 }, { transform: `translate(${W * .5}px,40px)`, opacity: 1, offset: .8 }, { transform: `translate(${W * .5}px,30px) scale(.6)`, opacity: 0 }], { duration: 1300, easing: 'ease-in-out', fill: 'forwards' });
        setTimeout(() => { line.root.classList.add('drop-near'); line.feedback('松开挂入 1 项材料'); }, 600);
        a.onfinish = () => { line.root.classList.remove('drop-near'); if (line.live.length >= (W < 420 ? 2 : 4)) line.takeDown(line.live[0].item.id, now()); line.add(item(it), now()); line.feedback('已挂入'); setTimeout(() => line.feedback(''), 900); };
      });
    });
    mk($('.t-copy'), ({ W, scr, line, o }) => { line.add(item({ kind: 'image', thumb: 'chart' }), now(), { quiet: true }); if (W > 330) line.add(item({ kind: 'text', text: '周三 10:00 约见客户\n带上补充协议第二稿' }), now(), { quiet: true });
      const cur = document.createElement('div'); cur.className = 'ik-cursor'; cur.innerHTML = D.ICON.cursor; scr.appendChild(cur); let i = 0;
      const place = () => { const c = line.live[i % line.live.length]; const x = c.xTo - line.scroll.to; cur.style.transform = `translate(${x + 10}px,${D.ropeY(x, W) + 60}px)`; return c; };
      place(); every(o, 2000, () => { const c = place(); cur.animate([{ scale: 1 }, { scale: .82 }, { scale: 1 }], { duration: 220 }); line.copy(c.item.id, now()); i++; setTimeout(place, 1500); });
    });
    mk($('.t-note'), ({ W, H, scr, line, o }) => {
      const n = document.createElement('div'); n.className = 'ik-panel'; n.style.cssText = `left:${Math.max(8, D.redCenter(W) - 150)}px;top:58px;width:300px;border-radius:14px`; n.innerHTML = '<div class="ik-bar" style="height:28px"><span class="ik-lights"><i></i><i></i><i></i></span><span class="title">记事</span></div><div style="padding:10px 16px;font-size:13px;line-height:1.7;min-height:56px;white-space:pre-wrap" data-r="t"></div><div class="ik-note-foot" style="padding:6px 10px"><span class="st" data-r="s">边写边存本地草稿</span><span class="ik-btn primary" style="padding:3px 8px;font-size:11px">挂上去<kbd>⌘↩</kbd></span></div>'; scr.appendChild(n);
      const red = $('.ik-rope .red', line.root); const txt = '下周沟通准备\n先列出待确认的问题'; const t = $('[data-r=t]', n), s = $('[data-r=s]', n);
      if (reduced()) { t.textContent = txt; s.innerHTML = D.ICON.check + '草稿已保存到本机'; }
      every(o, 5200, () => { red.animate([{ strokeWidth: 2.4 }, { strokeWidth: 5 }, { strokeWidth: 2.4 }], { duration: 600 }); let k = 0; t.textContent = ''; s.textContent = '正在保存草稿…'; const iv = setInterval(() => { t.textContent = txt.slice(0, ++k); if (k >= txt.length) { clearInterval(iv); s.innerHTML = D.ICON.check + '草稿已保存到本机'; } }, 110); });
    });
    mk($('.t-menu'), ({ W, scr, line }) => { line.add(item({ kind: 'text', text: '“好的工具，让注意力回到事情本身。”\n——读书摘录' }), now(), { quiet: true }); const m = document.createElement('div'); m.className = 'ik-menu'; m.setAttribute('aria-hidden', 'true'); m.innerHTML = D.menuHTML(D.MENUS.card('text')).replace(/<button/g, '<div class="mi"').replace(/<\/button>/g, '</div>'); m.style.cssText = `left:${W / 2 + 20}px;top:44px;transform:scale(.86);transform-origin:0 0`; scr.appendChild(m); $$('.mi', m)[1].classList.add('hl'); });
    mk($('.t-scroll'), ({ W, line, o }) => { const pool = ['contract', 'chart', 'ui', 'flow', 'photo', 'board', 'receipt', 'contract', 'chart', 'ui']; pool.forEach(p => line.add(item({ kind: 'image', thumb: p }), now(), { quiet: true })); line.scrollTo(0, now(), true); let dir = 1; every(o, 1700, () => { const ms = line.maxScroll(); if (line.scroll.to >= ms - 1) dir = -1; if (line.scroll.to <= 1) dir = 1; line.page(dir > 0, now()); }); });
    mk($('.t-out'), ({ W, H, scr, line, o }) => {
      line.add(item({ kind: 'text', text: '第一行\n第二行\n第三行' }), now(), { quiet: true });
      const box = document.createElement('div'); box.className = 'ik-win'; box.style.cssText = `left:${W / 2 + 10}px;top:116px;width:${Math.min(220, W / 2 - 24)}px;height:74px;border-radius:10px;padding:8px 12px;font-size:11.5px;line-height:1.5`; box.innerHTML = '<span style="color:var(--ik-text2)">输入框</span><div data-r="v" style="white-space:pre-wrap"></div>'; scr.appendChild(box);
      const gh = document.createElement('div'); gh.className = 'ik-ghost'; gh.innerHTML = `<div class="ik-card" style="transform:scale(.7);transform-origin:0 0">${line.live[0].el.querySelector('.ik-photo').outerHTML}</div>`; scr.appendChild(gh);
      const v = $('[data-r=v]', box); if (reduced()) v.textContent = '第一行\n第二行'; every(o, 3000, () => { v.textContent = ''; const x0 = W / 2 - 50; const a = gh.animate([{ transform: `translate(${x0}px,40px)`, opacity: 0 }, { transform: `translate(${x0}px,40px)`, opacity: .95, offset: .1 }, { transform: `translate(${W / 2 + 40}px,100px) rotate(-4deg)`, opacity: .95, offset: .85 }, { transform: `translate(${W / 2 + 40}px,104px)`, opacity: 0 }], { duration: 1400, easing: 'ease-in-out', fill: 'forwards' }); a.onfinish = () => { v.textContent = '第一行\n第二行\n第三行'; }; });
    });
    mk($('.t-auto'), ({ W, scr, line, o }) => {
      line.root.style.display = 'none'; const p = document.createElement('div'); p.className = 'ik-panel'; p.style.cssText = `left:50%;transform:translateX(-50%);top:18px;width:${Math.min(400, W - 24)}px;border-radius:14px`; p.innerHTML = '<div class="ik-set" style="padding:6px 14px 12px"><div class="ik-group"><div class="ik-row"><div>复制后自动挂入<small>默认关闭 · 可随时暂停</small></div><span class="ik-toggle" data-r="a" aria-checked="false"></span></div><div class="ik-row"><div><div class="ik-check"><i>✓</i>接收图片</div><div class="ik-check"><i>✓</i>接收文字</div></div><div><div class="ik-check"><i class="off"></i>接收文件</div><div class="ik-check"><i class="off"></i>启动时已有内容</div></div></div><div class="ik-row"><div>截图目录监听<small>只接收新保存的截图，已有图片不补挂</small></div><span class="ik-toggle" aria-checked="false"></span></div></div></div>'; scr.appendChild(p);
      const tg = $('[data-r=a]', p); every(o, 2200, () => tg.setAttribute('aria-checked', tg.getAttribute('aria-checked') !== 'true'));
    });
    (function keys() { const v = $('.viz-key'); if (!v) return; const ks = $$('kbd', v); const o = { active: false }; watch(v, o); let t; o.onVis = vis => { clearInterval(t); if (vis && !reduced()) t = setInterval(() => { ks.forEach((k, i) => setTimeout(() => k.classList.add('press'), i * 120)); setTimeout(() => ks.forEach(k => k.classList.remove('press')), 700); }, 2000); }; })();
  })();

  /* ---------- 下载：读取版本元数据 ---------- */
  /* release.json 的 sizeBytes / sha256 为真实值时才启用下载；占位状态（pending）下按钮保持停用并显示“待定”。 */
  (function () {
    const btn = $('#download-btn'), sizeEl = $('#download-size'), shaEl = $('#sha-value');
    const pending = () => { btn.classList.add('is-pending'); btn.setAttribute('aria-disabled', 'true'); };
    btn.addEventListener('click', e => { if (btn.getAttribute('aria-disabled') === 'true') { e.preventDefault(); toast('2.0 安装包尚未上传，请稍后再来'); } });
    pending();
    fetch('downloads/release.json', { cache: 'no-store' }).then(r => r.ok ? r.json() : null).then(j => {
      const ok = j && !j.pending && Number.isFinite(j.sizeBytes) && j.sizeBytes > 0 && /^[0-9a-f]{64}$/.test(j.sha256 || '') && j.file;
      if (!ok) return pending();
      btn.href = 'downloads/' + encodeURIComponent(j.file); btn.setAttribute('download', j.file);
      sizeEl.textContent = `（${(j.sizeBytes / 1e6).toFixed(1)} MB）`; shaEl.textContent = j.sha256;
      if (j.installCommand) $('#install-command').textContent = j.installCommand;
      btn.classList.remove('is-pending'); btn.removeAttribute('aria-disabled');
    }).catch(pending);
  })();
  $('#sha-copy').addEventListener('click', () => { const v = $('#sha-value').textContent; (navigator.clipboard && window.isSecureContext ? navigator.clipboard.writeText(v) : Promise.reject()).then(() => toast('已复制 SHA-256'), () => toast('请手动选择并复制校验值')); });

  $('#install-command-copy').addEventListener('click', () => {
    const value = $('#install-command').textContent;
    (navigator.clipboard && window.isSecureContext ? navigator.clipboard.writeText(value) : Promise.reject()).then(
      () => toast('已复制，打开终端粘贴并按回车'),
      () => { $('.install-command-box details').open = true; const selection = getSelection(), range = document.createRange(); range.selectNodeContents($('#install-command')); selection.removeAllRanges(); selection.addRange(range); toast('请复制已选中的安装命令'); }
    );
  });

  /* ---------- 首屏入场 ---------- */
  if (window.gsap && !reduced()) { gsap.from('.hero h1 .line', { yPercent: 40, opacity: 0, duration: .9, stagger: .12, ease: 'power3.out' }); gsap.from('.lead,.hero-cta,.status-line', { y: 18, opacity: 0, duration: .8, delay: .25, stagger: .08, ease: 'power3.out' }); }


  /* ---------- 进入视口时淡入（只隐藏首屏以下的元素） ---------- */
  if (!reduced() && 'IntersectionObserver' in window && !Q.get('state') && !Q.has('noreveal')) {
    const els = $$('.tile,.status .col,.steps li,.promises li,.lib-tree,.panel-preview').filter(el => el.getBoundingClientRect().top > innerHeight);
    els.forEach(el => el.classList.add('reveal-pre'));
    const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('reveal-in'); e.target.classList.remove('reveal-pre'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px' });
    els.forEach(el => io.observe(el));
  }

  /* ---------- 截图／验收用的直达状态 ---------- */
  const st = Q.get('state');
  if (PG && st) setTimeout(() => {
    const L0 = PG.line;
    if (st === 'received' || st === 'menu' || st === 'copy') { PG.hangSource('shot'); PG.hangSource('quote'); }
    if (st === 'received') { PG.deliver(SOURCES.quote, 'writer'); PG.deliver(SOURCES.pdf, 'writer'); }
    if (st === 'copy') setTimeout(() => PG.copyCard(PG.line.live[3]), 900);
    if (st === 'menu') setTimeout(() => PG.cardMenu(4), 900);
    if (st === 'note') { PG.openNote(); const ta = $('#ik-note-ta'); ta.value = '下周沟通准备\n\n周二前整理会议记录，把待确认的问题单独列出。\n带上两份方案和对应的参考图片。'; ta.dispatchEvent(new Event('input')); }
    if (st === 'overflow') { PG.fill(); setTimeout(() => { PG.line.scrollTo(PG.line.maxScroll() * .5, now()); }, 1300); }
    if (st === 'settings' || st === 'cleanup') { PG.takeDown(PG.line.live[0].item.id); PG.openSettings('storage'); if (st === 'cleanup') setTimeout(() => $('.pg-screen [data-r=preview]').click(), 300); }
    if (st === 'intake') PG.openSettings('intake');
    if (st === 'hidden') PG.setHidden(true);
    if (st === 'dropping') { const s = PG.screen(); s.querySelector('[data-r=line]').classList.add('drop-near'); PG.line.feedback('松开挂入 1 项材料'); }
  }, 600);
})();
