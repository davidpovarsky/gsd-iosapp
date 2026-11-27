#!/usr/bin/env python3
"""Recover one synthetic GSD dataset through the unchanged real backup script."""
import argparse
import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid

POCKETBASE_VERSION = "0.40.6"
EXPECTED_COUNTS = {"users": 1, "tasks": 1, "gsd_library": 1}
RESERVED_PORTS = {8095, 8770, 8768, 8767, 8769, 20241}
MINIMUM_FREE_BYTES = 128 * 1024 * 1024


def require(condition: bool, code: str) -> None:
    if not condition:
        raise RuntimeError(code)


def digest(value: dict) -> str:
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def file_digest(path: pathlib.Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def request(origin: str, method: str, path: str, body: dict | None = None,
            token: str | None = None, expect: tuple = (200,)) -> dict:
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(origin + path, data=data, headers=headers, method=method)
    try:
        with HTTP.open(req, timeout=10) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    require(status in expect, "unexpected_http_status_" + str(status))
    result = json.loads(raw) if raw else {}
    require(isinstance(result, dict), "unexpected_json_shape")
    return result


def owned_origin(process: subprocess.Popen) -> str | None:
    # Port zero avoids a bind/release race. Read only this child's Linux socket FDs.
    inodes = set()
    for fd in pathlib.Path(f"/proc/{process.pid}/fd").iterdir():
        try:
            match = re.fullmatch(r"socket:\[(\d+)\]", os.readlink(fd))
        except FileNotFoundError:
            continue
        if match:
            inodes.add(match[1])
    addresses = []
    for line in pathlib.Path(f"/proc/{process.pid}/net/tcp").read_text().splitlines()[1:]:
        fields = line.split()
        if fields[3] != "0A" or fields[9] not in inodes:
            continue
        address, port_hex = fields[1].split(":")
        port = int(port_hex, 16)
        require(address == "0100007F" and port not in RESERVED_PORTS and port > 0,
                "fixture_listener_is_not_isolated_loopback")
        addresses.append("http://127.0.0.1:" + str(port))
    require(len(addresses) <= 1, "unexpected_fixture_listener_count")
    return addresses[0] if addresses else None


def stop(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
    require(process.poll() is not None, "owned_process_not_stopped")


@contextlib.contextmanager
def pocketbase(binary: pathlib.Path, root: pathlib.Path, children: list):
    with (root / "pocketbase.log").open("wb") as log:
        process = subprocess.Popen([
            str(binary), "serve", "--http=127.0.0.1:0",
            "--dir=" + str(root / "pb_data"),
            "--hooksDir=" + str(root / "pb_hooks"),
            "--migrationsDir=" + str(root / "pb_migrations"),
        ], cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        children.append(process)
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                require(process.poll() is None, "pocketbase_startup_exited")
                origin = owned_origin(process)
                if origin:
                    request(origin, "GET", "/api/health")
                    yield origin
                    return
                time.sleep(0.1)
            raise RuntimeError("pocketbase_startup_timeout")
        finally:
            stop(process)


def authenticate(origin: str, identity: str, password: str) -> tuple[str, str]:
    auth = request(origin, "POST", "/api/collections/users/auth-with-password",
                   {"identity": identity, "password": password})
    owner, token = auth["record"]["id"], auth["token"]
    require(isinstance(owner, str) and re.fullmatch(r"[a-z0-9]{15}", owner) is not None,
            "invalid_authenticated_owner")
    require(isinstance(token, str) and bool(token), "missing_authentication_token")
    return owner, token


def snapshot(origin: str, owner: str, token: str) -> dict:
    records = {}
    for collection in ("tasks", "gsd_library"):
        response = request(origin, "GET", "/api/collections/" + collection +
                           "/records?perPage=20", token=token)
        require(response["totalItems"] == 1 and len(response["items"]) == 1,
                "unexpected_" + collection + "_count")
        record = response["items"][0]
        require(record["owner"] == owner, "unexpected_record_owner")
        records[collection] = record
    return records


def seed(origin: str) -> tuple[str, str, str, dict]:
    tag = secrets.token_hex(7)
    identity = "gsd-recovery-" + tag + "@example.invalid"
    password = secrets.token_urlsafe(24) + "Az2!"
    request(origin, "POST", "/api/collections/users/records",
            {"email": identity, "password": password, "passwordConfirm": password},
            expect=(200, 201))
    owner, token = authenticate(origin, identity, password)
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = now.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    millis = int(now.timestamp() * 1000)
    task = {
        "owner": owner, "task_id": str(uuid.uuid4()),
        "title": "משימת שחזור — Café ☕", "description": "עברית ו־Unicode\nSecond line: résumé",
        "urgent": True, "important": True, "quadrant": "urgentImportant",
        "completed": False, "recurrence": "none", "tags": ["עברית", "café"],
        "subtasks": [], "dependencies": [], "time_entries": [],
        "client_created_at": stamp, "client_updated_at": stamp,
        "device_id": "gsd-nonempty-recovery-fixture",
    }
    request(origin, "POST", "/api/collections/tasks/records", task, token, (200, 201))
    view = {"id": str(uuid.uuid4()), "name": "תצוגת שחזור — Café", "icon": "cloud",
            "isBuiltIn": False, "createdAt": millis, "updatedAt": millis,
            "criteria": {"tags": ["עברית"]}}
    request(origin, "PUT", "/api/gsd/library/view/" + view["id"],
            {"expected_version": "", "payload": json.dumps(view, ensure_ascii=False),
             "client_updated_at": stamp, "deleted": False}, token, (204,))
    before = snapshot(origin, owner, token)
    require(all(before["tasks"][key] == value for key, value in task.items()),
            "seeded_task_content_mismatch")
    require(json.loads(before["gsd_library"]["payload"]) == view and
            before["gsd_library"]["kind"] == "view" and not before["gsd_library"]["deleted"],
            "seeded_library_content_mismatch")
    return identity, password, owner, before


def exercise(binary: pathlib.Path, cloud: pathlib.Path, workspace: pathlib.Path,
             receipt: dict, children: list) -> None:
    source, restored, archives = (workspace / name for name in ("source", "restored", "archives"))
    source.mkdir()
    restored.mkdir()
    for name in ("pb_hooks", "pb_migrations"):
        shutil.copytree(cloud / "pocketbase" / name, source / name)
    receipt["stage"] = "seed_source"
    with pocketbase(binary, source, children) as origin:
        identity, password, owner, before = seed(origin)
        receipt["stage"] = "online_backup"
        command = subprocess.run([
            sys.executable, str(cloud / "backup.py"), "--root", str(source),
            "--destination", str(archives), "--keep", "1",
        ], cwd=workspace, capture_output=True, timeout=90, check=False)
        require(command.returncode == 0, "backup_command_failed")
        backed_up = json.loads(command.stdout)
        require(backed_up["counts"] == EXPECTED_COUNTS and
                backed_up["integrity"] == "ok" and backed_up["restore"] == "ok",
                "nonempty_backup_verification_failed")
        archive = pathlib.Path(backed_up["backup"]).resolve()
        require(archive.parent == archives.resolve() and archive.is_file() and
                re.fullmatch(r"gsd-cloud-\d{8}T\d{6}Z\.tar\.gz", archive.name) is not None,
                "unexpected_backup_output_path")
        require(file_digest(archive) == backed_up["sha256"], "archive_digest_mismatch")
        receipt["backup"] = {key: backed_up[key] for key in
                             ("bytes", "sha256", "integrity", "restore", "counts")}
    receipt["source_stopped_before_restore"] = True
    receipt["stage"] = "restore_archive"
    with tarfile.open(archive, "r:gz") as bundle:
        bundle.extractall(restored, filter="data")
    receipt["stage"] = "authenticate_restored_copy"
    with pocketbase(binary, restored, children) as origin:
        restored_owner, token = authenticate(origin, identity, password)
        require(restored_owner == owner, "restored_account_identity_mismatch")
        after = snapshot(origin, restored_owner, token)
        receipt["content"] = {}
        for collection in ("tasks", "gsd_library"):
            require(after[collection] == before[collection], "restored_" + collection + "_mismatch")
            receipt["content"][collection] = {"before_sha256": digest(before[collection]),
                                              "restored_sha256": digest(after[collection])}
        receipt["authenticated_restored_read"] = True


def interrupted(signum: int, frame) -> None:
    raise InterruptedError("fixture_interrupted")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pocketbase", required=True, type=pathlib.Path)
    parser.add_argument("--work-parent", required=True, type=pathlib.Path)
    parser.add_argument("--receipt", required=True, type=pathlib.Path)
    args = parser.parse_args()
    require(sys.platform == "linux" and sys.version_info >= (3, 12), "requires_linux_python312")
    binary, parent = args.pocketbase.resolve(strict=True), args.work_parent.resolve(strict=True)
    require(binary.is_file() and parent.is_dir(), "invalid_fixture_inputs")
    require(shutil.disk_usage(parent).free >= MINIMUM_FREE_BYTES, "insufficient_fixture_disk_space")
    cloud = pathlib.Path(__file__).resolve().parent
    sources = [cloud / "backup.py", pathlib.Path(__file__).resolve()]
    for name in ("pb_hooks", "pb_migrations"):
        tree = sorted((cloud / "pocketbase" / name).rglob("*"))
        require(tree and all(not path.is_symlink() for path in tree), "invalid_fixture_source_tree")
        sources += [path for path in tree if path.is_file()]
    require(len(sources) >= 6 and all(path.is_file() and not path.is_symlink() for path in sources),
            "missing_fixture_source_files")
    os.umask(0o077)
    receipt = {"schema": 1, "passed": False, "stage": "preflight",
               "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "input_sha256": {str(path.relative_to(cloud)): file_digest(path) for path in sources}}
    children, workspace, cleanup_errors = [], None, []
    signal.signal(signal.SIGTERM, interrupted)
    with args.receipt.open("x", encoding="utf-8") as report:
        try:
            workspace = pathlib.Path(tempfile.mkdtemp(prefix="gsd-nonempty-recovery-", dir=parent))
            version = subprocess.run([str(binary), "--version"], cwd=workspace,
                                     capture_output=True, text=True, timeout=15, check=False)
            match = re.search(r"\b(\d+\.\d+\.\d+)\b", version.stdout)
            require(version.returncode == 0 and match is not None and match[1] == POCKETBASE_VERSION,
                    "unexpected_pocketbase_version")
            receipt["pocketbase"] = {"version": POCKETBASE_VERSION, "sha256": file_digest(binary)}
            exercise(binary, cloud, workspace, receipt, children)
            receipt["checks_passed"] = True
        except BaseException as error:
            receipt["failure_type"] = type(error).__name__
            # Only our fixed codes are eligible for evidence; no response bodies or auth records.
            if type(error) is RuntimeError:
                receipt["failure_code"] = str(error)
        finally:
            for process in reversed(children):
                try:
                    stop(process)
                except BaseException as error:
                    cleanup_errors.append(type(error).__name__)
            stopped = all(process.poll() is not None for process in children)
            if workspace is not None and stopped:
                try:
                    shutil.rmtree(workspace)
                except BaseException as error:
                    cleanup_errors.append(type(error).__name__)
            removed = workspace is None or not workspace.exists()
            receipt["cleanup"] = {"owned_processes_stopped": stopped, "owned_directory_removed": removed,
                                  "errors": cleanup_errors}
            receipt["passed"] = bool(receipt.get("checks_passed") and stopped and removed and not cleanup_errors)
            receipt["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            report.write(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": receipt["passed"], "stage": receipt["stage"], "cleanup": receipt["cleanup"]}))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
