# Nonempty GSD backup recovery acceptance — 24 November 2026

## Observed result

**PASS at 07:08:46 UTC.** One actual isolated recovery fixture ran with the existing PocketBase **0.40.6** executable, the unchanged committed `cloud/backup.py`, and the exact committed hooks/migrations. The backup contained **1 user, 1 task and 1 library record**. After stopping the source PocketBase, a separate restored instance accepted a fresh password login and returned task and library records exactly equal to the original records.

The fixture performed no production account, data, gateway, service or storage-capacity mutation. It used its own root-filesystem directory and two sequential child PocketBase instances, each bound to a kernel-assigned loopback port. The production GSD and Lorvex processes continued with the same PIDs, start identities and listening sockets. Both known GSD health endpoints returned HTTP 200 and JSON code 200 before and after.

## Exact source and execution

| Item | Evidence |
|---|---|
| Fixture source commit | `6ecccbbad34404a412e7eeca2f396ff6dc25292d`, branch `test/gsd-nonempty-backup-20261124` |
| Fixture | `cloud/test_nonempty_backup_recovery.py`, SHA-256 `d35f7158574f0c3ca2b1784ede3954338470c5318a3f4e23c9f00df31cc91af1` |
| Unchanged committed backup implementation | SHA-256 `61370295d45e7480a9b08d363d92f22c9516a9312b9a1260929c233daf0ab213` |
| Six-file source package | 9,947 bytes; SHA-256 `09791d6fcc7fd584814e05116513b6822db4d0ab2a1b35000e5855191831b558` |
| PocketBase executable | Version 0.40.6; SHA-256 `419baf8f0b4fb455ac0dd3e0a59f4545eb9cc93eab0c47b20b29ec3a6f99f442` |
| Successful wrapper | SHA-256 `a05cb155fe34829b7b4cfad96e04897a8fdb47ff00e42b5b2b1dc5e83d20f8ae` |
| Actual test interval | `07:08:46.055999`–`07:08:46.828421 UTC` |
| Wrapper and live-service checks finished | `07:08:46.982298 UTC` |
| Launch job | `job_d4277b5ad3ce` |
| Terminal observation job | `job_3118f46ba6c9`, read-only observation at `07:09:14.996199 UTC` |
| Test exit | `0`; terminal wrapper result `PASS`; observed worker no longer running |

The exact source-only manifest is preserved beside the receipts. The archive had exactly six regular files: the fixture, backup implementation, two hooks and two migrations. Each file's byte count and SHA-256 was checked before materialization. The source package contained no executable binary, database, account data or credentials.

The one-time operational wrapper is retained under `docs/ai-agent/operations/backup-recovery-20261124/run_nonempty_recovery_once.py`. It is historical evidence for this fixed host and observation window, not a new production backup service or a command to rerun against another environment. Its exclusive claim prevents a second execution in the same owned directory. It detached the worker with closed stdin and private output files, so an uncertain SSH observation could not start a duplicate fixture.

## Content and recovery assertions

| Assertion | Actual result |
|---|---|
| Synthetic account authentication before backup | Passed |
| Hebrew/Unicode task fields, timestamps, tags and task identity | Seeded and compared exactly before backup |
| Unicode custom-view payload and library identity | Seeded and compared exactly before backup |
| Online backup while isolated source PocketBase was running | Passed through unchanged `backup.py` |
| Backup database counts | `users: 1`, `tasks: 1`, `gsd_library: 1` |
| Backup SQLite integrity and built-in restore check | Both `ok` |
| Archive size | 15,807 bytes |
| Archive SHA-256 | `2c498ffb651a58773ae8c9321bbf8917ab365205d4f315d783f7fc877108dfdc` |
| Source stopped before independently restored instance | Confirmed |
| Fresh password authentication against restored instance | Passed, same account identity |
| Full task record equality | Passed |
| Full library record equality | Passed |
| Owned PocketBase children terminated | Confirmed |
| Owned fixture directory, databases and temporary archive removed | Confirmed; zero cleanup errors |
| Successful run's source staging and fixture-parent directory removed | Confirmed independently by terminal observer |

Exact normalized-record digests before and after restoration:

| Record | Before and restored SHA-256, identical |
|---|---|
| Task | `417c92b4a5dcbebba75b6b8c5f3b7b420bf714ec4dd606285fcd708b752ced51` |
| Library view | `1d3502a60357822fbb3c400859aef2ad72a1976ed14d2a68dfb28df68ce1a535` |

