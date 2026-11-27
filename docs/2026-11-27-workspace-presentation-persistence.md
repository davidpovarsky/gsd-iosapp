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
declare macOS 15, Swift 6.2, and an executable target with dependencies
TaskVisualizationKit, GSDSync, and GSDWire, and define
GSD_WORKSPACE_PRESENTATION_FIXTURE. Copy the four source files byte-for-byte;
retain their SHA256 hashes, the actual package pins, the compile log, and output.

Required environment:

- GSD_WORKSPACE_PRESENTATION_FIXTURE_ALLOWED=1
- Optional GSD_WORKSPACE_PRESENTATION_FIXTURE_CASE selects one exact name below.
  An unknown selector fails; no selector runs all eight.

The eight exact checks are:

1. fresh_store_restores_hidden_lanes_and_timeline
2. canonical_root_scopes_remain_distinct
3. guest_and_accounts_remain_isolated
4. unresolved_same_account_rejects_old_binding
5. cross_account_and_root_retarget_reject_old_binding
6. same_scope_views_share_latest_state
7. invalid_identity_and_viewport_fail_closed
8. session_resolution_holds_identity_until_apply

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
GREEN must run all eight against the new immutable candidate. The sole native
acceptance owner executes these jobs; do not duplicate Core1333 or Agent39.

## Native touch and cold relaunch gate

The default XCTest branch will define:

GSDWorkspacePresentationPersistenceUITests/testBoardCollapseAndTimelineZoomPersistAcrossNavigationAndRelaunch

It is a supplemental gate, intended once for each phone/tablet and English/Hebrew
configuration. It must use an ordinary fresh owned simulator without --demo flags,
because HarnessLaunch intentionally isolates and clears demo preferences.

The final native receipt and checkpoint contract are being completed with the
one native execution owner. No native UI PASS, physical-device acceptance,
personal account grant, or release acceptance is claimed by this source checkpoint.
