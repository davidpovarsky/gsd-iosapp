"""One owned, detached execution of the reviewed isolated recovery fixture."""
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

BASE = pathlib.Path(__file__).resolve().parent
DAEMONS = {
    "gsd-pocketbase.service": ("3365518", "7004392915116", "127.0.0.1:8095"),
    "gsd-cloud-gateway.service": ("3422173", "7011118358127", "127.0.0.1:8770"),
    "gsd-mcp-bridge.service": ("2118307", "6934668490142", "127.0.0.1:8768"),
    "lorvex-cloud.service": ("3336621", "7001739566839", "127.0.0.1:8769"),
    "lorvex-mcp-bridge.service": ("3287789", "6999133148522", "127.0.0.1:8767"),
    "lorvex-cf-quick.service": ("1807512", "6921133171227", "127.0.0.1:20241"),
}
SOURCE_COMMIT = "6ecccbbad34404a412e7eeca2f396ff6dc25292d"
BACKUP_SHA = "efea842528ce51a2f8a358c47216419b97bab5c8f46520720e690352f09e4e4a"


def require(ok, code):
    if not ok:
        raise RuntimeError(code)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def persist(name, payload):
    path = BASE / name
    temporary = BASE / (name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(payload, stream, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def observed_state():
    state = {"observed_at_utc": now(), "read_only": True, "services": {}, "free_space": {}}
    for mount in ("/", "/mnt/development"):
        fs = os.statvfs(mount)
        state["free_space"][mount] = {"available_bytes": fs.f_bavail * fs.f_frsize,
                                       "free_bytes": fs.f_bfree * fs.f_frsize,
                                       "available_inodes": fs.f_favail}
    for unit in DAEMONS:
        command = subprocess.run(["systemctl", "show", unit, "--property=Id", "--property=ActiveState",
                                  "--property=SubState", "--property=MainPID",
                                  "--property=ExecMainStartTimestampMonotonic"],
                                 capture_output=True, text=True, timeout=10, check=True)
        state["services"][unit] = dict(line.split("=", 1) for line in command.stdout.splitlines() if "=" in line)
    command = subprocess.run(["ss", "-H", "-ltnp"], capture_output=True, text=True, timeout=10, check=True)
    state["sockets"] = {unit: [] for unit in DAEMONS}
    pids = {pid: unit for unit, (pid, _, _) in DAEMONS.items()}
    for line in command.stdout.splitlines():
        for pid in set(re.findall(r"pid=(\d+),", line)) & pids.keys():
            fields = line.split()
            state["sockets"][pids[pid]].append({"state": fields[0], "local_address": fields[3], "peer_address": fields[4]})
    state["health"] = {}
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for label, url in (("pocketbase", "http://127.0.0.1:8095/api/health"),
                       ("public_gateway", "https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud/api/health")):
        with client.open(url, timeout=10) as response:
            state["health"][label] = {"http_status": response.status,
                                      "body_code": json.loads(response.read(16384)).get("code")}
    # Allocation metadata only, no contents and no following symlinks into other projects.
    try:
        command = subprocess.run(["du", "-s", "-B1", "--one-file-system", "--",
                                  "/mnt/development/projects/gsd-cloud"],
                                 capture_output=True, text=True, timeout=10, check=False)
        state["gsd_owned_directory"] = {"path": "/mnt/development/projects/gsd-cloud",
                                         "exit_code": command.returncode, "measurement": "allocated_bytes"}
        if command.returncode == 0:
            state["gsd_owned_directory"]["allocated_bytes"] = int(command.stdout.split("\t", 1)[0])
    except subprocess.TimeoutExpired:
        state["gsd_owned_directory"] = {"path": "/mnt/development/projects/gsd-cloud", "bounded_read_timeout_seconds": 10}
    for unit, (pid, started, address) in DAEMONS.items():
        service = state["services"][unit]
        require(service["MainPID"] == pid and service["ExecMainStartTimestampMonotonic"] == started
                and service["ActiveState"] == "active" and service["SubState"] == "running", "SERVICE_CONTINUITY_CHANGED")
        require(state["sockets"][unit] == [{"state": "LISTEN", "local_address": address,
                                           "peer_address": "0.0.0.0:*"}], "SOCKET_CONTINUITY_CHANGED")
    require(all(value == {"http_status": 200, "body_code": 200} for value in state["health"].values()),
            "GSD_HEALTH_FAILED")
    state["lorvex_scope"] = "Selected unit/PID/start/socket continuity only, not application functional acceptance."
    return state


def main():
    os.umask(0o077)
    # Permanent exclusive claim means an uncertain observer cannot execute the fixture twice.
    claim = os.open(BASE / "execution.claim", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(claim)
    report = {"schema": 1, "status": "RUNNING", "source_commit": SOURCE_COMMIT,
              "started_at_utc": now(), "scope": "One isolated synthetic real-PocketBase backup/restore; no production data or service mutations."}
    persist("progress.json", report)
    child = None
    try:
        require(BASE.stat().st_dev == pathlib.Path("/").stat().st_dev, "SOURCE_NOT_ON_ROOT_FILESYSTEM")
        report["before"] = observed_state()
        require(report["before"]["free_space"]["/"]["available_bytes"] >= 128 * 1024 * 1024, "ROOT_FREE_BELOW_MINIMUM")
        production_backup = pathlib.Path("/mnt/development/projects/gsd-cloud/backup.py")
        require(production_backup.is_file() and not production_backup.is_symlink(), "PRODUCTION_BACKUP_SOURCE_INVALID")
        report["production_backup_sha256"] = hashlib.sha256(production_backup.read_bytes()).hexdigest()
        require(report["production_backup_sha256"] == BACKUP_SHA, "PRODUCTION_BACKUP_SOURCE_DIFFERENT")
        source = BASE / "source"
        parent = BASE / "fixture-parent"
        parent.mkdir(mode=0o700)
        report["stage"] = "fixture_running"
        persist("progress.json", report)
        with (BASE / "fixture.stdout").open("xb") as stdout, (BASE / "fixture.stderr").open("xb") as stderr:
            child = subprocess.Popen([sys.executable, str(source / "cloud/test_nonempty_backup_recovery.py"),
                                      "--pocketbase", "/mnt/development/projects/gsd-cloud/pocketbase",
                                      "--work-parent", str(parent), "--receipt", str(BASE / "fixture-receipt.json")],
                                     cwd=source, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, close_fds=True)
            report["fixture_pid"] = child.pid
            persist("progress.json", report)
            try:
                report["fixture_exit_code"] = child.wait(timeout=300)
            except subprocess.TimeoutExpired:
                # Terminate only the exact owned test process; its handler cleans its own children/data.
                child.send_signal(signal.SIGTERM)
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    report["owned_process_cleanup_requires_inspection"] = True
                raise RuntimeError("FIXTURE_BOUNDED_TIMEOUT")
        require((BASE / "fixture-receipt.json").is_file(), "FIXTURE_RECEIPT_MISSING")
        report["fixture"] = json.loads((BASE / "fixture-receipt.json").read_text())
        require(report["fixture_exit_code"] == 0 and report["fixture"].get("passed") is True, "FIXTURE_FAILED")
        require(not list(parent.iterdir()), "FIXTURE_DIRECTORY_NOT_EMPTY_AFTER_CLEANUP")
        parent.rmdir()
        shutil.rmtree(source)
        report["source_staging_removed"] = not source.exists()
        report["fixture_parent_removed"] = not parent.exists()
        report["status"] = "PASS"
    except BaseException as error:
        report["status"] = "FAILED"
        report["failure_type"] = type(error).__name__
        if type(error) is RuntimeError:
            report["failure_code"] = str(error)
        path = BASE / "fixture-receipt.json"
        if path.is_file():
            try:
                report["fixture"] = json.loads(path.read_text())
            except Exception:
                report["fixture_receipt_parse_failed"] = True
    finally:
        report["owned_fixture_process_finished"] = child is None or child.poll() is not None
        try:
            report["after"] = observed_state()
        except BaseException as error:
            report["status"] = "FAILED"
            report["postflight_failure_type"] = type(error).__name__
            if type(error) is RuntimeError:
                report["postflight_failure_code"] = str(error)
        report["finished_at_utc"] = now()
        persist("result.json", report)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
