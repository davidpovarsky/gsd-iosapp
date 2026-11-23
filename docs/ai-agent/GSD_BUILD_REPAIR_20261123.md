# GSD Hanlin MCP build repair — 2026-11-23

## Scope and causes

Continue the requested GSD iPad + Hanlin SDK + ChatGPT MCP delivery on
feat/hanlin-agent-api-20261122. The existing Lorvex deployment is outside this repair.

[Original native run 45094695724](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45094695724)
failed because the remote adapter used GSDHanlinArgs, objectIDs and args.name.
The existing GSD contract is GSDHanlinArguments, taskIDs and title/id.

[First repair run 45100448844](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45100448844)
passed the seven SDK tests but identified an oversized SwiftUI type-check expression.
ContentView now composes four small opaque view boundaries while preserving the
modifier order, state, callbacks and account-switch guard.

## Application and server repairs

- Map remote arguments and approval task IDs to the actual GSD contract.
- Give foreground polling loops identities so a cancelled predecessor cannot clear its replacement.
- Present remote write approval on the active main, assistant or settings surface.
- Preserve the public /gsd prefix in OAuth consent and canonical discovery.
- Declare the Hanlin package and iOS 27 minimum in project.yml; use version 4.0.1 build 47.
- Regenerate the Xcode project with XcodeGen rather than editing generated output.
- Provide a full unsigned IPA and a compatibility IPA without widgets, Share Extension or Watch.

## Verified application build

[Native run 45101502774](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45101502774)
on b5c78c3dc86617b2a006799eeefd0dcb4a5d6986 passed:

- Xcode 27 project generation; all nine generated files match the committed files byte for byte.
- Seven Hanlin tests, two local MCP tests and three packaging tests, with zero failures.
- ARM64 device compilation and generation of both unsigned IPA variants.
- Universal iPhone/iPad simulator compilation.
- Normal installation, launch, five-second process liveness and screenshot on iPhone.
  The screenshot was visually reviewed and shows the normal GSD onboarding screen.

The run failed only at iPad simulator initialization: create and boot succeeded,
but bootstatus timed out after 300 seconds before GSD was installed. The old
inventory-order selection picked an iPhone 11 and a fourth-generation iPad Pro.
The recorded iPad failure is not an application crash receipt.

## Simulator and artifact correction

The corrected harness selects compatible modern devices deterministically from
the actual available inventory, retaining the general iOS 27.2 runtime. It logs
command starts, elapsed time and partial timeout output. One shutdown/reboot is
allowed only for a pre-install boot timeout; installation, launch, liveness and
screenshot failures are never retried. Both device families must pass.

IPA artifacts are now saved immediately after the device build, using an explicit
always condition so a later simulator failure cannot discard built binaries.
The compiled simulator app is also archived before launch for reproducible diagnosis.
The corrected harness still requires a new native acceptance run.

The generated project.pbxproj SHA256 is
8b959df9cfc64bcef95df924b2cc7c9fe972907080cc8aee49765235df345b83.

## Verified public MCP service

[Public acceptance 45100655342](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45100655342)
passed twelve checkpoints on febbc6bb03077915087ba8ec348e66c940b2573a:
canonical discovery, DCR, actual consent-form action, OAuth PKCE, refresh rotation
and replay rejection, synthetic MCP dashboard round trip, and authorization revocation.
The exact synthetic fixture and its authorization records were removed afterwards.
Existing user devices were preserved, and both GSD and the root service stayed healthy.
This is live server/transport evidence; it is not personal iPad/ChatGPT pairing evidence.

## Remaining delivery

- Complete native acceptance with the corrected iPad initialization and inspect both screenshots.
- Verify exported IPA contents, bundle identifiers, version, architecture and manifest SHA256.
- Publish the verified build as a prerelease and update Asana.
- Physical iPad signing/installation and personal ChatGPT OAuth pairing remain user-device acceptance.
