#!/usr/bin/env python3
"""Complete the two failed HE-iPad cases against immutable GSD48 app products.

The parent remains a failed run. Eleven proven case outcomes are inherited with
their original test source; only test01 and test02 are run by the corrected,
separately identified UI runner. No app, embedded target or package is rebuilt.
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
import struct
import subprocess
import sys
import time
import uuid
import zipfile

sys.dont_write_bytecode = True

from gsd_native_acceptance import run, redact
from gsd_simulator_smoke import devices_for_runtime
from resume_gsd_native_acceptance import api, sha, tree_digest, verify_restored
from verify_gsd_release_bundle import audit, BUNDLES
from gsd_appstore_connect import TEAM, APP_GROUP

SOURCE = "168b59aff816e39555acbf8535aaefaec19ee195"
PARENT_RUN = "45380356237"
PARENT_JOB = 138397478627
WORKFLOW = ".github/workflows/gsd-hanlin-agent-ios.yml"
BUILD = "48"
XCODE = "Xcode 27.1\nBuild version 27A9275"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
RUNTIME_BUILD = "24B8117"
PROJECT_HASH = "c2b6eac9e7526b9a07f46f4d4820b1eaaae20a024c5f0ec0742115fc5807cc10"
INNER_HASH = "90c9063b1b3142b9ecfbd426a0bd9b5abde3a8cec444e423953487a7740c4814"
ORIGINAL_TEST_BLOB = "d9d6fa16c3e87aa71c034960fa3a9d6e00e8c0ca"
TEST_SOURCE_SHA256 = "c00bf373f925489756c03321b38852e358e62639f1c38359dd6805bc28951584"
SWIFT = Path("ScreenshotTests/GSDCloudReleaseUITests.swift")
COMMON = ["test01LocalizedNavigationEditorChartsAndRTL", "test03LocalizedWidgetView",
          "test04LocalizedHanlinProvidersAndChatGPTAccount"]
CLOUD = "test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload"
RECOVERY = [COMMON[0], CLOUD]
PROFILES = [("iPhone", "en"), ("iPhone", "he"), ("iPad", "en"), ("iPad", "he")]
ARTIFACTS = {
    "native": (14918938042, "GSD-Native-Evidence-45380356237",
        "84d3bde819dc9960d6daa8a75664614f2763a914a558ad75227dfff15e7f87fc",
        "71b00bb88b197c90e6ee24adc1e19c8f7c51836813796a941976f4458d06922b", 192),
    "products": (14913034710, "GSD-Simulator-BuildProducts-45380356237",
        "bd4fc199d098f59bc4941ffa5e2bbe9b3474b3bfddd494e88441eadacb77b57b",
        "98213068b4994c3e95e68aa9929f3285d3040e1070bd7ea141d632ee0c5426df", 2),
    "project": (14919691738, "GSD-Generated-Project-45380356237",
        "d4dbb9ff42feb8b2ad605c0cfe349da04f4a73cb6bd18410a1e9179deca40a0a",
        "a12aa11da9aa6efdecfe534cb9b5255ad938d9e76de7c9390f5d074c0fd595bd", 9),
}
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
    18: "Sanitize retained native diagnostic text before upload",
    21: "Preserve localized generated project",
    22: "Preserve test summaries, screenshots and sanitized logs",
}


def read(path: Path) -> dict:
    return json.loads(path.read_bytes().decode("utf-8"))


def verify_parent(parent: dict, jobs: dict, artifacts: dict) -> None:
    assert (str(parent["id"]), parent["head_sha"], parent["path"], parent["run_attempt"]) == (
        PARENT_RUN, SOURCE, WORKFLOW, 1)
    assert parent["status"] == "completed" and parent["conclusion"] == "failure"
    assert jobs["total_count"] == len(jobs["jobs"])
    matching = [j for j in jobs["jobs"] if j["id"] == PARENT_JOB]
    assert len(matching) == 1
    job = matching[0]
    assert job["head_sha"] == SOURCE and job["run_attempt"] == 1
    assert job["status"] == "completed" and job["conclusion"] == "failure"
    steps = {step["number"]: step for step in job["steps"]}
    for number, name in REQUIRED_STEPS.items():
        assert steps[number]["name"] == name and steps[number]["conclusion"] == "success", name
    assert steps[17]["conclusion"] == "failure"
    assert steps[19]["conclusion"] == steps[20]["conclusion"] == "skipped"
    assert artifacts["total_count"] == len(artifacts["artifacts"])
    assert not any(a["name"] == "GSD-Native-Acceptance-Receipt-" + PARENT_RUN for a in artifacts["artifacts"])
    for identifier, name, digest, _, _ in ARTIFACTS.values():
        matches = [a for a in artifacts["artifacts"] if a["id"] == identifier and a["name"] == name]
        assert len(matches) == 1 and not matches[0]["expired"]
        a = matches[0]
        assert a["digest"] == "sha256:" + digest
        assert str(a["workflow_run"]["id"]) == PARENT_RUN and a["workflow_run"]["head_sha"] == SOURCE


def safe_archive(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        items = archive.infolist()
        assert len(items) <= 20000 and sum(i.file_size for i in items) <= 2_000_000_000
        assert len({i.filename for i in items}) == len(items), "Duplicate archive member"
        for item in items:
            name = PurePosixPath(item.filename)
            assert not name.is_absolute() and ".." not in name.parts and "\\" not in item.filename
            assert not stat.S_ISLNK(item.external_attr >> 16), "Unexpected artifact symlink"


def download(kind: str, temporary: Path, logs: Path) -> Path:
    identifier, _, digest, tree, count = ARTIFACTS[kind]
    archive = temporary / (kind + ".zip")
    with archive.open("xb") as stream:
        result = subprocess.run(["gh", "api", "repos/davidpovarsky/gsd-iosapp/actions/artifacts/"
                                 + str(identifier) + "/zip"], stdout=stream,
                                stderr=subprocess.PIPE, timeout=210)
    assert result.returncode == 0, "Authenticated artifact read failed"
    assert sha(archive) == digest, "Actual outer artifact hash differs"
    safe_archive(archive)
    directory = temporary / kind
    run(["ditto", "-x", "-k", str(archive), str(directory)], logs / ("extract-" + kind + ".log"), timeout=120)
    assert tree_digest(directory) == (tree, count), "Extracted artifact bytes differ: " + kind
    return directory


def outcomes(directory: Path, tests: list[str], expected: dict[str, str], simulator: str) -> dict:
    log = (directory / "xcodebuild.log").read_bytes().decode("utf-8")
    observed = {}
    all_terminals = re.findall(r"(?im)^.*Test [Cc]ase.*\b(test\d+\w+)\b.*\b(passed|failed)\b", log)
    assert len(all_terminals) == len(tests) and {n for n, _ in all_terminals} == set(tests)
    for test in tests:
        values = [value.lower() for name, value in all_terminals if name == test]
        assert values == [expected[test]], "Missing, duplicate or incorrect terminal outcome: " + test
        observed[test] = values[0]
    summary = read(directory / "test-summary.json")
    passed = sum(v == "passed" for v in expected.values())
    failed = len(tests) - passed
    assert summary["totalTestCount"] == len(tests)
    assert summary["passedTests"] == passed and summary["failedTests"] == failed
    assert summary["skippedTests"] == summary["expectedFailures"] == 0
    assert summary["result"] == ("Failed" if failed else "Passed")
    failures = summary["testFailures"]
    names = {f["testIdentifierString"] for f in failures}
    assert names == {"GSDCloudReleaseUITests/" + t + "()" for t in tests if expected[t] == "failed"}
    assert all(f["targetName"] == "GSDScreenshotTests" for f in failures)
    configurations = summary["devicesAndConfigurations"]
    assert len(configurations) == 1
    device = configurations[0]["device"]
    assert device["osBuildNumber"] == RUNTIME_BUILD and device["deviceId"] == simulator
    return {"outcomes": observed, "summary": summary, "log": log}


def verify_inherited(native: Path) -> tuple[dict, dict, list[dict]]:
    ui = read(native / "ui/native-ui-receipt.json")
    assert ui["passed"] is False and ui["profile"] == "native-release"
    assert [(p["family"], p["language"]) for p in ui["runs"]] == PROFILES
    inherited = []
    for profile in ui["runs"]:
        family, language = profile["family"], profile["language"]
        cloud = (family, language) == ("iPad", "he")
        tests = COMMON + ([CLOUD] if cloud else [])
        expected = {test: ("failed" if cloud and test in RECOVERY else "passed") for test in tests}
        assert profile["runtime"] == "27.2" and profile["cloudRoundTrip"] is cloud
        assert profile["selectedTests"] == tests and profile["passed"] is (not cloud)
        assert not profile.get("cleanupErrors")
        folder = native / "ui" / (family.lower() + "-" + language)
        checked = outcomes(folder, tests, expected, profile["simulatorId"])
        assert (folder / "shutdown.log").read_bytes().strip() == b""
        assert (folder / "delete.log").read_bytes().strip() == b""
        if not cloud:
            assert profile["verifiedPassedTests"] == tests
        else:
            failures = {f["testIdentifierString"]: f["failureText"] for f in checked["summary"]["testFailures"]}
            assert "Context menu did not dismiss" in failures["GSDCloudReleaseUITests/" + COMMON[0] + "()"]
            assert "Valid native signup must enable submission" in failures["GSDCloudReleaseUITests/" + CLOUD + "()"]
            assert "GSD_NATIVE_ACCOUNT_DELETION_PUBLIC_PASS" not in checked["log"]
        for test, result in expected.items():
            if result == "passed":
                inherited.append({"family": family, "language": language, "test": test, "outcome": "passed",
                    "run_id": PARENT_RUN, "test_source_git_blob": ORIGINAL_TEST_BLOB,
                    "app_source_sha": SOURCE, "simulator_id": profile["simulatorId"],
                    "runtime_build": RUNTIME_BUILD, "evidence_directory": "inherited/ui/" + family.lower() + "-" + language,
                    "cleanup": "Parent checked simctl delete returned success; shutdown/delete output empty; final membership unobserved"})
    assert len(inherited) == 11
    for filename, markers in {
        "session-observation.log": ["SESSION_OBSERVATION_RESULT passed=13 failed=0"],
        "sync-connectivity.log": ["SYNC_CONNECTIVITY_RESULT passed=8 failed=0"],
        "hanlin-tests.log": ["Executed 7 tests, with 0 failures", "Test run with 13 tests in 1 suite passed"],
        "cloud-sync-tests.log": ["Test run with 3 tests in 1 suite passed", "Test run with 94 tests in 7 suites passed",
                                 "Test run with 4 tests in 1 suite passed"],
        "account-deletion-tests.log": ["Test run with 18 tests in 2 suites passed"],
    }.items():
        text = (native / "logs" / filename).read_bytes().decode("utf-8")
        assert all(marker in text for marker in markers), "Inherited gate missing: " + filename
    compiler = set(re.findall(r"--xcode-version[ =]+([A-Za-z0-9]+)",
                             (native / "logs/build-for-testing.log").read_bytes().decode("utf-8")))
    assert compiler == {"27A9275"}
    bundles = read(native / "compiled-bundles.json")
    assert bundles["passed"] is True and len(bundles["targets"]) == 5
    assert {t["bundleId"] for t in bundles["targets"]} == set(BUNDLES)
    assert all((t["version"], t["build"]) == ("4.1.0", BUILD) for t in bundles["targets"])
    entitlements = read(native / "logs/simulator-entitlements.json")
    assert entitlements["passed"] is True and entitlements["source_sha"] == SOURCE
    assert entitlements["simulator_only"] is True
    assert entitlements["entitlement_source"] == "Mach-O __TEXT,__entitlements"
    assert len(entitlements["targets"]) == 5
    assert {t["bundleId"] for t in entitlements["targets"]} == set(BUNDLES)
    for target in entitlements["targets"]:
        assert target["runtimeEntitlements"]["application-identifier"] == TEAM + "." + target["bundleId"]
        assert target["runtimeEntitlements"]["com.apple.security.application-groups"] == [APP_GROUP]
    return ui, bundles, inherited


def verify_products(directory: Path) -> Path:
    manifest = read(directory / "simulator-build.json")
    assert (manifest["source_sha"], manifest["run_id"], manifest["build"]) == (SOURCE, PARENT_RUN, BUILD)
    assert manifest["simulator_only"] is True and manifest["build_for_testing_completed"] is True
    assert manifest["archive"] == "GSD-Simulator-BuildProducts.zip" and manifest["sha256"] == INNER_HASH
    archive = directory / manifest["archive"]
    assert sha(archive) == INNER_HASH
    safe_archive(archive)
    with zipfile.ZipFile(archive) as entries:
        assert [n for n in entries.namelist() if n.endswith(".xctestrun")] == [
            "Products/GSDScreenshots_iphonesimulator27.1-arm64.xctestrun"]
    return archive


def verify_harness() -> dict:
    head = subprocess.run(["git", "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    assert head == os.environ["GITHUB_SHA"] and re.fullmatch(r"[0-9a-f]{40}", head)
    original = subprocess.run(["git", "rev-parse", SOURCE + ":" + SWIFT.as_posix()],
                              check=True, capture_output=True, text=True).stdout.strip()
    assert original == ORIGINAL_TEST_BLOB
    assert re.fullmatch(r"[0-9a-f]{64}", TEST_SOURCE_SHA256) and sha(SWIFT) == TEST_SOURCE_SHA256
    allowed = {SWIFT.as_posix(), WORKFLOW, "scripts/complete_gsd_he_acceptance.py",
               "scripts/sanitize_gsd_native_diagnostics.py"}
    paths = subprocess.run(["git", "diff", "--name-only", SOURCE, head],
                           check=True, capture_output=True, text=True).stdout.splitlines()
    assert all(p in allowed or p.startswith("docs/ai-agent/") for p in paths), "App/build/dependency source changed"
    assert subprocess.run(["git", "status", "--porcelain"], check=True, capture_output=True, text=True).stdout == ""
    return {"harness_sha": head, "corrected_test_source_sha256": TEST_SOURCE_SHA256,
            "original_test_source_git_blob": original, "changed_paths": paths}

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
    return {"name": "GSDHERecovery", "options": {"deploymentTarget": {"iOS": "27.0"}},
        "targets": {"GSDScreenshotTests": {"type": "bundle.ui-testing", "platform": "iOS",
            "sources": [str(source.resolve())], "dependencies": [],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.itorah.gsd.screenshot-tests",
                "SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES",
                "CURRENT_PROJECT_VERSION": BUILD, "MARKETING_VERSION": "4.1.0",
                "SUPPORTED_PLATFORMS": "iphonesimulator", "TARGETED_DEVICE_FAMILY": "1,2",
                "CODE_SIGN_IDENTITY": "-", "CODE_SIGNING_ALLOWED": "YES"}}}},
        "schemes": {"GSDHERecovery": {"build": {"targets": {"GSDScreenshotTests": ["testing"]},
              "buildImplicitDependencies": False},
              "test": {"config": "Debug", "targets": ["GSDScreenshotTests"]}}}}


def verify_projection(spec: dict, source: Path) -> None:
    assert set(spec["targets"]) == {"GSDScreenshotTests"} and not spec.get("packages")
    target = spec["targets"]["GSDScreenshotTests"]
    assert target["type"] == "bundle.ui-testing" and target["platform"] == "iOS"
    assert target["sources"] == [str(source.resolve())] and not target["dependencies"]
    assert "TEST_TARGET_NAME" not in target["settings"]["base"] and "TEST_HOST" not in target["settings"]["base"]
    scheme = spec["schemes"]["GSDHERecovery"]
    assert scheme["build"] == {"targets": {"GSDScreenshotTests": ["testing"]}, "buildImplicitDependencies": False}
    assert scheme["test"]["targets"] == ["GSDScreenshotTests"]
    text = source.read_text()
    imports = re.findall(r"(?m)^\s*import\s+(\w+)", text)
    assert imports and set(imports).issubset({"Foundation", "UIKit", "XCTest"})
    assert not re.search(r"XCUIApplication\s*\(\s*\)", text)
    assert "com.itorah.gsd" in text


def verify_build_plan(text: str) -> None:
    headings = re.findall(r"(?m)^\s*Target '([^']+)' in project '([^']+)'", text)
    assert headings and set(headings) == {("GSDScreenshotTests", "GSDHERecovery")}, "Unexpected target in test-only build"
    assert not re.search(r"CompileSwift.*(?:GSDKit|Hanlin)", text, re.I), "Unexpected package compilation"
    assert "** TEST BUILD SUCCEEDED **" in text



def exact_owned_device(inventory: dict, name: str, before: set[str]) -> str:
    matches = [d["udid"] for d in inventory.get("devices", {}).get(RUNTIME, [])
               if d.get("name") == name and d["udid"] not in before
               and re.fullmatch(r"[A-Fa-f0-9-]{36}", d["udid"])]
    assert len(matches) == 1, "New simulator ownership is absent or ambiguous"
    return matches[0]


def create_owned(inventory: dict, device_type: str, folder: Path, report: dict) -> str:
    before = {d["udid"] for group in inventory.get("devices", {}).values() for d in group}
    name = "GSD48-he-recovery-" + os.environ["GITHUB_RUN_ID"] + "-" + uuid.uuid4().hex[:8]
    report["requested_simulator_name"] = name
    try:
        result = run(["xcrun", "simctl", "create", name, device_type, RUNTIME], folder / "create.log").strip()
    except (OSError, RuntimeError, subprocess.SubprocessError):
        # A failed/uncertain create can still have created the requested device.
        # Reconcile once, never repeat creation or adopt an existing/other device.
        try:
            current = json.loads(run(["xcrun", "simctl", "list", "--json"], folder / "create-reconciliation.json", timeout=60))
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


def cleanup_owned(device: str | None, folder: Path, report: dict) -> None:
    errors = []
    if device:
        for action in ("shutdown", "delete"):
            try:
                run(["xcrun", "simctl", action, device], folder / (action + ".log"), timeout=90)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                errors.append({"action": action, "type": type(error).__name__})
        try:
            final = json.loads(run(["xcrun", "simctl", "list", "--json"], folder / "final-inventory.json", timeout=60))
            remaining = {d["udid"] for group in final.get("devices", {}).values() for d in group}
            assert device not in remaining, "Owned simulator remains after deletion"
            report["owned_simulator_absent"] = True
        except (OSError, RuntimeError, subprocess.SubprocessError, AssertionError, ValueError) as error:
            errors.append({"action": "verify-absence", "type": type(error).__name__})
    report["cleanup_errors"] = errors
    if errors:
        raise RuntimeError("Owned simulator cleanup failed")


def build_runner(temporary: Path, output: Path, app: Path, immutable_tree: tuple) -> Path:
    projected = temporary / "test-project"
    projected.mkdir()
    spec = projection(SWIFT)
    verify_projection(spec, SWIFT)
    (projected / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
    run(["xcodegen", "generate", "--spec", str(projected / "project.json"),
         "--project", str(projected)], output / "logs/test-project-generation.log", timeout=120)
    derived = temporary / "test-derived"
    log = run(["xcodebuild", "-project", str(projected / "GSDHERecovery.xcodeproj"),
               "-scheme", "GSDHERecovery", "-configuration", "Debug",
               "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
               "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
               "CURRENT_PROJECT_VERSION=" + BUILD, "build-for-testing"],
              output / "logs/test-only-build.log", timeout=900)
    verify_build_plan(log)
    assert tree_digest(app) == immutable_tree, "Immutable app changed during test-only build"
    products = derived / "Build/Products"
    assert not list(products.rglob("*.appex")), "An extension was built by test-only projection"
    apps = list(products.rglob("*.app"))
    assert len(apps) == 1 and apps[0].name == "GSDScreenshotTests-Runner.app"
    test = apps[0] / "PlugIns/GSDScreenshotTests.xctest"
    info = plistlib.loads((test / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "com.itorah.gsd.screenshot-tests"
    assert info["DTXcodeBuild"] == "27A9275" and info["CFBundleVersion"] == BUILD
    run(["codesign", "--verify", "--deep", "--strict", str(apps[0])], output / "logs/new-runner-signature.log")
    files = list(products.glob("*.xctestrun"))
    assert len(files) == 1
    (output / "corrected-test-build.json").write_text(json.dumps({
        "harness_sha": os.environ["GITHUB_SHA"], "test_source_sha256": TEST_SOURCE_SHA256,
        "test_executable_sha256": sha(test / info["CFBundleExecutable"]),
        "xctestrun_sha256": sha(files[0]), "app_source_sha": SOURCE,
        "app_tree_unchanged": True, "build_scope": "GSDScreenshotTests only"}, indent=2) + "\n")
    return files[0]


def execute_recovery(xctestrun: Path, app: Path, output: Path, inventory: dict, report: dict) -> dict:
    folder = output / "ui/ipad-he-recovery"; folder.mkdir(parents=True)
    runtime = next(r for r in inventory["runtimes"] if r["identifier"] == RUNTIME and r["isAvailable"])
    assert runtime["buildversion"] == RUNTIME_BUILD and runtime["version"] == "27.2"
    devices = devices_for_runtime(inventory, runtime)
    assert "iPad" in devices
    checked = None
    try:
        device = create_owned(inventory, devices["iPad"]["identifier"], folder, report)
        run(["xcrun", "simctl", "boot", device], folder / "boot.log")
        run(["xcrun", "simctl", "bootstatus", device, "-b"], folder / "bootstatus.log", timeout=300)
        run(["xcrun", "simctl", "install", device, str(app)], folder / "install.log", timeout=300)
        installed = Path(run(["xcrun", "simctl", "get_app_container", device, "com.itorah.gsd", "app"],
                             folder / "installed-app-path.log").strip())
        assert tree_digest(installed) == tree_digest(app), "Installed app bytes differ from restored signed products"
        report["installed_app_tree_verified"] = True
        environment = os.environ.copy()
        for name in ("GH_TOKEN", "GITHUB_TOKEN"):
            environment.pop(name, None)
        environment.update({
            "TEST_RUNNER_GSD_TEST_LANGUAGE": "he",
            "TEST_RUNNER_GSD_SCREENSHOT_DIR": str(folder / "screenshots"),
            "TEST_RUNNER_GSD_CLOUD_SYSTEM_TEST": "1",
            "TEST_RUNNER_GSD_CLOUD_TEST_BASE": os.environ["GSD_CLOUD_TEST_BASE"]})
        run(["curl", "--fail", "--silent", "--show-error", "--max-time", "30",
             os.environ["GSD_CLOUD_TEST_BASE"].rstrip("/") + "/api/health"],
            output / "logs/recovery-cloud-health.json", env=environment, timeout=40)
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                   "-destination", "platform=iOS Simulator,id=" + device,
                   "-destination-timeout", "90", "-parallel-testing-enabled", "NO",
                   "-resultBundlePath", str(folder / "Results.xcresult"), "-testLanguage", "he", "-testRegion", "IL"]
        command += ["-only-testing:GSDScreenshotTests/GSDCloudReleaseUITests/" + test for test in RECOVERY]
        report["selected_tests"] = RECOVERY
        run(command, folder / "xcodebuild.log", timeout=1800, env=environment)
        run(["xcrun", "xcresulttool", "get", "test-results", "summary",
             "--path", str(folder / "Results.xcresult")], folder / "test-summary.json")
        checked = outcomes(folder, RECOVERY, {test: "passed" for test in RECOVERY}, device)
        report["fresh_cases_passed"] = RECOVERY
    finally:
        result = folder / "Results.xcresult"
        diagnostics_error = None
        if result.exists() and not (folder / "test-summary.json").exists():
            try:
                run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                     "--path", str(result)], folder / "test-summary.json")
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                diagnostics_error = type(error).__name__
                report["summary_error"] = diagnostics_error
        cleanup_owned(report.get("owned_simulator_id"), folder, report)
        if diagnostics_error:
            raise RuntimeError("Recovery test summary could not be retained")
    assert checked is not None and report["owned_simulator_absent"] is True
    owners = set(re.findall(r"GSD_NATIVE_ACCOUNT_DELETION_PUBLIC_PASS owner=([A-Za-z0-9]{15})(?![A-Za-z0-9])",
                           checked["log"]))
    assert len(owners) == 1, "Missing or ambiguous fresh native account deletion public proof"
    return {"simulator_id": report["owned_simulator_id"], "runtime_build": RUNTIME_BUILD,
            "native_deletion_public_owner": owners.pop(), "summary": checked["summary"]}


def compose(inherited: list[dict], fresh: dict, run_id: str, harness: dict) -> dict:
    assert len(inherited) == 11
    cases = list(inherited)
    for test in RECOVERY:
        cases.append({"family": "iPad", "language": "he", "test": test, "outcome": "passed",
            "run_id": run_id, "harness_sha": harness["harness_sha"],
            "test_source_sha256": TEST_SOURCE_SHA256, "app_source_sha": SOURCE,
            "simulator_id": fresh["simulator_id"], "runtime_build": RUNTIME_BUILD,
            "evidence_directory": "ui/ipad-he-recovery",
            "cleanup": "Independent shutdown/delete attempts succeeded and owned UUID absent in final inventory"})
    expected = {(family, lang, test) for family, lang in PROFILES
                for test in COMMON + ([CLOUD] if (family, lang) == ("iPad", "he") else [])}
    actual = [(c["family"], c["language"], c["test"]) for c in cases]
    assert len(cases) == 13 and len(set(actual)) == 13 and set(actual) == expected
    assert all(c["outcome"] == "passed" and c["app_source_sha"] == SOURCE and c["runtime_build"] == RUNTIME_BUILD for c in cases)
    assert sum(c["run_id"] == PARENT_RUN for c in cases) == 11
    assert {(c["family"], c["language"], c["test"]) for c in cases if c["run_id"] == run_id} == {
        ("iPad", "he", test) for test in RECOVERY}
    profiles = []
    for family, language in PROFILES:
        cloud = (family, language) == ("iPad", "he")
        tests = COMMON + ([CLOUD] if cloud else [])
        selected = [c for c in cases if (c["family"], c["language"]) == (family, language)]
        profiles.append({"family": family, "language": language, "runtime": "27.2", "passed": True,
            "cloudRoundTrip": cloud, "selectedTests": tests, "verifiedPassedTests": tests,
            "caseEvidence": selected, "evidence_run_ids": sorted({c["run_id"] for c in selected}),
            "composition": "Cases retain their actual test source, run and simulator; no parent receipt is rewritten"})
    assert re.fullmatch(r"[A-Za-z0-9]{15}", fresh["native_deletion_public_owner"])
    return {"passed": True, "profile": "native-release", "runs": profiles,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "composition": "same-app-eleven-parent-cases-and-two-corrected-he-cases",
        "native_deletion_public_owner": fresh["native_deletion_public_owner"],
        "oracle_zero_row_verification": "pending independent root read"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    logs = output / "logs"; logs.mkdir(exist_ok=True)
    report = {"passed": False, "source_sha": SOURCE, "compiled_product_run_id": PARENT_RUN,
              "parent_conclusion": "failure", "parent_ui_passed": False,
              "run_id": os.environ.get("GITHUB_RUN_ID"), "harness_sha": os.environ.get("GITHUB_SHA"),
              "inherited_cases": 11, "required_fresh_cases": RECOVERY, "no_app_rebuild": True}
    started = time.monotonic()
    try:
        assert os.environ["GSD_SOURCE_SHA"] == SOURCE and os.environ["GSD_BUILD_NUMBER"] == BUILD
        run_id = os.environ["GITHUB_RUN_ID"]
        assert run_id.isdigit() and run_id != PARENT_RUN
        harness = verify_harness(); report.update(harness)
        assert run(["xcodebuild", "-version"], logs / "toolchain.log").strip() == XCODE
        parent = api("actions/runs/" + PARENT_RUN)
        jobs = api("actions/runs/" + PARENT_RUN + "/jobs?per_page=100")
        entries = api("actions/runs/" + PARENT_RUN + "/artifacts?per_page=100")
        verify_parent(parent, jobs, entries)
        temporary = Path(os.environ["RUNNER_TEMP"]) / ("gsd48-he-recovery-" + run_id)
        temporary.mkdir(exist_ok=False)
        downloaded = {kind: download(kind, temporary, logs) for kind in ARTIFACTS}
        native = downloaded["native"]
        parent_ui, bundles, inherited = verify_inherited(native)
        assert sha(downloaded["project"] / "GSD.xcodeproj/project.pbxproj") == PROJECT_HASH
        archive = verify_products(downloaded["products"])
        restored = temporary / "restored"
        run(["ditto", "-x", "-k", str(archive), str(restored)], logs / "restore-products.log")
        report["original_compiled_products"] = verify_restored(restored / "Products", logs)
        app = restored / "Products/Debug-iphonesimulator/GSD.app"
        before = audit_products(app, output)
        report["restored_five_bundle_audit"] = before
        immutable_tree = tree_digest(app)
        # Retain original false receipt and individual original outcomes without
        # mutating them into a fabricated successful parent.
        shutil.copytree(native, output / "inherited")
        report["inherited_artifacts"] = {kind: {"artifact_id": a[0], "outer_zip_sha256": a[2],
            "original_extracted_tree_sha256": a[3], "original_files": a[4]} for kind, a in ARTIFACTS.items()}
        xctestrun = build_runner(temporary, output, app, immutable_tree)
        assert tree_digest(app) == immutable_tree
        inventory = json.loads(run(["xcrun", "simctl", "list", "--json"], logs / "runtime-inventory.json"))
        assert time.monotonic() - started <= 2100, "Recovery preparation exhausted its bounded setup budget"
        fresh = execute_recovery(xctestrun, app, output, inventory, report)
        after = audit_products(app, output)
        assert after == before and tree_digest(app) == immutable_tree, "Original app or embedded target bytes changed"
        combined = compose(inherited, fresh, run_id, harness)
        (output / "ui/native-ui-receipt.json").write_text(json.dumps(combined, indent=2) + "\n")
        packages = {"passed": True, "mode": "verified-parent-steps-and-hashed-logs",
            "current_source_sha": SOURCE, "source_sha": SOURCE, "run_id": PARENT_RUN,
            "parent_conclusion": "failure", "scope": "Only successful package gates inherited; whole parent UI failed"}
        receipt = {"passed": True, "source_sha": SOURCE, "build": BUILD, "run_id": run_id,
            "workflow": WORKFLOW, "generated_project_sha256": PROJECT_HASH,
            "hanlin_lock_sha256": sha(Path("HanlinSDK.lock.json")), "ui": combined, "bundles": bundles,
            "package_contracts": packages, "compiled_product_run_id": PARENT_RUN,
            "compiled_product_sha256": INNER_HASH, "harness_sha": harness["harness_sha"],
            "corrected_test_source_sha256": TEST_SOURCE_SHA256, "inherited_parent_conclusion": "failure"}
        (output / "native-acceptance.json").write_text(json.dumps(receipt, indent=2) + "\n")
        report["passed"] = True
        print("GSD_NATIVE_ACCOUNT_DELETION_PUBLIC_PASS owner=" + combined["native_deletion_public_owner"], flush=True)
        print("GSD_NATIVE_UI_ALL_FOUR_PASS source=" + SOURCE + " inherited_cases=11 fresh_cases=2", flush=True)
    except BaseException as error:
        report["error_type"] = type(error).__name__
        raise
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (output / "he-recovery-provenance.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
