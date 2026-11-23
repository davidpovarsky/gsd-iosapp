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
The consolidated native acceptance is [run 45111695893](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45111695893)
on 383ff4833d0ae412d4cf37475ec70813d1cb28dc; it is awaiting a GitHub Xcode runner
at this checkpoint. Earlier queued run45106355079 was cancelled before any
step ran after almost an hour, once this current-code replacement was created.

The generated project.pbxproj SHA256 is
8b959df9cfc64bcef95df924b2cc7c9fe972907080cc8aee49765235df345b83.

## Verified public MCP service

[Public acceptance 45110816923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45110816923)
passed twelve checkpoints on code revision 383ff4833d0ae412d4cf37475ec70813d1cb28dc.
They cover canonical discovery, DCR, actual consent-form action, OAuth PKCE,
refresh rotation/replay rejection, a synthetic dashboard round trip and revocation.
The round trip carried 240,069 UTF-8 bytes of Hebrew text through public HTTPS.

A focused native/relay wire review found matching registration, polling and result
field contracts, but an inconsistent result size limit. Native allowed 1 MiB of
UTF-8 while the relay allowed only 128 KiB envelopes and 100,000 text characters.
The result route now accepts a bounded escaped-JSON envelope and enforces the
same decoded 1 MiB UTF-8 limit. Other endpoints retain their 128 KiB body cap.
Three Node tests passed, including exact-limit transport, a one-byte-over-limit
rejection and unchanged ordinary request limits.

Deployed server SHA256:
3f11aa7a1df46d205f129ea03fc78e52f89fd2a62fca24418de751a524888ac6.
The exact synthetic fixture and its client/auth records were removed afterwards.
Existing user devices were preserved; GSD and Lorvex both remained healthy.
This is live server/transport evidence, not personal iPad/ChatGPT pairing evidence.

## Remaining delivery

- Complete native acceptance with the corrected iPad initialization and inspect both screenshots.
- Verify exported IPA contents, bundle identifiers, version, architecture and manifest SHA256.
- Publish the verified build as a prerelease and update Asana.
- Physical iPad signing/installation and personal ChatGPT OAuth pairing remain user-device acceptance.
