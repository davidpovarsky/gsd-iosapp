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
## Guarded-version regression closed

A task PATCH must change its version; reusing the expected version now fails with HTTP 400. A library payload cannot change while keeping the same version; exact idempotent retries remain safe. The native library wire client advances an equal outgoing version by one millisecond, matching the existing active-task guarded-write rule. Public unguarded task PATCH is denied; normal writes use the transactional route. Real-PocketBase staging repeated the nine affected checkpoints and passed, including same-version rejection and denied raw PATCH. Evidence: `/mnt/development/projects/gsd-cloud/backend-staging-evidence-ubuntu.txt`. This run was invoked from Windows over SSH as ubuntu and cleaned its own ephemeral processes/data.

## Public route and repository handoff

All implementation commits through cd039e1 were pushed successfully to the explicitly requested davidpovarsky/gsd-iosapp fork, branch feat/gsd-cloud-testflight-20261123. The worktree's original origin points to upstream vscarpenter, so publication used the explicit David repository URL and the existing gh credential helper without changing shared remotes or force-pushing.

Public DNS lookup returned Funnel ingress addresses 185.40.234.75, 185.40.234.55 and 185.40.234.198. HTTPS health was independently verified through the first public address using curl --resolve with normal certificate validation, returning HTTP 200. This did not use the Oracle tailnet DNS address.

The following additive port-10000 aliases were installed and returned HTTP 200 with the correct cloud issuer/resource:
- /.well-known/oauth-authorization-server/gsd-cloud
- /.well-known/oauth-protected-resource/gsd-cloud/mcp
- /.well-known/oauth-protected-resource/gsd-cloud

Every preexisting Web handler, TCP setting and AllowFunnel flag was compared and preserved. Non-secret operational evidence is in /mnt/development/projects/gsd-cloud/discovery-alias-evidence.json. Only routing changed; the old gateway process remains active until the sanctioned service-policy registration/restart gate is resolved.

For the postdeployment public E2E, set GSD_TEST_PUBLIC_IP to a freshly resolved public Funnel IP, in addition to the normal HTTPS GSD_TEST_BASE. The fixture pins only its own target-host DNS, retains hostname/SNI/certificate validation, and refuses a private address. Keep credentials out of logs.

The official Sentinel service-registration edit was dry-run successfully with YAML validation, but has not been applied. It is scoped to named GSD units/actions, and no existing service policy was relaxed.


## Production deployment and public acceptance — 2026-11-24

This section supersedes the earlier deployment gates. Production was deployed from `0e8911a33fc29eed8dfd969e43a0e6a86b63c9a4` at 2026-11-23T23:42:01Z. The existing Windows SSH identity had normal OS authorization for the two exact GSD service restart commands; those permissions were checked before use. No Sentinel registry, allowlist, authentication settings or sudo policy was changed. Both GSD production services are healthy, the gateway encryption key is preserved, and the five unrelated/legacy service states match the predeployment snapshot.

The real public E2E completed at 2026-11-23T23:45:49Z with exit 0 and all nine checkpoints above passing. It used the public Funnel IP `185.40.234.75` with the original HTTPS hostname/SNI and normal certificate validation. It therefore proves the public route without tailnet membership. Synthetic account cleanup succeeded. Raw receipts are in [evidence/cloud-20261124](evidence/cloud-20261124).

The production MCP URL is `https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud/mcp`; scopes are `gsd.read gsd.write offline_access`. All three cloud discovery aliases are active. The coordinating agent published and read back the same private plugin as version 0.2.0, release `pluginrel_6b04d42b006c81919d7c1f65c062159a`, source commit `3ec114fa4f4d7f4913f2de0983824c21899e540f`. Personal ChatGPT Connect consent and an actual ChatGPT invocation remain separate acceptance gates.

### Active backups

The immediate predeployment backup `gsd-cloud-20261123T233809Z.tar.gz` is 29,303 bytes, SHA-256 `1545902635fcf333c51783116c88005f530afb98053e364daee24111bc47d826`. SQLite integrity and restore passed. Its off-server CurrentUser-DPAPI copy on Windows was decrypted in memory and matched that hash; downloaded plaintext was removed.

`gsd-cloud-backup.timer` is installed, enabled and active. It schedules daily 03:15 UTC plus up to ten minutes random delay; the observed next firing was 2026-11-24 03:18:33 UTC. The service was manually invoked through systemd and exited 0. The initial service sandbox blocked SQLite WAL sidecar access; the corrected unit permits writes only to the GSD backup directory and GSD `pb_data`, while source database connections remain `mode=ro`. It keeps the other hardening settings.

The verified scheduled-service archive is `gsd-cloud-20261124T001150Z.tar.gz`, 48,685 bytes, SHA-256 `cfe16957e14cb4d780b145a9eb2c76dca485c362b290caae47e0048bb6f7d95e`. A fresh restore proof succeeded. It contained one existing account and zero active/library task rows at that snapshot; no account was removed by backup work. The next timer firing has not yet occurred. Automatic off-server replication is not configured; the confirmed off-server copy above was made explicitly.

Root filesystem free space was approximately 167 MiB and the GSD data filesystem approximately 1.60 GiB at verification. No package builds, root-filesystem cleanup or other-project deletions were performed.

### Final native ordering regression

Commit `a908147ffac3a1ef72f3becc427524e58449d355` moves library synchronization after the original resurrect-on-sight step, while confirming the account identity before any account data is applied. A remembered Trash ID is not published if resurrection failed transiently. Otherwise the newly introduced library could remove the server task before the original sign-in policy restored it.

Two `CloudLibraryOrderingTests` use the real GRDB repositories/SyncEngine and a destructive library-route fixture: normal sign-in restoration and a failed-then-retried resurrection. Swift frontend syntax parsing passed (exit 0); their runtime execution belongs to the canonical native CI, not to this backend receipt.

Updated native filter:
`AuthServiceTests|CloudAccountAuthTests|CloudTimerWireTests|CloudLibrarySyncTests|CloudLibraryOrderingTests|CloudNativeSystemTests|SyncEngineGuardedWriteTests|SyncEngineSessionFenceTests|AccountSwitchTests`.

The native-only ordering change does not alter the already accepted gateway/PocketBase code. The backup unit from that commit is active. Xcode, simulator screenshots, actual closed-app native roundtrip, physical-iPad availability, ChatGPT personal consent and signed TestFlight availability must be evidenced by their respective owners before the project is complete.
