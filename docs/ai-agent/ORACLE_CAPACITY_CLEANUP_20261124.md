# GSD Oracle capacity — bounded cache cleanup

## Outcome

On 24 November 2026 at **04:22:32 UTC**, the reviewed cleanup removed exactly two regenerable APT binary index caches and reclaimed **123,867,136 bytes (118.13 MiB)** on the root filesystem. All three GSD services retained the same PIDs and start timestamps. PocketBase and the public GSD Cloud health endpoint both returned HTTP 200 after the operation.

The source frozen for native acceptance, `1ee8224dacf679738161a96bb1d034572bbff730`, was not changed. This is a documentation-only follow-up on `docs/gsd-backup-calendar-evidence-20261124`.

| Filesystem | Available immediately before | Available immediately after | Change |
|---|---:|---:|---:|
| Root `/` | 153,456,640 bytes (146.35 MiB) | 277,323,776 bytes (264.48 MiB) | +123,867,136 bytes (118.13 MiB) |
| Data `/mnt/development` | 702,832,640 bytes (670.27 MiB) | 702,832,640 bytes (670.27 MiB) | 0 |

These are observations at the cleanup instant. The remaining headroom is still low; this bounded cleanup does not resolve ongoing capacity requirements.

## Exact deletion scope and safety evidence

The only removed paths were:

- `/var/cache/apt/pkgcache.bin`: 61,943,808 allocated bytes; 61,937,095 logical bytes.
- `/var/cache/apt/srcpkgcache.bin`: 61,923,328 allocated bytes; 61,916,019 logical bytes.

Both files were root-owned regular files with one link, no symlink components, and the same root mount, inode, size, allocation, mode, owner, and precise modification/change timestamps as the reviewed preflight. An open-directory-relative `unlink` targeted each exact basename after another identity check. No glob or recursive removal was used. These are generated package indexes; installed packages, package databases and downloaded archives were outside the operation.

PID 1227 was positively classified as the root-owned `unattended-upgrade-shutdown --wait-for-signal` waiter. It did not map either cache. Immediately before unlink, both APT daily units were inactive/dead, no other package-manager activity was identified, and no dpkg/APT lock was held. The operation did not acquire package locks or stop a service.

The first guarded attempt, job `job_2224f8636b2a`, removed nothing. JavaScript JSON numbers had rounded the expected nanosecond timestamps by 77 ns and 67 ns; the exact identity guard rejected that mismatch. A separate read-only check confirmed that the files still matched the untouched original receipt in every field. The successful attempt used decimal strings for inode, device and nanosecond timestamps throughout; all original safety conditions remained mandatory.

No project data, journal history, backups, live acceptance fixtures, package installations, data-volume files, service configuration, reserved blocks, partitions or volumes were changed.

## Health and continuity

Job `job_8a5fc9318ddb` records the completed operation and exact before/after disk values. For `gsd-pocketbase.service`, `gsd-cloud-gateway.service` and `gsd-mcp-bridge.service`, the active/running state, MainPID and ExecMainStartTimestampMonotonic were unchanged. There was no restart window.

The two post-operation GET checks were `http://127.0.0.1:8095/api/health` and `https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud/api/health`. Both returned a JSON health response with HTTP/code 200. No account, OAuth, MCP, synchronization or UI suite was repeated.

## Filesystem capacity metadata

The read-only capacity observation was made at **04:16:56 UTC**, before cleanup.

| Mounted filesystem | Source | Type | Filesystem block count × size | Selected device bytes | Reserved blocks | Device bytes beyond filesystem |
|---|---|---|---:|---:|---:|---:|
| `/` | `/dev/sda1` | ext4 | 11,947,259 × 4,096 = 48,935,972,864 | 48,935,976,448 | 0 | 3,584 |
| `/mnt/development` | `/dev/sdb` | ext4 | 26,214,400 × 4,096 = 107,374,182,400 | 107,374,182,400 | 0 | 0 |

Both superblocks reported clean. Neither has an ext4 reserved-block pool to release. The selected data block device is already fully represented by its filesystem. The root comparison covers its mounted partition; the containing disk's partition table was not inspected. The 3,584-byte root remainder is less than one filesystem block. No capacity change follows from these observations.

The earlier GSD-only size inspection found 32.11 MiB of allocated files under the GSD Cloud project directory; it did not explain the larger decline in data-volume free space. That bounded evidence remains in [the backup calendar report](BACKUP_CALENDAR_ACCEPTANCE_20261124.md). Other projects were not traversed.

## Existing management access: bounded availability check

A separate read-only check at **04:24:15 UTC** found:

- No `oci` executable on the inspected Windows or Oracle PATH, and no OCI SDK in the inspected Python interpreters.
- No OCI config in the inspected Oracle ubuntu/root locations.
- An existing Windows own-user OCI config with profile `DEFAULT` and region `il-jerusalem-1`.
- Selected IMDSv2 instance-region metadata available with HTTP 200, also `il-jerusalem-1`.

Only profile/region names and file presence were reported. No credential value, private key, instance user-data, instance-principal credential endpoint or cloud management API was accessed. The existing Windows config is a potential authorized management route; its credential validity and volume-management permission are **not yet verified**. Preparing an exact expansion requires a separately scoped read-only target/permission review, followed by concrete capacity/cost approval before any billed change. No installation or resource change occurred here.

## Receipts

- [Exact cleanup and safety guards](evidence/capacity-20261124/apt-cache-cleanup.json)
- [Selected filesystem and device capacity](evidence/capacity-20261124/filesystem-capacity.json)
- [Management tooling availability](evidence/capacity-20261124/oci-management-availability.json)

These receipts establish the bounded cleanup and the stated metadata only. Native acceptance, personal ChatGPT Connect, TestFlight availability, and the pending native account-deletion database proof remain owned by the corresponding release gates.
