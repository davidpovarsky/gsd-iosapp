"""One fixed guest launch or observation. The remote worker survives transport loss."""
import argparse, base64, datetime, hashlib, importlib.util, json, os, pathlib, subprocess, sys

BASE = pathlib.Path(r"C:\Users\DAVID\AppData\Local\Temp\gsd-oci-target-map-20261124-1bf4pgbe")
CODE = BASE / "bounded-expansion-code"
STATE = BASE / "bounded-expansion-20261124"
BINDING_SHA = "ec71e521ae5d5b130dbe6f5b825f1977f484c7e7521a45fa48e2c74c4d09dfd1"
PROVIDER_SHA = "120f7c47e7060d030bfecc5c4b6a5e0d8ec5251d5d2811f6d76e1c10ecd90594"
GUEST_SHA = "4da02615b3b3eec8cc6b8021ca57749b382e479e1e5957005cf802edf97aa914"
CONTROL_SHA = "cd9c174631a75db699fa0063a750d1512428a41ebc564675ef9d9d00d32d908d"

def require(ok, code):
    if not ok:
        raise RuntimeError(code)

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def atomic(path, value):
    temp = path.with_name(path.name + ".tmp")
    with temp.open("xb") as stream:
        stream.write((json.dumps(value, indent=2, sort_keys=True) + "\n").encode())
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)

