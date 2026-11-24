#!/usr/bin/env python3
"""Install only the current user's GSD off-server task; no password or elevation."""
import argparse, csv, ctypes, datetime, hashlib, io, json, os, pathlib, re
import shutil, subprocess, sys, xml.etree.ElementTree as ET
from ctypes import wintypes

TASK = "GSD Cloud Offsite Backup"
ROOT = pathlib.Path(os.environ["LOCALAPPDATA"]) / "GSD"
TOOLS = ROOT / "BackupTools"
BACKUPS = ROOT / "Backups"
NAMESPACE = "http://schemas.microsoft.com/windows/2004/02/mit/task"

def command(args, timeout=30, required=True):
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    def decode(data):
        if data.startswith((b"\xff\xfe", b"\xfe\xff")):
            return data.decode("utf-16")
        if b"\0" in data[:200]:
            return data.decode("utf-16-le")
        return data.decode("utf-8-sig", errors="replace")
    result.stdout, result.stderr = decode(result.stdout), decode(result.stderr)
    if required and result.returncode:
        raise RuntimeError("Command rejected: " + args[0] + " (exit " + str(result.returncode) + ")")
    return result

def dacl(path):
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    descriptor = ctypes.c_void_p()
    getter = advapi.GetNamedSecurityInfoW
    getter.argtypes = [wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD,
                      ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                      ctypes.POINTER(ctypes.c_void_p)]
    getter.restype = wintypes.DWORD
    converter = advapi.ConvertSecurityDescriptorToStringSecurityDescriptorW
    converter.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                         ctypes.POINTER(wintypes.LPWSTR), ctypes.c_void_p]
    converter.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    if getter(str(path), 1, 4, None, None, None, None, ctypes.byref(descriptor)):
        raise RuntimeError("Cannot inspect backup ACL")
    output = wintypes.LPWSTR()
    try:
        if not converter(descriptor, 1, 4, ctypes.byref(output), None):
            raise RuntimeError("Cannot decode backup ACL")
        return output.value
    finally:
        if output:
            kernel.LocalFree(ctypes.cast(output, ctypes.c_void_p))
        kernel.LocalFree(descriptor)

