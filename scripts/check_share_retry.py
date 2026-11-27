#!/usr/bin/env python3
"""Fault-test the Share controller's actual save operation with a doubled network.

The complete saveAndPush method and its per-sheet state are copied from source.
UIKit presentation is omitted; DirectTaskPush is a recording network double.
The real GSDSnapshot outbox, capture builder, and inbox drain are compiled unchanged.
This proves local retry behavior, not live-cloud or native Share sheet acceptance.
"""
import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = {
    "write_failure_is_reported_after_push",
    "retry_does_not_repeat_remote_create",
    "retry_preserves_identity_and_edits_on_drain",
    "first_success_uses_pushed_ingest",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def controller_operation(text):
    # The method boundary is structural scaffolding only. Its complete body runs in Swift;
    # no assertion is satisfied by finding a source substring.
    marker = "    private func saveAndPush(_ capture: SharedCapture) async throws {"
    if text.count(marker) != 1:
        raise ValueError("Expected the controller's single saveAndPush operation")
    start = text.index(marker)
    end = text.index("\n    override func viewDidLoad()", start)
    method = text[start:end].rstrip().replace("private func saveAndPush", "func saveAndPush", 1)
    state = "\n".join(re.findall(
        r"^    private (?:let captureTaskID|var didAttemptPush) = .+$", text, re.MULTILINE))
    return f'''import Foundation
import GSDModel
import GSDSnapshot
@MainActor final class ShareViewController {{
    private let outbox: ShareOutboxStore
    private let push: DirectTaskPush
{state}
    init(outbox: ShareOutboxStore, push: DirectTaskPush) {{
        self.outbox = outbox
        self.push = push
    }}
{method}
}}
'''


def scoped_controller_operation(text):
    # Keep the production delegation method. Only UIKit ownership and the verified
    # synthetic account prerequisite are fixture setup; the actual per-sheet writer runs.
    marker = "    private func saveAndPush(_ capture: SharedCapture) async throws -> ShareCaptureSession.SaveResult {"
    if text.count(marker) != 1:
        raise ValueError("Expected the single scoped Share delegation method")
    start = text.index(marker)
    end = text.index("\n    override func viewDidLoad()", start)
    method = text[start:end].rstrip().replace("private func saveAndPush", "func saveAndPush", 1)
    return '''import Foundation
import GSDModel
import GSDSnapshot
@MainActor final class ShareViewController {
    private let captureSession: ShareCaptureSession
    init(outbox: ShareOutboxStore, push: DirectTaskPush) {
        let directory = outbox._gsdAcceptanceContainer
        let identity = try! SharedDatasetIdentityStore(directory: directory).loadOrCreate()
        let publication = ShareScopePublicationStore(directory: directory)
        try! publication.publish(ShareScopePublication(
            scope: .account(userID: "share-retry-fixture", datasetID: identity.datasetID)))
        captureSession = ShareCaptureSession(outbox: outbox, directory: directory,
            credential: { .account(token: "fixture-token", ownerID: "share-retry-fixture") },
            push: { task, _ in
                if case .pushed(let id) = await push.attempt(task) { return id }
                return nil
            })
    }
''' + method + "\n}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    source, output = args.source_root.resolve(), args.output.resolve()
    if output.exists():
        raise ValueError("Output exists; preserve evidence and choose another output path")
    if not args.prepare_only and platform.system() != "Darwin":
        raise RuntimeError("Execute Swift only on the owned Apple runner")
    output.mkdir(parents=True)
    package = output / "package"
    inputs = {}
    for module in ("GSDModel", "GSDSnapshot"):
        original = source / "GSDKit/Sources" / module
        for path in sorted(original.rglob("*")):
            if path.is_file():
                inputs[str(path.relative_to(source))] = digest(path)
        shutil.copytree(original, package / "Sources" / module)
    target = package / "Sources/ShareRetryProbe"
    target.mkdir(parents=True)
    original = source / "ShareExtension/ShareViewController.swift"
    inputs[str(original.relative_to(source))] = digest(original)
    scoped = (source / "GSDKit/Sources/GSDSnapshot/ShareCaptureSession.swift").exists()
    operation = scoped_controller_operation(original.read_text()) if scoped else controller_operation(original.read_text())
    (target / "ShareViewController.swift").write_text(operation)
    if scoped:
        # Read-only same-file fixture access; no production storage/path behavior changes.
        copied_outbox = package / "Sources/GSDSnapshot/ShareOutboxStore.swift"
        with copied_outbox.open("a") as f:
            f.write("\nextension ShareOutboxStore {\n"
                    "    public var _gsdAcceptanceContainer: URL? { directoryURL?.deletingLastPathComponent() }\n"
                    "}\n")
    fixture = Path(__file__).with_name("share_retry_probe.swift")
    inputs["probe/share_retry_probe.swift"] = digest(fixture)
    inputs["probe/check_share_retry.py"] = digest(Path(__file__))
    shutil.copyfile(fixture, target / "Probe.swift")
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "GSDShareRetryProbe", platforms: [.macOS(.v26)],
    targets: [
        .target(name: "GSDModel", resources: [.copy("Resources/whats-new.json")]),
        .target(name: "GSDSnapshot", dependencies: ["GSDModel"]),
        .executableTarget(name: "ShareRetryProbe", dependencies: ["GSDModel", "GSDSnapshot"]),
    ]
)
''')
    manifest = {
        "sourceRoot": str(source), "files": inputs,
        "productionOperation": "ShareViewController.saveAndPush and actual ShareCaptureSession when present",
        "verifiedAccountFixturePrerequisite": scoped,
        "unchangedOriginalAssertionFixture": True,
        "accountIsolationAcceptance": False,
        "doubles": ["DirectTaskPush", "UIViewController presentation shell"],
        "liveCloudAcceptance": False, "nativeShareAcceptance": False,
    }
    (output / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if args.prepare_only:
        print(json.dumps({"prepared": True, "executed": False, "package": str(package)}))
        return 0
    result = subprocess.run(["swift", "run", "--package-path", str(package),
                             "--scratch-path", str(output / "build"), "-j", str(args.jobs),
                             "ShareRetryProbe"], text=True, capture_output=True, timeout=240)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("SHARE_RETRY_CHECK "))
              for line in result.stdout.splitlines() if line.startswith("SHARE_RETRY_CHECK ")]
    passed = (result.returncode == 0 and {c["name"] for c in checks} == EXPECTED
              and len(checks) == len(EXPECTED) and all(c["passed"] for c in checks))
    receipt = {"passed": passed, "returncode": result.returncode, "checks": checks,
               "expected": sorted(EXPECTED), "liveCloudAcceptance": False,
               "nativeShareAcceptance": False,
               "inputManifestSHA256": digest(output / "input-manifest.json")}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
