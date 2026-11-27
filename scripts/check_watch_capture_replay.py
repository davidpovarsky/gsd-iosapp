#!/usr/bin/env python3
"""Exercise retained Trash/archive capture replay with actual TaskStore and GRDB."""
import argparse
import hashlib
import importlib.util
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = {"capture_replay_preserves_retained_trash_after_ledger_eviction",
            "capture_replay_preserves_retained_archive_after_ledger_eviction"}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(source, output):
    helper = Path(__file__).with_name("check_watch_gate.py")
    spec = importlib.util.spec_from_file_location("watch_gate_preparation", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    package, manifest = module.prepare(source, output)
    original = Path(__file__).with_name("watch_gate_probe.swift")
    text = original.read_text()
    marker = "@main struct WatchGateProbe"
    if text.count(marker) != 1:
        raise ValueError("Original gate fixture marker changed")
    fixture = Path(__file__).with_name("watch_capture_replay_probe.swift")
    (package / "Sources/WatchGateProbe/Probe.swift").write_text(text.split(marker)[0] + fixture.read_text())
    manifest["files"]["probe/check_watch_capture_replay.py"] = digest(Path(__file__))
    manifest["files"]["probe/watch_capture_replay_probe.swift"] = digest(fixture)
    manifest["replayProof"] = (
        "Actual phone capture -> actual TaskStore delete/archive -> actual bounded ledger eviction "
        "-> reconstructed coordinator -> original capture replay -> canonical rows, terminal records and outbox"
    )
    (output / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return package, manifest


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
    checks = [json.loads(line.removeprefix("WATCH_REPLAY_CHECK ")) for line in result.stdout.splitlines()
              if line.startswith("WATCH_REPLAY_CHECK ")]
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
        "realTaskStoreCaptureReplayAcceptance": passed,
        "physicalWatchAcceptance": False, "nativeFrameworkCompilation": False,
        "dependencyExactAndClean": dependency_exact, "actualGRDBRevision": actual_revision,
        "changedInputs": changed, "inputManifestSHA256": digest(output / "input-manifest.json"),
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
