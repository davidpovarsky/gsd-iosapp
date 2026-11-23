#!/usr/bin/env python3
"""Small, consistent GSD-only backups. Never emits user data or secret contents."""
import argparse, datetime, hashlib, json, os, pathlib, re, shutil, sqlite3, tarfile, tempfile

def checked_database(path):
    with sqlite3.connect(path) as db:
        result = db.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise RuntimeError("SQLite integrity check failed: " + path.name)
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        return {name: db.execute('SELECT count(*) FROM "' + name + '"').fetchone()[0]
                for name in ("users", "tasks", "gsd_library") if name in tables}

def verify(archive):
    with tempfile.TemporaryDirectory(prefix="gsd-restore-proof-", dir=archive.parent) as temp:
        root = pathlib.Path(temp)
        with tarfile.open(archive, "r:gz") as bundle:
            bundle.extractall(root, filter="data")
        manifest = json.loads((root / "manifest.json").read_text())
        for name, digest in manifest["sha256"].items():
            path = root / name
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise RuntimeError("Backup checksum mismatch")
        counts = checked_database(root / "pb_data/data.db")
        if counts != manifest["counts"]:
            raise RuntimeError("Restore row count mismatch")
        if (root / "gateway-state/gateway.key").is_file() and (root / "gateway-state/gateway.key").stat().st_size != 32:
            raise RuntimeError("Invalid backed-up session key")
        return counts

def backup(root, destination, keep):
    os.umask(0o077)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(destination, 0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = destination / ("gsd-cloud-" + stamp + ".tar.gz")
    if target.exists():
        raise RuntimeError("A backup already exists for this second")
    sources = [root / "pb_data/data.db", root / "pb_data/auxiliary.db", root / "pb_data/aux.db"]
    required = sum(p.stat().st_size for p in sources if p.exists()) * 3 + 16 * 1024 * 1024
    if shutil.disk_usage(destination).free < required:
        raise RuntimeError("Insufficient space for a consistent GSD backup")
    with tempfile.TemporaryDirectory(prefix="gsd-backup-stage-", dir=destination) as temp:
        stage = pathlib.Path(temp)
        (stage / "pb_data").mkdir()
        for source in sources:
            if not source.is_file():
                continue
            output = stage / "pb_data" / source.name
            with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as live, sqlite3.connect(output) as copy:
                live.backup(copy)
        for name in ("gateway-state", "pb_hooks", "pb_migrations", "gateway"):
            source = root / name
            if source.is_dir():
                shutil.copytree(source, stage / name, ignore=shutil.ignore_patterns("*.log", "*.bak*", "__pycache__"))
        counts = checked_database(stage / "pb_data/data.db")
        hashes = {p.relative_to(stage).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in stage.rglob("*") if p.is_file()}
        (stage / "manifest.json").write_text(json.dumps({"version": 1, "created": stamp,
                                                         "counts": counts, "sha256": hashes}, sort_keys=True))
        pending = target.with_suffix(".partial")
        try:
            with tarfile.open(pending, "w:gz") as archive:
                for path in sorted(stage.iterdir()):
                    archive.add(path, arcname=path.name)
            with pending.open("rb") as handle:
                os.fsync(handle.fileno())
            os.chmod(pending, 0o600)
            pending.replace(target)
            verify(target)
        except Exception:
            pending.unlink(missing_ok=True)
            raise
    # Only archives created by this program are eligible for retention cleanup.
    own = sorted(p for p in destination.iterdir()
                 if p.is_file() and re.fullmatch(r"gsd-cloud-\d{8}T\d{6}Z\.tar\.gz", p.name))
    for old in own[:-keep]:
        old.unlink()
    print(json.dumps({"backup": str(target), "bytes": target.stat().st_size,
                      "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                      "integrity": "ok", "restore": "ok", "counts": counts}))
    return target

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path("/mnt/development/projects/gsd-cloud"))
    parser.add_argument("--destination", type=pathlib.Path)
    parser.add_argument("--keep", type=int, default=7)
    parser.add_argument("--verify", type=pathlib.Path)
    args = parser.parse_args()
    if args.verify:
        print(json.dumps({"restore": "ok", "counts": verify(args.verify)}))
    else:
        if args.keep < 1:
            parser.error("--keep must be at least one")
        backup(args.root.resolve(), args.destination or args.root / "backups", args.keep)
