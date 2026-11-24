#!/usr/bin/env python3
"""Collect one owned Hebrew iPad startup crash; never emit native acceptance."""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import time
import uuid

from gsd_native_acceptance import redact, run
from gsd_simulator_smoke import devices_for_runtime

BUNDLE = "com.itorah.gsd"


def report_time(value: str) -> float | None:
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        return parsed.timestamp() if parsed.tzinfo else None
    except (ValueError, AttributeError):
        return None


def crash_identity(text: str) -> dict | None:
    """Read Apple's two-object IPS format or the corresponding text report."""
    try:
        decoder = json.JSONDecoder()
        stripped = text.lstrip("\ufeff \r\n\t")
        header, end = decoder.raw_decode(stripped)
        remainder = stripped[end:].lstrip()
        body = decoder.raw_decode(remainder)[0] if remainder else header
        declared = body.get("bundleInfo", {}).get("CFBundleIdentifier")
        if declared and header.get("bundleID") and declared != header["bundleID"]:
            return None
        return {"pid": body.get("pid"), "name": body.get("procName"),
                "bundle": body.get("bundleInfo", {}).get("CFBundleIdentifier", header.get("bundleID")),
                "path": body.get("procPath"),
                "timestamp": report_time(body.get("captureTime", header.get("timestamp")))}
    except (ValueError, TypeError, AttributeError):
        fields = {}
        for key, pattern in {"process": r"(?m)^Process:\s+GSD\s+\[(\d+)\]",
                             "path": r"(?m)^Path:\s+(.+)$",
                             "bundle": r"(?m)^Identifier:\s+(\S+)",
                             "date": r"(?m)^Date/Time:\s+(.+)$"}.items():
            match = re.search(pattern, text)
            if not match:
                return None
            fields[key] = match.group(1).strip()
        return {"pid": int(fields["process"]), "name": "GSD", "path": fields["path"],
                "bundle": fields["bundle"], "timestamp": report_time(fields["date"])}


def matches_phase(identity: dict | None, device: str, phase: dict, modified: float) -> bool:
    if not identity or identity["name"] != "GSD" or identity["bundle"] != BUNDLE:
        return False
    pid, path, occurred = identity["pid"], identity["path"], identity["timestamp"]
    if not isinstance(pid, int) or pid <= 0 or not isinstance(path, str) or occurred is None:
        return False
    if "/" + device.lower() + "/" not in path.lower() or not path.endswith("/GSD.app/GSD"):
        return False
    if phase.get("pid") is not None and pid != phase["pid"]:
        return False
    return (phase["started_epoch"] <= occurred <= phase["ended_epoch"] + 2
            and modified >= phase["started_epoch"] and modified <= time.time() + 2)


def collect_crashes(device: str, phase: dict, destination: Path, wait_seconds: int,
                    home: Path | None = None) -> list[dict]:
    """Copy only new GSD reports bound to this device, phase, bundle and PID."""
    home = home or Path.home()
    host = home / "Library/Logs/DiagnosticReports"
    roots = [host, host / "Retired", home / "Library/Developer/CoreSimulator/Devices" /
             device / "data/Library/Logs/CrashReporter"]
    deadline = time.monotonic() + wait_seconds
    scan_deadline = max(deadline, time.monotonic() + 5)
    found = {item["sha256"]: item for item in phase.get("crashes", [])}
    errors = phase.setdefault("crash_scan_error_counts", {})
    destination.mkdir(parents=True, exist_ok=True)
    while True:
        for root in roots:
            try:
                if not root.is_dir() or root.is_symlink():
                    continue
                candidates = sorted(root.iterdir())
            except OSError:
                errors["directory_io"] = errors.get("directory_io", 0) + 1
                continue
            for path in candidates:
                if time.monotonic() > scan_deadline:
                    return list(found.values())
                try:
                    if (not path.is_file() or path.is_symlink() or not path.name.startswith("GSD")
                            or path.suffix not in (".ips", ".crash")):
                        continue
                    metadata = path.stat()
                    if metadata.st_mtime < phase["started_epoch"] or metadata.st_size > 20_000_000:
                        continue
                    raw = path.read_bytes()
                    text = raw.decode("utf-8")
                    identity = crash_identity(text)
                except (OSError, UnicodeError) as error:
                    category = ("vanished" if isinstance(error, FileNotFoundError) else
                                "permission" if isinstance(error, PermissionError) else
                                "encoding" if isinstance(error, UnicodeError) else "file_io")
                    errors[category] = errors.get(category, 0) + 1
                    continue
                if not matches_phase(identity, device, phase, metadata.st_mtime):
                    continue
                digest = hashlib.sha256(raw).hexdigest()
                if digest in found:
                    continue
                # Preserve the original report format as text; the existing
                # mandatory artifact sanitizer covers this .log suffix too.
                target = destination / (phase["name"] + "-" + path.name + ".log")
                target.write_bytes(raw)
                found[digest] = {"original_name": path.name, "file": target.name,
                                 "sha256": digest, "identity": identity,
                                 "pid_binding": "observed-launch" if phase.get("pid") else "owned-path-bundle-phase"}
                # Preserve each verified copy immediately, including if a later
                # source rotates or another candidate cannot be read.
                phase["crashes"] = list(found.values())
        if found or time.monotonic() >= deadline:
            return list(found.values())
        time.sleep(min(3, max(0, deadline - time.monotonic())))


