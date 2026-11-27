#!/usr/bin/env python3
"""Qualify actual Share lease/identity/gate code with separate native child processes."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = {
    "shared_leases_coexist_and_exclusive_reset_keeps_main_actor_responsive",
    "external_process_share_lease_delays_dataset_reset",
    "cancelled_exclusive_acquisition_releases_admission_without_running_body",
    "throwing_external_body_releases_lease_and_local_pause",
    "concurrent_first_processes_share_one_persisted_identity",
    "corrupt_identity_stays_held_and_legacy_codec_survives",
    "owned_process_death_releases_local_lease_without_replacing_lock_inode",
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
    target = package / "Sources/ShareProcessProbe"
    target.mkdir(parents=True)
    gate = source / "App/Watch/WatchMutationGate.swift"
    inputs[str(gate.relative_to(source))] = digest(gate)
    shutil.copyfile(gate, target / gate.name)
    fixture = Path(__file__).with_name("share_process_probe.swift")
    shutil.copyfile(fixture, target / "Probe.swift")
    inputs["probe/check_share_processes.py"] = digest(Path(__file__))
    inputs["probe/share_process_probe.swift"] = digest(fixture)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "GSDShareProcessProbe", platforms: [.macOS(.v26)],
    targets: [
        .target(name: "GSDModel", resources: [.copy("Resources/whats-new.json")]),
        .target(name: "GSDSnapshot", dependencies: ["GSDModel"]),
        .executableTarget(name: "ShareProcessProbe", dependencies: ["GSDModel", "GSDSnapshot"])
    ])
''')
    manifest = {
        "sourceRoot": str(source), "files": inputs,
        "realImplementations": ["SharedMutationLease", "SharedDatasetIdentityStore",
                                "WatchMutationGate", "actual filesystem and OS flock",
                                "separate child processes of the same native executable"],
        "processesAtOnceMaximum": 8,
        "mutationBody": "isolated marker only; actual TaskStore coverage belongs to gate8/Share16",
        "temporaryFilesystemOnly": True,
        "networkRequests": False, "personalCredentialsUsed": False,
        "remoteLateCommitOrderingAcceptance": False, "nativeShareSheetAcceptance": False,
    }
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
    if output.exists():
        raise ValueError("Output exists; retain prior evidence")
    if not a.prepare_only and platform.system() != "Darwin":
        raise RuntimeError("Execute native Swift only on the owned Apple runner")
    output.mkdir(parents=True)
    package, manifest = prepare(source, output)
    if a.prepare_only:
        print(json.dumps({"prepared": True, "executed": False, "package": str(package)}))
        return 0
    scratch = (a.scratch_path or output / "build").resolve()
    result = subprocess.run(["swift", "run", "--package-path", str(package),
                             "--scratch-path", str(scratch), "-j", str(a.jobs), "ShareProcessProbe"],
                            capture_output=True, text=True, timeout=300)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("SHARE_PROCESS_CHECK ")) for line in result.stdout.splitlines()
              if line.startswith("SHARE_PROCESS_CHECK ")]
    names = [c["name"] for c in checks]
    changed = [f for f, h in manifest["files"].items()
               if not f.startswith("probe/") and digest(source / f) != h]
    passed = (result.returncode == 0 and len(names) == len(EXPECTED) and set(names) == EXPECTED
              and all(c["passed"] for c in checks) and not changed)
    receipt = {
        "passed": passed, "returncode": result.returncode, "checks": checks,
        "expected": sorted(EXPECTED), "changedInputs": changed,
        "actualCrossProcessCoordinationAcceptance": passed,
        "actualTaskStoreAcceptance": False, "remoteLateCommitOrderingAcceptance": False,
        "nativeShareSheetAcceptance": False, "personalCredentialsUsed": False,
        "inputManifestSHA256": digest(output / "input-manifest.json"),
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
