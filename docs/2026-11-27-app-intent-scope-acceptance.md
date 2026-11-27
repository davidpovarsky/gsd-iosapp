# App Intent account and dataset acceptance

This followup starts at frozen Watch producer ac616e22330219c6b608740e80cda250a1214280 in an isolated worktree. It does not edit that producer's Watch, gate, wire, scheduler or notification consumer source.

The old GSDTaskEntity stores only the raw task ID. CompleteTaskIntent resolves that ID from the current store, so a selected or persisted A entity can complete an imported B row with the same ID. Create/Complete hold only the database lifecycle window; neither participates in the account/reset mutation drain. Query results can also retain A content across an awaited read and a changed account.

## Scope and acceptance

Preserve existing intent names, phrases, parameter descriptions, capture parsing and non-opening behavior. Bind entity identity to immutable account + dataset + task ID. Legacy raw identifiers require explicit re-selection. All canonical queries check their captured scope after reads. Current Create and selected Complete keep the existing shared gate ticket across the actual TaskStore operation.

The standalone eight-case probe compiles actual GSDAppIntents.swift, the real AppIntents framework, actual TaskStore/GRDB/outbox and BackgroundDatabaseWindow. Only UIKit applicationState is doubled. It registers only its isolated in-memory store and synthetic account provider with AppDependencyManager; no live credentials, network or user's database are used. It calls actual GSDTaskQuery methods and actual CreateTaskIntent/CompleteTaskIntent.perform(), not substitutes. Repository suspension retains actual GRDB results or pauses before actual upsert to expose the internal write/reset window.

Cases: legacy raw selection; A selection under B; previous dataset; suspended query read; suspended completion read; completion internal write/reset; creation internal write/reset; unresolved phase. Valid current account controls and unchanged capture shorthand are asserted within the cases. The original native acceptance tests and all Core test identities remain unchanged.

Prepare only on Oracle; native owner executes on Mac and binds exact clean GRDB pin plus all original source hashes before and after. This direct-method/framework test does not establish Siri or Shortcuts host locale, OS parameter serialization, microphone authorization or physical-device acceptance. Final iOS target compilation and system-surface acceptance remain required.

## Primary API references

- Apple, EntityIdentifier: https://developer.apple.com/documentation/appintents/entityidentifier — persistent entities use stable IDs unique within their entity type.
- Apple, AppDependencyManager: https://developer.apple.com/documentation/appintents/appdependencymanager — registers actual dependencies; standalone managers are also supported for tests.
- Apple, Creating your first app intent: https://developer.apple.com/documentation/appintents/creating-your-first-app-intent — register dependencies early and keep actions as wrappers over existing services.

These are API/design references, not evidence that this app passed runtime acceptance.
