#!/usr/bin/env python3
"""Launch the normal GSD app on disposable iPhone and iPad simulators."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid


PREFERRED_DEVICE_TYPES = {
    "iPhone": (
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
    ),
    "iPad": (
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
        "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4",
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB",
    ),
}


def captured_output(stream, limit: int | None = None) -> str:
    # Snapshot a regular file; a descendant retaining its descriptor cannot hold EOF open.
    size = stream.seek(0, os.SEEK_END)
    start = max(0, size - limit) if limit is not None else 0
    stream.seek(start)
    text = stream.read(size - start).decode("utf-8", errors="replace")
    return ("[earlier output truncated]\n" if start else "") + text


def run(command: list[str], log: Path, timeout: int = 120,
        check: bool = True, output_limit: int | None = None) -> str:
    started = time.monotonic()
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    heading = f"[{stamp}] $ {' '.join(command)} (timeout={timeout}s)\n"
    print(heading, end="", flush=True)
    with log.open("a", encoding="utf-8") as stream, \
            tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        stream.write(heading)
        stream.flush()
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            returncode_at_deadline = process.poll()
            stop_note = ""
            try:
                process.kill()
                process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired) as stop_error:
                stop_note = f"\nDirect-process cleanup failed: {stop_error}"
            error.output = captured_output(stdout, output_limit)
            error.stderr = captured_output(stderr, output_limit)
            message = (error.output + error.stderr
                       + f"\nTIMEOUT waiting for direct process after {time.monotonic() - started:.1f}s"
                       + f"; returncodeAtDeadline={returncode_at_deadline}"
                       + f"; returncodeAfterKill={process.returncode}{stop_note}\n")
            stream.write(message)
            print(message, end="", flush=True)
            raise
        output, errors = captured_output(stdout, output_limit), captured_output(stderr, output_limit)
        footer = f"\nexit={returncode}; elapsed={time.monotonic() - started:.1f}s; wait=direct-process\n"
        stream.write(output + errors + footer)
    print(output + errors + footer, end="", flush=True)
    if check and returncode:
        raise subprocess.CalledProcessError(returncode, command, output=output, stderr=errors)
    return output


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
        compatible = {item["identifier"]: item for item in candidates}
        for preferred in PREFERRED_DEVICE_TYPES[family]:
            if preferred in compatible:
                selected[family] = compatible[preferred]
                break
    return selected


def boot_device(device_id: str, log: Path, receipt: dict) -> None:
    # The observed failure was a bootstatus timeout before GSD was installed.
    # Only that infrastructure boundary permits one reset; app checks never retry.
    receipt["bootAttempts"] = []
    for attempt in (1, 2):
        details = {"attempt": attempt, "status": "running"}
        receipt["bootAttempts"].append(details)
        try:
            receipt["stage"] = "boot"
            run(["xcrun", "simctl", "boot", device_id], log)
            receipt["stage"] = "bootstatus"
            run(["xcrun", "simctl", "bootstatus", device_id, "-b"], log, timeout=300)
            details["status"] = "passed"
            return
        except subprocess.TimeoutExpired as error:
            details.update(status="timed_out", stage=receipt["stage"], error=str(error))
            if attempt == 2:
                raise
            message = "Pre-install boot timed out; recording state before one shutdown/reboot.\n"
            print(message, end="", flush=True)
            with log.open("a", encoding="utf-8") as stream:
                stream.write(message)
            try:
                run(["xcrun", "simctl", "list", "devices", "--json"],
                    log, timeout=30, check=False)
            except (OSError, subprocess.SubprocessError) as diagnostic_error:
                with log.open("a", encoding="utf-8") as stream:
                    stream.write(f"Boot-state diagnostic failed: {diagnostic_error}\n")
            run(["xcrun", "simctl", "shutdown", device_id], log)


def install_resource_snapshot(app: Path, runtime: dict) -> dict:
    snapshot = {
        "cpuCount": os.cpu_count(),
        "freeDiskBytes": shutil.disk_usage(app).free,
        "runtimeBundleExists": Path(runtime["bundlePath"]).is_dir(),
    }
    if hasattr(os, "getloadavg"):
        snapshot["loadAverage"] = list(os.getloadavg())
    return snapshot


def install_diagnostics(device_id: str, app: Path, runtime: dict, log: Path) -> None:
    # Best-effort evidence only: neither an installed container nor diagnostic success
    # substitutes for the single install command returning zero.
    deadline = time.monotonic() + 75
    with log.open("a", encoding="utf-8") as stream:
        try:
            stream.write(json.dumps(install_resource_snapshot(app, runtime)) + "\n")
        except (OSError, KeyError) as error:
            stream.write(f"Resource snapshot failed: {error}\n")
    host_predicate = ('process == "simdiskimaged" OR process == "cryptexd" '
                      'OR subsystem BEGINSWITH "com.apple.CoreSimulator"')
    device_predicate = ('process == "installd" OR process == "installcoordinationd" '
                        'OR eventMessage CONTAINS "dev.vinny.gsd"')
    commands = [
        ["sysctl", "hw.memsize", "hw.ncpu", "vm.swapusage"],
        ["vm_stat"],
        ["ps", "-axo", "pid,ppid,pcpu,pmem,etime,comm"],
        ["xcrun", "simctl", "list", "devices", "--json"],
        ["/usr/bin/log", "show", "--style", "compact", "--last", "5m",
         "--predicate", host_predicate],
        ["xcrun", "simctl", "spawn", device_id, "log", "show", "--style", "compact",
         "--last", "5m", "--predicate", device_predicate],
        ["xcrun", "simctl", "get_app_container", device_id, "dev.vinny.gsd", "app"],
    ]
    for command in commands:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            with log.open("a", encoding="utf-8") as stream:
                stream.write("Installation diagnostic budget exhausted (75 seconds).\n")
            break
        try:
            run(command, log, timeout=min(15, remaining), check=False, output_limit=24000)
        except (OSError, subprocess.SubprocessError) as error:
            with log.open("a", encoding="utf-8") as stream:
                stream.write(f"Diagnostic command failed: {error}\n")


def install_app(device_id: str, app: Path, runtime: dict, log: Path, receipt: dict) -> None:
    # Observed cold-boot command waits reached 104-145s. This one install gets
    # a bounded 300s direct-process deadline; never retry the installation.
    details = {"attempts": 1, "timeoutSeconds": 300, "status": "running"}
    receipt["installation"] = details
    try:
        details["resourcesBefore"] = install_resource_snapshot(app, runtime)
    except (OSError, KeyError) as error:
        details["resourceSnapshotError"] = str(error)
    started = time.monotonic()
    try:
        run(["xcrun", "simctl", "install", device_id, str(app)], log, timeout=300)
    except (OSError, subprocess.SubprocessError) as error:
        details.update(status="timed_out" if isinstance(error, subprocess.TimeoutExpired) else "failed",
                       elapsedSeconds=round(time.monotonic() - started, 1))
        if isinstance(error, subprocess.CalledProcessError):
            details["exitCode"] = error.returncode
        diagnostic_log = log.with_name(log.stem + "-installation-diagnostics.log")
        details["diagnosticLog"] = diagnostic_log.name
        try:
            install_diagnostics(device_id, app, runtime, diagnostic_log)
        except (OSError, subprocess.SubprocessError) as diagnostic_error:
            details["diagnosticError"] = str(diagnostic_error)
        raise
    details.update(status="passed", exitCode=0, elapsedSeconds=round(time.monotonic() - started, 1))


def smoke_device(family: str, device_type: dict, runtime: dict, app: Path,
                 bundle_id: str, executable: str, output: Path) -> dict:
    log = output / f"{family.lower()}.log"
    receipt = {"family": family, "deviceType": device_type["identifier"],
               "deviceName": device_type["name"], "runtime": runtime["identifier"],
               "status": "failed", "stage": "create"}
    device_id = None
    try:
        name = f"GSD-smoke-{family}-{uuid.uuid4().hex[:8]}"
        device_id = run(["xcrun", "simctl", "create", name,
                         device_type["identifier"], runtime["identifier"]], log).strip()
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device_id):
            raise RuntimeError("simctl create did not return a device UUID")
        receipt["deviceID"] = device_id
        boot_device(device_id, log, receipt)
        receipt["stage"] = "install"
        install_app(device_id, app, runtime, log, receipt)
        receipt["stage"] = "launch"
        launch = run(["xcrun", "simctl", "launch", device_id, bundle_id], log)
        match = re.search(rf"(?m)^{re.escape(bundle_id)}:\s*(\d+)\s*$", launch)
        if not match:
            raise RuntimeError("simctl launch did not report the app PID")
        process_id = match.group(1)
        receipt["stage"] = "liveness"
        time.sleep(5)
        process = run(["ps", "-p", process_id, "-o", "pid=,comm="], log).strip()
        columns = process.split(maxsplit=1)
        if (len(columns) != 2 or columns[0] != process_id
                or Path(columns[1]).name != executable):
            raise RuntimeError("The launched GSD process did not remain alive")
        receipt["stage"] = "screenshot"
        screenshot = output / f"{family.lower()}.png"
        run(["xcrun", "simctl", "io", device_id, "screenshot",
             "--type=png", str(screenshot)], log)
        with screenshot.open("rb") as image:
            if image.read(8) != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError("Simulator screenshot is not a PNG")
        receipt.update(status="passed", stage="complete", processID=int(process_id),
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
             and re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-27(?:-\d+)*",
                              runtime["identifier"])),
            key=lambda runtime: version(runtime["version"]), reverse=True)
        selected = None
        for runtime in runtimes:
            device_types = devices_for_runtime(inventory, runtime)
            if len(device_types) == 2:
                selected = runtime, device_types
                break
        if selected is None:
            raise RuntimeError("No available general iOS 27 runtime with preferred compatible iPhone and iPad types")
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
