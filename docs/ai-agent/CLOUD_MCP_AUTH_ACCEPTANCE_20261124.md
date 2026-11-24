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

Personal Plugin Connect and availability on a supported mobile surface remain unverified, separate acceptance steps. Backend contract checks alone do not establish either result.

### Plugin packaging and mobile scope

A valid remote MCP plugin package using `mcp.json` does not require `.app.json`. The [Help Center guidance on importing plugin marketplaces](https://help.openai.com/en/articles/20001504-importing-and-syncing-plugin-marketplaces-from-github) describes `.app.json` as an optional reference to an existing app; it neither creates an app nor grants permissions. For imported workspace plugins, declaring an MCP server can produce a Desktop only label even with a remote HTTPS URL, and adding `.app.json` alone does not remove that label.

The [official plugin guide](https://learn.chatgpt.com/docs/plugins) states that Desktop only plugins are unavailable on mobile. The Help Center classification explanation is explicitly scoped to imported workspace plugins. Applying that explanation to GSD's `USER`/`PRIVATE` plugin would be an inference; the exact cause of its classification has not been established. Personal Plugin Connect and supported mobile-surface availability require direct verification; App registration is not an established prerequisite or an iPad remedy.

## Implemented and verified

- Focused Node regression suite: 15 passed, zero failures: one existing gateway-security case, ten OAuth page/localization cases and four new MCP authorization cases. Synthetic fixtures only.
- Missing bearer credentials, revoked grants and insufficient scopes reject before tool execution; the affected fixtures assert that no PocketBase operation is dispatched.
- A simulated PocketBase HTTP 401 returns reconnect metadata with fixed public error text. Issuer identification is present on both callback paths.
- Lorvex adds only an OAuth-request language column; migration and restart preserve existing accounts, sessions, consent, PKCE and expiry.
- Source deployment is verified below. Actual personal ChatGPT linking remains a separate acceptance step.

The MCP regression variable `expired` refers to an access token checked after its grant was revoked. The rejected-account case injects PocketBase HTTP 401. These observations cover revocation and account rejection; natural bearer clock expiry was not exercised. The session/TTL implementation is unchanged.

## Production receipt

- Deployed and verified at 2026-11-24T15:34:39Z using the existing gsd-cloud-gateway.service unit.
- Deployment receipt local source identifier: `98d298bb4ea3ebc2266e80b7e883c00573365a71`. The published server linked below has the exact deployed hash.
- Public health returned HTTP 200. Issuer metadata and MCP 2025-11-25 negotiation passed. Protected catalog discovery without credentials returned HTTP 401; the unauthenticated tool call returned HTTP 200 with `isError: true` and an `invalid_token` challenge. This rollout receipt contains no authenticated catalog result.
- Existing unit definitions, environment, account credentials and user data were preserved; only application code modules were copied. Source rollback copies were retained.
- Personal Plugin Connect remained unverified at this rollout checkpoint: the available owner browser was logged out and the connected Browser extension was unavailable. No App ID was invented; neither private plugin identity nor audience changed.

### Live module hashes

- `server.mjs`: `45526f16d81eaac4b2e1e2f54e764aa7e86e5874b6d9ba7f8441e9ccce5acf54`

## Reused tool evidence and published source identity

The [public nine-checkpoint E2E](https://github.com/davidpovarsky/gsd-iosapp/blob/cfe9470b6020c28474395ff97f0672d4a5c8f126/docs/ai-agent/evidence/cloud-20261124/public-e2e.txt) at `0e8911a33fc29eed8dfd969e43a0e6a86b63c9a4` remains evidence for the actual execution of all 22 tools and account isolation. Direct comparison with the [published server at b746c080](https://github.com/davidpovarsky/gsd-iosapp/blob/b746c080473439708defc285ceee43e9165aa636/cloud/gateway/server.mjs) found the 158-line `executeTool` implementation byte-identical (SHA-256 `219c1c32be03da7a36ea19fe47eb0822f75333496627d4a07d986d086b5b493a`), as was the containing 264-line bearer/session, PocketBase and data-helper block. The tool catalog, task-domain module, PocketBase hooks and migrations also retain identical Git blobs. The published server's SHA-256 is the live hash above, matching the 15:34 deployment receipt. This reuses the existing tool/data results; changed OAuth web and MCP authorization/protocol behavior is covered by the focused suite and bounded rollout checks above. Personal Plugin Connect and supported mobile-surface availability remain unverified, separate acceptance steps.
