#!/usr/bin/env python3
"""Verify the 2.0 site's real browser behavior and downloaded release bytes."""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:8767')
parser.add_argument('--out', required=True)
parser.add_argument('--cancel-only', action='store_true')
parser.add_argument('--download-guard-only', action='store_true')
parser.add_argument('--reset-only', action='store_true')
parser.add_argument('--resize-only', action='store_true')
args = parser.parse_args()
base = args.url.rstrip('/')
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
checks = []


def record(name):
    checks.append(name)
    print('PASS:', name, flush=True)


def count(page):
    return page.evaluate('window.__inkpeg.line.live.length')


def load(page, query='?noreveal&motion=reduce'):
    page.goto(base + '/' + query)
    page.wait_for_function('window.__inkpeg && window.__inkpeg.line.live.length === 3')
    page.locator('#playground').scroll_into_view_if_needed()


def drag_to(page, source, x, y):
    b = page.locator(source).bounding_box()
    assert b, source
    page.mouse.move(b['x'] + b['width'] / 2, b['y'] + min(20, b['height'] / 2))
    page.mouse.down()
    page.mouse.move(x, y, steps=14)


def cancel_input(page):
    load(page)
    b = page.locator('.pg-screen').bounding_box()
    n = count(page)
    x, y = b['x'] + b['width'] * .3, b['y'] + 60
    drag_to(page, '.pg-screen [data-src=chart]', x, y)
    page.locator('.pg-screen').dispatch_event('pointercancel', {'clientX': x, 'clientY': y, 'pointerId': 1})
    page.mouse.up()
    assert count(page) == n, 'Cancelled pointer must not publish a material'
    assert page.locator('.pg-screen .ik-ghost').count() == 0
    assert not page.locator('.pg-screen .ik-line').evaluate('(e) => e.classList.contains("drop-near")')
    record('Pointer cancellation never publishes a material or leaves drag feedback')


