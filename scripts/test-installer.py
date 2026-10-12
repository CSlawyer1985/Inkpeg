#!/usr/bin/env python3
"""Exercise the actual installer in isolated folders, never real Applications."""
import hashlib, pathlib, plistlib, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parent.parent
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.root=pathlib.Path(tempfile.mkdtemp(prefix='inkpeg-installer-test-',dir='/tmp'))
        self.package=self.root/'可信安装包';self.package.mkdir()
        self.destination=self.root/'隔离应用程序';self.destination.mkdir()
        self.helper=self.package/'安装文夹.command'
        source=ROOT/'packaging/安装文夹.command'
        self.assertTrue(source.exists(),'The package must include the runnable installation helper')
        shutil.copy2(source,self.helper)
        app=self.package/'Inkpeg.app';(app/'Contents/MacOS').mkdir(parents=True); (app/'Contents/Resources').mkdir()
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.inkpeg.Inkpeg','CFBundleExecutable':'Inkpeg','CFBundleShortVersionString':'2.0.0','CFBundleVersion':'5'}))
        binary=app/'Contents/MacOS/Inkpeg';binary.write_text('#!/bin/sh\nexit 0\n');binary.chmod(0o755)
        self.source=app;self.manifest()
    def manifest(self):
        files=sorted(p for p in self.source.rglob('*') if p.is_file() and p.name!='安装校验.sha256')
        (self.source/'Contents/Resources/安装校验.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(self.package))+'\n' for p in files))
    def run_helper(self,answer='\n',destination=None):
        return subprocess.run(['/bin/bash',str(self.helper),'--destination',str(destination or self.destination),'--no-launch','--confirm'],input=answer,text=True,capture_output=True)
    def test_default_installs_without_extra_confirmation(self):
        r=subprocess.run(['/bin/bash',str(self.helper),'--destination',str(self.destination),'--no-launch'],input='',text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertTrue((self.destination/'Inkpeg.app/Contents/MacOS/Inkpeg').is_file())
    def test_quarantined_helper_runs_via_explicit_local_bash(self):
        subprocess.run(['/usr/bin/xattr','-w','com.apple.quarantine','0083;test;Browser;',str(self.helper)],check=True)
        r=subprocess.run(['/bin/bash',str(self.helper),'--destination',str(self.destination),'--no-launch'],input='',text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertTrue((self.destination/'Inkpeg.app/Contents/MacOS/Inkpeg').is_file())
    def test_empty_internal_manifest_rejected(self):
        (self.source/'Contents/Resources/安装校验.sha256').write_text('')
        r=self.run_helper();self.assertNotEqual(r.returncode,0);self.assertFalse((self.destination/'Inkpeg.app').exists())
    def test_confirm_eof_does_not_install(self):
        r=self.run_helper('');self.assertNotEqual(r.returncode,0);self.assertFalse((self.destination/'Inkpeg.app').exists())
    def test_install_preserves_bytes_and_launchable_mode(self):
        r=self.run_helper();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        target=self.destination/'Inkpeg.app';self.assertEqual((target/'Contents/MacOS/Inkpeg').read_bytes(),(self.source/'Contents/MacOS/Inkpeg').read_bytes());self.assertTrue((target/'Contents/MacOS/Inkpeg').stat().st_mode&0o111)
    def test_cancel_does_not_install(self):
        r=self.run_helper('q\n');self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.assertFalse((self.destination/'Inkpeg.app').exists())
    def test_changed_payload_fails_before_destination_changes(self):
        (self.source/'Contents/MacOS/Inkpeg').write_text('changed')
        r=self.run_helper();self.assertNotEqual(r.returncode,0);self.assertFalse((self.destination/'Inkpeg.app').exists())
    def test_upgrade_retains_original_application(self):
        target=self.destination/'Inkpeg.app';target.mkdir();(target/'old.txt').write_text('existing application')
        r=self.run_helper();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        backups=list(self.destination.glob('Inkpeg-旧版-*.app'));self.assertEqual(len(backups),1);self.assertEqual((backups[0]/'old.txt').read_text(),'existing application');self.assertTrue((target/'Contents/Info.plist').exists())
    def test_destination_symlink_rejected_without_touching_other_directory(self):
        other=self.root/'other';other.mkdir();(self.destination/'Inkpeg.app').symlink_to(other,target_is_directory=True)
        r=self.run_helper();self.assertNotEqual(r.returncode,0);self.assertEqual(list(other.iterdir()),[])
    def test_foreign_bundle_identifier_rejected(self):
        p=self.source/'Contents/Info.plist';info=plistlib.loads(p.read_bytes());info['CFBundleIdentifier']='foreign.app';p.write_bytes(plistlib.dumps(info));self.manifest()
        r=self.run_helper();self.assertNotEqual(r.returncode,0);self.assertFalse((self.destination/'Inkpeg.app').exists())
    def test_quarantine_removed_only_from_installed_copy(self):
        subprocess.run(['/usr/bin/xattr','-w','com.apple.quarantine','0081;test;Inkpeg;',str(self.source)],check=True)
        other=self.destination/'Unrelated.app';other.mkdir();subprocess.run(['/usr/bin/xattr','-w','com.apple.quarantine','0081;test;Other;',str(other)],check=True)
        r=self.run_helper();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertNotEqual(subprocess.run(['/usr/bin/xattr','-p','com.apple.quarantine',str(self.destination/'Inkpeg.app')],capture_output=True).returncode,0)
        self.assertEqual(subprocess.run(['/usr/bin/xattr','-p','com.apple.quarantine',str(other)],capture_output=True).returncode,0)
        self.assertEqual(subprocess.run(['/usr/bin/xattr','-p','com.apple.quarantine',str(self.source)],capture_output=True).returncode,0)
if __name__=='__main__':unittest.main()
