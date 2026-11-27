#!/usr/bin/env python3
"""Stage exact app credential source for a focused native fixture; never read real Keychain data."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--source-root", type=Path, required=True)
parser.add_argument("--package-root", type=Path, required=True)
args = parser.parse_args()
source = args.source_root.resolve(strict=True)
destination = args.package_root.absolute()
if destination.exists():
    raise SystemExit("Refusing to replace an existing acceptance workspace")
destination.mkdir(parents=True)
inputs = {
    "App/ChatGPT/GSDHanlinProviderCredential.swift":
        "Sources/ProviderCredentialFixture/GSDHanlinProviderCredential.swift",
    "Packages/GSDHanlinAgent/Acceptance/ProviderCredential/ProviderCredentialTests.swift":
        "Tests/ProviderCredentialFixtureTests/ProviderCredentialTests.swift",
}
manifest = {}
for relative, output in inputs.items():
    path = source / relative
    data = path.read_bytes()
    target = destination / output
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    manifest[relative] = hashlib.sha256(data).hexdigest()
package = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ProviderCredentialFixture",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ProviderCredentialFixture"),
        .testTarget(name: "ProviderCredentialFixtureTests", dependencies: ["ProviderCredentialFixture"])
    ],
    swiftLanguageModes: [.v6]
)
"""
(destination / "Package.swift").write_text(package)
(destination / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps({"package": str(destination), "inputs": manifest}))
