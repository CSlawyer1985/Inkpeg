'use strict';
(() => {
  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const desktop = $('#desktop'), shelf = $('#shelf'), track = $('#shelf-track');
  const ropeArea = $('#rope-area'), receiveZone = $('#receive-zone');
  const guides = [
    { title: '产生 · 这句话，等会儿还要用。', description: '一份阅读摘记，从眼前的文章开始。演示中的材料不离开此页。' },
    { title: '挂入 · 把这份摘记挂到绳上。', description: '小红段打开记事，按“挂上去”保存。输入任意文字即可接管。' },
    { title: '找到 · 还是刚才那份摘记。', description: '左右滑动，或点箭头。挂满了也不自动取下，材料仍在手边。' },
    { title: '复用 · 原样放到下一处。', description: '点文字卡复制；记事卡单击继续写。菜单或拖出手柄可送到输入窗口。' }
  ];
  const { createDemoState, reduceDemo, editorText } = InkpegDemo;
  let state = createDemoState(), cards = state.userCards, step = 0;
  let guideTimeline = null, guideTimers = [], toastTimer = null, selectedID = null;
  let lastNoteTrigger = null, gesture = null, receivedOwner = 'user', suppressClickUntil = 0;
  function syncViewport() {
    const viewport = window.visualViewport;
    document.documentElement.style.setProperty('--visible-height', (viewport?.height || innerHeight) + 'px');
    document.documentElement.style.setProperty('--visible-top', (viewport?.offsetTop || 0) + 'px');
  }
  window.visualViewport?.addEventListener('resize', syncViewport);
  window.visualViewport?.addEventListener('scroll', syncViewport);
  window.addEventListener('resize', syncViewport);
  syncViewport();
  function focusCard(id, fallback = $('#new-note')) {
    const element = id ? track.querySelector(`[data-card="${id}"]`) : null;
    const target = element || fallback;
    target?.focus({ preventScroll: true });
    target?.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
  }
  function renderRecovery() {
    const entries = state.takenDown;
    $('#recent-taken-down').hidden = $('#undo-take-down').hidden = !entries.length;
    $('#recovery-list').innerHTML = entries.slice().reverse().map(({ card }) => `<button data-recover="${card.id}">找回：${escapeHTML(card.title)}</button>`).join('');
  }
  function closeRecovery(restore = true) {
    const wasOpen = !$('#recovery-dialog').hidden;
    $('#recovery-dialog').hidden = true;
    $('#recent-taken-down').setAttribute('aria-expanded', 'false');
    if (restore && wasOpen) focusCard(null, $('#recent-taken-down').hidden ? $('#new-note') : $('#recent-taken-down'));
  }
  function recoverCard(id) {
    interruptGuide(); dispatch({ type: 'RECOVER', cardID: id });
    closeRecovery(false); renderCards(id); focusCard(id); toast('已找回副本 · 继续接着用');
  }
  function dispatch(command) {
    const old = state;
    state = reduceDemo(state, command);
    cards = [...state.userCards, ...(state.scenario.status === 'completed' ? [] : state.scenario.cards)];
    return old !== state;
  }
  const escapeHTML = value => String(value).replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
  const fileIcon = '<svg viewBox="0 0 42 52" aria-hidden="true"><path d="M6 1h20l12 12v38H6z" fill="#f1f1e8" stroke="#b6bcb0"/><path d="M26 1v12h12M13 21h17M13 26h17M13 31h13" fill="none" stroke="#b6bcb0"/><rect x="1" y="35" width="29" height="13" rx="2" fill="#ac5b46"/><text x="5" y="45" fill="white" font-family="system-ui" font-size="8">PDF</text></svg>';
  const kindLabel = kind => ({ image: '截图 / 图片', text: '文字', note: '记事', file: '文件副本' })[kind];
  function cardBody(card) {
    const content = card.kind === 'image' ? `<img class="card-image" src="${card.image}" alt="绿色山峦与落日">` : card.kind === 'file' ? `<span class="card-file">${fileIcon}<span>等会儿接着用</span></span>` : `<span class="card-text">${escapeHTML(card.text)}</span>`;
    return `<span class="card-kind">${kindLabel(card.kind)}</span>${content}<span class="card-title">${escapeHTML(card.title)}</span>`;
  }
  function renderCards(newID) {
    const focusedID = document.activeElement?.closest("[data-card]")?.dataset.card;
    const oldOffset = shelf.scrollLeft;
    track.innerHTML = cards.map(card => {
      const action = card.kind === 'note' ? '继续记事' : card.kind === 'text' ? '复制文字' : '在网页输入窗口预览复用';
      return `<div class="peg-wrap"><button class="peg-card${card.kind === 'note' ? ' card-note' : ''}" data-card="${card.id}" aria-label="${escapeHTML(card.title)}，${action}" title="${action}">${cardBody(card)}<span class="drag-handle" aria-hidden="true">⠿ 拖出</span></button><button class="card-menu" data-menu="${card.id}" aria-haspopup="dialog" aria-controls="card-popover" aria-label="${escapeHTML(card.title)}的操作菜单">···</button></div>`;
    }).join('');
    shelf.scrollLeft = oldOffset;
    updateShelf(); renderRecovery();
    if (focusedID) focusCard(focusedID);
    if (newID) {
      const item = track.querySelector(`[data-card="${newID}"]`);
      if (item) {
        const target = shelf.scrollLeft + item.getBoundingClientRect().right - shelf.getBoundingClientRect().right + 32;
        shelf.scrollTo({ left: Math.max(0, target), behavior: reduced.matches ? 'instant' : 'smooth' });
        if (!reduced.matches && window.gsap) gsap.from(item, { y: -24, rotation: -5, opacity: 0, duration: .24, ease: 'power2.out' });
      }
    }
  }
  function updateShelf() {
    const max = Math.max(0, shelf.scrollWidth - shelf.clientWidth);
    $('#shelf-nav').hidden = max < 2;
    $('#shelf-count').textContent = String(cards.length);
    $('#shelf-prev').disabled = shelf.scrollLeft < 2;
    $('#shelf-next').disabled = shelf.scrollLeft >= max - 2;
    desktop.dataset.cardCount = String(cards.length);
    desktop.dataset.userCardCount = String(state.userCards.length);
    desktop.dataset.scenarioCardCount = String(cards.length - state.userCards.length);
  }
  function toast(message) {
    clearTimeout(toastTimer);
    $('#desktop-toast').textContent = message;
    $('#desktop-toast').classList.add('visible');
    toastTimer = setTimeout(() => $('#desktop-toast').classList.remove('visible'), 2400);
  }
  function closePopover(restore = true) {
    const wasOpen = !$('#card-popover').hidden, id = selectedID;
    $('#card-popover').hidden = true; selectedID = null;
    if (restore && wasOpen) focusCard(id);
  }
  function stopGuideClock() {
    if (guideTimeline) { guideTimeline.kill(); guideTimeline = null; }
    guideTimers.forEach(clearTimeout); guideTimers = [];
    if (window.gsap) gsap.killTweensOf(['#guide-cursor', shelf]);
    $('#guide-cursor').style.opacity = '0';
  }
  function syncGuide() {
    const playing = state.scenario.status === 'playing';
    $('#guide-play').setAttribute('aria-pressed', String(playing));
    $('#play-icon').textContent = playing ? 'Ⅱ' : '▶';
    $('#play-label').textContent = playing ? '暂停引导' : state.scenario.status === 'paused' ? '继续引导' : '看 15 秒演示';
    desktop.dataset.playing = String(playing);
    desktop.dataset.runId = String(state.scenario.runID);
    desktop.dataset.phase = String(state.scenario.phase);
    desktop.dataset.materialId = state.scenario.material?.id || '';
    desktop.dataset.foundId = state.scenario.foundID || '';
    $('#demo-material-text').textContent = state.scenario.material?.text || '让注意力，\n回到事情本身。';
    setGuideCopy(state.scenario.step);
  }
  function interruptGuide() {
    const focus = desktop.dataset.focus;
    stopGuideClock(); dispatch({ type: 'PAUSE' }); syncGuide();
    if (focus) desktop.dataset.focus = focus;
  }
  function syncEditor() {
    const e = state.editor;
    $('#note-dialog').hidden = e.owner === 'none';
    if (e.owner === 'none') return;
    const options = [{ value: 'new', label: '新建记事' }];
    for (const id of Object.keys(state.editDrafts)) {
      options.push({ value: 'edit:' + id, label: '编辑：' + (state.userCards.find(c => c.id === id)?.title || '已取下记事') });
    }
    for (const id of Object.keys(state.guideDrafts)) options.push({ value: 'guide:' + id, label: '接管的引导草稿 ' + id });
    if (e.owner === 'scenario') options.push({ value: 'scenario', label: '引导中的记事（输入即可接管）' });
    $('#draft-select').replaceChildren(...options.map(o => { const option = document.createElement('option'); option.value = o.value; option.textContent = o.label; return option; }));
    $('#draft-select').value = e.owner === 'scenario' ? 'scenario' : e.mode === 'new' ? 'new' : e.mode + ':' + (e.cardID || e.draftID);
    const text = editorText(state);
    if ($('#note-text').value !== text) $('#note-text').value = text;
  }
  function addCard(source, options = {}) {
    dispatch({ type: 'ADD_CARD', source });
    const card = state.userCards.at(-1); renderCards(card.id);
    if (!options.quiet) toast('已挂上：' + card.title + ' · 原件留在原处');
    return card.id;
  }
  function openNote(trigger, command = { type: 'OPEN_NEW' }) {
    closePopover(false); closeRecovery(false); lastNoteTrigger = { cardID: command.cardID || trigger?.dataset.card, element: trigger || $('#new-note') };
    dispatch(command); syncEditor(); syncGuide();
    desktop.scrollIntoView({ block: 'start', behavior: 'instant' });
    if (!reduced.matches && window.gsap) gsap.fromTo('#note-dialog', { opacity: 0, y: 8 }, { opacity: 1, y: 0, duration: .25, ease: 'power2.out' });
    $('#note-text').focus({ preventScroll: true });
  }
  function closeNote() {
    dispatch({ type: 'CLOSE_EDITOR' }); syncEditor(); syncGuide();
    focusCard(lastNoteTrigger?.cardID, lastNoteTrigger?.element?.isConnected ? lastNoteTrigger.element : $('#new-note'));
  }
  function takeOverInput() {
    // compositionstart runs before the first IME input event; preserve ownership now.
    dispatch({ type: 'TAKE_OVER' }); stopGuideClock(); syncGuide(); syncEditor();
  }
  function hangNote() {
    dispatch({ type: 'INPUT', text: $('#note-text').value });
    if (!editorText(state).trim()) { $('#note-text').focus(); toast('先写一点，再挂上去。'); return; }
    const id = state.editor.mode === 'edit' ? state.editor.cardID : 'new-' + (state.nextID + 1);
    dispatch({ type: 'SUBMIT' }); syncEditor(); renderCards(id);
    desktop.dataset.focus = 'shelf';
    focusCard(id);
    toast('已挂上记事 · 还可以点击卡片接着写');
  }
  function setGuideCopy(index) {
    step = index;
    $('#guide-number').textContent = String(index + 1).padStart(2, '0');
    $('#guide-title').textContent = guides[index].title;
    $('#guide-description').textContent = guides[index].description;
    $$('[data-step]').forEach(button => { const active = Number(button.dataset.step) === index; button.classList.toggle('active', active); button.setAttribute('aria-pressed', String(active)); });
    desktop.dataset.step = String(index);
    desktop.dataset.focus = ['source', 'note', 'shelf', 'receiver'][index];
  }
  function chooseStep(index) {
    interruptGuide(); closePopover();
    dispatch({ type: 'CHOOSE_STEP', step: index }); syncEditor(); syncGuide(); renderCards();
    desktop.scrollIntoView({ block: 'start', behavior: 'instant' });
    if (index === 1) openNote($('#new-note'));
    if (index === 2 || index === 3) shelf.scrollTo({ left: 0, behavior: 'instant' });
    if (index === 3) toast('拖动“拖出”手柄，或点“···”选择拖出到输入窗口。');
  }
  function renderReceived() {
    const card = receivedOwner === 'scenario' ? state.scenario.received : state.received;
    $('.receive-placeholder').hidden = Boolean(card);
    const output = $('#received-content'); output.hidden = !card;
    if (!card) { output.replaceChildren(); receiveZone.classList.remove('received'); delete receiveZone.dataset.receivedId; return; }
    if (card.kind === 'image') {
      const image = document.createElement('img'); image.src = card.image; image.alt = card.title; output.replaceChildren(image);
    } else output.textContent = card.kind === 'file' ? '文件副本 · ' + card.title : card.text;
    receiveZone.classList.add('received'); receiveZone.dataset.receivedId = card.id; receiveZone.scrollTop = 0;
    if (!reduced.matches && window.gsap) gsap.fromTo(output, { opacity: 0, y: 6 }, { opacity: 1, y: 0, duration: .25, ease: 'power2.out' });
  }
  function sendCard(id) {
    if (!cards.some(c => c.id === id)) return;
    dispatch({ type: 'SEND', cardID: id }); receivedOwner = 'user'; renderReceived();
    desktop.dataset.focus = 'receiver';
    desktop.scrollIntoView({ block: 'start', behavior: 'instant' });
    toast('已放到输入窗口 · 绳上的卡片仍然保留');
  }
  function showPopover(id, element) {
    interruptGuide(); closeRecovery(false); selectedID = id;
    const card = cards.find(c => c.id === id); if (!card) return;
    const popup = $('#card-popover'); $('#popover-title').textContent = card.title;
    $('#card-copy').hidden = card.kind === 'file' || card.kind === 'image';
    $('#card-edit').hidden = card.kind !== 'note';
    popup.hidden = false;
    const rect = element.getBoundingClientRect();
    popup.style.left = Math.max(12, Math.min(innerWidth - popup.offsetWidth - 12, rect.left)) + 'px';
    popup.style.top = Math.max(12, Math.min(innerHeight - popup.offsetHeight - 12, rect.bottom + 8)) + 'px';
    popup.querySelector('button:not([hidden])').focus({ preventScroll: true });
  }
  function moveShelf(forward) {
    interruptGuide(); closePopover();
    shelf.scrollBy({ left: (forward ? 1 : -1) * shelf.clientWidth * .75, behavior: reduced.matches ? 'instant' : 'smooth' });
  }
  function cursorPoint(element) {
    const a = element.getBoundingClientRect(), b = desktop.getBoundingClientRect();
    return { x: a.left - b.left + a.width * .5, y: a.top - b.top + a.height * .45 };
  }
  function scheduleGuide() {
    const runID = state.scenario.runID, startPhase = state.scenario.phase;
    const times = [.45, 2.8, 5.8, 8.2, 12.25, 15];
    const offset = startPhase ? times[startPhase - 1] : 0;
    const cursor = $('#guide-cursor');
    const advance = phase => {
      if (!dispatch({ type: 'ADVANCE', runID, phase })) return;
      syncGuide(); syncEditor(); renderCards(phase === 2 ? state.scenario.material?.id : null);
      if (phase === 3) {
        const found = track.querySelector(`[data-card="${state.scenario.foundID}"]`);
        found?.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'instant' });
        found?.classList.add('is-found');
      }
      if (phase === 1) lastNoteTrigger = { element: $('#new-note') };
      if (phase === 4) { receivedOwner = 'scenario'; renderReceived(); }
      if (phase === 5) {
        stopGuideClock();
        if (state.scenario.status === 'completed') toast('同一份摘记，已原样复用。现在可以自己试试。');
        return;
      }
      if (!reduced.matches && window.gsap) {
        const target = phase === 0 ? $('.source-add') : phase < 3 ? $('#new-note') : phase === 3 ? shelf : receiveZone;
        $('#cursor-caption').textContent = ['产生一份摘记', '小红段打开记事', '这份摘记挂好了', '找到同一份摘记', '内容原样复用'][phase];
        gsap.to(cursor, { ...cursorPoint(target), opacity: 1, duration: .3, ease: 'power2.out' });

      }
    };
    // Both motion preferences execute precisely the same commands and delays.
    if (window.gsap) {
      guideTimeline = gsap.timeline();
      for (let phase = startPhase; phase < times.length; phase++) guideTimeline.call(() => advance(phase), [], times[phase] - offset);
    } else {
      for (let phase = startPhase; phase < times.length; phase++) guideTimers.push(setTimeout(() => advance(phase), (times[phase] - offset) * 1000));
    }
  }
  function playGuide(replay = false) {
    if (!replay && state.scenario.status === 'playing') { interruptGuide(); return; }
    stopGuideClock(); closePopover();
    dispatch({ type: replay ? 'REPLAY' : 'PLAY' }); syncEditor(); syncGuide(); renderCards();
    receivedOwner = state.scenario.received ? 'scenario' : 'user'; renderReceived();
    $('#playground').scrollIntoView({ block: 'start', behavior: 'instant' });
    scheduleGuide();
  }
  shelf.addEventListener('scroll', updateShelf, { passive: true });
  new ResizeObserver(updateShelf).observe(shelf);
  shelf.addEventListener('wheel', event => {
    if (event.deltaX || (event.shiftKey && event.deltaY)) {
      interruptGuide(); closePopover();
      if (!event.deltaX) { shelf.scrollLeft += event.deltaY; event.preventDefault(); }
    }
  }, { passive: false });
  shelf.addEventListener('keydown', event => {
    if (event.target !== shelf) return;
    if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') { event.preventDefault(); moveShelf(event.key === 'ArrowRight'); }
  });
  track.addEventListener('click', event => {
    if (gesture?.moved || (event.detail > 0 && performance.now() < suppressClickUntil)) return;
    const menu = event.target.closest('[data-menu]');
    if (menu) { showPopover(menu.dataset.menu, menu); return; }
    const element = event.target.closest('[data-card]');
    if (!element) return;
    const card = cards.find(c => c.id === element.dataset.card);
    interruptGuide();
    if (card.kind === 'note') openNote(element, { type: 'OPEN_EDIT', cardID: card.id });
    else if (card.kind === 'text') copyTextCard(card);
    else { sendCard(card.id); toast('网页复用预览 · 实际 App 可复制或拖出材料副本'); }
  });
  track.addEventListener('keydown', event => {
    if (event.key === 'ContextMenu' || (event.shiftKey && event.key === 'F10')) {
      const element = event.target.closest('[data-card]');
      if (element) { event.preventDefault(); showPopover(element.dataset.card, element); }
    }
  });
  track.addEventListener('contextmenu', event => {
    const element = event.target.closest('[data-card]');
    if (element) { event.preventDefault(); showPopover(element.dataset.card, element); }
  });
  $('#hero-play').addEventListener('click', () => playGuide(true));
  $('#hero-try').addEventListener('click', () => { interruptGuide(); openNote($('#hero-try')); });
  $('#new-note').addEventListener('click', () => { interruptGuide(); openNote($('#new-note')); });
  $('#close-note').addEventListener('click', () => { interruptGuide(); closeNote(); });
  $('#hang-note').addEventListener('click', () => { interruptGuide(); hangNote(); });
  $('#note-text').addEventListener('compositionstart', takeOverInput);
  $('#note-text').addEventListener('beforeinput', takeOverInput);
  $('#note-text').addEventListener('input', () => {
    const text = $('#note-text').value;
    dispatch({ type: 'INPUT', text }); stopGuideClock(); syncGuide(); syncEditor();
  });
  $('#draft-select').addEventListener('change', event => {
    const value = event.target.value; interruptGuide();
    if (value === 'new') openNote($('#new-note'));
    else if (value.startsWith('edit:')) openNote($('#new-note'), { type: 'OPEN_EDIT', cardID: value.slice(5) });
    else if (value.startsWith('guide:')) openNote($('#new-note'), { type: 'OPEN_GUIDE', draftID: value.slice(6) });
  });
  $('#note-text').addEventListener('keydown', event => { if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') { event.preventDefault(); interruptGuide(); hangNote(); } });
  $('.source-add').addEventListener('click', () => { interruptGuide(); addCard('text'); });
  $('#desk-file').addEventListener('click', event => { if (gesture?.moved || (event.detail > 0 && performance.now() < suppressClickUntil)) return; interruptGuide(); addCard('file'); });
  $('#desk-file').addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); interruptGuide(); addCard('file'); } });
  $('#shelf-prev').addEventListener('click', () => moveShelf(false));
  $('#shelf-next').addEventListener('click', () => moveShelf(true));
  $('#guide-play').addEventListener('click', () => playGuide());
  $('#guide-next').addEventListener('click', () => chooseStep((step + 1) % 4));
  $('#reset-desk').addEventListener('click', () => playGuide(true));
  $$('[data-step]').forEach(button => button.addEventListener('click', () => chooseStep(Number(button.dataset.step))));
  $('#card-send').addEventListener('click', () => { sendCard(selectedID); closePopover(); });
  async function copyTextCard(card) {
    try { if (!navigator.clipboard?.writeText) throw new Error('Unavailable'); await navigator.clipboard.writeText(card.text); toast('已复制文字：' + card.title); }
    catch { toast('浏览器未允许复制，可以用菜单“拖出到输入窗口”。'); }
  }
  $('#card-copy').addEventListener('click', () => {
    const card = cards.find(c => c.id === selectedID); if (card) copyTextCard(card);
    closePopover();
  });
  $('#card-edit').addEventListener('click', () => {
    const card = cards.find(c => c.id === selectedID); if (!card) return;
    const trigger = $(`[data-card="${card.id}"]`);
    openNote(trigger, { type: 'OPEN_EDIT', cardID: card.id });
  });
  $('#card-take-down').addEventListener('click', () => {
    const card = cards.find(c => c.id === selectedID); if (!card) return;
    const index = cards.findIndex(c => c.id === card.id);
    const neighbourID = (cards[index + 1] || cards[index - 1])?.id;
    dispatch({ type: 'TAKE_DOWN', cardID: selectedID }); closePopover(false); renderCards();
    focusCard(neighbourID, $('#recent-taken-down')); toast('已取下：' + card.title + ' · 可在最近取下中找回');
  });
  $('#popover-close').addEventListener('click', () => closePopover());
  $('#recent-taken-down').addEventListener('click', () => {
    interruptGuide(); closePopover(); renderRecovery();
    $('#recovery-dialog').hidden = false;
    $('#recent-taken-down').setAttribute('aria-expanded', 'true');
    desktop.scrollIntoView({ block: 'start', behavior: 'instant' });
    $('#recovery-list button')?.focus({ preventScroll: true });
  });
  $('#undo-take-down').addEventListener('click', () => { const entry = state.takenDown.at(-1); if (entry) recoverCard(entry.card.id); });
  $('#recovery-list').addEventListener('click', event => { const button = event.target.closest('[data-recover]'); if (button) recoverCard(button.dataset.recover); });
  $('#close-recovery').addEventListener('click', () => closeRecovery());
  document.addEventListener('keydown', event => { if (event.key === 'Escape') { interruptGuide(); if (!$('#recovery-dialog').hidden) closeRecovery(); else if (!$('#note-dialog').hidden) closeNote(); else closePopover(); cancelGesture(); } });
  document.addEventListener('pointerdown', event => {
    if (!$('#card-popover').hidden && !event.target.closest('#card-popover') && !event.target.closest('[data-card]')) closePopover();
    if (!event.isPrimary) { cancelGesture(); return; }
    if (!gesture) suppressClickUntil = 0;
    const element = event.target.closest('[data-card],#desk-file');
    if (!element || event.button !== 0 || !$('#note-dialog').hidden) return;
    // Browser owns pans and pinch on card surfaces from pointerdown. Only the
    // visible handle opts into touch dragging; a mouse can drag the whole card.
    if (event.pointerType !== 'mouse' && !event.target.closest('.drag-handle')) { interruptGuide(); return; }
    interruptGuide(); cancelGesture();
    gesture = { element, pointerID: event.pointerId, x: event.clientX, y: event.clientY, moved: false, ghost: null, cardID: element.dataset.card, source: element.dataset.source };
    element.setPointerCapture(event.pointerId);
  });
  function cancelGesture() {
    if (!gesture) return;
    const old = gesture; gesture = null;
    if (old.moved) suppressClickUntil = performance.now() + 500;
    old.ghost?.remove(); old.element.classList.remove('drag-origin');
    ropeArea.classList.remove('drag-over'); receiveZone.classList.remove('drag-over');
    try { old.element.releasePointerCapture(old.pointerID); } catch { /* The native pointer may already be released. */ }
    gesture = null;
  }
  document.addEventListener('pointermove', event => {
    if (!gesture || gesture.pointerID !== event.pointerId) return;
    const dx = event.clientX - gesture.x, dy = event.clientY - gesture.y;
    if (!gesture.moved && Math.hypot(dx, dy) < 8) return;
    if (!gesture.moved) {
      gesture.moved = true;
      const rect = gesture.element.getBoundingClientRect();
      const ghost = gesture.element.cloneNode(true); ghost.removeAttribute('id'); ghost.removeAttribute('data-card'); ghost.removeAttribute('data-source'); ghost.removeAttribute('tabindex'); ghost.setAttribute('aria-hidden', 'true');
      ghost.className = 'peg-card drag-ghost';
      if (gesture.source) { ghost.innerHTML = `<span class="card-kind">文件副本</span><span class="card-file">${fileIcon}<span>项目资料.pdf</span></span>`; }
      ghost.style.width = Math.min(142, rect.width) + 'px'; ghost.style.height = '148px';
      document.body.append(ghost); gesture.ghost = ghost; gesture.element.classList.add('drag-origin'); closePopover(false);
    }
    gesture.ghost.style.left = event.clientX - 60 + 'px'; gesture.ghost.style.top = event.clientY - 28 + 'px';
    const target = document.elementFromPoint(event.clientX, event.clientY);
    ropeArea.classList.toggle('drag-over', Boolean(gesture.source && target?.closest('#rope-area')));
    receiveZone.classList.toggle('drag-over', Boolean(gesture.cardID && target?.closest('#receive-zone')));
  });
  document.addEventListener('pointerup', event => {
    if (!gesture || gesture.pointerID !== event.pointerId) return;
    const old = gesture;
    if (old.moved) {
      const target = document.elementFromPoint(event.clientX, event.clientY);
      if (old.source && target?.closest('#rope-area')) addCard(old.source);
      else if (old.cardID && target?.closest('#receive-zone')) sendCard(old.cardID);
      else toast('放回绳上 · 材料还在');
      suppressClickUntil = performance.now() + 500;
    }
    cancelGesture();
  });
  document.addEventListener('pointercancel', event => { if (gesture?.pointerID === event.pointerId) cancelGesture(); });
  document.addEventListener('lostpointercapture', event => { if (gesture?.pointerID === event.pointerId) cancelGesture(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) { interruptGuide(); cancelGesture(); } });
  renderCards(); syncGuide();
  const requested = new URLSearchParams(location.search).get('state');
  if (requested === 'overflow') chooseStep(2);
  else if (requested === 'note') chooseStep(1);
  else if (requested === 'received') { chooseStep(3); sendCard('reading'); }
  if (window.gsap && window.ScrollTrigger) {
    gsap.registerPlugin(ScrollTrigger);
    const mm = gsap.matchMedia();
    mm.add('(prefers-reduced-motion: no-preference)', () => {
      gsap.from('.hero-intro h1', { opacity: 0, y: 12, duration: .3, ease: 'power2.out' });
      gsap.from('.playground', { opacity: 0, y: 18, duration: .3, delay: .1, ease: 'power2.out', clearProps: 'transform' });
      const story = gsap.timeline({ scrollTrigger: { trigger: '.story', start: 'top 65%', end: 'bottom 35%', scrub: true }, defaults: { ease: 'none' } });
      story.to('.story-rope', { opacity: 1, duration: .3 }, 0)
        .to('.paper-one', { y: 0, rotation: 3, duration: .7 }, 0)
        .to('.paper-two', { y: 0, rotation: -1, duration: .7 }, 0)
        .to('.paper-three', { y: 0, rotation: 1, duration: .7 }, 0)
        .to('.paper-one', { rotation: -2, duration: .3 }, .7)
        .to('.paper-two', { rotation: 1, duration: .3 }, .7)
        .to('.paper-three', { rotation: -1, duration: .3 }, .7)
        .to('.story-pin', { opacity: 1, duration: .2 }, .7)
        .to('.before-caption', { opacity: 0, duration: .2 }, .55)
        .to('.after-caption', { opacity: 1, duration: .2 }, .8);
      return () => { interruptGuide(); };
    });
  }
  reduced.addEventListener('change', () => { interruptGuide(); });
  fetch('downloads/release.json').then(response => { if (!response.ok) throw new Error('release'); return response.json(); }).then(release => {
    if (/^\d+\.\d+\.\d+$/.test(release.version) && /^Inkpeg-[A-Za-z0-9.-]+\.dmg$/.test(release.file)) {
      const button = $('.download-button');
      button.href = 'downloads/' + release.file;
      button.download = release.file;
      $('.download-summary').textContent = `文夹 Inkpeg ${release.version} · 预览版（build ${release.build}） · macOS ${release.minimumMacOS} 及以上 · M 系列与 Intel 双架构`;
    }
    if (Number.isFinite(release.sizeBytes)) $('#download-size').textContent = (release.sizeBytes / 1024 / 1024).toFixed(1) + ' MB';
  }).catch(() => { /* Download links remain usable without optional size metadata. */ });
})();
