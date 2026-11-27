#!/usr/bin/env python3
"""Run actual Share inbox/title code with isolated real TaskStore, outbox and GRDB."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED = set([
    "legacy_share_stays_durable_for_review",
    "account_a_share_cannot_overwrite_account_b",
    "old_dataset_share_stays_held_after_reset",
    "unresolved_identity_does_not_ingest_share",
    "current_scope_preserves_local_and_pushed_landings",
    "local_share_create_drains_before_reset",
    "pushed_ingest_drains_before_reset",
    "late_title_fetch_cannot_edit_another_account",
    "title_enrichment_reads_canonical_row_without_ui_snapshot",
    "title_internal_write_drains_before_reset",
    "retained_trash_blocks_share_replay",
    "retained_archive_blocks_share_replay",
    "canonical_edit_survives_pushed_creation_replay",
    "canonical_edit_survives_queued_creation_replay",
    "distinct_edited_retry_is_retained_without_overwriting_canonical",
    "open_share_review_does_not_follow_account_transitions",
    "account_capture_without_server_generation_stays_held",
    "account_capture_generation_mismatch_stays_held",
    "generation_lookup_failure_preserves_share",
    "pushed_capture_revalidates_server_generation_before_ingest",
    "late_share_generation_lookup_revalidates_account_scope",
    "share_generation_reaches_persisted_sync_queue",
    "title_generation_reaches_persisted_sync_queue",
    "title_enrichment_rejects_rotated_server_generation",
    "unbound_account_title_enrichment_does_not_queue",
    "guest_share_and_title_do_not_require_server_generation",
    "canonical_edits_during_generation_lookup_are_preserved"
])

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(source, output):
    package = output / "package"
    target = package / "Sources/ShareScopeProbe"
    target.mkdir(parents=True)
    inputs = {}
    for path in sorted((source / "GSDKit/Sources").rglob("*")):
        if path.is_file():
            inputs[str(path.relative_to(source))] = digest(path)
    for relative in ("GSDKit/Package.swift", "GSDKit/Package.resolved",
                     "App/Watch/WatchMutationGate.swift", "App/Sharing/ShareInboxDrainer.swift",
                     "App/Sharing/ShareTitleEnricher.swift"):
        inputs[relative] = digest(source / relative)
    scoped = "mutationGate:" in (source / "App/Sharing/ShareInboxDrainer.swift").read_text()
    copy = ["App/Watch/WatchMutationGate.swift", "App/Sharing/ShareInboxDrainer.swift",
            "App/Sharing/ShareTitleEnricher.swift"]
    if scoped:
        copy.append("App/Sharing/ShareScopeContext.swift")
    for relative in copy:
        path = source / relative
        inputs[relative] = digest(path)
        text = path.read_text()
        if "import UIKit\n" in text:
            text = text.replace("import UIKit\n", "")
        if relative == "App/Sharing/ShareTitleEnricher.swift" and not scoped:
            # Expose the original fire-and-forget Task handle for deterministic fixture
            # joining. Its complete inner body and all production branching are unchanged.
            before = "    func schedule(for task: GSDModel.Task) {"
            if text.count(before) != 1:
                raise ValueError("Expected the original title scheduling operation")
            text = text.replace(before, "    func schedule(for task: GSDModel.Task) -> _Concurrency.Task<Void, Never>? {", 1)
            text = text.replace("else { return }   // not URL-derived", "else { return nil }   // not URL-derived", 1)
            text = text.replace("        _Concurrency.Task { [weak self] in", "        return _Concurrency.Task { [weak self] in", 1)
        (target / path.name).write_text(text)
    fixture = Path(__file__).with_name("share_scope_probe.swift")
    shutil.copyfile(fixture, target / "Probe.swift")
    inputs["probe/check_share_scopes.py"] = digest(Path(__file__))
    inputs["probe/share_scope_probe.swift"] = digest(fixture)
    definitions = ['.define("SHARE_ACCOUNT_SCOPED")'] if scoped else []
    if "func isReviewCurrent(" in (source / "App/Sharing/ShareInboxDrainer.swift").read_text():
        definitions.append('.define("SHARE_REVIEW_LEASED")')
    if "serverGeneration:" in (source / "App/Sharing/ShareInboxDrainer.swift").read_text():
        definitions.append('.define("SHARE_SERVER_GENERATION")')
    settings = ', swiftSettings: [' + ', '.join(definitions) + ']' if definitions else ''
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "GSDShareScopeProbe",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: SOURCE_PATH)],
    targets: [
        .executableTarget(name: "ShareScopeProbe",
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
        "platformDoubles": ["UIKit applicationState"],
        "realImplementations": ["ShareInbox", "ShareInboxDrainer", "ShareTitleEnricher",
                                "TaskStore", "GRDBTaskRepository", "GRDBSyncQueueRepository",
                                "BackgroundDatabaseWindow", "WatchMutationGate"],
        "suspendedOperations": "TaskRepository decorator holds actual read results/internal upsert; all persistence is actual GRDB",
        "scopedShareAvailable": scoped,
        "generationFixtureAdaptation": "Explicit known generation for original16 controls; constructor signatures only; original16 assertion bodies unchanged",
        "titleTaskHandleAdaptation": "Baseline only: return the existing Task handle; full async body remains unchanged",
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
               "-j", str(args.jobs), "ShareScopeProbe", "--demo-share-scope"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    (output / "stdout.log").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    checks = [json.loads(line.removeprefix("SHARE_SCOPE_CHECK ")) for line in result.stdout.splitlines()
              if line.startswith("SHARE_SCOPE_CHECK ")]
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
        "actualShareScopeWithTaskStoreAcceptance": passed,
        "nativeShareSheetAcceptance": False,
        "liveCloudAcceptance": False,
        "physicalWatchAcceptance": False, "nativeFrameworkCompilation": False,
        "dependencyExactAndClean": dependency_exact, "actualGRDBRevision": actual_revision,
        "changedInputs": changed, "inputManifestSHA256": digest(output / "input-manifest.json"),
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
