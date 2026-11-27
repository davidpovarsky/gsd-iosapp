# Share server generation acceptance — 2026-11-27

## Approved boundary

The native Share client must use the same configured PocketBase base for dataset discovery
and task creation. A nonempty server generation, at most 128 UTF-8 bytes and without ASCII
controls, is immutable capture metadata. After discovery the client rechecks cancellation,
the exact frozen credential and the local account/dataset publication. It writes the bound
generation into the existing in-flight journal before sending a create carrying
X-GSD-Dataset-Generation. A failed discovery, invalidated origin, cancellation, persistence
failure or409 must never fall back to an unguarded create.

The existing local shared lease stays held through discovery, authorization, POST and
durable outbox work. It does not substitute for the server transaction fence. Guest captures
remain local. Signed-in captures without verified generation remain durable for review.

Root owns TaskStore/queue generation propagation, atomic reset and app credential wiring.
The wire owner owns the PocketBase dataset methods. This lane owns DirectTaskPush,
ShareCaptureSession, SharedCapture, the extension and app Share consumers. No external SDK,
TaskVisualizationKit or server source is modified.

## Test-first source

scripts/check_share_dataset_generation.py copies the actual three GRDB-free modules.
The only HTTP double is the existing RequestExecuting seam; an actor records real
PocketBaseClient URLRequests and can hold a discovery response beyond cancellation or
local publication invalidation. Filesystem, outbox codec, journal and lease code are real.

The eleven fixed identities cover configured-base/auth/payload/header agreement, failed
discovery,409 without headerless fallback, delayed GET after invalidation/cancellation,
durable generation before POST, edited-save retry, crash journal recovery, failed journal
binding, a prebound stale generation, and malformed generations. The baseline has no
generation API, so a documented compile-time branch supplies only the old call signature.
The assertions and case identities are identical in RED and GREEN.

No Swift execution occurs on Oracle. The sole native owner executes immutable candidates
and preserves exact source, driver, logs and products. Prepared source is not acceptance.

## Existing cases

The eight original DirectTaskPush test identities and their payload assertions remain
mandatory. Their recording executor must learn the real GET response; successful cases
must inspect the one POST after one GET instead of assuming the first request is a POST.
No headerless production compatibility path is introduced for a test.

Original Share4 and extension10 retain their assertions. Their explicit HTTP doubles will
supply a verified fixture generation and invoke the production binding callback before
recording their simulated POST. Their purpose remains local retry/account behavior, while
the new eleven-case suite exercises the real DirectTaskPush/PocketBaseClient protocol.

The app-side drainer/title acceptance follows the root's create/save generation contract.
There is no new full Core, native Share-sheet, live server or personal-account claim in this
source checkpoint.

## Producer protocol freeze after observed RED

Native execution of immutable `7c009cb7b8789f9fbeff6dcc93a2f1ba2655920d` reached all eleven identities: 0 passed and 11 failed as expected. The preserved receipt is `share-dataset11-red-7c009cb/receipt.json`, SHA-256 `878d0142c938aac87dd7c70acfac1c43343f4a03ebd6264d4d8e8e8a528b84ef`; execution proof `84381ad91c7ed0eb50398578c0de6c0eff5d14eebca65989788bfdd99f52fd49`. This is a meaningful native RED, not a setup or compilation failure.

The producer uses the normally merged wire API `c21c46b7296ca30e92c0f090ec95acb294ea5d1d`. `DirectTaskPush.attempt` now requires an asynchronous preparation callback. Discovery and create use the same client/base and frozen bearer. The callback validates the sheet's exact credential/publication scope and atomically persists the capture's immutable server generation before create. Cancellation, failed discovery, failed journal write and stale scope cannot fall back to headerless POST. An already bound capture never discovers a newer generation. Unbound account captures stay durable and return the existing held/review state.

The original eight `DirectTaskPushTests` identities remain. Their HTTP fixture now returns a generation to GET; the create test asserts exactly one GET followed by one POST, with the generation header, while retaining all original task/owner/device/title/date payload assertions and the default-reminder assertion. The four skip cases still require zero requests. Required callback arguments are explicit fixtures, not a production bypass.

The original Share retry four assertion source is unchanged. Its controller fixture now supplies a known synthetic generation to the real preparation callback before its recording network double. The extension ten case bodies and assertions are unchanged; only their constructor fixture supplies the same explicit prerequisite. Both adapters record this prerequisite. They prove their existing retry/account-scope behavior, while the new eleven-case fixture proves actual PocketBase generation discovery, cancellation and durable binding. Actual Apple framework, real server and system Share-sheet acceptance remain separate gates.

## App consumer after observed actual-store RED

Native execution of immutable `73f7eb9f0927bebaefb66b8d5ffcaf7b7db6f4c2` reached all 27 identities: the original sixteen controls and the guest control passed; exactly ten new generation cases failed. Receipt SHA-256 `4f733b052b3127a53ff53f4638f3ef42c3e301da3fceadd32d8b7eb4e42f0382`, execution proof `3186a7de55a6ee96e84f0caaff85506d91196424e991433920dd194398f3e37f`. The assertions remain unchanged.

The normally merged `bcfadbcec1a7062ef5ed7fb6229134e126689508` dependency supplies nullable durable queue bindings and `TaskStore.create/save(_:serverDatasetGeneration:)`. The consumer does not edit those producers. Both app initializers require a final `serverGeneration: @MainActor @Sendable (WatchAccountScope) async throws -> String` argument; GSDApp owns the provider and its exact-token fence.

Personal-account ingestion refuses missing/invalid or noncurrent server generations while retaining the capture. Guest ingestion remains local and makes no generation request. Existing already-applied/terminal capture replay is a no-write acknowledgement. After the awaited generation read, ingestion checks canonical live/terminal rows again, preserving any intervening manual edit. A new creation queues its original server authority through the TaskStore API. Pushed captures are also checked before ingest.

Optional title enrichment retains the original authority. After its URL response, it reacquires the origin lease, verifies the server generation and only then reads the canonical row. It saves through the same bound queue API; missing authority, discovery failure, reset, cancellation or a newer manual title leaves the row unchanged. No timestamp alone grants authority or overwrites a canonical edit.

This is source preparation following meaningful native RED. GREEN, complete Core discovery/execution, actual extension/framework build and final system-surface acceptance are owned by the native runner and must be recorded separately.
