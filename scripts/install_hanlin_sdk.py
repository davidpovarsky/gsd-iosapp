#!/usr/bin/env python3
"""Install GSD's locked, original Hanlin SDK using its canonical installer."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen

HOST = Path(__file__).resolve().parents[1]
INSTALLER_PATH = "Scripts/SDK/install.py"


def main() -> int:
    lock = json.loads((HOST / "HanlinSDK.lock.json").read_text(encoding="utf-8"))
    revision = lock.get("revision", "")
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("Hanlin SDK requires a complete immutable revision")
    # The lock also pins the bootstrap bytes, before executing downloaded code.
    expected = lock.get("installerSHA256", "")
    if not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise ValueError("Hanlin SDK requires its canonical installer digest")
    installed = HOST / "Vendor/HanlinSDK" / INSTALLER_PATH
    if installed.is_file() and hashlib.sha256(installed.read_bytes().replace(b"\r\n", b"\n")).hexdigest() == expected:
        return subprocess.call([sys.executable, str(installed), "--host-root", str(HOST), *sys.argv[1:]])
    if "--check" in sys.argv[1:]:
        raise RuntimeError("Run scripts/install_hanlin_sdk.py before checking the installation")
    url = f"https://raw.githubusercontent.com/davidpovarsky/hanlin-ai/{revision}/{INSTALLER_PATH}"
    request = Request(url, headers={"User-Agent": "GSD-HanlinSDK-bootstrap"})
    with urlopen(request, timeout=60) as response:
        source = response.read()
    if hashlib.sha256(source).hexdigest() != expected:
        raise RuntimeError("Canonical installer digest does not match the immutable lock")
    with tempfile.TemporaryDirectory(prefix="gsd-hanlin-sdk-") as directory:
        installer = Path(directory) / "install.py"
        installer.write_bytes(source)
        return subprocess.call([sys.executable, str(installer), "--host-root", str(HOST), *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(main())
