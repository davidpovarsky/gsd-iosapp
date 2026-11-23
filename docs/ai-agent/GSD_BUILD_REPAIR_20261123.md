# GSD Hanlin MCP build repair — 2026-11-23

## Scope and cause

Continue the existing GSD iPad delivery on feat/hanlin-agent-api-20261122.
Native acceptance run [45094695724](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45094695724)
failed because the remote adapter referenced a different host's contract:
GSDHanlinArgs, objectIDs, and args.name. GSD uses
GSDHanlinArguments, taskIDs, and title/id.

## Repairs

- Route remote parameters and approval task IDs through the existing GSD contract.
- Give each foreground polling loop an identity so cancellation of an old loop
  cannot clear its replacement.
- Present remote write approval on the active main, assistant, or settings surface.
  Defer no-choice dismissal so an explicit Allow action resolves first.
- Preserve the /gsd prefix when the browser submits OAuth consent, and expose
  canonical issuer/protected-resource discovery through additive Funnel routes.
- Declare Hanlin's local package and iOS 27 floor in project.yml; use build 47.
  CI regenerates the project with XcodeGen before compiling.
- Correct the sideload manifest: omitted capabilities are widgets, the Share
  Extension, and Watch. Both IPA variants still need external signing.
- Add one simulator build, then normal launch/process/screenshot checks on
  disposable iPhone and iPad simulators.

## Evidence checkpoint

Native code/configuration revision: 538773c20873f5181b145f14c1807e3262d10202.

[Native acceptance 45100448844](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45100448844):
Xcode generation passed; seven Hanlin tests and three IPA packaging tests passed.
The device build then identified an oversized SwiftUI constraint expression in
ContentView. The root modifier chain has now been split into four small opaque
view boundaries with the same modifier order, state and callbacks. A new native
run is required to verify that change and produce IPA/simulator evidence.
Do not treat this checkpoint as a completed release receipt yet.

The generated GSD.xcodeproj/project.pbxproj was downloaded from that run's
GSD-Hanlin-Generated-Project-45100448844 artifact and copied without hand edits.
SHA256: 8b959df9cfc64bcef95df924b2cc7c9fe972907080cc8aee49765235df345b83.

[Public HTTPS acceptance 45100655342](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45100655342)
passed on febbc6bb03077915087ba8ec348e66c940b2573a.
Its twelve checkpoints cover canonical discovery, DCR, actual form action,
OAuth PKCE, refresh rotation/replay rejection, a synthetic MCP dashboard
round trip, and authorization revocation. This is a live server/transport test,
not an iPad or personal ChatGPT account pairing receipt.

After the run, the exact synthetic device/client and related authorization
records were removed; GSD state returned to zero test records. Existing devices
were preserved. Both GSD and the existing root service remained healthy.

## Remaining acceptance

- Run native acceptance after the ContentView decomposition and inspect its
  terminal result and screenshots. Previous run 45100448844 failed only the
  app build; SDK and packaging checks passed.
- Verify the exported IPA ZIP contents, identifiers, version, and SHA256.
- Publish the verified build as a prerelease and update Asana.
- Physical iPad signing/installation and personal ChatGPT OAuth pairing remain
  user-device acceptance. Keep that Asana task open until observed.
