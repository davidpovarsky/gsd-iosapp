# GSD Oracle — bounded maintenance execution evidence, 24 November 2026

## Observed outcome at this checkpoint

**PASS — both fixed volume expansions and their guest filesystems are complete and verified at 06:51:02 UTC.** Boot is 50 GB; data is 103 GB. Exactly two FULL provider backups were created first and remain AVAILABLE. Exactly one size-only PUT was accepted for each target. No backup or other volume was deleted, no quota/IAM/performance setting was changed, and no service was stopped or restarted. The application source stayed frozen.

The operation identifier is `6e6b1bb1e28f4d1fada42ec0ada4da58`. Exact resource IDs, credentials and retry tokens remain in private authorized receipts. Public evidence contains fingerprints, expected target bindings and states.

## Provider snapshots

| Phase | Actual proof | Sentinel job |
|---|---|---|
| Pinned setup/preflight | PASS; 9 provider HTTP 200 reads; 194/200 GB, 6 available, 0/5 backups; unchanged exact attachments/AD/settings; fresh guest/service/socket/health gate | `job_ac1c8b132ad4` |
| Boot FULL create | One HTTP 200 POST; exact-ID GET REQUEST_RECEIVED; PENDING exit 2 | `job_957a251ffd9f` |
| Data FULL create | Fresh guest/service/HTTP gate passed; one HTTP 200 POST; exact-ID GET REQUEST_RECEIVED; PENDING exit 2 | `job_3d202f75a4f0` |
| Both exact snapshots | Two HTTP 200 GETs; both AVAILABLE, type FULL, expected sources; no mutation; PASS exit 0 | `job_284610347fed` |

Boot backup fingerprint: `9790b990d1a830d8174ed2412748f4282ee765f3048e0ffd88aa51528a567220`.

Data backup fingerprint: `784bd08cf905158138d0ba98ac78afa8f819e7551e4b1f098e556ee5604f69e3`.

Sentinel labels a job with exit 2 “failed” generically. The reviewed provider and wrapper deliberately use **2 for PENDING**, **0 for PASS**, and **1 for FAILED**. The JSON status, exact resource state and matching inner/wrapper/outer exit were inspected. The first two creation receipts are pending observations, not failures or proof of completed backups; the later AVAILABLE receipt supplies completion evidence.

These are online provider snapshots of running shared volumes. AVAILABLE does not establish a restored boot, cross-volume application consistency or Lorvex recovery. The existing GSD SQLite backup and Windows DPAPI/offsite evidence remain separate, as documented in [the calendar report](BACKUP_CALENDAR_ACCEPTANCE_20261124.md).

## Strict guest guard validation

The initial actual read-only preflight at **06:29:21 UTC** stopped before mutation with `PROTECTED_BOOT_IDENTITY_CHANGED` (`job_77ad03e0cc23`). Cached original/current private receipts proved the entire selected EFI partition record and its UUID bytes unchanged. Its originally uppercase FAT UUID had been fingerprinted without normalization while the worker normalizes UUID case. Only the expected EFI constant was corrected from the uppercase hash to the verified lowercase hash; source hash pins were updated accordingly. The failed receipt and zero-API cached diagnosis are preserved.

The corrected actual-source preflight passed at **06:32:01 UTC** (`job_3b5b861ee517`): old disk/partition/FS geometry, all protected partition and filesystem identities, ext4 clean/zero-reserve state, read-write mounts, six unchanged daemon PID/start/socket identities and both known GSD HTTP health checks. The mutating command list is empty. It created no server operation directory.

At this pre-growth checkpoint, available bytes were **270,254,080 on root** and **412,041,216 on data**. These are measured values, not a post-growth forecast.

## Exact reviewed operational sources

The five scripts implement only the fixed targets and independently invoked phases in [the runbook](OCI_BOUNDED_EXPANSION_RUNBOOK_20261124.md). No application source, integration branch, service configuration, package, IAM policy or quota was modified to prepare them.

