#!/usr/bin/env python3
"""Build-independent UI acceptance on four disposable iPhone/iPad simulators.

The chatgpt-settings profile only checks provider/account settings UI. Its terminal
markers deliberately differ from native-release, which also selects navigation,
chart, editor, widget-harness, and the Hebrew iPad cloud round-trip tests.
"""
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

class CommandFailure(RuntimeError):
    def __init__(self, arguments: list[str], code: int, log: Path):
        self.arguments, self.code = arguments, code
        super().__init__(f"{arguments[0]} {arguments[1]} exited {code}; see {log}")

def redact(text: str) -> str:
    """Retain fixture masks in memory so later xcresult summaries are sanitized too."""
    _redactions.update(re.findall(r"::add-mask::([^\s]+)", text))
    for value in _redactions:
        text = text.replace(value, "[REDACTED_EPHEMERAL_PASSWORD]")
    return text


def signal_command(process: subprocess.Popen, sig: int) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        process.send_signal(sig)


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
            except subprocess.TimeoutExpired as timeout_error:
                try:
                    signal_command(process, signal.SIGTERM)
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        signal_command(process, signal.SIGKILL)
                        process.wait(timeout=10)
                except (OSError, subprocess.TimeoutExpired) as cleanup_error:
                    raise timeout_error from cleanup_error
                raise
        finally:
            # pread preserves the shared stdout offset if a simulator child
            # inherited this file descriptor and remains alive after xcodebuild.
            raw = os.pread(stream.fileno(), os.fstat(stream.fileno()).st_size, 0)
            output = redact(raw.decode("utf-8", errors="replace"))
            log.write_text(output, encoding="utf-8")
    if check and code:
        raise CommandFailure(args, code, log)
    return output


def simulator_state(device_id: str, log: Path) -> str | None:
    inventory = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"], log, timeout=30))
    return next((device["state"] for devices in inventory["devices"].values()
                 for device in devices if device["udid"] == device_id), None)


def await_simulator_boot(device_id: str, folder: Path) -> str:
    log = folder / "bootstatus.log"
    try:
        run(["xcrun", "simctl", "bootstatus", device_id, "-b"], log, timeout=300)
    except subprocess.TimeoutExpired:
        if ("Device already booted, nothing to do." not in log.read_text(encoding="utf-8")
                or simulator_state(device_id, folder / "boot-state.json") != "Booted"):
            raise
        return "verified-booted-after-status-timeout"
    return "bootstatus-completed"


def remove_simulator(device_id: str, folder: Path) -> str | None:
    shutdown_warning = None
    try:
        run(["xcrun", "simctl", "shutdown", device_id], folder / "shutdown.log", timeout=30, check=False)
    except subprocess.TimeoutExpired as error:
        shutdown_warning = redact(str(error))
    run(["xcrun", "simctl", "delete", device_id], folder / "delete.log", timeout=60)
    if simulator_state(device_id, folder / "cleanup-inventory.json") is not None:
        raise RuntimeError("Owned simulator remained after deletion: " + device_id)
    return shutdown_warning


def completed_assertion_failure(error: CommandFailure, tests: list[str],
                                log: str, summary: dict) -> dict:
    """Continue only after every selected test finished and failures are assertions."""
    if error.arguments[:2] != ["xcodebuild", "test-without-building"] or error.code != 65:
        raise error
    outcomes = {}
    for test in tests:
        matches = re.findall(r"(?im)^.*Test [Cc]ase.*\b" + re.escape(test) +
                             r"\b.*\b(passed|failed)\b", log)
        if len(matches) != 1:
            raise RuntimeError("Incomplete or ambiguous XCTest outcome: " + test)
        outcomes[test] = matches[0].lower()
    passed = [test for test in tests if outcomes[test] == "passed"]
    failed = [test for test in tests if outcomes[test] == "failed"]
    if (not failed or summary.get("result") != "Failed" or summary.get("totalTestCount") != len(tests)
            or summary.get("passedTests") != len(passed) or summary.get("failedTests") != len(failed)
            or summary.get("skippedTests") != 0 or summary.get("expectedFailures") != 0):
        raise RuntimeError("XCTest summary does not prove completed selected tests")
    failures = summary.get("testFailures", [])
    names = set()
    for failure in failures:
        identifier = failure.get("testIdentifierString", "")
        names.add(identifier)
        if (failure.get("targetName") != "GSDScreenshotTests"
                or identifier not in {"GSDCloudReleaseUITests/" + test + "()" for test in failed}
                or not re.match(r"^XCTAssert\w* failed\b", failure.get("failureText", ""))):
            raise RuntimeError("Non-assertion failure requires an immediate stop")
    if names != {"GSDCloudReleaseUITests/" + test + "()" for test in failed}:
        raise RuntimeError("Failed test assertion details are incomplete")
    return {"verifiedPassedTests": passed, "failedTests": failed, "xcodebuildExitCode": error.code,
            "failureKind": "completed-xctest-assertions"}

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
                receipt["bootVerification"] = await_simulator_boot(device_id, folder)
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
            except CommandFailure as error:
                if error.arguments[:2] != ["xcodebuild", "test-without-building"] or error.code != 65:
                    raise
                result = folder / "Results.xcresult"
                summary = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                          "--path", str(result)], folder / "test-summary.json"))
                receipt.update(completed_assertion_failure(error, selected_tests,
                               (folder / "xcodebuild.log").read_text(), summary))
            finally:
                result = folder / "Results.xcresult"
                cleanup_errors = []
                if result.exists() and not (folder / "test-summary.json").exists():
                    try:
                        run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                             "--path", str(result)], folder / "test-summary.json")
                    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                        cleanup_errors.append(redact(str(error)))
                if device_id:
                    try:
                        shutdown_warning = remove_simulator(device_id, folder)
                        if shutdown_warning:
                            receipt["shutdownWarning"] = shutdown_warning
                    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                        cleanup_errors.append(redact(str(error)))
                if cleanup_errors:
                    receipt.update(passed=False, cleanupErrors=cleanup_errors)
                receipt_path.write_text(json.dumps({"passed": all(r["passed"] for r in receipts) and len(receipts) == 4,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "profile": "chatgpt-settings" if args.ai_settings_only else "native-release", "runs": receipts}, indent=2) + "\n")
                if cleanup_errors:
                    raise RuntimeError("Profile diagnostics or simulator cleanup failed: " + name)
            marker = "GSD_AI_SETTINGS_UI_PASS" if args.ai_settings_only else "GSD_NATIVE_UI_PASS"
            if not receipt["passed"]:
                marker = marker.removesuffix("PASS") + "FAIL"
            print(marker, name, flush=True)
    if not all(r["passed"] for r in receipts):
        raise RuntimeError("One or more required UI profiles failed; full acceptance is rejected")
    marker = "GSD_AI_SETTINGS_UI_ALL_FOUR_PASS" if args.ai_settings_only else "GSD_NATIVE_UI_ALL_FOUR_PASS"
    print(marker, flush=True)

if __name__ == "__main__":
    main()
