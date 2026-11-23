# GSD Hanlin MCP build repair — 2026-11-23

## Scope and current checkpoint

Finish the requested GSD iPad + Hanlin SDK + ChatGPT MCP delivery on
feat/hanlin-agent-api-20261122. The existing Lorvex deployment is outside this repair.

| Gate | Recorded result |
| --- | --- |
| Current native acceptance | [45113033128](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128), queued on d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca; no success claim |
| Public OAuth/MCP acceptance | [45110816923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45110816923), passed: three Node tests and twelve external checkpoints |
| Earlier device and simulator compilation | [45101502774](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45101502774), passed compilation and produced both IPA variants; overall run failed at pre-install iPad simulator boot |
| Physical iPad, personal ChatGPT pairing, model inference | Not yet verified |

The queued native attempts
[45106355079](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45106355079)
and [45111695893](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45111695893)
were cancelled before either acquired a runner or executed a step. They do not
supply application failure evidence. The native workflow now uses a concurrency
key scoped to both workflow and ref, retaining cancel-in-progress: false.
Run 45113033128 is the current continuation; do not dispatch a duplicate.

## Reproduced build causes and repairs

[Original native run 45094695724](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45094695724)
failed because the remote adapter referred to GSDHanlinArgs, objectIDs and args.name.
The GSD contract uses GSDHanlinArguments, taskIDs and title/id.

[First repair run 45100448844](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45100448844)
passed all seven SDK tests but exposed an oversized SwiftUI type-check expression.
ContentView now composes four opaque view boundaries while preserving modifier
order, state, callbacks and the account-switch guard.

The repair also:

- Gives foreground polling loops identities so a cancelled predecessor cannot clear its replacement.
- Presents remote write approval on the active main, assistant or settings surface.
- Preserves the public /gsd prefix in OAuth consent and canonical discovery.
- Declares the Hanlin package and iOS 27 minimum in project.yml; uses version 4.0.1, build 47.
- Regenerates the Xcode project with XcodeGen instead of editing generated output.
- Exports a full unsigned IPA and a compatibility IPA without widgets, Share Extension or Watch.

## Verified application build

Native run 45101502774 on b5c78c3dc86617b2a006799eeefd0dcb4a5d6986 passed:

- Xcode 27 project generation; all nine generated files matched the committed files byte for byte.
- Seven Hanlin tests, two local MCP tests and three packaging tests, with zero failures.
- ARM64 device compilation and generation of both unsigned IPA variants.
- Universal iPhone/iPad simulator compilation.
- Normal installation, launch, five-second process liveness and screenshot on iPhone.
  Visual review showed the normal GSD onboarding screen.

The overall run failed at iPad simulator initialization: create and boot succeeded,
but bootstatus timed out after 300 seconds before GSD was installed. Inventory-order
selection had picked an iPhone 11 and a fourth-generation iPad Pro. This is a
pre-install simulator failure, not an application crash receipt.

## Simulator correction awaiting native verification

The revised harness selects compatible modern devices deterministically from the
actual available inventory and requires a general iOS 27 runtime. It prints command
starts and elapsed time and preserves partial timeout output. One shutdown/reboot
is allowed only for a pre-install boot timeout. Installation, launch, liveness and
screenshot failures are never retried. Both iPhone and iPad must pass for acceptance.

IPA artifacts are saved immediately after the device build, with an explicit
always condition so a later simulator failure cannot discard built binaries.
The compiled simulator app is archived before launch for reproducible diagnosis.

The committed generated project.pbxproj SHA256 is
8b959df9cfc64bcef95df924b2cc7c9fe972907080cc8aee49765235df345b83.

## Verified public MCP service

Public acceptance 45110816923 passed three Node tests and twelve external checkpoints
on revision 383ff4833d0ae412d4cf37475ec70813d1cb28dc. External coverage includes canonical
discovery, DCR, the actual consent-form action, OAuth PKCE, refresh rotation and
replay rejection, a synthetic dashboard round trip and revocation.

The public HTTPS round trip carried 240,069 UTF-8 bytes of Hebrew text. A wire review
had found matching registration, polling and result fields, but inconsistent result
size limits: native allowed 1 MiB of UTF-8, while the relay allowed only a 128 KiB
envelope and 100,000 text characters. The result route now accepts a bounded
escaped-JSON envelope and enforces the same decoded 1 MiB UTF-8 limit. Other routes
retain their 128 KiB body cap. Regression coverage includes exact-limit transport,
one-byte-over-limit rejection and unchanged ordinary request limits.

The deployed bridge revision is 383ff4833d0ae412d4cf37475ec70813d1cb28dc.
Its server.mjs SHA256 is
3f11aa7a1df46d205f129ea03fc78e52f89fd2a62fca24418de751a524888ac6.

The exact synthetic fixture and its client/auth records were removed afterwards.
Existing user devices were preserved. GSD and Lorvex health endpoints both returned
HTTP 200. These receipts verify server and transport behavior; they do not prove
personal iPad/ChatGPT pairing or provider model inference.

## Remaining delivery

- Complete run 45113033128, record its actual terminal result and inspect both simulator screenshots.
- Validate exported IPA contents, bundle identifiers, version, architecture and manifest SHA256.
- Publish only the verified build as a prerelease and update Asana.
- Keep physical iPad signing/installation and personal ChatGPT OAuth pairing open until observed.

User setup and the separation between ChatGPT MCP and the in-app provider API are
documented in [the handoff](GSD_REMOTE_MCP_HANDOFF_20261123.md).
