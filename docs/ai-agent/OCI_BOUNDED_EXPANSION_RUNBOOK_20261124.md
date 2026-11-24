# GSD Oracle — bounded 50/103 GB expansion runbook

## Review status and exact scope

**EXECUTED AND VERIFIED — final PASS at 06:51:02 UTC.** Both FULL snapshots are AVAILABLE; boot/data are 50/103 GB with the exact guest filesystems and service continuity verified. The fixed phases below document what was reviewed and executed. They are not an instruction to repeat the operation. See [the execution receipt](OCI_BOUNDED_EXPANSION_EXECUTION_20261124.md) for exact observations, preserved pending/failed guard history and remaining limits.

The sole candidate is the already bound `torah-social` boot volume **47 → 50 GB** and attached data volume **100 → 103 GB**, preserving **10 VPU/GB**, autotune, encryption settings and attachment identities. The other boot volume is outside the mutation scope. No quota increase, paid-tier upgrade, old-backup deletion, volume detach, reboot, service stop or reserve change is included.

The [regional assessment](OCI_CAPACITY_PROPOSAL_20261124.md), commit `4840607fde739204bdb6d4ad45ecc52db2aca56d`, established 194/200 GB usage and zero of five provider backups. The +50 GB option was rejected. The +6 GB candidate fits observed quantity limits; the report retains billing qualifications and the US$0.255/month standard-list arithmetic if charged.

## Immutable bindings and installed prerequisites

Load exact OCI IDs from the existing private Windows receipt `target-map-private.json`; require its SHA-256 to equal:

`ec71e521ae5d5b130dbe6f5b825f1977f484c7e7521a45fa48e2c74c4d09dfd1`.

Require the selected `DEFAULT` region to remain `il-jerusalem-1`. Use official SDK 2.192.0 and its resolved `get_endpoint()` under the already verified HTTPS/domain/exact-region guards. Keys remain in the original authorized profile/key location; do not copy them into any artifact or log.

| Binding | Expected value or fingerprint |
|---|---|
| Instance ID SHA-256 | `26d0f00c604741a30e687ccc2b0b1dc2c0ba4f0f7fa622b389d8956bdf978570` |
| Boot volume ID SHA-256 | `16f63e72133ed38ec16e4431d617c0605d1a54ef309adbaf4b706d6b5313b004` |
| Data volume ID SHA-256 | `37610e120e864c0110cd1657aaacc3decd96cbda0341ef209eb57090b8440ba9` |
| Root mount / filesystem device | `/` → `/dev/sda1`, ext4, major:minor `8:1` |
| Boot disk | `/dev/sda`, major:minor `8:0`, GPT |
| Data mount / entire filesystem device | `/mnt/development` → `/dev/sdb`, ext4, `8:16`, no partition children |
| Root filesystem UUID SHA-256 | `5312b5cffd5a50b5b3901d84f5e016c33d5acd47c08c6109a7480a1ab6947561` |
| Data filesystem UUID SHA-256 | `fd89070272a5c0ad7fdbb22f8080e0597c1550a537a44193ceb4440032a9179b` |

Full pre-change GPT/partition/FS UUIDs and attachment IDs remain in private receipts. Compare UUIDs case-insensitively across tools; raw `sfdisk` and `lsblk` formatting differs in letter case. Capture node inode metadata, but bind devices by OCI attachment, block-device major/minor, mount and filesystem/partition UUID together.

Read-only guest preflight at **05:41:38 UTC** verified Ubuntu **24.04.4 LTS**, kernel **6.17.0-1020-oracle**, `cloud-guest-utils 0.33-1`, `e2fsprogs 1.47.0-2.4~exp1ubuntu4.1` and `util-linux 2.39.3-9ubuntu6.6`. Required `growpart`, `resize2fs`, `sfdisk`, `lsblk`, `blockdev`, `findmnt`, `tune2fs`, `partx`, `udevadm`, `dd`, `systemctl`, `ss` and Python are installed. Both selected ext4 filesystems report clean state and zero reserved blocks. Both sysfs rescan controls exist and are root-owned. **No package installation is needed or included.**

