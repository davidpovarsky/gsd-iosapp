# GSD Task Manager × Hanlin × ChatGPT Remote MCP

Date: 2026-11-23
Original GSD source: https://github.com/vscarpenter/gsd-iosapp at fe35879146b7
Fork/branch: https://github.com/davidpovarsky/gsd-iosapp/tree/feat/hanlin-agent-api-20261122
Hanlin SDK: existing verified Vendor/HanlinAgentSDK and Vendor/HanlinPlatform.

## Previously verified

- GSD and HanlinAgentSDK baseline Xcode27 acceptance passed:
  https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45060441724
- The current task uses the same canonical GSD TaskStore and original sync path.

## New GSD MCP components

- Independent Oracle service: /home/ubuntu/gsd-mcp-bridge,
  gsd-mcp-bridge.service, loopback port 8768 on Node 24.
- Existing Tailscale Funnel port 10000, separate path /gsd:
  https://torah-social.tail0a6c7d.ts.net:10000/gsd/mcp.
- The Lorvex root URL and original service remain unchanged.
- OAuth PKCE/DCR, code-based pairing, hashed access/refresh credentials
  and iPad-side Keychain storage. No duplicate task database is hosted on
  Oracle; only limited transient command queues and OAuth pairing state.
- iPad GSDRemoteBridgeState: outbound HTTPS with foreground polling;
  root-hosted approval dialog for all writes, routed into GSDHanlinHost
  using the existing GSD TaskStore.
- GSDHanlinDashboard uses JSON from the actual get_dashboard tool,
  rendered with Swift Charts and interactive matrix/status selection.

## Server acceptance completed

- Node OAuth/MCP/device round-trip tests passed on Windows and Oracle.
- Oracle gsd-mcp-bridge.service active on 127.0.0.1:8768.
- Public HTTPS /gsd/health returns 200.
- OAuth discovery returns 200 with /gsd prefix.
- Unauthenticated /gsd/mcp tools/list returns 401.
- Existing Lorvex /health still returns 200.

## iPad acceptance and build scope

- scripts/build_gsd_hanlin_ipad_ipa.sh prepares an unsigned ARM64 device
  application, full IPA and sideload-compatible IPA without nested extensions,
  with ZIP CRC and SHA256 manifest validation.
- GitHub CI gsd-hanlin-agent-ios.yml runs SDK tests, server tests and the
  unsigned iPad build and uploads logs and separate assets.
- Device installation requires an Apple signing and provisioning service.
- Physical iPad execution and ChatGPT OAuth pairing still require
  user verification before any claim of end-to-end completion.

## Security / isolation

- GSD and Lorvex have independent ports, services, credentials, OAuth
  issuers and tool catalogs. Neither shares or exposes the other's tasks.
- Every remote write requires explicit human approval on the iPad.
- The MCP server does not receive arbitrary SQL or executable commands.
- When iPadOS suspends GSD, remote commands fail closed rather than
  claiming success or changing another copy of the data.
