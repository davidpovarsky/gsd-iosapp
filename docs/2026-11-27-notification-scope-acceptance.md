# Scoped phone notification acceptance — 2026-11-27

## Problem and production boundary

A scheduled phone reminder originally carried only taskID. The app serializes reminder actions and may attach its TaskStore after a cold launch. A delayed action could therefore complete or snooze a different account's task when that account imported the same ID. The ordinary notification tap also persisted a generic task URL and fetched whichever row later occupied that ID.

The bounded host change carries the original GSDSnapshot.WatchAccountScope through action admission and a separate typed, persisted notification-open request. It uses the shared WatchMutationGate for the entire existing ReminderActionHandler call. Admission reads the current attachment and scope after the previous serial action has finished. A task-opening lease covers the canonical fetch, the post-await identity/dataset validation and the synchronous presentation callback.

Owned production files:

- App/Notifications/ReminderActionInbox.swift
- App/Notifications/NotificationResponder.swift
- App/ContentView.swift (only the scoped notification receive/consume path and presentation callback)

The Watch owner supplies WatchAccountScope, WatchMutationGate, canonical scope-provider wiring in GSDApp and scoped payloads in LiveReminderScheduler. The exact frozen metadata/gate API intake is ace1576d81004588aa1a25e02ad8ba9c65301ba7; qualification of the final combined host remains a separate gate.

No core ReminderActionHandler API or existing test changes are required. DeepLinkHandoff, external task URLs, Widgets, Spotlight and quick actions retain their existing routes. All new notification actions/taps with legacy, invalid, mismatched or unavailable scope are safely refused. The action's system completion is called once on rejection, missing task, handler error and successful completion. A valid pre-attachment action remains queued until store attachment, retaining its origin.

## Focused real-store fixture

Acceptance/NotificationScope/NotificationScopeAcceptance.swift is an isolated macOS executable source. It is outside the app and original test targets. It uses:

- the unchanged real GSDStore.TaskStore and ReminderActionHandler;
- real in-memory AppDatabase/GRDB task, archive, trash, smart-view and sync-queue repositories;
- the exact production WatchMutationGate and WatchAccountScope;
- fresh private UserDefaults suites and a fresh temporary gate-identity directory per case;
- a TaskRepository decorator that only suspends or fails a named read, forwarding every other operation to real GRDB;
- one explicitly identified foreground-only UIApplication stub, never a store, handler, database-window or gate stub.

The fixture passes its private defaults as both TaskStore defaults and feedbackDefaults. It does not read or write a personal account, real credential, app-group database, Watch payload, system notification or network connection.

The nine GREEN case identities, in order:

1. cold_action_retains_original_scope_until_attach
2. cross_account_action_cannot_mutate_same_id_task
3. matching_scope_actions_reach_canonical_store
4. legacy_invalid_and_paused_actions_complete_without_writes
5. queued_action_cannot_cross_account_dataset_replacement
6. missing_task_and_read_error_complete_once
7. persisted_open_refuses_cross_account_and_legacy_payloads
8. scoped_open_revalidates_after_suspended_fetch
9. valid_open_reads_canonical_task_without_mutation

Case 5 suspends the second fetch of the real Complete operation: the first belongs to ReminderActionHandler, the second is inside TaskStore.toggleComplete. It then queues another old-scope action and starts actual gate.replacingDataset around actual TaskStore.eraseAllData. The assertions require synchronous closed admission, no erase before the whole action finishes, no task resurrection, no old outbox write, a rotated dataset and refusal of a later replay.

Cases 7–9 decode the typed pending request from a fresh defaults handle, refuse a different account and a reset of the same account, protect a newer nonce from a late delivery, hold an actual canonical read during replacement, and check the synchronous callback and unchanged real task/outbox values. A fresh defaults handle proves persistence/decoding but is not claimed as an OS process relaunch.

## RED/GREEN input contract

The native acceptance owner alone compiles and executes this fixture. Do not duplicate Apple jobs.

Use SwiftPM on the existing Mac with macOS 26 minimum (matching GSDKit), the exact selected GSDKit dependency inputs and their existing resolved pins. No compiler-safety flags or original assertions may be relaxed.

Copy the exact complete acceptance file into two targets:

- UIKit target: define only GSD_NOTIFICATION_UIKIT_STUB. This compiles only the small UIApplication foreground surface at the top of the file.
- NotificationScopeAcceptance executable: copy the acceptance file, production ReminderActionInbox.swift and production WatchMutationGate.swift; depend on UIKit and the actual GSDKit products GSDModel, GSDStore and GSDSnapshot. Do not define the stub flag here.

The whole file, isolated stub branch bytes, copied production files, package input manifests and resolved dependencies must be separately hashed and retained. The GSDSnapshot product must contain the exact qualified scope producer source. No source rewriting is needed for the original UIKit import.

For the single behavioral RED, take the untouched original Inbox from c1b71d42885e4653616e92a623283760c87e92d4 and define GSD_NOTIFICATION_SCOPE_BASELINE for the executable target. This flag changes only the fixture's two call-site adapters to the original attach(store:) and deliver(action:taskID:done:) signatures and excludes new-API presentation cases that cannot exist on the baseline. It never changes the underlying store, action handler or selected assertion. Select exactly cross_account_action_cannot_mutate_same_id_task.

Expected RED assertion:

> An account A notification must not mutate account B's task with the same imported ID.

A compile failure, crash, timeout, different assertion failure or missing case does not qualify that RED. For GREEN, use the candidate Inbox and remove the baseline flag; execute all nine cases without a case filter.

Runtime admission:

- GSD_NOTIFICATION_SCOPE_FIXTURE_ALLOWED=1
- Optional exact case selector GSD_NOTIFICATION_SCOPE_FIXTURE_CASE (only for the explicit RED probe)

Each executed case prints NOTIFICATION_SCOPE_CHECK followed by a JSON object containing its exact id, passed and, on failure, error. The final NOTIFICATION_SCOPE_RESULT contains the complete ordered checks array, passed/failed counts and explicit realTaskStore, realGRDB, realReminderHandler, realOutbox, uiApplicationForegroundStub, personalAccounts=false and externalNetwork=false fields. Success requires every expected identity exactly once and zero failures; source inputs must remain unchanged before and after execution.

## Integration and limits

The final app build must compile the unchanged NotificationResponder delegate and the new ContentView hooks against the Watch owner's required attach(store:mutationGate:scopeProvider:) wiring. Native notification delivery, OS background lifetime and user-visible task presentation still belong to the app/native acceptance gate; this focused fixture does not claim to drive UNUserNotificationCenter or physical devices.

The new typed pending notification key is pendingScopedReminderTask.v1. It never adopts unscoped data. The previous shared pendingDeepLinkURL key had no provenance distinguishing a reminder from a Widget or user URL. Existing untyped URLs cannot be retrospectively classified as reminders while preserving the explicitly unchanged generic URL behavior; this fixture makes no such claim.

This note defines the evidence contract. Actual executions and their source/binary/log receipts are recorded by the native owner; source review alone is not a PASS.
