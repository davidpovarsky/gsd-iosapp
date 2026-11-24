# GSD Cloud: capacity growth and bounded native admission — 24 November 2026

## Outcome and scope

The observed storage pressure comes primarily from new and changing external Hanlin worktrees, rather than GSD's small database. The latest retained read at **10:26:04 UTC** found **951,066,624 available bytes (907.008 MiB)** on the data filesystem and **2,720,710,656 bytes (2,594.672 MiB)** on root. Six original GSD/Lorvex service PID/start identities were unchanged, and both known GSD health endpoints returned HTTP 200 with body code 200.

Root accepted a proportional operational admission rule for the existing native acceptance. This does **not** complete Cloud acceptance, reserve disk space, prove a maximum write bound, or guarantee protection against arbitrary concurrent writers. A fresh check is required when Native is ready, and further reads must be coordinated with observed phase transitions. The 10:26 sample is not described as immediately before signup.

No files were deleted or moved. No service was restarted, no quota changed, no volume purchased, no archive copied, and no account or test fixture was created by this assessment. All external worktrees, source files, caches and incoming archives remain excluded from cleanup.

The machine-readable receipt is [readonly-capacity-and-admission.json](evidence/cloud-capacity-20261124/readonly-capacity-and-admission.json). Other projects' full paths and filenames are omitted from the published receipt. The original bounded Sentinel receipts remain identified by job ID.

## Measured allocation

| GSD resource at 10:26 | File bytes | Allocated bytes |
|---|---:|---:|
| Main database | 200,704 | 200,704 |
| Auxiliary database | 425,984 | 430,080 |
| Both database files | 626,688 | 630,784 |
| Four retained backup archives | 179,651 | 188,416 |
| Gateway state, two files | 1,037 | 8,192 |

The read-only SQLite geometry was 4,096-byte pages: 49 pages/one freelist page for the main DB and 104 pages/no freelist pages for auxiliary. Both databases reported WAL journal mode. No matching WAL, SHM or rollback-journal files were present in the initial file-stat sample. That is an observation at that instant; WAL allocation may appear during the next transaction. No checkpoint, vacuum or write PRAGMA was run. Connections used URI mode=ro, query_only and short read transactions.

The backup service's last run was 03:18:35 UTC, result success/exit 0. It was inactive at the read. The persistent timer remained active; its next scheduled execution was **25 November at 03:23:05 UTC**, with the existing 03:15 calendar and up-to-ten-minute random delay. There was no destination or retention override: the unchanged [backup.py](../../cloud/backup.py) default keeps seven matching GSD archives in its own backups directory. No temporary backup/restore directory was observed. At current DB file sizes, the script's three-copies-plus-16-MiB preflight requirement computes to **18,657,280 bytes**. No backup was triggered during this review.

Deletion is expected to remove account rows and owned records. It is **not** assumed to shrink SQLite files or immediately return every allocated block to the filesystem.

## Where the observed growth occurred

| UTC sample | Data available bytes | Root available bytes |
|---|---:|---:|
| 10:07:31 | 1,243,205,632 | 3,094,765,568 |
| 10:10:26 | 976,601,088 | 3,083,464,704 |
| 10:12:32 | 976,297,984 | 3,083,374,592 |
| 10:14:51 | 963,842,048 | 3,075,047,424 |
| 10:16:53 | 963,538,944 | 2,674,552,832 |
| 10:26:04 | 951,066,624 | 2,720,710,656 |

A newly inspected external worktree had 265,015,296 allocated bytes and file-change metadata around 10:10:01. Its complete metadata walk found 8,347 regular files with no multi-link allocation, primarily source, resources and retained evidence. This corresponds to 99.4% of the 266,604,544-byte data-free decline in the preceding sampled interval. It is not shared-hard-link double counting and is not a disposable build cache.

Repeated allocation measurements of the same six worktrees increased by **12,197,888 bytes**, accounting for **95.6%** of the contemporaneous **12,759,040-byte** data loss between the 10:12 and 10:16 samples. This identifies the dominant changes in those intervals, not every historical byte. Sixteen worktree roots had modification times after 08:14. No content of unrelated source files or archives was read.