The receipt contains hashes and assertions. It does not publish the synthetic credentials, authentication tokens, account identifier, record contents or database archive. The test archive was intentionally removed with the owned fixture after verification.

## Preserved preflight stop and exact correction

The first wrapper attempt, `job_a2b9390cfa52`, stopped at `PRODUCTION_BACKUP_SOURCE_DIFFERENT` before starting the fixture. Its terminal observation, `job_3442f3310121`, showed no fixture PID, no fixture-parent directory and no fixture receipt; the worker had ended. Six service/PID/socket identities and both health responses were unchanged.

The cause was a byte-level line-ending difference. The approved Git file is 5,190 bytes with 96 LF line endings and SHA-256 `61370295d45e7480a9b08d363d92f22c9516a9312b9a1260929c233daf0ab213`. Converting only those 96 line endings to CRLF produces 5,286 bytes and SHA-256 `efea842528ce51a2f8a358c47216419b97bab5c8f46520720e690352f09e4e4a`, exactly the production file's observed hash. No semantic or production file edit was required.

The root coordinator independently reproduced that transform and verified that reversing the expected-hash substitution reproduced the original wrapper hash `04ea1d2baf3012f5e065201398602c2da4c581e379e929cef54cab8077c33654`. The only wrapper logic change was the exact expected production-file hash; its dependent source pins and a fresh owned claim directory followed. The approved test and six-file source archive did not change. The failed claimed directory was never relaunched. The successful second wrapper attempt was the **first and only actual fixture execution**.

Both the stopped preflight receipt and the line-ending diagnosis are retained. The stopped attempt left only its private source/worker/receipt material, with no user fixture or database; the actual successful fixture removed all of its own test data and source staging.

## Service continuity and storage scope

| Measurement | Immediately before actual fixture | Immediately after actual fixture |
|---|---:|---:|
| Root available bytes | 3,707,727,872 | 3,707,789,312 |
| Data-volume available bytes | 3,102,003,200 | 3,102,003,200 |
| GSD production directory allocated bytes | 33,820,672 | 33,820,672 |

The GSD size check was a bounded, metadata-only `du` on `/mnt/development/projects/gsd-cloud`, without following symlinks or examining other projects. The fixture ran on the root filesystem. Its before/after window shows no reduction in data-volume available space and no change in GSD's allocated size. Earlier free-space decline remains unattributed; this check did not inspect other workloads or infer their behavior.

All six long-lived GSD/Lorvex daemons retained their exact PIDs, monotonic start identities and sockets. GSD health checks used the existing PocketBase endpoint and public `/gsd-cloud/api/health`. Lorvex evidence is service continuity only; no Lorvex application-health URL or functional workflow was tested.

## Relationship to other backup and app evidence

This proves nonempty account/task/library content recovery through the current GSD backup implementation in an isolated real-PocketBase environment. It adds content-level evidence to the earlier calendar backup and Windows DPAPI offsite tests, whose observed production archive contained **1 user / 0 tasks / 0 library**. Those earlier counts remain unchanged in their reports.

The fixture did not rerun either production scheduler, create a production backup, restore a provider volume, test a complete production disaster-recovery cutover, verify cross-volume Lorvex consistency, or exercise OAuth-grant recovery. The two provider FULL snapshots and bounded storage expansion have separate receipts in `OCI_BOUNDED_EXPANSION_EXECUTION_20261124.md`.

The frozen app source `37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc` was unchanged. Canonical native run `45343781703` was active independently; this receipt is not evidence of native UI, physical iPad, TestFlight, or personal ChatGPT Connect acceptance.

## Published evidence

Under `docs/ai-agent/evidence/nonempty-backup-20261124/`:

- `nonempty-recovery-passed.json`: terminal result, full sanitized fixture assertions, before/after service and storage checks, plus independent worker/directory observation.
- `nonempty-recovery-preflight-failed.json`: exact safe stop before any fixture process.
- `nonempty-recovery-line-ending-diagnosis.json`: deterministic LF/CRLF identity proof and the two wrapper hashes.
- `source-manifest.json`: six immutable source-file hashes and source commit.

The historical `progress.json` embedded in observation receipts records the last in-progress state. The authoritative outcome is the separate terminal `result.json` plus the independent finished-worker observation; `PENDING` in the launch receipt denotes launch acceptance only.
