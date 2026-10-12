#!/usr/bin/env python3
"""Release contract regressions; no real app/data/security mutations."""
import importlib.util, json, pathlib, tempfile, unittest, sys
sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/release-tools.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
class ReleaseContract(unittest.TestCase):
    def test_single_version(self):
        self.assertEqual(release.version(ROOT), {'version':'2.0.0','build':'5','minimumMacOS':'14.0'})
    def test_dirty_fingerprint_includes_untracked_sources_excludes_metadata_and_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); (root/'Sources/New').mkdir(parents=True)
            source=root/'Sources/New/Untracked.swift'; source.write_text('new source')
            before=release.inputs(root)
            self.assertEqual([i['path'] for i in before], ['Sources/New/Untracked.swift'])
            (root/'Sources/.DS_Store').write_text('metadata')
            (root/'site/downloads').mkdir(parents=True)
            (root/'site/downloads/release.json').write_text('output')
            self.assertEqual(before, release.inputs(root))
            source.write_text('changed source')
            self.assertNotEqual(release.fingerprint(before),release.fingerprint(release.inputs(root)))
    def test_plist_and_binary_minimum_must_match(self):
        metadata = {'CFBundleShortVersionString':'2.0.0','CFBundleVersion':'5','LSMinimumSystemVersion':'14.0','CFBundleIconFile':'Inkpeg.icns'}
        release.check_metadata(metadata, ['14.0','14.0'], release.version(ROOT))
        with self.assertRaises(ValueError): release.check_metadata(metadata,['13.0','14.0'],release.version(ROOT))
        metadata['CFBundleVersion']='1'
        with self.assertRaises(ValueError): release.check_metadata(metadata,['14.0','14.0'],release.version(ROOT))
    def test_new_site_hints_match_direct_card_and_context_menu_actions(self):
        html=(ROOT/'site/index.html').read_text()
        self.assertIn('data-task="copy"',html)
        self.assertIn('单击复制',html)
        self.assertIn('右键',html)
        self.assertNotIn('点卡片选择',html)
        self.assertIn('安装文夹.command',html)
        self.assertNotIn('id="status"',html)
if __name__=='__main__': unittest.main()
