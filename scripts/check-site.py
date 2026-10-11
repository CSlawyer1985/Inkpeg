#!/usr/bin/env python3
"""Exercise the actual site in an isolated browser; no external app or user data."""
import argparse, hashlib, json, time
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:8767')
parser.add_argument('--out', required=True)
parser.add_argument('--task14-only', action='store_true')
parser.add_argument('--task15-only', action='store_true')
parser.add_argument('--task8-only', action='store_true')
parser.add_argument('--task9-only', action='store_true')
parser.add_argument('--task9-lines', type=int, nargs='+', default=[1, 10, 50])
parser.add_argument('--task9-case', choices=['long', 'focus', 'recovery'])
args = parser.parse_args()
out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
results = []

def record(name):
    results.append(name); print('PASS:', name, flush=True)

def drag(page, source, target):
    a = page.locator(source).bounding_box(); b = page.locator(target).bounding_box()
    assert a and b
    page.mouse.move(a['x'] + a['width'] / 2, a['y'] + a['height'] / 2)
    page.mouse.down()
    page.mouse.move(b['x'] + b['width'] / 2, b['y'] + b['height'] / 2, steps=18)
    page.mouse.up()


def task8_regressions(browser):
    ctx = browser.new_context(viewport={'width': 1440, 'height': 1080}, record_video_dir=str(out / 'takeover-video'))
    page = ctx.new_page(); errors = []; external = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
    page.on('request', lambda r: external.append(r.url) if urlparse(r.url).netloc != urlparse(args.url).netloc else None)
    def fresh(reduced=False):
        page.emulate_media(reduced_motion='reduce' if reduced else 'no-preference')
        page.goto(args.url); page.wait_for_load_state('networkidle')
    def finish():
        page.wait_for_function('document.querySelector("#desktop").dataset.playing === "false" && document.querySelector("#desktop").dataset.step === "3"', timeout=25000)
    # Delivery and completion are separate commands: continuing between them must
    # keep the already delivered scene visible, even with a different user receipt.
    for existing_receipt in [True, False]:
        fresh()
        if existing_receipt:
            page.locator('[data-menu="note"]').click(); page.locator('#card-send').click()
            expect(page.locator('#received-content')).to_have_text('先整理材料，\n再整理思路。')
        page.locator('#guide-play').click()
        page.wait_for_function('document.querySelector("#receive-zone").dataset.receivedId?.startsWith("scenario-")')
        delivered_id = page.locator('#receive-zone').get_attribute('data-received-id')
        page.locator('#guide-play').click()
        expect(page.locator('#desktop')).to_have_attribute('data-playing', 'false')
        expect(page.locator('#received-content')).to_be_visible()
        expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
        page.locator('#guide-play').click(); finish()
        expect(page.locator('#received-content')).to_be_visible()
        expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
        expect(page.locator('#receive-zone')).to_have_attribute('data-received-id', delivered_id)
        expect(page.locator('#desktop')).to_have_attribute('data-scenario-card-count', '0')
        expect(page.locator('.peg-card[data-card]')).to_have_count(4)
        if existing_receipt:
            # Fresh replay exposes the saved user receipt, proving it was not overwritten.
            page.locator('#reset-desk').click(); page.locator('#guide-play').click()
            expect(page.locator('#received-content')).to_be_visible()
            expect(page.locator('#received-content')).to_have_text('先整理材料，\n再整理思路。')
            expect(page.locator('#receive-zone')).to_have_attribute('data-received-id', 'note')
        else:
            # Explicit user delivery after completion must supersede scene presentation.
            page.locator('[data-menu="note"]').click(); page.locator('#card-send').click()
            expect(page.locator('#received-content')).to_be_visible()
            expect(page.locator('#received-content')).to_have_text('先整理材料，\n再整理思路。')
            expect(page.locator('#receive-zone')).to_have_attribute('data-received-id', 'note')
    record('Delivery-phase pause/resume keeps exact visible scenario receipt; user receipt and later manual send survive')
    fresh()
    page.locator('#new-note').click(); page.locator('#note-text').fill('AUDIT USER DRAFT keep this')
    page.locator('#close-note').click(); page.locator('#guide-play').click()
    page.wait_for_timeout(5400)
    page.locator('#new-note').click()
    expect(page.locator('#note-text')).to_have_value('AUDIT USER DRAFT keep this')
    record('W01 closed new draft survives guide and reopening')
    fresh()
    page.locator('#guide-play').click()
    page.wait_for_function('!document.querySelector("#note-dialog").hidden')
    page.locator('#note-text').dispatch_event('compositionstart')
    expect(page.locator('#desktop')).to_have_attribute('data-playing', 'false')
    page.locator('#note-text').fill('USER TYPING should pause')
    page.wait_for_timeout(3500)
    expect(page.locator('#note-text')).to_have_value('USER TYPING should pause')
    expect(page.locator('#note-dialog')).to_be_visible()
    expect(page.locator('#desktop')).to_have_attribute('data-user-card-count', '4')
    page.screenshot(path=str(out / 'takeover-before-submit.png'))
    page.locator('#hang-note').click()
    expect(page.locator('[data-card="new-1"] .card-text')).to_have_text('USER TYPING should pause')
    page.locator('[data-menu="new-1"]').click(); page.locator('#card-send').click()
    expect(page.locator('#received-content')).to_have_text('USER TYPING should pause')
    page.wait_for_function('getComputedStyle(document.querySelector("#received-content")).opacity === "1"')
    page.screenshot(path=str(out / 'takeover-manual-complete.png'))
    record('W01 compositionstart takes ownership before input; late timeline cannot submit; manual completion works')
    fresh(True)
    page.locator('[data-menu="note"]').click(); page.locator('#card-edit').click()
    page.locator('#note-text').fill('UNSAVED A'); page.locator('#close-note').click()
    page.locator('#guide-play').click(); page.wait_for_function('!document.querySelector("#note-dialog").hidden')
    page.locator('#note-text').fill('REDUCED USER NOTE'); page.locator('#hang-note').click()
    expect(page.locator('[data-card="note"] .card-text')).to_have_text('先整理材料，\n再整理思路。')
    expect(page.locator('[data-card="new-1"] .card-text')).to_have_text('REDUCED USER NOTE')
    record('W02 reduced-motion takeover publishes a new note without overwriting old card')
    page.locator('[data-menu="new-1"]').click(); page.locator('#card-edit').click()
    page.locator('#note-text').fill('UNSAVED B'); page.locator('#close-note').click()
    page.locator('#new-note').click(); page.locator('#note-text').fill('UNSAVED NEW'); page.locator('#close-note').click()
    page.locator('#reset-desk').click(); page.wait_for_function('!document.querySelector("#note-dialog").hidden')
    page.locator('#note-text').fill('UNSAVED GUIDE'); page.locator('#close-note').click()
    page.locator('#reset-desk').click(); finish()
    page.locator('#new-note').click()
    expect(page.locator('#note-text')).to_have_value('UNSAVED NEW')
    page.locator('#draft-select').select_option('edit:note'); expect(page.locator('#note-text')).to_have_value('UNSAVED A')
    page.locator('#draft-select').select_option('edit:new-1'); expect(page.locator('#note-text')).to_have_value('UNSAVED B')
    guide_value = page.locator('#draft-select option').evaluate_all('(opts) => opts.find(o => o.value.startsWith("guide:")).value')
    page.locator('#draft-select').select_option(guide_value); expect(page.locator('#note-text')).to_have_value('UNSAVED GUIDE')
    page.locator('#draft-select').select_option('new'); expect(page.locator('#note-text')).to_have_value('UNSAVED NEW')
    page.locator('#close-note').click()
    record('New draft, card A/B edits, and taken-over guide draft reopen independently after replay')
    fresh()
    for card in ['photo', 'reading', 'note', 'pdf']:
        page.locator(f'[data-menu="{card}"]').click(); page.locator('#card-take-down').click()
    page.locator('#guide-play').click(); finish()
    expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
    expect(page.locator('.peg-card[data-card]')).to_have_count(0)
    assert page.locator('#receive-zone').get_attribute('data-received-id').startswith('scenario-')
    record('W03 all initial cards removed: scenario delivers its own card and removes only its display')
    fresh()
    page.locator('#guide-play').click(); page.wait_for_function('document.querySelector("#desktop").dataset.step === "1"')
    page.locator('#guide-play').click()
    run = page.locator('#desktop').get_attribute('data-run-id')
    page.wait_for_timeout(2600)
    expect(page.locator('#desktop')).to_have_attribute('data-step', '1')
    page.locator('#guide-play').click()
    assert page.locator('#desktop').get_attribute('data-run-id') != run
    expect(page.locator('#desktop')).to_have_attribute('data-step', '1')
    finish(); expect(page.locator('#desktop')).to_have_attribute('data-user-card-count', '4')
    record('Pause preserves step; continue uses a fresh callback identity and completes')
    page.evaluate('gsap.globalTimeline.timeScale(25)')
    for _ in range(10):
        page.locator('#reset-desk').click(); finish()
        expect(page.locator('.peg-card[data-card]')).to_have_count(4)
        expect(page.locator('#desktop')).to_have_attribute('data-user-card-count', '4')
        expect(page.locator('#desktop')).to_have_attribute('data-scenario-card-count', '0')
        expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
    record('Ten complete UI replays preserve exact user card count and real receiver result')
    pure = page.evaluate("""() => {
      const {createDemoState, reduceDemo} = InkpegDemo;
      const check = (v, m) => {if (!v) throw Error(m)};
      let s = createDemoState(); const original = JSON.stringify(s);
      s = reduceDemo(s, {type:'SEND',cardID:'note'});
      const userReceived = JSON.stringify(s.received);
      let playing = reduceDemo(s, {type:'PLAY'});
      check(JSON.stringify(createDemoState()) === original, 'initial state reused mutable data');
      const untouched = JSON.stringify(s);
      reduceDemo(s, {type:'ADD_CARD',source:'text'});
      check(JSON.stringify(s) === untouched, 'reducer mutated input');
      let runID = playing.scenario.runID;
      playing = reduceDemo(playing, {type:'ADVANCE', runID, phase:0});
      playing = reduceDemo(playing, {type:'ADVANCE', runID, phase:1});
      for (const command of [{type:'PAUSE'}, {type:'INPUT', text:'owned'}, {type:'REPLAY'}]) {
        const next = reduceDemo(playing, command);
        const late = reduceDemo(next, {type:'ADVANCE', runID, phase:2});
        check(JSON.stringify(next) === JSON.stringify(late), 'stale callback wrote after '+command.type);
      }
      const paused = reduceDemo(playing, {type:'PAUSE'});
      const resumed = reduceDemo(paused, {type:'PLAY'});
      check(resumed.scenario.runID !== paused.scenario.runID && resumed.scenario.phase === playing.scenario.phase && resumed.editor.draftID === playing.editor.draftID, 'resume identity and position');
      const taken = reduceDemo(playing, {type:'INPUT', text:'first owned draft'});
      const again = reduceDemo(reduceDemo(taken, {type:'PLAY'}), {type:'INPUT',text:'second owned draft'});
      check(Object.values(again.guideDrafts).includes('first owned draft') && Object.values(again.guideDrafts).includes('second owned draft'), 'continued guide reused an owned draft');
      const snapshot = JSON.stringify(playing);
      let done = playing;
      for(let phase=2; phase<6; phase++) done=reduceDemo(done,{type:'ADVANCE',runID,phase});
      check(JSON.stringify(playing) === snapshot, 'advance mutated input');
      check(JSON.stringify(done.received) === userReceived, 'scenario overwrote user receiver');
      check(done.scenario.status === 'completed', 'not complete');
      check(done.scenario.received && done.scenario.cards.some(c => c.id === done.scenario.received.id && c.text === done.scenario.received.text), 'receiver provenance');
      let removed = reduceDemo(playing, {type:'ADVANCE',runID,phase:2});
      for(let phase=3; phase<5; phase++) removed=reduceDemo(removed,{type:'ADVANCE',runID,phase});
      removed=reduceDemo(removed,{type:'TAKE_DOWN',cardID:removed.scenario.received.id});
      removed=reduceDemo(removed,{type:'PLAY'});
      removed=reduceDemo(removed,{type:'ADVANCE',runID:removed.scenario.runID,phase:5});
      check(removed.scenario.status === 'completed' && removed.scenario.cards.some(c=>c.id===removed.scenario.received.id), 'take-down after delivery blocked completion');
      return 'PASS';
    }""")
    assert pure == 'PASS'
    record('Pure immutable reducer rejects stale pause/input/replay callbacks and proves scenario receiver provenance')
    assert not errors, errors
    assert not external, external
    ctx.close()