def protect_directory(path, sid):
    existed = path.exists()
    path.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.is_junction():
        raise RuntimeError("Refusing a redirected GSD directory")
    if not existed:
        command(["icacls.exe", str(path), "/inheritance:r", "/grant:r",
                 "*" + sid + ":(OI)(CI)F", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F"])
    acl = dacl(path)
    flags = acl.partition("(")[0]
    trustees = [ace.split(";")[-1] for ace in re.findall(r"\(([^()]*)\)", acl)]
    if "P" not in flags or not trustees or not set(trustees) <= {sid, "SY", "BA", "S-1-5-18", "S-1-5-32-544"}:
        raise RuntimeError("Existing GSD directory ACL is not restricted; left unchanged")
    return acl

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-revision", required=True)
    args = parser.parse_args()
    account, sid = next(csv.reader(io.StringIO(command(["whoami.exe", "/user", "/fo", "csv", "/nh"]).stdout)))
    existing = command(["schtasks.exe", "/query", "/TN", TASK, "/XML"], required=False)
    if existing.returncode == 0:
        tree = ET.fromstring(existing.stdout.lstrip("\ufeff"))
        ns = {"t": NAMESPACE}
        principal = tree.findtext(".//t:Principal/t:UserId", namespaces=ns)
        program = tree.findtext(".//t:Actions/t:Exec/t:Command", namespaces=ns)
        arguments = tree.findtext(".//t:Actions/t:Exec/t:Arguments", namespaces=ns)
        if principal != sid or arguments != '"' + str(TOOLS / "offsite_backup.py") + '"':
            raise RuntimeError("Existing scheduled task does not match this GSD installation")
        if pathlib.Path(program).parent != pathlib.Path(sys.executable).parent:
            raise RuntimeError("Existing task interpreter differs")
    elif "cannot find" not in existing.stderr.lower() and "cannot find" not in existing.stdout.lower():
        raise RuntimeError("Task Scheduler inspection was denied; no changes made")
    acls = {str(path): protect_directory(path, sid) for path in [TOOLS, BACKUPS]}
    source = pathlib.Path(__file__).with_name("offsite_backup.py")
    target = TOOLS / source.name
    if target.exists() and not (TOOLS / "install.json").exists():
        raise RuntimeError("Existing worker has no GSD ownership receipt")
    target.write_bytes(source.read_bytes())
    python = pathlib.Path(sys.executable)
    pythonw = python.with_name("pythonw.exe")
    scheduled_python = pythonw if pythonw.is_file() else python
    ssh = shutil.which("ssh.exe")
    if not ssh:
        raise RuntimeError("Existing OpenSSH client is unavailable")
    settings = {"owner": TASK, "user_sid": sid, "user_account": account,
                "ssh_executable": ssh, "python_executable": str(scheduled_python),
                "source_revision": args.source_revision,
                "worker_sha256": hashlib.sha256(target.read_bytes()).hexdigest()}
    (TOOLS / "install.json").write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    ET.register_namespace("", NAMESPACE)
    def element(parent, name, value=None, **attributes):
        item = ET.SubElement(parent, name, attributes)
        if value is not None:
            item.text = value
        return item
    task = ET.Element("Task", {"version": "1.2", "xmlns": NAMESPACE})
    registration = element(task, "RegistrationInfo")
    element(registration, "Author", account)
    element(registration, "Description", "GSD-only SSH backup to CurrentUser DPAPI; requires this Windows user to be logged in.")
    element(registration, "URI", "\\" + TASK)
    triggers = element(task, "Triggers")
    calendar = element(triggers, "CalendarTrigger")
    day = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    element(calendar, "StartBoundary", day + "T03:35:00Z")
    element(calendar, "Enabled", "true")
    schedule = element(calendar, "ScheduleByDay")
    element(schedule, "DaysInterval", "1")
    logon = element(triggers, "LogonTrigger")
    element(logon, "Enabled", "true")
    element(logon, "Delay", "PT2M")
    element(logon, "UserId", sid)
    principals = element(task, "Principals")
    principal = element(principals, "Principal", id="Author")
    element(principal, "UserId", sid)
    element(principal, "LogonType", "InteractiveToken")
    element(principal, "RunLevel", "LeastPrivilege")
    options = element(task, "Settings")
    for name, value in [
        ("MultipleInstancesPolicy", "IgnoreNew"), ("DisallowStartIfOnBatteries", "false"),
        ("StopIfGoingOnBatteries", "false"), ("AllowHardTerminate", "true"),
        ("StartWhenAvailable", "true"), ("RunOnlyIfNetworkAvailable", "true"),
        ("AllowStartOnDemand", "true"), ("Enabled", "true"), ("Hidden", "false"),
        ("RunOnlyIfIdle", "false"), ("WakeToRun", "false"), ("ExecutionTimeLimit", "PT10M"),
        ("Priority", "7")]:
        element(options, name, value)
    retry = element(options, "RestartOnFailure")
    element(retry, "Interval", "PT10M")
    element(retry, "Count", "2")
    actions = element(task, "Actions", Context="Author")
    execute = element(actions, "Exec")
    element(execute, "Command", str(scheduled_python))
    element(execute, "Arguments", '"' + str(target) + '"')
    element(execute, "WorkingDirectory", str(TOOLS))
    definition = TOOLS / "offsite-task.xml"
    ET.ElementTree(task).write(definition, encoding="utf-16", xml_declaration=True)
    command(["schtasks.exe", "/create", "/TN", TASK, "/XML", str(definition), "/F"])
    installed = command(["schtasks.exe", "/query", "/TN", TASK, "/XML"]).stdout
    actual = ET.fromstring(installed.lstrip("\ufeff"))
    ns = {"t": NAMESPACE}
    assert actual.findtext(".//t:LogonType", namespaces=ns) == "InteractiveToken"
    # Task Scheduler omits the default LUA level when exporting XML.
    assert actual.findtext(".//t:RunLevel", default="LeastPrivilege", namespaces=ns) == "LeastPrivilege"
    boundary = actual.findtext(".//t:CalendarTrigger/t:StartBoundary", namespaces=ns)
    utc = datetime.datetime.fromisoformat(boundary.replace("Z", "+00:00")).astimezone(datetime.timezone.utc)
    assert (utc.hour, utc.minute) == (3, 35)
    assert actual.findtext(".//t:DaysInterval", namespaces=ns) == "1"
    assert actual.findtext(".//t:StartWhenAvailable", namespaces=ns) == "true"
    assert actual.findtext(".//t:Principal/t:UserId", namespaces=ns) == sid
    assert actual.findtext(".//t:Exec/t:Arguments", namespaces=ns) == '"' + str(target) + '"'
    receipt = dict(settings, task_name=TASK, installed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   schedule_utc="03:35 daily", catch_up="StartWhenAvailable and own-user logon + 2 minutes",
                   logon_type="InteractiveToken", run_level="LeastPrivilege", password_stored=False,
                   task_definition=str(definition), restricted_directory_acls=acls)
    (TOOLS / "installation-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