with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    ctx = browser.new_context(viewport={'width': 1440, 'height': 1080}, accept_downloads=True)
    page = ctx.new_page()
    errors, external = [], []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
    page.on('request', lambda r: external.append(r.url) if urlparse(r.url).netloc != urlparse(base).netloc else None)
    cancel_input(page)
    if args.download_guard_only:
        held = []
        page.route('**/downloads/release.json', lambda r: held.append(r))
        page.goto(base + '/', wait_until='domcontentloaded')
        page.wait_for_function('window.__inkpeg != null')
        expect(page.locator('#download-btn')).to_have_attribute('aria-disabled', 'true')
        record('Unresolved release metadata keeps JavaScript download disabled')
        for request in held:
            request.fulfill(json={'pending': True})
        page.unroute('**/downloads/release.json')
    if args.reset_only:
        load(page)
        page.locator('.pg-screen .ik-red-hit').click()
        page.locator('#ik-note-ta').fill('重置前尚在保存的草稿')
        page.locator('#demo-reset').click()
        page.wait_for_timeout(650)
        assert count(page) == 3
        assert not errors, errors
        record('Reset cancels a pending draft save without a JavaScript error')
    if args.resize_only:
        load(page)
        page.locator('.pg-screen .ik-red-hit').click()
        page.locator('#ik-note-ta').fill('正在写但尚未挂出的想法')
        page.set_viewport_size({'width':390,'height':844})
        expect(page.locator('.pg-screen .ik-panel.note')).to_be_visible()
        expect(page.locator('#ik-note-ta')).to_have_value('正在写但尚未挂出的想法')
        page.wait_for_timeout(650)
        assert not errors, errors
        page.keyboard.press('Escape')
        page.locator('.pg-screen .ik-red-hit').click()
        expect(page.locator('#ik-note-ta')).to_have_value('正在写但尚未挂出的想法')
        record('Responsive rebuilding preserves an open draft and reopening')
    if not args.cancel_only and not args.download_guard_only and not args.reset_only and not args.resize_only:
        load(page)
        screen = page.locator('.pg-screen').bounding_box()
        n = count(page)
        drag_to(page, '.pg-screen [data-src=chart]', screen['x'] + screen['width'] * .3, screen['y'] + 60)
        page.mouse.up()
        page.wait_for_function('window.__inkpeg.line.live.length === 4')
        page.locator('.pg-screen [data-src=pdf]').focus()
        page.keyboard.press('Enter')
        assert count(page) == n + 2
        page.keyboard.press('Enter')
        assert count(page) == n + 2, 'Repeated source must not duplicate a card'
        record('Pointer drag and keyboard hanging; duplicate source rejected')
        peg = page.locator('.pg-screen .ik-peg').first
        peg.focus()
        page.keyboard.press('Enter')
        expect(peg).to_have_class(__import__('re').compile(r'.*copied.*'))
        page.locator('.pg-screen [data-r=paste]').click()
        assert page.locator('.pg-screen [data-r=wlist] > *').count() == 1
        record('Copy and equivalent paste deliver without taking down the original')
        page.locator('.pg-screen .ik-red-hit').click()
        note = page.locator('.pg-screen .ik-panel.note')
        expect(note).to_be_visible()
        page.keyboard.press('Control+Enter')
        expect(note).to_be_visible()
        expect(note.locator('[data-r=st]')).to_contain_text('记事为空')
        text = '跨语言工作计划 Q4 2026\n保留换行、20261012 和阅读时的一句话。'
        ta = page.locator('#ik-note-ta')
        ta.fill(text)
        expect(note.locator('[data-r=st]')).to_contain_text('草稿已保存')
        page.keyboard.press('Escape')
        expect(note).to_be_hidden()
        page.locator('.pg-screen .ik-red-hit').click()
        expect(ta).to_have_value(text)
        n = count(page)
        page.keyboard.press('Control+Enter')
        assert count(page) == n + 1
        expect(note).to_be_hidden()
        note_peg = page.locator('.pg-screen .ik-peg').last
        note_peg.focus()
        page.keyboard.press('Enter')
        expect(ta).to_have_value(text)
        ta.fill(text + '\n继续想。')
        page.keyboard.press('Control+Enter')
        assert count(page) == n + 1
        expect(note_peg.locator('.ik-photo')).to_have_text(text + '\n继续想。')
        record('Blank note rejection, multiline draft recovery and edit-in-place')
        peg.focus()
        page.keyboard.press('Shift+F10')
        assert page.locator('.pg-screen .ik-menu button').count() > 3
        page.keyboard.press('Escape')
        page.locator('#demo-fill').click()
        page.wait_for_function('window.__inkpeg.line.live.length >= 16')
        expect(page.locator('.pg-screen .ik-pager')).to_be_visible()
        page.locator('.pg-screen .ik-pager .prev').click()
        previous = page.evaluate('window.__inkpeg.line.scroll.to')
        page.locator('.pg-screen .ik-pager .next').click()
        assert page.evaluate('window.__inkpeg.line.scroll.to') > previous
        record('Context menu and overflow navigation in both directions')
        page.locator('#demo-reset').click()
        assert count(page) == 3
        screen = page.locator('.pg-screen').bounding_box()
        page.evaluate('() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))')
        first_card = page.locator('.pg-screen .ik-peg').first.locator('.ik-card')
        cb, wb = first_card.bounding_box(), page.locator('.pg-screen [data-r=writer]').bounding_box()
        (out/'drag-geometry.json').write_text(json.dumps({'card':cb,'writer':wb,'screen':screen,'viewport':page.viewport_size},indent=2))
        page.mouse.move(cb['x'] + cb['width'] / 2, cb['y'] + cb['height'] / 2)
        page.mouse.down()
        page.mouse.move(wb['x'] + wb['width'] / 2, wb['y'] + wb['height'] / 2, steps=14)
        page.mouse.up()
        assert count(page) == 3
        assert page.locator('.pg-screen [data-r=wlist] > *').count() == 1
        record('Real pointer drag-out delivers a copy and leaves the card')
        page.keyboard.press('Control+Alt+t')
        assert page.locator('.pg-screen .ik-line').evaluate('(e)=>e.classList.contains("hidden")')
        page.mouse.move(screen['x'] + screen['width'] / 2, screen['y'] + 5)
        page.wait_for_function('!document.querySelector(".pg-screen .ik-line").classList.contains("hidden")')
        page.locator('.pg-screen .ik-peg').first.focus()
        page.keyboard.press('Delete')
        assert count(page) == 2
        page.locator('.pg-screen [data-r=clip]').click()
        page.locator('.pg-screen .ik-menu button', has_text='设置…').click()
        settings = page.locator('.pg-screen .ik-panel.settings')
        settings.locator('[data-r=preview]').click()
        expect(settings.locator('[data-r=sum]')).to_contain_text('已取下资料 1 项')
        settings.locator('[data-r=confirm]').click()
        expect(settings.locator('[data-r=msg]')).to_contain_text('已将 3 项')
        expect(page.locator('#task-progress')).to_have_text('4 / 8')
        record('Hide/reveal, take-down and cleanup preserve the reset task counter')
        page.locator('#demo-reset').click()
        page.locator('#demo-play').click()
        expect(page.locator('#demo-play')).to_have_attribute('aria-pressed', 'true')
        page.wait_for_function('document.querySelector("#demo-play").getAttribute("aria-pressed") === "false"', timeout=25000)
        assert count(page) > 3
        page.locator('#demo-play').click()
        page.locator('#demo-play').click()
        expect(page.locator('#demo-play')).to_have_attribute('aria-pressed', 'false')
        page.locator('#demo-reset').click()
        assert count(page) == 3
        record('Full automatic demonstration, pause and reset')
        release = page.request.get(base + '/downloads/release.json').json()
        assert not release.get('pending') and release['version'] == '2.0.0'
        with page.expect_download() as pending:
            page.locator('#download-btn').click()
        download = pending.value
        file = out / download.suggested_filename
        download.save_as(file)
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        assert digest == release['sha256'] and file.stat().st_size == release['sizeBytes']
        assert download.suggested_filename == 'Inkpeg-2.0.0-build3-universal.dmg'
        expect(page.locator('#sha-value')).to_have_text(digest)
        expect(page.locator('#download-size')).to_contain_text(f"{release['sizeBytes']/1e6:.1f} MB")
        assert release['architectures'] == ['arm64', 'x86_64'] and release['minimumMacOS'] == '14.0'
        assert digest + '  ' + release['file'] in page.request.get(base + '/downloads/SHA256SUMS.txt').text()
        for path in ['downloads/安装教程.md', 'downloads/本版限制.md', 'LICENSE.txt', 'media/promo.zh.vtt']:
            assert page.request.get(base + '/' + path).status == 200, path
        record('Real DMG bytes, SHA256, size, name, architecture metadata and docs agree')
        for width, height in [(1440,1080),(1024,900),(768,1024),(390,844),(360,780),(320,780),(720,540)]:
            for theme in ['light', 'dark']:
                page.set_viewport_size({'width':width,'height':height})
                load(page, '?noreveal&motion=reduce&theme=' + theme)
                assert page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), (width,theme)
                page.locator('.pg-screen .ik-red-hit').click()
                page.locator('#ik-note-ta').fill('非常长的中文记事与 International_Project_Report_20261012.pdf\n' * 8)
                page.keyboard.press('Control+Enter')
                assert count(page) == 4
                assert page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1')
                expect(page.locator('#demo-play')).to_be_visible()
                record(f'Responsive {width}px {theme}, long mixed text and reduced motion')
        touch = browser.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True)
        tp = touch.new_page()
        load(tp)
        tp.locator('.pg-screen [data-src=pdf]').focus()
        tp.keyboard.press('Enter')
        tp.locator('.pg-screen .ik-red-hit').tap()
        tp.locator('#ik-note-ta').fill('触屏也能随手记')
        tp.locator('.pg-screen .ik-panel.note [data-r=hang]').tap()
        assert count(tp) == 5
        tp.locator('#demo-fill').tap()
        tp.wait_for_function('window.__inkpeg.line.live.length === 15')
        tp.locator('.pg-screen .ik-pager .prev').tap()
        touch.close()
        record('Actual touch note, publication and pager controls')
        page.set_viewport_size({'width':1440,'height':1080})
        page.goto(base + '/?noreveal')
        page.locator('#film-play').click()
        page.wait_for_function('document.querySelector("#film-video").videoWidth > 0')
        expect(page.locator('#film-dialog')).to_be_visible()
        page.wait_for_function('document.querySelector("#film-video").currentTime > .1')
        assert not page.locator('#film-video').evaluate('(v)=>v.muted')
        page.keyboard.press('Escape')
        expect(page.locator('#film-dialog')).not_to_be_visible()
        assert page.locator('#film-video').evaluate('(v)=>v.paused')
        page.locator('.film-chapters button[data-t="26.1"]').click()
        page.wait_for_function('document.querySelector("#film-video").currentTime >= 26', timeout=10000)
        page.locator('#film-close').click()
        expect(page.locator('#film-dialog')).not_to_be_visible()
        record('Film opens with audio, Escape pauses and chapter seeking works')
        page.goto(base + '/?noreveal')
        page.route('**/downloads/release.json', lambda r:r.fulfill(json={'version':'2.0.0','pending':True}))
        page.reload()
        expect(page.locator('#download-btn')).to_have_attribute('aria-disabled','true')
        downloads = []
        page.on('download', lambda d: downloads.append(d))
        page.locator('#download-btn').click(force=True)
        page.wait_for_timeout(300)
        assert not downloads
        page.unroute('**/downloads/release.json')
        record('Pending release fails closed and cannot download')
        nojs = browser.new_context(java_script_enabled=False, accept_downloads=True)
        nj = nojs.new_page()
        nj.goto(base + '/')
        with nj.expect_download() as pending:
            nj.locator('#download-btn').click()
        assert pending.value.suggested_filename == 'Inkpeg-2.0.0-build3-universal.dmg'
        nojs.close()
        record('Published fallback download also works without JavaScript')
        assert not errors, errors
        assert not external, external
        record('No JavaScript errors or external runtime requests')
        page.goto(base + '/?noreveal&theme=light')
        page.screenshot(path=str(out/'desktop-light.png'),full_page=True)
        page.set_viewport_size({'width':390,'height':844})
        page.goto(base + '/?noreveal&theme=dark')
        page.screenshot(path=str(out/'mobile-dark.png'),full_page=True)
    browser.close()
(out/'results.json').write_text(json.dumps({'result':'PASS','count':len(checks),'checks':checks},ensure_ascii=False,indent=2)+'\n')
print('ALL CHECKS PASSED:',len(checks))