| Source under `operations/capacity-20261124/` | SHA-256 |
|---|---|
| `gsd_capacity_provider_20261124.py` | `120f7c47e7060d030bfecc5c4b6a5e0d8ec5251d5d2811f6d76e1c10ecd90594` |
| `gsd_capacity_provider_windows_20261124.py` | `7924c9bfbdaebdd7fb5d6adcabd0dfef90ed6c3e737519e9816300b0fbe1932a` |
| `gsd_capacity_guest_20261124.py` | `4da02615b3b3eec8cc6b8021ca57749b382e479e1e5957005cf802edf97aa914` |
| `gsd_capacity_guest_control_20261124.py` | `cd9c174631a75db699fa0063a750d1512428a41ebc564675ef9d9d00d32d908d` |
| `gsd_capacity_guest_windows_20261124.py` | `1dc0580b39c282c6dfa33414acda06da86f14f65adee9d0dd2e9e25f898a62fb` |

The provider persists the exact request intention, stable retry token and expected body before a POST, uses explicit no-retry semantics and fresh ETags before size updates. Each phase is invoked separately. A prior ambiguous request is never silently replaced.

The guest worker runs in a new detached session with closed stdin and private file-backed stdout/stderr. A root-owned mode-0700 directory under `/var/lib/gsd-capacity-20261124/<operation>/<phase>` retains its hash-pinned source, durable intent, permanent worker claim, current-step progress and final receipt. Worker writes do not receive a command timeout. A short launch/observe call can time out without terminating the detached worker; a subsequent observation reads exact process identity/receipt and never relaunches or kills it. Only verified final PASS produces the Windows phase proof that permits the next provider stage.

The installed growpart 0.33-1 source deliberately removes `last-lba` from the proposed dump and reserves 33 sectors for the secondary GPT. The parser derives that header only from the verified new disk size, requires exact root start/size/end and both protected partitions, then verifies the actual written GPT. No direct sfdisk mutation, forced repair, unmount, reboot or reserve change is included.

## Execution commands and stopping conditions

From the single retained isolated SDK environment, the approved order is one call at a time:

1. Provider `--phase resize-root --execute`; await exact provider PASS.
2. Guest Windows wrapper `--phase root-growfs --action launch --execute`; then `--phase root-growfs --action observe` only, until final PASS.
3. Provider `--phase resize-data --execute`; await exact provider PASS and the accepted root guest proof.
4. Guest Windows wrapper `--phase data-growfs --action launch --execute`; then `--phase data-growfs --action observe` only, until final PASS.
5. Provider `--phase verify` plus final guest geometry/free-space/service/HTTP evidence.

PENDING or FAILED does not advance automatically. Unknown outcomes require read-only reconciliation, not duplicate writes, worker restarts, deletion, quota changes or a rollback-by-shrink. Root keeps native network acceptance on hold through the maintenance window.

## Final growth results

### Boot provider phase

The single size-only, fresh-ETag update was accepted HTTP 200 in `job_74d2a5d4b9d8`. Its initial readback at 06:34:50 UTC showed 50 GB / 51,200 MiB in PROVISIONING state and storage usage 197/200 GB, so the phase returned PENDING 2 and did not start guest growth.

The separately invoked guarded readback (`job_3397fda4430a`) confirmed the exact boot volume AVAILABLE at 06:36:53 UTC, with unchanged attachments, 10 VPU/GB, autotune off, no replicas and both FULL snapshots AVAILABLE. It made zero cloud mutations and marked the local update ledger CONFIRMED. No second PUT was issued.

### Root guest phase

A single detached launch in `job_9410ee56e1e3` returned PENDING with worker PID 3487091. A separate observe call at 06:40:54 UTC read the durable final PASS; it did not relaunch or signal the worker. Root dry-run, partition growth and resize2fs each exited 0. The resulting root partition has start 2,099,200, size 102,758,367 sectors and last usable GPT LBA 104,857,566; root ext4 has 12,844,795 blocks of 4,096 bytes.

The EFI and /boot partitions, all UUIDs, filesystem features, zero reserve policy, mount options, six daemon PID/start/socket identities and both known GSD health HTTP 200 checks were preserved. The final private guest receipt fingerprint is `b9d73fc6260cfba6cc74878f7a7d95c8b8e22f035ad1adb80a401cbc180be0fe`.

Root available space in that phase's snapshot was **3,832,913,920 bytes**. The unmodified data filesystem had **178,626,560 bytes** available, demonstrating continued capacity pressure; that observation is not attributed to another project without evidence. The data phase follows only after the accepted root proof.

### Data provider phase

