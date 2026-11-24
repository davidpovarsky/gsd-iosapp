# Automatic connectivity scheduling probe — 24 November 2026

## Scope

This is a test-only addition approved during the cloud acceptance review. It fills
the gap between a monitor event and the coordinator choosing the existing sync
engine's `networkRegained` trigger. Production source and package targets are
unchanged.

`scripts/check_sync_connectivity.py` reads the current
`App/Sync/SyncCoordinator.swift` at execution time. It removes exactly the three
imports at the platform/package boundaries (`Network`, `GSDSync`, `GSDStore`) and
compiles the complete coordinator implementation with real Foundation and
Observation. The receipt prints the source file's SHA-256. Source-boundary drift
fails explicitly instead of silently testing a copied implementation.

The controlled monitor records registration, start and cancellation. It delivers
statuses to the actual registered `pathUpdateHandler` from the dispatch queue the
coordinator supplied. The test never calls private scheduling methods or invokes
`engine.sync` itself. A cancelled monitor can deliver an explicitly simulated
already-queued callback, which exercises the lifecycle/session guards.

The engine boundary only records calls and returns immediate results. Its async
methods remain on MainActor and contain no suspension points, making callback
health acknowledgments deterministic for this scheduling probe. It contains no
task repository, synchronization algorithm, credentials or network requests.
The existing `tokenProvider { nil }` seam keeps SSE out of these cases. Every
fixture stops the coordinator on exit, including on a failed assertion.

## Eight acceptance cases

1. Launch registers and starts a monitor and requests the initial sync.
2. Loss updates offline health; return automatically requests exactly one recovery.
3. Initial/repeated satisfied or repeated unsatisfied statuses cause no duplicate.
4. Background cancels the monitor and suppresses a queued return; foreground
   installs a fresh monitor and requests foreground sync.
5. Sign-out cancels monitoring, resets the cursor and suppresses queued recovery
   and lifecycle/manual triggers while the session is absent.
6. A session that disappears before lifecycle teardown cannot trigger recovery.
7. A pending sign-in/account decision holds recovery even if the signed-in
   predicate is true; explicit acceptance restores automatic recovery.
8. Account deletion holds recovery and other triggers; a failed deletion can
   explicitly release that hold and resume synchronization.

Each callback/status wait is bounded at two seconds. Compilation is bounded at
180 seconds and execution at 20 seconds. A timeout terminates only that child
process tree, returns failure, and cleans the dedicated temporary directory.

## Commands and evidence boundary

The native lane runs this unconditional Mac gate outside package-evidence reuse:

```sh
python3 scripts/check_sync_connectivity.py
```

A behavioral pass must finish with exit 0 and:

```text
SYNC_CONNECTIVITY_RESULT passed=8 failed=0
```

Windows validation is limited to Python syntax, generated Swift frontend parsing
(`python scripts/check_sync_connectivity.py --parse-only`), and `git diff --check`.
The parse-only mode reports `behavior=not_run`. Its receipt is recorded at
`docs/ai-agent/evidence/sync-connectivity-20261124/windows-parse.json`.
Mac behavioral acceptance is pending the native lane's canonical gate; this
commit does not claim a runtime pass.

The separately passing
`CloudNativeSystemTests.closedNativePullOfflinePushNewDeviceAndAccountIsolation`
exercises real GRDB, the real SyncEngine and production Oracle after an explicit
engine trigger. That evidence and this scheduling probe cover separate layers.
This probe does not prove real engine actor interleavings, physical Wi-Fi changes,
SSE reconnects, timer cadence or native account UI behavior.

### Windows receipt

Python syntax and generated Swift parsing passed at 03:14:21 UTC. The first
parse-only attempt timed out after 30 seconds without compiler diagnostics;
`windows-parse-timeout.json` preserves it. The final check used the explicit
`-frontend -parse` entry point from the earlier successful native-source syntax
receipt. No Windows typecheck, executable build or behavioral run was attempted.