The guest private receipt is `guest-capacity-preflight-20261124T054138Z-private.json`, SHA-256 `8eba004ba030dfb49a976febd23b7bcdf6132e9065c21c95dbb71695cce8ae6e`. Its [sanitized copy](evidence/capacity-20261124/guest-capacity-preflight.json) includes all selected pre-change geometry and service metadata.

**Provider AD/ETag/replication follow-up completed:** five exact-target HTTP 200 reads at 05:47 UTC confirmed unchanged instance and attachment IDs, expected sizes/settings, nonempty ETags and zero replicas/customer-managed keys. Two further scoped HTTP 200 limit reads confirmed one selected AD limit row, with its queried AD matching both target volumes and the instance; usage remains 194/200 GB with 6 GB available. The original regional volume lists had no AD filter. The final receipt reports PASS and the SDK environment was removed at 05:52 UTC. A local helper keyword collision before the limit reads is preserved separately; the five successful target reads were reused, and the final wrapper exits nonzero for failed inner status.

The complete provider private receipt is `resize-provider-preflight-complete-private.json`, SHA-256 `05a1d54bfe0a8369ad3bfe317204076bd061c65443989ad5a3490a106ef4daed`. See [the sanitized target/AD proof](evidence/capacity-20261124/provider-capacity-preflight.json) and [the preserved partial receipt](evidence/capacity-20261124/provider-preflight-partial.json). This preflight does not establish backup or update permission and authorizes no mutation.

The original attachment binding did not retain encryption-in-transit fields. No such historical comparison is claimed. The executor constrains attachment IDs/modes and the verified absence of customer-managed volume keys; its update bodies contain only `sizeInGBs` and make no attachment/encryption calls.

## Exact byte and partition expectations

OCI's current boot `size_in_gbs=47` is accompanied by **`size_in_mbs=47694`**, not 47 GiB of device bytes. Use the actual measured byte counts below.

| Layer | Measured before | Expected after the selected update |
|---|---:|---:|
| Boot API size | 47 GB / 47,694 MiB | 50 GB / 51,200 MiB |
| Whole boot disk | 50,010,783,744 bytes | **53,687,091,200 bytes** |
| Root partition `sda1` | 48,935,976,448 bytes | **52,612,283,904 bytes**, subject to the reviewed dry-run geometry |
| Root ext4 blocks, 4,096 bytes each | 11,947,259 | **12,844,795** at that partition maximum |
| Data API size | 100 GB / 102,400 MiB | 103 GB / 105,472 MiB |
| Whole data device / filesystem backing device | 107,374,182,400 bytes | **110,595,407,872 bytes** |
| Data ext4 blocks, 4,096 bytes each | 26,214,400 | **27,000,832** |

With 512-byte sectors, boot GPT's expected last usable LBA becomes **104,857,566**. Root's start must remain **2,099,200**. At that maximum its size becomes **102,758,367 sectors** and its inclusive end becomes **104,857,566**. Its GPT type, partition UUID and filesystem UUID must stay unchanged.

The other boot-disk partitions must remain exact:

| Partition | Start sector | Size in sectors | Protected role |
|---|---:|---:|---|
| `sda15` | 2,048 | 202,753 | Existing EFI partition and UUID |
| `sda16` | 206,848 | 1,890,305 | Existing /boot partition and UUID |

No data-disk partition operation is appropriate: ext4 is directly on `/dev/sdb`. Do not create a partition table there.

## Stage 0 — fresh clearance and guards

Obtain a fresh native-safe/root execution clearance. Before each mutation boundary, re-read exact instance/attachments, both target volumes, relevant limit availability and guest identities. Require instance RUNNING, exactly the same one attached boot and one attached read-write/nonshareable data volume, matching compartment/AD, expected current sizes, 10 VPU/GB and unchanged autotune. Require no configured replication that would need a separate disable action.

