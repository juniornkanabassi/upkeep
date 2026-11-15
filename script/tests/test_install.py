"""install.sh refuses bundles that are not Upkeep builds before it changes anything."""
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

INSTALL = Path(__file__).resolve().parents[2] / "install.sh"


class InstallLayoutTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.target = self.root / "Apps"
        self.target.mkdir()

    def bundle(self, executable, cli):
        app = self.root / "Build" / "Some.app" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "Helpers").mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleIdentifier": "com.juniornkanabassi.Updater"}))
        for path in (app / "MacOS" / executable, app / "Helpers" / cli):
            path.write_text("#!/bin/sh\n")
            path.chmod(0o755)
        return app.parent

    def install(self, app):
        environment = {"PATH": "/usr/bin:/bin", "UPDATER_INSTALL_ROOT": str(self.target),
                       "HOME": str(self.root)}
        return subprocess.run(["/bin/zsh", str(INSTALL), str(app)], env=environment,
                              capture_output=True, text=True, timeout=30)

    def test_pre_rename_build_is_refused_and_nothing_changes(self):
        result = self.install(self.bundle("Updater", "updater"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not an Upkeep build", result.stderr)
        self.assertIn("Nothing was changed", result.stderr)
        self.assertEqual(list(self.target.iterdir()), [])

    def test_upkeep_layout_passes_the_layout_check(self):
        # The fixture is unsigned, so it stops at the signature check, still before any change.
        result = self.install(self.bundle("Upkeep", "upkeep"))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("not an Upkeep build", result.stderr)
        self.assertIn("not signed", result.stderr)
        self.assertEqual(list(self.target.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