def sanitized(value):
    if isinstance(value, list):
        return [sanitized(item) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if item is not None and key in ("id", "uuid", "partuuid", "ptuuid", "Filesystem UUID"):
                result[key + "_sha256"] = sha(str(item).lower().encode())
            else:
                result[key] = sanitized(item)
        return result
    return value

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, choices=["preflight", "root-growfs", "data-growfs"])
    parser.add_argument("--action", choices=["launch", "observe"], default="observe")
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    require(args.phase != "preflight" or args.action == "observe", "PREFLIGHT_IS_READ_ONLY")
    require(args.action != "launch" or args.execute, "EXECUTION_FLAG_REQUIRED")
    require(BASE.is_dir() and STATE.is_dir() and not BASE.is_symlink() and not STATE.is_symlink(), "OPERATION_DIRECTORY_CHANGED")
    require(sha((BASE / "target-map-private.json").read_bytes()) == BINDING_SHA, "BINDING_CHANGED")
    require(sha((CODE / "gsd_capacity_provider_20261124.py").read_bytes()) == PROVIDER_SHA, "PROVIDER_SOURCE_CHANGED")
    guest_source = (CODE / "gsd_capacity_guest_20261124.py").read_bytes()
    control_source = (CODE / "gsd_capacity_guest_control_20261124.py").read_bytes()
    require(sha(guest_source) == GUEST_SHA and sha(control_source) == CONTROL_SHA, "GUEST_SOURCE_CHANGED")
    lock_path = STATE / "phase.lock"
    lock = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(lock, str(os.getpid()).encode())
    os.fsync(lock)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    receipt = {"phase": args.phase, "action": args.action, "started_utc": now(), "status": "FAILED",
               "provider_source_sha256": PROVIDER_SHA, "guest_source_sha256": GUEST_SHA,
               "controller_source_sha256": CONTROL_SHA}
    operation = None
    intent = None
    try:
        ledger = json.loads((STATE / "ledger.json").read_text(encoding="utf-8"))
        require(ledger["binding_sha256"] == BINDING_SHA, "LEDGER_BINDING_CHANGED")
        operation_id = ledger["operation_id"]
        receipt["operation_id"] = operation_id
        request_path = STATE / ("guest-request-" + args.phase + ".json")
        ssh = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "ConnectTimeout=15", "torah-social", "sudo", "-n", "python3", "-"]
        if args.phase == "preflight":
            ssh.extend(["--phase", "preflight", "--operation-id", operation_id])
            source = guest_source.decode()
        else:
            if args.action == "launch":
                require(not request_path.exists(), "PRIOR_GUEST_ATTEMPT_NO_BLIND_RETRY")
                spec = importlib.util.spec_from_file_location("gsd_capacity_provider", CODE / "gsd_capacity_provider_20261124.py")
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                operation = module.Operation("preflight", False)
                require(operation.state["operation_id"] == operation_id, "OPERATION_CHANGED")
                operation.require_backups()
                volumes, storage, backups = operation.context()
                role = "boot" if args.phase == "root-growfs" else "data"
                require(operation.state["updates"].get(role, {}).get("status") == "CONFIRMED", "PROVIDER_UPDATE_NOT_CONFIRMED")
                expected = {"boot": 50, "data": 100 if role == "boot" else 103}
                require(all(volumes[key].data.lifecycle_state == "AVAILABLE" and volumes[key].data.size_in_gbs == size
                            for key, size in expected.items()), "PROVIDER_SIZE_NOT_READY")
                require(storage["used"] == (197 if role == "boot" else 200)
                        and storage["available"] == (3 if role == "boot" else 0)
                        and 2 <= backups["used"] <= 5, "POST_UPDATE_QUOTA_CHANGED")
                if role == "data":
                    operation.require_guest("boot")
                intent = {"operation_id": operation_id, "phase": args.phase,
                          "guest_source_sha256": GUEST_SHA, "controller_source_sha256": CONTROL_SHA,
                          "status": "LAUNCH_REQUESTING", "created_utc": now()}
                atomic(request_path, intent)  # Durable intention BEFORE remote launch.
            else:
                require(request_path.is_file(), "NO_PRIOR_LAUNCH_TO_OBSERVE")
                intent = json.loads(request_path.read_text(encoding="utf-8"))
                require(intent["operation_id"] == operation_id and intent["phase"] == args.phase
                        and intent["guest_source_sha256"] == GUEST_SHA
                        and intent["controller_source_sha256"] == CONTROL_SHA, "WINDOWS_INTENT_CHANGED")
            request = {"action": args.action, "operation_id": operation_id, "phase": args.phase}
            if args.action == "launch":
                request["source_base64"] = base64.b64encode(guest_source).decode()
            source = control_source.decode() + "\nraise SystemExit(main(" + repr(request) + "))\n"
        # This timeout applies only to a read-only preflight or a short launch/observer.
        # The detached, session-independent worker has closed stdin and private file logs.
        child = subprocess.run(ssh, input=source, capture_output=True, text=True, encoding="utf-8",
                               timeout=70 if args.phase == "preflight" else 45)
        receipt["child_exit_code"] = child.returncode
        private = STATE / (stamp + "-guest-" + args.phase + "-private.json")
        try:
            inner = json.loads(child.stdout)
        except Exception:
            atomic(private, {"stdout": child.stdout, "stderr": child.stderr, "child_exit_code": child.returncode})
            raise RuntimeError("REMOTE_RECEIPT_NOT_JSON_OBSERVE_ONLY_NO_RETRY")
        atomic(private, {"inner": inner, "ssh_stderr": child.stderr, "child_exit_code": child.returncode})
        receipt["private_receipt_basename"] = private.name
        receipt["private_receipt_sha256"] = sha(private.read_bytes())
        require(inner.get("operation_id") == operation_id and inner.get("phase") == args.phase, "REMOTE_BINDING_CHANGED")
        expected_exit = {"PASS": 0, "PENDING": 2, "FAILED": 1}.get(inner.get("status"))
        require(expected_exit is not None and child.returncode == expected_exit, "REMOTE_STATUS_EXIT_MISMATCH")
        guest = inner if args.phase == "preflight" else inner.get("guest")
        receipt["remote"] = sanitized(inner)
        public_guest = receipt["remote"] if args.phase == "preflight" else receipt["remote"].get("guest")
        if public_guest:
            for record in public_guest.get("commands", []):
                for key in ("stdout", "stderr"):
                    if key in record:
                        record[key + "_sha256"] = sha(record.pop(key).encode())
        receipt["status"] = inner["status"]
        if receipt["status"] == "PASS":
            require(guest and guest.get("exit_code") == 0 and guest.get("service_continuity_verified") is True, "REMOTE_PROOF_MISMATCH")
            if args.phase != "preflight":
                require(guest.get("filesystem_target_verified") is True and guest.get("source_sha256") == GUEST_SHA, "REMOTE_FILESYSTEM_NOT_VERIFIED")
                receipt.update({"filesystem_target_verified": True, "service_continuity_verified": True})
        if intent:
            intent.update({"status": receipt["status"], "last_observed_utc": now(),
                           "last_private_receipt_sha256": receipt["private_receipt_sha256"]})
            atomic(request_path, intent)
    except Exception as error:
        receipt["status"] = "FAILED"
        receipt["error_type"] = type(error).__name__
        if isinstance(error, subprocess.TimeoutExpired):
            receipt["error_code"] = "TRANSPORT_TIMEOUT_WORKER_UNTOUCHED_OBSERVE_ONLY"
        elif isinstance(error, RuntimeError):
            receipt["error_code"] = str(error)
        elif operation and isinstance(error, operation.oci.exceptions.ServiceError):
            receipt.update({"http_status": error.status, "service_code": error.code})
        else:
            receipt["error_code"] = "LOCAL_OR_PROVIDER_GUARD_FAILURE"
    finally:
        if operation:
            receipt["provider_gate"] = operation.receipt
        receipt["finished_utc"] = now()
        code = {"PASS": 0, "PENDING": 2, "FAILED": 1}[receipt["status"]]
        receipt["wrapper_exit_code"] = code
        try:
            atomic(STATE / (stamp + "-guest-" + args.phase + ".json"), receipt)
            if code == 0 and args.phase != "preflight":
                proof = STATE / ("guest-" + args.phase + ".json")
                if proof.exists():
                    accepted = json.loads(proof.read_text(encoding="utf-8"))
                    require(accepted["operation_id"] == operation_id and accepted["status"] == "PASS"
                            and accepted["guest_source_sha256"] == GUEST_SHA, "ACCEPTED_PROOF_CHANGED")
                else:
                    atomic(proof, receipt)
            print(json.dumps(receipt, sort_keys=True), flush=True)
        finally:
            os.close(lock)
            lock_path.unlink()
    return code

if __name__ == "__main__":
    sys.exit(main())
