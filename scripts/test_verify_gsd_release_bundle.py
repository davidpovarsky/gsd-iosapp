#!/usr/bin/env python3
"""Regression checks for release gates: incomplete/incorrect artifacts must fail."""
import datetime as dt
from pathlib import Path
import plistlib
import tempfile
import unittest
from gsd_appstore_connect import TEAM, APP_GROUP, validate_profile
from verify_gsd_release_bundle import BUNDLES, audit

class ReleaseArtifactGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "GSD.app"
        for identifier, relative in BUNDLES.items():
            folder = self.app / relative
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleVersion": "48",
                "CFBundleShortVersionString": "4.1.0", "CFBundleLocalizations": ["en", "he"]}))
            (folder / "he.lproj").mkdir()
            (folder / "he.lproj/Localizable.strings").write_bytes(plistlib.dumps({"Hello": "שלום"}))
        (self.app / "he.lproj/AppShortcuts.strings").write_bytes(plistlib.dumps({"Open": "פתיחה"}))

    def test_complete_five_target_artifact_is_accepted(self):
        self.assertEqual(len(audit(self.app, "48", "4.1.0", False)), 5)

    def test_missing_watch_extension_is_rejected(self):
        import shutil
        shutil.rmtree(self.app / BUNDLES["com.itorah.gsd.watchkitapp.widgets"])
        with self.assertRaisesRegex(RuntimeError, "Unexpected embedded targets"):
            audit(self.app, "48", "4.1.0", False)

    def test_missing_embedded_translation_is_rejected(self):
        (self.app / BUNDLES["com.itorah.gsd.share"] / "he.lproj/Localizable.strings").unlink()
        with self.assertRaisesRegex(RuntimeError, "no compiled Hebrew"):
            audit(self.app, "48", "4.1.0", False)

    def test_extension_version_drift_is_rejected(self):
        path = self.app / BUNDLES["com.itorah.gsd.widgets"] / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleVersion"] = "47"
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError, "wrong CFBundleVersion"):
            audit(self.app, "48", "4.1.0", False)

    def test_siri_catalog_missing_is_rejected(self):
        (self.app / "he.lproj/AppShortcuts.strings").unlink()
        with self.assertRaisesRegex(RuntimeError, "App Shortcuts Hebrew"):
            audit(self.app, "48", "4.1.0", False)

class ProvisioningGateTests(unittest.TestCase):
    def profile(self):
        return {"TeamIdentifier": [TEAM], "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=3),
                "Entitlements": {"application-identifier": TEAM + ".com.itorah.gsd",
                                 "get-task-allow": False, "com.apple.security.application-groups": [APP_GROUP]}}

    def test_valid_store_profile_is_accepted(self):
        validate_profile(self.profile(), "com.itorah.gsd")

    def test_wrong_team_is_rejected(self):
        profile = self.profile()
        profile["TeamIdentifier"] = ["52HVJ3VDSM"]
        with self.assertRaises(ValueError):
            validate_profile(profile, "com.itorah.gsd")

    def test_group_not_associated_is_rejected(self):
        profile = self.profile()
        profile["Entitlements"]["com.apple.security.application-groups"] = []
        with self.assertRaises(ValueError):
            validate_profile(profile, "com.itorah.gsd")

    def test_development_profile_is_rejected(self):
        profile = self.profile()
        profile["Entitlements"]["get-task-allow"] = True
        with self.assertRaises(ValueError):
            validate_profile(profile, "com.itorah.gsd")

    def test_adhoc_profile_is_rejected(self):
        profile = self.profile()
        profile["ProvisionedDevices"] = ["test-device"]
        with self.assertRaises(ValueError):
            validate_profile(profile, "com.itorah.gsd")

if __name__ == "__main__":
    unittest.main()
