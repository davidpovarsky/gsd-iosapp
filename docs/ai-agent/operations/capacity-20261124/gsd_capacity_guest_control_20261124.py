"""Fixed root-only launch/observe controller. No arbitrary command or target input."""
import base64, datetime, hashlib, json, os, pathlib, re, stat, subprocess

BASE = pathlib.Path("/var/lib/gsd-capacity-20261124")
WORKER_SHA = "4da02615b3b3eec8cc6b8021ca57749b382e479e1e5957005cf802edf97aa914"
PHASES = ("root-growfs", "data-growfs")

def require(ok, code):
    if not ok:
        raise RuntimeError(code)

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def directory(path, create=False):
    if create and not path.exists():
        path.mkdir(mode=0o700)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
            and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700, "PRIVATE_DIRECTORY_CHANGED")

def atomic(path, value):
    raw = (json.dumps(value, sort_keys=True) + "\n").encode()
    temp = path.with_name(path.name + ".tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def read_json(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode)
            and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_size <= 2 * 1024 * 1024, "PRIVATE_RECEIPT_CHANGED")
    return json.loads(path.read_text())

def observe(folder, operation_id, phase):
    for path in (BASE, BASE / operation_id, folder):
        directory(path)
    intent = read_json(folder / "intent.json")
    require(intent["operation_id"] == operation_id and intent["phase"] == phase
            and intent["source_sha256"] == WORKER_SHA, "INTENT_BINDING_CHANGED")
    source = folder / "worker.py"
    info = source.lstat()
    require(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode) and info.st_uid == 0
            and stat.S_IMODE(info.st_mode) == 0o600
            and hashlib.sha256(source.read_bytes()).hexdigest() == WORKER_SHA, "WORKER_SOURCE_CHANGED")
    report = {"phase": phase, "operation_id": operation_id, "observed_utc": now(),
              "source_sha256": WORKER_SHA, "server_directory": str(folder)}
    if (folder / "result.json").exists():
        result = read_json(folder / "result.json")
        require(result["phase"] == phase and result["operation_id"] == operation_id
                and result.get("source_sha256") == WORKER_SHA, "FINAL_RECEIPT_BINDING_CHANGED")
        require((result["status"], result["exit_code"]) in (("PASS", 0), ("FAILED", 1)), "FINAL_STATUS_EXIT_MISMATCH")
        report.update({"status": result["status"], "guest": result})
        return report
    launch = read_json(folder / "launch.json") if (folder / "launch.json").exists() else None
    progress = read_json(folder / "progress.json") if (folder / "progress.json").exists() else None
    pid = progress.get("worker_pid") if progress else (launch or {}).get("pid")
    require(isinstance(pid, int) and pid > 1, "LAUNCH_OUTCOME_UNKNOWN_NO_RETRY")
    proc = pathlib.Path("/proc") / str(pid)
    require(proc.exists() and proc.stat().st_uid == 0, "WORKER_MISSING_WITHOUT_FINAL_RECEIPT")
    args = (proc / "cmdline").read_bytes().split(b"\0")[:-1]
    expected = [b"/usr/bin/python3", str(source).encode(), b"--phase", phase.encode(),
                b"--operation-id", operation_id.encode(), b"--execute"]
    require(args == expected, "WORKER_PID_IDENTITY_CHANGED")
    start = (proc / "stat").read_text().rsplit(") ", 1)[1].split()[19]
    if progress:
        require(progress["phase"] == phase and progress["operation_id"] == operation_id
                and progress["source_sha256"] == WORKER_SHA and progress["worker_start_ticks"] == start,
                "WORKER_START_IDENTITY_CHANGED")
    report.update({"status": "PENDING", "worker_pid": pid, "worker_start_ticks": start,
                   "current_step": progress.get("current_step") if progress else "worker-starting"})
    return report

def main(request):
    result = {"status": "FAILED", "observed_utc": now()}
    try:
        require(os.geteuid() == 0, "ROOT_REQUIRED")
        require(set(request) <= {"action", "phase", "operation_id", "source_base64"}, "UNEXPECTED_REQUEST_FIELD")
        action, phase, operation_id = request["action"], request["phase"], request["operation_id"]
        require(action in ("launch", "observe") and phase in PHASES
                and re.fullmatch(r"[0-9a-f]{32}", operation_id), "REQUEST_BINDING_INVALID")
        folder = BASE / operation_id / phase
        if action == "launch":
            raw = base64.b64decode(request["source_base64"], validate=True)
            require(hashlib.sha256(raw).hexdigest() == WORKER_SHA, "SOURCE_HASH_CHANGED")
            directory(BASE, create=True)
            directory(BASE / operation_id, create=True)
            # Existing phase directory always blocks launch, including an ambiguous crash before Popen.
            require(not folder.exists(), "PRIOR_SERVER_PHASE_NO_RELAUNCH")
            folder.mkdir(mode=0o700)
            atomic(folder / "intent.json", {"operation_id": operation_id, "phase": phase,
                   "source_sha256": WORKER_SHA, "created_utc": now(), "status": "REQUESTING"})
            source = folder / "worker.py"
            fd = os.open(source, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            out = os.open(folder / "stdout.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            err = os.open(folder / "stderr.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                child = subprocess.Popen(["/usr/bin/python3", str(source), "--phase", phase,
                    "--operation-id", operation_id, "--execute"], stdin=subprocess.DEVNULL,
                    stdout=out, stderr=err, cwd=folder, start_new_session=True, close_fds=True)
                atomic(folder / "launch.json", {"pid": child.pid, "created_utc": now(),
                       "operation_id": operation_id, "phase": phase, "source_sha256": WORKER_SHA})
            finally:
                os.close(out)
                os.close(err)
            result = {"status": "PENDING", "operation_id": operation_id, "phase": phase,
                      "worker_pid": child.pid, "source_sha256": WORKER_SHA,
                      "server_directory": str(folder), "observed_utc": now()}
        else:
            result = observe(folder, operation_id, phase)
    except Exception as error:
        result.update({"status": "FAILED", "error_type": type(error).__name__,
                       "error_code": str(error) if isinstance(error, RuntimeError) else "LOCAL_OBSERVER_OR_LAUNCH_FAILURE"})
    code = {"PASS": 0, "PENDING": 2, "FAILED": 1}[result["status"]]
    result["controller_exit_code"] = code
    print(json.dumps(result, sort_keys=True), flush=True)
    return code