def screenshot(device: str, path: Path, phase: dict, environment: dict) -> None:
    run(["xcrun", "simctl", "io", device, "screenshot", "--type=png", str(path)],
        path.with_suffix(".log"), timeout=30, env=environment)
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24
    width, height = struct.unpack(">II", data[16:24])
    phase["screen"] = {"file": path.name, "width": width, "height": height,
                       "observed_orientation": "landscape" if width > height else "portrait",
                       "full_screen": True, "app_frame_or_orientation_asserted": False}


def phase_launch(device: str, name: str, arguments: list[str], seconds: int,
                 folder: Path, environment: dict) -> dict:
    phase = {"name": name, "arguments": arguments, "started_epoch": time.time(),
             "pid": None, "alive_samples": [], "observation_seconds_requested": seconds}
    console = folder / (name + "-console.log")
    process = None
    try:
        with console.open("wb") as stream:
            process = subprocess.Popen(["xcrun", "simctl", "launch", "--console-pty", device, BUNDLE, *arguments],
                                       stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                                       env=environment, start_new_session=True)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                text = console.read_bytes().decode("utf-8", errors="replace")
                match = re.search(r"(?m)^" + re.escape(BUNDLE) + r":\s*(\d+)\s*$", text)
                if match:
                    phase["pid"] = int(match.group(1))
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.5)
            if phase["pid"] is not None:
                until = time.monotonic() + seconds
                while True:
                    result = subprocess.run(["ps", "-p", str(phase["pid"]), "-o", "pid=,comm="],
                                            capture_output=True, text=True, timeout=10)
                    columns = result.stdout.strip().split(maxsplit=1)
                    alive = (result.returncode == 0 and len(columns) == 2
                             and columns[0] == str(phase["pid"]) and Path(columns[1]).name == "GSD")
                    phase["alive_samples"].append({"epoch": time.time(), "alive": alive})
                    if not alive or time.monotonic() >= until:
                        break
                    time.sleep(min(2, max(0, until - time.monotonic())))
            phase["alive_at_observation_end"] = bool(phase["alive_samples"] and phase["alive_samples"][-1]["alive"])
            phase["launcher_exit_before_cleanup"] = process.poll()
            phase["ended_epoch"] = time.time()
            phase["observation_ended_epoch"] = phase["ended_epoch"]
            try:
                screenshot(device, folder / (name + "-screen.png"), phase, environment)
            except (OSError, RuntimeError, subprocess.SubprocessError, AssertionError) as error:
                phase["screenshot_error"] = redact(str(error))
            phase["crash_collection_started"] = True
            phase["crashes"] = collect_crashes(device, phase, folder / "crashes",
                                               0 if phase["alive_at_observation_end"] else 90)
    except (OSError, RuntimeError, subprocess.SubprocessError, AssertionError, ValueError) as error:
        phase["error"] = redact(str(error))
        phase.setdefault("ended_epoch", time.time())
        phase.setdefault("observation_ended_epoch", phase["ended_epoch"])
        if not phase.get("crash_collection_started"):
            phase["crash_collection_started"] = True
            try:
                phase["crashes"] = collect_crashes(device, phase, folder / "crashes", 90)
            except (OSError, ValueError) as diagnostic_error:
                phase["crash_collection_error"] = redact(str(diagnostic_error))
    finally:
        phase.setdefault("ended_epoch", time.time())
        phase.setdefault("observation_ended_epoch", phase["ended_epoch"])
        phase["collection_finished_epoch"] = time.time()
        try:
            run(["xcrun", "simctl", "terminate", device, BUNDLE], folder / (name + "-terminate.log"),
                timeout=20, check=False, env=environment)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            phase["termination_error"] = redact(str(error))
        try:
            if process is not None:
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
        except (OSError, subprocess.SubprocessError) as error:
            phase["launcher_cleanup_error"] = redact(str(error))
        phase["cleanup_finished_epoch"] = time.time()
        (folder / (name + "-phase.json")).write_text(json.dumps(phase, indent=2) + "\n")
    return phase


