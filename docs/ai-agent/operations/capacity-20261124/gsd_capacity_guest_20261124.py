"""Fixed GSD guest growth phase, invoked only after provider and root review gates.
No installation, service control, arbitrary target, forced filesystem repair or shrink.
"""
import argparse, datetime, hashlib, json, os, pathlib, re, stat, subprocess, sys, time

VERSION = "gsd-capacity-guest-20261124-v1"
SERVER_BASE = pathlib.Path("/var/lib/gsd-capacity-20261124")
PHASE_DIR = None
EXPECTED = {
    "disk_guid": "4e44426202694eab4128311e657c132ba2422dd18de921d32759ad33d4bcaa99",
    "root_fs": "5312b5cffd5a50b5b3901d84f5e016c33d5acd47c08c6109a7480a1ab6947561",
    "data_fs": "fd89070272a5c0ad7fdbb22f8080e0597c1550a537a44193ceb4440032a9179b",
    "efi_fs": "6e77d863281574d82c08403bc2ce39f24eca3c420f0e4f335dcda1a2261b80c3",
    "boot_fs": "9cb9073c0d727567850ea3e4d51f3ece22be8b84bc6f793ed5cd825892c54cde",
}
PARTS = {
    "/dev/sda1": (2099200, None, "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "8393a388fc854eef61a7e08096d57182092427cfff17bff81fd0258434fe66bd"),
    "/dev/sda15": (2048, 202753, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "4d37fcca42d085b9834178b6adc2d34f813f91c8c4f0359f4694d340dafb4112"),
    "/dev/sda16": (206848, 1890305, "BC13C2FF-59E6-4262-A352-B275FD6F7172", "0cd949437776a437b816e629a604bb8979702a4b742bfa24199868be2c3c870c"),
}
DAEMONS = {
    "gsd-pocketbase.service": ("3365518", "7004392915116", "127.0.0.1:8095"),
    "gsd-cloud-gateway.service": ("3422173", "7011118358127", "127.0.0.1:8770"),
    "gsd-mcp-bridge.service": ("2118307", "6934668490142", "127.0.0.1:8768"),
    "lorvex-cloud.service": ("3336621", "7001739566839", "127.0.0.1:8769"),
    "lorvex-mcp-bridge.service": ("3287789", "6999133148522", "127.0.0.1:8767"),
    "lorvex-cf-quick.service": ("1807512", "6921133171227", "127.0.0.1:20241"),
}
BOOT_OLD, BOOT_NEW = 50010783744, 53687091200
DATA_OLD, DATA_NEW = 107374182400, 110595407872
ROOT_PART_OLD, ROOT_PART_NEW = 95578079, 102758367
ROOT_FS_OLD, ROOT_FS_NEW = 11947259, 12844795
DATA_FS_OLD, DATA_FS_NEW = 26214400, 27000832

class GuardFailure(Exception):
    pass

def require(ok, code):
    if not ok:
        raise GuardFailure(code)

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def persist(receipt, final=False):
    if PHASE_DIR is None:  # The strict preflight remains read-only on Oracle.
        return
    path = PHASE_DIR / ("result.json" if final else "progress.json")
    temp = path.with_name(path.name + ".tmp")
    descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write((json.dumps(receipt, sort_keys=True) + "\n").encode())
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    directory = os.open(PHASE_DIR, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)

def uuid_hash(value):
    return hashlib.sha256(str(value).lower().encode()).hexdigest()

def check_table(table, root_sectors, expected_last=None):
    require(table.get("label") == "gpt" and table.get("device") == "/dev/sda"
            and table.get("unit") == "sectors" and table.get("sectorsize") == 512
            and table.get("firstlba") == 34, "GPT_FORMAT_CHANGED")
    require(uuid_hash(table.get("id")) == EXPECTED["disk_guid"], "GPT_ID_CHANGED")
    if expected_last is not None:
        require(table.get("lastlba") == expected_last, "GPT_END_UNEXPECTED")
    else:
        require(table.get("lastlba") in (97677278, 104857566), "GPT_END_UNEXPECTED")
    parts = {item["node"]: item for item in table["partitions"]}
    require(set(parts) == set(PARTS), "PARTITION_SET_CHANGED")
    for node, (start, size, kind, fingerprint) in PARTS.items():
        item = parts[node]
        require(set(item) == {"node", "start", "size", "type", "uuid"}, "PARTITION_FIELDS_CHANGED")
        require(item["start"] == start and item["size"] == (root_sectors if size is None else size)
                and item["type"].upper() == kind and uuid_hash(item["uuid"]) == fingerprint,
                "PARTITION_IDENTITY_OR_GEOMETRY_CHANGED")

def check_services(state):
    require(state["listening_socket_command_exit"] == 0, "SOCKET_READ_FAILED")
    for unit, (pid, started, address) in DAEMONS.items():
        service = state["services"][unit]
        require(service["MainPID"] == pid and service["ExecMainStartTimestampMonotonic"] == started
                and service["ActiveState"] == "active" and service["SubState"] == "running",
                "DAEMON_CONTINUITY_CHANGED")
        sockets = state["listening_sockets_by_service"][unit]
        require(sockets == [{"local_address": address, "peer_address": "0.0.0.0:*", "state": "LISTEN"}],
                "DAEMON_SOCKET_CHANGED")
    require(all(state["health"].get(key) == {"body_code": 200, "http_status": 200}
                for key in ("pocketbase", "public_gateway")), "GSD_HEALTH_FAILED")

def check_identity(state, boot_sizes, data_sizes, root_sectors, root_blocks, data_blocks):
    require(state["kernel_release"] == "6.17.0-1020-oracle", "KERNEL_CHANGED")
    devices = state["devices"]
    for path, minor in (("/dev/sda", 0), ("/dev/sda1", 1), ("/dev/sdb", 16)):
        item = devices[path]
        require(item["major"] == 8 and item["minor"] == minor and item["owner_uid"] == 0
                and item["realpath"] == path, "DEVICE_NODE_CHANGED")
    require(devices["/dev/sda"]["size_bytes"] in boot_sizes and devices["/dev/sdb"]["size_bytes"] in data_sizes
            and devices["/dev/sda1"]["size_bytes"] == root_sectors * 512, "DEVICE_CAPACITY_UNEXPECTED")
    check_table(state["root_partition_table"]["partitiontable"], root_sectors)
    disks = {item["path"]: item for item in state["block_topology"]["blockdevices"]}
    require(set(disks) == {"/dev/sda", "/dev/sdb"}, "BLOCK_SET_CHANGED")
    boot, data = disks["/dev/sda"], disks["/dev/sdb"]
    require(boot["type"] == "disk" and boot["maj:min"] == "8:0" and boot["fstype"] is None
            and uuid_hash(boot["ptuuid"]) == EXPECTED["disk_guid"], "BOOT_BLOCK_ID_CHANGED")
    require(data["type"] == "disk" and data["maj:min"] == "8:16" and data["fstype"] == "ext4"
            and data.get("ptuuid") is None and data.get("partuuid") is None and not data.get("children")
            and data["mountpoints"] == ["/mnt/development"]
            and uuid_hash(data["uuid"]) == EXPECTED["data_fs"], "DATA_WHOLE_DEVICE_CHANGED")
    children = {item["path"]: item for item in boot["children"]}
    require(set(children) == set(PARTS), "BOOT_CHILDREN_CHANGED")
    for path, fstype, mount, fskey in (("/dev/sda1", "ext4", "/", "root_fs"),
                                      ("/dev/sda15", "vfat", "/boot/efi", "efi_fs"),
                                      ("/dev/sda16", "ext4", "/boot", "boot_fs")):
        item = children[path]
        require(item["type"] == "part" and item["pkname"] == "sda" and item["fstype"] == fstype
                and item["mountpoints"] == [mount] and uuid_hash(item["uuid"]) == EXPECTED[fskey]
                and uuid_hash(item["partuuid"]) == PARTS[path][3], "PROTECTED_BOOT_IDENTITY_CHANGED")
    for mount, device, fskey, blocks, minor in (("/", "/dev/sda1", "root_fs", root_blocks, "8:1"),
                                               ("/mnt/development", "/dev/sdb", "data_fs", data_blocks, "8:16")):
        mounts = state["mounts"][mount]["filesystems"]
        require(len(mounts) == 1, "MOUNT_AMBIGUOUS")
        item = mounts[0]
        require(item["source"] == device and item["target"] == mount and item["fstype"] == "ext4"
                and item["maj:min"] == minor and "rw" in item["options"].split(",")
                and uuid_hash(item["uuid"]) == EXPECTED[fskey], "MOUNT_IDENTITY_CHANGED")
        fs = state["filesystems"][device]
        require(uuid_hash(fs["Filesystem UUID"]) == EXPECTED[fskey]
                and fs["Block size"] == "4096" and int(fs["Block count"]) == blocks
                and fs["Filesystem state"] == "clean" and fs["Reserved block count"] == "0"
                and int(fs.get("FS Error count", "0")) == 0, "FILESYSTEM_STATE_UNEXPECTED")
    check_services(state)

def parse_dry_run(text, verified_disk_bytes):
    marker = "# === new sfdisk -d ==="
    require(text.count(marker) == 1, "DRY_RUN_TABLE_MISSING")
    table = {"partitions": []}
    for line in text.split(marker, 1)[1].splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("/dev/"):
            node, values = line.split(":", 1)
            item = {"node": node.strip()}
            for field in values.split(","):
                key, value = field.strip().split("=", 1)
                require(key in ("start", "size", "type", "uuid"), "DRY_RUN_EXTRA_PARTITION_FIELD")
                item[key] = int(value) if key in ("start", "size") else value.strip()
            table["partitions"].append(item)
        else:
            key, value = line.split(":", 1)
            key = {"label-id": "id", "first-lba": "firstlba", "last-lba": "lastlba", "sector-size": "sectorsize"}.get(key, key)
            require(key in ("label", "id", "device", "unit", "firstlba", "lastlba", "sectorsize"), "DRY_RUN_EXTRA_HEADER")
            table[key] = int(value) if key in ("firstlba", "lastlba", "sectorsize") else value.strip()
    # Installed growpart 0.33-1 intentionally removes last-lba from the dump
    # so sfdisk relocates the backup GPT. Derive that header only from the
    # already verified whole-device capacity; still require the exact end
    # through the proposed partition size, and read the actual GPT after write.
    require("lastlba" not in table and verified_disk_bytes == BOOT_NEW, "DRY_RUN_GPT_HEADER_UNEXPECTED")
    table["lastlba"] = verified_disk_bytes // 512 - 34
    check_table(table, ROOT_PART_NEW, 104857566)
    table["lastlba_evidence"] = "Derived from verified disk bytes; installed growpart removes this header. Actual post-write GPT is checked separately."
    return table

def command(receipt, label, argv, mutation=False):
    receipt["current_step"] = label
    record = {"step": label, "argv": argv, "started_utc": now(), "mutation": mutation}
    receipt["commands"].append(record)
    persist(receipt)  # Durable current-step intent before each command/write.
    # A started filesystem/partition write is never killed by an artificial command timeout.
    child = subprocess.run(argv, capture_output=True, text=True, timeout=None if mutation else 20,
                           env={**os.environ, "LC_ALL": "C"})
    record.update({"exit_code": child.returncode, "finished_utc": now(),
                   "stdout": child.stdout[:65536], "stderr": child.stderr[:65536]})
    persist(receipt)
    require(child.returncode == 0, "COMMAND_FAILED_" + label.upper().replace("-", "_"))
    return child

def rescan(receipt, name, expected_size):
    command(receipt, name + "-direct-read", ["dd", "iflag=direct", "if=/dev/" + name, "of=/dev/null", "count=1"])
    path = pathlib.Path("/sys/class/block") / name / "device/rescan"
    info = path.stat()
    require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o200 and stat.S_ISREG(info.st_mode), "RESCAN_CONTROL_CHANGED")
    receipt["current_step"] = name + "-rescan"
    receipt["commands"].append({"step": name + "-rescan", "path": str(path), "mutation": True, "started_utc": now()})
    persist(receipt)
    with path.open("w") as stream:
        stream.write("1\n")
    receipt["commands"][-1]["finished_utc"] = now()
    persist(receipt)
    for attempt in range(5):
        result = command(receipt, name + "-capacity-read", ["blockdev", "--getsize64", "/dev/" + name])
        if int(result.stdout.strip()) == expected_size:
            return
        if attempt < 4:
            time.sleep(1)
    raise GuardFailure("RESCAN_CAPACITY_NOT_VISIBLE")

