# GSD ChatGPT plan SDK integration acceptance

Date: 2026-11-23

Canonical shared SDK pin: https://github.com/davidpovarsky/hanlin-ai/commit/caa4faa509ebf5ba4164408734bb6e0dd3662203

Client/transport change: 1d485194c479069b123c6ba0348315357af70225. Follow-up engine correction: caa4faa509ebf5ba4164408734bb6e0dd3662203 (restores all tool definitions; shared plan transport is automatic for configured and per-turn fetches).

## Ownership and implementation

GSD consumes the original Hanlin repository through a selected-product installation. The host lock specifies the complete canonical revision and the SHA-256 of its official installer. The bootstrap downloads that immutable installer, verifies its bytes (allowing Git's Windows CRLF normalization), and delegates installation to it. It does not generate replacement SDK source.

The selected products are HanlinAgentCore, HanlinHostContracts, HanlinPersistenceAdapters, HanlinPlatformContracts, and HanlinChatCore. The installer materializes Vendor/HanlinSDK and verifies that its source has no host edits. The two former tracked copies, Vendor/HanlinPlatform and Vendor/HanlinAgentSDK, are removed from this isolated integration branch. Their prior history and acceptance receipts remain in Git.

The shared SIWC client now supports:

- Actual initial app name, stable host ID, saved issued-client mapping after local sign-out, optional account hints, and explicit consent only when requested.
- Injected URLSession and clock for real request/verification tests.
- Callback state/duplicate/registration checks and cryptographic ID-token validation. Refreshed ID tokens must preserve issuer, audience, and subject.
- Rotating refresh credentials, granted scopes, expiry, and earliest_refresh_at metadata.
- Revocation through validated official discovery and empty-success handling.
- Exact OAuth error code, HTTP status, and request ID without retaining response credential bodies.

The shared Responses transport enforces POST https://api.openai.com/v1/responses, store=false, stream=true, array input, and supported preview fields. It moves original function/custom tool schemas into the documented additional_tools input contract without renaming aliases. Tool dispatch, host approval, persistence, diagrams, and all 22 GSD tool implementations stay in their original layers.

The old canonical engine suppressed all plan tools while its wire format was unsupported. That suppression is removed now that the shared transport implements the official format. The engine automatically wraps both configured and per-turn transports; GSD does not maintain a duplicate wrapper or agent engine.

A stream is complete only after response.completed. HTTP admission errors, response.failed, response.incomplete, error events, and interrupted streams are failures even after visible partial text.

The GSD assistant selects company OpenAI/apiType openai-responses for provider ChatGPT. It rebuilds that engine for each send so the host manager's newly refreshed token is used. Other provider credential replacement also invalidates the engine using a SHA-256 credential fingerprint rather than a raw-key fingerprint. OpenRouter and other API provider options remain supported.

## Reproducible commands

From the GSD repository root, before XcodeGen:

    python3 scripts/install_hanlin_sdk.py
    python3 scripts/install_hanlin_sdk.py --check

On the native runner:

    swift test --package-path Packages/GSDHanlinAgent

The focused public SDK contract suite is ChatGPTPlanContractTests. It exercises auth registration and return, callback rejection, signed ES256 identity, rotation and subject consistency, scope-based plan availability, revocation discovery, exact error diagnostics, all 22 tool aliases, route restrictions, and terminal stream verification. A real original-engine/provider interception test ensures tools are actually advertised rather than only checking a fabricated body. All credentials are synthetic fixtures.

## Verified before native integration

- Windows remote installation through the original pinned installer succeeded; selected profile has no binary/native artifact targets.
- Original installer --check passed, including original source ownership and generated manifest/receipt integrity.
- GSD consumer Swift package manifest dump passed.
- Swift frontend parsing passed for changed shared sources, changed host adapters, and the focused contract source.
- Python bootstrap syntax and Git whitespace checks passed.
- Localization checkpoint and repair remain separate: d99527b4977c70d23d39522c56c0c8b6ace2c793, f2462b60cae3246f0375677cd67bd28fa7b359a1, 9fda3bae2f200e7b645b4f2b7ed8bcc39d896b3c.

A local partial-clone object cache could not serve missing promisor objects to another clone. Retrying the original installer from the canonical GitHub remote resolved installation without altering another checkout. An initial Windows bootstrap audit rejected CRLF installer bytes; canonical LF normalization now preserves the digest check across Windows/macOS.

## Outstanding evidence

Native execution of the contract suite, Xcode/UI integration, personal official OAuth consent, actual account entitlement and inference, and TestFlight acceptance are owned by the coordinated integration/release run. This report does not claim an active ChatGPT subscription connection, native acceptance, or a release based on source parsing.

The account manager/UI is separate host work: loopback callback listener, Keychain multi-account state, atomic credential rotation, account switching, and user recovery are not duplicated in this SDK layer.

## Official contract references

- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- https://developers.openai.com/siwc/token-sharing-open-source/token-reference
- https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
