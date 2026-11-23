#!/usr/bin/env python3
"""Install existing Apple signing identity in an isolated CI keychain, then clean it."""
from __future__ import annotations
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess

def security(*args: str) -> bytes:
    result = subprocess.run(["security", *args], capture_output=True, timeout=60)
    if result.returncode:
        # Command arguments can contain passwords. Never include them in failures.
        raise RuntimeError("Apple keychain operation failed: " + args[0])
    return result.stdout

def location() -> Path:
    return Path(os.environ["RUNNER_TEMP"]) / ("gsd-signing-" + os.environ["GITHUB_RUN_ID"] + "-" +
                                             os.environ.get("GITHUB_RUN_ATTEMPT", "1"))

def prepare() -> None:
    required = ("APPLE_CERTIFICATE_P12_B64", "APPLE_CERTIFICATE_PASSWORD", "ASC_KEY_P8", "ASC_KEY_ID")
    for name in required:
        if not os.environ.get(name):
            raise RuntimeError("Missing GitHub secret: " + name)
    folder = location()
    folder.mkdir(mode=0o700)
    old = shlex.split(security("list-keychains", "-d", "user").decode())
    state = {"keychains": old, "keychain": str(folder / "distribution.keychain-db")}
    (folder / "state.json").write_text(json.dumps(state), encoding="utf-8")
    p12 = folder / "distribution.p12"
    p12.write_bytes(base64.b64decode(os.environ["APPLE_CERTIFICATE_P12_B64"], validate=True))
    p12.chmod(0o600)
    key = folder / ("AuthKey_" + os.environ["ASC_KEY_ID"] + ".p8")
    key.write_bytes(base64.b64decode(os.environ["ASC_KEY_P8"], validate=True))
    key.chmod(0o600)
    password = secrets.token_urlsafe(40)
    keychain = state["keychain"]
    security("create-keychain", "-p", password, keychain)
    security("set-keychain-settings", "-lut", "21600", keychain)
    security("unlock-keychain", "-p", password, keychain)
    security("import", str(p12), "-P", os.environ["APPLE_CERTIFICATE_PASSWORD"], "-f", "pkcs12",
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-k", keychain)
    security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain)
    security("list-keychains", "-d", "user", "-s", keychain, *old)
    identities = security("find-identity", "-v", "-p", "codesigning", keychain).decode()
    if "Apple Distribution: David Povarsky (NA6HPWARQ2)" not in identities:
        raise RuntimeError("Expected owner's existing Apple Distribution identity is unavailable")
    with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as environment:
        environment.write("ASC_KEY_PATH=" + str(key) + "\n")
        environment.write("SIGNING_KEYCHAIN=" + keychain + "\n")
    p12.unlink()
    print("GSD_EXISTING_DISTRIBUTION_IDENTITY_READY")

def cleanup(profiles: Path | None) -> None:
    folder = location()
    if folder.exists():
        state_path = folder / "state.json"
        if state_path.exists():
            state = json.loads(state_path.read_text(encoding="utf-8"))
            try:
                security("list-keychains", "-d", "user", "-s", *state["keychains"])
            finally:
                keychain = Path(state["keychain"])
                if keychain.exists():
                    security("delete-keychain", str(keychain))
        shutil.rmtree(folder)
    if profiles and profiles.exists():
        for row in json.loads(profiles.read_text(encoding="utf-8")):
            if row.get("installed"):
                path = Path.home() / "Library/MobileDevice/Provisioning Profiles" / (row["uuid"] + ".mobileprovision")
                path.unlink(missing_ok=True)
    print("GSD_CI_SIGNING_MATERIAL_REMOVED")

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "cleanup"))
    parser.add_argument("--profiles", type=Path)
    args = parser.parse_args()
    if args.operation == "prepare":
        prepare()
    else:
        cleanup(args.profiles)

if __name__ == "__main__":
    main()
