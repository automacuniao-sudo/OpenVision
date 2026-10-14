import copy
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MetaDeveloperConfigTests(unittest.TestCase):
    def setUp(self):
        self.plist = {
            'MWDAT': {'MetaAppID': '', 'ClientToken': '', 'TeamID': '',
                      'AppLinkURLScheme': 'jarvis://'},
            'CFBundleURLTypes': [{'CFBundleURLSchemes': ['jarvis']}],
        }

    def validate(self, value):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'Info.plist'
            path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
            return subprocess.run([sys.executable, str(ROOT / 'scripts/validate_meta_developer_config.py'), str(path)], capture_output=True, text=True)

    def test_ci_build_settings_have_no_attestation_credentials(self):
        path = ROOT / 'Config.developer.xcconfig'
        self.assertTrue(path.exists(), 'CI needs an explicit developer configuration instead of fake credentials')
        settings = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line and not line.startswith('//'))
        settings = {key.strip(): value.strip() for key, value in settings.items()}
        for key in ('META_APP_ID', 'CLIENT_TOKEN', 'DEVELOPMENT_TEAM'):
            self.assertEqual(settings[key], '')
        self.assertEqual(settings['APP_LINK_URL_SCHEME'], 'jarvis')

    def test_source_plist_resolves_with_ci_developer_settings(self):
        settings = {}
        for line in (ROOT / 'Config.developer.xcconfig').read_text().splitlines():
            if '=' in line and not line.startswith('//'):
                key, value = line.split('=', 1)
                settings[key.strip()] = value.strip()
        source = (ROOT / 'JARVIS/Resources/Info.plist').read_text()
        for key, value in settings.items():
            source = source.replace('$(' + key + ')', value)
        result = self.validate(plistlib.loads(source.encode()))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_resolved_developer_plist(self):
        self.assertEqual(self.validate(self.plist).returncode, 0)

    def test_rejects_build43_partial_attestation(self):
        self.plist['MWDAT'].update(MetaAppID='0000000000', ClientToken='AR|0000000000|YOUR_CLIENT_TOKEN')
        result = self.validate(self.plist)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MetaAppID', result.stderr)
        self.assertNotIn('AR|', result.stderr, 'diagnostics must not echo credentials')

    def test_rejects_unexpanded_or_nonempty_credentials(self):
        for key in ('MetaAppID', 'ClientToken', 'TeamID'):
            for value in ('$(UNRESOLVED)', 'YOUR_EXAMPLE', 'some-real-value'):
                with self.subTest(key=key, value=value):
                    plist = copy.deepcopy(self.plist)
                    plist['MWDAT'][key] = value
                    self.assertNotEqual(self.validate(plist).returncode, 0)

    def test_rejects_missing_credentials_or_dictionary(self):
        for key in ('MetaAppID', 'ClientToken', 'TeamID', 'AppLinkURLScheme'):
            plist = copy.deepcopy(self.plist)
            del plist['MWDAT'][key]
            self.assertNotEqual(self.validate(plist).returncode, 0)
        self.assertNotEqual(self.validate({}).returncode, 0)

    def test_rejects_mismatched_missing_or_unexpanded_callback(self):
        for callback in ('', 'other://', '$(APP_LINK_URL_SCHEME)://', 'jarvis', 'jarvis://path'):
            with self.subTest(callback=callback):
                self.plist['MWDAT']['AppLinkURLScheme'] = callback
                self.assertNotEqual(self.validate(self.plist).returncode, 0)
        self.plist['MWDAT']['AppLinkURLScheme'] = 'jarvis://'
        del self.plist['CFBundleURLTypes']
        self.assertNotEqual(self.validate(self.plist).returncode, 0)


if __name__ == '__main__':
    unittest.main()
