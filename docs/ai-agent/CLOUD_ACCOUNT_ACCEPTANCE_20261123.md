# GSD Cloud account and sync acceptance — 2026-11-23

## Scope and architecture

Work branch: `feat/gsd-cloud-testflight-20261123`.
Initial preserved checkpoint: `86794659ad55ad18033a0f8368fee114a2c97c0b`.
The existing TaskStore, GRDB repositories, GSDSync SyncEngine and GSDWire remain authoritative. No parallel active-task engine was added.

Changes fix the production endpoint (`/gsd-cloud`), allow native guarded writes to include the immutable same-account owner, preserve exact timer stop times and notes, and synchronize archive/trash/custom-view data through the same single-flight SyncEngine. The added GRDB table stores owner-scoped sync metadata; user data stays in the original repositories. A different-account login holds sync until the existing merge/fresh/cancel decision, considers all account data, and does not persist an undecided account token across relaunch. Fresh-account erasure resets metadata so old local deletion state cannot erase the new account's data.

The cloud gateway implements the original 22-tool Hanlin catalog, including real timers, archive/trash reads, custom views, dependency cycle prevention, monthly recurrence with month-end clamping, honest partial bulk failures, and transactional soft deletion. Recurrence date arithmetic on the server uses UTC; no account timezone preference exists yet.

## Verified backend evidence

`cloud/test_cloud_e2e.py` ran against a real disposable PocketBase process and the candidate gateway on Oracle loopback ports 8096/8771. All processes and synthetic data were removed afterward. Exit 0; nine checkpoints:

1. Two ordinary email/password accounts.
2. Native-shaped guarded PATCH including owner, stale 412 conflict, owner immutability.
3. OAuth login with S256 PKCE, invalid verifier rejection, state preservation, single-use code.
4. Exactly 22 MCP tools and cross-account isolation.
5. All 22 tools execute; real create/update/complete/subtasks/dependencies/focus/bulk/timers/soft-delete.
6. Native archive and custom-view payloads, deletion tombstones, version conflict and isolation.
7. Monthly recurrence month-end behavior and idempotent repeated completion.
8. Read-only OAuth scope rejects write operations.
9. Refresh rotation, replay rejection, grant-family revocation and rejected revoked access token.

Raw non-secret evidence: `/mnt/development/projects/gsd-cloud/backend-staging-evidence.txt`.

The earlier public endpoint test reproduced the native PATCH HTTP 400 before the fix. Production deployment and public HTTPS repetition are separate gates and are not claimed by staging evidence.

## Backup and security

The gateway persists hashed opaque credentials; PocketBase bearer tokens in its state are encrypted with AES-256-GCM. Its encryption key is outside git and has private filesystem permissions. PKCE, exact registered callback matching, scope checks, account-scoped PocketBase rules, rotating refresh credentials, resource audience checks and grant revocation are implemented. Refresh credentials are claimed before network I/O so concurrent replays cannot both rotate.

`cloud/backup.py` performs SQLite online backups, includes gateway state/key and the matching server code, writes private archives, verifies checksums and restored SQLite integrity/counts, and retains only its own seven newest named backups.

Verified predeployment backup:
- Oracle: `/mnt/development/projects/gsd-cloud/backups/gsd-cloud-20261123T222739Z.tar.gz`
- Size: 29,130 bytes
- SHA-256: `7138e7194b5c263f6009add15b403abbef541bdd943bb06c94ce0d52764808b5`
- Integrity and restore: OK; baseline contained zero users and zero tasks.
- Windows off-server copy: `C:\Users\DAVID\AppData\Local\GSD\Backups\gsd-cloud-20261123T222739Z.tar.gz.dpapi`
- Windows copy encrypted using CurrentUser DPAPI under `DAVID_AND_GOLDY\DAVID`; directory ACL restricted to that user, SYSTEM and Administrators. Decrypt roundtrip matched the SHA-256; downloaded plaintext was removed.

Daily backup service/timer definitions are in `cloud/systemd`. Installation/activation is a deployment gate.

## Native verification handoff

Swift syntax parsing passed for all 23 touched/new Swift files before integration. Syntax is not a substitute for Xcode type checking, unit execution or UI acceptance.

Added focused tests:
- `CloudAccountAuthTests`: email registration/login, normalization, rejected credentials, session preservation.
- `CloudTimerWireTests`: exact stopped/running timers, cross-device remote stop, notes, legacy wire compatibility.
- `CloudLibrarySyncTests`: original GRDB repositories, durable owner-scoped tombstones, newer local edit preservation, fresh-account metadata reset.
- `CloudNativeSystemTests`: opt-in real server test through AuthService, TaskStore, GRDB, PocketBaseClient and SyncEngine. Server creates while engine is stopped; launch pulls; pending local create pushes on network-regained; another clean database pulls the same account; account B sees no A data; deletion and trash propagate.

Native runner filters:
`AuthServiceTests|CloudAccountAuthTests|CloudTimerWireTests|CloudLibrarySyncTests|CloudNativeSystemTests|SyncEngineGuardedWriteTests|SyncEngineSessionFenceTests|AccountSwitchTests`.

Live system test environment:
```
GSD_CLOUD_SYSTEM_TEST=1
GSD_CLOUD_TEST_BASE=https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud
```

Credentials are generated in memory, never printed or persisted in repository artifacts, and both synthetic accounts are deleted after the test.

XCUI accessibility IDs: `gsd.cloud.open`, `gsd.cloud.mode`, `gsd.cloud.email`, `gsd.cloud.password`, `gsd.cloud.confirmation`, `gsd.cloud.submit`, `gsd.cloud.signed-in`, `gsd.cloud.sign-out`.

Regular account routes use the PocketBase API beneath the public base: users/records, users/auth-with-password, users/auth-refresh, tasks/records; guarded task mutations use /api/gsd/tasks/{recordID}, account deletion /api/gsd/account. ChatGPT uses /mcp with scopes gsd.read, gsd.write and offline_access.

## Deployment gates outstanding at this checkpoint

SentinelX's service registry did not contain either GSD service; its service status tool returned `service_not_allowed`. The prescribed operator-approved policy registration route was escalated to the coordinating agent. No alternate shell service restart was used to bypass that decision.

Tailscale confirms public Funnel is enabled for port 10000 with /gsd-cloud -> localhost:8770. RFC discovery aliases for /gsd-cloud still need to be installed separately from the existing /gsd aliases.

Native Xcode tests, Hebrew/English simulator UI, closed-app UI flow, private ChatGPT plugin reconnection, real personal-account OAuth consent and TestFlight are owned by the coordinating/native agents and are not certified by the backend loopback tests. A simulator or backend test does not certify a physical iPad session.

## Additional OAuth durability proof

`node --test cloud/gateway/gateway-security.test.mjs` passed on Windows. It verifies exact requested consent text in Hebrew/RTL and English/LTR, absence of unrequested write/offline permission text, persisted access after restarting the gateway, encrypted PocketBase tokens and hashed opaque access tokens on disk, exactly one successful rotation from two concurrent requests using the same refresh credential, and revoked access rejection. This focused test uses a synthetic PocketBase auth fixture; the separate nine-checkpoint test above uses real PocketBase.