#!/usr/bin/env python3
"""Launch the already validated Watch binary without rebuilding product code."""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import time
import uuid
import zipfile

from gsd_simulator_smoke import boot_device, devices_for_runtime, run, version

REPOSITORY = "davidpovarsky/gsd-iosapp"
WORKFLOW = ".github/workflows/gsd-hanlin-agent-ios.yml"
PHONE = "com.itorah.gsd"
WATCH = PHONE + ".watchkitapp"
LANGUAGES = (("en", "en_US"), ("he", "he_IL"))

# One reviewed recovery may validate the original compiled source on a distinct
# harness commit. Preserve both identities; never treat its cancelled build
# parent as a successful complete acceptance run.
COMPOSED_SOURCE = "37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc"
COMPOSED_HARNESS = "c9ee902768fcbf5828d9cfc436e0b739b9ae8a6d"
COMPOSED_PRODUCT_RUN = "45343781703"
COMPOSED_PRODUCT_ARTIFACT = 14897632059
COMPOSED_OUTER_HASH = "0396371b6530b09d0d405df887291f248193813e58986f734a58b11bb87749c5"
COMPOSED_INNER_HASH = "14cd82477fd8956d9d4f173ee98aa10d26244857f1b5fd8b73a23ad4c1c6be9b"


def api(path: str) -> dict:
    result = subprocess.run(["gh", "api", "repos/" + REPOSITORY + "/" + path],
                            capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"GitHub read failed (exit={result.returncode})")
    return json.loads(result.stdout)


def verify_parent(receipt: dict, source: str, run_id: str, build: str) -> None:
    assert receipt["passed"] is True and receipt["workflow"] == WORKFLOW
    assert (receipt["source_sha"], receipt["run_id"], receipt["build"]) == (source, run_id, build)
    ui = receipt["ui"]
    assert ui["passed"] is True and ui["profile"] == "native-release"
    profiles = ui["runs"]
    assert len(profiles) == 4 and {(r["family"], r["language"]) for r in profiles} == {
        (family, language) for family in ("iPhone", "iPad") for language in ("en", "he")}
    assert all(r["passed"] is True for r in profiles)
    cloud = [r for r in profiles if r["cloudRoundTrip"] is True]
    assert len(cloud) == 1 and (cloud[0]["family"], cloud[0]["language"]) == ("iPad", "he")
    assert "test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload" in cloud[0]["verifiedPassedTests"]


def verify_archive(directory: Path, source: str, run_id: str, build: str) -> dict:
    manifest = json.loads((directory / "simulator-build.json").read_text())
    assert (manifest["source_sha"], manifest["run_id"], manifest["build"]) == (source, run_id, build)
    assert manifest["simulator_only"] is True and manifest["build_for_testing_completed"] is True
    assert manifest["archive"] == "GSD-Simulator-BuildProducts.zip"
    archive = directory / manifest["archive"]
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert digest == manifest["sha256"], "Compiled product archive digest mismatch"
    with zipfile.ZipFile(archive) as contents:
        assert len(contents.infolist()) <= 20000
        assert sum(item.file_size for item in contents.infolist()) <= 2_000_000_000
        for item in contents.infolist():
            path = PurePosixPath(item.filename)
            assert not path.is_absolute() and ".." not in path.parts, "Unsafe archive path"
            assert not stat.S_ISLNK(item.external_attr >> 16), "Unexpected product archive symlink"
    return manifest


