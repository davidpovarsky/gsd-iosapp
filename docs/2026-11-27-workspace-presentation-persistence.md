# Workspace presentation persistence — host and native acceptance

## Scope and source ownership

GSD owns device-local Board collapse and Timeline viewport preferences. The shared
TaskVisualizationKit API was qualified at 4006fe14a6d8019edd0aceffad0dbe79dd7c91af;
the release integrator owns the final dependency pin and any qualified diagnostic
cleanup. Host changes do not edit the shared package, task database, sync outbox,
credentials, original acceptance cases, or original package tests.

The host namespace uses the live SessionStore account and the canonical explicit
root task IDs. A nil root request, an empty request, and a nonempty explicit request
remain distinct. Absent roots and collapsed lanes are retained. Inline, expanded,
and main workspace instances share the same repository for the same scope.
Observation invalidates a view's binding generation synchronously before identity
changes, including A -> unresolved -> A with no intervening suspension.

The narrow SessionStore phase fix marks resolution in progress before claiming the
pending confirmation. The existing async merge/fresh/cancel path settles before that
phase is cleared. This prevents a suspended eraseLocal operation from appearing
to the preference owner as a legitimate signed-out guest.

## Focused native host fixture

The conditional branch GSD_WORKSPACE_PRESENTATION_FIXTURE in
ScreenshotTests/GSDWorkspacePresentationPersistenceUITests.swift is an executable
fixture, compiled with these exact production files:

- App/Workspace/GSDTaskWorkspacePresentationStore.swift
- App/Auth/SessionStore.swift
- App/Auth/KeychainTokenStore.swift

Use the actual qualified TaskVisualizationKit and GSDKit packages as dependencies.
Do not truncate or recreate the shared DTO source. A small isolated package can
declare macOS 26 (the actual GSDKit minimum), Swift 6.2, and an executable target with dependencies
TaskVisualizationKit, GSDSync, and GSDWire, and define
GSD_WORKSPACE_PRESENTATION_FIXTURE. Copy the four source files byte-for-byte;
retain their SHA256 hashes, the actual package pins, the compile log, and output.

Required environment:

- GSD_WORKSPACE_PRESENTATION_FIXTURE_ALLOWED=1
- Optional GSD_WORKSPACE_PRESENTATION_FIXTURE_CASE selects one exact name below.
  An unknown selector fails; no selector runs all nine.

The nine exact checks are (the first eight remain unchanged):

1. fresh_store_restores_hidden_lanes_and_timeline
2. canonical_root_scopes_remain_distinct
3. guest_and_accounts_remain_isolated
4. unresolved_same_account_rejects_old_binding
5. cross_account_and_root_retarget_reject_old_binding
6. same_scope_views_share_latest_state
7. invalid_identity_and_viewport_fail_closed
8. session_resolution_holds_identity_until_apply
9. oauth_retry_cannot_interrupt_an_inflight_signin

Check 8 calls the actual SessionStore.signInWithEmail and resolveAccountSwitch
methods with the real AuthService, PocketBaseClient, AccountSwitch, and JWT parser.
Its ephemeral URLSession intercepts every request, accepts only the exact
fixture.invalid password-auth route, and fails unexpected requests. Tokens are
synthetic, memory-only, and never printed. A held eraseLocal closure proves both
the suspended success path and the existing failure path. No actual Keychain
method is called. The compile-only SyncCoordinator shape traps every method;
the real SessionStore receives coordinator:nil, so it cannot substitute for or
claim sync execution.

Preferences use a newly generated owned suite for each check. Only the three
standard account-default keys consulted by the real SessionStore are temporarily
set and restored in the explicitly owned fixture process. No entire standard
domain is erased. Fresh-store restoration is not a process-cold UI claim.

For a meaningful RED of the account phase defect, use the unchanged fixture and
host preference helper with SessionStore from 6904270c3dc40db877eb0b8d64646f0a7a9c0f8f,
select check 8, and require the synchronous inProgress assertion to fail after the
real pending-account route. A compile/transport failure is not this RED.
GREEN must run all nine against the new immutable candidate. The sole native
acceptance owner executes these jobs; do not duplicate Core1333 or Agent39.


Check 9 holds the first real email sign-in response in a separate rejecting
URLProtocol and attempts OAuth concurrently. The second entry must leave the first
phase unresolved, start no transport or presenter, and preserve its original token
until the held response is released. Cleanup always releases and joins that first
login; only its exact response token/account may survive. Every URL is intercepted
and an unexpected OAuth discovery request fails locally before any presenter.

For its separate RED, keep the new fixture unchanged and use SessionStore from
56d73d8d290d63f20c7b9a6d92a88dbf7d0f7b2c (before the OAuth admission guard), selecting
oauth_retry_cannot_interrupt_an_inflight_signin. Require the precise assertion
`A second OAuth attempt must not end the first sign-in phase.` A build, transport,
or cleanup failure is not that RED. The existing eight checks and native UI branch
are preserved; the app change is the same synchronous !inProgress entry guard
already used by email login. No real OAuth browser is opened in either path.

## Native touch and cold relaunch gate

Exact selector:

GSDWorkspacePresentationPersistenceUITests/testBoardCollapseAndTimelineZoomPersistAcrossNavigationAndRelaunch

