'use strict';
// Pure state transitions. Animation callbacks carry the identity of their run.
(() => {
  const initialCards = [
    { id: 'photo', kind: 'image', title: '刚截的风景', text: '刚截的风景', image: 'assets/landscape.svg' },
    { id: 'reading', kind: 'text', title: '阅读摘记', text: '让注意力，\n回到事情本身。' },
    { id: 'note', kind: 'note', title: '下午的想法', text: '先整理材料，\n再整理思路。' },
    { id: 'pdf', kind: 'file', title: '项目资料.pdf', text: '项目资料.pdf' }
  ];
  const none = () => ({ owner: 'none', mode: 'new', cardID: null, draftID: null });
  const scenario = runID => ({ cards: [], draft: '', received: null, step: 0, status: 'idle', runID, draftID: String(runID), phase: 0, material: null, foundID: null });
  const copy = value => JSON.parse(JSON.stringify(value));
  function createDemoState() {
    return { userCards: copy(initialCards), newDraft: '', editDrafts: {}, guideDrafts: {}, editor: none(), scenario: scenario(0), received: null, takenDown: [], nextID: 0 };
  }
  function editorText(s) {
    const e = s.editor;
    if (e.owner === 'scenario') return s.scenario.draft;
    if (e.mode === 'edit') return s.editDrafts[e.cardID] ?? '';
    if (e.mode === 'guide') return s.guideDrafts[e.draftID] ?? '';
    return s.newDraft;
  }
  function pause(s) {
    if (s.scenario.status === 'playing') {
      s.scenario.status = 'paused';
      s.scenario.runID++;
    }
  }
  function ownEditor(s) {
    if (s.editor.owner === 'scenario') {
      const id = s.editor.draftID;
      s.guideDrafts[id] = s.scenario.draft;
      s.editor = { owner: 'user', mode: 'guide', cardID: null, draftID: id };
    }
    pause(s);
  }
  function overflow(s) {
    if (s.scenario.cards.some(c => c.id.endsWith('-overflow-0'))) return;
    for (const [i, text] of ['等会儿要用的链接', '一张参考图', '要继续写的段落', '会议中的一句话', '整理资料的清单', '下一步的想法'].entries()) {
      s.scenario.cards.push({ id: `scenario-${s.scenario.runID}-overflow-${i}`, kind: i === 1 ? 'image' : 'text', title: text, text: text + '\n放在手边，接着用。', image: 'assets/landscape.svg' });
    }
  }
  function reduceDemo(state, command) {
    if (command.type === 'ADVANCE' && (state.scenario.status !== 'playing' || command.runID !== state.scenario.runID || command.phase !== state.scenario.phase)) return state;
    const s = copy(state), e = s.editor, sc = s.scenario;
    switch (command.type) {
      case 'PLAY':
        if (sc.status !== 'paused') s.scenario = scenario(sc.runID + 1);
        else sc.runID++;
        s.scenario.status = 'playing'; s.editor = none();
        // Resume the demonstration's editor, never a user-owned draft.
        if (s.scenario.phase === 2) {
          if (Object.hasOwn(s.guideDrafts, s.scenario.draftID)) s.scenario.draftID = String(s.scenario.runID);
          s.editor = { owner: 'scenario', mode: 'guide', cardID: null, draftID: s.scenario.draftID };
        }
        break;
      case 'REPLAY':
        ownEditor(s); s.scenario = scenario(s.scenario.runID + 1); s.scenario.status = 'playing'; s.editor = none(); break;
      case 'PAUSE': pause(s); break;
      case 'TAKE_OVER': ownEditor(s); break;
      case 'OPEN_NEW':
        ownEditor(s); s.editor = { owner: 'user', mode: 'new', cardID: null, draftID: 'new' }; break;
      case 'OPEN_EDIT': {
        ownEditor(s);
        let card = s.userCards.find(c => c.id === command.cardID);
        if (!card) {
          const source = sc.cards.find(c => c.id === command.cardID && c.kind === 'note');
          if (source) { card = copy(source); s.userCards.push(card); sc.cards = sc.cards.filter(c => c.id !== card.id); }
        }
        if (!card || card.kind !== 'note') break;
        s.editDrafts[card.id] ??= card.text;
        s.editor = { owner: 'user', mode: 'edit', cardID: card.id, draftID: card.id }; break;
      }
      case 'OPEN_GUIDE':
        ownEditor(s);
        if (Object.hasOwn(s.guideDrafts, command.draftID)) s.editor = { owner: 'user', mode: 'guide', cardID: null, draftID: command.draftID };
        break;
      case 'INPUT':
        ownEditor(s);
        if (s.editor.owner !== 'user') break;
        if (s.editor.mode === 'new') s.newDraft = command.text;
        else if (s.editor.mode === 'edit') s.editDrafts[s.editor.cardID] = command.text;
        else s.guideDrafts[s.editor.draftID] = command.text;
        break;
      case 'CLOSE_EDITOR': ownEditor(s); s.editor = none(); break;
      case 'SUBMIT': {
        ownEditor(s);
        if (s.editor.owner !== 'user') break;
        const text = editorText(s); if (!text.trim()) break;
        const card = s.editor.mode === 'edit' ? s.userCards.find(c => c.id === s.editor.cardID) : null;
        if (card) { card.text = text; card.title = text.trim().split('\n')[0].slice(0, 18); }
        else s.userCards.push({ id: 'new-' + ++s.nextID, kind: 'note', title: text.trim().split('\n')[0].slice(0, 18), text });
        if (s.editor.mode === 'new') s.newDraft = '';
        else if (s.editor.mode === 'edit') delete s.editDrafts[s.editor.cardID];
        else delete s.guideDrafts[s.editor.draftID];
        s.editor = none(); break;
      }
      case 'ADD_CARD': {
        pause(s); const id = 'new-' + ++s.nextID;
        s.userCards.push(command.source === 'file' ? { id, kind: 'file', title: '项目资料.pdf', text: '项目资料.pdf' } : { id, kind: 'text', title: '一句阅读摘记', text: '让注意力，\n回到事情本身。' }); break;
      }
      case 'TAKE_DOWN': {
        pause(s);
        const index = s.userCards.findIndex(c => c.id === command.cardID);
        const card = index >= 0 ? s.userCards[index] : sc.cards.find(c => c.id === command.cardID);
        if (!card) break;
        // Keep the complete copy and identity outside replay-owned scene state.
        s.takenDown.push({ card: copy(card), index: index >= 0 ? index : s.userCards.length });
        s.userCards = s.userCards.filter(c => c.id !== command.cardID);
        sc.cards = sc.cards.filter(c => c.id !== command.cardID); break;
      }
      case 'RECOVER': {
        pause(s);
        const entry = s.takenDown.find(item => item.card.id === command.cardID);
        if (!entry) break;
        // An explicit recovery becomes user-owned, including a former scene card.
        if (!s.userCards.some(c => c.id === command.cardID)) s.userCards.splice(Math.min(entry.index, s.userCards.length), 0, copy(entry.card));
        sc.cards = sc.cards.filter(c => c.id !== command.cardID);
        s.takenDown = s.takenDown.filter(item => item.card.id !== command.cardID); break;
      }
      case 'SEND': {
        pause(s); const card = [...s.userCards, ...sc.cards].find(c => c.id === command.cardID);
        if (card) s.received = copy(card); break;
      }
      case 'CHOOSE_STEP':
        ownEditor(s); s.editor = none(); sc.step = command.step;
        if (command.step === 2) { if (sc.status === 'completed') s.scenario = scenario(sc.runID + 1); s.scenario.step = 2; overflow(s); }
        break;
      case 'ADVANCE':
        if (sc.phase === 0) {
          sc.step = 0;
          sc.material = { id: `scenario-${sc.runID}-note`, kind: 'note', title: '阅读摘记', text: '让注意力，\n回到事情本身。' };
          sc.draft = sc.material.text;
        } else if (sc.phase === 1) {
          sc.step = 1;
          s.editor = { owner: 'scenario', mode: 'guide', cardID: null, draftID: sc.draftID };
        } else if (sc.phase === 2) {
          sc.cards.push({ ...copy(sc.material), text: sc.draft });
          sc.draft = ''; if (e.owner === 'scenario') s.editor = none();
        } else if (sc.phase === 3) {
          sc.step = 2; overflow(s);
          sc.foundID = [...s.userCards, ...sc.cards].find(c => c.id === sc.material?.id)?.id || null;
        }
        else if (sc.phase === 4) {
          sc.step = 3;
          let card = [...s.userCards, ...sc.cards].find(c => c.id === sc.material?.id);
          // Replenish only a scene-owned source if it was taken down while paused.
          if (!card && sc.material) { card = copy(sc.material); sc.cards.push(card); }
          if (!card) break;
          sc.received = copy(card);
        } else if (sc.phase === 5 && sc.received) {
          // Keep receipt provenance even if its source was taken down after delivery.
          if (![...s.userCards, ...sc.cards].some(c => c.id === sc.received.id)) sc.cards.push(copy(sc.received));
          sc.status = 'completed';
        }
        sc.phase++;
        break;
      default: return state;
    }
    return s;
  }
  globalThis.InkpegDemo = { createDemoState, reduceDemo, editorText };
})();