def diagnose(products: Path, output: Path, inventory: dict, runtime: dict) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    environment = {key: value for key, value in os.environ.items() if key not in ("GH_TOKEN", "GITHUB_TOKEN")}
    report = {"diagnostic_only": True, "full_acceptance": False, "passed": False,
              "scope": "Same-binary Hebrew demo then normal startup; no XCTest/account/API fixture execution",
              "landscape_xctest_failure_cleared": False, "phases": [], "cleanup_errors": []}
    device = None
    try:
        help_text = run(["xcrun", "simctl", "help", "launch"], output / "launch-help.log", timeout=30, env=environment)
        assert "--console-pty" in help_text, "Required Simulator console capture is unavailable"
        kind = devices_for_runtime(inventory, runtime)["iPad"]
        device = run(["xcrun", "simctl", "create", "GSD48-he-startup-" + uuid.uuid4().hex[:8],
                      kind["identifier"], runtime["identifier"]], output / "create.log", timeout=30, env=environment).strip()
        assert re.fullmatch(r"[A-Fa-f0-9-]{36}", device), "Unexpected owned simulator identifier"
        report.update(simulator_id=device, device_type=kind["identifier"], runtime=runtime["identifier"])
        run(["xcrun", "simctl", "boot", device], output / "boot.log", timeout=30, env=environment)
        run(["xcrun", "simctl", "bootstatus", device, "-b"], output / "bootstatus.log", timeout=300, env=environment)
        app = products / "Debug-iphonesimulator/GSD.app"
        run(["xcrun", "simctl", "install", device, str(app)], output / "install.log", timeout=60, env=environment)
        locale = ["-AppleLanguages", "(he)", "-AppleLocale", "he_IL"]
        for name, arguments, seconds in (("demo", ["--demo-seed", *locale], 15), ("normal", locale, 60)):
            print("GSD_STARTUP_DIAGNOSTIC_PHASE", name, flush=True)
            phase = phase_launch(device, name, arguments, seconds, output, environment)
            report["phases"].append(phase)
            if phase.get("launcher_cleanup_error"):
                report["cleanup_errors"].append(phase["launcher_cleanup_error"])
    except (OSError, RuntimeError, subprocess.SubprocessError, AssertionError, ValueError) as error:
        report["diagnostic_error"] = redact(str(error))
        raise
    finally:
        if device and re.fullmatch(r"[A-Fa-f0-9-]{36}", device):
            # Collect bounded GSD-only logging and delayed owned crash reports
            # before deleting the device, even if launch or capture failed.
            try:
                run(["xcrun", "simctl", "spawn", device, "log", "show", "--style", "json",
                     "--last", "10m", "--predicate", 'process == "GSD"'], output / "gsd-unified.log",
                    timeout=30, env=environment)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                report["log_collection_error"] = redact(str(error))
            for phase in report["phases"]:
                try:
                    phase["crashes"] = collect_crashes(device, phase, output / "crashes", 0)
                except (OSError, ValueError) as error:
                    phase["final_crash_collection_error"] = redact(str(error))
            for operation in ("shutdown", "delete"):
                try:
                    run(["xcrun", "simctl", operation, device], output / (operation + ".log"),
                        timeout=30, check=(operation == "delete"), env=environment)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    report["cleanup_errors"].append(redact(str(error)))
            try:
                remaining = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"],
                                           output / "cleanup-inventory.json", timeout=15, env=environment))
                assert all(row["udid"] != device for rows in remaining["devices"].values() for row in rows)
                report["owned_simulator_absent"] = True
            except (OSError, RuntimeError, subprocess.SubprocessError, ValueError, AssertionError) as error:
                report["cleanup_errors"].append(redact(str(error)))
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        (output / "startup-diagnostic.json").write_text(json.dumps(report, indent=2) + "\n")
    if report["cleanup_errors"]:
        raise RuntimeError("Owned diagnostic simulator cleanup failed")
    print("GSD_STARTUP_DIAGNOSTIC_COLLECTED acceptance=false", flush=True)
    return report