Require storage usage still 194 with at least 6 GB available and room for both provider backups. The earlier regional volume lists had **no AD filter**; the storage limit is AD-scoped. Require the AD used by the live resource-availability query to match **both target volumes**.

Capture fresh GSD/Lorvex long-lived service PIDs, start timestamps and listening sockets, root/data free bytes and inodes, full selected GPT/partition table, mount/UUID/device identities, ext4 block counts, block sizes, features and state. Require the known PocketBase and public gateway health checks HTTP 200. No other project's files or private application configuration is inspected.

Any missing tool, SSH/sudo denial, identity/attachment/AD mismatch, unexpected replica, active native test, changed quota arithmetic or unhealthy required service blocks mutation. Do not change permissions or policies to pass a guard.

## Stage 1 — create exactly two FULL provider backups

Create an operation ledger on Windows before either POST, with a unique request ID and a stable per-role `opc_retry_token`. Keep exact resource IDs in that private ledger and publish only fingerprints. Record response IDs immediately. A transport timeout must be reconciled using that same request token and returned/identified backup; never issue a fresh duplicate create blindly.

The request bodies are exactly:

```json
{
  "bootVolumeId": "<boot ID loaded from the hash-verified private binding>",
  "displayName": "GSD maintenance root pre-grow 2026-11-24",
  "type": "FULL"
}
```

```json
{
  "volumeId": "<data ID loaded from the hash-verified private binding>",
  "displayName": "GSD maintenance data pre-grow 2026-11-24",
  "type": "FULL"
}
```

Use `CreateBootVolumeBackupDetails` with `create_boot_volume_backup`, and `CreateVolumeBackupDetails` with `create_volume_backup`. Set no new KMS key, lock, retention policy or cross-region copy. Use explicit `NoneRetryStrategy` and the stable create retry token; parent IDs remain the two approved targets.

Read the two created backups until **both are AVAILABLE**, `type=FULL`, and bound to their expected source IDs and region. REQUEST_RECEIVED or CREATING is pending, not complete. Poll at bounded intervals from Windows; a phase timeout records pending state and stops before resizing. FAULTY, deletion, identity mismatch or permission error stops the operation. Keep any successfully created backup; no cleanup/delete is authorized.

These are provider snapshots of shared, running volumes. AVAILABLE is provider completion evidence, not a tested boot restore or proof that every application was quiesced across both volumes. The separately verified GSD application backups retain their independent evidence.

[Backup API and retry-token behavior](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/core/client/oci.core.BlockstorageClient.html) · [Boot FULL body](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/core/models/oci.core.models.CreateBootVolumeBackupDetails.html) · [Data FULL body](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/core/models/oci.core.models.CreateVolumeBackupDetails.html)

## Stage 2 — ETag-guarded boot update, then complete root guest growth

After both backup gates pass, GET the boot volume again. Recheck its exact ID/attachment/AD, 47 GB / 47,694 MiB, AVAILABLE state, no replicas and unchanged performance/encryption settings. Use the **fresh GET ETag**, not the preflight or pre-backup ETag.

Invoke only:

```python
block.update_boot_volume(
    verified_boot_id,
    oci.core.models.UpdateBootVolumeDetails(size_in_gbs=50),
    if_match=fresh_boot_response.headers["etag"],
    retry_strategy=oci.retry.NoneRetryStrategy(),
)
```

GET/read back until the exact boot volume is AVAILABLE at 50 GB / 51,200 MiB. Confirm unchanged target attachment, AD, key/performance/autotune settings; record fresh fingerprints/ETags and the expected storage usage of 197 GB. HTTP 412 requires stopping for read-only reconciliation, not an unconditional retry.

Using the existing authorized Windows→SSH path, recheck the selected device and mount identities, then perform the Oracle-documented read/rescan on **sda only**:

