#!/usr/bin/env python3
"""Exercise installer in temporary destinations; do not launch or replace live apps."""
from pathlib import Path
import hashlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='codex-battery-install-test-')
        self.addCleanup(self.folder.cleanup)
        self.destination = Path(self.folder.name) / 'Applications/Codex 电量管家.app'

    def install(self, *extra):
        return subprocess.run([
            '/bin/zsh', str(ROOT / 'install.sh'), '--destination',
            str(self.destination), '--no-open', *extra,
        ], capture_output=True, text=True)

    def fake_app(self, identifier, version):
        info = self.destination / 'Contents/Info.plist'
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier,
            'CFBundleShortVersionString': version,
        }))

    def test_dry_run_has_no_installation(self):
        result = self.install('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination.exists())

    def test_fresh_copy_preserves_executable(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        relative = 'Contents/MacOS/CodexBattery'
        original = ROOT / 'dist/Codex 电量管家.app' / relative
        installed = self.destination / relative
        self.assertEqual(hashlib.sha256(original.read_bytes()).digest(),
                         hashlib.sha256(installed.read_bytes()).digest())
        check = subprocess.run(['/usr/bin/codesign', '--verify', '--strict',
                                str(self.destination)], capture_output=True)
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_unrelated_app_is_preserved(self):
        self.fake_app('example.other-tool', '1.0')
        before = (self.destination / 'Contents/Info.plist').read_bytes()
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.destination / 'Contents/Info.plist').read_bytes(), before)

    def test_other_major_version_is_preserved(self):
        self.fake_app('local.codex-battery', '2.0.0')
        before = (self.destination / 'Contents/Info.plist').read_bytes()
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.destination / 'Contents/Info.plist').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
