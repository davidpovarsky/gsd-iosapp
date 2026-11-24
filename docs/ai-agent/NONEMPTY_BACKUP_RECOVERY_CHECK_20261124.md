# Nonempty backup recovery check

## Status and purpose

This is a prepared acceptance check, **not a passing recovery receipt**. Its first real execution requires root review and Backend's capacity-maintenance gate. The native release candidate remains frozen at `37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc`; this test does not change that candidate or any production implementation.

The retained calendar backup proves SQLite integrity, archive checksums, restoration mechanics and off-server encrypted copying. Its manifest has one user, zero tasks and zero library records. Those results do not prove recovery of task content. This check adds exactly that missing proof using one synthetic account, one Unicode task and one custom-view library record.

## Existing implementation used

- The installed PocketBase **0.40.6** executable, supplied explicitly with `--pocketbase`. Backend confirmed the retained executable at `/mnt/development/projects/gsd-cloud/pocketbase`.
- The committed `cloud/pocketbase/pb_hooks` and `pb_migrations`, copied into a fresh private fixture. The launch flags are the same `serve`, `--dir`, `--hooksDir` and `--migrationsDir` contract used by `gsd-pocketbase.service`.
- The existing native account/task REST routes and guarded `PUT /api/gsd/library/view/{id}` route. The script does not import the existing live contract runners, which execute tests on import.
- **Unchanged `cloud/backup.py`**, invoked as a subprocess with explicit fixture `--root`, `--destination` and `--keep 1`. Its online SQLite backup and built-in archive verification run normally. The test does not implement a backup engine.

The earlier real-PocketBase staging receipt contains nine passing checkpoint lines but no retained launcher source. The new script therefore contains only the fixture lifecycle and this focused recovery assertion; it does not rerun the cloud/MCP suite.

## Exact scope and acceptance

1. Start the real binary with fresh data, hooks and migrations, bound to `127.0.0.1:0`. Discover the assigned loopback port from that child process's Linux socket descriptors. No production port is used, and no public gateway is contacted.
2. Register and authenticate one random `@example.invalid` account. Create one task containing Hebrew, accented Latin text, emoji and a newline, plus one custom-view library payload containing Hebrew. Use UUID identities matching native task/custom-view data. Read both through authenticated APIs and assert their stored content.
3. While the source server is running, invoke the actual backup script. Require successful archive integrity/restore verification and exact counts `users=1`, `tasks=1`, `gsd_library=1`. Verify the produced archive digest and its location inside the owned fixture.
4. Stop the source child before restoring. Extract that verified archive into a different fresh directory, then launch the same binary against the restored database, hooks and migrations.
5. Authenticate again with the same synthetic account. Require the same account ID, exactly one task and one library row, and exact full-record equality with the authenticated source reads. Record matching SHA-256 content digests without exposing the content or auth records.
6. Stop only child processes created by the test and remove only its `mkdtemp` directory, including on failure or normal termination. Any cleanup error forces a failed result. The receipt is created exclusively, so an existing evidence file is never overwritten.

The sanitized receipt includes the binary version/hash, hashes of all used source files, archive integrity/counts/hash, content digests, stage and cleanup outcome. It excludes passwords, bearer tokens, raw auth records, task/library bodies and database files. Temporary process logs and the archive stay inside the owned directory and are removed with it.

## Prerequisites and reviewed execution

Use Linux with Python 3.12 or later, the exact installed executable, and at least 128 MiB free on the selected work filesystem. Materialize the reviewed source tree with `cloud/test_nonempty_backup_recovery.py`, `cloud/backup.py` and `cloud/pocketbase/{pb_hooks,pb_migrations}` intact. Run the test from that reviewed source, not from the production data directory.

```sh
python3 cloud/test_nonempty_backup_recovery.py \
  --pocketbase /mnt/development/projects/gsd-cloud/pocketbase \
  --work-parent "$GSD_RECOVERY_WORK_PARENT" \
  --receipt "$GSD_RECOVERY_RECEIPT"
```

Backend selects an existing work parent on the reviewed filesystem and a new receipt path. The test creates its own unpredictable private child directory. It never accepts a source database path and never uses the backup script's production defaults. Do not execute until root approves this exact source and Backend confirms capacity readiness. A failed check must remain failed; do not publish a pass before authenticated restored reads and cleanup both succeed.

## Evidence boundaries

This check proves nonempty recovery of the native PocketBase task/library/account dataset from the real GSD archive path. It does not exercise OAuth grant recovery, production failover, gateway replacement, native UI, TestFlight, automatic scheduling or off-server copying. Existing calendar/off-server evidence remains separate. Hard process termination such as SIGKILL cannot produce a passing cleanup receipt; inspect and clean only the owned fixture if such an interruption occurs.

## Preparation verification

Windows preparation passed Python AST parsing and `--help` (exit 0) at 06:32:49 UTC. A focused local Linux check also created one disposable socket child bound to loopback port zero, verified that `owned_origin` returned that child's independently reported port, stopped it, and verified an idempotent second stop. This validates only the fixture's Linux socket/process helper; it did not start PocketBase, create accounts or execute the backup.

Root reviewed the full flow and requested native UUID identities. After that scoped correction, Windows AST parsing, `--help` and the staged diff check passed at 06:37:04 UTC. The final test script SHA-256 is `d35f7158574f0c3ca2b1784ede3954338470c5318a3f4e23c9f00df31cc91af1`. The backup implementation, migrations and hooks have no changes.

The real PocketBase/backup execution is intentionally pending final review of the published commit and Backend's capacity gate. No production services or data have been modified by this preparation.
