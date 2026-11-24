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
