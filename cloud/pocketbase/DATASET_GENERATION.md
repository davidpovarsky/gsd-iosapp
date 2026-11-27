# Dataset generation and atomic reset

## Accepted scope

The integration owner approved this contract on 2026-11-27 before implementation.
The change is limited to the GSD PocketBase service and its existing native REST
proxy. Client integration belongs to the GSD app owner. Production deployment and
final acceptance remain separate gates.

An old Share capture can outlive its local process or HTTP timeout. The server
must order its task insert against dataset reset and account deletion. Existing
accounts and headerless clients remain supported. No native JWT or OAuth-wide
revocation change is included.

## Wire contract

Authenticated `GET /api/gsd/dataset` returns `{"generation":"0"}` for an existing
account with no reset history, or its current opaque generation.

Authenticated `POST /api/gsd/dataset/reset` accepts exactly:

```json
{"expected_generation":"0","request_id":"one-stable-reset-id"}
```

Both values are nonempty strings of at most 128 UTF-8 bytes, preserved exactly.
ASCII control characters and DEL are rejected. A successful reset
returns the stable receipt:

```json
{"generation":"new-opaque-generation","request_id":"one-stable-reset-id","deleted_tasks":3,"tombstoned_library":2}
```

The reset, generation rotation and receipt commit in one transaction. An exact
retry returns the original receipt without another erase. Reusing a request ID
with a different expected generation returns HTTP 409 with the PocketBase error
message `request_id_conflict`. A new request ID with a stale expected generation
returns HTTP 409 with message `dataset_generation_mismatch`. Errors retain the
PocketBase `status`, `message`, and `data` envelope.

Task creation may supply `X-GSD-Dataset-Generation`. When present, it must match
the current generation in the same transaction that checks the current account,
validates the task and inserts it. A mismatch returns 409 and inserts nothing.
All task creates, including legacy headerless creates, check that their owner
still exists inside that transaction. Headerless clients keep their original
meaning; they do not acquire a stale-dataset guarantee merely by upgrading the
server.

Reset deletes the account's active tasks and tombstones its nondeleted archive,
trash and saved-view library rows with empty payloads and strictly increasing
client timestamps. Already-deleted library metadata and unrelated accounts are
preserved. Account deletion cascades the new private generation and receipt
records together with existing account data.

## Client obligations

- Capture generation once for a Share operation and retain it across retries.
- After an awaited generation lookup, recheck cancellation and the unchanged
  local account/dataset scope before posting.
- Never stamp an old queued capture with a newer generation or retry it without
  the header after 409. Hold it in its original scope.
- Keep reset request ID and expected generation fixed across ambiguous retries.
- Clear local data and pending writes only after the atomic reset ACK.
- Local sign-out and OAuth revocation remain distinct from dataset reset and
  account deletion; this protocol does not claim to revoke every native JWT.

## Verification

`test_dataset_generation.py` runs the exact existing PocketBase binary against a
new empty database and the real native gateway on ephemeral loopback ports. Its
fixture-only hook pauses task creation after relation validation and before the
insert. No production database, credential, process or listener is used.

The original baseline must first reproduce delayed insert after an erase
snapshot and an orphan after account deletion. Green acceptance must then prove
atomic reset ordering, stale-generation rejection, account deletion ordering,
stable idempotent receipts, fingerprint conflicts, cross-account isolation,
legacy behavior, library timestamp semantics and forwarding through the gateway.
RED originals, every failed attempt and GREEN originals remain separate immutable
evidence. Fixture hook and bootstrap files are generated only in the disposable
runtime and must never be deployed as product hooks.

The isolated candidate passed 56 real PocketBase/gateway checks and all 27 existing
gateway regression tests. Exact file hashes and immutable receipt locations are
recorded in `dataset-generation-validation-20261127.json`. Deployment acceptance
and native Share-sheet acceptance remain separate gates.