```sh
sudo dd iflag=direct if=/dev/sda of=/dev/null count=1
# Write exactly "1\n" to /sys/class/block/sda/device/rescan.
```

The write is performed by a small privileged Python operation against that exact root-owned sysfs path after identity checks; do not interpolate a discovered arbitrary path into a shell. Wait boundedly for `blockdev --getsize64 /dev/sda` to report **53,687,091,200**. Confirm existing partition/mount UUIDs and protected sda15/sda16 geometries remain unchanged.

Run **`sudo growpart --dry-run /dev/sda 1`** first. Record its exit status and full proposed table. Require only root partition 1 to grow; preserve its start/type/UUID, the disk GUID, sda15/sda16 identities and their boundaries. The proposed end must match the reviewed GPT maximum above. The installed growpart 0.33-1 source removes the `last-lba` header from its new dump deliberately and reserves 33 trailing GPT sectors. The parser requires that installed format, derives last usable LBA from the independently verified device bytes, checks the exact proposed partition end and checks the actual GPT header after growth. Any unexpected difference stops before the partition write.

Only after the dry-run passes, run **`sudo growpart /dev/sda 1`**. Re-read `sfdisk --json`, `lsblk`, `findmnt` and `blockdev --getsize64 /dev/sda1`. Require the new root geometry and unchanged identities. If the kernel has not recognized the new partition size, stop for review; do not force a reboot, unmount or destructive reread.

Then run **`sudo resize2fs /dev/sda1`** with no force, shrink or filesystem-feature flags. Read back the ext4 UUID, block size/count, state, reserve count and mount. Require the filesystem to fill the verified larger partition within sub-block rounding. Verify GSD HTTP health and daemon/socket continuity before starting the data update.