The separate build-cache directory occupied 229,822,464 bytes, but no GSD ownership and exclusive reproducibility was established. Ten incoming archives likewise had no verified GSD ownership or verified off-host duplicate. Absence of an open process dependency at one instant was not treated as permission to remove anything. Broad allocation walks were stopped at their 18/40-second limits and were explicitly partial; no complete-volume inventory is claimed. Root's short-term free-space decline was not attributed to a specific writer, and the latest root sample had recovered some space.

## Exact live acceptance covered

The code reviewed is frozen product source [37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc](https://github.com/davidpovarsky/gsd-iosapp/commit/37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc). A narrow app-only startup fix may change the eventual app revision; this allowance applies only while the fixture source and scope below remain unchanged.

1. **Existing package fallback, once if required:** [CloudNativeSystemTests](../../GSDKit/Tests/GSDSyncTests/CloudNativeSystemTests.swift), blob 8d252f2e3ecb4789dee55a158e2f95cb87edd820, creates two disposable accounts and two short tasks for account A. It converts one task to a trash-library record, checks account B isolation and second-local-store synchronization, then deletes both accounts. The error path attempts both exact-account deletions and rethrows. Existing unchanged package evidence should be reused where its dependency provenance permits; this record does not bypass that verifier.
2. **Later HE-iPad UI case:** [GSDCloudReleaseUITests](../../ScreenshotTests/GSDCloudReleaseUITests.swift), blob ac894b615ccacaa81f93d0c27b095018ef19c6d8, creates one account through native UI, exercises sign-out/sign-in, creates one server task while the app is closed and one local task, then performs native account deletion with owned teardown.

The two phases are sequential: **three accounts, four task creations and one trash-library record in total**. They contain no attachment upload, large JSON workload, additional public MCP suite or extra account retry loop. The UI server-task payload contains short text and empty JSON arrays; server-list polling is bounded to twenty iterations. The package's second device is another in-memory GRDB store, not an actual second iPad.

The existing schema permits larger general-purpose JSON/library fields, so its maximum field sizes alone do not prove this allowance. This operational estimate is for these fixed small fixtures only.

## Accepted operational admission and monitoring

- Reserve **64 MiB per live phase**, **128 MiB cumulative** when the package fallback is needed. This is a conservative operational allowance, not a measured peak or formally enforced cap. It exceeds the current combined DB allocation by over two orders of magnitude and leaves room for transaction journals, indexes, auxiliary request logging and cleanup.
- Require **at least 512 MiB available on data and 768 MiB on root** in a fresh read before a live scenario is admitted. The data threshold accounts for 64 MiB of fixture allowance, a 128 MiB operating floor, one roughly 256 MiB observed external checkout burst and 64 MiB of additional slack.
- Require package fixture cleanup before admitting the later UI account phase. Re-read actual free space rather than assuming deletion reduced file sizes.
- At **less than 256 MiB on either filesystem**, stop admission of new scenarios/additional scenario writes; preserve the existing exact-owner deletion/cleanup path and its working margin. Do not stop unrelated agents or services.
- Coordinate one-shot statvfs, selected-service and known-health reads with Native's dispatch/live-phase updates. While a live phase is known active, use at most one check per minute. Stop when the phase ends; no daemon, ongoing filesystem scan or new public health API is introduced.
- Record actual measurement times. Stage visibility does not justify a claim that a read occurred immediately before signup. If the phase or measurement becomes stale, obtain a fresh read before further live admission.

Compilation and UI preparation do not need a global one-GiB data-volume hold. Passing the admission rule is permission to attempt the fixed scenario, not evidence that it passed.

## Remaining acceptance

No new native account lifecycle or deletion marker was produced by this read-only assessment. Root's exact-owner Oracle zero-row query remains a later independent check, after a real native deletion marker. Personal ChatGPT consent, physical-device behavior, SIWC eligibility and signed/TestFlight delivery are outside this capacity record. The Cloud task remains open.
