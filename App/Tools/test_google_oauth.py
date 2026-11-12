"""Synthetic-only tests. Never use the developer's actual local configuration."""
import contextlib
import io
import os
import pathlib
import plistlib
import stat
import tempfile
import unittest
from unittest import mock

import google_oauth as oauth


class LocalGoogleOAuthTests(unittest.TestCase):
    def setUp(self):
        # Keep even the synthetic fixtures on the project's selected storage.
        build = oauth.ROOT / ".build"
        build.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=build, prefix="oauth-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / "App/Config").mkdir(parents=True)
        self.source = self.root / "App/Config/Info.plist"
        self.info = {oauth.CLIENT_ID: "synthetic-desktop-client", "CFBundleIconFile": "current-icon", "Other": "preserve"}
        with self.source.open("wb") as stream:
            plistlib.dump(self.info, stream)
        self.value = "synthetic-only+&=%/value"
        self.fields = {oauth.CLIENT_ID: self.info[oauth.CLIENT_ID], oauth.CLIENT_SECRET: self.value}
        guard = mock.patch.object(oauth, "require_ignored_config")
        guard.start()
        self.addCleanup(guard.stop)

    def test_local_file_is_private_and_roundtrips(self):
        path = self.root / oauth.CONFIG
        oauth.write_private(path, self.fields)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(oauth.read_private(path), self.fields)
        path.chmod(0o644)
        with self.assertRaises(oauth.ConfigurationError):
            oauth.read_private(path)

    def test_symlinks_are_rejected_without_touching_target(self):
        path = self.root / oauth.CONFIG
        path.symlink_to(self.source)
        with self.assertRaises(oauth.ConfigurationError):
            oauth.write_private(path, self.fields)
        with self.assertRaises(OSError):
            oauth.read_private(path)
        self.assertEqual(plistlib.loads(self.source.read_bytes()), self.info)

    def test_build_merges_current_icon_and_passes_only_a_private_path(self):
        oauth.write_private(self.root / oauth.CONFIG, self.fields)
        original = self.source.read_bytes()
        seen = []
        def runner(command, **kwargs):
            self.assertNotIn(self.value, str(command))
            self.assertEqual(kwargs, {"cwd": self.root, "check": False})
            path = pathlib.Path(next(value.split("=", 1)[1] for value in command if value.startswith("INFOPLIST_FILE=")))
            seen.append(path)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            info = plistlib.loads(path.read_bytes())
            self.assertEqual(info, {**self.info, oauth.CLIENT_SECRET: self.value})
            return mock.Mock(returncode=0)
        self.assertEqual(oauth.build(self.root, "SYNTHETIC_TEAM", runner=runner), 0)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(len(seen), 1)
        self.assertFalse(seen[0].exists())

    def test_mismatched_client_does_not_build(self):
        oauth.write_private(self.root / oauth.CONFIG, {**self.fields, oauth.CLIENT_ID: "other-client"})
        runner = mock.Mock()
        with self.assertRaises(oauth.ConfigurationError):
            oauth.build(self.root, "SYNTHETIC_TEAM", runner=runner)
        runner.assert_not_called()

    def test_configure_never_echoes_input_and_requires_terminal(self):
        output = io.StringIO()
        with mock.patch("sys.stdin.isatty", return_value=True), mock.patch("getpass.getpass", return_value=self.value), contextlib.redirect_stdout(output):
            oauth.configure(self.root)
        self.assertNotIn(self.value, output.getvalue())
        with mock.patch("sys.stdin.isatty", return_value=False), self.assertRaises(oauth.ConfigurationError):
            oauth.configure(self.root)

    def test_empty_and_placeholders_are_not_configuration(self):
        for value in [None, "", " ", "REPLACE_SECRET", "$(GOOGLE_SECRET)", 1]:
            self.assertFalse(oauth.configured(value))


if __name__ == "__main__":
    unittest.main()