Run this supplemental case once for each phone/tablet and English/Hebrew
configuration. Use an ordinary fresh owned simulator without --demo flags,
because HarnessLaunch intentionally isolates and clears demo preferences. The case
creates three ordinary tasks through the canonical editor and sets their dates
through the original shared date editor. The middle task is edited after zoom;
its two outer neighbors retain the original full Timeline date domain.

Required environment:

- GSD_SYSTEM_SURFACE_FRESH_SIMULATOR=1
- GSD_SYSTEM_SURFACE_APP_SOURCE=<exact final app source SHA, 40 lowercase hex>
- GSD_SYSTEM_SURFACE_SIMULATOR_UDID=<actual owned simulator UUID>
- GSD_SYSTEM_SURFACE_ARTIFACTS=<absolute existing parent evidence directory>
- GSD_TEST_LANGUAGE=en or he
- GSD_WORKSPACE_PRESENTATION_DEVICE_FAMILY=phone or tablet

The test verifies actual idiom and app geometry (phone portrait, tablet landscape).
It compares SIMULATOR_UDID when exposed by the runner. It creates a fresh child
directory workspace-presentation-<family>-<language>; an existing child fails.
The mutable progress/final receipt is workspace-presentation-persistence.json.
Every PNG and raw AX text filename is unique and never replaced. Source, simulator,
locale, measured date bounds, zoom percentages, frames, task IDs/titles and the
read-only database snapshots remain in the receipt.

Exact ordered final checks array (all nine required, no omissions):

1. ordinaryTasksAndDatesCreated
2. boardCollapseSurvivesTabAndFilter
3. collapseLeavesDatabaseAndOutboxUnchanged
4. boardCollapseSurvivesColdRelaunch
5. nativePinchChangesZoomAndVisibleRange
6. earlierAndLaterShiftDatesWithoutChangingZoom
7. postZoomDateActionUpdatesCanonicalTask
8. dateMutationAndPresentationSurviveColdRelaunch
9. fitRestoresFullRange

The original Board collapse button must retain its real Expand label and a 44 pt
touch target after mode changes, an actual no-results search and filter clearing,
and ordinary process termination/relaunch. A genuine Timeline chart pinch at
1.5 scale must produce 140–160% and a narrower parsed rendered interval whose
ratio agrees with the percentage. Both Earlier and Later then move actual dates
without changing zoom or leaving the original task domain. The original Timeline
row and footer open the middle task's original date editor after zoom. Removing
that date is read back through the same task's Table and canonical editor, then
through a second actual cold relaunch. The original task IDs/titles, Board
collapse, Timeline percentage and center date must persist. Fit finally restores
100% and the full original date range. Minute-formatted range comparisons allow
at most 60 seconds per endpoint, not an arbitrary visual tolerance.

### Read-only database checkpoint protocol

The sole native runner watches the case's evidence child while XCTest runs.
Two request/acknowledgment pairs are required:

- database-before-collapse.request.json / database-before-collapse.ack.json
- database-after-collapse.request.json / database-after-collapse.ack.json

Each request contains:

- schemaVersion: 1
- phase: before-collapse or after-collapse
- nonce: a new UUID generated by the test
- sourceSHA and simulator: the exact contract values above
- taskIDs: the sorted three real task IDs observed through the canonical UI
- tables: ["tasks", "syncQueue", "deletedTasks", "archivedTasks"]
- readOnlyRequired: true

The runner must verify ownership/source/UDID/nonce and resolve that simulator's
actual GSD App Group container via simctl. Open the existing SQLite database in a
read-only transaction. Capture complete rows and all columns, including timestamps
and outbox payloads, from the four requested tables. Bind the table definitions
and column schema too. Retain the raw logical snapshot and hashes as evidence;
do not write, inject, normalize away fields, clear WAL, or mutate the database.
The exact source schema is GSDKit/Sources/GSDStore/Migrations.swift: tasks,
syncQueue, deletedTasks, archivedTasks. The outbox is syncQueue.

Write each acknowledgment atomically only after its actual snapshot is complete:

- schemaVersion: 1
- phase, nonce, sourceSHA, simulator: identical to the current request
- captureComplete: true
- readOnly: true
- taskIDs: sorted IDs actually present in the entire tasks table; must equal
  the three UI-observed IDs
- schemaSHA256: SHA256 of the captured table/column definitions
- taskRowsSHA256: SHA256 of canonical complete tasks rows
- outboxRowsSHA256: SHA256 of canonical complete syncQueue rows
- otherTaskRowsSHA256: SHA256 of canonical complete deletedTasks/archivedTasks rows

All hashes are 64 lowercase hex. Extra evidence paths or counts may be included.
The test waits at most 60 seconds per checkpoint and fails without a valid ack.
It requires every before/after digest to match exactly. The native controller
must independently retain and validate both actual snapshots; writing a matching
hash without reading the database does not satisfy this protocol.

## Acceptance limits

This is additive to the original Native13, Workspace4, Share2/all8, Agent31/Core1333,
and the separate Matrix, Network and Flow/Board supplements. The fixture proves
host account/root isolation and actual SessionStore phase behavior with synthetic
credentials. Native ordinary-data runs prove touch and process-cold preferences
only when their real receipts pass. Neither path claims a personal ChatGPT grant,
a physical-device action, live cloud authentication, or TestFlight availability.
