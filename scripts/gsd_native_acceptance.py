#!/usr/bin/env python3
"""Build-independent UI acceptance on four disposable iPhone/iPad simulators."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import uuid

from gsd_simulator_smoke import devices_for_runtime, version

_redactions: set[str] = set()

def redact(text: str) -> str:
    """Retain fixture masks in memory so later xcresult summaries are sanitized too."""
    _redactions.update(re.findall(r"::add-mask::([^\s]+)", text))
    for value in _redactions:
        text = text.replace(value, "[REDACTED_EPHEMERAL_PASSWORD]")
    return text

def run(args: list[str], log: Path, timeout: int = 120, env: dict | None = None,
        check: bool = True) -> str:
    """Keep raw XCTest output outside artifacts and wait for the actual process."""
    log.parent.mkdir(parents=True, exist_ok=True)
    print("GSD_NATIVE_COMMAND", args[0], args[1] if len(args) > 1 else "", flush=True)
    # A private unnamed temporary file cannot be picked up by artifact globbing,
    # including when GitHub cancels the job before this function completes.
    with tempfile.TemporaryFile(mode="w+b", dir=os.environ.get("RUNNER_TEMP")) as stream:
        process = subprocess.Popen(args, stdout=stream, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        try:
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                raise
        finally:
            # pread preserves the shared stdout offset if a simulator child
            # inherited this file descriptor and remains alive after xcodebuild.
            raw = os.pread(stream.fileno(), os.fstat(stream.fileno()).st_size, 0)
            output = redact(raw.decode("utf-8", errors="replace"))
            log.write_text(output, encoding="utf-8")
    if check and code:
        raise RuntimeError(f"{args[0]} {args[1]} exited {code}; see {log}")
    return output

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ai-settings-only", action="store_true",
                        help="Run only localized Hanlin/ChatGPT UI; no live cloud fixtures")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    candidates = list((args.derived_data / "Build/Products").glob("*.xctestrun"))
    if len(candidates) != 1:
        raise RuntimeError("Expected one build-for-testing xctestrun, found " + str(len(candidates)))
    xctestrun = candidates[0].resolve()
    inventory = json.loads(run(["xcrun", "simctl", "list", "--json"], output / "inventory.log"))
    runtimes = sorted((r for r in inventory["runtimes"]
                       if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                       and version(r["version"]) >= version("27.0")),
                      key=lambda r: version(r["version"]), reverse=True)
    selected = next(((r, devices_for_runtime(inventory, r)) for r in runtimes
                     if len(devices_for_runtime(inventory, r)) == 2), None)
    if selected is None:
        raise RuntimeError("No available iOS 27 runtime with both iPhone and iPad types")
    runtime, devices = selected
    receipts = []
    receipt_path = output / "native-ui-receipt.json"
    for family in ("iPhone", "iPad"):
        for language in ("en", "he"):
            name = family.lower() + "-" + language
            folder = output / name
            folder.mkdir(exist_ok=True)
            device = devices[family]
            device_id = None
            cloud_round_trip = not args.ai_settings_only and family == "iPad" and language == "he"
            receipt = {"family": family, "language": language, "deviceType": device["name"],
                       "runtime": runtime["version"], "passed": False, "cloudRoundTrip": cloud_round_trip}
            receipts.append(receipt)
            try:
                device_id = run(["xcrun", "simctl", "create", "GSD48-" + name + "-" + uuid.uuid4().hex[:8],
                                 device["identifier"], runtime["identifier"]], folder / "create.log").strip()
                receipt["simulatorId"] = device_id
                run(["xcrun", "simctl", "boot", device_id], folder / "boot.log")
                run(["xcrun", "simctl", "bootstatus", device_id, "-b"], folder / "bootstatus.log", timeout=300)
                command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                           "-destination", "platform=iOS Simulator,id=" + device_id,
                           "-destination-timeout", "90", "-parallel-testing-enabled", "NO",
                           "-resultBundlePath", str(folder / "Results.xcresult"),
                           "-testLanguage", language, "-testRegion", "IL" if language == "he" else "US"]
                selected_tests = ["test04LocalizedHanlinProvidersAndChatGPTAccount"]
                if not args.ai_settings_only:
                    selected_tests = ["test01LocalizedNavigationEditorChartsAndRTL",
                                      "test03LocalizedWidgetView", *selected_tests]
                if cloud_round_trip:
                    selected_tests.append("test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload")
                command.extend("-only-testing:GSDScreenshotTests/GSDCloudReleaseUITests/" + name
                               for name in selected_tests)
                receipt["selectedTests"] = selected_tests
                environment = os.environ.copy()
                environment.update({
                    "TEST_RUNNER_GSD_TEST_LANGUAGE": language,
                    "TEST_RUNNER_GSD_SCREENSHOT_DIR": str(folder / "screenshots"),
                    "TEST_RUNNER_GSD_CLOUD_SYSTEM_TEST": "1" if cloud_round_trip else "0",
                    "TEST_RUNNER_GSD_CLOUD_TEST_BASE": environment.get("GSD_CLOUD_TEST_BASE",
                        "https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud"),
                })
                log = run(command, folder / "xcodebuild.log", timeout=1200, env=environment)
                verified = []
                for test in selected_tests:
                    marker = r"(?im)^.*Test [Cc]ase.*\b" + re.escape(test) + r"\b.*\bpassed\b"
                    if not re.search(marker, log):
                        raise RuntimeError("XCTest did not report the selected test passed: " + test)
                    verified.append(test)
                receipt["verifiedPassedTests"] = verified
                receipt["passed"] = True
            finally:
                result = folder / "Results.xcresult"
                if result.exists():
                    run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
                        folder / "test-summary.json", check=False)
                if device_id:
                    run(["xcrun", "simctl", "shutdown", device_id], folder / "shutdown.log", check=False)
                    run(["xcrun", "simctl", "delete", device_id], folder / "delete.log", check=False)
                receipt_path.write_text(json.dumps({"passed": all(r["passed"] for r in receipts) and len(receipts) == 4,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "profile": "chatgpt-settings" if args.ai_settings_only else "native-release", "runs": receipts}, indent=2) + "\n")
            print("GSD_NATIVE_UI_PASS", name, flush=True)
    print("GSD_NATIVE_UI_ALL_FOUR_PASS", flush=True)

if __name__ == "__main__":
    main()