def task9_regressions(browser):
    for width, height in [(1440, 1080), (390, 844)]:
        ctx = browser.new_context(viewport={'width': width, 'height': height}, permissions=['clipboard-read', 'clipboard-write'])
        page = ctx.new_page(); errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        def fresh():
            page.emulate_media(reduced_motion='reduce')
            page.goto(args.url); page.wait_for_load_state('networkidle')
        def focused(selector):
            expect(page.locator(selector)).to_be_focused()
            assert page.evaluate('document.activeElement.tagName') != 'BODY'
            rect = page.locator(selector).bounding_box()
            assert rect and rect['x'] >= 0 and rect['y'] >= 0 and rect['x'] + rect['width'] <= width and rect['y'] + rect['height'] <= height, (selector, rect, width, height)
        def tab_to(selector):
            for _ in range(100):
                if page.locator(selector).evaluate('(e) => e === document.activeElement'):
                    return
                page.keyboard.press('Tab')
            raise AssertionError('keyboard cannot reach '+selector)
        if args.task9_case in [None, 'long']:
            for lines in args.task9_lines:
                fresh()
                empty = page.locator('#receive-zone').evaluate("e => ({align:getComputedStyle(e).alignItems,justify:getComputedStyle(e).justifyContent})")
                assert empty == {'align': 'center', 'justify': 'center'}, empty
                text = '\n'.join(f'第{i:02}行 Q4' for i in range(1, lines+1))
                page.locator('#new-note').click(); page.locator('#note-text').fill(text); page.locator('#hang-note').click()
                page.locator('[data-menu="new-1"]').click(); page.locator('#card-send').click()
                assert page.locator('#received-content').text_content() == text
                page.wait_for_function('getComputedStyle(document.querySelector("#desktop-toast")).opacity === "0"')
                for edge in ['first', 'last']:
                    bounds = page.locator('#receive-zone').evaluate(r"""(zone, edge) => {
                        zone.scrollTop = edge === 'first' ? 0 : zone.scrollHeight;
                        const text = document.querySelector('#received-content').firstChild;
                        const range = document.createRange(), len = text.length;
                        const start = edge === 'first' ? 0 : text.textContent.lastIndexOf('\n') + 1;
                        const end = edge === 'first' ? (text.textContent.indexOf('\n') < 0 ? len : text.textContent.indexOf('\n')) : len;
                        range.setStart(text, start); range.setEnd(text, end);
                        const r = range.getBoundingClientRect(), z = zone.getBoundingClientRect();
                        const clip = {top:Math.max(0,z.top),bottom:Math.min(innerHeight,z.bottom),left:Math.max(0,z.left),right:Math.min(innerWidth,z.right)};
                        const hit = document.elementFromPoint((r.left+r.right)/2,(r.top+r.bottom)/2);
                        return {edge, rect:{top:r.top,bottom:r.bottom,left:r.left,right:r.right},clip,scrollTop:zone.scrollTop,unobscured:!!hit?.closest('#received-content')};
                    }""", edge)
                    r, c = bounds['rect'], bounds['clip']
                    assert r['top'] >= c['top'] and r['bottom'] <= c['bottom'] and r['left'] >= c['left'] and r['right'] <= c['right'], (width, lines, bounds)
                    assert bounds['unobscured'], (width, lines, bounds)
                    page.screenshot(path=str(out / f'task9-{width}-{lines}-{edge}.png'))
                page.locator('[data-menu="new-1"]').click(); page.locator('#card-copy').click()
                assert page.evaluate('navigator.clipboard.readText()') == text
                record(f'W04 {width}px {lines} received lines: exact copy and first/last Ranges inside actual scrollport AND viewport')
            fresh()
            text = '\n  开头留白\n\n末尾也留白  \n'
            page.locator('#new-note').click(); page.locator('#note-text').fill(text); page.locator('#hang-note').click()
            page.locator('[data-menu="new-1"]').click(); page.locator('#card-send').click()
            assert page.locator('#received-content').text_content() == text
            expect(page.locator('[data-card="new-1"]')).to_have_attribute('aria-label', '开头留白，继续记事')
            page.locator('[data-menu="new-1"]').click(); page.locator('#card-copy').click()
            assert page.evaluate('navigator.clipboard.readText()') == text
            record(f'{width}px leading/trailing blank lines and whitespace preserved in received copy')
        if args.task9_case in [None, 'focus']:
            fresh()
            page.locator('[data-menu="note"]').click(); page.keyboard.press('Escape'); focused('[data-card="note"]')
            page.keyboard.press('Shift+F10'); page.locator('#card-edit').click()
            page.locator('[data-card="note"]').evaluate('e => window.task9OldCard = e')
            page.locator('#note-text').fill('保存后回到同一张卡'); page.keyboard.press('Control+Enter')
            focused('[data-card="note"]')
            assert page.locator('[data-card="note"]').evaluate('e => e !== window.task9OldCard && !window.task9OldCard.isConnected')
            page.keyboard.press('Shift+F10'); page.locator('#card-take-down').click(); focused('[data-card="pdf"]')
            record(f'W07 {width}px Esc / save DOM replacement / take-down focus resolves same ID or next card')
        if args.task9_case in [None, 'recovery']:
            fresh(); tab_to('#new-note'); page.keyboard.press('Enter')
            page.keyboard.type('Keyboard note\nsecond line'); page.keyboard.press('Control+Enter'); focused('[data-card="new-1"]')
            page.keyboard.press('Shift+F10'); tab_to('#card-edit'); page.keyboard.press('Enter')
            page.keyboard.press('Control+End'); page.keyboard.type('\nEdited'); page.keyboard.press('Control+Enter'); focused('[data-card="new-1"]')
            page.keyboard.press('Shift+F10'); tab_to('#card-send'); page.keyboard.press('Enter'); focused('[data-card="new-1"]')
            assert page.locator('#received-content').text_content() == 'Keyboard note\nsecond line\nEdited'
            page.keyboard.press('Shift+F10'); tab_to('#card-take-down'); page.keyboard.press('Enter'); focused('[data-card="pdf"]')
            tab_to('#recent-taken-down'); page.keyboard.press('Enter'); tab_to('[data-recover="new-1"]'); page.keyboard.press('Enter'); focused('[data-card="new-1"]')
            expect(page.locator('[data-card="new-1"] .card-text')).to_have_text('Keyboard note\nsecond line\nEdited')
            page.keyboard.press('Enter'); page.keyboard.press('Escape'); focused('[data-card="new-1"]')
            # Undo and recovery archives survive replay; recovered content keeps its ID.
            page.locator('[data-menu="note"]').click(); page.locator('#card-take-down').click()
            page.locator('#undo-take-down').click(); focused('[data-card="note"]')
            page.locator('[data-menu="new-1"]').click(); page.locator('#card-take-down').click()
            page.locator('#reset-desk').click(); page.evaluate('() => { gsap.globalTimeline.timeScale(25); }')
            page.wait_for_function('document.querySelector("#desktop").dataset.playing === "false" && document.querySelector("#desktop").dataset.step === "3"', timeout=25000)
            expect(page.locator('[data-card="new-1"]')).to_have_count(0)
            page.locator('#recent-taken-down').click(); page.locator('[data-recover="new-1"]').click(); focused('[data-card="new-1"]')
            expect(page.locator('[data-card="new-1"] .card-text')).to_have_text('Keyboard note\nsecond line\nEdited')
            fresh()
            for card in ['photo', 'reading', 'note', 'pdf']:
                page.locator(f'[data-menu="{card}"]').click(); page.locator('#card-take-down').click()
            focused('#recent-taken-down'); page.keyboard.press('Enter'); page.keyboard.press('Escape'); focused('#recent-taken-down')
            page.keyboard.press('Enter'); tab_to('[data-recover="note"]'); page.keyboard.press('Enter'); focused('[data-card="note"]')
            record(f'{width}px actual keyboard create/edit/send/take-down/recover/Esc; undo and replay retain same ID/content')
        assert not errors, errors
        ctx.close()
    if args.task9_case in [None, 'recovery']:
        ctx = browser.new_context(); page = ctx.new_page(); page.goto(args.url)
        assert page.evaluate("""() => {
            const {createDemoState,reduceDemo} = InkpegDemo;
            const check = (v,m) => {if(!v)throw Error(m)};
            const base = createDemoState(), snapshot = JSON.stringify(base);
            let s=reduceDemo(base,{type:'OPEN_EDIT',cardID:'note'});
            s=reduceDemo(s,{type:'INPUT',text:'Unfinished edit'});
            s=reduceDemo(s,{type:'CLOSE_EDITOR'});
            s=reduceDemo(s,{type:'SEND',cardID:'note'}); const receipt=JSON.stringify(s.received);
            s=reduceDemo(s,{type:'TAKE_DOWN',cardID:'note'});
            check(s.takenDown.length===1,'archive missing'); const removed=JSON.stringify(s);
            s=reduceDemo(s,{type:'REPLAY'}); s=reduceDemo(s,{type:'RECOVER',cardID:'note'});
            check(JSON.stringify(base)===snapshot,'base mutated');
            check(JSON.stringify(s.received)===receipt,'receipt changed');
            check(s.userCards.find(c=>c.id==='note').text===base.userCards.find(c=>c.id==='note').text,'content lost');
            check(s.editDrafts.note==='Unfinished edit','draft lost');
            check(s.takenDown.length===0,'recovery repeated');
            s=reduceDemo(s,{type:'RECOVER',cardID:'note'});
            check(s.userCards.filter(c=>c.id==='note').length===1,'duplicate ID');
            check(JSON.parse(removed).takenDown.length===1,'prior state changed');
            let scene=reduceDemo(createDemoState(),{type:'PLAY'});
            for(let phase=0;phase<5;phase++)scene=reduceDemo(scene,{type:'ADVANCE',runID:scene.scenario.runID,phase});
            const sceneReceipt=JSON.stringify(scene.scenario.received), sceneID=scene.scenario.received.id;
            scene=reduceDemo(scene,{type:'TAKE_DOWN',cardID:sceneID});
            scene=reduceDemo(scene,{type:'RECOVER',cardID:sceneID});
            scene=reduceDemo(scene,{type:'PLAY'});
            scene=reduceDemo(scene,{type:'ADVANCE',runID:scene.scenario.runID,phase:5});
            check([...scene.userCards,...scene.scenario.cards].filter(c=>c.id===sceneID).length===1,'scene recovery duplicated ID at completion');
            check(JSON.stringify(scene.scenario.received)===sceneReceipt && !scene.received,'scene recovery changed receipt owner');
            scene=reduceDemo(scene,{type:'TAKE_DOWN',cardID:sceneID});scene=reduceDemo(scene,{type:'REPLAY'});
            scene=reduceDemo(scene,{type:'RECOVER',cardID:sceneID});
            check(scene.userCards.some(c=>c.id===sceneID && c.text===JSON.parse(sceneReceipt).text),'scene copy lost on replay');return true;
        }""")
        ctx.close(); record('Pure immutable recovery preserves original card IDs/content, receipt ownership and unfinished drafts across replay; repeated restore is idempotent')