def product_run_for_validation(parent: dict, receipt: dict, source: str, run_id: str, build: str) -> str:
    assert parent["status"] == "completed" and parent["conclusion"] == "success", "Validation must succeed first"
    assert parent["path"] == WORKFLOW and str(parent["id"]) == run_id
    verify_parent(receipt, source, run_id, build)
    if parent["head_sha"] == source:
        assert receipt.get("compiled_product_run_id", run_id) == run_id, "Ordinary validation must own its products"
        return run_id
    assert source == COMPOSED_SOURCE and parent["head_sha"] == COMPOSED_HARNESS
    assert receipt["harness_sha"] == parent["head_sha"] and parent["run_attempt"] == 1
    assert receipt["compiled_product_run_id"] == COMPOSED_PRODUCT_RUN
    assert receipt["compiled_product_sha256"] == COMPOSED_INNER_HASH
    assert receipt["inherited_parent_conclusion"] == "cancelled"
    total = 0
    for profile in receipt["ui"]["runs"]:
        tests = ["test01LocalizedNavigationEditorChartsAndRTL", "test03LocalizedWidgetView",
                 "test04LocalizedHanlinProvidersAndChatGPTAccount"]
        if (profile["family"], profile["language"]) == ("iPad", "he"):
            tests.append("test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload")
        assert profile["selectedTests"] == tests and profile["verifiedPassedTests"] == tests
        assert profile["source_sha"] == source
        assert profile["evidence_run_id"] == (COMPOSED_PRODUCT_RUN if profile["family"] == "iPhone" else run_id)
        total += len(tests)
    assert total == 13
    return COMPOSED_PRODUCT_RUN


def retrieve_products(args: argparse.Namespace, report: dict) -> Path:
    parent = api("actions/runs/" + args.run_id)
    assert parent["status"] == "completed" and parent["conclusion"] == "success", "Parent must succeed first"
    assert parent["path"] == WORKFLOW
    validation_entries = api("actions/runs/" + args.run_id + "/artifacts?per_page=100")["artifacts"]
    receipt_name = "GSD-Native-Acceptance-Receipt-" + args.run_id
    receipts = [a for a in validation_entries if a["name"] == receipt_name and not a["expired"]]
    assert len(receipts) == 1 and str(receipts[0]["workflow_run"]["id"]) == args.run_id
    assert receipts[0]["workflow_run"]["head_sha"] == parent["head_sha"]
    downloaded = args.output / "download"
    run(["gh", "run", "download", args.run_id, "--repo", REPOSITORY, "--name", receipt_name,
         "--dir", str(downloaded / "receipt")], args.output / "retrieval.log")
    receipt = json.loads((downloaded / "receipt/native-acceptance.json").read_text())
    product_run = product_run_for_validation(parent, receipt, args.source_sha, args.run_id, args.build)
    composed = product_run != args.run_id
    product_parent = api("actions/runs/" + product_run) if composed else parent
    assert product_parent["status"] == "completed" and product_parent["head_sha"] == args.source_sha
    assert product_parent["path"] == WORKFLOW
    if composed:
        assert product_parent["conclusion"] == "cancelled" and product_parent["run_attempt"] == 1
    entries = api("actions/runs/" + product_run + "/artifacts?per_page=100")["artifacts"] if composed else validation_entries
    name = "GSD-Simulator-BuildProducts-" + product_run
    artifacts = [a for a in entries if a["name"] == name and not a["expired"]]
    assert len(artifacts) == 1 and artifacts[0]["workflow_run"]["head_sha"] == args.source_sha
    assert str(artifacts[0]["workflow_run"]["id"]) == product_run
    if composed:
        assert artifacts[0]["id"] == COMPOSED_PRODUCT_ARTIFACT
        assert artifacts[0]["digest"] == "sha256:" + COMPOSED_OUTER_HASH
    helper = api("contents/scripts/gsd_simulator_smoke.py?ref=" + args.source_sha)
    expected = hashlib.sha256(base64.b64decode(helper["content"])).hexdigest()
    actual = hashlib.sha256(Path(__file__).with_name("gsd_simulator_smoke.py").read_bytes()).hexdigest()
    assert expected == actual, "Existing simulator helper differs from compiled source"
    run(["gh", "run", "download", product_run, "--repo", REPOSITORY, "--name", name,
         "--dir", str(downloaded / "products")], args.output / "retrieval.log")
    manifest = verify_archive(downloaded / "products", args.source_sha, product_run, args.build)
    if composed:
        assert manifest["sha256"] == COMPOSED_INNER_HASH == receipt["compiled_product_sha256"]
    report["provenance"] = {"source_sha": args.source_sha, "native_run_id": args.run_id,
        "validation_head_sha": parent["head_sha"], "compiled_product_run_id": product_run,
        "compiled_product_run_conclusion": product_parent["conclusion"], "composed_acceptance": composed,
        "build": args.build, "artifact_id": artifacts[0]["id"],
        "github_artifact_digest": artifacts[0].get("digest"), "product_zip_sha256": manifest["sha256"],
        "simulator_helper_sha256": actual, "parent_native_receipt_verified": True}
    run(["ditto", "-x", "-k", str(downloaded / "products" / manifest["archive"]),
         str(args.output / "products")], args.output / "retrieval.log")
    return args.output / "products/Products"


