#!/usr/bin/env python3
"""Run production Watch glue with real model/outbox code and platform test doubles.

The probe copies the original Foundation modules unchanged. It replaces only imports
for unavailable phone/watch frameworks and the WatchModel storage-directory lookup.
This is a fault/lifecycle unit probe, not evidence of WatchConnectivity radio delivery
or SwiftUI rendering. The native app and Watch targets must also compile normally.
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
    "no_container_keeps_outbox_empty",
    "failed_write_preserves_existing_queue",
    "capture_success_is_durable",
    "capture_failure_is_reported",
    "unchanged_snapshot_is_coalesced",
    "activation_resends_current_snapshot",
    "watch_reinstall_resends_current_snapshot",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(source, output):
    package = output / "package"
    inputs = {}
    for module in ("GSDModel", "GSDSnapshot"):
        original = source / "GSDKit/Sources" / module
        for path in sorted(original.rglob("*")):
            if path.is_file():
                inputs[str(path.relative_to(source))] = digest(path)
        shutil.copytree(original, package / "Sources" / module)
    target = package / "Sources/WatchSystemsProbe"
    target.mkdir(parents=True)
    for relative, excluded in (
        ("Watch/WatchModel.swift", {"import WatchConnectivity", "import WidgetKit"}),
        ("App/Watch/WatchSessionCoordinator.swift",
         {"import UIKit", "import WatchConnectivity", "import GSDStore"}),
        ("GSDKit/Sources/GSDStore/AppGroupDefaults.swift", set()),
    ):
        original = source / relative
        inputs[relative] = digest(original)
        text = original.read_text()
        for line in excluded:
            if text.count(line + "\n") != 1:
                raise ValueError(f"Expected one platform import: {relative}: {line}")
            text = text.replace(line + "\n", "")
        if relative.startswith("Watch/"):
            needle = "let directory = Self.storageDirectory()"
            if text.count(needle) != 1:
                raise ValueError("WatchModel storage injection seam changed")
            text = text.replace(needle, "let directory = watchProbeDirectory")
        (target / original.name).write_text(text)
    fixture = Path(__file__).with_name("watch_systems_probe.swift")
    inputs["probe/watch_systems_probe.swift"] = digest(fixture)
    inputs["probe/check_watch_systems.py"] = digest(Path(__file__))
    shutil.copyfile(fixture, target / "Probe.swift")
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "GSDWatchSystemsProbe",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "GSDModel", resources: [.copy("Resources/whats-new.json")]),
        .target(name: "GSDSnapshot", dependencies: ["GSDModel"]),
        .executableTarget(name: "WatchSystemsProbe", dependencies: ["GSDModel", "GSDSnapshot"]),
    ]
)
''')
    manifest = {
        "sourceRoot": str(source),
        "files": inputs,
        "platformDoubles": ["WatchConnectivity", "WidgetKit", "UIKit", "TaskStore",
                            "BackgroundDatabaseWindow", "HarnessLaunch", "StoreLocation"],
        "storageInjection": "WatchModel initializer directory only",
        "physicalWatchAcceptance": False,
        "nativeFrameworkCompilation": False,
    }
    (output / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    source, output = args.source_root.resolve(), args.output.resolve()
    if output.exists():
        raise ValueError("Output already exists; retain the prior evidence and select a new path")
    if not args.prepare_only and platform.system() != "Darwin":
        raise RuntimeError("Execute the Swift probe on the owned Apple runner")
    output.mkdir(parents=True)
    package = prepare(source, output)
    if args.prepare_only:
        print(json.dumps({"prepared": True, "executed": False, "package": str(package)}))
        return 0
    command = ["swift", "run", "--package-path", str(package), "--scratch-path",
               str(output / "build"), "-j", str(args.jobs), "WatchSystemsProbe"]
    result = subprocess.run(command, text=True, capture_output=True, timeout=240)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = []
    for line in result.stdout.splitlines():
        if line.startswith("WATCH_SYSTEMS_CHECK "):
            checks.append(json.loads(line.removeprefix("WATCH_SYSTEMS_CHECK ")))
    names = [check["name"] for check in checks]
    passed = (result.returncode == 0 and set(names) == EXPECTED
              and len(names) == len(EXPECTED) and all(check["passed"] for check in checks))
    receipt = {"passed": passed, "returncode": result.returncode, "checks": checks,
               "expected": sorted(EXPECTED), "physicalWatchAcceptance": False,
               "nativeFrameworkCompilation": False,
               "inputManifestSHA256": digest(output / "input-manifest.json")}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
