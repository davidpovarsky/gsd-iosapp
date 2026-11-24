#!/usr/bin/env python3
"""Audit compiled GSD targets and, for release, every embedded signature/profile."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

from gsd_appstore_connect import TEAM, APP_GROUP, validate_profile

BUNDLES = {
    "com.itorah.gsd": ".",
    "com.itorah.gsd.widgets": "PlugIns/GSDWidgets.appex",
    "com.itorah.gsd.share": "PlugIns/GSDShareExtension.appex",
    "com.itorah.gsd.watchkitapp": "Watch/GSDWatch.app",
    "com.itorah.gsd.watchkitapp.widgets": "Watch/GSDWatch.app/PlugIns/GSDWatchWidgets.appex",
}

def plist(path: Path) -> dict:
    return plistlib.loads(path.read_bytes())

def command(args: list[str]) -> bytes:
    result = subprocess.run(args, capture_output=True, timeout=45)
    if result.returncode:
        raise RuntimeError("Verification failed: " + " ".join(args[:3]))
    return result.stdout

def audit(app: Path, build: str, version: str, signed: bool) -> list[dict]:
    found = {}
    for path in [app, *app.rglob("*.appex"), *app.rglob("*.app")]:
        if (path / "Info.plist").exists():
            info = plist(path / "Info.plist")
            identifier = info.get("CFBundleIdentifier", "")
            if identifier in found:
                raise RuntimeError("Duplicate embedded bundle: " + identifier)
            found[identifier] = path
    if set(found) != set(BUNDLES):
        raise RuntimeError("Unexpected embedded targets: " + str(sorted(set(found) ^ set(BUNDLES))))
    receipts = []
    for identifier, path in found.items():
        info = plist(path / "Info.plist")
        for key, expected in (("CFBundleVersion", build), ("CFBundleShortVersionString", version)):
            if str(info.get(key)) != expected:
                raise RuntimeError(identifier + " has wrong " + key)
        if not {"en", "he"}.issubset(set(info.get("CFBundleLocalizations", []))):
            raise RuntimeError(identifier + " does not declare English and Hebrew")
        he = path / "he.lproj/Localizable.strings"
        if not he.exists() or not plist(he):
            raise RuntimeError(identifier + " has no compiled Hebrew strings")
        if identifier == "com.itorah.gsd" and not (path / "he.lproj/AppShortcuts.strings").exists():
            raise RuntimeError("App Shortcuts Hebrew catalog was not compiled into main app")
        receipt = {"bundleId": identifier, "version": version, "build": build,
                   "relativePath": str(path.relative_to(app)), "hebrewStringCount": len(plist(he)),
                   "localizations": info["CFBundleLocalizations"], "signatureVerified": False}
        if signed:
            command(["codesign", "--verify", "--strict", "--verbose=2", str(path)])
            raw = command(["codesign", "-d", "--entitlements", ":-", str(path)])
            ent = plistlib.loads(raw)
            if ent.get("application-identifier") != TEAM + "." + identifier:
                raise RuntimeError("Wrong signed app identifier: " + identifier)
            if ent.get("com.apple.developer.team-identifier") != TEAM:
                raise RuntimeError("Wrong signed team: " + identifier)
            if ent.get("get-task-allow", False) is not False:
                raise RuntimeError("Debug signing on release: " + identifier)
            if ent.get("com.apple.security.application-groups") != [APP_GROUP]:
                raise RuntimeError("Wrong signed App Group: " + identifier)
            profile_path = path / "embedded.mobileprovision"
            if not profile_path.exists():
                raise RuntimeError("Release bundle has no provisioning profile: " + identifier)
            profile = plistlib.loads(command(["security", "cms", "-D", "-i", str(profile_path)]))
            validate_profile(profile, identifier)
            details = subprocess.run(["codesign", "-dvvv", str(path)], capture_output=True,
                                     text=True, timeout=30)
            if details.returncode or "Authority=Apple Distribution:" not in details.stderr:
                raise RuntimeError("Not signed by Apple Distribution: " + identifier)
            if "TeamIdentifier=" + TEAM not in details.stderr:
                raise RuntimeError("Signature team mismatch: " + identifier)
            receipt.update(signatureVerified=True, profileUUID=profile["UUID"], teamId=TEAM)
        receipts.append(receipt)
    if signed:
        command(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    return receipts

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    location = parser.add_mutually_exclusive_group(required=True)
    location.add_argument("--app", type=Path)
    location.add_argument("--ipa", type=Path)
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--build", default="48")
    parser.add_argument("--version", default="4.1.0")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.ipa:
        with tempfile.TemporaryDirectory(prefix="gsd-ipa-audit-") as temporary:
            root = Path(temporary)
            with zipfile.ZipFile(args.ipa) as archive:
                for name in archive.namelist():
                    if not (root / name).resolve().is_relative_to(root.resolve()):
                        raise RuntimeError("Unsafe IPA archive member")
            command(["ditto", "-x", "-k", str(args.ipa), str(root)])
            apps = list((root / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise RuntimeError("IPA must have exactly one main application")
            result = audit(apps[0], args.build, args.version, args.signed)
    else:
        result = audit(args.app, args.build, args.version, args.signed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"passed": True, "signed": args.signed, "targets": result},
                                      indent=2) + "\n", encoding="utf-8")
    print("GSD_BUNDLE_AUDIT_PASS", len(result), "signed=" + str(args.signed))

if __name__ == "__main__":
    main()
