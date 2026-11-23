# GSD × Hanlin Agent SDK — integration record

Initial integration: 2026-11-22; updated checkpoint: 2026-11-23
Application branch: feat/hanlin-agent-api-20261122
Recovery branch: fix/gsd-simulator-install-20261123
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

## Current build evidence

[Source native run 45113033128](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128)
on d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca completed with overall failure solely in
simulator smoke. Seven Hanlin tests, three Node tests and three packaging tests
passed. Device compilation, both unsigned IPA exports/uploads, universal simulator
compilation and simulator archive/upload all passed.

Both modern simulator devices booted on the first attempt. Both simctl install
invocations then hit the 120-second harness deadline; normal launch, liveness and
screenshots were not established by that run.

The actual downloaded full IPA is 28,024,600 bytes, SHA256
a0af2ad0e61aac8242da6c14557dc7e06a3b271a8c20063c8fac71b799cb8bdd.
The no-extensions IPA is 24,829,003 bytes, SHA256
f617ff67394bb2bd1e30604199079fa2cd98404524a253aabb7c9eeb9a09324e.
Observed bundle identifiers and versions, including nested bundles, are consistent.
Independent ZIP CRC, ARM64 Mach-O iOS-device-platform, minimum-OS, bundle/version
and manifest-hash checks have passed for both archives. All 41 retained sideload
entries match the full archive. The aggregate validation record is
GSD-IPA-validation-recovered-45119548923.json. Both archives remain unsigned.

## Successful recovery and reviewed artifacts

[Recovery run 45119548923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45119548923)
completed successfully on 22555c2f8ad8aebe4d7a5935eb9976246ade3fe9 at 06:30:48 UTC
on 2026-11-23, including finalization and evidence upload. It reused the exact simulator
binary from the original source run after repository/run/attempt/step identity,
artifact digest, protected-source-tree and all nine generated-input checks.
Application inputs remain unchanged. Default full acceptance remains available
and unchanged; this branch uses explicitly selected recovery mode.

The corrected harness uses temporary files for stdout/stderr and waits for the
direct child, with one 300-second installation attempt and bounded diagnostics.
Synthetic checks reproduced the previous pipe-EOF false timeout, observed a
successful direct wait in about 0.08 seconds, preserved exit 7 and preserved a real
timeout. These results are not proof of the cause of the observed simctl failure.

Both current normal device installs, launches, PIDs, five-second liveness checks
and PNG screenshots passed. Each device's first bootstatus wait timed out and its
second boot attempt passed. Installations ran once: iPhone 83.9 seconds/PID 14583 and
iPad 111.3 seconds/PID 18122, both exit 0. The separately downloaded aggregate validator
confirmed the actual successful recovery run and combined receipt while retaining
the original run's failure. Compiled code remains
d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca; the harness revision is 22555c2f above.

The assistant separately viewed both current screenshots. They show GSD's normal first-run
onboarding, with title/icon/text, page dots and legible Skip/Next controls within
bounds, without a blank/error view. This confirms launch/onboarding only; navigation,
task editing and personal MCP interaction have not been demonstrated.

## Published prerelease and remaining personal acceptance

[Published prerelease](https://github.com/davidpovarsky/gsd-iosapp/releases/tag/gsd-hanlin-mcp-ipad-20261123-build47) (gsd-hanlin-mcp-ipad-20261123-build47) is published and verified. Release 455067425 is not a draft;
it is a prerelease pointing to tested commit 22555c2f8ad8aebe4d7a5935eb9976246ade3fe9. Publication occurred at
2026-11-23 06:39:48 UTC; all nine asset names, sizes and SHA256 digests were verified
at 06:39:49 UTC. Public release-page and both IPA HEAD checks returned HTTP 200
without authentication at 06:40:28 UTC, with matching IPA Content-Length.

Recommended sideload asset: [GSD-Hanlin-iPad-4.0.1+47-SIDELOAD-NO-EXTENSIONS-UNSIGNED.ipa](https://github.com/davidpovarsky/gsd-iosapp/releases/download/gsd-hanlin-mcp-ipad-20261123-build47/GSD-Hanlin-iPad-4.0.1%2B47-SIDELOAD-NO-EXTENSIONS-UNSIGNED.ipa).
The full unsigned IPA and all verification records are available on the release.
The separately published [visual inspection record](https://github.com/davidpovarsky/gsd-iosapp/releases/download/gsd-hanlin-mcp-ipad-20261123-build47/GSD-simulator-visual-review-45119548923.json) records assistant
inspection of the current iPhone/iPad onboarding screenshots.

Technical delivery is complete; Asana native and IPA tasks are complete. Both IPA
variants remain unsigned. Physical iPad signing/installation, personal ChatGPT
OAuth pairing and provider inference remain unverified; the physical-acceptance
task remains open. Follow [the handoff](GSD_REMOTE_MCP_HANDOFF_20261123.md), including
cancelling auto-opened Model settings before opening MCP.

## Historical intermediate native evidence

[Run 45101502774](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45101502774)
compiled the app and both IPA variants and showed normal GSD onboarding on iPhone.
Its iPad bootstatus timed out after 300 seconds before installation. That historical
screenshot does not satisfy the current two-family recovery gate.

Queued attempts 45106355079 and 45111695893 were cancelled before any runner or
step. The workflow/ref concurrency key retains cancel-in-progress: false.

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