[Oracle rescan procedure](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/rescanningdisk.htm) · [Installed-version growpart manual](https://manpages.ubuntu.com/manpages/noble/man1/growpart.1.html) · [Installed-version resize2fs manual](https://manpages.ubuntu.com/manpages/noble/man8/resize2fs.8.html)

## Stage 3 — ETag-guarded data update and whole-device ext4 growth

Only after root growth and continuity gates pass, recheck data's exact attachment/ID/AD, 100 GB / 102,400 MiB, AVAILABLE state, no replicas, read-write/nonshareable status and unchanged settings. Require at least the remaining 3 GB of capacity. GET a fresh data ETag and invoke only:

```python
block.update_volume(
    verified_data_id,
    oci.core.models.UpdateVolumeDetails(size_in_gbs=103),
    if_match=fresh_data_response.headers["etag"],
    retry_strategy=oci.retry.NoneRetryStrategy(),
)
```

GET/read back the exact 103 GB / 105,472 MiB target and unchanged attachment/settings. Reconfirm that `/dev/sdb` is still the same whole-device ext4 mounted at `/mnt/development`.

Use the same read/rescan sequence for **sdb only**, then require its device size to be **110,595,407,872 bytes** and its filesystem UUID/mount unchanged. There is no growpart step for data. Run **`sudo resize2fs /dev/sdb`** without force or feature flags. Require block size 4,096, expected block count 27,000,832, unchanged UUID, clean state and the same mounted device. Verify public/PocketBase health and daemon/socket continuity again.

## Stage 4 — final readback and explicit evidence

Read back both target provider sizes/performance/attachments and both FULL backups. Confirm the matching-AD storage usage is 200/200 GB with no quota increase, and record the actual backup count. Do not inspect or modify the unrelated boot volume to manufacture capacity.

Compare the complete pre/post selected partition and filesystem metadata. Preserve root start/UUID/type, both protected boot partitions, filesystem UUIDs, mount identities and reserve policy. Record exact final filesystem blocks and free bytes/inodes, not a forecast. Growth that fails to produce expected usable space remains a limitation even if the provider update succeeded.

Pin the following long-lived units from the observed guest preflight; repeat fresh before and after mutation:

| Unit | Observed PID | Observed listening endpoint |
|---|---:|---|
| `gsd-pocketbase.service` | 3365518 | 127.0.0.1:8095 |
| `gsd-cloud-gateway.service` | 3422173 | 127.0.0.1:8770 |
| `gsd-mcp-bridge.service` | 2118307 | 127.0.0.1:8768 |
| `lorvex-cloud.service` | 3336621 | 127.0.0.1:8769 |
| `lorvex-mcp-bridge.service` | 3287789 | 127.0.0.1:8767 |
| `lorvex-cf-quick.service` | 1807512 | 127.0.0.1:20241 |

All were active/running at 05:41:38 UTC. Compare PID and start time, not PID alone. The existing Lorvex backup oneshot was inactive/dead with prior exit status zero; it is not a daemon to restart, and any natural schedule transition is recorded separately.

GSD health checks are the already verified `http://127.0.0.1:8095/api/health` and `https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud/api/health`. Lorvex proof is explicitly limited to systemd state/PID/start time/listening sockets; no verified application-health URL or functional E2E is available in this scope.

## Receipts, failure and partial-state handling

Each stage writes an atomic private Windows receipt with operation/phase, timestamps, expected and actual state, sanitized API/command status, prior-receipt digest and an explicit PASS, PENDING or FAILED outcome. Guest growth runs as a fixed detached worker in a root-owned mode-0700 directory under `/var/lib/gsd-capacity-20261124/<operation>/<phase>`, with mode-0600 source/logs and durable server intent, permanent worker claim, per-step progress and final result. It starts a new session, uses closed stdin and file-backed stdout/stderr, and survives observer/SSH/Windows timeout. Observation never launches, kills or restarts a worker. Unknown launch outcomes require read-only reconciliation; there is no automatic retry. Publish only sanitized metadata. Never log the OCI key/config, authorization headers, archive contents or unrelated resource identifiers.

The outer worker must check the inner result, all guard booleans and expected child exit codes. Any FAILED inner stage must make the wrapper exit nonzero after saving its receipt. PENDING backup waits must not be labeled completed or permit a resize. A successful receipt write or wrapper exit zero alone is never a pass.

| Failure point | Required behavior |
|---|---|
| Before any backup | Stop without cloud/guest mutation; preserve exact failed guard |
| One backup exists, other pending/failed | Keep existing backup, record its ID privately; no resize or duplicate create |
| ETag / quota / permission rejection | Stop, preserve error code and read-only actual state; no IAM/limit/billing change |
| Provider size changed, guest has old geometry | Record allocated-but-not-grown state; do not shrink the volume or touch the next target |
| Dry-run or partition identity differs | Stop before partition mutation; retain old table and backup evidence |
| Partition grew but ext4 did not | Preserve mounted state and read-only diagnostics; no forced fsck, unmount, reboot or restore |
| Unexpected service/PID/socket/health change | Finish any already running noninterruptible filesystem command, then stop before the next stage and report the exact change |
| Unknown outcome after transport interruption | Reconcile exact resource/state and stable create token; do not blindly repeat a mutation |

Oracle volume expansion cannot be reversed by shrinking. Restoring a whole volume could require additional resources and interruption and is outside this runbook's automatic actions. Existing full backups are retained for a separately reviewed recovery decision. [Oracle resize constraints](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/resizingavolume.htm)

After successful verification, update Cloud Asana with source/evidence commits, actual backup states, byte/partition/FS/PID/health readbacks, limitations and the native-clearance window. Keep the Cloud task open until its separate native and account acceptance criteria are met.

## Reviewed phase executors

The provider body and thin wrapper are pinned separately from the detached guest worker, controller and Windows launch/observe wrapper. Source hashes and exact commands are recorded in the execution receipt. These are narrowly scoped operational scripts, not application changes or an automatic maintenance service. The read-only guest `--phase preflight` does not create the server state directory.
