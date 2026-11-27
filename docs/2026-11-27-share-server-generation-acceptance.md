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
