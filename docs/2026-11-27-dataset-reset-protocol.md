# Dataset generation and atomic reset — GSD client

The final-product request authorizes this correction. The shared-server contract is the
integration owner's 2026-11-27 Asana comment 1220945990527264 on task1220883546668527.
This is a non-trivial persistence and wire change, with isolated file ownership.

## Behavior

An authenticated Share capture binds the server dataset generation before its task POST.
The generation is immutable across retries, survives its outbox/journal, and is carried
into any pending task upload or automatic title enrichment. A delayed discovery cannot
authorize work after cancellation, token replacement, account change, or local dataset
replacement. Failed discovery and stale-generation responses preserve the capture for
review; they never cause an unguarded upload. Anonymous local capture remains available.

Erase everywhere uses GET /api/gsd/dataset and POST /api/gsd/dataset/reset at the configured
PocketBase base. A persistent SQLite request records base URL, owner, expected generation
and a random request ID before the destructive POST. An ambiguous retry sends the same
identity. The validated acknowledgement is persisted before retiring the queue or
clearing local data. It remains available until local completion, preventing a replay
from deleting tasks created after the first server reset.

Automatic sync and realtime writes wait while an acknowledged or ambiguous reset is
unfinished. A different account cannot consume its request or acknowledgement. The
existing process lease and local mutation gate remain in force.

## Boundaries and ownership

GSD owns its client, queue metadata, reset journal and app wiring. The shared owner owns
server transactions, deployment, original SDK/Kit and plugin behavior. Native execution
has one owner on the Scaleway Mac. No bearer value is persisted in reset receipts or
evidence. No legacy headerless fallback is added to the new Share/reset route.

## Verification

Retain every original test identity and behavioral requirement. HTTP fixtures may learn
the new exact GET/reset/header protocol; no assertion is disabled to retain an old count.
New protocol tests are additive and the final catalog will report the actual total.
First preserve four regressions that call the existing eraseAllRemote API: atomic route
selection, discovery failure preserving the queue, reset failure preserving the queue,
and replay of a lost acknowledgement with the same request ID/generation. Execute their
actual behavioral RED before qualifying the successor. Then verify durable reopen,
per-account isolation, malformed/stale acknowledgements, exact-token cancellation,
queue generation persistence/inheritance and no headerless resend.

The successful c8 clean Apple build is a preserved checkpoint. Fresh final Core/Agent,
native UI, system-surface, personal and release acceptance follow the final integrated
source and actual server contract qualification.
