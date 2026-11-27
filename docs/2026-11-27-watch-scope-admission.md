# Watch capture identity and account/dataset admission

## Product behavior

A Watch capture uses the optimistic row's exact opaque ID, pending- followed by its capture command UUID, through the existing TaskStore.create path. Validation, reminder defaults and create-outbox behavior remain intact. Replaying a capture preserves an existing canonical row. Dependent actions stay durable until capture acknowledgement; the four-second local Undo hold remains in force.

WatchCommand and WatchSnapshot add optional WatchAccountScope metadata: a verified account or explicit local installation plus a durable dataset UUID. Missing legacy metadata remains decodable but is never assigned to the next account. Unknown scope metadata is retained by the DTO and fails admission.

The phone requires an exact current account/dataset match and rechecks an observation generation after awaited reads. One required WatchMutationGate ticket spans the full database window and TaskStore operation, including its internal reads and writes. Observation invalidates synchronously before a deferred reread.

GSDApp constructs the gate before operations, then SessionStore and a canonical scope provider before Watch or notification attachment. The provider rejects pending/in-progress account transitions and verifies SessionStore's owner against the stored token owner. The notification scheduler receives that resolver once before the store starts.

## Dataset replacement

The atomic app-group file watch-dataset-identity.json contains only installation and dataset UUIDs. Harness launches use their scratch directory. An unavailable/unreadable identity fails Watch admission without overwriting unreadable data at initialization.

A confirmed replacement closes admission synchronously, drains admitted operations and writes a new dataset identity before any destructive body starts. SyncCoordinator.eraseEverywhere rotates before its first remote erase. SessionStore's local erase closure and Import Replace use the same boundary. Persistence failure prevents destructive work. A later remote/reset failure conservatively retains the new boundary and reports failure, preventing waiting old captures from resurrecting data.

The gate is an admission/drain barrier, not a general mutex between unrelated transition bodies. Only sign-in preparation and reset callers pause or replace. Admitted Watch/notification handlers only acquire and finish tickets; they never await their own barrier. Nested/overlapping holds cannot reopen admission early. Cancellation still drains admitted work before releasing a hold.

## Watch presentation and upgrade handling

Rows and drafts retain the action lease under which they were drawn. Account/dataset changes invalidate old callbacks, Undo and pending navigation. Only matching commands enter overlays, Today counts or transfers. Other commands remain in the durable outbox and appear as held counts without exposing their titles in the current account.

An observed scope change keeps an unqueued draft inside its open sheet and prevents submission. An explicit Resume action is possible if the original scope returns. Closing/canceling retains existing draft-cancellation behavior; no new process-termination persistence is claimed for a text-field draft.

Widgets refuse unscoped snapshots. Notifications carry a property-list-safe JSON origin; Watch notification mutations/details require a matching scope. Phone notification consumers come from the separately owned notification lane.

An offline Watch only learns a phone account change when a new context arrives. Phone admission stays authoritative during that gap. No host fixture proves physical transport.

An older phone may already have created a random-ID task for a capture. The new client never guesses by title. An unresolved legacy pending-UUID action stays unacknowledged instead of being falsely reported as applied. Unscoped old commands remain held and are not silently migrated. The 44-character stable ID fits the repository's declared text task_id field (maximum160, no UUID-only pattern); this is source-schema evidence, not a fresh live query.

## Acceptance and integration

- Stable-ID RED27: 6df6ae27650cf81d91959f0762c256f95d0563fe. Original17 plus Undo control passed; nine new faults failed.
- Stable-ID GREEN27: 3b2422fbc61a1650cbb390b2472b1d6c803b0b5b. Actual native27/27 passed.
- Scope RED18: d6836f05849e1597d2ad67801690af3f4c95c1e4. Actual native17 failures plus same-scope refresh control passed.
- Real-TaskStore RED8: ef91ebb0342a35780384db25f2222fecacc6b13a. Three intended reset/write failures reproduced; one unexpected identity-failure control is being diagnosed at fixture-only2e49364a1a392bd3025d29b4e06281fb96c63fea.
- Final scoped GREEN27/18/8 and full app/Watch framework builds are pending at this checkpoint.

The original27 Swift fixture is byte-identical. A test-only adapter supplies a verified synthetic guest prerequisite and callback origins, so scope refusal cannot mask its original storage-failure/Undo checks. Scope18 uses explicit wire metadata and retained origins. Gate8 uses actual TaskStore, GRDB task/outbox repositories and BackgroundDatabaseWindow; only UIKit application state and WatchConnectivity transport are doubled.

Normal integration must also include canonical SessionStore transition/OAuth guards, root's AuthService token fence and notification consumer bd61337dc1184aa4590db5628ab571e0c5368f61. No shared visualization library, Hanlin SDK or server source was edited. This lane adds no GSDKit @Test identities. Core and Agent suites must run against final integrated sources.
