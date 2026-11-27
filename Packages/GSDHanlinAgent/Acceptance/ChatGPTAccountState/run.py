#!/usr/bin/env python3
"""Execute actual GSD ChatGPT account lifecycle against isolated storage/network fixtures.

Only the browser/loopback authorization presenter is replaced. The app account state,
Keychain data model, localization mapping and original HanlinChatCore client are compiled.
No live Keychain operation, OAuth account, revocation or network traffic is permitted.
"""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = {
    "logout_survives_revoke_and_keychain_failure",
    "signout_fence_precedes_remote_requests",
    "fence_contains_only_hashed_registration",
    "reopening_recovers_initial_keychain_failure",
    "storage_retry_preserves_signout_fence",
    "signout_isolated_to_registration",
    "both_storage_failures_report_failure_without_remote_work",
    "corrupt_fence_fails_closed",
    "repeated_logout_can_finish_keychain_cleanup",
    "verified_signin_clears_only_current_fence",
    "failed_signin_save_preserves_fence",
    "refresh_after_signout_cannot_restore_credentials",
    "same_registration_reauth_discards_old_model_catalog",
    "same_registration_reauth_invalidates_pending_inference",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    source, sdk, output = args.source_root.resolve(), args.sdk_root.resolve(), args.output.resolve()
    if output.exists():
        raise ValueError("Output exists; preserve prior evidence and choose a new directory")
    if not args.prepare_only and platform.system() != "Darwin":
        raise RuntimeError("Execute this acceptance harness only on the owned Apple runner")
    output.mkdir(parents=True)
    package = output / "package"
    target = package / "Sources/ChatGPTAccountAcceptance"
    target.mkdir(parents=True)
    inputs = {}
    for name in ("GSDChatGPTAccountState.swift", "GSDChatGPTKeychain.swift", "GSDChatGPTCopy.swift",
                 "GSDChatGPTLocalSignOutStore.swift"):
        original = source / "App/ChatGPT" / name
        inputs[str(original.relative_to(source))] = digest(original)
        shutil.copyfile(original, target / name)
    for name in ("AuthorizationFixture.swift", "AccountStateProbe.swift"):
        original = Path(__file__).with_name(name)
        inputs["fixture/" + name] = digest(original)
        shutil.copyfile(original, target / name)
    inputs["fixture/run.py"] = digest(Path(__file__))
    sdk_inputs = {}
    for original in sorted(sdk.rglob("*")):
        if any(part in {".build", ".git"} for part in original.relative_to(sdk).parts):
            continue
        if original.is_file() and (original.suffix == ".swift" or original.name == "Package.resolved"):
            sdk_inputs[str(original.relative_to(sdk))] = digest(original)
    if not sdk_inputs.get("Package.swift"):
        raise ValueError("Use the installed original SDK package with a root Package.swift")
    sdk_literal = json.dumps(str(sdk))
    (package / "Package.swift").write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "GSDChatGPTAccountAcceptance", platforms: [.macOS(.v26)],
    dependencies: [.package(name: "HanlinSDK", path: {sdk_literal})],
    targets: [.executableTarget(name: "ChatGPTAccountAcceptance", dependencies: [
        .product(name: "HanlinChatCore", package: "HanlinSDK")
    ])], swiftLanguageModes: [.v6]
)
''')
    manifest = {
        "sourceRoot": str(source), "sdkRoot": str(sdk), "files": inputs, "sdkFiles": sdk_inputs,
        "presenterDouble": "GSDChatGPTAuthorization browser/loopback only",
        "storage": "Injected snapshot closures; real temporary atomic sign-out fence",
        "network": "URLProtocol intercepts every SDK URLSession request; all identities and tokens are fixtures",
        "personalChatGPTAcceptance": False, "nativeFrameworkCompilation": False,
    }
    (output / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if args.prepare_only:
        print(json.dumps({"prepared": True, "executed": False, "package": str(package)}))
        return 0
    scratch = args.scratch_path.resolve() if args.scratch_path else output / "build"
    command = ["swift", "run", "--package-path", str(package), "--scratch-path", str(scratch),
               "-j", str(args.jobs), "ChatGPTAccountAcceptance"]
    result = subprocess.run(command, text=True, capture_output=True, timeout=900)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("CHATGPT_ACCOUNT_CHECK "))
              for line in result.stdout.splitlines() if line.startswith("CHATGPT_ACCOUNT_CHECK ")]
    passed = (result.returncode == 0 and {c["name"] for c in checks} == EXPECTED
              and len(checks) == len(EXPECTED) and all(c["passed"] for c in checks))
    receipt = {"passed": passed, "returncode": result.returncode, "checks": checks,
               "expected": sorted(EXPECTED), "personalChatGPTAcceptance": False,
               "nativeFrameworkCompilation": False,
               "inputManifestSHA256": digest(output / "input-manifest.json")}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
