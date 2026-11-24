#!/usr/bin/env python3
"""Resolve dependencies before tests; retry one observed public submodule fetch failure."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

PUBLIC_SUBMODULE = "https://github.com/swiftlyfalling/SQLiteLib.git"
PUBLIC_METADATA = "https://api.github.com/repos/swiftlyfalling/SQLiteLib"

def is_known_transport_failure(output: str) -> bool:
    text = output.lower().replace("\u2019", "'")
    return (PUBLIC_SUBMODULE.lower() in text and "sqlitecustom/src" in text
            and ("couldn't update repository submodules" in text or "failed to clone" in text)
            and any(marker in text for marker in (
                "terminal prompts disabled", "rpc failed", "early eof",
                "remote end hung up", "connection reset", "could not resolve host",
                "operation timed out", "requested url returned error: 502",
                "requested url returned error: 503", "requested url returned error: 504")))

def confirm_public_repository() -> bool:
    request = urllib.request.Request(PUBLIC_METADATA, headers={
        "Accept": "application/vnd.github+json", "User-Agent": "GSD-native-dependency-check"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            metadata = json.load(response)
        return metadata.get("full_name", "").lower() == "swiftlyfalling/sqlitelib" and metadata.get("private") is False
    except Exception:
        # No token fallback or permission escalation. An unconfirmed repository is not retried.
        return False

def run_resolution(package: str) -> tuple[int, str]:
    command = ["swift", "package", "--package-path", package, "resolve"]
    environment = os.environ.copy()
    environment["GIT_TERMINAL_PROMPT"] = "0"
    try:
        result = subprocess.run(command, capture_output=True, text=True, errors="replace",
                                env=environment, timeout=300)
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as error:
        def text(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
        return 124, text(error.stdout) + text(error.stderr) + "\nDependency resolution timed out after 300s.\n"

def resolve_packages(packages: list[str], output: Path, runner=None, public_check=None, pause=None) -> None:
    runner = runner or run_resolution
    public_check = public_check or confirm_public_repository
    pause = pause or time.sleep
    output.mkdir(parents=True, exist_ok=True)
    receipts = []
    retry_used = False  # One retry across the whole dependency phase, not per test/suite.
    for package in packages:
        for attempt in (1, 2):
            code, text = runner(package)
            (output / (Path(package).name + f"-attempt-{attempt}.log")).write_text(text, encoding="utf-8")
            retry = bool(code and not retry_used and is_known_transport_failure(text) and public_check())
            receipts.append({"package": package, "attempt": attempt, "exitCode": code, "retry": retry})
            (output / "resolution.json").write_text(json.dumps(receipts, indent=2) + "\n", encoding="utf-8")
            print(text, end="" if text.endswith("\n") else "\n", flush=True)
            if code == 0:
                break
            if not retry:
                raise RuntimeError("Dependency resolution failed for " + package + "; tests were not started")
            retry_used = True
            print("GSD_PUBLIC_SUBMODULE_FETCH_RETRY_ONCE", package, flush=True)
            pause(5)
    print("GSD_DEPENDENCIES_RESOLVED_TESTS_NOT_YET_EXECUTED", flush=True)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", action="append", choices=("Packages/GSDHanlinAgent", "GSDKit"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    resolve_packages(args.package, args.output)

if __name__ == "__main__":
    main()
