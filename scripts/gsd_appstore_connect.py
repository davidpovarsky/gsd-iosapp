#!/usr/bin/env python3
"""Provision and verify GSD App Store distribution using CI-owned credentials."""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

TEAM = "NA6HPWARQ2"
APP_GROUP = "group.com.itorah.gsd"
CERTIFICATE_ID = "B8HSX5CPJ4"
TARGETS = {
    "GSD": ("com.itorah.gsd", "4888DDZ3CZ", "GSD_Tasks_MAIN_AppStore_20261123"),
    "GSDWidgets": ("com.itorah.gsd.widgets", "FT8CGJA23Z", "GSD_Tasks_WIDGETS_AppStore_20261123"),
    "GSDShareExtension": ("com.itorah.gsd.share", "3WU23T2RLK", "GSD_Tasks_SHARE_AppStore_20261123"),
    "GSDWatch": ("com.itorah.gsd.watchkitapp", "N6AZ3WK759", "GSD_Tasks_WATCH_AppStore_20261123"),
    "GSDWatchWidgets": ("com.itorah.gsd.watchkitapp.widgets", "8P9G9J4V48", "GSD_Tasks_WATCHWIDGETS_AppStore_20261123"),
}


class Client:
    def __init__(self) -> None:
        import jwt
        self.jwt = jwt
        self.key = base64.b64decode(os.environ["ASC_KEY_P8"], validate=True).decode()
        self.key_id = os.environ["ASC_KEY_ID"]
        self.issuer = os.environ["ASC_ISSUER_ID"]
        if os.environ.get("APPLE_TEAM_ID") != TEAM:
            raise RuntimeError("Configured team differs from verified owner distribution identity")

    def request(self, path: str, method: str = "GET", payload: dict | None = None) -> dict:
        now = int(time.time())
        token = self.jwt.encode(
            {"iss": self.issuer, "iat": now - 10, "exp": now + 600, "aud": "appstoreconnect-v1"},
            self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})
        request = urllib.request.Request(
            "https://api.appstoreconnect.apple.com/v1/" + path,
            data=None if payload is None else json.dumps(payload).encode(),
            method=method,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=35) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            data = json.loads(error.read())
            summary = [{k: e.get(k) for k in ("status", "code", "title")}
                       for e in data.get("errors", [])]
            raise RuntimeError(f"Apple {method} {path.split('?')[0]}: {summary}") from None

    def app(self) -> dict:
        query = urllib.parse.urlencode({"filter[bundleId]": TARGETS["GSD"][0]})
        matches = self.request("apps?" + query)["data"]
        matches = [app for app in matches if app["attributes"]["bundleId"] == TARGETS["GSD"][0]]
        if len(matches) != 1:
            raise RuntimeError("Create the GSD Tasks app record for com.itorah.gsd in App Store Connect")
        return matches[0]


def decode_profile(content: str) -> tuple[bytes, dict]:
    raw = base64.b64decode(content, validate=True)
    if os.name != "nt":
        result = subprocess.run(["security", "cms", "-D"], input=raw,
                                capture_output=True, timeout=30, check=True)
        return raw, plistlib.loads(result.stdout)
    start = raw.index(b"<?xml")
    end = raw.index(b"</plist>", start) + len(b"</plist>")
    return raw, plistlib.loads(raw[start:end])


def validate_profile(profile: dict, bundle: str) -> None:
    entitlements = profile["Entitlements"]
    if profile.get("TeamIdentifier") != [TEAM]:
        raise ValueError("Profile belongs to another team")
    if entitlements.get("application-identifier") != TEAM + "." + bundle:
        raise ValueError("Profile application identifier mismatch")
    if entitlements.get("get-task-allow") is not False:
        raise ValueError("Profile allows debugging instead of App Store distribution")
    if "ProvisionedDevices" in profile or "ProvisionsAllDevices" in profile:
        raise ValueError("Profile is not App Store distribution")
    if entitlements.get("com.apple.security.application-groups") != [APP_GROUP]:
        raise ValueError("Associate group.com.itorah.gsd with every GSD App ID in Developer portal")
    expiration = profile["ExpirationDate"]
    now = dt.datetime.now(expiration.tzinfo) if expiration.tzinfo else dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    if expiration <= now:
        raise ValueError("Profile has expired")


