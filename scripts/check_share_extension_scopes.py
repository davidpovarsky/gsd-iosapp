#!/usr/bin/env python3
"""Execute actual Share sheet writer/publisher/Keychain interpretation with isolated filesystem and doubled HTTP/SecItem read."""
import argparse
import hashlib
import importlib.util
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path
EXPECTED = set([
    "keychain_missing_unavailable_and_token_are_distinct",
    "missing_publication_never_authorizes_account_post",
    "first_share_bootstraps_only_unpushed_stable_guest",
    "unavailable_keychain_cannot_bootstrap_guest",
    "old_sheet_never_posts_with_another_accounts_token",
    "same_owner_token_replacement_invalidates_open_sheet",
    "unresolved_then_same_account_keeps_old_sheet_invalid",
    "post_uses_frozen_token_after_durable_origin_journal",
    "abandoned_post_recovers_once_under_the_same_identity"
])

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def prepare(source, output):
    package = output / "package"
    inputs = {}
    for module in ("GSDModel", "GSDSnapshot"):
        original = source / "GSDKit/Sources" / module
        for path in sorted(original.rglob("*")):
            if path.is_file(): inputs[str(path.relative_to(source))] = digest(path)
        shutil.copytree(original, package / "Sources" / module)
    target = package / "Sources/ShareExtensionScopeProbe"
    target.mkdir(parents=True)
    scoped = (source / "GSDKit/Sources/GSDSnapshot/ShareCaptureSession.swift").exists()
    for relative in ["GSDKit/Sources/GSDWire/SharedTokenKeychain.swift", "GSDKit/Sources/GSDWire/JWT.swift"]:
        path = source / relative
        inputs[relative] = digest(path)
        text = path.read_text()
        if path.name == "SharedTokenKeychain.swift":
            text = text.replace("SecItemCopyMatching(", "fixtureSecItemCopyMatching(")
        (target / path.name).write_text(text)
    if scoped:
        original = source / "App/Sharing/ShareScopePublisher.swift"
        inputs[str(original.relative_to(source))] = digest(original)
        shutil.copyfile(original, target / original.name)
    else:
        helper_path = Path(__file__).with_name("check_share_retry.py")
        spec = importlib.util.spec_from_file_location("share_retry_helper", helper_path)
        helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
        inputs["probe/check_share_retry.py"] = digest(helper_path)
        original = source / "ShareExtension/ShareViewController.swift"
        inputs[str(original.relative_to(source))] = digest(original)
        (target / original.name).write_text(helper.controller_operation(original.read_text()))
    fixture = Path(__file__).with_name("share_extension_scope_probe.swift")
    shutil.copyfile(fixture, target / "Probe.swift")
    inputs["probe/share_extension_scope_probe.swift"] = digest(fixture)
    inputs["probe/check_share_extension_scopes.py"] = digest(Path(__file__))
    settings = ', swiftSettings: [.define("SHARE_SCOPE_PRESENT")]' if scoped else ''
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "GSDShareExtensionScopeProbe", platforms: [.macOS(.v26)],
    targets: [
        .target(name: "GSDModel", resources: [.copy("Resources/whats-new.json")]),
        .target(name: "GSDSnapshot", dependencies: ["GSDModel"]),
        .executableTarget(name: "ShareExtensionScopeProbe", dependencies: ["GSDModel", "GSDSnapshot"]SETTINGS)
    ])
'''.replace("SETTINGS", settings))
    manifest = {"sourceRoot": str(source), "files": inputs, "scopedWriterAvailable": scoped,
        "realImplementations": ["ShareCaptureSession or complete legacy controller save method",
                                "ShareScopePublisher when available", "SharedTokenKeychain snapshot/load",
                                "JWT decode", "SharedCapture/ShareOutboxStore", "real filesystem/atomic publication/lease"],
        "doubles": ["HTTP request recording and suspension", "SecItemCopyMatching status/data only",
                    "legacy UIViewController presentation shell"],
        "personalCredentialsUsed": False, "liveCloudAcceptance": False, "nativeShareSheetAcceptance": False}
    (output / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return package, manifest

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--scratch-path", type=Path)
    ap.add_argument("--prepare-only", action="store_true")
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    source, output = a.source_root.resolve(), a.output.resolve()
    if output.exists(): raise ValueError("Output exists; preserve prior evidence")
    if not a.prepare_only and platform.system() != "Darwin": raise RuntimeError("Apple runner required")
    output.mkdir(parents=True)
    package, manifest = prepare(source, output)
    if a.prepare_only:
        print(json.dumps({"prepared": True, "executed": False, "package": str(package)})); return 0
    scratch = (a.scratch_path or output / "build").resolve()
    result = subprocess.run(["swift", "run", "--package-path", str(package), "--scratch-path", str(scratch),
                             "-j", str(a.jobs), "ShareExtensionScopeProbe"],
                            text=True, capture_output=True, timeout=300)
    (output / "stdout.log").write_text(result.stdout); (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("SHARE_EXTENSION_SCOPE_CHECK ")) for line in result.stdout.splitlines()
              if line.startswith("SHARE_EXTENSION_SCOPE_CHECK ")]
    names = [c["name"] for c in checks]
    changed = [f for f,h in manifest["files"].items() if not f.startswith("probe/") and digest(source/f) != h]
    passed = result.returncode == 0 and set(names) == EXPECTED and len(names) == len(EXPECTED) and all(c["passed"] for c in checks) and not changed
    receipt = {"passed": passed, "returncode": result.returncode, "checks": checks, "expected": sorted(EXPECTED),
               "changedInputs": changed, "personalCredentialsUsed": False, "liveCloudAcceptance": False,
               "nativeShareSheetAcceptance": False, "inputManifestSHA256": digest(output/"input-manifest.json")}
    (output/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps(receipt)); return 0 if passed else 1
if __name__ == "__main__": sys.exit(main())