def task14_regressions(browser):
    ctx = browser.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
    page = ctx.new_page(); page.goto(args.url + '/?state=overflow', wait_until='networkidle')
    page.locator('#shelf').evaluate('e => e.scrollLeft = 0'); page.wait_for_timeout(400)
    page.locator('#desktop').scroll_into_view_if_needed()
    before = page.locator('#shelf-track [data-card]').evaluate_all('es => es.map(e => e.dataset.card)')
    box = page.locator('[data-card="reading"]').bounding_box()
    x, y = box['x'] + 50, box['y'] + 65
    cdp = ctx.new_cdp_session(page)
    cdp.send('Input.dispatchTouchEvent', {'type':'touchStart','touchPoints':[{'x':x,'y':y,'id':1}]})
    for delta in [20,40,60,80,100]:
        cdp.send('Input.dispatchTouchEvent', {'type':'touchMove','touchPoints':[{'x':x-delta,'y':y,'id':1}]})
        page.wait_for_timeout(35)
        assert page.locator('.drag-ghost').count() == 0, 'Browsing a card must not create a drag ghost'
    cdp.send('Input.dispatchTouchEvent', {'type':'touchEnd','touchPoints':[]})
    page.wait_for_timeout(400)
    assert page.locator('#shelf').evaluate('e => e.scrollLeft') > 50, '100px touch swipe did not browse shelf'
    assert page.locator('#shelf-track [data-card]').evaluate_all('es => es.map(e => e.dataset.card)') == before
    expect(page.locator('#card-popover')).to_be_hidden()
    record('100px Chromium touch pan browses card surface without ghost, popover, creation or take-down')
    page.screenshot(path=str(out / 'touch-pan-390.png'))
    def fresh(state='overflow'):
        page.goto(args.url + '/?state=' + state, wait_until='networkidle')
        page.locator('#desktop').scroll_into_view_if_needed()
        page.locator('#shelf').evaluate('e => e.scrollLeft = 0'); page.wait_for_timeout(350)
    def points(kind, coords):
        cdp.send('Input.dispatchTouchEvent', {'type':kind,'touchPoints':[{'x':x,'y':y,'id':i+1} for i,(x,y) in enumerate(coords)]})
    def origin(selector, offset=0):
        box=page.locator(selector).bounding_box()
        return box['x']+box['width']/2, box['y']+box['height']/2+offset
    # Browser-owned vertical scroll from the same card surface.
    fresh(); x,y=origin('[data-card="photo"]',-20); previous=page.evaluate('scrollY')
    points('touchStart',[(x,y)])
    for dy in [20,40,60,80,100]:
        points('touchMove',[(x,y-dy)]); page.wait_for_timeout(35)
    points('touchEnd',[]); page.wait_for_timeout(350)
    assert page.evaluate('scrollY') > previous+40
    expect(page.locator('.drag-ghost')).to_have_count(0)
    record('Card surface allows vertical native page pan in Chromium touch emulation')
    # Real browser touch input cancels a live handle drag without publishing.
    for cancellation in ['pointercancel','lostpointercapture']:
        fresh(); x,y=origin('[data-card="photo"] .drag-handle')
        points('touchStart',[(x,y)]); points('touchMove',[(x+20,y+20)])
        expect(page.locator('.drag-ghost')).to_have_count(1)
        if cancellation == 'pointercancel': points('touchCancel',[])
        else:
            page.locator('[data-card="photo"]').evaluate("e => {for(let id=1;id<50;id++)if(e.hasPointerCapture(id))e.releasePointerCapture(id)}")
            page.wait_for_timeout(50); points('touchEnd',[])
        expect(page.locator('.drag-ghost')).to_have_count(0)
        expect(page.locator('.drag-origin')).to_have_count(0)
        assert page.locator('#shelf-track [data-card]').evaluate_all('es => es.map(e => e.dataset.card)') == before
        assert page.locator('#receive-zone').get_attribute('data-received-id') is None
        record(cancellation + ' clears a live captured touch drag without creating/sending/removing material')
    fresh('received'); x,y=origin('[data-card="photo"] .drag-handle'); tx,ty=origin('#receive-zone')
    points('touchStart',[(x,y)])
    for part in range(1,11):
        points('touchMove',[(x+(tx-x)*part/10,y+(ty-y)*part/10)]); page.wait_for_timeout(20)
    points('touchEnd',[])
    expect(page.locator('#receive-zone')).to_have_attribute('data-received-id','photo')
    expect(page.locator('#card-popover')).to_be_hidden()
    page.locator('[data-card="photo"]').dispatch_event('click', {'detail':1})
    expect(page.locator('#card-popover')).to_be_hidden()
    expect(page.locator('#desktop-toast')).to_have_text('已放到输入窗口 · 绳上的卡片仍然保留')
    page.locator('[data-card="photo"]').tap()
    expect(page.locator('#receive-zone')).to_have_attribute('data-received-id','photo')
    expect(page.locator('#desktop-toast')).to_have_text('网页复用预览 · 实际 App 可复制或拖出材料副本')
    record('Visible handle delivers by actual touch drag; post-drag click suppressed; later intentional tap works')
    fresh(); x,y=origin('[data-card="photo"]',-20)
    points('touchStart',[(x-25,y),(x+25,y)])
    for distance in [35,45,60,75,90]:
        points('touchMove',[(x-distance,y),(x+distance,y)]); page.wait_for_timeout(60)
    points('touchEnd',[]); page.wait_for_timeout(300)
    scale=page.evaluate('visualViewport.scale')
    assert scale > 1.1, ('two-finger pinch did not zoom',scale)
    expect(page.locator('.drag-ghost')).to_have_count(0)
    assert page.locator('#shelf-track [data-card]').evaluate_all('es => es.map(e => e.dataset.card)') == before
    page.screenshot(path=str(out / 'chromium-pinch.png'))
    record(f'Two-finger Chromium touch pinch zooms to {scale:.2f} with unchanged cards; physical Safari NOT VERIFIED')
    cdp.send('Emulation.setPageScaleFactor', {'pageScaleFactor':2})
    assert page.evaluate('visualViewport.scale') == 2
    page.screenshot(path=str(out / 'chromium-200-percent-visual-scale.png'))
    record('Chromium visual viewport at 200% captured; desktop browser zoom and physical Safari remain NOT VERIFIED')
    ctx.close()
    measurements=[]
    for width,height in [(1280,800),(1440,900),(320,780),(360,780),(390,844),(430,932)]:
        ctx=browser.new_context(viewport={'width':width,'height':height}, reduced_motion='reduce')
        page=ctx.new_page(); errors=[]; page.on('pageerror',lambda e: errors.append(str(e)))
        page.goto(args.url,wait_until='networkidle')
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
        play=page.locator('#guide-play').bounding_box()
        if width>760: assert play['y']+play['height'] <= height
        page.screenshot(path=str(out/f'initial-{width}.png'))
        page.locator('#playground').screenshot(path=str(out/f'playground-{width}.png'))
        selectors=['.work-paragraph','.guide-copy p','.hero-footnote','.release-note','.file-tip','.source-add','.window-bar','.card-kind','.card-title','.receiver-note','.receive-zone','.note-bottom','.download-links','.download-button span','.hero-aside','.feature-lines p','.faq details p','.download-section .eyebrow']
        colors=page.evaluate("""selectors => selectors.map(selector => {
          const e=document.querySelector(selector),style=getComputedStyle(e);
          let node=e,bg;
          while(node){bg=getComputedStyle(node).backgroundColor;if(bg.startsWith('rgb('))break;node=node.parentElement}
          return {selector,color:style.color,background:bg,font:parseFloat(style.fontSize)};
        })""",selectors)
        import re
        def luminance(color):
            rgb=[float(n)/255 for n in re.findall(r'[\d.]+',color)[:3]]
            v=[n/12.92 if n<=.04045 else ((n+.055)/1.055)**2.4 for n in rgb]
            return .2126*v[0]+.7152*v[1]+.0722*v[2]
        for color in colors:
            a,b=sorted([luminance(color['color']),luminance(color['background'])])
            color['contrast']=(b+.05)/(a+.05)
            assert color['contrast']>=4.5,color
        if width<=760:
            for selector in ['.work-paragraph','.receive-zone','.note-body textarea','.card-text']:
                assert page.locator(selector).first.evaluate('e=>parseFloat(getComputedStyle(e).fontSize)') >=16
            for selector in ['.file-tip','.guide-copy p','.receiver-note','.card-kind','.card-title']:
                assert page.locator(selector).first.evaluate('e=>parseFloat(getComputedStyle(e).fontSize)') >=14
        for selector in ['.source-add','#guide-play','#guide-next','#reset-desk','#new-note','[data-step="0"]','.drag-handle']:
            box=page.locator(selector).first.bounding_box()
            assert box and box['width']>=44 and box['height']>=44,(selector,box)
        page.locator('[data-step="2"]').click();page.locator('#shelf-next').click()
        assert page.locator('#shelf').evaluate('e=>e.scrollLeft')>50
        page.locator('#shelf-prev').click();page.locator('#shelf').focus();page.keyboard.press('ArrowRight')
        assert page.locator('#shelf').evaluate('e=>e.scrollLeft')>50
        for step,focus in [(0,'source'),(1,'note'),(2,'shelf'),(3,'receiver')]:
            page.locator(f'[data-step="{step}"]').click()
            expect(page.locator('#desktop')).to_have_attribute('data-focus',focus)
            if width<=760:
                if step==0: expect(page.locator('#work-window')).to_be_visible()
                else: expect(page.locator('#work-window')).to_be_hidden()
                if step==3: expect(page.locator('#receiver')).to_be_visible()
            if step==1:
                page.locator('#note-text').fill('手机记事 · 保留换行\n第二行')
                page.screenshot(path=str(out/f'note-{width}.png'))
                page.locator('#close-note').click()
        measurements.append({'width':width,'height':height,'colors':colors})
        assert not errors,errors
        ctx.close()
        record(f'{width}×{height}: no overflow/errors, colors ≥4.5, type/44px controls, all steps, arrows and keyboard')
    ctx=browser.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True)
    page=ctx.new_page();page.goto(args.url+'/?state=note',wait_until='networkidle')
    page.locator('#note-text').fill('缩小可见窗口后仍能提交')
    page.set_viewport_size({'width':390,'height':360});page.wait_for_timeout(150)
    box=page.locator('#hang-note').bounding_box()
    assert box['y']>=0 and box['y']+box['height']<=360,box
    page.screenshot(path=str(out/'note-resized-viewport.png'))
    page.locator('#hang-note').tap()
    expect(page.locator('[data-card="new-1"]')).to_have_count(1)
    record('360px-high simulated visualViewport resize keeps submit visible and operable; real keyboard NOT VERIFIED')
    ctx.close()
    (out/'measurements.json').write_text(json.dumps(measurements,ensure_ascii=False,indent=2))
    (out/'results.json').write_text(json.dumps({'result':'PASS','checks':results,'count':len(results)},ensure_ascii=False,indent=2))

