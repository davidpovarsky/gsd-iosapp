"""One reviewed GSD capacity phase. Default/read phases never mutate OCI.
Mutating phases require --execute and the externally recorded root/native GO.
Exact targets come only from the pinned existing private binding. No CLI targets.
"""
import argparse, datetime, hashlib, json, os, pathlib, sys, urllib.parse, uuid

BASE = pathlib.Path(r"C:\Users\DAVID\AppData\Local\Temp\gsd-oci-target-map-20261124-1bf4pgbe")
BINDING_SHA = "ec71e521ae5d5b130dbe6f5b825f1977f484c7e7521a45fa48e2c74c4d09dfd1"
STATE_DIR = BASE / "bounded-expansion-20261124"
REGION = "il-jerusalem-1"
VERSION = "gsd-capacity-provider-20261124-v1"
SPECS = {"boot": {"old_gb": 47, "old_mb": 47694, "new_gb": 50, "new_mb": 51200},
         "data": {"old_gb": 100, "old_mb": 102400, "new_gb": 103, "new_mb": 105472}}
MUTATIONS = {"backup-root", "backup-data", "resize-root", "resize-data"}

class GuardFailure(Exception):
    pass
class Pending(Exception):
    pass

def require(condition, code):
    if not condition:
        raise GuardFailure(code)

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def digest(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()

def atomic_json(path, value):
    temp = path.with_name(path.name + ".tmp")
    require(not temp.exists(), "UNFINISHED_ATOMIC_FILE")
    raw = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    with temp.open("xb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)

class Operation:
    def __init__(self, phase, execute):
        self.phase, self.execute = phase, execute
        raw = (BASE / "target-map-private.json").read_bytes()
        require(digest(raw) == BINDING_SHA, "BINDING_FILE_CHANGED")
        self.binding = json.loads(raw)
        self.targets = {v["kind"]: v for v in self.binding["volumes"]}
        require(set(self.targets) == {"boot", "data"}, "TARGET_SET_CHANGED")
        STATE_DIR.mkdir(exist_ok=True)
        require(not STATE_DIR.is_symlink(), "STATE_DIRECTORY_SYMLINK")
        self.state_path = STATE_DIR / "ledger.json"
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text(encoding="utf-8"))
            require(self.state["binding_sha256"] == BINDING_SHA and self.state["version"] == VERSION, "LEDGER_BINDING_CHANGED")
        else:
            self.state = {"version": VERSION, "binding_sha256": BINDING_SHA,
                          "operation_id": uuid.uuid4().hex, "created_utc": now(),
                          "backups": {}, "updates": {}}
            self.save()
        self.receipt = {"version": VERSION, "phase": phase, "started_utc": now(),
                        "operation_id": self.state["operation_id"], "calls": [],
                        "cloud_mutations_attempted": 0, "binding_sha256": BINDING_SHA}
        import logging
        logging.disable(logging.CRITICAL)
        import oci
        require(oci.__version__ == "2.192.0", "SDK_VERSION_CHANGED")
        self.oci = oci
        config = oci.config.from_file(file_location=r"C:\Users\DAVID\.oci\config", profile_name="DEFAULT")
        require(config.get("region") == REGION, "REGION_CHANGED")
        config["log_requests"] = False
        oci.config.validate_config(config)
        self.tenancy = config["tenancy"]
        self.no_retry = oci.retry.NoneRetryStrategy()
        options = {"timeout": (5, 30), "retry_strategy": self.no_retry}
        self.compute = oci.core.ComputeClient(config, **options)
        self.block = oci.core.BlockstorageClient(config, **options)
        self.limits = oci.limits.LimitsClient(config, **options)
        for client in (self.compute, self.block, self.limits):
            url = urllib.parse.urlparse(client.base_client.get_endpoint())
            require(url.scheme == "https" and (url.hostname or "").endswith(".oraclecloud.com")
                    and ("." + REGION + ".") in (url.hostname or ""), "ENDPOINT_OUTSIDE_REGION")

    def save(self):
        self.state["updated_utc"] = now()
        atomic_json(self.state_path, self.state)

    def api(self, operation, function, *args, mutation=False, **kwargs):
        require(len(self.receipt["calls"]) < 50, "PHASE_READ_BUDGET")
        if mutation:
            require(self.execute and self.phase in MUTATIONS, "EXECUTION_FLAG_REQUIRED")
            self.receipt["cloud_mutations_attempted"] += 1
        try:
            response = function(*args, retry_strategy=self.no_retry, **kwargs)
            self.receipt["calls"].append({"operation": operation, "status": response.status})
            return response
        except self.oci.exceptions.ServiceError as error:
            self.receipt["calls"].append({"operation": operation, "status": error.status, "code": error.code})
            raise

    def quota(self, name, ad=None):
        response = self.api("ListLimitValues[" + name + "]", self.limits.list_limit_values,
                            self.tenancy, "block-storage", name=name, limit=100)
        require(not response.headers.get("opc-next-page"), "LIMIT_PAGINATION_UNEXPECTED")
        rows = [r for r in response.data if r.name == name and
                ((ad is not None and r.scope_type == "AD" and r.availability_domain == ad)
                 or (ad is None and r.scope_type == "REGION"))]
        require(len(rows) == 1, "LIMIT_SCOPE_AMBIGUOUS")
        kwargs = {"availability_domain": ad} if ad is not None else {}
        usage = self.api("GetResourceAvailability[" + name + "]", self.limits.get_resource_availability,
                         "block-storage", name, self.tenancy, **kwargs).data
        return {"value": rows[0].value, "used": usage.used, "available": usage.available}

    def context(self):
        expected = self.binding["instance"]
        instance = self.api("GetInstance[target]", self.compute.get_instance, expected["id"]).data
        require(instance.id == expected["id"] and instance.compartment_id == expected["compartment_id"]
                and instance.availability_domain == expected["availability_domain"]
                and instance.lifecycle_state == "RUNNING", "INSTANCE_BINDING_CHANGED")
        ba = self.api("ListBootAttachments[target]", self.compute.list_boot_volume_attachments,
                      instance.availability_domain, instance.compartment_id, instance_id=instance.id, limit=100)
        da = self.api("ListDataAttachments[target]", self.compute.list_volume_attachments,
                      compartment_id=instance.compartment_id, instance_id=instance.id, limit=100)
        require(not ba.headers.get("opc-next-page") and not da.headers.get("opc-next-page")
                and len(ba.data) == len(da.data) == 1, "ATTACHMENT_SET_CHANGED")
        volumes = {}
        for role, attachment in (("boot", ba.data[0]), ("data", da.data[0])):
            old = self.targets[role]
            response = self.api("GetVolume[" + role + "]",
                                self.block.get_boot_volume if role == "boot" else self.block.get_volume, old["id"])
            volume = response.data
            require(attachment.id == old["attachment"]["id"] and attachment.instance_id == instance.id
                    and attachment.lifecycle_state == "ATTACHED"
                    and getattr(attachment, "boot_volume_id" if role == "boot" else "volume_id") == old["id"],
                    "ATTACHMENT_BINDING_CHANGED")
            if role == "data":
                require(attachment.is_read_only is False and attachment.is_shareable is False, "DATA_ATTACHMENT_MODE_CHANGED")
            require(volume.id == old["id"] and volume.compartment_id == old["compartment_id"]
                    and volume.availability_domain == old["availability_domain"] == instance.availability_domain,
                    "VOLUME_BINDING_OR_AD_CHANGED")
            require(volume.vpus_per_gb == 10 and volume.is_auto_tune_enabled is False
                    and getattr(volume, "kms_key_id", None) is None, "VOLUME_SETTINGS_CHANGED")
            field = "boot_volume_replicas" if role == "boot" else "block_volume_replicas"
            require(hasattr(volume, field) and not getattr(volume, field), "REPLICATION_REQUIRES_SEPARATE_REVIEW")
            spec = SPECS[role]
            require((volume.size_in_gbs, volume.size_in_mbs) in
                    ((spec["old_gb"], spec["old_mb"]), (spec["new_gb"], spec["new_mb"])), "UNEXPECTED_VOLUME_SIZE")
            require(bool(response.headers.get("etag")), "MISSING_ETAG")
            volumes[role] = response
        storage = self.quota("total-storage-gb", instance.availability_domain)
        backups = self.quota("backup-count")
        require(storage["value"] == 200 and backups["value"] == 5, "LIMIT_VALUE_CHANGED")
        self.receipt["context"] = {"target_ad_matches_both_volumes": True, "storage": storage, "backups": backups,
            "volumes": {role: {"id_sha256": digest(r.data.id), "size_gb": r.data.size_in_gbs,
                "size_mb": r.data.size_in_mbs, "state": r.data.lifecycle_state,
                "etag_sha256": digest(r.headers["etag"]), "vpus_per_gb": 10,
                "autotune_enabled": False, "replicas": 0} for role, r in volumes.items()}}
        return volumes, storage, backups

    def backup_status(self, role):
        entry = self.state["backups"].get(role)
        require(entry and entry.get("id"), "BACKUP_ID_MISSING_OR_UNKNOWN_OUTCOME")
        backup = self.api("GetBackup[" + role + "]",
            self.block.get_boot_volume_backup if role == "boot" else self.block.get_volume_backup, entry["id"]).data
        parent = getattr(backup, "boot_volume_id" if role == "boot" else "volume_id")
        require(parent == self.targets[role]["id"] and backup.type == "FULL", "BACKUP_SOURCE_OR_TYPE_CHANGED")
        entry["state"] = backup.lifecycle_state
        self.save()
        result = {"role": role, "id_sha256": digest(entry["id"]), "state": backup.lifecycle_state,
                  "type": backup.type, "source_matches": True}
        self.receipt.setdefault("backups", {})[role] = result
        require(backup.lifecycle_state in ("REQUEST_RECEIVED", "CREATING", "AVAILABLE"), "BACKUP_FAILED")
        return backup.lifecycle_state == "AVAILABLE"

    def create_backup(self, role):
        require(self.execute, "EXECUTION_FLAG_REQUIRED")
        if role in self.state["backups"]:
            if not self.backup_status(role):
                raise Pending("BACKUP_NOT_AVAILABLE")
            return
        volumes, storage, backups = self.context()
        require(all(volumes[r].data.size_in_gbs == SPECS[r]["old_gb"] and
                    volumes[r].data.lifecycle_state == "AVAILABLE" for r in SPECS), "BACKUP_PRE_GROW_STATE_CHANGED")
        require(storage["used"] == 194 and storage["available"] >= 6, "STORAGE_HEADROOM_CHANGED")
        require(backups["available"] >= 2 - len(self.state["backups"]), "BACKUP_ALLOWANCE_CHANGED")
        label = "GSD maintenance " + ("root" if role == "boot" else "data") + " pre-grow 2026-11-24"
        body = {"bootVolumeId" if role == "boot" else "volumeId": self.targets[role]["id"],
                "displayName": label, "type": "FULL"}
        entry = {"status": "REQUESTING", "created_utc": now(), "retry_token": str(uuid.uuid4()),
                 "request_body_sha256": digest(json.dumps(body, sort_keys=True)), "display_name": label}
        self.state["backups"][role] = entry
        self.save()  # Durable token/body binding BEFORE POST. Never silently replace an existing entry.
        model = (self.oci.core.models.CreateBootVolumeBackupDetails(boot_volume_id=self.targets[role]["id"], display_name=label, type="FULL")
                 if role == "boot" else self.oci.core.models.CreateVolumeBackupDetails(volume_id=self.targets[role]["id"], display_name=label, type="FULL"))
        response = self.api("CreateFULLBackup[" + role + "]",
            self.block.create_boot_volume_backup if role == "boot" else self.block.create_volume_backup,
            model, mutation=True, opc_retry_token=entry["retry_token"])
        entry["id"], entry["status"] = response.data.id, "REQUEST_ACCEPTED"
        self.save()
        if not self.backup_status(role):
            raise Pending("BACKUP_NOT_AVAILABLE")

    def require_backups(self):
        ready = [self.backup_status(role) for role in ("boot", "data")]
        if not all(ready):
            raise Pending("BOTH_FULL_BACKUPS_MUST_BE_AVAILABLE")

    def require_guest(self, role):
        label = "root" if role == "boot" else "data"
        path = STATE_DIR / ("guest-" + label + "-growfs.json")
        require(path.is_file(), "GUEST_GROWTH_RECEIPT_MISSING")
        proof = json.loads(path.read_text(encoding="utf-8"))
        require(proof.get("status") == "PASS" and proof.get("phase") == label + "-growfs"
                and proof.get("operation_id") == self.state["operation_id"], "GUEST_GROWTH_RECEIPT_INVALID")
        require(proof.get("filesystem_target_verified") is True and proof.get("service_continuity_verified") is True,
                "GUEST_GROWTH_NOT_VERIFIED")

    def resize(self, role):
        require(self.execute, "EXECUTION_FLAG_REQUIRED")
        self.require_backups()
        if role == "data":
            self.require_guest("boot")
        volumes, storage, _ = self.context()
        spec, current = SPECS[role], volumes[role]
        expected_used = 194 if role == "boot" else 197
        other = "data" if role == "boot" else "boot"
        require(volumes[other].data.size_in_gbs == (100 if role == "boot" else 50)
                and volumes[other].data.lifecycle_state == "AVAILABLE", "OTHER_TARGET_STATE_CHANGED")
        prior_update = self.state["updates"].get(role)
        if prior_update is None:
            require(current.data.lifecycle_state == "AVAILABLE" and current.data.size_in_gbs == spec["old_gb"], "UPDATE_START_STATE_CHANGED")
            require(storage["used"] == expected_used and storage["available"] >= (6 if role == "boot" else 3), "UPDATE_QUOTA_CHANGED")
            entry = {"status": "REQUESTING", "requested_utc": now(), "target_gb": spec["new_gb"],
                     "etag_before": current.headers["etag"]}
            self.state["updates"][role] = entry
            self.save()  # Persist intended ETag-guarded operation before PUT.
            model = (self.oci.core.models.UpdateBootVolumeDetails(size_in_gbs=50) if role == "boot"
                     else self.oci.core.models.UpdateVolumeDetails(size_in_gbs=103))
            self.api("UpdateSize[" + role + "]", self.block.update_boot_volume if role == "boot" else self.block.update_volume,
                     self.targets[role]["id"], model, mutation=True, if_match=current.headers["etag"])
            entry["status"] = "REQUEST_ACCEPTED"
            self.save()
            volumes, storage, _ = self.context()
            current = volumes[role]
        else:
            require(prior_update["target_gb"] == spec["new_gb"], "UPDATE_LEDGER_CHANGED")
            if current.data.size_in_gbs == spec["old_gb"]:
                require(prior_update["status"] == "REQUEST_ACCEPTED", "UNKNOWN_UPDATE_OUTCOME_NO_BLIND_RETRY")
                raise Pending("PROVIDER_SIZE_NOT_YET_UPDATED")
        if current.data.lifecycle_state != "AVAILABLE" or current.data.size_in_gbs != spec["new_gb"]:
            raise Pending("PROVIDER_UPDATE_NOT_AVAILABLE")
        if storage["used"] != expected_used + 3:
            raise Pending("UPDATED_QUOTA_READBACK_PENDING")
        self.state["updates"][role]["status"] = "CONFIRMED"
        self.save()
        self.receipt["provider_target_verified"] = True

    def run(self):
        if self.phase == "preflight":
            self.context()
        elif self.phase in ("backup-root", "backup-data"):
            self.create_backup("boot" if self.phase == "backup-root" else "data")
        elif self.phase == "backups-status":
            self.require_backups()
        elif self.phase in ("resize-root", "resize-data"):
            self.resize("boot" if self.phase == "resize-root" else "data")
        elif self.phase == "verify":
            self.require_backups()
            self.require_guest("boot")
            self.require_guest("data")
            volumes, storage, backups = self.context()
            require(all(volumes[r].data.lifecycle_state == "AVAILABLE" and volumes[r].data.size_in_gbs == SPECS[r]["new_gb"] for r in SPECS), "FINAL_SIZE_NOT_VERIFIED")
            require(storage["used"] == 200 and 2 <= backups["used"] <= 5, "FINAL_USAGE_NOT_VERIFIED")
            self.receipt["provider_target_verified"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, choices=["preflight", "backup-root", "backup-data", "backups-status", "resize-root", "resize-data", "verify"])
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    require(args.phase not in MUTATIONS or args.execute, "EXECUTION_FLAG_REQUIRED")
    require(BASE.is_dir() and not BASE.is_symlink(), "OPERATION_DIRECTORY_MISSING")
    STATE_DIR.mkdir(exist_ok=True)
    lock_path = STATE_DIR / "phase.lock"
    lock = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(lock, str(os.getpid()).encode())
    os.fsync(lock)
    operation = None
    result = {"version": VERSION, "phase": args.phase, "started_utc": now()}
    code = 1
    try:
        operation = Operation(args.phase, args.execute)
        operation.run()
        result, code = operation.receipt, 0
        result["status"] = "PASS"
    except Pending as error:
        result = operation.receipt if operation else result
        result.update({"status": "PENDING", "error_code": str(error)})
        code = 2
    except Exception as error:
        result = operation.receipt if operation else result
        result.update({"status": "FAILED", "error_type": type(error).__name__})
        if isinstance(error, GuardFailure):
            result["error_code"] = str(error)
        elif operation and isinstance(error, operation.oci.exceptions.ServiceError):
            result.update({"http_status": error.status, "service_code": error.code})
        code = 1
    finally:
        result["finished_utc"] = now()
        result["exit_code"] = code
        path = STATE_DIR / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + "-" + args.phase + ".json")
        try:
            atomic_json(path, result)
            print(json.dumps(result, sort_keys=True), flush=True)
        finally:
            os.close(lock)
            lock_path.unlink()
    return code

if __name__ == "__main__":
    sys.exit(main())
