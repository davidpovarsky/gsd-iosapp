#!/usr/bin/env python3
"""Exercise the actual Share generation client/session/journal with an injected HTTP executor."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = {
    "generation_get_and_create_use_same_base_bearer_and_payload",
    "failed_generation_discovery_holds_capture_without_post",
    "generation_conflict_never_retries_headerless",
    "late_generation_after_scope_invalidation_cannot_post",
    "late_generation_after_cancellation_cannot_post",
    "bound_generation_is_durable_before_first_post",
    "edited_retry_retains_bound_generation_without_refetch_or_repost",
    "crash_journal_recovery_preserves_original_generation_and_identity",
    "failed_generation_journal_write_prevents_post",
    "bound_attempt_never_refreshes_generation_after_server_reset",
    "invalid_server_generations_never_reach_create",
}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(source, output):
    package = output / "package"
    inputs = {}
    for module in ("GSDModel", "GSDWire", "GSDSnapshot"):
        original = source / "GSDKit/Sources" / module
        for path in sorted(original.rglob("*")):
            if path.is_file():
                inputs[str(path.relative_to(source))] = digest(path)
        shutil.copytree(original, package / "Sources" / module)
    fixture = Path(__file__).with_name("share_dataset_generation_probe.swift")
    target = package / "Sources/ShareDatasetGenerationProbe"
    target.mkdir(parents=True)
    shutil.copyfile(fixture, target / "Probe.swift")
    inputs["probe/check_share_dataset_generation.py"] = digest(Path(__file__))
    inputs["probe/share_dataset_generation_probe.swift"] = digest(fixture)
    session = (source / "GSDKit/Sources/GSDSnapshot/ShareCaptureSession.swift").read_text()
    direct = (source / "GSDKit/Sources/GSDWire/DirectTaskPush.swift").read_text()
    guarded = "public struct PushAuthorization" in session
    if guarded != ("beforeCreate:" in direct):
        raise ValueError("Mixed Share/client generation API; freeze a complete source candidate")
    settings = ', swiftSettings: [.define("SHARE_DATASET_GENERATION")]' if guarded else ''
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "GSDShareDatasetGenerationProbe", platforms: [.macOS(.v26)],
    targets: [
        .target(name: "GSDModel", resources: [.copy("Resources/whats-new.json")]),
        .target(name: "GSDWire", dependencies: ["GSDModel"]),
        .target(name: "GSDSnapshot", dependencies: ["GSDModel"]),
        .executableTarget(name: "ShareDatasetGenerationProbe",
            dependencies: ["GSDModel", "GSDWire", "GSDSnapshot"]SETTINGS)
    ])
'''
    (package / "Package.swift").write_text(manifest.replace("SETTINGS", settings))
    receipt = {
        "sourceRoot": str(source), "files": inputs,
        "realImplementations": ["PocketBaseClient", "DirectTaskPush", "ShareCaptureSession",
                                "SharedCapture codec", "ShareOutboxStore", "SharedMutationLease"],
        "double": "RequestExecuting actor; records actual URLRequests and holds a real awaited GET",
        "fixtureAdaptation": "Compile-time old/new call signatures only; all eleven assertions identical",
        "datasetGenerationAPIAvailable": guarded,
        "networkRequests": False, "personalCredentialsUsed": False,
        "nativeShareSheetAcceptance": False, "serverTransactionAcceptance": False,
        "actualTaskStoreAcceptance": False,
    }
    (output / "input-manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return package, receipt

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    source, output = args.source_root.resolve(), args.output.resolve()
    if output.exists():
        raise ValueError("Output exists; preserve prior evidence")
    if not args.prepare_only and platform.system() != "Darwin":
        raise RuntimeError("Execute Swift only on the owned Apple runner")
    output.mkdir(parents=True)
    package, manifest = prepare(source, output)
    if args.prepare_only:
        print(json.dumps({"prepared": True, "executed": False, "package": str(package)}))
        return 0
    scratch = (args.scratch_path or output / "build").resolve()
    result = subprocess.run(["swift", "run", "--package-path", str(package),
                             "--scratch-path", str(scratch), "-j", str(args.jobs),
                             "ShareDatasetGenerationProbe"],
                            capture_output=True, text=True, timeout=300)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("SHARE_DATASET_CHECK "))
              for line in result.stdout.splitlines() if line.startswith("SHARE_DATASET_CHECK ")]
    names = [check["name"] for check in checks]
    changed = [path for path, sha in manifest["files"].items()
               if not path.startswith("probe/") and digest(source / path) != sha]
    passed = (result.returncode == 0 and len(names) == len(EXPECTED) and set(names) == EXPECTED
              and all(check["passed"] for check in checks) and not changed)
    receipt = {
        "passed": passed, "returncode": result.returncode, "checks": checks,
        "expected": sorted(EXPECTED), "changedInputs": changed,
        "actualShareGenerationClientAcceptance": passed,
        "nativeShareSheetAcceptance": False, "serverTransactionAcceptance": False,
        "actualTaskStoreAcceptance": False, "personalCredentialsUsed": False,
        "inputManifestSHA256": digest(output / "input-manifest.json"),
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
