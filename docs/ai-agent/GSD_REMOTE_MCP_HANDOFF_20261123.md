# GSD Task Manager × Hanlin × ChatGPT Remote MCP

Updated: 2026-11-23
Original GSD source: https://github.com/vscarpenter/gsd-iosapp at fe35879146b7
Application origin branch: https://github.com/davidpovarsky/gsd-iosapp/tree/feat/hanlin-agent-api-20261122
Delivery branch: https://github.com/davidpovarsky/gsd-iosapp/tree/fix/gsd-simulator-install-20261123
Hanlin SDK: the existing Vendor/HanlinAgentSDK and Vendor/HanlinPlatform.

## Delivery checkpoint

| Component | Evidence and limit |
| --- | --- |
| Application source | d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca; no application inputs changed for recovery |
| Device/tests/IPA/simulator build | [Source run 45113033128](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128) passed seven Hanlin, three Node and three packaging tests; compiled, exported and preserved both IPA variants and the simulator app |
| Original simulator smoke | Both modern devices booted on the first attempt; both install commands hit 120-second harness timeouts. Source run 45113033128 remains failed overall |
| Recovery acceptance | [Run 45119548923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45119548923) passed on harness revision 22555c2f8ad8aebe4d7a5935eb9976246ade3fe9, including both simulator families and final acceptance |
| Artifact and visual review | Independent IPA integrity/aggregate validation passed; both current onboarding screenshots were viewed and checked |
| Public OAuth/MCP | [Run 45110816923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45110816923) passed three Node tests and twelve external checkpoints |
| Delivery and personal use | [Published prerelease](https://github.com/davidpovarsky/gsd-iosapp/releases/tag/gsd-hanlin-mcp-ipad-20261123-build47), verified; physical installation, personal OAuth pairing and provider inference remain unverified |

Recovery branch: fix/gsd-simulator-install-20261123. Its explicit recovery mode
reuses the source simulator archive only after source, step, artifact digest,
protected-tree and nine generated-file checks. Default full CI remains unchanged.
Both normal app launches, five-second liveness checks and screenshots passed.
Each recovery device passed its second boot after an initial bootstatus timeout.
Installation passed once per device: iPhone 83.9 seconds/PID 14583; iPad 111.3 seconds/
PID 18122, both exit 0. The current screenshots were separately viewed and show
legible GSD first-run onboarding, including Skip/Next and page dots, with no blank
or error view. This covers launch/onboarding, not navigation, task manipulation
or personal MCP use. The earlier 45101502774 image remains historical evidence.

## Downloaded IPA checkpoint

The actual source-run downloads are:

| Variant | Bytes | SHA256 |
| --- | ---: | --- |
| Full unsigned | 28,024,600 | a0af2ad0e61aac8242da6c14557dc7e06a3b271a8c20063c8fac71b799cb8bdd |
| Sideload without extensions, unsigned | 24,829,003 | f617ff67394bb2bd1e30604199079fa2cd98404524a253aabb7c9eeb9a09324e |

The main/nested bundle identifiers and versions are consistent. Independent ZIP
CRC, ARM64 Mach-O device-platform, minimum-OS and manifest-hash checks passed for
both files. The 41 retained sideload entries match the full archive byte-for-byte.
The aggregate record is GSD-IPA-validation-recovered-45119548923.json. The archives
remain unsigned; physical installation is not established by these checks.

## Install the validated iPad build

The build is **GSD 4.0.1 (47)** for **iOS/iPadOS 27 or later**. Both IPA variants are
unsigned and require signing/provisioning before installation. For the sideload
workflow that changes the main bundle identifier, use the
SIDELOAD-NO-EXTENSIONS-UNSIGNED variant; it omits widgets, Share Extension and Watch.
The full unsigned variant retains those components and needs compatible signing.

Recommended download: [GSD-Hanlin-iPad-4.0.1+47-SIDELOAD-NO-EXTENSIONS-UNSIGNED.ipa](https://github.com/davidpovarsky/gsd-iosapp/releases/download/gsd-hanlin-mcp-ipad-20261123-build47/GSD-Hanlin-iPad-4.0.1%2B47-SIDELOAD-NO-EXTENSIONS-UNSIGNED.ipa).
[All release files and verification evidence](https://github.com/davidpovarsky/gsd-iosapp/releases/tag/gsd-hanlin-mcp-ipad-20261123-build47).

1. Open the installed GSD app and finish or dismiss its normal onboarding.
2. Tap the **AI** button to open **Hanlin AI**.
3. If **Hanlin model settings** opens automatically because no model is configured,
   tap **Cancel**. Provider API configuration is not required for ChatGPT MCP pairing.
4. Tap **MCP**. Keep the HTTPS relay address below, then choose
   **Pair this iPad with ChatGPT**.
5. Keep the displayed one-time pairing code private. In ChatGPT, connect the private
   GSD Tasks plugin or the custom MCP endpoint using OAuth. Enter the code on the
   GSD authorization page. The code expires after ten minutes.
6. Keep GSD in the foreground while ChatGPT uses its tools. Read requests execute
   against the device's current tasks; each write requires **Allow change** on the iPad.
7. Verify a read and one deliberately approved task change before calling personal
   end-to-end acceptance complete.

Use the owner's existing private GSD Tasks plugin. Its installation link is in
the private delivery message and project handoff. Creating that plugin does not
establish that the owner's ChatGPT account has completed authorization.

Relay base URL:

https://torah-social.tail0a6c7d.ts.net:10000/gsd

ChatGPT MCP endpoint:

https://torah-social.tail0a6c7d.ts.net:10000/gsd/mcp

**Model** settings configure the separate in-app Hanlin agent's provider endpoint,
model and API credential. That credential is stored in the device Keychain.
Connecting ChatGPT through MCP does not configure or verify provider inference.

## Components and data flow

- Oracle directory: /home/ubuntu/gsd-mcp-bridge.
- Independent gsd-mcp-bridge.service on loopback 127.0.0.1:8768, using Node 24.
- The existing Tailscale Funnel on port 10000 routes /gsd to this service.
  The Lorvex root URL and original service are preserved.
- OAuth PKCE/DCR and a one-time pairing code connect ChatGPT to the device.
  Access/refresh credentials are hashed on the relay; the device secret stays in Keychain.
- GSDRemoteBridgeState polls outbound HTTPS while foregrounded. Approval appears
  on the active main, assistant or settings surface.
- Remote calls enter GSDHanlinHost and the existing canonical TaskStore.
  The original reminder, sync and recurrence paths remain in use.
- GSDHanlinDashboard decodes the actual get_dashboard result and renders Swift Charts
  with interactive matrix/status selection.

Oracle holds pairing state and limited transient command queues, not another task
database. Reads and approved writes require the app to service the request.

## Server acceptance and deployed revision

The deployed bridge revision is 383ff4833d0ae412d4cf37475ec70813d1cb28dc.
The server.mjs SHA256 is
3f11aa7a1df46d205f129ea03fc78e52f89fd2a62fca24418de751a524888ac6.

Public acceptance 45110816923 passed canonical discovery, DCR, real consent-form
routing, OAuth PKCE, refresh rotation/replay rejection, a synthetic MCP round trip
and revocation. The round trip transported 240,069 UTF-8 bytes of Hebrew text.
Three Node tests also verify the decoded 1 MiB UTF-8 result boundary and rejection
above it; ordinary endpoint body limits remain 128 KiB.

The exact synthetic test device and its client/auth records were removed after
acceptance. Existing devices were preserved. Both GSD and Lorvex health endpoints
returned HTTP 200. These checks do not use the user's personal tasks or establish
physical iPad pairing.

## Validation and isolation

- scripts/build_gsd_hanlin_ipad_ipa.sh generated both IPA variants with manifests;
  independent validation of the actual downloaded archives passed.
- Native CI preserves the IPA files and simulator binary before simulator smoke tests.
- Both simulator families must pass normal installation, launch, five-second liveness
  and PNG screenshot checks. Each installation has one 300-second attempt; failure
  diagnostics do not retry it or replace acceptance.
- The corrected harness uses file-backed stdout/stderr and a direct-child wait.
  Synthetic timeout/exit-code checks passed, but do not prove the actual simctl cause.
- The successful recovery run and its verified combined receipt remain separate
  from the original source run's failed overall conclusion.
- GSD and Lorvex have separate ports, services, device credentials, OAuth issuers
  and tool catalogs.
- Every remote write requires explicit approval on the iPad. The MCP surface exposes
  declared tools, not arbitrary SQL or executable commands.
- When GSD cannot service requests in the foreground, the relay cannot execute tasks
  against a separate server-side data copy or claim a completed native write.

## Published release and remaining personal acceptance

[Published prerelease](https://github.com/davidpovarsky/gsd-iosapp/releases/tag/gsd-hanlin-mcp-ipad-20261123-build47) (gsd-hanlin-mcp-ipad-20261123-build47) was published at 2026-11-23 06:39:48 UTC as release 455067425,
not a draft, and verified at 06:39:49 UTC. The tag targets tested commit
22555c2f8ad8aebe4d7a5935eb9976246ade3fe9. All nine asset names, sizes and SHA256 digests match the delivery records.

At 06:40:28 UTC the public release page and both IPA download HEAD requests returned
HTTP 200 without authentication; the IPA Content-Length values matched the files.
Technical delivery is complete. The separate [visual inspection record](https://github.com/davidpovarsky/gsd-iosapp/releases/download/gsd-hanlin-mcp-ipad-20261123-build47/GSD-simulator-visual-review-45119548923.json)
documents assistant inspection of the current launch/onboarding screenshots.

Asana native and IPA delivery tasks are complete. Physical installation, personal
ChatGPT OAuth pairing and provider inference still require observation on the user's
device/account; the physical-acceptance task remains open. Detailed provenance:
[GSD build repair record](GSD_BUILD_REPAIR_20261123.md).