def task15_regressions(browser):
    # The public entry must be reachable before any scroll, and run real commands.
    evidence=[]
    for width,height in [(1280,800),(1440,900),(390,844)]:
        ctx=browser.new_context(viewport={'width':width,'height':height}, record_video_dir=str(out/'task15-video'))
        page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        page.goto(args.url,wait_until='networkidle')
        for selector in ['#hero-play','#hero-try']:
            assert page.locator(selector).count()==1, f'Missing first-screen entry: {selector}'
            box=page.locator(selector).bounding_box()
            assert box['y']>=0 and box['y']+box['height']<=height,(selector,box)
            assert box['height']>=44
        page.wait_for_timeout(350)
        page.screenshot(path=str(out/f'task15-first-{width}.png'))
        page.locator('#hero-play').click();started=time.monotonic();frames=[]
        for phase in [1,2,3,4,5,6]:
            page.wait_for_function('(phase)=>Number(document.querySelector("#desktop").dataset.phase)>=phase',arg=phase,timeout=20000)
            observed=page.locator('#desktop').evaluate('e=>({...e.dataset})')
            frame={'phase':phase,'elapsed':round(time.monotonic()-started,3),'observed':observed}
            if phase==1:
                material=observed['materialId']; content=page.locator('#demo-material-text').text_content()
            assert observed['materialId']==material
            if phase==2: expect(page.locator('#note-text')).to_have_value(content)
            if phase in [3,4,5]:
                expect(page.locator(f'[data-card="{material}"] .card-text')).to_have_text(content)
            if phase==4:
                assert observed['foundId']==material
                assert page.locator(f'[data-card="{material}"]').evaluate('e=>{const a=e.getBoundingClientRect(),b=document.querySelector("#shelf").getBoundingClientRect();return a.left>=b.left&&a.right<=b.right}')
            if phase>=5:
                expect(page.locator('#receive-zone')).to_have_attribute('data-received-id',material)
                expect(page.locator('#received-content')).to_have_text(content)
            page.wait_for_timeout(350)
            page.screenshot(path=str(out/f'task15-{width}-phase-{phase}.png'));frames.append(frame)
        elapsed=time.monotonic()-started
        assert 14.5<=elapsed<=17,elapsed
        expect(page.locator('#desktop')).to_have_attribute('data-playing','false')
        evidence.append({'width':width,'elapsed':elapsed,'material':material,'content':content,'frames':frames})
        page.locator('#features').scroll_into_view_if_needed();page.screenshot(path=str(out/f'task15-story-{width}.png'))
        page.locator('#playground').scroll_into_view_if_needed();page.screenshot(path=str(out/f'task15-return-{width}.png'))
        page.locator('#hero-try').click();expect(page.locator('#note-dialog')).to_be_visible()
        page.locator('#note-text').fill('我接手这一张材料\n保留完整换行');page.locator('#hang-note').click()
        expect(page.locator('[data-card="new-1"] .card-text')).to_have_text('我接手这一张材料\n保留完整换行')
        assert not errors,errors
        ctx.close();record(f'Task15 {width}: visible entries, 15-second commands, same material/content, scroll return, manual entry')
    ctx=browser.new_context(viewport={'width':390,'height':844},reduced_motion='reduce',record_video_dir=str(out/'task15-reduced-video'))
    page=ctx.new_page();page.goto(args.url,wait_until='networkidle');page.locator('#hero-play').click()
    page.wait_for_function('document.querySelector("#desktop").dataset.phase === "2"')
    page.locator('#note-text').fill('立即接管，不等待演示')
    page.wait_for_timeout(4200)
    expect(page.locator('#desktop')).to_have_attribute('data-playing','false')
    expect(page.locator('#note-text')).to_have_value('立即接管，不等待演示')
    expect(page.locator('#note-dialog')).to_be_visible()
    page.screenshot(path=str(out/'task15-reduced-takeover.png'))
    page.locator('#hang-note').click()
    expect(page.locator('[data-card="new-1"] .card-text')).to_have_text('立即接管，不等待演示')
    page.locator('a[href="install.html"]').first.click();expect(page).to_have_url(args.url+'/install.html')
    expect(page.locator('#first-install')).to_be_visible();expect(page.locator('#upgrade')).to_be_visible()
    for anchor in ['#first-install','#security','#upgrade','#limits']:
        expect(page.locator(f'.install-nav a[href="{anchor}"]')).to_be_visible()
    page.locator('.install-nav a[href="#upgrade"]').click()
    expect(page.locator('#upgrade')).to_be_in_viewport()
    assert page.locator('a[href="https://support.apple.com/zh-cn/102445"]').count()==1
    assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
    page.screenshot(path=str(out/'task15-install-mobile.png'),full_page=True)
    page.locator('a[href="index.html#download"]').first.click();expect(page.locator('#download')).to_be_in_viewport()
    ctx.close();record('Task15 reduced-motion immediate takeover, draft submission and readable installation navigation')
    ctx=browser.new_context(viewport={'width':1440,'height':900},permissions=['clipboard-read','clipboard-write'])
    page=ctx.new_page();page.goto(args.url,wait_until='networkidle')
    page.locator('[data-card="reading"]').click()
    assert page.evaluate('navigator.clipboard.readText()')=='让注意力，\n回到事情本身。'
    expect(page.locator('#card-popover')).to_be_hidden()
    page.locator('[data-card="note"]').click()
    expect(page.locator('#note-text')).to_have_value('先整理材料，\n再整理思路。')
    page.locator('#note-text').fill('单击编辑，原卡保存');page.locator('#hang-note').click()
    expect(page.locator('[data-card="note"] .card-text')).to_have_text('单击编辑，原卡保存')
    page.locator('[data-card="pdf"]').click()
    expect(page.locator('#receive-zone')).to_have_attribute('data-received-id','pdf')
    expect(page.locator('#desktop-toast')).to_have_text('网页复用预览 · 实际 App 可复制或拖出材料副本')
    for entry in ['button','context','keyboard']:
        if entry=='button': page.locator('[data-menu="note"]').click()
        elif entry=='context': page.locator('[data-card="note"]').click(button='right')
        else: page.locator('[data-card="note"]').focus();page.keyboard.press('Shift+F10')
        expect(page.locator('#card-popover')).to_be_visible()
        for selector in ['#card-copy','#card-send','#card-edit','#card-take-down']:
            expect(page.locator(selector)).to_be_visible()
        page.keyboard.press('Escape');expect(page.locator('[data-card="note"]')).to_be_focused()
    source=page.locator('#demo-material-text').text_content()
    page.locator('.source-add').click()
    expect(page.locator('[data-card="new-1"] .card-text')).to_have_text(source)
    page.locator('[data-menu="new-1"]').click();page.locator('#card-send').click()
    expect(page.locator('#receive-zone')).to_have_attribute('data-received-id','new-1')
    expect(page.locator('#received-content')).to_have_text(source)
    page.screenshot(path=str(out/'task15-primary-actions.png'));ctx.close()
    record('Task15 primary click: text exact clipboard, note edits same ID, file honest preview; full menu via button/right-click/keyboard')
    (out/'task15-measurements.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2))
    (out/'results.json').write_text(json.dumps({'result':'PASS','checks':results,'count':len(results)},ensure_ascii=False,indent=2))

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    if args.task15_only:
        task15_regressions(browser)
        browser.close()
        print('ALL TASK15 CHECKS PASSED:',len(results))
        raise SystemExit(0)
    if args.task14_only:
        task14_regressions(browser)
        browser.close()
        print('ALL TASK14 CHECKS PASSED:', len(results))
        raise SystemExit(0)
    if args.task9_only:
        task9_regressions(browser)
        browser.close()
        print('ALL TASK9 CHECKS PASSED:', len(results))
        raise SystemExit(0)
    if args.task8_only:
        task8_regressions(browser)
        browser.close()
        print('ALL TASK8 CHECKS PASSED:', len(results))
        raise SystemExit(0)
    context = browser.new_context(viewport={'width': 1440, 'height': 1080}, accept_downloads=True)
    page = context.new_page(); errors = []; external = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
    page.on('request', lambda r: external.append(r.url) if urlparse(r.url).netloc != urlparse(args.url).netloc else None)
    page.goto(args.url); page.wait_for_load_state('networkidle')
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '4')
    expect(page.locator('#shelf-nav')).to_be_hidden()
    page.locator('[data-menu="photo"]').click()
    expect(page.locator('#card-copy')).to_be_hidden(); expect(page.locator('#card-edit')).to_be_hidden()
    page.locator('#popover-close').click()
    record('Fit shelf hides navigation; image actions do not expose unsupported text copy')
    page.locator('.source-add').click()
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '5')
    record('Click source hangs an additional card')
    page.locator('#new-note').click(); expect(page.locator('#note-dialog')).to_be_visible()
    page.locator('#hang-note').click(); expect(page.locator('#note-dialog')).to_be_visible()
    text = '跨语言工作计划 Q4 2026\n保留换行、长数字 202610102130 和阅读时想到的一句话。'
    page.locator('#note-text').fill(text); page.locator('#note-text').press('Control+Enter')
    expect(page.locator('#note-dialog')).to_be_hidden(); expect(page.locator('#desktop')).to_have_attribute('data-card-count', '6')
    note = page.locator('[data-menu="new-2"]'); note.click(); page.locator('#card-edit').click()
    expect(page.locator('#note-text')).to_have_value(text)
    page.locator('#note-text').fill(text + '\n继续想。'); page.locator('#hang-note').click()
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '6')
    record('Note validation, keyboard publication, multiline fidelity, and edit-in-place')
    page.locator('[data-step="2"]').click(); expect(page.locator('#desktop')).to_have_attribute('data-card-count', '12')
    page.locator('#shelf-next').click()
    page.wait_for_function('document.querySelector("#shelf").scrollLeft > 100')
    page.locator('#shelf-prev').click()
    page.wait_for_function('document.querySelector("#shelf").scrollLeft < 2')
    page.locator('#shelf').focus(); page.locator('#shelf').press('ArrowRight')
    page.wait_for_function('document.querySelector("#shelf").scrollLeft > 100')
    page.locator('#shelf-prev').click(); page.wait_for_function('document.querySelector("#shelf").scrollLeft < 2')
    record('Overflow, both navigation directions, and keyboard shelf controls')
    page.locator('[data-menu="reading"]').click(); page.locator('#card-send').click()
    expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '12')
    record('Equivalent click-to-send preserves original card and exact text')
    page.goto(args.url); page.wait_for_load_state('networkidle'); expect(page.locator('#desktop')).to_have_attribute('data-card-count', '4')
    drag(page, '#desk-file', '#rope-area')
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '5')
    record('Actual pointer drag from desktop file to rope')
    page.locator('#shelf').evaluate('(e) => e.scrollLeft = 0')
    drag(page, '[data-card="reading"]', '#receive-zone')
    expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '5')
    record('Actual pointer drag to receiver leaves shelf material intact')
    page.locator('[data-menu="reading"]').click(); page.locator('#card-take-down').click()
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '4')
    record('Take-down updates shelf count without moving unrelated cards')
    page.goto(args.url); page.wait_for_load_state('networkidle'); page.locator('#guide-play').click()
    expect(page.locator('#desktop')).to_have_attribute('data-playing', 'true')
    page.locator('#guide-play').click(); expect(page.locator('#desktop')).to_have_attribute('data-playing', 'false')
    page.locator('[data-step="2"]').click(); page.goto(args.url); page.wait_for_load_state('networkidle')
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '4')
    page.locator('#guide-play').click()
    desktop_box = page.locator('#desktop').bounding_box()
    assert desktop_box['y'] >= 0 and desktop_box['y'] + desktop_box['height'] <= 1080
    page.wait_for_function('document.querySelector("#desktop").dataset.step === "1"')
    note_box = page.locator('#note-dialog').bounding_box()
    assert note_box['y'] >= 0 and note_box['y'] + note_box['height'] <= 1080
    page.wait_for_function('document.querySelector("#desktop").dataset.playing === "false" && document.querySelector("#desktop").dataset.step === "3"', timeout=25000)
    expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '4')
    expect(page.locator('#desktop')).to_have_attribute('data-user-card-count', '4')
    expect(page.locator('#desktop')).to_have_attribute('data-scenario-card-count', '0')
    assert page.locator('#receive-zone').get_attribute('data-received-id').startswith('scenario-')
    record('Complete guide performs four real state changes; pause and clean-page isolation work')
    page.goto(args.url); page.wait_for_load_state('networkidle')
    page.locator('[data-menu="note"]').click(); page.locator('#card-edit').click()
    page.locator('#close-note').click(); page.locator('#guide-play').click()
    page.wait_for_function('document.querySelector("#desktop").dataset.playing === "false" && document.querySelector("#desktop").dataset.step === "3"', timeout=25000)
    expect(page.locator('[data-card="note"] .card-text')).to_have_text('先整理材料，\n再整理思路。')
    expect(page.locator('#desktop')).to_have_attribute('data-card-count', '4')
    expect(page.locator('#desktop')).to_have_attribute('data-user-card-count', '4')
    expect(page.locator('#desktop')).to_have_attribute('data-scenario-card-count', '0')
    record('Guide creates its own note without replacing a previously edited card')
    # Escape cancels rather than publishing a drag, and drafts remain readable.
    page.locator('#new-note').click(); page.locator('#note-text').fill('未完成的想法'); page.locator('#note-text').press('Escape')
    expect(page.locator('#note-dialog')).to_be_hidden(); page.locator('#new-note').click()
    expect(page.locator('#note-text')).to_have_value('未完成的想法'); page.locator('#close-note').click()
    record('Closing and reopening retains an unfinished note')
    # Check genuine downloadable bytes, not merely presence of a link.
    release = page.request.get(args.url + '/downloads/release.json').json()
    with page.expect_download() as pending:
        page.locator('.download-button').click()
    download = pending.value; file = out / download.suggested_filename; download.save_as(file)
    assert hashlib.sha256(file.read_bytes()).hexdigest() == release['sha256']
    assert release['architectures'] == ['arm64', 'x86_64']
    for path in ['downloads/安装教程.md', 'downloads/本版限制.md', 'downloads/SHA256SUMS.txt', 'LICENSE.txt']:
        assert page.request.get(args.url + '/' + path).status == 200, path
    assert page.locator('.download-links a[href="https://github.com/CSlawyer1985/Inkpeg"]').count() == 1
    record('Actual DMG download, exact SHA256, architecture metadata, docs, and correct repository')
    for width, height in [(1440, 1080), (1024, 900), (768, 1024), (390, 844), (360, 780), (320, 780)]:
        page.set_viewport_size({'width': width, 'height': height}); page.goto(args.url); page.wait_for_load_state('networkidle')
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), (width, page.evaluate('document.documentElement.scrollWidth'))
        expect(page.locator('#guide-play')).to_be_visible()
        page.locator('[data-step="1"]').click(); page.locator('#note-text').fill('非常长的中文记事名称与 International_Project_Report_20261010.pdf\n' * 8)
        page.locator('#hang-note').click(); page.locator('[data-menu="new-1"]').click(); page.locator('#card-send').click()
        assert page.locator('#received-content').inner_text().startswith('非常长的中文记事名称')
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), ('long text', width)
        record(f'Responsive {width}px with long mixed-script content and accessible click equivalents')
    # Equivalent 200% desktop reading viewport; DPR alone would not zoom CSS layout.
    page.set_viewport_size({'width': 720, 'height': 540}); page.goto(args.url); page.wait_for_load_state('networkidle')
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1')
    record('200% equivalent layout viewport keeps controls reachable')
    page.emulate_media(reduced_motion='reduce'); page.goto(args.url); page.wait_for_load_state('networkidle')
    page.locator('[data-step="2"]').click(); page.locator('#shelf-next').click()
    assert page.locator('#shelf').evaluate('(e) => e.scrollLeft') > 0
    page.locator('[data-step="3"]').click(); page.locator('[data-menu="reading"]').click(); page.locator('#card-send').click()
    expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
    expect(page.locator('.feature-lines')).to_be_visible()
    record('Reduced motion retains every essential state and action')
    touch_context = browser.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
    touch = touch_context.new_page(); touch.goto(args.url); touch.wait_for_load_state('networkidle')
    touch.locator('.source-add').tap(); expect(touch.locator('#desktop')).to_have_attribute('data-card-count', '5')
    touch.locator('[data-step="1"]').tap(); touch.locator('#note-text').fill('触屏也能随手记')
    note_box = touch.locator('#note-dialog').bounding_box()
    assert note_box['y'] >= 0 and note_box['y'] + note_box['height'] <= 844
    touch.locator('#hang-note').tap(); expect(touch.locator('#desktop')).to_have_attribute('data-card-count', '6')
    touch.locator('[data-step="2"]').tap(); touch.locator('#shelf-next').tap()
    touch.wait_for_function('document.querySelector("#shelf").scrollLeft > 100')
    touch_context.close(); record('Actual touch tap controls support hanging, notes, and shelf navigation')
    assert not errors, errors
    assert not external, external
    record('No JavaScript/console errors and no external runtime requests')
    task8_regressions(browser)
    task9_regressions(browser)
    task14_regressions(browser)
    task15_regressions(browser)
    browser.close()
(out / 'results.json').write_text(json.dumps({'result': 'PASS', 'checks': results, 'count': len(results)}, ensure_ascii=False, indent=2) + '\n')
print('ALL CHECKS PASSED:', len(results))