The single fresh-ETag, size-only update was accepted HTTP 200 in `job_dda1b2cf0540`. The initial 06:42:20 UTC readback showed 103 GB / 105,472 MiB in PROVISIONING and quota usage 200/200 GB. It returned PENDING 2 and did not start the guest phase.

The separate existing-request reconciliation (`job_4dde420cc69e`) made zero cloud mutations and confirmed AVAILABLE at 06:44:47 UTC. Both target settings/attachments remained unchanged, provider backup usage was 2/5, and the two exact FULL snapshots remained AVAILABLE. No second PUT was issued.

### Data guest phase

One detached launch (`job_5d86b8bb13a9`) returned PENDING with worker PID 3489055. Separate observation at 06:48:46 UTC read the durable final PASS. The fixed sdb rescan and whole-device resize2fs completed; no data partition was created or changed. The data device is exactly 110,595,407,872 bytes and ext4 has 27,000,832 blocks of 4,096 bytes. Root remained at its verified new geometry.

All fixed UUID/partition/mount, filesystem feature/reserve, daemon identity/socket and known GSD health gates passed. The private final data receipt fingerprint is `1d1277d10103c77605629bd3787cd5dc3b992d31e168ce9e8f466f561fe86c20`. Measured available bytes in that snapshot: root **3,708,596,224**, data **3,346,681,856**.

### Final provider, guest and service readback

`job_e207f61d2ae6` passed at **06:51:02 UTC**. Eleven final provider GET/list calls returned HTTP 200, with **zero cloud mutations**: both target volumes AVAILABLE at 50/103 GB, 10 VPU/GB, autotune off, expected original attachments/AD/settings and no replicas; matching-AD storage usage **200/200 GB**; backup usage **2/5** and both exact FULL snapshots AVAILABLE.

The fresh guest readback loaded the hash-pinned worker's existing validation functions without running its main/write path. It checked both new geometries, filesystem/partition UUIDs, protected EFI and /boot partitions, read-write mounts, full original mount options and filesystem features, zero reserved blocks, and the six unchanged daemon PID/start/socket identities. Both known GSD health checks returned HTTP 200 with body code 200. Both original detached workers were no longer running and retained final PASS receipts.

| Layer | Final measured value |
|---|---:|
| Whole boot device | 53,687,091,200 bytes |
| Root partition | 52,612,283,904 bytes |
| Root ext4 | 12,844,795 × 4,096-byte blocks |
| Whole data device / ext4 | 110,595,407,872 bytes / 27,000,832 × 4,096-byte blocks |
| Root available bytes | **3,708,383,232** (about 3.45 GiB) |
| Data available bytes | **3,346,444,288** (about 3.12 GiB) |
| Root available inodes | 4,807,154 |
| Data available inodes | 4,749,147 |

Final private guest receipt SHA-256: `92d9ae4bf6a1e45b7e38c88f21772c9b38ce94e91373ec920c828e2aca71e138`. The original sanitized combined receipt was `6ef0ec2367228b53e9ddb2aa06752a357df2104882515d6d3b62db8236fd921e`; the checked-in copy adds the Sentinel job identifier for traceability.

Root accepted the final result and released the native maintenance hold. No further production volume/service/data mutation is planned in this operation. Native validation and the separately approved isolated port-0 nonempty recovery check retain separate evidence and scope.

## Limits that remain

Available filesystem space is a point-in-time measurement and continues to vary with live workloads. The bounded expansion removes the immediate small-free-space condition; it does not identify the source of ongoing consumption or establish a long-term capacity policy. Matching-AD storage allocation is now **200/200 GB**, so this operation leaves no additional allocation headroom under that unchanged limit.

Both provider backups are AVAILABLE, but no whole-volume boot restore or Lorvex application-consistency test was performed. Lorvex verification is limited to unchanged long-lived service identity/listening sockets. No claim of guaranteed zero billing is made: the regional capacity proposal records the applicable allowance metadata, public-price discrepancy and conditional standard-list arithmetic. The other boot volume and unrelated project data were not modified or inspected for content.


## Owned SDK cleanup

After the terminal verification, `job_f39da50933d7` removed only the operation-owned Windows `sdk-env-bounded-expansion` environment and verified its absence at **06:53:32 UTC**. Original OCI credentials/config, source, private ledger and receipts were retained. Windows free bytes rose from 36,274,003,968 to 36,592,910,336 during the bounded cleanup. No Oracle package, service, backup or data was removed.
