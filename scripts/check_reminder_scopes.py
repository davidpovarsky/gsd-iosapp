#!/usr/bin/env python3
"""Exercise canonical scoped reminder scheduling with actual TaskStore and GRDB."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = set([
    "reminder_uses_canonical_row_for_scoped_payload",
    "reminder_missing_canonical_task_cancels_stale_copy",
    "reminder_requires_configured_verified_scope",
    "cancelled_resync_cannot_start_new_reminder",
    "reminder_revalidates_scope_after_suspended_read",
    "reminder_read_failure_preserves_existing_request",
    "paused_dataset_blocks_reminder_admission",
    "dataset_reset_drains_admitted_notification_add"
])

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(source, output):
    package = output / "package"
    target = package / "Sources/ReminderScopeProbe"
    target.mkdir(parents=True)
    inputs = {}
    for path in sorted((source / "GSDKit/Sources").rglob("*")):
        if path.is_file():
            inputs[str(path.relative_to(source))] = digest(path)
    for relative in ("GSDKit/Package.swift", "GSDKit/Package.resolved",
                     "App/Watch/WatchMutationGate.swift", "App/Notifications/LiveReminderScheduler.swift"):
        path = source / relative
        inputs[relative] = digest(path)
    scheduler = (source / "App/Notifications/LiveReminderScheduler.swift").read_text()
    scoped = "func configureScope(" in scheduler
    if scheduler.count("import UserNotifications\n") != 1:
        raise ValueError("UserNotifications platform import changed")
    # Retain the real framework import for NSString.localizedUserNotificationString.
    # Module-local fixture types shadow only notification delivery/content/requests.
    if "import UIKit\n" in scheduler:
        scheduler = scheduler.replace("import UIKit\n", "")
    (target / "LiveReminderScheduler.swift").write_text(scheduler)
    shutil.copyfile(source / "App/Watch/WatchMutationGate.swift", target / "WatchMutationGate.swift")
    fixture = Path(__file__).with_name("reminder_scope_probe.swift")
    shutil.copyfile(fixture, target / "Probe.swift")
    inputs["probe/check_reminder_scopes.py"] = digest(Path(__file__))
    inputs["probe/reminder_scope_probe.swift"] = digest(fixture)
    settings = ', swiftSettings: [.define("REMINDER_CANONICAL_CONTEXT")]' if scoped else ''
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "GSDReminderScopeProbe",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: SOURCE_PATH)],
    targets: [
        .executableTarget(name: "ReminderScopeProbe",
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
        "platformDoubles": ["UserNotifications recording center", "UIKit applicationState"],
        "retainedFrameworkAPI": "Actual UserNotifications NSString localization extension; module-local transport types remain doubles",
        "realImplementations": ["TaskStore", "GRDBTaskRepository", "ReminderMath",
                                "BackgroundDatabaseWindow", "LiveReminderScheduler", "WatchMutationGate"],
        "suspendedRead": "TaskRepository decorator holds one actual GRDB read result or injects one read error",
        "canonicalReminderContextAvailable": scoped,
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
               "-j", str(args.jobs), "ReminderScopeProbe"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("REMINDER_SCOPE_CHECK ")) for line in result.stdout.splitlines()
              if line.startswith("REMINDER_SCOPE_CHECK ")]
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
        "realTaskStoreCanonicalReminderAcceptance": passed,
        "systemNotificationDeliveryAcceptance": False,
        "physicalWatchAcceptance": False, "nativeFrameworkCompilation": False,
        "dependencyExactAndClean": dependency_exact, "actualGRDBRevision": actual_revision,
        "changedInputs": changed, "inputManifestSHA256": digest(output / "input-manifest.json"),
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
