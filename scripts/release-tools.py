#!/usr/bin/env python3
"""Bounded release provenance and actual bundle inspection. No signing/install changes."""
import argparse, hashlib, json, pathlib, plistlib, re, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
INPUT_FILES = ['Package.swift', 'LICENSE', 'scripts/build-inkpeg.sh', 'scripts/package-inkpeg.sh',
 'scripts/make-icon.swift', 'scripts/release-tools.py', 'scripts/verify-inkpeg.sh',
 'packaging/release-version.json', 'packaging/先读我-安装与使用.txt', 'packaging/来源与致谢.txt',
 'docs/inkpeg/INSTALL.md', 'docs/inkpeg/KNOWN-ISSUES.md', 'site/assets/mark.svg']
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def write(path, value): path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def version(root):
    value=json.loads((root/'packaging/release-version.json').read_text())
    if set(value)!={'version','build','minimumMacOS'} or not re.fullmatch(r'\d+\.\d+\.\d+',value['version']) or not re.fullmatch(r'\d+',value['build']) or not re.fullmatch(r'\d+\.\d+',value['minimumMacOS']): raise ValueError('Invalid release version')
    return value
def inputs(root):
    paths=[root/f for f in INPUT_FILES if (root/f).is_file()]
    for folder in ['Sources','packaging/brand']:
        paths.extend(p for p in (root/folder).rglob('*') if p.is_file() and p.name!='.DS_Store' and '__pycache__' not in p.parts)
    return [{'path':p.relative_to(root).as_posix(),'sha256':sha(p)} for p in sorted(set(paths))]
def fingerprint(files):
    return hashlib.sha256(''.join(f"{f['path']}\0{f['sha256']}\n" for f in files).encode()).hexdigest()
def source():
    files=inputs(ROOT)
    return {'schema':1,'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
      'dirty':bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=all'],cwd=ROOT,text=True)),
      'sha256':fingerprint(files),'algorithm':'SHA256 of sorted UTF-8 relative-path + NUL + file-sha256 + LF',
      'scope':'All Sources files including untracked; packaging/brand; explicit build, version and package-document inputs. Excludes .DS_Store, tests, website implementation, generated manifests, DMGs, logs and other outputs.', 'files':files}
def check_metadata(info, minimums, expected):
    actual={k:info[v] for k,v in [('version','CFBundleShortVersionString'),('build','CFBundleVersion'),('minimumMacOS','LSMinimumSystemVersion')]}
    if actual!=expected or not minimums or any(x!=expected['minimumMacOS'] for x in minimums): raise ValueError('Bundle/binary/version mismatch')
    if info.get('CFBundleIconFile')!='Inkpeg.icns': raise ValueError('Missing branded icon declaration')
def inspect(app):
    binary=app/'Contents/MacOS/Inkpeg'; info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    archs=sorted(subprocess.check_output(['lipo','-archs',str(binary)],text=True).split())
    minimums=[]
    for arch in archs:
        commands=subprocess.check_output(['otool','-arch',arch,'-l',str(binary)],text=True)
        match=re.search(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([\d.]+)',commands)
        if not match: raise ValueError('No binary minimum OS')
        minimums.append(match.group(1))
    check_metadata(info,minimums,version(ROOT))
    if not archs or set(archs) - {'arm64','x86_64'}: raise ValueError('Unsupported binary architecture')
    resources=subprocess.check_output([str(binary),'--check-resources'],text=True).strip()
    if resources!='Inkpeg resources OK: en, es, zh-Hans': raise ValueError('Resource validation failed')
    if sha(app/'Contents/Resources/Inkpeg.icns')!=sha(ROOT/'packaging/brand/Inkpeg.icns'): raise ValueError('Icon mismatch')
    provenance=json.loads((app/'Contents/Resources/build-source.json').read_text())
    if provenance['sha256']!=source()['sha256']: raise ValueError('Build inputs changed after build')
    code=subprocess.run(['codesign','-dvv',str(binary)],text=True,capture_output=True)
    bundlecode=subprocess.run(['codesign','-dvv',str(app)],text=True,capture_output=True)
    signature=code.stdout+code.stderr
    if 'Authority=Developer ID' in signature or 'Authority=Developer ID' in bundlecode.stderr: raise ValueError('Unexpected signing state; review required')
    staple=subprocess.run(['xcrun','stapler','validate',str(app)],text=True,capture_output=True)
    return dict(version(ROOT),architectures=archs,minimumOSBySlice=dict(zip(archs,minimums)),resources=resources,
      iconSHA256=sha(app/'Contents/Resources/Inkpeg.icns'),binarySHA256=sha(binary),source=provenance,
      developerIDSigned=False,notarized=False,signing={'binary':'ad-hoc' if 'Signature=adhoc' in signature else 'unsigned',
       'bundleInspectionExit':bundlecode.returncode,'staplerValidationExit':staple.returncode,'note':'No Developer ID identity or notarization supplied. Linker ad-hoc signature is not identity verification.'})
def main():
    parser=argparse.ArgumentParser(); parser.add_argument('action',choices=['source','plist','inspect','site']); parser.add_argument('--app',type=pathlib.Path); parser.add_argument('--out',type=pathlib.Path); parser.add_argument('--dmg',type=pathlib.Path)
    args=parser.parse_args()
    if args.action=='source': write(args.out,source())
    elif args.action=='plist':
        v=version(ROOT); info={'CFBundleIdentifier':'local.inkpeg.Inkpeg','CFBundleExecutable':'Inkpeg','CFBundleName':'Inkpeg','CFBundleDisplayName':'文夹','CFBundlePackageType':'APPL','CFBundleShortVersionString':v['version'],'CFBundleVersion':v['build'],'LSMinimumSystemVersion':v['minimumMacOS'],'LSUIElement':True,'CFBundleIconFile':'Inkpeg.icns'}
        args.out.write_bytes(plistlib.dumps(info))
    elif args.action=='inspect': write(args.out,inspect(args.app))
    else:
        checked=inspect(args.app)
        if checked['architectures']!=['arm64','x86_64']: raise ValueError('Website release requires actual Universal binary')
        name=f"Inkpeg-{checked['version']}-build{checked['build']}-universal.dmg"; dest=ROOT/'site/downloads'/name
        if dest.exists(): raise ValueError('Release asset already exists; do not overwrite')
        shutil.copyfile(args.dmg,dest)
        data={k:checked[k] for k in ['version','build','minimumMacOS','architectures','developerIDSigned','notarized']}
        data.update(channel='preview',architecture='universal',file=name,sizeBytes=dest.stat().st_size,sha256=sha(dest),source=checked['source'],signing=checked['signing'],intelHardwareVerified=False,minimumMacOSHardwareVerified=False,guiInstallationVerified=False,testRecords=['verification.json'],sourceRecords='build-source.json')
        # Keep the manifest small; full input list travels alongside it and inside the app.
        write(ROOT/'site/downloads/build-source.json',data.pop('source'))
        data['source']={k:checked['source'][k] for k in ['head','dirty','sha256','algorithm','scope']}
        write(ROOT/'site/downloads/release.json',data)
        (ROOT/'site/downloads/SHA256SUMS.txt').write_text(f"{data['sha256']}  {name}\n")
        shutil.copyfile(ROOT/'docs/inkpeg/INSTALL.md',ROOT/'site/downloads/安装教程.md')
        shutil.copyfile(ROOT/'docs/inkpeg/KNOWN-ISSUES.md',ROOT/'site/downloads/本版限制.md')
        print(json.dumps({k:data[k] for k in ['file','sizeBytes','sha256']},indent=2))
if __name__=='__main__': main()