def inspect_bundles(products: Path, build: str, log: Path) -> dict:
    bundles = {}
    for family, folder, identifier, platform in (
            ("phone", "Debug-iphonesimulator/GSD.app", PHONE, "iphonesimulator"),
            ("watch", "Debug-watchsimulator/GSDWatch.app", WATCH, "watchsimulator")):
        app = products / folder
        info = plistlib.loads((app / "Info.plist").read_bytes())
        assert (info["CFBundleIdentifier"], info["CFBundleVersion"], info["CFBundleShortVersionString"]) == (
            identifier, build, "4.1.0")
        assert info["DTPlatformName"] == platform
        if family == "watch":
            assert info["WKApplication"] is True and info["WKCompanionAppBundleIdentifier"] == PHONE
        run(["codesign", "--verify", "--deep", "--strict", str(app)], log)
        bundles[family] = {"path": str(app), "bundleID": identifier,
            "executable": info["CFBundleExecutable"], "minimumOS": info["MinimumOSVersion"],
            "executable_sha256": hashlib.sha256((app / info["CFBundleExecutable"]).read_bytes()).hexdigest()}
    return bundles


def select_pair(inventory: dict, bundles: dict) -> dict:
    available = [r for r in inventory["runtimes"] if r.get("isAvailable")]
    watches = sorted((r for r in available if ".watchOS-" in r["identifier"]
                      and version(r["version"]) >= version(bundles["watch"]["minimumOS"])),
                     key=lambda r: version(r["version"]), reverse=True)
    for watch in watches:
        phones = [r for r in available if ".iOS-" in r["identifier"]
                  and version(r["version"]) == version(watch["version"])
                  and version(r["version"]) >= version(bundles["phone"]["minimumOS"])]
        supported = {d["identifier"] if isinstance(d, dict) else d for d in watch["supportedDeviceTypes"]}
        types = [d for d in inventory["devicetypes"]
                 if d.get("productFamily") == "Apple Watch" and d["identifier"] in supported]
        for phone in phones:
            device = devices_for_runtime(inventory, phone).get("iPhone")
            if device and types:
                return {"phone": {"runtime": phone, "type": device}, "watch": {"runtime": watch, "type": types[0]}}
    raise RuntimeError("No compatible installed watchOS/iOS simulator pair")


def prepare_pair(selected: dict, bundles: dict, output: Path, report: dict) -> None:
    log = output / "simulators.log"
    for family in ("phone", "watch"):
        choice = selected[family]
        device = run(["xcrun", "simctl", "create", "GSD-WatchSmoke-" + family + "-" + uuid.uuid4().hex[:8],
                      choice["type"]["identifier"], choice["runtime"]["identifier"]], log).strip()
        assert re.fullmatch(r"[0-9A-Fa-f-]{36}", device), "Unexpected created device ID"
        report["devices"][family] = {"id": device, "type": choice["type"]["identifier"],
            "runtime": choice["runtime"]["identifier"], "runtimeVersion": choice["runtime"]["version"]}
    devices = report["devices"]
    run(["xcrun", "simctl", "pair", devices["watch"]["id"], devices["phone"]["id"]], log)
    pairs = json.loads(run(["xcrun", "simctl", "list", "pairs", "--json"], log))["pairs"]
    matches = [key for key, value in pairs.items()
               if value["watch"]["udid"] == devices["watch"]["id"] and value["phone"]["udid"] == devices["phone"]["id"]]
    assert len(matches) == 1, "Created simulator pairing did not read back"
    report["pair_id"] = matches[0]
    for family in ("phone", "watch"):
        boot_device(devices[family]["id"], log, devices[family])
        run(["xcrun", "simctl", "install", devices[family]["id"], bundles[family]["path"]], log)


