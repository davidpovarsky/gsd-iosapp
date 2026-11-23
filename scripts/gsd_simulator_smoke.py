#!/usr/bin/env python3
"""Launch the normal GSD app on disposable iPhone and iPad simulators."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time
import uuid


def run(command: list[str], log: Path, timeout: int = 120,
        check: bool = True) -> str:
    with log.open("a", encoding="utf-8") as stream:
        stream.write("$ " + " ".join(command) + "\n")
        stream.flush()
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=timeout)
        output = result.stdout + result.stderr
        stream.write(output + f"\nexit={result.returncode}\n")
    print(output, end="", flush=True)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(command)}")
    return result.stdout


def version(value: str) -> tuple[int, ...]:
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * max(0, 3 - len(parts))


def devices_for_runtime(inventory: dict, runtime: dict) -> dict[str, dict]:
    supported = runtime.get("supportedDeviceTypes", [])
    supported_ids = {
        item["identifier"] if isinstance(item, dict) else item
        for item in supported
    }
    runtime_version = version(runtime["version"])
    selected = {}
    for family in ("iPhone", "iPad"):
        candidates = []
        for device_type in inventory["devicetypes"]:
            if not device_type["name"].startswith(family + " "):
                continue
            if supported_ids and device_type["identifier"] not in supported_ids:
                continue
            minimum = version(device_type.get("minRuntimeVersionString", "0"))
            maximum = version(device_type.get("maxRuntimeVersionString", "99999"))
            if minimum <= runtime_version <= maximum:
                candidates.append(device_type)
        if candidates:
            selected[family] = candidates[-1]
    return selected


def smoke_device(family: str, device_type: dict, runtime: dict, app: Path,
                 bundle_id: str, executable: str, output: Path) -> dict:
    log = output / f"{family.lower()}.log"
    receipt = {"family": family, "deviceType": device_type["identifier"],
               "runtime": runtime["identifier"], "status": "failed"}
    device_id = None
    try:
        name = f"GSD-smoke-{family}-{uuid.uuid4().hex[:8]}"
        device_id = run(["xcrun", "simctl", "create", name,
                         device_type["identifier"], runtime["identifier"]], log).strip()
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device_id):
            raise RuntimeError("simctl create did not return a device UUID")
        receipt["deviceID"] = device_id
        run(["xcrun", "simctl", "boot", device_id], log)
        run(["xcrun", "simctl", "bootstatus", device_id, "-b"], log, timeout=300)
        run(["xcrun", "simctl", "install", device_id, str(app)], log)
        launch = run(["xcrun", "simctl", "launch", device_id, bundle_id], log)
        match = re.search(rf"(?m)^{re.escape(bundle_id)}:\s*(\d+)\s*$", launch)
        if not match:
            raise RuntimeError("simctl launch did not report the app PID")
        process_id = match.group(1)
        time.sleep(5)
        process = run(["ps", "-p", process_id, "-o", "pid=,comm="], log).strip()
        columns = process.split(maxsplit=1)
        if (len(columns) != 2 or columns[0] != process_id
                or Path(columns[1]).name != executable):
            raise RuntimeError("The launched GSD process did not remain alive")
        screenshot = output / f"{family.lower()}.png"
        run(["xcrun", "simctl", "io", device_id, "screenshot",
             "--type=png", str(screenshot)], log)
        with screenshot.open("rb") as image:
            if image.read(8) != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError("Simulator screenshot is not a PNG")
        receipt.update(status="passed", processID=int(process_id),
                       aliveAfterSeconds=5, screenshot=screenshot.name)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        receipt["error"] = str(error)
        with log.open("a", encoding="utf-8") as stream:
            stream.write(f"SMOKE FAILED: {error}\n")
    finally:
        if device_id and re.fullmatch(r"[0-9A-Fa-f-]{36}", device_id):
            for operation in ("shutdown", "delete"):
                try:
                    run(["xcrun", "simctl", operation, device_id], log, check=False)
                except (OSError, subprocess.SubprocessError) as error:
                    with log.open("a", encoding="utf-8") as stream:
                        stream.write(f"CLEANUP {operation}: {error}\n")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "failed", "app": str(app), "devices": [],
        "launchMode": "normal (no demo arguments)",
        "limitations": "Launch/liveness screenshots only; no physical-device, OAuth or task-write claim."
    }
    try:
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        bundle_id, executable = info["CFBundleIdentifier"], info["CFBundleExecutable"]
        report["bundleID"] = bundle_id
        inventory = json.loads(run(["xcrun", "simctl", "list", "--json"],
                                   output / "discovery.log"))
        runtimes = sorted(
            (runtime for runtime in inventory["runtimes"]
             if runtime.get("isAvailable")
             and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-27")),
            key=lambda runtime: version(runtime["version"]), reverse=True)
        selected = None
        for runtime in runtimes:
            device_types = devices_for_runtime(inventory, runtime)
            if len(device_types) == 2:
                selected = runtime, device_types
                break
        if selected is None:
            raise RuntimeError("No available iOS 27 runtime with compatible iPhone and iPad types")
        runtime, device_types = selected
        for family in ("iPhone", "iPad"):
            report["devices"].append(smoke_device(
                family, device_types[family], runtime, app, bundle_id, executable, output))
        if all(device["status"] == "passed" for device in report["devices"]):
            report["status"] = "passed"
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    finally:
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n",
                                            encoding="utf-8")
        print(json.dumps(report, indent=2), flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
