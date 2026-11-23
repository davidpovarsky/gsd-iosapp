# GSD Task Manager × Hanlin × ChatGPT Remote MCP

Updated: 2026-11-23
Original GSD source: https://github.com/vscarpenter/gsd-iosapp at fe35879146b7
Fork/branch: https://github.com/davidpovarsky/gsd-iosapp/tree/feat/hanlin-agent-api-20261122
Hanlin SDK: the existing Vendor/HanlinAgentSDK and Vendor/HanlinPlatform.

## Delivery checkpoint

| Component | Evidence and limit |
| --- | --- |
| Native acceptance continuation | [Run 45113033128](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128) is queued at this checkpoint; current success is not yet verified |
| GSD device build and IPA export | [Run 45101502774](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45101502774) compiled the ARM64 app and generated both unsigned IPA variants |
| Simulator execution | The same earlier run compiled both families and showed normal GSD onboarding on iPhone; iPad boot timed out before installation |
| Public OAuth/MCP | [Run 45110816923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45110816923) passed three Node tests and twelve external checkpoints |
| Personal device and account | Physical installation, personal ChatGPT OAuth pairing and provider inference remain unverified |

The modern compatible-device selection and one pre-install boot recovery are
awaiting the current native run. Earlier queued runs 45106355079 and 45111695893 were
cancelled before any runner or step. The workflow/ref concurrency key preserves
cancel-in-progress: false and separates native scheduling from the bridge workflow.

## Using the iPad build after artifact validation

The build is **GSD 4.0.1 (47)** for **iOS/iPadOS 27 or later**. Both IPA variants are
unsigned and require signing/provisioning before installation. For the sideload
workflow that changes the main bundle identifier, use the
SIDELOAD-NO-EXTENSIONS-UNSIGNED variant; it omits widgets, Share Extension and Watch.
The full unsigned variant retains those components and needs compatible signing.

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

- scripts/build_gsd_hanlin_ipad_ipa.sh generates both IPA variants with ZIP and
  SHA256 manifests; release delivery still requires validating the exported artifacts.
- Native CI preserves the IPA files and simulator binary before simulator smoke tests.
- Both simulator families must pass normal install, launch, liveness and screenshot checks.
  Only a pre-install boot timeout allows one recovery attempt.
- GSD and Lorvex have separate ports, services, device credentials, OAuth issuers
  and tool catalogs.
- Every remote write requires explicit approval on the iPad. The MCP surface exposes
  declared tools, not arbitrary SQL or executable commands.
- When GSD cannot service requests in the foreground, the relay cannot execute tasks
  against a separate server-side data copy or claim a completed native write.

Detailed failures, repairs and remaining acceptance:
[GSD build repair record](GSD_BUILD_REPAIR_20261123.md).