def profiles(client: Client, install: bool, create: bool, output: Path) -> None:
    receipts = []
    for target, (bundle, bundle_id, name) in TARGETS.items():
        data = client.request("bundleIds/" + bundle_id + "/profiles?limit=200")["data"]
        candidates = [p for p in data if p["attributes"]["name"] == name
                      and p["attributes"]["profileState"] == "ACTIVE"]
        if not candidates and create:
            result = client.request("profiles", "POST", {"data": {
                "type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                    "certificates": {"data": [{"type": "certificates", "id": CERTIFICATE_ID}]}}}})
            candidates = [result["data"]]
        if len(candidates) != 1:
            raise RuntimeError(f"Missing or ambiguous App Store profile for {target}; create after App Group association")
        item = candidates[0]
        attrs = item["attributes"]
        if "profileContent" not in attrs:
            item = client.request("profiles/" + item["id"])["data"]
            attrs = item["attributes"]
        raw, profile = decode_profile(attrs["profileContent"])
        validate_profile(profile, bundle)
        if install:
            folder = Path.home() / "Library/MobileDevice/Provisioning Profiles"
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / (profile["UUID"] + ".mobileprovision")
            path.write_bytes(raw)
            path.chmod(0o600)
        receipt = {"target": target, "bundleId": bundle, "resourceId": item["id"],
                   "uuid": profile["UUID"], "name": name, "teamId": TEAM,
                   "expiration": profile["ExpirationDate"].isoformat(), "installed": install}
        receipts.append(receipt)
        output.write_text(json.dumps(receipts, indent=2) + "\n")
        print("GSD_PROFILE_VERIFIED", target, bundle, profile["UUID"], flush=True)
    output.write_text(json.dumps(receipts, indent=2) + "\n")


def preflight(client: Client, build: str, output: Path) -> None:
    app = client.app()
    query = urllib.parse.urlencode({"filter[app]": app["id"], "filter[version]": build})
    existing = client.request("builds?" + query)["data"]
    if existing:
        raise RuntimeError("Build " + build + " already exists; select a new build before archiving")
    receipt = {"appId": app["id"], "bundleId": app["attributes"]["bundleId"],
               "name": app["attributes"]["name"], "build": build, "buildAvailable": True, "teamId": TEAM}
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print("GSD_TESTFLIGHT_PREFLIGHT_PASS", app["id"], build, flush=True)


def export_options(path: Path) -> None:
    path.write_bytes(plistlib.dumps({
        "method": "app-store-connect", "destination": "export",
        "teamID": TEAM, "signingStyle": "manual", "signingCertificate": "Apple Distribution",
        "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
        "uploadSymbols": True,
        "provisioningProfiles": {bundle: name for bundle, _, name in TARGETS.values()}}))


def verify_upload(client: Client, build: str, timeout: int, output: Path) -> None:
    app = client.app()
    deadline = time.monotonic() + timeout
    query = urllib.parse.urlencode({"filter[app]": app["id"], "filter[version]": build})
    last_state = None
    while True:
        rows = client.request("builds?" + query)["data"]
        for row in rows:
            attrs = row["attributes"]
            state = attrs["processingState"]
            if state != last_state:
                print("GSD_TESTFLIGHT_PROCESSING", row["id"], build, state, flush=True)
                last_state = state
            if state in ("FAILED", "INVALID"):
                raise RuntimeError("Apple processing rejected build: " + state)
            if state == "VALID":
                details = client.request("builds/" + row["id"] + "/buildBetaDetail")["data"]
                receipt = {"appId": app["id"], "buildId": row["id"], "build": build,
                           "processingState": state, "expired": attrs.get("expired"),
                           "beta": details["attributes"], "timestamp": dt.datetime.now(dt.timezone.utc).isoformat()}
                output.write_text(json.dumps(receipt, indent=2) + "\n")
                print("GSD_TESTFLIGHT_VALID", row["id"], build, flush=True)
                return
        if time.monotonic() >= deadline:
            raise RuntimeError("Upload submitted but Apple processing has not completed")
        time.sleep(25)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("profiles", "preflight", "export-options", "verify-upload"))
    parser.add_argument("--build", default="49")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--create", action="store_true")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.operation == "export-options":
        export_options(args.output)
        return
    client = Client()
    if args.operation == "profiles":
        profiles(client, args.install, args.create, args.output)
    elif args.operation == "preflight":
        preflight(client, args.build, args.output)
    else:
        verify_upload(client, args.build, args.timeout, args.output)


if __name__ == "__main__":
    main()
