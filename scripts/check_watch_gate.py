#!/usr/bin/env python3
"""Exercise the Watch reset barrier with actual TaskStore and in-memory GRDB."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = set([
    "pause_closes_admission_before_drain",
    "nested_and_overlapping_pauses_keep_admission_closed",
    "cancelled_pause_waits_for_admitted_write",
    "dataset_rotation_is_durable_before_body",
    "identity_failure_prevents_destructive_body",
    "reset_waits_for_internal_taskstore_write",
    "reset_leaves_no_late_task_or_outbox_write",
    "queued_capture_before_reset_is_not_admitted_afterward"
])

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(source, output):
    package = output / "package"
    target = package / "Sources/WatchGateProbe"
    target.mkdir(parents=True)
    inputs = {}
    for path in sorted((source / "GSDKit/Sources").rglob("*")):
        if path.is_file():
            inputs[str(path.relative_to(source))] = digest(path)
    for relative in ("GSDKit/Package.swift", "GSDKit/Package.resolved",
                     "App/Watch/WatchMutationGate.swift", "App/Watch/WatchSessionCoordinator.swift"):
        path = source / relative
        inputs[relative] = digest(path)
    phone = (source / "App/Watch/WatchSessionCoordinator.swift").read_text()
    scoped = "private let mutationGate: WatchMutationGate" in phone
    for excluded in ("import UIKit", "import WatchConnectivity"):
        if phone.count(excluded + "\n") != 1:
            raise ValueError("Phone platform import changed")
        phone = phone.replace(excluded + "\n", "")
    (target / "WatchSessionCoordinator.swift").write_text(phone)
    shutil.copyfile(source / "App/Watch/WatchMutationGate.swift", target / "WatchMutationGate.swift")
    fixture = Path(__file__).with_name("watch_gate_probe.swift")
    shutil.copyfile(fixture, target / "Probe.swift")
    inputs["probe/check_watch_gate.py"] = digest(Path(__file__))
    inputs["probe/watch_gate_probe.swift"] = digest(fixture)
    settings = ', swiftSettings: [.define("WATCH_ACCOUNT_SCOPED")]' if scoped else ''
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "GSDWatchGateProbe",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: SOURCE_PATH)],
    targets: [
        .executableTarget(name: "WatchGateProbe",
            dependencies: [.product(name: "GSDModel", package: "GSDKit"),
                           .product(name: "GSDStore", package: "GSDKit"),
                           .product(name: "GSDSnapshot", package: "GSDKit")]TARGET_SETTINGS)
    ]
)
'''
    (package / "Package.swift").write_text(
        manifest.replace("SOURCE_PATH", json.dumps(str(source / "GSDKit"))).replace("TARGET_SETTINGS", settings))
    shutil.copyfile(source / "GSDKit/Package.resolved", package / "Package.resolved")
    source_pins = json.loads((source / "GSDKit/Package.resolved").read_text())["pins"]
    grdb = next(pin for pin in source_pins if pin["identity"] == "grdb.swift")
    receipt = {
        "sourceRoot": str(source), "files": inputs,
        "platformDoubles": ["WatchConnectivity", "UIKit applicationState"],
        "realImplementations": ["TaskStore", "GRDBTaskRepository", "GRDBSyncQueueRepository",
                                "BackgroundDatabaseWindow", "WatchSessionCoordinator", "WatchMutationGate"],
        "suspendedRead": "TaskRepository decorator delays only read2; all reads/writes execute real GRDB",
        "scopedCoordinatorWired": scoped,
        "database": "AppDatabase.inMemory; isolated suite and feedback defaults; no live credentials or network",
        "expectedGRDBRevision": grdb["state"]["revision"],
        "physicalWatchAcceptance": False, "nativeFrameworkCompilation": False,
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
        raise ValueError("Output exists; retain prior evidence")
    if not args.prepare_only and platform.system() != "Darwin":
        raise RuntimeError("Execute Swift only on the owned Apple runner")
    output.mkdir(parents=True)
    package, manifest = prepare(source, output)
    if args.prepare_only:
        print(json.dumps({"prepared": True, "executed": False, "package": str(package)}))
        return 0
    scratch = (args.scratch_path or output / "build").resolve()
    command = ["swift", "run", "--package-path", str(package), "--scratch-path", str(scratch),
               "-j", str(args.jobs), "WatchGateProbe"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("WATCH_GATE_CHECK ")) for line in result.stdout.splitlines()
              if line.startswith("WATCH_GATE_CHECK ")]
    names = [check["name"] for check in checks]
    grdb_path = scratch / "checkouts/GRDB.swift"
    actual_revision = subprocess.run(["git", "-C", str(grdb_path), "rev-parse", "HEAD"],
                                     capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", str(grdb_path), "status", "--porcelain"],
                           capture_output=True, text=True)
    dependency_exact = actual_revision == manifest["expectedGRDBRevision"] and dirty.returncode == 0 and not dirty.stdout
    changed = [relative for relative, sha in manifest["files"].items()
               if not relative.startswith("probe/") and digest(source / relative) != sha]
    passed = (result.returncode == 0 and set(names) == EXPECTED and len(names) == len(EXPECTED)
              and all(check["passed"] for check in checks) and dependency_exact and not changed)
    receipt = {
        "passed": passed, "returncode": result.returncode, "checks": checks, "expected": sorted(EXPECTED),
        "realTaskStoreWriteDrainAcceptance": passed,
        "physicalWatchAcceptance": False, "nativeFrameworkCompilation": False,
        "dependencyExactAndClean": dependency_exact, "actualGRDBRevision": actual_revision,
        "changedInputs": changed, "inputManifestSHA256": digest(output / "input-manifest.json"),
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
