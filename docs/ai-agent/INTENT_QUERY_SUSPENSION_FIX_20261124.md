# App Intent entity queries and suspended database access

Source baseline: `703fe74a763ed7c9293f739ccb3e799c54bfd375`.

## Finding and correction

`GSDTaskQuery.entities(for:)`, `suggestedEntities()`, and `entities(matching:)`
read through `TaskStore.fetchTask` or `fetchAllTasks` before an intent's `perform()`
can run. Those methods read the GRDB repository directly; they do not resume the
database. `AppDatabase.live()` uses a `DatabaseQueue` configured to observe
suspension notifications. The lifecycle suspends it while the app is backgrounded.
Consequently, entity resolution could fail before `CompleteTaskIntent.perform()`
entered its already-protected database window.

All three query entry points now use the existing
`withDatabaseResumedForIntent` helper. Matching, identifier order, saved/completed
filters, and the existing 20-item limit are unchanged. The store dependency is
resolved before entering the actor-isolated closure. There is no new lifecycle
framework, storage schema, or query behavior.

## Regression evidence and limits

`IntentQueryDatabaseSuspensionTests` adds two native tests using a real on-disk
GRDB `DatabaseQueue`, the production database configuration and repositories, and
`TaskStore`. Each fixture suspends only its own queue through the pinned GRDB
testable API, avoiding global notifications that would interrupt parallel tests.
The existing `BackgroundDatabaseWindow` supplies the injectable resume/suspend
window. The tests cover direct reads failing while suspended, persisted reads
succeeding inside the window without foreground observation, and restoration of
suspension after both success and a thrown error. They also check that the row
remains intact after resuming. Temporary files and fixture defaults are removed.

These tests exercise the concrete store/database lifecycle, not an out-of-process
App Intents or Siri/Shortcuts invocation. The app's query methods must also compile
in the final native build; actual Shortcuts UI acceptance is separate.

Verified on Oracle before handoff: both changed Swift files parse in Swift 6 mode;
`git diff --check` passes. The new native tests have not yet been executed at this
handoff, because the Mac execution slot is owned by the other app's validation.
The coordinated next native package run should include:

```sh
swift test --package-path GSDKit --filter IntentQueryDatabaseSuspensionTests
```

GRDB is the existing 7.12.0 pin at
`92a554cd0d5e8d67cb18993c6054e73fe42c066c`; no dependency is added or upgraded by
this patch.

## Lorvex parity

A separate source review against published Lorvex
`c9700aa8e797b6a6fa72655f50a4edde2f064cf8` confirmed its ten regular entity-query
classes already use `LorvexIntentFailure.rewording` and
`DatabaseSuspension.withBackgroundAccess`. Its Focus query is excluded from the
host framework and runs in the dedicated extension; widget queries map IDs or
snapshots. No corresponding Lorvex change is needed for this specific defect.

## Follow-up: shared lifecycle ownership and expiration

The query fix was published as `50cec1039fdf95b45c85e2cbfef474a18c52b056`.
Review of its existing helper exposed a separate race: its defer could suspend
again after the app became active. The original BackgroundDatabaseWindow already
rechecked foreground state, but each call independently suspended on exit, so
one overlapping call could interrupt another.

The follow-up makes the existing window own a shared reference count for the
production AppDatabase. Intent queries/actions, reminder actions, watch commands,
background refresh, and scene-phase transitions now use that same ownership.
Injected callbacks retain an isolated scope for tests; copying such a window
shares that fixture's scope. Scene backgrounding requests suspension until the
last owner exits. With no owner, it still suspends immediately. Foregrounding
resumes and clears the pending request. Catalyst's existing no-suspension guards
remain in place.

Background refresh holds an idempotent lease. Expiration cancels its task and
finishes only that lease; its completion callback runs once even if another
operation still needs the database. The worker checks cancellation and lease
validity before and after awaited phases, so a late continuation cannot report
success after expiration or begin the next phase. The post-sync auto-archive
hook, share inbox loop, and auto-archive loop also stop at safe domain-operation
boundaries. A successful share create is acknowledged even if cancellation
arrives during it; unprocessed captures stay on disk for retry.

This is cooperative cancellation and exactly-once completion, not interruption
or rollback of an already-started network request or database transaction. The
shared SyncEngine is not globally cancelled or redesigned.

Regression additions in this follow-up:

- Six additional real DatabaseQueue cases (eight total in
  IntentQueryDatabaseSuspensionTests) cover concurrent owners, foreground return,
  nested errors, scene-background deferral, expiration while another owner reads,
  and a late continuation that ignores cancellation.
- Two real-file ShareInbox cases cover cancellation retaining current/later
  captures, and successful-create acknowledgement without starting the next item.
- One controlled repository case proves an auto-archive fetch returning after
  cancellation cannot start an archive operation.
- Existing BackgroundDatabaseWindowTests and ReminderActionHandlerTests remain
  the focused compatibility checks for foreground/background and reminder behavior.

Swift 6 parse and whitespace checks pass before handoff. The existing window
source also typechecks in Swift 6 with only its two notification endpoints stubbed
on Oracle; this checks the helper's type/isolation shape, not native database or
BGTaskScheduler behavior. Final native execution and app compilation remain the
coordinator's next required gate. The focused package filter is:

```sh
swift test --package-path GSDKit --filter 'IntentQueryDatabaseSuspensionTests|BackgroundDatabaseWindowTests|ReminderActionHandlerTests|TaskStoreArchiveTests|ShareInboxTests'
```

These tests do not claim an actual OS-scheduled background refresh, Watch transport,
Siri invocation, or personal-account acceptance.
