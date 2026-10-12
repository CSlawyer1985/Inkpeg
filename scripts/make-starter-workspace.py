#!/usr/bin/env python3
"""Create only product-owned welcome materials; never read a user library."""
import argparse, datetime, hashlib, json, pathlib, shutil
from playwright.sync_api import sync_playwright
ROOT=pathlib.Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--url',default='http://127.0.0.1:8780');args=p.parse_args()
assets=ROOT/'packaging/starter-assets';workspace=ROOT/'packaging/starter-workspace'
with sync_playwright() as pw:
    browser=pw.chromium.launch();page=browser.new_page(viewport={'width':1160,'height':900},device_scale_factor=1)
    page.goto(args.url+'/?noreveal&motion=reduce&theme=light');page.wait_for_load_state('networkidle')
    page.wait_for_function('window.__inkpeg!=null')
    page.add_style_tag(content='.site-header,.skip-link,.site-toast{display:none!important}.reveal-pre{opacity:1!important;transform:none!important}*{animation:none!important}')
    # Keep a static product-page snapshot, without self-referential release SHA.
    page.locator('.checksum-details').evaluate('(e)=>e.remove()')
    page.locator('.dl-meta').evaluate('(e)=>e.remove()')
    page.locator('.dl-links').evaluate('(e)=>e.remove()')
    page.locator('.terminal-alternative').evaluate('(e)=>e.remove()')
    page.locator('#download-btn').evaluate('(e)=>{e.removeAttribute("download");e.href="https://inkpeg.chenshi.ai/#download";e.textContent="前往官网下载安装"}')
    page.emulate_media(media='screen');height=page.evaluate('document.documentElement.scrollHeight')
    page.pdf(path=str(assets/'文夹·产品网页.pdf'),width='1160px',height=str(height+32)+'px',print_background=True,margin={'top':'0','bottom':'0','left':'0','right':'0'})
    browser.close()
shutil.copyfile(ROOT/'site/media/poster-promo.jpg',assets/'文夹·宣传图.jpg')
records=[];matter='00000000-0000-0000-0000-000000000001'
epoch=(datetime.datetime(2026,10,12,2,tzinfo=datetime.timezone.utc)-datetime.datetime(2001,1,1,tzinfo=datetime.timezone.utc)).total_seconds()
spec=[('文夹·介绍记事.txt','text','note','文夹 · 让眼前的资料，一直在手边'),('文夹·宣传图.jpg','image','fileSelection','文夹 · 产品宣传图'),('文夹·产品网页.pdf','pdf','fileSelection','文夹 · 产品网页 PDF')]
for i,(name,kind,origin,title) in enumerate(spec,1):
    mid=f'10000000-0000-0000-0000-{i:012d}';vid=f'20000000-0000-0000-0000-{i:012d}';rel=f'Materials/{mid}/{vid}{pathlib.Path(name).suffix}'
    dest=workspace/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(assets/name,dest);data=dest.read_bytes()
    v={'id':vid,'relativePath':rel,'sha256':hashlib.sha256(data).hexdigest(),'byteCount':len(data),'kind':'original','createdAt':epoch}
    records.append({'id':mid,'kind':kind,'matterID':matter,'status':'hanging','pinned':False,'order':i-1,'title':title,'createdAt':epoch,'source':{'origin':origin,'manualTitle':'文夹产品示例','webURL':'https://inkpeg.chenshi.ai/','isManuallyRegistered':False},'versions':[v],'originalVersionID':vid,'activeVersionID':vid})
(workspace/'state.json').write_text(json.dumps({'schemaVersion':1,'generation':0,'materials':records,'matters':[{'id':matter,'name':'未分组','order':0}],'selectedMatterID':matter,'privacyHidden':False},ensure_ascii=False,indent=2)+'\n')
(workspace/'clipboard-settings.json').write_text(json.dumps({'version':2,'enabled':False,'images':True,'text':True,'files':True,'includeExisting':False},indent=2)+'\n')
print('Generated three product-owned samples: note, promotional image and website PDF')
