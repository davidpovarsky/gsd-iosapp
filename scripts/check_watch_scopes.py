#!/usr/bin/env python3
"""Execute Watch account/dataset regressions against immutable app glue.

The original 27-check fixture is not edited. This suite uses the same exact source
preparation plus explicit platform/TaskStore doubles. Scope input is JSON on the
real Watch wire, so the unscoped baseline compiles and demonstrates the fault.
A separate real-TaskStore fixture is required for the internal-write drain window.
"""
import argparse
import hashlib
import importlib.util
import json
import platform
import subprocess
import sys
from pathlib import Path

EXPECTED = set([
    "scoped_capture_preserves_verified_origin",
    "unresolved_snapshot_disables_capture",
    "legacy_snapshot_hides_unverified_rows",
    "account_change_hides_previous_pending_rows",
    "account_change_clears_undo_and_navigation",
    "stale_row_callback_cannot_queue_for_new_account",
    "stale_capture_draft_cannot_move_to_new_account",
    "same_account_transition_invalidates_old_ui_lease",
    "legacy_unscoped_command_is_kept_and_not_transferred",
    "other_account_ack_does_not_discard_held_command",
    "relaunch_preserves_scope_quarantine",
    "matching_account_returns_held_command_without_rebinding",
    "snapshot_refresh_keeps_current_ui_lease",
    "phone_rejects_other_account_capture",
    "phone_rejects_unscoped_legacy_capture",
    "phone_revalidates_scope_after_suspended_fetch",
    "phone_emits_empty_snapshot_during_unresolved_identity",
    "phone_rejects_previous_dataset_capture"
])

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(source, output):
    helper = Path(__file__).with_name("check_watch_systems.py")
    spec = importlib.util.spec_from_file_location("watch_systems_preparation", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    package = module.prepare(source, output)
    target = package / "Sources/WatchSystemsProbe"
    original = Path(__file__).with_name("watch_systems_probe.swift")
    original_text = original.read_text()
    marker = "@main struct WatchSystemsProbe"
    if original_text.count(marker) != 1:
        raise ValueError("Original 27-check fixture marker changed")
    doubles = original_text.split(marker)[0]
    needle = "    private(set) var fetches: [String] = []"
    if doubles.count(needle) != 1:
        raise ValueError("TaskStore double fetch seam changed")
    doubles = doubles.replace(needle, "    var beforeFetch: (@MainActor () async -> Void)?\n" + needle)
    needle = "        fetches.append(id)"
    if doubles.count(needle) != 1:
        raise ValueError("TaskStore double fetch hook changed")
    doubles = doubles.replace(needle, "        if let beforeFetch { await beforeFetch() }\n" + needle)
    fixture = Path(__file__).with_name("watch_scope_probe.swift")
    (target / "Probe.swift").write_text(doubles + fixture.read_text())
    manifest = json.loads((output / "input-manifest.json").read_text())
    scoped = (source / "App/Watch/WatchMutationGate.swift").exists()
    if scoped:
        gate = source / "App/Watch/WatchMutationGate.swift"
        (target / gate.name).write_bytes(gate.read_bytes())
        manifest["files"][str(gate.relative_to(source))] = digest(gate)
        package_file = package / "Package.swift"
        text = package_file.read_text()
        needle = '.executableTarget(name: "WatchSystemsProbe", dependencies: ["GSDModel", "GSDSnapshot"]),'
        if text.count(needle) != 1:
            raise ValueError("Prepared target declaration changed")
        text = text.replace(needle, '.executableTarget(name: "WatchSystemsProbe", dependencies: ["GSDModel", "GSDSnapshot"], swiftSettings: [.define("WATCH_ACCOUNT_SCOPED")]),')
        package_file.write_text(text)
    manifest["files"]["probe/check_watch_scopes.py"] = digest(Path(__file__))
    manifest["files"]["probe/watch_scope_probe.swift"] = digest(fixture)
    manifest["fixtureAdaptation"] = {
        "original27FixtureUnmodified": True,
        "platformDoublesFromOriginalFixturePrefix": True,
        "suspendedReadHook": "TaskStore double beforeFetch await, for coordinator revalidation only",
        "scopeInput": "Real WatchCommand/WatchSnapshot JSON encode/decode",
        "scopedHostAPIAvailable": scoped,
        "baselineBehavior": "Original host APIs ignore new origin metadata; no source behavior patch",
        "realTaskStoreWriteDrainAcceptance": False,
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
        raise ValueError("Output exists; preserve prior evidence")
    if not args.prepare_only and platform.system() != "Darwin":
        raise RuntimeError("Swift execution belongs on the owned Apple runner")
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
    checks = [json.loads(line.removeprefix("WATCH_SCOPE_CHECK "))
              for line in result.stdout.splitlines() if line.startswith("WATCH_SCOPE_CHECK ")]
    names = [check["name"] for check in checks]
    passed = (result.returncode == 0 and set(names) == EXPECTED
              and len(names) == len(EXPECTED) and all(check["passed"] for check in checks))
    receipt = {"passed": passed, "returncode": result.returncode, "checks": checks,
               "expected": sorted(EXPECTED), "physicalWatchAcceptance": False,
               "nativeFrameworkCompilation": False, "realTaskStoreWriteDrainAcceptance": False,
               "inputManifestSHA256": digest(output / "input-manifest.json")}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
