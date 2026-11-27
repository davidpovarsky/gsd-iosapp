# Populated backup recovery — 2026-11-27

## Result

PASS on Oracle using deployed PocketBase 0.40.6 and the deployed backup script, hooks and migrations, copied into an isolated loopback fixture. One synthetic account, one Hebrew/Unicode task and one saved view were backed up online. The original fixture process was stopped before restoring the archive into a separate directory and starting a new PocketBase process. Normal account authentication and full-record reads succeeded after restore; both task and saved-view content hashes matched exactly. All fixture processes and the temporary populated directory were removed.

The reusable test is recovered unchanged from commit `6ecccbbad34404a412e7eeca2f396ff6dc25292d`. This report records the new run and does not replace or relabel historical evidence. The production gateway deployment remains commit `9d0f763bef923082957c74869583919f816aa212`; this follow-up changes only the regression test and this report.

## Evidence

Oracle directory: `/mnt/development/projects/evidence/gsd-lorvex-integration-20261127/cloud`.

- `gsd-populated-restore-20261127.json`: detailed restore receipt, timestamps 00:09:53–00:09:54 UTC.
- `gsd-populated-restore-20261127-run.json`: exit 0, run log SHA256 `923c8bb086a854bd962605f46f5a1639324cbb64501b3e2820b4aecacc07b722`.
- Test SHA256: `d35f7158574f0c3ca2b1784ede3954338470c5318a3f4e23c9f00df31cc91af1`.
- Backup implementation SHA256: `efea842528ce51a2f8a358c47216419b97bab5c8f46520720e690352f09e4e4a`.
- PocketBase binary SHA256: `419baf8f0b4fb455ac0dd3e0a59f4545eb9cc93eab0c47b20b29ec3a6f99f442`.
- Temporary archive SHA256: `edee5905b141973364a7de1566dc48f3761d3b9d396060c8e7fc55c3cce727fe`; integrity and restore checks both `ok`, counts users=1/tasks=1/gsd_library=1. This synthetic archive was removed during fixture cleanup.

Separately, the protected predeployment production backup was restored for SQLite integrity/count/key verification, and the deployed gateway passed actual canonical HTTPS OAuth, CRUD, account-isolation, durable receipt replay across a real restart, refresh and revocation acceptance. Those receipts are `predeploy-backup-receipt.json`, `gsd-production-deployment-9d0f763.json`, `gsd-canonical-https-acceptance-9d0f763.json` and `gsd-canonical-https-cleanup-9d0f763.json`.

## Reuse

Run on Linux with Python 3.12 or later and the verified PocketBase 0.40.6 binary:

```sh
python3 cloud/test_nonempty_backup_recovery.py \
  --pocketbase /path/to/pocketbase \
  --work-parent /path/to/isolated-scratch \
  --receipt /path/to/new-receipt.json
```

The test requires a new receipt path, uses ephemeral loopback ports, does not use production credentials or production database paths, and fails if cleanup is incomplete. It proves recoverability of persisted cloud content. Physical iPad synchronization and a live ChatGPT conversation are separate acceptance gates.
