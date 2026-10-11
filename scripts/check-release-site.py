#!/usr/bin/env python3
"""Final release metadata, click-menu delivery and fresh README renders."""
import argparse, hashlib, json, pathlib, re
from playwright.sync_api import sync_playwright, expect
ROOT=pathlib.Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(); p.add_argument('--url',default='http://127.0.0.1:8768'); p.add_argument('--out',required=True); args=p.parse_args()
out=pathlib.Path(args.out); out.mkdir(parents=True,exist_ok=False)
version=json.loads((ROOT/'packaging/release-version.json').read_text()); manifest=json.loads((ROOT/'site/downloads/release.json').read_text())
assert all(manifest[k]==v for k,v in version.items())
checks=[]
with sync_playwright() as pw:
    browser=pw.chromium.launch(); page=browser.new_page(viewport={'width':1440,'height':1080},device_scale_factor=1)
    page.goto(args.url); page.wait_for_load_state('networkidle')
    assert page.request.get(args.url+'/downloads/release.json').json()==manifest
    expect(page.locator('.download-summary')).to_contain_text('0.2.0')
    expect(page.locator('.download-summary')).to_contain_text('build 2')
    assert page.locator('.download-button').get_attribute('href')=='downloads/'+manifest['file']
    raw=page.request.get(args.url).text()
    assert 'Inkpeg-0.2.0-build2-universal.dmg' in raw and '0.1.0' not in raw
    assert '“···”' in raw and '点卡片选择' not in raw
    assert '“···”' in page.request.get(args.url+'/app.js').text()
    for name in manifest['testRecords']+[manifest['sourceRecords']]:
        response=page.request.get(args.url+'/downloads/'+name); assert response.status==200; response.json()
    checks.append('Actual served release metadata, static fallback, public evidence links and version source match')
    with page.expect_download() as pending:
        page.locator('.download-button').click()
    download=pending.value; downloaded=out/download.suggested_filename; download.save_as(downloaded)
    assert downloaded.name==manifest['file'] and downloaded.stat().st_size==manifest['sizeBytes']
    assert hashlib.sha256(downloaded.read_bytes()).hexdigest()==manifest['sha256']
    checks.append('Actual final DMG browser download: exact filename, size and SHA256 match final manifest')
    page.locator('[data-menu="reading"]').click(); page.locator('#card-send').click()
    expect(page.locator('#received-content')).to_have_text('让注意力，\n回到事情本身。')
    expect(page.locator('#receive-zone')).to_have_attribute('data-received-id','reading')
    checks.append('Actual ellipsis-menu send delivers exact text and card identity')
    page.screenshot(path=str(out/'actual-menu-send.png'))
    # Fresh final page, no mocked data or replaced pixels.
    page.goto(args.url); page.wait_for_load_state('networkidle')
    page.screenshot(path=str(ROOT/'docs/assets/inkpeg-site-desktop.png'),full_page=True)
    mobile=browser.new_context(viewport={'width':390,'height':844},device_scale_factor=1,is_mobile=True,has_touch=True)
    phone=mobile.new_page(); phone.goto(args.url); phone.wait_for_load_state('networkidle')
    expect(phone.locator('.download-summary')).to_contain_text('0.2.0')
    assert phone.evaluate('document.documentElement.scrollWidth<=innerWidth')
    phone.screenshot(path=str(ROOT/'docs/assets/inkpeg-site-mobile.png'),full_page=True)
    checks.append('Fresh desktop 1440x1080 and mobile 390x844 full-page Chromium renders, final metadata loaded')
    mobile.close(); browser.close()
files=[x for x in (ROOT/'site').rglob('*') if x.is_file() and x.name!='.DS_Store']
assert len(files)<=20000 and all(x.stat().st_size<=25*1024*1024 for x in files)
checks.append(f'Actual site tree: {len(files)} files; every asset <=25 MiB')
assets={str(x.relative_to(ROOT)):{'sha256':hashlib.sha256(x.read_bytes()).hexdigest(),'sizeBytes':x.stat().st_size} for x in [ROOT/'docs/assets/inkpeg-site-desktop.png',ROOT/'docs/assets/inkpeg-site-mobile.png']}
(out/'result.json').write_text(json.dumps({'result':'PASS','checks':checks,'images':assets,'servedManifestSHA256':hashlib.sha256((ROOT/'site/downloads/release.json').read_bytes()).hexdigest()},ensure_ascii=False,indent=2)+'\n')
for x in checks: print('PASS:',x)
