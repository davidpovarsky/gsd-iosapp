# Windows off-server backup

This complements the Oracle daily backup. It does not change the SSH identity, host-key policy, Windows account privileges, or SentinelX policy.

## Installation and schedule

Run the existing Python interpreter as the intended Windows user:

    python cloud/windows/install_offsite_backup.py --source-revision <published-commit>

The installer refuses an unrelated existing task and verifies restricted directory ACLs. Its only task is **GSD Cloud Offsite Backup**. It uses the current user's interactive token and least privilege; no account password is requested or stored.

- Daily at **03:35 UTC**, after Oracle's 03:15 UTC backup plus up to ten minutes jitter.
- StartWhenAvailable is true; an additional trigger catches the same user's next logon after a two-minute delay.
- Two retries ten minutes apart on failure.
- Ten-minute execution limit; concurrent task instances are ignored.
- Windows must be running, have network access, and the same user must be logged in. Locking the session is compatible with the interactive token. This is not an always-on offsite service.

Installed files are beneath %LOCALAPPDATA%\GSD\BackupTools. Encrypted archives are beneath %LOCALAPPDATA%\GSD\Backups. These directories are restricted to the current user, SYSTEM and local Administrators. The source task definition and receipts contain no credentials.

## Data handling

The worker connects using the existing torah-social OpenSSH alias with BatchMode=yes and the existing host-key verification. It selects only the newest exact GSD archive filename, rejects archives older than 48 hours, and invokes the existing Oracle restore-verification function.

Transfer is bounded to **128 MiB** and **180 seconds**. The archive is received in memory. The worker verifies its SHA-256 and every archive manifest entry, with a **512 MiB** expansion limit. It uses Windows **CurrentUser DPAPI**, verifies decryption, writes only encrypted bytes to a temporary file, flushes it, and atomically replaces the final path. The installed file is read back, decrypted in memory, and its hash and manifest are verified again.

No plaintext archive is written to the Windows filesystem. Retention deletes only the worker's exact gsd-cloud-YYYYMMDDTHHMMSSZ.tar.gz.dpapi names beyond the seven newest, and their paired receipts. Unrelated files are excluded. A source archive already present with a different decrypted hash is rejected, not overwritten.

offsite-last-run.json contains the result, timestamp, source archive, SHA-256, aggregate restored row counts, verification result and removed GSD archive names. It contains no tokens, private keys, passwords or user task data. The source backup includes the gateway's secret state/key inside the encrypted archive.

## Recovery and verification

The encrypted copy requires the original Windows user's DPAPI context; it is not portable to an arbitrary machine/account. Preserve the Windows account/profile recovery path as part of disaster recovery.

Each successful copy records its original archive SHA-256 in a paired receipt. The worker's dpapi(ciphertext, decrypt=True) and verify_manifest(plaintext) functions can verify a copy entirely in memory. A server restore should first use a private staging directory and cloud/backup.py --verify before any deliberate service/database replacement.

The self-test uses synthetic bytes and a temporary retention fixture:

    python cloud/windows/offsite_backup.py --self-test

Actual acceptance must also invoke the registered task with schtasks /Run /TN "GSD Cloud Offsite Backup" and verify its completed receipt and Task Scheduler result. The self-test alone is insufficient.

## Windows API references

- [DPAPI CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
- [DPAPI CryptUnprotectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptunprotectdata)
- [UTC StartBoundary](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/nf-taskschd-itrigger-get_startboundary)
- [StartWhenAvailable](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-startwhenavailable)
