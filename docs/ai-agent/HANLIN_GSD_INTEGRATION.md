# GSD × Hanlin Agent SDK — integration record

Initial integration: 2026-11-22; updated checkpoint: 2026-11-23
Working branch: feat/hanlin-agent-api-20261122
Upstream GSD: https://github.com/vscarpenter/gsd-iosapp @ fe35879146b7
Owner Hanlin source: https://github.com/davidpovarsky/hanlin-ai
Hanlin source checkout: codex/hanlin-agy-integration-20261122 @ a8edb565

## Scope and provenance

- GSD's existing GRDB TaskStore remains the only mutation path.
- Vendor/HanlinAgentSDK and Vendor/HanlinPlatform came from the existing Hanlin
  source checkout above, retaining the original license/notice files.
- Both packages use local SwiftPM package dependencies. The upstream swift-ai-sdk
  pinned by Hanlin is e7bf34111e603ca977becd007dd4e5bb109af857.
- Packages/GSDHanlinAgent is linked by the GSD Xcode app target.
- HanlinAgentSDK requires iOS 27.0. project.yml declares that deployment minimum
  and is the source of truth for the generated Xcode project.
- The current IPA configuration is version 4.0.1, build 47, unsigned.

## Native assistant

The main-screen AI button presents Hanlin AI with streamed responses, tool activity,
provider configuration, charts and human write approvals. Provider credentials
are stored in the device Keychain. GSD remains usable offline. Approved changes
use TaskStore and preserve its reminder, sync and recurrence semantics.

The engine uses the existing Hanlin components:

- HanlinAgentSession and HanlinAISDKAgentEngine for streaming and tool calls.
- HanlinHostIntegration for business-service adaptation.
- HanlinHostDispatcher for catalog, session freshness and idempotency.
- HanlinHostSchemaValidation for JSON Schema validation.
- HanlinPrivateConversationStore for private app-local history.

No API key is embedded in the source, and no second task database is created.
**Model** settings are the separate provider API configuration. They do not sign
the user into ChatGPT, and live provider inference has not yet been verified.

## Tool operations (22)

Read: list_tasks, get_task, get_dashboard, list_tags, list_smart_views,
list_saved_tasks, list_archived_tasks, list_trashed_tasks.

Write, with human approval: create_task, update_task, set_completed, delete_task,
add_subtask, toggle_subtask, add_dependency, remove_dependency, bulk_complete,
bulk_add_tags, bulk_move, set_focus, start_timer, stop_timer.

Results are machine-readable JSON. The dashboard renders real get_dashboard output
with Swift Charts and matrix/status selection.

## ChatGPT remote access added on 2026-11-23

The initial 2026-11-22 integration was local-only and had no public MCP bridge.
That historical limitation was superseded by the authenticated GSD remote bridge.

ChatGPT now has an implemented OAuth PKCE/DCR transport at
https://torah-social.tail0a6c7d.ts.net:10000/gsd/mcp.
GSD pairs with a short-lived code and polls outbound HTTPS while foregrounded.
Remote commands use the same declared tool catalog, schema validator and TaskStore
as the native assistant. Writes wait for approval on the active iPad surface.

The independent Oracle service listens on 127.0.0.1:8768. Its deployed bridge revision
is 383ff4833d0ae412d4cf37475ec70813d1cb28dc; server.mjs SHA256 is
3f11aa7a1df46d205f129ea03fc78e52f89fd2a62fca24418de751a524888ac6.

[Public acceptance 45110816923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45110816923)
passed three Node tests and twelve external checks, including OAuth consent,
refresh/replay protection, revocation and a 240,069-byte UTF-8 Hebrew result through
public HTTPS. The exact synthetic fixture and its auth records were removed.
GSD and Lorvex health endpoints both returned HTTP 200. This verifies the service
and transport, not personal ChatGPT pairing or a live provider model response.

## Safety

1. Only named tool aliases and schema-declared arguments are accepted.
2. JSON Schema is validated before invoking TaskStore.
3. Provider approval is separate from interactive device approval.
4. The default write authorizer denies changes.
5. Local context changes invalidate old agent sessions.
6. Uncertain post-dispatch results are not represented as rollback.
7. API credentials stay in Keychain, outside source and logs.
8. Tests cover the catalog, default denial, approved create/replay, stale contexts
   and the remote adapter.

## Current build evidence and pending acceptance

[Native run 45101502774](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45101502774)
passed all seven SDK tests, device compilation, generation of both unsigned IPA
variants, universal simulator compilation and normal iPhone launch. Visual review
showed GSD onboarding. The run failed at iPad bootstatus after 300 seconds, before
the app was installed.

Modern compatible simulator selection and one pre-install boot recovery are now
implemented. Both families still must pass; app installation, launch, liveness and
screenshot failures are not retried. Native continuation
[45113033128](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128)
on d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca is queued at this checkpoint.

Queued attempts 45106355079 and 45111695893 were cancelled before any runner or step.
The native workflow's concurrency key now includes workflow and ref and retains
cancel-in-progress: false. These scheduling changes do not establish a native pass.

Unsigned IPA generation has therefore been demonstrated; final current-run
acceptance, artifact validation and prerelease delivery remain pending. Physical
iPad signing/installation and personal ChatGPT OAuth pairing must be observed
separately. Follow [the current handoff](GSD_REMOTE_MCP_HANDOFF_20261123.md) for setup,
including cancelling auto-opened Model settings before opening MCP.

## Historical evidence — initial integration on 2026-11-22

- Swift source parsing, package manifest inspection and git diff --check passed.
- The first Windows swift test attempt timed out after 500 seconds during dependency
  resolution. It was not a passed test.
- At that initial checkpoint, native CI and GSD IPA generation were still pending.
  The later evidence above supersedes those present-tense limitations.
- Apple run 45058469760 failed before tests because its macos-26 runner lacked Xcode 27.
- Run 45058764054 reached GSDHanlinHost compilation and found the GSDModel.Task/
  concurrency Task collision and throwing nil-coalescing errors. Those were repaired.
- Run 45059134995 found a non-Sendable XCTest async closure. The test helper was
  replaced with actor-local inline do/catch. Its redundant simulator compilation
  was cancelled after logs were preserved.
- [Run 45060441724](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45060441724)
  subsequently passed the Hanlin package tests and unsigned ARM64 iOS compilation.

Do not mark personal end-to-end delivery complete from source, parsing, compilation
or synthetic server checks alone.