def snapshot():
    import subprocess, pathlib, json, os, stat, shutil, datetime, urllib.request, re
    report={"observed_at_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),"read_only":True,"guest_writes":0,"scope":"Selected root/data device metadata, installed utilities, GSD/Lorvex unit and socket continuity only"}
    def run(args,timeout=12,allow_failure=False):
     p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
     if p.returncode and not allow_failure:raise RuntimeError("read_only_command_failed:"+pathlib.Path(args[0]).name+":"+str(p.returncode))
     return p
    os_release={}
    for line in pathlib.Path('/etc/os-release').read_text().splitlines():
     k,sep,v=line.partition('=')
     if sep and k in ('ID','VERSION_ID','PRETTY_NAME'):os_release[k]=v.strip('"')
    report['os']=os_release
    report['kernel_release']=os.uname().release
    wanted=('growpart','resize2fs','sfdisk','lsblk','blockdev','findmnt','tune2fs','partx','udevadm','dd','systemctl','ss','python3')
    report['tools']={name:shutil.which(name) for name in wanted}
    p=run(['dpkg-query','--show','--showformat=${binary:Package}\t${Version}\t${db:Status-Status}\n','cloud-guest-utils','e2fsprogs','util-linux'],allow_failure=True)
    report['package_versions']={'exit_code':p.returncode,'rows':p.stdout.splitlines()}
    report['devices']={}
    for device in ('/dev/sda','/dev/sda1','/dev/sdb'):
     s=os.lstat(device)
     assert stat.S_ISBLK(s.st_mode) and not stat.S_ISLNK(s.st_mode)
     report['devices'][device]={'major':os.major(s.st_rdev),'minor':os.minor(s.st_rdev),'inode':str(s.st_ino),'node_device':str(s.st_dev),'owner_uid':s.st_uid,'realpath':str(pathlib.Path(device).resolve()),'size_bytes':int(run(['blockdev','--getsize64',device]).stdout.strip())}
    report['block_topology']=json.loads(run(['lsblk','--json','--bytes','--output','NAME,PATH,TYPE,PKNAME,SIZE,MAJ:MIN,FSTYPE,UUID,PARTUUID,PTUUID,MOUNTPOINTS','/dev/sda','/dev/sdb']).stdout)
    report['root_partition_table']=json.loads(run(['sfdisk','--json','/dev/sda']).stdout)
    report['mounts']={}
    report['free_space']={}
    for mount in ('/','/mnt/development'):
     report['mounts'][mount]=json.loads(run(['findmnt','--json','--target',mount,'--output','TARGET,SOURCE,FSTYPE,UUID,PARTUUID,MAJ:MIN,OPTIONS']).stdout)
     fs=os.statvfs(mount)
     report['free_space'][mount]={'block_size':fs.f_frsize,'total_bytes':fs.f_blocks*fs.f_frsize,'free_bytes':fs.f_bfree*fs.f_frsize,'available_bytes':fs.f_bavail*fs.f_frsize,'free_inodes':fs.f_ffree,'available_inodes':fs.f_favail}
    report['filesystems']={}
    keys={'Filesystem UUID','Filesystem features','Filesystem state','Errors behavior','Block count','Reserved block count','Free blocks','Block size','Filesystem created','Last mount time','Last write time','Last checked','FS Error count','First error time','Last error time'}
    for device in ('/dev/sda1','/dev/sdb'):
     rows={}
     for line in run(['tune2fs','-l',device]).stdout.splitlines():
      k,sep,v=line.partition(':')
      if sep and k.strip() in keys:rows[k.strip()]=v.strip()
     report['filesystems'][device]=rows
    report['rescan_controls']={}
    for name in ('sda','sdb'):
     p=pathlib.Path('/sys/class/block')/name/'device/rescan'
     s=p.stat()
     report['rescan_controls'][name]={'exists':True,'mode':oct(stat.S_IMODE(s.st_mode)),'owner_uid':s.st_uid,'write_performed':False}
    listed=run(['systemctl','list-units','--all','--type=service','--plain','--no-legend','lorvex*.service']).stdout
    lorvex=[]
    for line in listed.splitlines():
     parts=line.split()
     if parts and re.fullmatch(r'lorvex[A-Za-z0-9_.@-]*\.service',parts[0]):lorvex.append(parts[0])
    units=['gsd-pocketbase.service','gsd-cloud-gateway.service','gsd-mcp-bridge.service']+sorted(set(lorvex))
    report['services']={}
    properties=('Id','ActiveState','SubState','MainPID','ExecMainStartTimestamp','ExecMainStartTimestampMonotonic','ActiveEnterTimestamp','ExecMainCode','ExecMainStatus')
    for unit in units:
     args=['systemctl','show',unit]
     for prop in properties:args.extend(['--property',prop])
     values={}
     for line in run(args).stdout.splitlines():
      k,sep,v=line.partition('=')
      if sep and k in properties:values[k]=v
     report['services'][unit]=values
    pids={r['MainPID']:unit for unit,r in report['services'].items() if r.get('MainPID','0')!='0'}
    report['listening_sockets_by_service']={unit:[] for unit in report['services']}
    p=run(['ss','-H','-ltnp'],allow_failure=True)
    report['listening_socket_command_exit']=p.returncode
    if p.returncode==0:
     for line in p.stdout.splitlines():
      matched=set(re.findall(r'pid=(\d+),',line))&pids.keys()
      if matched:
       fields=line.split()
       for pid in matched:report['listening_sockets_by_service'][pids[pid]].append({'local_address':fields[3],'peer_address':fields[4],'state':fields[0]})
    report['health']={}
    for label,url in [('pocketbase','http://127.0.0.1:8095/api/health'),('public_gateway','https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud/api/health')]:
     try:
      with urllib.request.urlopen(url,timeout=10) as response:
       body=response.read(16384)
       data=json.loads(body)
       report['health'][label]={'http_status':response.status,'body_code':data.get('code')}
     except Exception as error:report['health'][label]={'error_type':type(error).__name__}
    report['lorvex_scope_limitation']='Unit and listening-socket continuity only; no verified Lorvex application health URL or functional E2E was used.'
    report['no_guest_rescan_growpart_resizefs_backup_or_restart']=True
    report['finished_at_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    return report

def main():
    global PHASE_DIR
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, choices=["preflight", "root-growfs", "data-growfs"])
    parser.add_argument("--operation-id", required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{32}", args.operation_id), "OPERATION_ID_INVALID")
    require(args.phase == "preflight" or args.execute, "EXECUTION_FLAG_REQUIRED")
    require(os.geteuid() == 0, "ROOT_REQUIRED")
    receipt = {"version": VERSION, "phase": args.phase, "operation_id": args.operation_id,
               "started_utc": now(), "status": "FAILED", "commands": [], "snapshots": {},
               "service_continuity_scope": "Six daemon PID/start/socket identities and known GSD HTTP health only; not Lorvex functional E2E"}
    try:
        if args.phase != "preflight":
            candidate = SERVER_BASE / args.operation_id / args.phase
            for path in (SERVER_BASE, SERVER_BASE / args.operation_id, candidate):
                info = path.lstat()
                require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
                        and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700, "PRIVATE_PHASE_DIRECTORY_CHANGED")
            intent = json.loads((candidate / "intent.json").read_text())
            source_hash = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
            require(intent["operation_id"] == args.operation_id and intent["phase"] == args.phase
                    and intent["source_sha256"] == source_hash, "SERVER_INTENT_BINDING_CHANGED")
            require(not (candidate / "result.json").exists() and not (candidate / "progress.json").exists(), "WORKER_ALREADY_STARTED_NO_RETRY")
            claim = os.open(candidate / "worker.lock", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.write(claim, str(os.getpid()).encode())
            os.fsync(claim)
            os.close(claim)  # Keep the claim file permanently; this phase cannot be relaunched.
            PHASE_DIR = candidate
            receipt["worker_pid"] = os.getpid()
            receipt["worker_start_ticks"] = pathlib.Path("/proc/self/stat").read_text().rsplit(") ", 1)[1].split()[19]
            receipt["source_sha256"] = source_hash
            receipt["current_step"] = "initial-identity-read"
            persist(receipt)
        before = snapshot()
        receipt["snapshots"]["before"] = before
        persist(receipt)
        if args.phase == "preflight":
            check_identity(before, (BOOT_OLD,), (DATA_OLD,), ROOT_PART_OLD, ROOT_FS_OLD, DATA_FS_OLD)
        elif args.phase == "root-growfs":
            check_identity(before, (BOOT_OLD, BOOT_NEW), (DATA_OLD,), ROOT_PART_OLD, ROOT_FS_OLD, DATA_FS_OLD)
            rescan(receipt, "sda", BOOT_NEW)
            after_rescan = snapshot()
            receipt["snapshots"]["after_rescan"] = after_rescan
            check_identity(after_rescan, (BOOT_NEW,), (DATA_OLD,), ROOT_PART_OLD, ROOT_FS_OLD, DATA_FS_OLD)
            dry = command(receipt, "root-partition-dry-run", ["growpart", "--dry-run", "/dev/sda", "1"])
            receipt["dry_run_proposed_table"] = parse_dry_run(dry.stderr, after_rescan["devices"]["/dev/sda"]["size_bytes"])
            # Re-read identities and health after dry run and immediately before actual partition growth.
            check_identity(snapshot(), (BOOT_NEW,), (DATA_OLD,), ROOT_PART_OLD, ROOT_FS_OLD, DATA_FS_OLD)
            command(receipt, "root-partition-grow", ["growpart", "/dev/sda", "1"], mutation=True)
            after_part = snapshot()
            receipt["snapshots"]["after_partition"] = after_part
            check_identity(after_part, (BOOT_NEW,), (DATA_OLD,), ROOT_PART_NEW, ROOT_FS_OLD, DATA_FS_OLD)
            check_table(after_part["root_partition_table"]["partitiontable"], ROOT_PART_NEW, 104857566)
            command(receipt, "root-filesystem-grow", ["resize2fs", "/dev/sda1"], mutation=True)
            after = snapshot()
            receipt["snapshots"]["after"] = after
            check_identity(after, (BOOT_NEW,), (DATA_OLD,), ROOT_PART_NEW, ROOT_FS_NEW, DATA_FS_OLD)
        else:
            check_identity(before, (BOOT_NEW,), (DATA_OLD, DATA_NEW), ROOT_PART_NEW, ROOT_FS_NEW, DATA_FS_OLD)
            rescan(receipt, "sdb", DATA_NEW)
            after_rescan = snapshot()
            receipt["snapshots"]["after_rescan"] = after_rescan
            check_identity(after_rescan, (BOOT_NEW,), (DATA_NEW,), ROOT_PART_NEW, ROOT_FS_NEW, DATA_FS_OLD)
            command(receipt, "data-filesystem-grow", ["resize2fs", "/dev/sdb"], mutation=True)
            after = snapshot()
            receipt["snapshots"]["after"] = after
            check_identity(after, (BOOT_NEW,), (DATA_NEW,), ROOT_PART_NEW, ROOT_FS_NEW, DATA_FS_NEW)
        if args.phase != "preflight":
            for device in ("/dev/sda1", "/dev/sdb"):
                require(receipt["snapshots"]["after"]["filesystems"][device]["Filesystem features"] ==
                        before["filesystems"][device]["Filesystem features"], "FILESYSTEM_FEATURES_CHANGED")
            require(receipt["snapshots"]["after"]["mounts"] == before["mounts"], "MOUNT_OPTIONS_CHANGED")
            receipt["filesystem_target_verified"] = True
        receipt["service_continuity_verified"] = True
        receipt["status"] = "PASS"
    except Exception as error:
        receipt.update({"error_type": type(error).__name__, "error_code": str(error) if isinstance(error, GuardFailure) else "LOCAL_OR_COMMAND_FAILURE"})
    finally:
        receipt["finished_utc"] = now()
        receipt["exit_code"] = 0 if receipt["status"] == "PASS" else 1
        persist(receipt, final=True)
        print(json.dumps(receipt, sort_keys=True), flush=True)
    return receipt["exit_code"]

if __name__ == "__main__":
    sys.exit(main())
