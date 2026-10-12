/* 宣传片：静音预告片仅在可见且未开启“减弱动态效果”时自动播放；完整版仅在点击后有声播放。无第三方播放器。 */
(function () {
  'use strict';
  const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
  const root = document.documentElement, mq = matchMedia('(prefers-reduced-motion: reduce)');
  const reduced = () => mq.matches || root.classList.contains('reduce-motion');
  const frame = $('.film-frame'), teaser = $('#film-teaser'), play = $('#film-play');
  const dlg = $('#film-dialog'), video = $('#film-video'), closeBtn = $('#film-close');
  if (!frame || !dlg || !video) return;
  let teaserLoaded = false, inView = false, opener = null;

  /* 预告片：进入视口附近才挂上视频源（懒加载） */
  function loadTeaser() {
    if (teaserLoaded) return; teaserLoaded = true;
    JSON.parse(teaser.dataset.sources).forEach(([src, type]) => { const s = document.createElement('source'); s.src = src; s.type = type; teaser.appendChild(s); });
    teaser.load();
  }
  function syncTeaser() {
    const want = inView && !reduced() && !dlg.open && document.visibilityState === 'visible';
    if (want) { loadTeaser(); const p = teaser.play(); if (p && p.catch) p.catch(() => {}); }
    else if (!teaser.paused) teaser.pause();
  }
  teaser.addEventListener('playing', () => { teaser.classList.add('on'); frame.classList.add('playing'); });
  teaser.addEventListener('pause', () => frame.classList.remove('playing'));
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(es => es.forEach(e => { inView = e.isIntersecting && e.intersectionRatio >= .35; syncTeaser(); }), { threshold: [0, .35, .7] }).observe(frame);
  }
  document.addEventListener('visibilitychange', () => { syncTeaser(); if (document.visibilityState !== 'visible' && !video.paused) video.pause(); });
  mq.addEventListener && mq.addEventListener('change', () => { if (reduced()) { teaser.pause(); teaser.classList.remove('on'); } syncTeaser(); });

  /* 完整版：点击后打开灯箱，有声播放 */
  function open(t, from) {
    opener = from || document.activeElement;
    if (!video.poster) video.poster = video.dataset.poster;
    if (video.preload !== 'auto') { video.preload = 'auto'; }
    if (typeof dlg.showModal === 'function') dlg.showModal(); else dlg.setAttribute('open', '');
    root.classList.add('film-lock'); syncTeaser();
    const start = () => { try { video.currentTime = t || 0; } catch (e) {} video.muted = false; const p = video.play(); if (p && p.catch) p.catch(() => {}); };
    if (video.readyState >= 1) start(); else { video.addEventListener('loadedmetadata', start, { once: true }); video.load(); }
    video.focus({ preventScroll: true });
  }
  function close() {
    if (!video.paused) video.pause();
    if (dlg.open) { if (typeof dlg.close === 'function') dlg.close(); else dlg.removeAttribute('open'); }
    root.classList.remove('film-lock'); syncTeaser();
    if (opener && opener.focus) opener.focus({ preventScroll: true });
  }
  play.addEventListener('click', () => open(0, play));
  $$('.film-chapters button').forEach(b => b.addEventListener('click', () => open(+b.dataset.t, b)));
  closeBtn.addEventListener('click', close);
  dlg.addEventListener('cancel', e => { e.preventDefault(); close(); });             // Esc（原生 dialog）
  dlg.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); close(); } });
  dlg.addEventListener('click', e => { if (e.target === dlg) close(); });            // 点遮罩关闭
  dlg.addEventListener('close', () => { if (!video.paused) video.pause(); root.classList.remove('film-lock'); syncTeaser(); });
  video.addEventListener('ended', () => { /* 停在片尾卡，用户自行关闭 */ });
  window.__film = { open, close, video, teaser };
})();
