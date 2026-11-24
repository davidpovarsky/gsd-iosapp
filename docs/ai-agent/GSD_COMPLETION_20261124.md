# GSD and Lorvex completion — 2026-11-24

User authorization: complete the remaining Asana work, update the original Hanlin SDK in both apps, fix shared defects, build and release using the Scaleway Mac, and report milestones. Existing accepted work and production data must be preserved.

## Scope
GSD owns its native adapter, cancellation lifecycle, localized AI failures, latest compatible canonical SDK pin and acceptance/release. Separate owners implement original SDK persistence/SIWC integration, Lorvex native parity and backend/plugin repairs.

## Acceptance
- Canonical new SDK includes current unified APIs and the existing supported ChatGPT plan flow; both apps pin the same full revision and installer digest.
- Cancelling a GSD send revokes that send before suspension. A late canceled result cannot finish, fail, approve tools or replace a newer send.
- Host storage failures and known AI status strings display through the host localization boundary.
- Existing Hebrew dashboard fix is retained.
- Native package and relevant iPhone/iPad acceptance run on Scaleway; signed TestFlight release uses the validated source and records Apple processing.
- Reuse equivalent prior cloud/package evidence; unobserved physical-device or personal grants remain explicitly unverified.

## Verification
A controlled conversation-store suspension drives a real HanlinAgentSession through cancel/restart and late completion. Canonical client/transport tests verify request shape and all advertised tools. Native acceptance checks changed UI and existing release requirements. Original SDK owner verifies system-alias storage and internal symlink rejection.

# GSD completion
- [x] Read current Asana records and immutable native/release evidence.
- [x] Isolate source at b19db20 (validated build48 + Hebrew fix and receipts).
- [ ] Merge latest compatible canonical Hanlin SDK pin.
- [ ] Repair cancellation ownership and localize AI failure display.
- [ ] Run focused native checks and required iPhone/iPad acceptance.
- [ ] Sign, export, upload and verify updated TestFlight build.
- [ ] Integrate backend milestone and record final evidence.

## Resuming From Here
Owner: /root. Canonical source: Oracle worktree gsd-final-20261124-root.
Native builds are serialized on Scaleway. SDK, Lorvex and Cloud have separate owners.

## Implementation notes

- Pin the published canonical SDK `bea35c3c2a435d1cc5f7ce93b08a649b104bc10f`, combining latest MiniApps and canonical SIWC with the verified Darwin private-store alias repair.
- Use the explicit `openai-chatgpt-plan` route and canonical `hanlin` tool namespace; ordinary API providers remain on their original routes.
- Each UI request owns its agent/host authorizer. Cancellation revokes ownership before awaiting invalidation; late old completions cannot replace new state. A new session keeps the same persisted conversation identity. SDK CAS/unresolved-write safeguards remain authoritative for an already dispatched tool.
- Preserve structured authentication/transport errors, localize host errors, and display bounded diagnostic identifiers without server response bodies.
- Integration gates: real host/SDK package tests, all four English/Hebrew phone/tablet profiles, signed-bundle validation, Apple processing verification. Supplemental watch/share/preconsent checks record their precise scope separately.

## Checks before native execution

- `git diff --check`: passed.
- Hebrew catalog audit: passed (App 1000 keys; widgets/share/watch catalogs and Siri phrases checked).
- Cloud MCP rollout verified by cloud lane: GSD source `98d298bb4ea3ebc2266e80b7e883c00573365a71`, 15/15 tests; live code matches source and unauthenticated write refusal carries reconnect metadata.

## Mac preparation and source freeze

The canonical installer and `--check`, both package dependency resolutions, and XcodeGen regeneration succeeded on the new Mac. Xcode 27.1 also resolved the actual generated app graph successfully with `-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution`. Both host and Xcode resolver files now pin the same three dependencies: GRDB 7.12.0, swift-ai-sdk 07431abccbfb151ca2dab67bca6cf86fcb2bd3b8, and swift-argument-parser 1.8.2.

The generated Xcode project, all five generated Info.plists and schemes are refreshed from `project.yml`. This incorporates the existing source-defined English/Hebrew localization settings and the new supplemental tests; no generated project was hand-edited. The native and signed CI commands now retain the verified resolver versions. Xcode 27.1 is used for compilation and Xcode 27.0 for simulator execution because the installed CoreSimulator service is compatible with the latter; system `xcode-select` remains unchanged.
