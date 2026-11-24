#!/usr/bin/env python3
"""GSD-only off-server backup: SSH -> memory -> CurrentUser DPAPI -> atomic file."""
import argparse, ctypes, datetime, hashlib, io, json, os, pathlib, queue, re
import shutil, subprocess, sys, tarfile, tempfile, threading, time
from ctypes import wintypes

MAX_ARCHIVE = 128 * 1024 * 1024
MAX_EXPANDED = 512 * 1024 * 1024
TRANSFER_TIMEOUT = 180
KEEP = 7
OWN_ARCHIVE = re.compile(r"gsd-cloud-\d{8}T\d{6}Z\.tar\.gz\.dpapi")
ROOT = pathlib.Path(os.environ.get("LOCALAPPDATA", ".")) / "GSD"
TOOLS = ROOT / "BackupTools"
BACKUPS = ROOT / "Backups"
STATE = TOOLS / "offsite-last-run.json"

class BackupFailure(Exception):
    pass

class Blob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]

def dpapi(data, decrypt=False):
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    source = ctypes.create_string_buffer(data, len(data))
    incoming = Blob(len(data), ctypes.cast(source, ctypes.POINTER(ctypes.c_ubyte)))
    outgoing = Blob()
    operation = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    operation.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.POINTER(Blob),
                          ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    operation.restype = wintypes.BOOL
    # No LOCAL_MACHINE flag: this uses the existing logged-in user's DPAPI identity.
    if not operation(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
        raise BackupFailure("dpapi_decryption_failed" if decrypt else "dpapi_encryption_failed")
    try:
        return ctypes.string_at(outgoing.pbData, outgoing.cbData)
    finally:
        kernel.LocalFree(ctypes.cast(outgoing.pbData, ctypes.c_void_p))

def atomic_write(path, data):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".gsd-offsite-", suffix=".tmp",
                                         dir=path.parent, delete=False) as output:
            temporary = pathlib.Path(output.name)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

