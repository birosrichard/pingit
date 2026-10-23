#!/usr/bin/env python3
"""Check that a cask uses the actual app version and final archive checksum."""
import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('generate_cask', Path(__file__).with_name('generate-cask.py'))
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class CaskTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / 'pingit-0.1.0.zip'
        self.info = {
            'CFBundleShortVersionString': '0.1.0',
            'CFBundleIdentifier': 'dev.biros.pingit',
            'LSMinimumSystemVersion': '14.0',
        }

    def write_archive(self):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('pingit.app/Contents/Info.plist', plistlib.dumps(self.info))

    def test_real_version_checksum_and_download(self):
        self.write_archive()
        output = generator.cask(self.archive)
        self.assertIn('version "0.1.0"', output)
        self.assertIn(f'sha256 "{hashlib.sha256(self.archive.read_bytes()).hexdigest()}"', output)
        self.assertIn('/birosrichard/pingit/releases/download/v#{version}/pingit-#{version}.zip', output)
        self.assertIn('app "pingit.app"', output)

    def test_rejects_mismatched_filename(self):
        self.info['CFBundleShortVersionString'] = '0.2.0'
        self.write_archive()
        with self.assertRaisesRegex(ValueError, 'filename'):
            generator.cask(self.archive)

    def test_rejects_unexpected_app_or_os(self):
        for key, value in [('CFBundleIdentifier', 'other.app'), ('LSMinimumSystemVersion', '15.0')]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.write_archive()
                with self.assertRaises(ValueError):
                    generator.cask(self.archive)
                self.info[key] = original

    def test_rejects_invalid_version(self):
        self.info['CFBundleShortVersionString'] = '0.1.0"; system("bad")'
        self.write_archive()
        with self.assertRaisesRegex(ValueError, 'version'):
            generator.cask(self.archive)


if __name__ == '__main__':
    unittest.main()
