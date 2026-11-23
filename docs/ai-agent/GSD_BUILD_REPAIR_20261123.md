# GSD Hanlin MCP build repair — 2026-11-23

## Scope and current checkpoint

Finish the requested GSD iPad + Hanlin SDK + ChatGPT MCP delivery. Application
source remains d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca on
feat/hanlin-agent-api-20261122. Recovery wiring is on
fix/gsd-simulator-install-20261123. Lorvex remains outside this repair.

| Gate | Recorded result |
| --- | --- |
| Source native run | [45113033128](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128) finished **failure** only at simulator smoke; its compilation, tests and artifact preservation passed |
| Recovery run | [45119548923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45119548923), **success**, on 22555c2f8ad8aebe4d7a5935eb9976246ade3fe9; both simulator families and combined acceptance passed |
| Public OAuth/MCP | [45110816923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45110816923) passed three Node tests and twelve external checkpoints |
| Artifact acceptance | Aggregate native/IPA validator passed; both screenshots were separately reviewed for launch/onboarding |
| Prerelease | [Published prerelease](https://github.com/davidpovarsky/gsd-iosapp/releases/tag/gsd-hanlin-mcp-ipad-20261123-build47), verified release 455067425, tag gsd-hanlin-mcp-ipad-20261123-build47 |
| Physical iPad, personal ChatGPT pairing, model inference | Not verified |

Queued attempts 45106355079 and 45111695893 were cancelled before acquiring a runner
or executing a step. The workflow/ref concurrency key retains
cancel-in-progress: false. The recovery branch is outside the native push filter;
the current run was explicitly dispatched with mode=simulator_recovery. Default
full acceptance is unchanged, and no skip-CI markers were used.

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

## Source application build and actual exported files

[Source run 45113033128](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128),
attempt 1, on d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca passed:

- Seven Hanlin tests, three Node tests and three packaging tests.
- XcodeGen project generation and preservation of the actual generated inputs.
- ARM64 device compilation, both unsigned IPA exports and the IPA upload.
- Universal simulator compilation, simulator app archive and artifact upload.
- First-attempt boot of both modern compatible simulator devices.

Both simctl install invocations then exceeded the harness's 120-second deadline.
The launch, five-second liveness and screenshot stages were not reached in this
source run. That run remains red; it is not relabeled successful by reusing its
completed prerequisites.

Both actual IPA files were downloaded from the source run:

| Variant, version 4.0.1 build 47 | Bytes | SHA256 |
| --- | ---: | --- |
| Full unsigned | 28,024,600 | a0af2ad0e61aac8242da6c14557dc7e06a3b271a8c20063c8fac71b799cb8bdd |
| Sideload, no extensions, unsigned | 24,829,003 | f617ff67394bb2bd1e30604199079fa2cd98404524a253aabb7c9eeb9a09324e |

Main and nested bundle identifiers and versions were checked and were consistent.
Independent aggregate validation passed for both IPA files: ZIP CRC, ARM64 Mach-O
iOS device platform, version/build/minimum OS, bundle relationships and manifest
hashes. All 41 retained sideload entries, including the main executable, match the
full archive byte-for-byte; the sideload archive has no nested app bundles.
The validation record is GSD-IPA-validation-recovered-45119548923.json.
Both IPA files remain unsigned.

## Recovery implementation and evidence boundaries

The smoke harness now directs stdout/stderr to temporary files and waits for the
direct child process. This removes dependence on EOF from a pipe that a descendant
could keep open. Installation gets one 300-second attempt. Bounded failure
diagnostics cannot satisfy the success checks or trigger an installation retry.
Both normal app launches, positive PIDs, five-second liveness and PNG screenshots
remain mandatory.

A synthetic process experiment reproduced an old capture-output false timeout
when a descendant inherited the streams; the revised direct wait completed in
about 0.08 seconds. Separate cases preserved a nonzero exit 7 and a genuine timeout.
These checks validate the harness behavior. They do not establish that inherited
pipes caused the actual simctl timeouts.

Recovery run 45119548923 uses the exact compiled GSD-Simulator.zip from source
run 45113033128. Before launching it, the job requires:

- Pinned repository, source run, attempt 1, SHA, required successful steps and sole smoke failure.
- The three source artifact identities, sizes and SHA256 digests.
- An unchanged protected source tree, including all application/build inputs.
- Byte equality of all nine actual generated project, scheme and plist files.
- The expected simulator app identity, ARM64 architecture, iOS 27 minimum and both supported device families.

The actual generated-project artifact was separately verified against all nine
d44649ed Git blobs. The generated project.pbxproj SHA256 is
8b959df9cfc64bcef95df924b2cc7c9fe972907080cc8aee49765235df345b83.

The recovery completed successfully on 2026-11-23 at 06:30:48 UTC, including both
families, final receipt validation and evidence upload. The separately downloaded
aggregate validator also passed. The receipt preserves
compiledCodeSHA=d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca separately from
harnessSHA=22555c2f8ad8aebe4d7a5935eb9976246ade3fe9 and retains the original source
run's failed overall conclusion.

| Recovery device | Boot outcome | Install outcome | Launched PID |
| --- | --- | --- | ---: |
| iPhone | First bootstatus timed out; second attempt passed | One attempt, exit 0, 83.9 seconds | 14583 |
| iPad | First bootstatus timed out; second attempt passed | One attempt, exit 0, 111.3 seconds | 18122 |

Both normal launches passed five-second liveness and PNG checks. The assistant separately
viewed the actual 1206×2622 iPhone and 2064×2752 iPad images: both render GSD's
first-run onboarding with title, icon, text, page dots and legible Skip/Next
controls in bounds; neither is blank or shows an error. The automated validator
deliberately does not claim visual review; this paragraph records the subsequent
assistant visual inspection. Coverage is launch/onboarding only, without a
navigation, task-editing, personal MCP or provider-inference claim.

## Historical simulator evidence

Earlier run 45101502774 on b5c78c3dc86617b2a006799eeefd0dcb4a5d6986 compiled the app,
exported both unsigned IPA variants and showed normal onboarding on an iPhone
after launch. That screenshot was visually reviewed. Its iPad bootstatus wait
timed out after 300 seconds before installation. This is historical evidence only;
it does not satisfy the current recovery's two-family gate.

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

## Published prerelease and acceptance boundary

Technical delivery is complete: native recovery, independent aggregate artifact
validation, assistant visual inspection of launch/onboarding and verified publication.

- [Published prerelease](https://github.com/davidpovarsky/gsd-iosapp/releases/tag/gsd-hanlin-mcp-ipad-20261123-build47): gsd-hanlin-mcp-ipad-20261123-build47.
- Recommended sideload download: [GSD-Hanlin-iPad-4.0.1+47-SIDELOAD-NO-EXTENSIONS-UNSIGNED.ipa](https://github.com/davidpovarsky/gsd-iosapp/releases/download/gsd-hanlin-mcp-ipad-20261123-build47/GSD-Hanlin-iPad-4.0.1%2B47-SIDELOAD-NO-EXTENSIONS-UNSIGNED.ipa).
- Release 455067425 is published, not a draft, and marked as a prerelease.
- Published at 2026-11-23 06:39:48 UTC; asset verification completed at 06:39:49 UTC.
- The tag points to tested commit 22555c2f8ad8aebe4d7a5935eb9976246ade3fe9.
- All nine asset names, byte sizes and SHA256 digests were verified against the
  delivery records after publication.
- At 06:40:28 UTC the public release page and both IPA download HEAD requests
  returned HTTP 200 without authentication; IPA Content-Length matched the files.
- The source run's overall failure and the successful recovery remain separate receipts.

The recommended IPA is unsigned and omits nested extensions for the sideload
installation workflow. The release also provides the full unsigned IPA, manifests,
independent validation, checksums and both screenshots. Assistant visual inspection
has its own published [visual inspection record](https://github.com/davidpovarsky/gsd-iosapp/releases/download/gsd-hanlin-mcp-ipad-20261123-build47/GSD-simulator-visual-review-45119548923.json).

Asana native and IPA tasks are complete; the final project status is on track
(status record 1220777011360994). Physical iPad signing/installation, personal
ChatGPT OAuth pairing and provider inference remain unverified, and the physical
acceptance task remains open. Setup is documented in
[the handoff](GSD_REMOTE_MCP_HANDOFF_20261123.md).