def smoke_language(language: str, locale: str, bundles: dict, output: Path, report: dict) -> None:
    log = output / ("watch-" + language + ".log")
    for family in ("phone", "watch"):
        identifier = bundles[family]["bundleID"]
        launch = run(["xcrun", "simctl", "launch", "--terminate-running-process",
            report["devices"][family]["id"], identifier, "-AppleLanguages", "(" + language + ")",
            "-AppleLocale", locale], log)
        match = re.search(rf"(?m)^{re.escape(identifier)}:\s*(\d+)\s*$", launch)
        assert match, "Simulator launch did not identify its process"
        if family == "watch":
            process_id = match[1]
    time.sleep(5)
    process = run(["ps", "-p", process_id, "-o", "pid=,comm="], log).strip().split(maxsplit=1)
    assert len(process) == 2 and process[0] == process_id and Path(process[1]).name == bundles["watch"]["executable"]
    screenshot = output / ("watch-" + language + ".png")
    run(["xcrun", "simctl", "io", report["devices"]["watch"]["id"], "screenshot", "--type=png", str(screenshot)], log)
    data = screenshot.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", "Expected raw simulator PNG"
    width, height = struct.unpack_from(">II", data, 16)
    assert width > 0 and height > 0, "Empty Watch screen capture"
    evidence = {"language": language, "locale": locale, "passed": True, "processID": int(process_id),
        "aliveAfterSeconds": 5, "screenshot": screenshot.name, "pixelWidth": width, "pixelHeight": height,
        "screenshot_sha256": hashlib.sha256(data).hexdigest(), "captureSource": "simctl io screenshot",
        "visualReview": "pending", "launchMode": "normal; standard language arguments only"}
    (output / ("watch-" + language + ".geometry.json")).write_text(json.dumps(evidence, indent=2) + "\n")
    report["languages"].append(evidence)


def cleanup(output: Path, report: dict) -> None:
    log = output / "cleanup.log"
    errors = []
    if report.get("pair_id"):
        try:
            run(["xcrun", "simctl", "unpair", report["pair_id"]], log, check=False)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            errors.append(str(error))
    created = [d["id"] for d in report["devices"].values()]
    for device in reversed(created):
        for action in ("shutdown", "delete"):
            try:
                run(["xcrun", "simctl", action, device], log, check=action == "delete")
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                errors.append(str(error))
    inventory = json.loads(run(["xcrun", "simctl", "list", "--json"], log))
    remaining = {d["udid"] for group in inventory["devices"].values() for d in group}
    assert not remaining.intersection(created), "Created smoke simulator was not removed"
    assert not errors, "Simulator cleanup command failed: " + "; ".join(errors)
    report["created_simulators_removed"] = True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert re.fullmatch(r"[0-9a-f]{40}", args.source_sha) and args.run_id.isdigit() and args.build.isdigit()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "harness_sha": os.environ["GITHUB_SHA"], "harness_run_id": os.environ["GITHUB_RUN_ID"],
        "devices": {}, "languages": [], "scope": "Watch process launch/liveness and raw localized screenshots only",
        "limitations": "No WatchConnectivity, complication/widget timeline, task-write, Siri, VoiceOver or physical-device proof."}
    try:
        report["xcode_version"] = run(["xcodebuild", "-version"], args.output / "toolchain.log").strip()
        products = retrieve_products(args, report)
        report["bundles"] = inspect_bundles(products, args.build, args.output / "bundle-audit.log")
        inventory = json.loads(run(["xcrun", "simctl", "list", "--json"], args.output / "inventory.log"))
        prepare_pair(select_pair(inventory, report["bundles"]), report["bundles"], args.output, report)
        for language, locale in LANGUAGES:
            smoke_language(language, locale, report["bundles"], args.output, report)
        report["passed"] = len(report["languages"]) == 2 and all(r["passed"] for r in report["languages"])
    except (AssertionError, KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    finally:
        if report["devices"]:
            try:
                cleanup(args.output, report)
            except (AssertionError, KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                report.update(passed=False, cleanup_error=str(error))
        report["timestamp"] = datetime.now(timezone.utc).isoformat()
        (args.output / "watch-smoke.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
