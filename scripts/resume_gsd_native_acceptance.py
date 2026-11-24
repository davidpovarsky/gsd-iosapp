#!/usr/bin/env python3
"""Finish only the missing iPads from the verified, cancelled GSD48 run.

This is intentionally pinned to one reviewed source and three immutable artifacts.
The cancelled parent is never called a successful complete acceptance run.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import zipfile

from gsd_native_acceptance import run
from gsd_simulator_smoke import devices_for_runtime, version

REPOSITORY = "davidpovarsky/gsd-iosapp"
WORKFLOW = ".github/workflows/gsd-hanlin-agent-ios.yml"
SOURCE = "37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc"
PARENT_RUN = "45343781703"
PARENT_JOB = 138273356562
BUILD = "48"
XCODE = "Xcode 27.1\nBuild version 27A9275"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
RUNTIME_BUILD = "24B8117"
PROJECT_HASH = "c2b6eac9e7526b9a07f46f4d4820b1eaaae20a024c5f0ec0742115fc5807cc10"
INNER_HASH = "14cd82477fd8956d9d4f173ee98aa10d26244857f1b5fd8b73a23ad4c1c6be9b"
ARTIFACTS = {
    "native": (14898584445, "GSD-Native-Evidence-45343781703",
        "483af6eb599df092919fafdea691ada6419967a9f0f1d3bb60f0be639e0047e9",
        "371a6e4851e5a9323581ab3e27e372996d93d26546b4efef306e293eab27a36c", 105),
    "products": (14897632059, "GSD-Simulator-BuildProducts-45343781703",
        "0396371b6530b09d0d405df887291f248193813e58986f734a58b11bb87749c5",
        "c52e9a1d1924e7ea74896d0b004beb7b48d9367ac570e38bc1b0b2f136e2caa8", 2),
    "project": (14898449718, "GSD-Generated-Project-45343781703",
        "ad039051907ef0b84eb3c7bd8dc5b8635fefee539bbe2c422509baa0dc5a8961",
        "a12aa11da9aa6efdecfe534cb9b5255ad938d9e76de7c9390f5d074c0fd595bd", 9),
}
TESTS = ["test01LocalizedNavigationEditorChartsAndRTL", "test03LocalizedWidgetView",
         "test04LocalizedHanlinProvidersAndChatGPTAccount"]
CLOUD_TEST = "test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload"
BUNDLE_IDS = {"com.itorah.gsd" + suffix for suffix in
              ("", ".widgets", ".share", ".watchkitapp", ".watchkitapp.widgets")}
REQUIRED_STEPS = {
    1: "Set up job", 2: "Run actions/checkout@v4", 3: "Verify immutable source and Xcode",
    4: "Verify native session identity observation", 5: "Verify native connectivity restoration",
    6: "Materialize and audit the original pinned Hanlin SDK", 7: "Generate localized Xcode targets",
    8: "Resolve public dependencies before executing tests",
    10: "Validate Hanlin tools and official ChatGPT contracts",
    11: "Validate account, cloud and sync conflict contracts",
    12: "Validate account deletion and recovery contracts",
    13: "Build app, four embedded targets and native UI runner once",
    14: "Preserve the compiled simulator products before runtime checks",
    15: "Retain simulator build for diagnostics and focused recovery",
    16: "Audit compiled target versions and localization resources",
    20: "Preserve localized generated project",
    21: "Preserve test summaries, screenshots and sanitized logs",
}


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read(path: Path) -> dict:
    return json.loads(path.read_text())


def api(path: str) -> dict:
    response = subprocess.run(["gh", "api", "repos/" + REPOSITORY + "/" + path],
                              capture_output=True, text=True, timeout=90)
    if response.returncode:
        raise RuntimeError("GitHub metadata read failed: exit=" + str(response.returncode))
    return json.loads(response.stdout)


def tree_digest(directory: Path) -> tuple[str, int]:
    rows = []
    for path in sorted(directory.rglob("*")):
        assert not path.is_symlink(), "Unexpected downloaded artifact symlink"
        if path.is_file():
            rows.append((path.relative_to(directory).as_posix(), sha(path)))
    rows.sort()
    value = hashlib.sha256(json.dumps(rows, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
    return value, len(rows)


def verify_parent_metadata(parent: dict, jobs: dict, entries: dict) -> None:
    assert str(parent["id"]) == PARENT_RUN and parent["head_sha"] == SOURCE
    assert parent["path"] == WORKFLOW and parent["status"] == "completed"
    assert parent["conclusion"] == "cancelled" and parent["run_attempt"] == 1
    assert jobs["total_count"] == len(jobs["jobs"]), "Incomplete job inventory"
    native = [job for job in jobs["jobs"] if job["id"] == PARENT_JOB]
    assert len(native) == 1 and native[0]["conclusion"] == "cancelled"
    steps = {step["number"]: step for step in native[0]["steps"]}
    for number, name in REQUIRED_STEPS.items():
        assert steps[number]["name"] == name and steps[number]["conclusion"] == "success", name
    assert steps[17]["conclusion"] == "cancelled"
    assert entries["total_count"] == len(entries["artifacts"]), "Incomplete artifact inventory"
    for identifier, name, digest, _, _ in ARTIFACTS.values():
        matches = [a for a in entries["artifacts"] if a["id"] == identifier and a["name"] == name]
        assert len(matches) == 1 and not matches[0]["expired"]
        assert matches[0]["digest"] == "sha256:" + digest
        assert matches[0]["workflow_run"]["head_sha"] == SOURCE
        assert str(matches[0]["workflow_run"]["id"]) == PARENT_RUN


def verify_profile(profile: dict, directory: Path, family: str, language: str) -> None:
    tests = TESTS + ([CLOUD_TEST] if (family, language) == ("iPad", "he") else [])
    assert (profile["family"], profile["language"], profile["runtime"]) == (family, language, "27.2")
    assert profile["passed"] is True and not profile.get("cleanupErrors")
    assert profile["cloudRoundTrip"] is ((family, language) == ("iPad", "he"))
    assert profile["selectedTests"] == tests and profile["verifiedPassedTests"] == tests
    summary = read(directory / "test-summary.json")
    assert summary["result"] == "Passed" and summary["passedTests"] == len(tests)
    assert summary["totalTestCount"] == len(tests)
    assert summary["failedTests"] == summary["skippedTests"] == summary["expectedFailures"] == 0
    assert not summary["testFailures"]
    configurations = summary["devicesAndConfigurations"]
    assert len(configurations) == 1 and configurations[0]["device"]["osBuildNumber"] == RUNTIME_BUILD
    assert configurations[0]["device"]["deviceId"] == profile["simulatorId"]
    log = (directory / "xcodebuild.log").read_text()
    for test in tests:
        outcomes = re.findall(r"(?im)^.*Test [Cc]ase.*\b" + re.escape(test) + r"\b.*\b(passed|failed)\b", log)
        assert outcomes == ["passed"], "Missing or ambiguous terminal test: " + test
    # The runner writes passed receipts only after checked deletion. Require both
    # current/parent retained cleanup outputs to agree with that success too.
    assert (directory / "shutdown.log").read_text().strip() == ""
    assert (directory / "delete.log").read_text().strip() == ""


def verify_inherited(native: Path) -> tuple[dict, dict]:
    ui = read(native / "ui/native-ui-receipt.json")
    assert ui["passed"] is False and ui["profile"] == "native-release"
    assert [(p["family"], p["language"]) for p in ui["runs"]] == [("iPhone", "en"), ("iPhone", "he")]
    for profile in ui["runs"]:
        verify_profile(profile, native / "ui" / ("iphone-" + profile["language"]), "iPhone", profile["language"])
    for filename, markers in {
        "session-observation.log": ["SESSION_OBSERVATION_RESULT passed=13 failed=0"],
        "sync-connectivity.log": ["SYNC_CONNECTIVITY_RESULT passed=8 failed=0"],
        "hanlin-tests.log": ["Executed 7 tests, with 0 failures", "Test run with 13 tests in 1 suite passed"],
        "cloud-sync-tests.log": ["Test run with 3 tests in 1 suite passed", "Test run with 94 tests in 7 suites passed",
                                 "Test run with 4 tests in 1 suite passed"],
        "account-deletion-tests.log": ["Test run with 18 tests in 2 suites passed"],
    }.items():
        text = (native / "logs" / filename).read_text()
        assert all(marker in text for marker in markers), "Missing inherited gate evidence: " + filename
    compiler_ids = set(re.findall(r"--xcode-version[ =]+([A-Za-z0-9]+)",
                                 (native / "logs/build-for-testing.log").read_text()))
    assert compiler_ids == {"27A9275"}, "Parent compiler build identity differs"
    bundles = read(native / "compiled-bundles.json")
    assert bundles["passed"] is True and {t["bundleId"] for t in bundles["targets"]} == BUNDLE_IDS
    assert len(bundles["targets"]) == 5
    assert all(t["version"] == "4.1.0" and t["build"] == BUILD for t in bundles["targets"])
    entitlements = read(native / "logs/simulator-entitlements.json")
    assert entitlements["passed"] is True and entitlements["source_sha"] == SOURCE
    assert entitlements["simulator_only"] is True and entitlements["entitlement_source"] == "Mach-O __TEXT,__entitlements"
    assert {t["bundleId"] for t in entitlements["targets"]} == BUNDLE_IDS and len(entitlements["targets"]) == 5
    for target in entitlements["targets"]:
        assert target["runtimeEntitlements"]["application-identifier"] == "NA6HPWARQ2." + target["bundleId"]
        assert target["runtimeEntitlements"]["com.apple.security.application-groups"] == ["group.com.itorah.gsd"]
    return ui, bundles


def verify_archive(directory: Path) -> Path:
    manifest = read(directory / "simulator-build.json")
    assert (manifest["source_sha"], manifest["run_id"], manifest["build"]) == (SOURCE, PARENT_RUN, BUILD)
    assert manifest["simulator_only"] is True and manifest["build_for_testing_completed"] is True
    assert manifest["archive"] == "GSD-Simulator-BuildProducts.zip" and manifest["sha256"] == INNER_HASH
    archive = directory / manifest["archive"]
    assert sha(archive) == INNER_HASH
    with zipfile.ZipFile(archive) as entries:
        assert len(entries.infolist()) <= 20000 and sum(i.file_size for i in entries.infolist()) <= 2_000_000_000
        for item in entries.infolist():
            name = PurePosixPath(item.filename)
            assert not name.is_absolute() and ".." not in name.parts and not stat.S_ISLNK(item.external_attr >> 16)
        assert [n for n in entries.namelist() if n.endswith(".xctestrun")] == ["Products/GSDScreenshots_iphonesimulator27.1-arm64.xctestrun"]
    return archive


def verify_restored(products: Path, logs: Path) -> dict:
    app = products / "Debug-iphonesimulator/GSD.app"
    found = {}
    for bundle in [app, *app.rglob("*.appex"), *app.rglob("*.app")]:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        identifier = info["CFBundleIdentifier"]
        assert identifier not in found
        assert (info["CFBundleVersion"], info["CFBundleShortVersionString"], info["DTXcodeBuild"]) == (BUILD, "4.1.0", "27A9275")
        found[identifier] = {"executable_sha256": sha(bundle / info["CFBundleExecutable"]), "xcode_build": info["DTXcodeBuild"]}
    assert set(found) == BUNDLE_IDS
    runner = products / "Debug-iphonesimulator/GSDScreenshotTests-Runner.app"
    test_bundle = runner / "PlugIns/GSDScreenshotTests.xctest"
    test_info = plistlib.loads((test_bundle / "Info.plist").read_bytes())
    assert (test_info["CFBundleIdentifier"], test_info["CFBundleVersion"], test_info["DTXcodeBuild"]) == (
        "com.itorah.gsd.screenshot-tests", BUILD, "27A9275")
    wrapper_info = plistlib.loads((runner / "Info.plist").read_bytes())
    assert (wrapper_info["CFBundleIdentifier"], wrapper_info["DTXcodeBuild"]) == (
        "com.itorah.gsd.screenshot-tests.xctrunner", "27A9272")  # Apple's prebuilt wrapper, unchanged.
    for bundle in (app, runner):
        run(["codesign", "--verify", "--deep", "--strict", str(bundle)], logs / (bundle.stem + "-signature.log"))
    return {"targets": found, "compiled_test_sha256": sha(test_bundle / test_info["CFBundleExecutable"]),
            "apple_prebuilt_runner_sha256": sha(runner / wrapper_info["CFBundleExecutable"])}


def compose_ui(inherited: dict, partial: dict, ui_directory: Path, run_id: str) -> dict:
    assert partial["passed"] is False and partial["profile"] == "native-release-partial"
    assert partial["selectedFamilies"] == ["iPad"]
    assert [(p["family"], p["language"]) for p in partial["runs"]] == [("iPad", "en"), ("iPad", "he")]
    profiles = []
    for original in inherited["runs"] + partial["runs"]:
        profile = dict(original)
        family, language = profile["family"], profile["language"]
        verify_profile(profile, ui_directory / (family.lower() + "-" + language), family, language)
        profile["source_sha"] = SOURCE
        profile["evidence_run_id"] = PARENT_RUN if family == "iPhone" else run_id
        profiles.append(profile)
    assert len(profiles) == 4 and {(p["family"], p["language"]) for p in profiles} == {
        (family, language) for family in ("iPhone", "iPad") for language in ("en", "he")}
    assert sum(len(p["verifiedPassedTests"]) for p in profiles) == 13
    marker_log = (ui_directory / "ipad-he/xcodebuild.log").read_text()
    owners = set(re.findall(r"GSD_NATIVE_ACCOUNT_DELETION_PUBLIC_PASS owner=([A-Za-z0-9]{15})(?![A-Za-z0-9])", marker_log))
    assert len(owners) == 1, "Missing or ambiguous native deletion public-proof owner"
    return {"passed": True, "profile": "native-release", "runs": profiles,
            "timestamp": datetime.now(timezone.utc).isoformat(), "composition": "same-source-verified-parent-phones-and-current-ipads",
            "native_deletion_public_owner": owners.pop(), "oracle_zero_row_verification": "pending independent root read"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    logs = output / "logs"; logs.mkdir(exist_ok=True)
    report = {"passed": False, "source_sha": SOURCE, "compiled_product_run_id": PARENT_RUN,
              "parent_conclusion": "cancelled", "cancel_actor": "unknown",
              "parent_ipad_en_cleanup": "Explicit simctl cleanup unobserved; hosted job terminated xcodebuild; no HE-iPad cloud fixture was entered",
              "parent_runner": "Metadata identifies GitHub Actions runner1000025605 / xcode-27 / MacCloud; historical simctl cleanup and VM disposal unobserved",
              "runner_reference": "https://docs.github.com/en/actions/reference/runners/github-hosted-runners",
              "harness_sha": os.environ.get("GITHUB_SHA"), "run_id": os.environ.get("GITHUB_RUN_ID")}
    try:
        assert os.environ["GSD_SOURCE_SHA"] == SOURCE and os.environ["GSD_BUILD_NUMBER"] == BUILD
        run_id = os.environ["GITHUB_RUN_ID"]
        assert run_id.isdigit() and run_id != PARENT_RUN and re.fullmatch(r"[0-9a-f]{40}", report["harness_sha"] or "")
        assert run(["xcodebuild", "-version"], logs / "toolchain.log").strip() == XCODE
        parent = api("actions/runs/" + PARENT_RUN)
        jobs = api("actions/runs/" + PARENT_RUN + "/jobs?per_page=100")
        entries = api("actions/runs/" + PARENT_RUN + "/artifacts?per_page=100")
        verify_parent_metadata(parent, jobs, entries)
        temporary = Path(os.environ["RUNNER_TEMP"]) / ("gsd48-resume-" + run_id)
        temporary.mkdir(exist_ok=False)
        downloaded = {}
        for kind, (_, name, digest, tree, count) in ARTIFACTS.items():
            directory = temporary / kind
            run(["gh", "run", "download", PARENT_RUN, "--repo", REPOSITORY, "--name", name,
                 "--dir", str(directory)], logs / ("download-" + kind + ".log"), timeout=180)
            assert tree_digest(directory) == (tree, count), "Extracted artifact bytes differ: " + kind
            downloaded[kind] = directory
        native, products, project = (downloaded[x] for x in ("native", "products", "project"))
        inherited, bundles = verify_inherited(native)
        project_path = project / "GSD.xcodeproj/project.pbxproj"
        assert sha(project_path) == PROJECT_HASH
        archive = verify_archive(products)
        derived = temporary / "derived"
        (derived / "Build").mkdir(parents=True)
        run(["ditto", "-x", "-k", str(archive), str(derived / "Build")], logs / "restore.log")
        report["restored_products"] = verify_restored(derived / "Build/Products", logs)
        # These source helpers are unchanged from the actual compiled source.
        for name in ("scripts/gsd_simulator_smoke.py", "scripts/verify_gsd_release_bundle.py", "scripts/gsd_appstore_connect.py", "HanlinSDK.lock.json"):
            expected = subprocess.run(["git", "show", SOURCE + ":" + name], check=True, capture_output=True).stdout
            assert Path(name).read_bytes() == expected, "Compiled-source helper differs: " + name
        inventory = json.loads(run(["xcrun", "simctl", "list", "--json"], logs / "runtime-inventory.json"))
        runtimes = sorted((r for r in inventory["runtimes"] if r.get("isAvailable")
                           and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                           and version(r["version"]) >= version("27.0")), key=lambda r: version(r["version"]), reverse=True)
        selected = next(r for r in runtimes if len(devices_for_runtime(inventory, r)) == 2)
        assert selected["identifier"] == RUNTIME and selected["buildversion"] == RUNTIME_BUILD
        run([sys.executable, "scripts/verify_gsd_release_bundle.py", "--app", str(derived / "Build/Products/Debug-iphonesimulator/GSD.app"),
             "--build", BUILD, "--output", str(output / "restored-compiled-bundles.json")], logs / "restored-bundle-audit.log")
        ui_directory = output / "ui"; ui_directory.mkdir(exist_ok=True)
        for language in ("en", "he"):
            shutil.copytree(native / "ui" / ("iphone-" + language), ui_directory / ("iphone-" + language))
        shutil.copytree(native / "logs", output / "inherited-logs")
        shutil.copy2(native / "compiled-bundles.json", output / "compiled-bundles.json")
        report["artifact_provenance"] = {kind: {"id": a[0], "github_zip_sha256": a[2], "extracted_tree_sha256": a[3], "files": a[4]}
                                         for kind, a in ARTIFACTS.items()}
        report["toolchain"] = XCODE
        report["harness_runner_sha256"] = sha(Path("scripts/gsd_native_acceptance.py"))
        report["harness_verifier_sha256"] = sha(Path(__file__))
        (output / "resume-provenance.json").write_text(json.dumps(report, indent=2) + "\n")
        environment = os.environ.copy()
        for secret in ("GH_TOKEN", "GITHUB_TOKEN"):
            environment.pop(secret, None)
        run(["curl", "--fail", "--silent", "--show-error", "--max-time", "30",
             environment["GSD_CLOUD_TEST_BASE"].rstrip("/") + "/api/health"], logs / "cloud-health.json", env=environment)
        # No rebuild, SDK installation, package suite or phone test is executed.
        # This runner emits only command/profile markers; raw XCTest output stays
        # in its private temporary files and is sanitized before artifact writes.
        # Inherit stdout so its safe progress remains visible during both iPads.
        subprocess.run([sys.executable, "scripts/gsd_native_acceptance.py", "--derived-data", str(derived),
                        "--output", str(ui_directory), "--family", "iPad"], check=True, env=environment)
        partial = read(ui_directory / "native-ui-receipt.json")
        shutil.copy2(ui_directory / "native-ui-receipt.json", ui_directory / "ipad-partial-receipt.json")
        combined = compose_ui(inherited, partial, ui_directory, run_id)
        (ui_directory / "native-ui-receipt.json").write_text(json.dumps(combined, indent=2) + "\n")
        packages = {"passed": True, "mode": "verified-parent-steps-and-hashed-logs", "current_source_sha": SOURCE,
                    "source_sha": SOURCE, "run_id": PARENT_RUN, "parent_conclusion": "cancelled",
                    "scope": "Only completed package gates inherited; parent whole-run acceptance was false"}
        receipt = {"passed": True, "source_sha": SOURCE, "build": BUILD, "run_id": run_id,
                   "workflow": WORKFLOW, "generated_project_sha256": PROJECT_HASH,
                   "hanlin_lock_sha256": sha(Path("HanlinSDK.lock.json")), "ui": combined, "bundles": bundles,
                   "package_contracts": packages, "compiled_product_run_id": PARENT_RUN,
                   "compiled_product_sha256": INNER_HASH, "harness_sha": report["harness_sha"],
                   "inherited_parent_conclusion": "cancelled"}
        (output / "native-acceptance.json").write_text(json.dumps(receipt, indent=2) + "\n")
        report["passed"] = True
        print("GSD_NATIVE_ACCOUNT_DELETION_PUBLIC_PASS owner=" + combined["native_deletion_public_owner"], flush=True)
        print("GSD_NATIVE_UI_ALL_FOUR_PASS source=" + SOURCE + " inherited_phones=" + PARENT_RUN + " current_ipads=" + run_id, flush=True)
    finally:
        (output / "resume-provenance.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
