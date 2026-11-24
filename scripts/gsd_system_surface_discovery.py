#!/usr/bin/env python3
"""Observe real iOS system surfaces using an immutable, validated GSD app.

Only the self-contained GSDScreenshotTests test runner is newly built. This is
supplemental evidence and can never emit the native-release acceptance receipt.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import sys
import time
import uuid
import zipfile

sys.dont_write_bytecode = True

from gsd_native_acceptance import run
from gsd_simulator_smoke import boot_device, devices_for_runtime
from resume_gsd_native_acceptance import api, sha, tree_digest
from verify_gsd_release_bundle import audit, BUNDLES
from gsd_appstore_connect import TEAM, APP_GROUP

SOURCE = "71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae"
PARENT_RUN = "45397928701"
PARENT_WORKFLOW_HEAD = "d0c5b9649a95e34aef0d4a641a28e2b7382bec0f"
PARENT_RECEIPT_SHA256 = "f099c5115a52e521e61bdcca41499326372999ff540c9dbc4df6e5b7c2164cd7"
INNER_PRODUCTS_SHA256 = "cfc50d90f996967ec968d967f56f656d128f1fe9d0d4be7d531fc72f0449428d"
TEST_SOURCE_SHA256 = "79bc4cc03c5047ea4d8843e21a6a86f32e4fc2a5fa3cda3643b460e39f87ba6c"
ARTIFACTS = {
    "GSD-Native-Acceptance-Receipt-" + PARENT_RUN: (
        14924405431, "57b0ec55d884f40f4842acd86a7c774bdafa70820a6c37e298b47ce6d8a8d278"),
    "GSD-Simulator-BuildProducts-" + PARENT_RUN: (
        14921503382, "881712bd03e5e6fd3ef0649805fc2bf661ba5fa60d6982215eb8c2018b05c209"),
}
BUILD = "48"
WORKFLOW = ".github/workflows/gsd-hanlin-agent-ios.yml"
XCODE = "Xcode 27.1\nBuild version 27A9275"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
RUNTIME_BUILD = "24B8117"
CLASS = "GSDSystemSurfaceUITests"
TESTS = ["test00RecordSystemSurfaceDiscovery", "test01TextShareExtensionRoundTripAndCancellation"]
SWIFT = Path("ScreenshotTests/GSDSystemSurfaceUITests.swift")
PHONE = "com.itorah.gsd"


def verify_parent(parent: dict, receipt: dict) -> None:
    assert (str(parent["id"]), parent["head_sha"], parent["path"]) == (PARENT_RUN, PARENT_WORKFLOW_HEAD, WORKFLOW)
    assert parent["status"] == "completed" and parent["conclusion"] == "success" and parent["run_attempt"] == 1
    assert receipt["passed"] is True and receipt["workflow"] == WORKFLOW
    assert (receipt["source_sha"], receipt["run_id"], receipt["build"]) == (SOURCE, PARENT_RUN, BUILD)
    ui = receipt["ui"]
    assert ui["passed"] is True and ui["profile"] == "native-release"
    profiles = ui["runs"]
    assert len(profiles) == 4 and {(p["family"], p["language"]) for p in profiles} == {
        (family, language) for family in ("iPhone", "iPad") for language in ("en", "he")}
    common = ["test01LocalizedNavigationEditorChartsAndRTL", "test03LocalizedWidgetView",
              "test04LocalizedHanlinProvidersAndChatGPTAccount"]
    for profile in profiles:
        cloud = (profile["family"], profile["language"]) == ("iPad", "he")
        selected = common + (["test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload"] if cloud else [])
        assert profile["passed"] is True and profile["cloudRoundTrip"] is cloud
        assert profile["runtime"] == "27.2" and profile["runtimeBuild"] == RUNTIME_BUILD
        assert profile["selectedTests"] == selected and profile["verifiedPassedTests"] == selected
        assert not profile.get("cleanupErrors") and not profile.get("failedTests")
    packages = receipt["package_contracts"]
    assert packages["passed"] is True and packages["mode"] == "executed"
    assert (packages["source_sha"], packages["current_source_sha"], packages["run_id"]) == (SOURCE, SOURCE, PARENT_RUN)
    assert receipt["bundles"]["passed"] is True and len(receipt["bundles"]["targets"]) == 5
    assert {r["bundleId"] for r in receipt["bundles"]["targets"]} == set(BUNDLES)


def safe_archive(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        items = archive.infolist()
        assert len(items) <= 20000 and sum(i.file_size for i in items) <= 2_000_000_000
        assert len({i.filename for i in items}) == len(items), "Duplicate archive member"
        for item in items:
            name = PurePosixPath(item.filename)
            assert not name.is_absolute() and ".." not in name.parts and "\\" not in item.filename
            assert not stat.S_ISLNK(item.external_attr >> 16), "Unexpected archive symlink"


def verify_artifact(name: str, entries: dict) -> dict:
    assert entries["total_count"] == len(entries["artifacts"]), "Incomplete artifact inventory"
    identifier, digest = ARTIFACTS[name]
    found = [a for a in entries["artifacts"] if a["name"] == name and not a["expired"]]
    assert len(found) == 1
    artifact = found[0]
    assert artifact["id"] == identifier and artifact.get("digest") == "sha256:" + digest
    assert str(artifact["workflow_run"]["id"]) == PARENT_RUN
    assert artifact["workflow_run"]["head_sha"] == PARENT_WORKFLOW_HEAD
    return artifact


def download(name: str, entries: dict, output: Path, report: dict) -> Path:
    artifact = verify_artifact(name, entries)
    digest = artifact["digest"]
    directory = output / "downloads" / name
    directory.mkdir(parents=True, exist_ok=False)
    archive = directory.with_suffix(".zip")
    with archive.open("xb") as stream:
        result = subprocess.run(["gh", "api", "repos/davidpovarsky/gsd-iosapp/actions/artifacts/"
                                 + str(artifact["id"]) + "/zip"], stdout=stream,
                                stderr=subprocess.PIPE, timeout=180)
    assert result.returncode == 0, "Authenticated artifact download failed"
    assert sha(archive) == digest.removeprefix("sha256:"), "GitHub artifact ZIP hash mismatch"
    safe_archive(archive)
    run(["ditto", "-x", "-k", str(archive), str(directory)], output / "logs" / (name + "-extract.log"), timeout=120)
    report["artifacts"][name] = {"id": artifact["id"], "actual_zip_sha256": sha(archive),
                                "github_digest": digest, "extracted_tree": tree_digest(directory)}
    return directory


def restore(output: Path, report: dict) -> Path:
    parent = api("actions/runs/" + PARENT_RUN)
    assert parent["status"] == "completed" and parent["conclusion"] == "success", "Current canonical native run must succeed first"
    entries = api("actions/runs/" + PARENT_RUN + "/artifacts?per_page=100")
    receipt_dir = download("GSD-Native-Acceptance-Receipt-" + PARENT_RUN, entries, output, report)
    receipt_path = receipt_dir / "native-acceptance.json"
    assert sha(receipt_path) == PARENT_RECEIPT_SHA256, "Exact validated parent receipt differs"
    receipt = json.loads(receipt_path.read_text())
    verify_parent(parent, receipt)
    directory = download("GSD-Simulator-BuildProducts-" + PARENT_RUN, entries, output, report)
    manifest = json.loads((directory / "simulator-build.json").read_text())
    assert (manifest["source_sha"], manifest["run_id"], manifest["build"]) == (SOURCE, PARENT_RUN, BUILD)
    assert manifest["simulator_only"] is True and manifest["build_for_testing_completed"] is True
    assert manifest["archive"] == "GSD-Simulator-BuildProducts.zip"
    assert manifest["sha256"] == INNER_PRODUCTS_SHA256
    archive = directory / manifest["archive"]
    assert sha(archive) == manifest["sha256"], "Inner compiled product hash mismatch"
    safe_archive(archive)
    restored = output / "restored"
    run(["ditto", "-x", "-k", str(archive), str(restored)], output / "logs/restore.log", timeout=120)
    report["compiled_product_manifest"] = manifest
    report["parent_native_receipt_verified"] = True
    return restored / "Products/Debug-iphonesimulator/GSD.app"


def simulator_entitlements(executable: Path, identifier: str) -> dict:
    # Same parser and identity checks used by the validated native workflow.
    data = executable.read_bytes()
    assert len(data) >= 32 and struct.unpack_from("<I", data)[0] == 0xfeedfacf
    assert struct.unpack_from("<I", data, 4)[0] == 0x0100000c
    count, size = struct.unpack_from("<II", data, 16)
    position, boundary = 32, 32 + size
    assert boundary <= len(data)
    matches = []
    for _ in range(count):
        assert position + 8 <= boundary
        command, length = struct.unpack_from("<II", data, position)
        assert length >= 8 and position + length <= boundary
        if command == 0x19:
            assert length >= 72
            sections = struct.unpack_from("<I", data, position + 64)[0]
            assert 72 + sections * 80 <= length
            for index in range(sections):
                section = position + 72 + index * 80
                name = data[section:section + 16].split(b"\0")[0]
                segment = data[section + 16:section + 32].split(b"\0")[0]
                if (segment, name) == (b"__TEXT", b"__entitlements"):
                    amount = struct.unpack_from("<Q", data, section + 40)[0]
                    offset = struct.unpack_from("<I", data, section + 48)[0]
                    assert offset + amount <= len(data)
                    matches.append(plistlib.loads(data[offset:offset + amount]))
        position += length
    assert len(matches) == 1
    entitlements = matches[0]
    assert entitlements.get("application-identifier") == TEAM + "." + identifier
    assert entitlements.get("com.apple.security.application-groups") == [APP_GROUP]
    return entitlements


def audit_products(app: Path, output: Path) -> dict:
    resources = audit(app, BUILD, "4.1.0", False)
    records = {}
    for identifier, relative in BUNDLES.items():
        bundle = app / relative
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        assert info["DTXcodeBuild"] == "27A9275"
        run(["codesign", "--verify", "--strict", str(bundle)], output / "logs" / (identifier + "-signature.log"))
        executable = bundle / info["CFBundleExecutable"]
        entitlements = simulator_entitlements(executable, identifier)
        records[identifier] = {"tree": tree_digest(bundle), "executable_sha256": sha(executable),
                               "runtimeEntitlements": entitlements}
    run(["codesign", "--verify", "--deep", "--strict", str(app)], output / "logs/deep-signature.log")
    return {"resources": resources, "targets": records, "app_tree": tree_digest(app)}


def projection(source: Path) -> dict:
    return {"name": "GSDSystemSurfaces", "options": {"deploymentTarget": {"iOS": "27.0"}},
        "targets": {"GSDScreenshotTests": {"type": "bundle.ui-testing", "platform": "iOS",
            "sources": [str(source.resolve())], "dependencies": [],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.itorah.gsd.screenshot-tests",
                "SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES",
                "CURRENT_PROJECT_VERSION": BUILD, "MARKETING_VERSION": "4.1.0",
                "SUPPORTED_PLATFORMS": "iphonesimulator", "TARGETED_DEVICE_FAMILY": "1,2",
                "CODE_SIGN_IDENTITY": "-", "CODE_SIGNING_ALLOWED": "YES"}}}},
        "schemes": {"GSDSystemSurfaces": {"build": {"targets": {"GSDScreenshotTests": ["testing"]},
              "buildImplicitDependencies": False},
              "test": {"config": "Debug", "targets": ["GSDScreenshotTests"]}}}}


def verify_projection(spec: dict, source: Path) -> None:
    assert set(spec["targets"]) == {"GSDScreenshotTests"} and not spec.get("packages")
    target = spec["targets"]["GSDScreenshotTests"]
    assert target["type"] == "bundle.ui-testing" and target["platform"] == "iOS"
    assert target["sources"] == [str(source.resolve())] and not target["dependencies"]
    assert "TEST_TARGET_NAME" not in target["settings"]["base"] and "TEST_HOST" not in target["settings"]["base"]
    scheme = spec["schemes"]["GSDSystemSurfaces"]
    assert scheme["build"] == {"targets": {"GSDScreenshotTests": ["testing"]}, "buildImplicitDependencies": False}
    assert scheme["test"]["targets"] == ["GSDScreenshotTests"]
    text = source.read_text()
    imports = re.findall(r"(?m)^\s*import\s+(\w+)", text)
    assert imports and set(imports).issubset({"Foundation", "UIKit", "XCTest"})
    assert not re.search(r"XCUIApplication\s*\(\s*\)", text)
    assert "com.itorah.gsd" in text and "targetEnvironment(simulator)" in text


def verify_build_plan(text: str) -> None:
    headings = re.findall(r"(?m)^\s*Target '([^']+)' in project '([^']+)'", text)
    assert headings and set(headings) == {("GSDScreenshotTests", "GSDSystemSurfaces")}, "Unexpected target in test-only build"
    assert not re.search(r"CompileSwift.*(?:GSDKit|Hanlin)", text, re.I), "Unexpected package compilation"
    assert "** TEST BUILD SUCCEEDED **" in text


def verify_observations(observations: dict, device: str, identifiers: list[str], outcomes: dict) -> None:
    assert observations["schemaVersion"] == 1
    assert observations["appSourceSHA"] == SOURCE and observations["simulatorID"] == device
    assert observations["language"] == "he" and observations["installedBundleIDs"] == identifiers
    assert observations["coverageComplete"] is False and observations["discoveryRecorded"] is True
    assert isinstance(observations["discoveryOnly"], bool)
    surfaces = observations["surfaces"]
    assert set(surfaces) == {"shareText", "shareWebURL", "widgetKit", "shortcuts", "accessibility", "voiceOver"}
    assert all(s["status"] in ("unknown", "incomplete", "passed", "failed") for s in surfaces.values())
    for name in ("shareWebURL", "widgetKit", "shortcuts", "voiceOver"):
        assert surfaces[name]["status"] != "passed", "Discovery-only surface cannot pass: " + name
    share = surfaces["shareText"]
    if share["status"] == "passed":
        expected = {"sourceCreated", "activitySheetOpened", "extensionOpenedForAdd", "addCreatedExactlyOne",
                    "addedTaskPersisted", "extensionOpenedForCancel", "cancelCreatedNone", "cancelNoneAfterRelaunch"}
        assert observations["discoveryOnly"] is False and outcomes[TESTS[1]] == "passed"
        assert set(share["assertions"]) == expected and all(v is True for v in share["assertions"].values())
    if outcomes[TESTS[1]] == "passed":
        assert share["status"] == "passed", "Passing Share test lacks its actual assertion receipt"
    accessibility = surfaces["accessibility"]
    if accessibility["status"] == "passed":
        # The pinned Swift emits this status only after the throwing audit returns.
        assert observations["discoveryOnly"] is False and outcomes[TESTS[0]] == "passed"
        assert share.get("assertions", {}).get("extensionOpenedForAdd") is True
        assert accessibility["scope"] == "sufficientElementDescription on the actual visible Share compose host"
        assert accessibility["voiceOverFocusOrSpeechVerified"] is False
    if share["status"] == "passed":
        assert accessibility["status"] == "passed", "Successful Share path lacks its actual compose audit"


def exact_owned_device(inventory: dict, name: str, before: set[str]) -> str:
    matches = [d["udid"] for d in inventory.get("devices", {}).get(RUNTIME, [])
               if d.get("name") == name and d["udid"] not in before
               and re.fullmatch(r"[A-Fa-f0-9-]{36}", d["udid"])]
    assert len(matches) == 1, "New simulator ownership is absent or ambiguous"
    return matches[0]


def create_owned(inventory: dict, device_type: str, folder: Path, report: dict) -> str:
    before = {d["udid"] for group in inventory.get("devices", {}).values() for d in group}
    name = "GSD-SystemSurfaces-he-" + os.environ["GITHUB_RUN_ID"] + "-" + uuid.uuid4().hex[:8]
    report["requested_simulator_name"] = name
    report["pre_create_simulator_ids"] = sorted(before)
    try:
        result = run(["xcrun", "simctl", "create", name, device_type, RUNTIME], folder / "create.log").strip()
    except (OSError, RuntimeError, subprocess.SubprocessError):
        # Reconcile an uncertain own create once; never repeat creation.
        try:
            current = json.loads(run(["xcrun", "simctl", "list", "--json"],
                                     folder / "create-reconciliation.json", timeout=60))
            report["owned_simulator_id"] = exact_owned_device(current, name, before)
            report["ownership_reconciled_after_create_error"] = True
        except (OSError, RuntimeError, subprocess.SubprocessError, AssertionError, ValueError):
            report["create_reconciliation"] = "No unambiguous new exact-name/runtime UUID established"
        raise
    if re.fullmatch(r"[A-Fa-f0-9-]{36}", result) and result not in before:
        report["owned_simulator_id"] = result
        report["ownership_source"] = "Successful own create response; inventory confirmation follows"
    current = json.loads(run(["xcrun", "simctl", "list", "--json"], folder / "created-inventory.json", timeout=60))
    owned = exact_owned_device(current, name, before)
    report["owned_simulator_id"] = owned
    assert result == owned, "simctl create output differs from observed owned device"
    return owned


def cleanup(device: str, output: Path, report: dict) -> None:
    errors = []
    for operation in ("shutdown", "delete"):
        try:
            run(["xcrun", "simctl", operation, device], output / "logs" / (operation + ".log"),
                timeout=120, check=operation == "delete")
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            errors.append(type(error).__name__ + ":" + operation)
    try:
        inventory = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"],
                                   output / "logs/final-devices.json", timeout=60))
        remaining = {d["udid"] for group in inventory["devices"].values() for d in group}
        report["created_simulator_removed"] = device not in remaining
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        errors.append(type(error).__name__ + ":final-inventory")
    report["cleanup_errors"] = errors
    assert report.get("created_simulator_removed") is True and not errors, "Owned simulator cleanup incomplete"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "logs").mkdir()
    report = {"source_sha": SOURCE, "compiled_product_run_id": PARENT_RUN, "build": BUILD,
        "harness_sha": os.environ["GITHUB_SHA"], "harness_run_id": os.environ["GITHUB_RUN_ID"],
        "parent_workflow_head": PARENT_WORKFLOW_HEAD,
        "parent_toolchain_reference": {
            "build": "Xcode 27.1 / 27A9275", "xctest_driver": "Xcode 27.0 / 27A266a",
            "native_artifact_id": 14923656158,
            "native_artifact_sha256": "7a9982bc82a7f15fffcac133bdddebb238c35893cf219c8e6c2eebfec15e08a4",
            "evidence": ["logs/build-for-testing.log", "logs/ui-test-driver.log"]},
        "diagnostic_only": True, "full_acceptance": False, "coverage_complete": False,
        "selected_tests": TESTS, "artifacts": {}, "execution_completed": False,
        "account_fixtures": 0, "scope": "one Hebrew simulator; real host discovery and source-defined text Share path only"}
    started = time.monotonic()
    device = None
    app = None
    prior_tree = None
    try:
        assert run(["git", "rev-parse", "HEAD"], output / "logs/harness-head.log").strip() == report["harness_sha"]
        toolchain = run(["xcodebuild", "-version"], output / "logs/toolchain.log").strip()
        assert toolchain == XCODE
        report["supplemental_toolchain"] = {
            "version": toolchain,
            "resolved_xcodebuild": run(["xcrun", "--find", "xcodebuild"],
                                      output / "logs/resolved-xcodebuild.log", timeout=30).strip(),
            "developer_dir": os.environ.get("DEVELOPER_DIR"),
            "scope": "managed xcode-27; this new test runner build and XCTest driver only"}
        assert re.fullmatch(r"[0-9a-f]{40}", report["harness_sha"]) and report["harness_run_id"].isdigit()
        subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, report["harness_sha"]],
                       check=True, capture_output=True, timeout=20)
        changed = subprocess.run(["git", "diff", "--name-only", SOURCE, report["harness_sha"]],
                                 check=True, capture_output=True, text=True, timeout=20).stdout.splitlines()
        allowed = {SWIFT.as_posix(), "scripts/gsd_system_surface_discovery.py",
                   ".github/workflows/gsd-system-surface-discovery.yml"}
        assert all(p in allowed or p.startswith("docs/ai-agent/") for p in changed), "App/build/dependency source changed"
        assert subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"],
                              check=True, capture_output=True, text=True, timeout=20).stdout == ""
        assert sha(SWIFT) == TEST_SOURCE_SHA256, "Reviewed supplemental Swift source differs"
        report["changed_paths"] = changed
        for helper in ("gsd_native_acceptance.py", "gsd_simulator_smoke.py", "resume_gsd_native_acceptance.py",
                       "verify_gsd_release_bundle.py", "gsd_appstore_connect.py"):
            expected = subprocess.run(["git", "show", SOURCE + ":scripts/" + helper],
                                      check=True, capture_output=True, timeout=20).stdout
            assert Path("scripts", helper).read_bytes() == expected, "Frozen source helper differs: " + helper
        app = restore(output, report)
        report["bundle_audit_before"] = audit_products(app, output)
        prior_tree = tree_digest(app)
        report["app_tree_before"] = prior_tree
        source = SWIFT.resolve()
        report["test_source_sha256"] = sha(source)
        spec = projection(source)
        verify_projection(spec, source)
        projected = output / "test-project"
        projected.mkdir()
        (projected / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
        run(["xcodegen", "generate", "--spec", str(projected / "project.json"),
             "--project", str(projected)], output / "logs/xcodegen.log")
        project = projected / "GSDSystemSurfaces.xcodeproj"
        text = (project / "project.pbxproj").read_text()
        assert "PBXTargetDependency" not in text and "XCRemoteSwiftPackageReference" not in text and "XCLocalSwiftPackageReference" not in text
        assert "PBXShellScriptBuildPhase" not in text and text.count("isa = PBXNativeTarget;") == 1
        assert text.count("productType = \"com.apple.product-type.bundle.ui-testing\";") == 1
        report["project_sha256"] = sha(project / "project.pbxproj")
        derived = output / "test-derived"
        environment = os.environ.copy()
        for secret in ("GH_TOKEN", "GITHUB_TOKEN"):
            environment.pop(secret, None)
        build_log = run(["xcodebuild", "build-for-testing", "-project", str(project), "-scheme", "GSDSystemSurfaces",
            "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
            "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES"],
            output / "logs/test-only-build.log", timeout=600, env=environment)
        verify_build_plan(build_log)
        assert tree_digest(app) == prior_tree, "App products changed while building test-only code"
        products = derived / "Build/Products"
        assert not list(products.rglob("GSD.app")) and not list(products.rglob("*.appex"))
        xctestruns = list(products.glob("*.xctestrun"))
        assert len(xctestruns) == 1
        report["new_test_runner_tree"] = tree_digest(products)
        test_configuration = plistlib.loads(xctestruns[0].read_bytes())
        assert not re.search(r"/GSD\.app(?:/|\")", json.dumps(test_configuration)), "Projected runner points at an app product"
        inventory = json.loads(run(["xcrun", "simctl", "list", "--json"], output / "logs/runtime-inventory.json"))
        runtime = next(r for r in inventory["runtimes"] if r["identifier"] == RUNTIME and r.get("isAvailable"))
        assert runtime["buildversion"] == RUNTIME_BUILD and runtime["version"] == "27.2"
        selected = devices_for_runtime(inventory, runtime)["iPhone"]
        device = create_owned(inventory, selected["identifier"], output / "logs", report)
        report["simulator"] = {"id": device, "runtime": RUNTIME, "runtime_build": RUNTIME_BUILD, "type": selected["identifier"]}
        # This is a new owned simulator only. Preserve unrelated preference keys.
        created = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"], output / "logs/created-device.json"))
        matches = [d for values in created["devices"].values() for d in values if d["udid"] == device]
        assert len(matches) == 1 and matches[0]["state"] == "Shutdown"
        data_path = Path(matches[0]["dataPath"]).resolve()
        assert data_path.name == "data" and data_path.parent.name.upper() == device.upper()
        preferences = data_path / "Library/Preferences/.GlobalPreferences.plist"
        values = plistlib.loads(preferences.read_bytes()) if preferences.exists() else {}
        values.update(AppleLanguages=["he"], AppleLocale="he_IL")
        preferences.parent.mkdir(parents=True, exist_ok=True)
        preferences.write_bytes(plistlib.dumps(values))
        boot_device(device, output / "logs/boot.log", report["simulator"])
        language = run(["xcrun", "simctl", "spawn", device, "defaults", "read", "-g", "AppleLanguages"],
                       output / "logs/os-languages.log").strip()
        locale = run(["xcrun", "simctl", "spawn", device, "defaults", "read", "-g", "AppleLocale"],
                     output / "logs/os-locale.log").strip()
        assert re.search(r"\bhe\b", language) and locale == "he_IL", "OS locale did not read back"
        report["os_locale"] = {"languages_readback": language, "locale_readback": locale,
                               "visual_system_host_locale": "pending actual screenshots"}
        run(["xcrun", "simctl", "install", device, str(app)], output / "logs/install.log", timeout=300)
        installed = Path(run(["xcrun", "simctl", "get_app_container", device, PHONE, "app"],
                             output / "logs/installed-path.log").strip())
        assert installed.is_absolute() and installed.name == "GSD.app"
        report["installed_app_tree"] = tree_digest(installed)
        assert tree_digest(installed) == prior_tree, "Installed app differs from validated product"
        run(["xcrun", "simctl", "listapps", device], output / "logs/installed-apps.plist")
        apps = json.loads(run(["plutil", "-convert", "json", "-o", "-", str(output / "logs/installed-apps.plist")],
                              output / "logs/installed-apps.json"))
        identifiers = sorted(k for k in apps if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]+", k))
        report["installed_bundle_ids"] = identifiers
        assert PHONE in identifiers
        artifacts = output / "ui"
        artifacts.mkdir()
        environment.update({
            "TEST_RUNNER_GSD_TEST_LANGUAGE": "he",
            "TEST_RUNNER_GSD_SYSTEM_SURFACE_ARTIFACTS": str(artifacts),
            "TEST_RUNNER_GSD_SYSTEM_INSTALLED_BUNDLE_IDS": json.dumps(identifiers),
            "TEST_RUNNER_GSD_SYSTEM_SURFACE_SIMULATOR_UDID": device,
        })
        report["setup_seconds"] = time.monotonic() - started
        assert report["setup_seconds"] <= 2400, "Setup budget exhausted; preserve cleanup instead of starting UI"
        result = output / "Results.xcresult"
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestruns[0]),
                   "-destination", "platform=iOS Simulator,id=" + device, "-destination-timeout", "90",
                   "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result),
                   "-testLanguage", "he", "-testRegion", "IL"]
        command.extend("-only-testing:GSDScreenshotTests/" + CLASS + "/" + test for test in TESTS)
        log = run(command, output / "logs/xcodebuild-system-surfaces.log", timeout=1200, env=environment)
        summary = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
                                 output / "test-summary.json", timeout=120))
        assert summary["totalTestCount"] == len(TESTS) and summary["failedTests"] == 0
        assert summary.get("expectedFailures", 0) == 0
        outcomes = {}
        for test in TESTS:
            matches = re.findall(r"(?im)^.*Test [Cc]ase.*\b" + re.escape(test) + r"\b.*\b(passed|failed|skipped)\b", log)
            assert len(matches) == 1 and matches[0].lower() in ("passed", "skipped")
            outcomes[test] = matches[0].lower()
        assert summary["passedTests"] == sum(v == "passed" for v in outcomes.values())
        assert summary["skippedTests"] == sum(v == "skipped" for v in outcomes.values())
        assert outcomes[TESTS[0]] == "passed", "Host discovery itself did not complete"
        observations = json.loads((artifacts / "system-surface-observations.json").read_text())
        verify_observations(observations, device, identifiers, outcomes)
        report.update(execution_completed=True, selected_test_outcomes=outcomes, observations=observations,
                      discovery_status="recorded", supplemental_acceptance="incomplete; inspect explicit per-surface observations")
    except (AssertionError, KeyError, OSError, RuntimeError, ValueError, StopIteration, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        report["error"] = type(error).__name__ + ": " + str(error)
    finally:
        result = output / "Results.xcresult"
        if result.exists() and not (output / "test-summary.json").exists():
            try:
                run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
                    output / "test-summary.json", timeout=120)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                report["summary_error"] = type(error).__name__
        if app is not None and prior_tree is not None:
            try:
                report["app_tree_after"] = tree_digest(app)
                assert report["app_tree_after"] == prior_tree
                report["app_products_unchanged"] = True
            except (AssertionError, OSError) as error:
                report.update(execution_completed=False, product_integrity_error=type(error).__name__)
        device = device or report.get("owned_simulator_id")
        if device and re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
            try:
                cleanup(device, output, report)
            except (AssertionError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                report.update(execution_completed=False, cleanup_error=type(error).__name__)
        report["timestamp"] = datetime.now(timezone.utc).isoformat()
        (output / "system-surface-discovery.json").write_text(json.dumps(report, indent=2) + "\n")
        print("GSD_SYSTEM_SURFACE_DISCOVERY_RECORDED" if report["execution_completed"] else "GSD_SYSTEM_SURFACE_DISCOVERY_FAILED", flush=True)
    return 0 if report["execution_completed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
