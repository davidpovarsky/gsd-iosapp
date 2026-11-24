# GSD backup calendar evidence — 24 November 2026

This documentation-only follow-up starts from frozen source
`ef3a4d00670037b4583e4952704663191e345be5`, on branch
`docs/gsd-backup-calendar-evidence-20261124`. Application, server, workflow and
backup code are unchanged. Inspections used the existing Windows/SSH path and
read task/service metadata, existing receipts and file metadata. No backup,
restore, decryption, service restart, schedule change or deletion was requested.

## Oracle: first calendar invocation confirmed

The read-only inspection at **03:22:42 UTC** matched the timer's actual
`LastTriggerUSec`, the service timestamps and the journal's invocation ID.

| Evidence | Observed value |
|---|---|
| Timer trigger | 2026-11-24 03:18:35 UTC |
| Service invocation | `1c1d938067b240a5b2890ac11209f864` |
| Service result / process exit | `success` / `0` |
| New archive | `gsd-cloud-20261124T031835Z.tar.gz` |
| Archive size / permissions | 72,533 bytes / `0600` |
| Job's own verification receipt | `integrity: ok`, `restore: ok` |
| Snapshot counts | 1 user, 0 tasks, 0 library rows |

Archive SHA-256:
`f2d96aa3ae61d1a316f47de7fa27bbfabf743a8e5a2c1afefb3bcb9acb2b125b`.

The timer remains enabled, active/waiting and persistent. Its daily definition is
03:15 UTC with up to ten minutes of randomized delay and one-minute accuracy.
The next observed execution was 25 November at 03:23:05 UTC. The service is
inactive after its successful one-shot invocation.

This archive and invocation are distinct from the earlier manually invoked
`gsd-cloud-20261124T001150Z.tar.gz` backup. The scheduled service itself ran the
verification in [backup.py](../../cloud/backup.py) before emitting its receipt;
the inspection did not rerun that verification.

Receipt: [oracle-calendar.json](evidence/backup-calendar-20261124/oracle-calendar.json).

## Windows: new successful execution at the configured calendar time

The registered task reported a last run at **03:35:00 UTC** and result **0**. Its
worker receipt completed at **03:35:13.670209 UTC** with `PASS`. Windows displayed
05:35:00 in UTC+02:00, matching its registered daily `CalendarTrigger`.

| Evidence | Observed value |
|---|---|
| Task | `GSD Cloud Offsite Backup` |
| State | Ready / Enabled; InteractiveToken |
| Source archive | The same `gsd-cloud-20261124T031835Z.tar.gz` |
| Source bytes / SHA-256 | 72,533 / the exact Oracle digest above |
| Encrypted artifact | `gsd-cloud-20261124T031835Z.tar.gz.dpapi` |
| Encrypted bytes | 72,758 |
| Worker verification | Source restore `ok`; 13 manifest files verified |
| Existing stored-file readback result | CurrentUser DPAPI; decrypt/hash `PASS` |
| Plaintext written to disk | `false`, as recorded by the worker |
| Retention | Seven own archives; none removed in this execution |

The per-archive receipt and encrypted file metadata agree with
`offsite-last-run.json`. The worker's stored-file verification is implemented in
[offsite_backup.py](../../cloud/windows/offsite_backup.py); this inspection only
read the completed receipt and file metadata, without separately decrypting or
exporting the archive.

**Trigger attribution remains limited.** The task also has a logon trigger with
a two-minute delay. Its daily/logon CSV rows share the same task-level last-run
metadata. A bounded event query returned no matching events; a subsequent
read-only channel query confirmed
`Microsoft-Windows-TaskScheduler/Operational` has `enabled=false`. No event
directly identifies which trigger caused this invocation. The evidence therefore
establishes a new successful execution exactly at the configured calendar time,
distinct from the 00:32 manual invocation. It does not establish a calendar-cause
event. Event history was not enabled or changed.

The next daily execution shown by the scheduler was 25 November at 03:35 UTC.
Automatic offsite execution requires Windows to be available, online and logged
into the existing user account. Recovery of CurrentUser DPAPI data depends on
that original Windows account/profile. `StartWhenAvailable` remains true.

Receipt: [windows-offsite-calendar.json](evidence/backup-calendar-20261124/windows-offsite-calendar.json).

## Capacity observation, restricted to GSD

At 03:22:42 UTC, `/` had **158,322,688 available bytes (150.99 MiB)** and
`/mnt/development` had **966,623,232 available bytes (921.84 MiB)**.

The separate bounded metadata inspection at 03:27:05 UTC covered 47 files and
13 directories inside `/mnt/development/projects/gsd-cloud`. It completed without
errors, followed no symlinks or foreign mounts and read no file contents.

| Current retained GSD files | Allocated bytes |
|---|---:|
| Entire project directory | 33,673,216 (32.11 MiB) |
| PocketBase executable, unchanged since October | 31,789,056 |
| `pb_data` | 1,372,160 |
| All backups | 192,512 |
| Files with mtimes since 01:30 UTC | 753,664 (736 KiB) |

These retained GSD files do not account for the approximately 800 MB decrease in
volume availability. This is a size snapshot, not a measured growth delta;
recent-file sizes must not be read as newly allocated growth. Other projects,
open-but-deleted files and filesystem-level attribution were not inspected.
Nothing was deleted or changed to reclaim space.

Receipt: [gsd-disk-size-review.json](evidence/backup-calendar-20261124/gsd-disk-size-review.json).

## Acceptance boundary and tracking

The snapshot contains no tasks or library rows. The verified snapshot/manifest
evidence does not demonstrate recovery of nonempty task data or booting an
alternate production server. One observed calendar window also does not prove
continued future execution. Oracle's timer invocation is directly confirmed;
Windows trigger-cause attribution remains limited as stated above.

The milestones were appended to [Cloud task 1220825972434803](https://app.asana.com/1/1219597879016953/project/1220770501963372/task/1220825972434803),
with exact readback and prior notes preserved. The task remains open for the
remaining original acceptance criteria. No project status was created. This lane
did not dispatch CI for the evidence-only follow-up.
