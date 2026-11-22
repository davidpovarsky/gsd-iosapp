# GSD × Hanlin Agent SDK — integration record

Date: 2026-11-22
Working branch: feat/hanlin-agent-api-20261122
Upstream GSD: https://github.com/vscarpenter/gsd-iosapp @ fe35879146b7
Owner Hanlin source: https://github.com/davidpovarsky/hanlin-ai
Hanlin source checkout: codex/hanlin-agy-integration-20261122 @ a8edb565

## Scope and provenance

- GSD's existing GRDB TaskStore remains the only mutation path.
- Vendor/HanlinAgentSDK and Vendor/HanlinPlatform were copied from the
  above existing Hanlin source checkout, with original license/notice files intact.
- Both packages use local SwiftPM package dependencies. The upstream
  swift-ai-sdk pinned by the Hanlin SDK is
  e7bf34111e603ca977becd007dd4e5bb109af857.
- The new product is a separate SwiftPM package at Packages/GSDHanlinAgent;
  GSD's Xcode app target links it directly.
- HanlinAgentSDK requires iOS 27.0; GSD project minimum changed from 26 to 27.

## Native assistant

An AI entry button on GSD's main interface presents a native SwiftUI sheet
with streamed Hanlin responses, tool activity, provider configuration,
and human approvals. Provider credentials are stored in the device Keychain.
GSD's tasks remain offline-first. All writes route to original TaskStore,
preserving reminder/sync/recurrence semantics.

The AI engine uses the existing HanlinAgentSDK:
- HanlinAgentSession + HanlinAISDKAgentEngine (streaming and tool calls)
- HanlinHostIntegration (business service adapter)
- HanlinHostDispatcher (catalog, session freshness, idempotency)
- HanlinHostSchemaValidation (real JSON Schema validation)
- HanlinPrivateConversationStore (private app-local history)

No hard-coded API key, implicit agent grant, or second task database.
Cloud providers still require their own credentials. This is not
ChatGPT account sign-in; it is a model API integration.

## Tool operations (22)

Read: list_tasks, get_task, get_dashboard, list_tags, list_smart_views,
list_saved_tasks, list_archived_tasks, list_trashed_tasks.

Write (human approval required):
create_task, update_task, set_completed, delete_task, add_subtask,
toggle_subtask, add_dependency, remove_dependency, bulk_complete,
bulk_add_tags, bulk_move, set_focus, start_timer, stop_timer.

Read responses are machine-readable JSON. This stage does not yet
implement a public internet REST/MCP server; no unauthenticated remote
write channel is exposed. Remote ChatGPT access would require a separate
authenticated MCP bridge with user authorization and audit evidence.

## Safety

1. Only named model-visible tool aliases and schema-declared arguments.
2. Real JSON Schema validated before invoking the original TaskStore.
3. Provider approval is separate from interactive host approval.
4. Default write authorizer denies all writes.
5. Context changes invalidate old agent sessions.
6. Uncertain post-dispatch outcomes are not misrepresented as rollback.
7. API keys are secured in Keychain; not checked in or logged.
8. New tests cover catalog, deny-by-default, approved create/replay,
   and stale-context rejection.

## Evidence and pending acceptance

- Swift parse: passed for modified app/package sources.
- Swift package dump-package: passed for GSDHanlinAgent.
- Git diff --check: passed.
- Windows swift test initial attempt: timed out after 500 seconds while
  resolving external dependencies; NOT a passed test.
- CI workflow .github/workflows/gsd-hanlin-agent-ios.yml:
  executes package tests and compiles unsigned GSD arm64 iOS device.
  CI results remain pending until run completion.
- No IPA is claimed for GSD. Lorvex IPA is a separate sequential stage.

Do not mark GSD complete based only on sources or syntax checks.

## Native CI follow-up

- Apple run 45058469760: failed before tests; macos-26 lacks Xcode 27.
- Apple run 45058764054: Xcode 27 setup passed, Swift compile reached
  GSDHanlinHost. Three type errors were found: GSDModel.Task shadowed
  concurrency Task, and throwing nil-coalescing needed explicit try.
- Patched those findings on the GSD branch; next run checks package tests
  and iOS app build independently, retaining both logs.

- Apple run 45059134995: package test step failed on an XCTest non-Sendable
  async closure. Replaced test-only helper with actor-local inline do/catch.
  The redundant two-architecture simulator compilation was cancelled after
  preserving logs. Next run builds one unsigned arm64 iOS device target.
