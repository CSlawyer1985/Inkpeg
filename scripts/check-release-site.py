#!/usr/bin/env python3
"""Check current release metadata, real DMG bytes and scoped website renders."""
import argparse, hashlib, json, pathlib
from playwright.sync_api import sync_playwright, expect
ROOT = pathlib.Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(); p.add_argument('--url', default='http://127.0.0.1:8780'); p.add_argument('--out', required=True); args = p.parse_args()
base=args.url.rstrip('/'); out=pathlib.Path(args.out); out.mkdir(parents=True,exist_ok=False)
version=json.loads((ROOT/'packaging/release-version.json').read_text()); manifest=json.loads((ROOT/'site/downloads/release.json').read_text())
assert all(manifest[k]==v for k,v in version.items())
checks=[]
with sync_playwright() as pw:
    browser=pw.chromium.launch(); page=browser.new_page(viewport={'width':1440,'height':1080},accept_downloads=True)
    page.goto(base+'/?noreveal&motion=reduce'); page.wait_for_load_state('networkidle')
    assert page.request.get(base+'/downloads/release.json').json()==manifest
    expect(page.locator('.dl-meta')).to_contain_text(version['version'])
    expect(page.locator('.dl-meta')).to_contain_text('build '+version['build'])
    expect(page.locator('#download-btn')).to_have_attribute('href','downloads/'+manifest['file'])
    raw=page.request.get(base).text()
    assert manifest['file'] in raw and manifest['sha256'] in raw
    assert '诚实的进度表' not in raw and 'id="status"' not in raw and '示意重绘' not in raw and '指针掠过' not in raw
    checks.append('Version/build, static download and requested caption removal match current release')
    for name in manifest['testRecords']+[manifest['sourceRecords']]:
        response=page.request.get(base+'/downloads/'+name); assert response.status==200; response.json()
    expect(page.locator('.steps')).to_contain_text('安装文夹.command')
    expect(page.locator('.steps')).to_contain_text('回车')
    checks.append('Three installation steps name the packaged helper; public provenance records load')
    with page.expect_download() as pending: page.locator('#download-btn').click()
    download=pending.value; downloaded=out/download.suggested_filename; download.save_as(downloaded)
    assert downloaded.name==manifest['file'] and downloaded.stat().st_size==manifest['sizeBytes']
    assert hashlib.sha256(downloaded.read_bytes()).hexdigest()==manifest['sha256']
    checks.append('Actual browser DMG download matches filename, length and SHA256')
    page.locator('#download').screenshot(path=str(out/'installation-desktop.png'))
    mobile=browser.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True)
    phone=mobile.new_page();phone.goto(base+'/?noreveal&motion=reduce');phone.wait_for_load_state('networkidle')
    assert phone.evaluate('document.documentElement.scrollWidth<=innerWidth')
    expect(phone.locator('.dl-meta')).to_contain_text(version['version'])
    phone.locator('#download').screenshot(path=str(out/'installation-mobile.png'))
    checks.append('Desktop and 390px mobile installation sections render without horizontal overflow')
    mobile.close(); browser.close()
files=[x for x in (ROOT/'site').rglob('*') if x.is_file() and x.name!='.DS_Store']
assert len(files)<=20000 and all(x.stat().st_size<=25*1024*1024 for x in files)
checks.append('Site file count and individual sizes satisfy Pages upload limits')
(out/'result.json').write_text(json.dumps({'result':'PASS','checks':checks},ensure_ascii=False,indent=2)+'\n')
for x in checks: print('PASS:',x)
