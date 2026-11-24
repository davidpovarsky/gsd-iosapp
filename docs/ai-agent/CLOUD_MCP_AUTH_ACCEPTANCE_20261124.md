# Cloud OAuth and MCP acceptance — 2026-11-24

## Authorized scope

Complete the cloud account connection contract and apply equivalent corrections to GSD and Lorvex. Use synthetic accounts in isolated fixtures; preserve existing accounts, authorization grants, task data, native schemas and the existing private plugin identities.

## Contract

- All existing 22 tools declare their OAuth scopes at the top level and in compatibility metadata.
- Known tool calls with missing, expired or insufficient credentials return an error result carrying `mcp/www_authenticate`; no operation executes. Protected catalog discovery and native APIs remain authenticated.
- Supported MCP versions are negotiated explicitly.
- OAuth issuer metadata agrees with every authorization callback.
- Lorvex consent reaches the existing GSD language and browser-origin standard: Hebrew and English, exact consent scopes, a language-only action that changes neither lifetime nor grant, same-origin forms, localized terminal errors, and persistent selection across a server restart.
- Canonical data, schema version and synchronization algorithms remain unchanged.

## Verification and release

Run the affected Node contract tests plus the existing isolation, persistence and synchronization tests. Keep deployment source snapshots and verify byte identities before rollout. Restart only the existing named application service and verify its public health and auth responses. Revert source files if rollout health fails.

Actual ChatGPT account linking and mobile app availability require a registered App binding and a signed-in owner session. Backend contract checks alone do not establish that acceptance.

## Implemented and verified

- Focused Node regression suite: 15 passed, zero failures. Synthetic fixtures only.
- Missing/expired authorization and insufficient scope reject before tool execution.
- GSD includes expired PocketBase credential reconnect handling and issuer identification on both callback paths.
- Lorvex adds only an OAuth-request language column; migration and restart preserve existing accounts, sessions, consent, PKCE and expiry.
- Source deployment is verified below. Actual personal ChatGPT linking remains a separate acceptance step.

## Production receipt

- Deployed and verified at 2026-11-24T15:34:39Z using the existing gsd-cloud-gateway.service unit.
- Code source: `98d298bb4ea3ebc2266e80b7e883c00573365a71`. Exact live hashes match the tested source.
- Public health returned HTTP 200. Issuer metadata, MCP 2025-11-25 negotiation, authenticated catalog discovery and structured unauthenticated-tool rejection passed.
- Existing unit definitions, environment, account credentials and user data were preserved; only application code modules were copied. Source rollback copies were retained.
- Registration acceptance remains open: the available owner browser is logged out and the connected Browser extension is unavailable. No App ID was invented; neither private plugin identity nor audience changed.

### Live module hashes

- `server.mjs`: `45526f16d81eaac4b2e1e2f54e764aa7e86e5874b6d9ba7f8441e9ccce5acf54`
