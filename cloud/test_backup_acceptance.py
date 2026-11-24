#!/usr/bin/env python3
"""Isolated populated backup/restore using the real gateway and PocketBase binary.

The caller must explicitly supply the binary. All databases, account credentials,
gateway keys, logs and listeners belong to a temporary loopback-only fixture.
No deployed database, environment file or account is read.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import socket
import sqlite3
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PUBLIC_ORIGIN = "https://cloud.example/gsd-cloud"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def request(origin, method, route, body=None, token=None, form=False, expect=200):
    assert origin.startswith("http://127.0.0.1:")
    headers = {"Accept": "application/json", "Origin": "https://cloud.example"}
    data = None
    if body is not None:
        headers["Content-Type"] = (
            "application/x-www-form-urlencoded" if form else "application/json"
        )
        data = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(origin + route, data=data, headers=headers, method=method)
    try:
        response = OPENER.open(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        status, raw, hs = response.status, response.read(2 * 1024 * 1024), dict(response.headers)
    expected = expect if isinstance(expect, tuple) else (expect,)
    assert status in expected, f"{method} {route.split('?')[0]}: unexpected HTTP {status}"
    try:
        value = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        value = raw.decode()
    return value, hs


def port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def snapshot(database):
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        names = [row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )]
        counts = {name: db.execute('SELECT count(*) FROM "' + name + '"').fetchone()[0]
                  for name in names}
        digest = hashlib.sha256("\n".join(db.iterdump()).encode()).hexdigest()
        return {"integrity": "ok", "counts": counts, "logicalSHA256": digest}


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=20, **kwargs)
    assert result.returncode == 0, "Fixture subprocess failed: " + pathlib.Path(command[0]).name
    return result.stdout


def start_fixture(root, binary, processes, logs):
    pb_port, gateway_port = port(), port()
    (root / "pb_public").mkdir(exist_ok=True)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("GSD_", "PB_", "POCKETBASE_"))}
    pb_log = open(root / "fixture-pocketbase.log", "w")
    logs.append(pb_log)
    pb = subprocess.Popen([
        str(binary), "serve", "--http=127.0.0.1:" + str(pb_port),
        "--dir=" + str(root / "pb_data"),
        "--hooksDir=" + str(root / "pb_hooks"),
        "--migrationsDir=" + str(root / "pb_migrations"),
        "--publicDir=" + str(root / "pb_public"), "--hooksWatch=false",
    ], cwd=root, env=environment, stdout=pb_log, stderr=subprocess.STDOUT)
    processes.append(pb)
    pb_origin = "http://127.0.0.1:" + str(pb_port)
    wait_health(pb_origin, "/api/health", pb)
    gateway_log = open(root / "fixture-gateway.log", "w")
    logs.append(gateway_log)
    gateway = subprocess.Popen(["node", str(root / "gateway/server.mjs")], cwd=root,
        env={**environment, "GSD_CLOUD_PORT": str(gateway_port),
             "GSD_CLOUD_HOST": "127.0.0.1", "GSD_CLOUD_ORIGIN": PUBLIC_ORIGIN,
             "GSD_POCKETBASE_ORIGIN": pb_origin,
             "GSD_CLOUD_STATE_DIR": str(root / "gateway-state")},
        stdout=gateway_log, stderr=subprocess.STDOUT)
    processes.append(gateway)
    gateway_origin = "http://127.0.0.1:" + str(gateway_port)
    wait_health(gateway_origin, "/health", gateway)
    return gateway_origin


def wait_health(origin, route, process):
    for _ in range(35):
        assert process.poll() is None, "An isolated fixture exited during startup"
        try:
            request(origin, "GET", route)
            return
        except (urllib.error.URLError, ConnectionError):
            time.sleep(0.1)
    raise AssertionError("Isolated fixture startup timed out")


def begin_oauth(origin):
    redirect = "http://127.0.0.1:8765/callback"
    client, _ = request(origin, "POST", "/oauth/register", {"redirect_uris": [redirect]},
                        expect=201)
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    page, _ = request(origin, "GET", "/oauth/authorize?" + urllib.parse.urlencode({
        "client_id": client["client_id"], "redirect_uri": redirect, "response_type": "code",
        "code_challenge_method": "S256", "code_challenge": challenge,
        "scope": "gsd.read gsd.write offline_access", "resource": PUBLIC_ORIGIN + "/mcp",
        "state": "isolated-backup-state", "ui_locales": "en",
    }))
    match = re.search(r'name="request" value="([^"]+)"', page)
    assert match is not None
    return {"request": match[1], "client_id": client["client_id"],
            "redirect_uri": redirect, "code_verifier": verifier}


def grant_oauth(origin, account):
    pending = begin_oauth(origin)
    _, headers = request(origin, "POST", "/oauth/login", {
        "request": pending["request"], "email": account["email"], "password": account["password"],
    }, form=True, expect=302)
    location = headers.get("Location") or headers.get("location")
    callback = urllib.parse.parse_qs(urllib.parse.urlsplit(location).query)
    assert callback["iss"] == [PUBLIC_ORIGIN]
    grant, _ = request(origin, "POST", "/oauth/token", {
        "grant_type": "authorization_code", "client_id": pending["client_id"],
        "redirect_uri": pending["redirect_uri"], "code_verifier": pending["code_verifier"],
        "code": callback["code"][0], "resource": PUBLIC_ORIGIN + "/mcp",
    }, form=True)
    assert grant.get("access_token") and grant.get("refresh_token")
    return {**grant, "client_id": pending["client_id"]}


def mcp(origin, grant, name, arguments=None):
    response, _ = request(origin, "POST", "/mcp", {
        "jsonrpc": "2.0", "id": "backup-acceptance", "method": "tools/call",
        "params": {"name": name, "arguments": arguments or {}},
    }, token=grant["access_token"])
    assert not response["result"].get("isError"), "Restored MCP session was rejected"
    return json.loads(response["result"]["content"][0]["text"])


def main(binary, source):
    binary = binary.resolve()
    assert binary.is_file()
    processes, logs = [], []
    with tempfile.TemporaryDirectory(prefix="gsd-populated-backup-") as directory:
        fixture = pathlib.Path(directory)
        root = fixture / "source"
        root.mkdir(mode=0o700)
        for name, original in (("gateway", source / "gateway"),
                               ("pb_hooks", source / "pocketbase/pb_hooks"),
                               ("pb_migrations", source / "pocketbase/pb_migrations")):
            (root / name).mkdir()
            for candidate in original.iterdir():
                if candidate.is_file() and candidate.suffix in (".mjs", ".js", ".json"):
                    if ".test." not in candidate.name:
                        shutil.copyfile(candidate, root / name / candidate.name)
        try:
            origin = start_fixture(root, binary, processes, logs)
            accounts, grants, views = [], [], []
            stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(
                timespec="milliseconds").replace("+00:00", "Z")
            for index in range(2):
                email = f"backup-{index}@example.invalid"
                password = secrets.token_urlsafe(28)
                user, _ = request(origin, "POST", "/api/collections/users/records", {
                    "email": email, "password": password, "passwordConfirm": password,
                    "display_name": "Isolated backup fixture",
                }, expect=(200, 201))
                auth, _ = request(origin, "POST", "/api/collections/users/auth-with-password", {
                    "identity": email, "password": password,
                })
                account = {"email": email, "password": password,
                           "id": user["id"], "token": auth["token"]}
                accounts.append(account)
                request(origin, "POST", "/api/collections/tasks/records", {
                    "owner": user["id"], "task_id": "backup-task-" + str(index),
                    "title": "Isolated populated backup", "urgent": False, "important": True,
                    "tags": [], "subtasks": [], "dependencies": [], "time_entries": [],
                    "client_updated_at": stamp, "client_created_at": stamp,
                    "device_id": "isolated-backup-fixture",
                }, token=auth["token"], expect=(200, 201))
                view_id = "backup-view-" + str(index)
                view = {"id": view_id, "name": "Backup view", "icon": "cloud",
                        "isBuiltIn": False, "createdAt": 1795521600000,
                        "updatedAt": 1795521600000, "criteria": {"tags": ["backup"]}}
                body = {"expected_version": "", "payload": json.dumps(view),
                        "client_updated_at": stamp, "deleted": False}
                request(origin, "PUT", "/api/gsd/library/view/" + view_id, body,
                        token=auth["token"], expect=204)
                views.append((view_id, body))
                grants.append(grant_oauth(origin, account))
            begin_oauth(origin)  # Preserve a real, unconsumed pending grant too.
            database = root / "pb_data/data.db"
            before = snapshot(database)
            assert {name: before["counts"][name] for name in ("users", "tasks", "gsd_library")} == {
                "users": 2, "tasks": 2, "gsd_library": 2,
            }
            assert (root / "pb_data/data.db-wal").stat().st_size > 0
            state = (root / "gateway-state/gateway-state.json").read_bytes()
            state_counts = {group: len(value) for group, value in json.loads(state).items()}
            assert state_counts == {"clients": 3, "pending": 1, "codes": 0, "access": 2, "refresh": 2}
            key = (root / "gateway-state/gateway.key").read_bytes()
            assert len(key) == 32
            for account in accounts:
                assert account["token"].encode() not in state, "Upstream credentials are sealed"
            backup_directory = fixture / "backups"
            output = json.loads(run(["python3", str(source / "backup.py"), "--root", str(root),
                                     "--destination", str(backup_directory), "--keep", "2"]))
            archive = pathlib.Path(output["backup"])
            assert archive.parent == backup_directory
            assert archive.stat().st_size < 4 * 1024 * 1024
            assert stat.S_IMODE(archive.stat().st_mode) == 0o600
            assert stat.S_IMODE(backup_directory.stat().st_mode) == 0o700
            assert output["counts"] == {"users": 2, "tasks": 2, "gsd_library": 2}
            verified = json.loads(run(["python3", str(source / "backup.py"),
                                       "--verify", str(archive)]))
            assert verified["restore"] == "ok"
            restored = fixture / "restored"
            restored.mkdir()
            with tarfile.open(archive, "r:gz") as bundle:
                assert sum(member.size for member in bundle.getmembers()) < 32 * 1024 * 1024
                bundle.extractall(restored, filter="data")
            assert snapshot(restored / "pb_data/data.db") == before
            assert (restored / "gateway-state/gateway-state.json").read_bytes() == state
            assert (restored / "gateway-state/gateway.key").read_bytes() == key
            recovered = start_fixture(restored, binary, processes, logs)
            for index, account in enumerate(accounts):
                listing, _ = request(recovered, "GET", "/api/collections/tasks/records",
                                     token=account["token"])
                assert len(listing["items"]) == 1
                assert listing["items"][0]["owner"] == account["id"]
                tasks = mcp(recovered, grants[index], "list_tasks")["tasks"]
                assert len(tasks) == 1 and tasks[0]["owner"] == account["id"]
                view_id, body = views[index]
                request(recovered, "PUT", "/api/gsd/library/view/" + view_id, body,
                        token=account["token"], expect=412)
                renewed, _ = request(recovered, "POST", "/oauth/token", {
                    "grant_type": "refresh_token", "client_id": grants[index]["client_id"],
                    "refresh_token": grants[index]["refresh_token"],
                    "resource": PUBLIC_ORIGIN + "/mcp",
                }, form=True)
                assert renewed.get("access_token") and renewed.get("refresh_token")
                request(recovered, "POST", "/oauth/token", {
                    "grant_type": "refresh_token", "client_id": grants[index]["client_id"],
                    "refresh_token": grants[index]["refresh_token"],
                    "resource": PUBLIC_ORIGIN + "/mcp",
                }, form=True, expect=400)
            after = snapshot(restored / "pb_data/data.db")
            for name in ("users", "tasks", "gsd_library"):
                assert after["counts"][name] == 2, "Restored CAS replay must not duplicate records"
            report = {
                "result": "PASS", "actualPocketBaseVersion": run([str(binary), "--version"]).strip(),
                "gatewaySHA256": hashlib.sha256((source / "gateway/server.mjs").read_bytes()).hexdigest(),
                "backupScriptSHA256": hashlib.sha256((source / "backup.py").read_bytes()).hexdigest(),
                "sourceConnectionOpenDuringBackup": True,
                "counts": {"users": 2, "tasks": 2, "gsd_library": 2},
                "allDatabaseTableCount": len(before["counts"]),
                "logicalSHA256": before["logicalSHA256"],
                "gatewayStateCounts": state_counts,
                "gatewayStateSHA256": hashlib.sha256(state).hexdigest(),
                "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                "archiveSizeBytes": archive.stat().st_size,
                "databaseSizeBytes": (restored / "pb_data/data.db").stat().st_size,
                "integrity": "ok", "manifestVerify": True,
                "completeInitialLogicalDatabaseIdentity": True,
                "gatewayKeyAndStateByteIdentity": True,
                "restoredNativeSessionsAndAccountIsolation": True,
                "restoredMCPAccessAndRefreshRotation": True,
                "restoredVersionedReplayRejectedWithoutDuplicates": True,
                "productionDataUsed": False,
            }
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
            for handle in logs:
                handle.close()
    report["fixtureCleanup"] = True
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pocketbase", required=True, type=pathlib.Path)
    args = parser.parse_args()
    main(args.pocketbase, pathlib.Path(__file__).resolve().parent)