def record_status(value):
    atomic_write(STATE, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8"))

REMOTE = r"""
import pathlib, re, datetime, runpy, hashlib, json, sys
root = pathlib.Path('/mnt/development/projects/gsd-cloud')
folder = root / 'backups'
paths = sorted(p for p in folder.iterdir()
               if p.is_file() and not p.is_symlink()
               and re.fullmatch(r'gsd-cloud-\d{8}T\d{6}Z\.tar\.gz', p.name))
if not paths:
    raise RuntimeError('no_gsd_archive')
path = paths[-1]
created = datetime.datetime.strptime(path.name[10:26], '%Y%m%dT%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
age = (datetime.datetime.now(datetime.timezone.utc) - created).total_seconds()
if age < -600 or age > 48 * 3600:
    raise RuntimeError('archive_not_recent')
if path.stat().st_size > 128 * 1024 * 1024:
    raise RuntimeError('archive_too_large')
verify = runpy.run_path(str(root / 'backup.py'))['verify']
counts = verify(path)
with path.open('rb') as source:
    data = source.read(128 * 1024 * 1024 + 1)
if len(data) > 128 * 1024 * 1024:
    raise RuntimeError('archive_too_large')
meta = {'name': path.name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
        'source_restore': 'ok', 'restored_counts': counts}
sys.stdout.buffer.write(json.dumps(meta, sort_keys=True).encode('utf-8') + b'\n')
sys.stdout.buffer.write(data)
"""

def receive_archive(ssh):
    args = [ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
            "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2", "torah-social", "python3", "-"]
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    chunks = queue.Queue(maxsize=4)
    stop = threading.Event()
    def reader():
        try:
            while not stop.is_set():
                part = process.stdout.read(65536)
                while not stop.is_set():
                    try:
                        chunks.put(part, timeout=0.5)
                        break
                    except queue.Full:
                        pass
                if not part:
                    return
        except (OSError, ValueError):
            pass
    thread = threading.Thread(target=reader, daemon=True)
    buffer = bytearray()
    deadline = time.monotonic() + TRANSFER_TIMEOUT
    try:
        process.stdin.write(REMOTE.encode("utf-8"))
        process.stdin.close()
        thread.start()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BackupFailure("ssh_transfer_timeout")
            try:
                part = chunks.get(timeout=min(1, remaining))
            except queue.Empty:
                if process.poll() is not None and not thread.is_alive():
                    raise BackupFailure("ssh_stream_failed")
                continue
            if not part:
                break
            if len(buffer) + len(part) > MAX_ARCHIVE + 65536:
                raise BackupFailure("transfer_limit_exceeded")
            buffer.extend(part)
        code = process.wait(timeout=max(1, deadline - time.monotonic()))
        if code:
            raise BackupFailure("ssh_exit_" + str(code))
    finally:
        stop.set()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        if process.stdout:
            process.stdout.close()
        if thread.is_alive():
            thread.join(timeout=1)
    header, separator, payload = bytes(buffer).partition(b"\n")
    if not separator or len(header) > 65536:
        raise BackupFailure("invalid_transfer_header")
    meta = json.loads(header)
    if not OWN_ARCHIVE.fullmatch(str(meta.get("name", "")) + ".dpapi"):
        raise BackupFailure("invalid_archive_name")
    if not isinstance(meta.get("size"), int) or not 0 < meta["size"] <= MAX_ARCHIVE:
        raise BackupFailure("invalid_archive_size")
    if len(payload) != meta["size"] or hashlib.sha256(payload).hexdigest() != meta.get("sha256"):
        raise BackupFailure("transfer_hash_mismatch")
    if meta.get("source_restore") != "ok":
        raise BackupFailure("source_restore_unverified")
    return meta, payload

def verify_manifest(payload):
    hashes, manifest = {}, None
    expanded = 0
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as bundle:
        for item in bundle:
            name = pathlib.PurePosixPath(item.name)
            if name.is_absolute() or ".." in name.parts:
                raise BackupFailure("unsafe_archive_member")
            if item.isdir():
                continue
            if not item.isfile() or item.name in hashes:
                raise BackupFailure("invalid_archive_member")
            expanded += item.size
            if expanded > MAX_EXPANDED:
                raise BackupFailure("expanded_archive_limit")
            stream = bundle.extractfile(item)
            if item.name == "manifest.json":
                if manifest is not None or item.size > 1024 * 1024:
                    raise BackupFailure("invalid_manifest")
                manifest = json.load(stream)
                continue
            digest = hashlib.sha256()
            while True:
                chunk = stream.read(65536)
                if not chunk:
                    break
                digest.update(chunk)
            hashes[item.name] = digest.hexdigest()
    if not isinstance(manifest, dict) or manifest.get("sha256") != hashes:
        raise BackupFailure("archive_manifest_mismatch")
    return len(hashes)

def retain_own_archives(folder, keep=KEEP):
    archives = sorted(p for p in folder.iterdir()
                      if p.is_file() and not p.is_symlink() and OWN_ARCHIVE.fullmatch(p.name))
    removed = []
    for old in archives[:-keep]:
        old.unlink()
        receipt = old.with_name(old.name + ".receipt.json")
        if receipt.is_file() and not receipt.is_symlink():
            receipt.unlink()
        removed.append(old.name)
    return removed

def run_backup():
    settings = json.loads((TOOLS / "install.json").read_text(encoding="utf-8"))
    if settings.get("owner") != "GSD Cloud Offsite Backup":
        raise BackupFailure("installation_identity_mismatch")
    meta, plaintext = receive_archive(settings["ssh_executable"])
    verified_files = verify_manifest(plaintext)
    destination = BACKUPS / (meta["name"] + ".dpapi")
    if destination.exists():
        if destination.is_symlink():
            raise BackupFailure("backup_symlink_rejected")
        restored = dpapi(destination.read_bytes(), decrypt=True)
        if hashlib.sha256(restored).hexdigest() != meta["sha256"]:
            raise BackupFailure("existing_backup_hash_mismatch")
    else:
        ciphertext = dpapi(plaintext)
        if hashlib.sha256(dpapi(ciphertext, decrypt=True)).hexdigest() != meta["sha256"]:
            raise BackupFailure("encrypted_roundtrip_mismatch")
        atomic_write(destination, ciphertext)
    # Read the installed encrypted artifact, not just the in-memory encrypted buffer.
    restored = dpapi(destination.read_bytes(), decrypt=True)
    if hashlib.sha256(restored).hexdigest() != meta["sha256"]:
        raise BackupFailure("stored_backup_hash_mismatch")
    if verify_manifest(restored) != verified_files:
        raise BackupFailure("restored_manifest_mismatch")
    receipt = {
        "result": "PASS", "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_archive": meta["name"], "source_bytes": meta["size"],
        "encrypted_archive": str(destination), "encrypted_bytes": destination.stat().st_size,
        "sha256": meta["sha256"], "source_restore": meta["source_restore"],
        "restored_counts": meta["restored_counts"], "manifest_files_verified": verified_files,
        "dpapi_scope": "CurrentUser", "stored_decrypt_hash": "PASS",
        "plaintext_written_to_disk": False, "transfer_limit_bytes": MAX_ARCHIVE,
        "transfer_timeout_seconds": TRANSFER_TIMEOUT, "retention_keep": KEEP,
        "source_revision": settings.get("source_revision"),
    }
    atomic_write(destination.with_name(destination.name + ".receipt.json"),
                 (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    receipt["removed_own_archives"] = retain_own_archives(BACKUPS)
    record_status(receipt)
    print(json.dumps(receipt, sort_keys=True))
    return 0

def self_test():
    sample = os.urandom(1024)
    cipher = dpapi(sample)
    assert cipher != sample and dpapi(cipher, decrypt=True) == sample
    try:
        dpapi(cipher[:-1] + bytes([cipher[-1] ^ 1]), decrypt=True)
        raise AssertionError("corrupted DPAPI data was accepted")
    except BackupFailure:
        pass
    with tempfile.TemporaryDirectory(prefix="gsd-offsite-retention-") as temporary:
        folder = pathlib.Path(temporary)
        for day in range(1, 10):
            (folder / ("gsd-cloud-202611%02dT033500Z.tar.gz.dpapi" % day)).write_bytes(b"test")
        unrelated = folder / "other-project-backup.tar.gz.dpapi"
        unrelated.write_bytes(b"keep")
        removed = retain_own_archives(folder)
        assert len(removed) == 2
        assert unrelated.read_bytes() == b"keep"
        assert len(list(folder.iterdir())) == 8
    print(json.dumps({"dpapi_roundtrip": "PASS", "corruption_rejected": "PASS",
                      "own_retention_seven": "PASS", "unrelated_preserved": "PASS"}))
    return 0

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    import msvcrt
    lock = None
    try:
        lock = (TOOLS / "offsite.lock").open("a+b")
        if lock.tell() == 0:
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        return run_backup()
    except Exception as error:
        failure = {"result": "FAIL", "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   "error": str(error) if isinstance(error, BackupFailure) else type(error).__name__,
                   "plaintext_written_to_disk": False}
        if TOOLS.exists():
            record_status(failure)
        print(json.dumps(failure, sort_keys=True))
        return 1
    finally:
        if lock is not None:
            lock.close()

if __name__ == "__main__":
    raise SystemExit(main())
