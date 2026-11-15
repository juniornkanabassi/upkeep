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
            {"CFBundleIdentifier": "com.juniornkanabassi.Upkeep"}))
        for path in (app / "MacOS" / executable, app / "Helpers" / cli):
            path.write_text("#!/bin/sh\n")
            path.chmod(0o755)
        return app.parent

    def install(self, app):
        environment = {"PATH": "/usr/bin:/bin", "UPKEEP_INSTALL_ROOT": str(self.target),
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

    def test_legacy_cleanup_is_guarded_and_uses_only_exact_paths(self):
        script = INSTALL.read_text()
        cleanup = script.index('do shell script')
        self.assertLess(script.index('if [[ -z "${UPKEEP_INSTALL_ROOT:-}" ]]'), cleanup)
        self.assertLess(script.index('Pending Updater transactions remain'), cleanup)
        self.assertLess(script.index('/usr/bin/pgrep -x installer'), cleanup)
        self.assertIn('/Library/PrivilegedHelperTools/com.juniornkanabassi.Updater.helper', script)
        self.assertIn('/Library/LaunchDaemons/com.juniornkanabassi.Updater.helper.plist', script)
        self.assertIn('with administrator privileges', script)
        self.assertNotIn('backgroundtaskmanagement', script)

    def test_staged_signature_is_verified_before_admin_step(self):
        script = INSTALL.read_text()
        self.assertLess(script.index('verify_signed "$STAGE"'), script.index('do shell script'))
        self.assertIn('Legacy helper removal was cancelled or failed', script)
        self.assertIn('-type f -name \'*.json\' -print -quit', script)

    def test_old_helper_runtime_paths_are_removed(self):
        root = INSTALL.parent
        helper = (root / "Upkeep/Platform/InstallHelper/UpdateInstallHelper.swift").read_text()
        for obsolete in ("retireOldIdentity", "oldIdentity", "oldActive", "legacyService", "InstallHelper.registration"):
            self.assertNotIn(obsolete, helper)
        project = (root / "Upkeep.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("com.juniornkanabassi.Updater.helper", project)
        self.assertNotIn("com.juniornkanabassi.Upkeep.helper.plist", project)

    def test_logs_use_migration_aware_root_and_conflict_is_reported(self):
        root = INSTALL.parent
        tool = (root / "Upkeep/Platform/Vendors/ToolProcess.swift").read_text()
        brew = (root / "Upkeep/Platform/Homebrew/Homebrew.swift").read_text()
        self.assertIn('ControlPaths.dataRoot.appendingPathComponent("logs")', tool)
        self.assertIn('logDirectory: URL = ToolProcess.defaultLogDirectory', brew)
        main = (root / "Upkeep/App/main.swift").read_text()
        self.assertIn('UpkeepIdentityMigration.holdUpdates(after: error)', main)


if __name__ == "__main__":
    unittest.main()
