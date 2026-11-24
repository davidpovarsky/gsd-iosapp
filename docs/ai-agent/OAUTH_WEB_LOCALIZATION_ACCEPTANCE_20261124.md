# GSD Cloud OAuth web localization acceptance — 2026-11-24

## Verified result and boundary

The production GSD account login/consent page renders Hebrew with RTL and English with LTR. After a fresh GET of the corrected production document, the root integration agent clicked the actual English selector, observed the English form, clicked the actual Hebrew selector, and observed the Hebrew RTL form. Both resulting screenshots were inspected for readable labels, password guidance, and permissions.

This real browser form-submission check used a disposable OAuth client. No credentials were entered, no user account was created, and no authorization grant was issued. It does **not** establish personal ChatGPT Plugin Connect, Continue with ChatGPT authorization, plan inference, or iPad acceptance. Those remain separate acceptance gates. The Plugin and Hebrew Asana tasks remain open.

Branch: `fix/gsd-cloud-oauth-l10n-20261124`.

## Source changes

| Commit | Scope |
| --- | --- |
| [3b67365aa32b1d17d8897731a3d7eb729083d268](https://github.com/davidpovarsky/gsd-iosapp/commit/3b67365aa32b1d17d8897731a3d7eb729083d268) | Localized forms and terminal HTML, supported he/en negotiation, same-origin language selector, preserved OAuth request fields. |
| [b46cc29656a56acb4dd2a359c64bc8a61dc62a12](https://github.com/davidpovarsky/gsd-iosapp/commit/b46cc29656a56acb4dd2a359c64bc8a61dc62a12) | Preserve the selected language when a pending request expires during rejected account login. |
| [b2dafb4fa130a8deed44caa65475b33c393c7eac](https://github.com/davidpovarsky/gsd-iosapp/commit/b2dafb4fa130a8deed44caa65475b33c393c7eac) | Correct document-only Referrer-Policy and add regression checks without weakening strict Origin validation. |

Explicit `ui_locales` takes precedence over supported weighted `Accept-Language` preferences. Pending requests preserve the selected language. Form labels, account/password validation, permission explanations, and terminal errors use shared he/en copy with appropriate `lang`, `dir`, and alert semantics. The password hint states 10–128 characters.

The selector posts to the same origin and changes only the pending request language. It preserves state, PKCE challenge and method, client, redirect URI, scopes, resource, expiration, and failure count. Unsupported locales and missing, literal null, or foreign Origin values remain rejected. OAuth protocol endpoints retain JSON errors.

## Why the first HTTP result was insufficient

The initial b46 public smoke completed at 01:12:52 UTC with 10/10 checks passing. Its HTTP client supplied an explicit valid Origin header for the selector, so it did not reproduce a browser-generated navigation POST.

Root's browser review then found a real failure: clicking English on the Hebrew form returned the localized invalid-origin error. The shared HTML helper used `Referrer-Policy: no-referrer`. The [Fetch Origin-header algorithm](https://fetch.spec.whatwg.org/#append-a-request-origin-header) makes a navigate-mode POST origin opaque under that policy. The strict Origin guard correctly rejected the resulting null Origin.

Commit b2dafb4 changes only the HTML document policy to `same-origin`. Legitimate same-origin forms retain a valid Origin while cross-origin referrers remain suppressed. The strict comparison, rejection of missing/null/foreign Origin, CSP `form-action 'self'`, `Cache-Control: no-store`, and `X-Content-Type-Options: nosniff` remain intact.

After deployment at 01:30:04 UTC, root used a **fresh GET** and exercised both real language buttons successfully. The earlier HTTP-only receipt remains historical evidence and must not be cited alone as browser acceptance.

## Evidence inventory

Paths below are relative to this document.

| Evidence | What it proves |
| --- | --- |
| [windows-focused-tests.json](evidence/oauth-web-20261124/windows-focused-tests.json) | Corrected source: Node syntax, all 10 focused HTTP fixture tests, and diff check passed. Includes exact command output and tested server hash. |
| [oauth-localization-deployment.json](evidence/oauth-web-20261124/oauth-localization-deployment.json) | Initial b46 gateway-only deployment, health 200, source hashes, preserved OAuth state/key and other services. |
| [oauth-localization-public-smoke.json](evidence/oauth-web-20261124/oauth-localization-public-smoke.json) | Historical 10/10 public HTTPS checks with ordinary certificate validation; HTTP selector Origin was explicitly supplied. Its cleanup-pending field describes that earlier moment. |
| [oauth-referrer-deployment.json](evidence/oauth-web-20261124/oauth-referrer-deployment.json) | Corrected b2 deployment, public same-origin document header, unchanged strict Origin guard, health 200, preserved state/key and other services. |
| [oauth-visual-cleanup.json](evidence/oauth-web-20261124/oauth-visual-cleanup.json) | Root's successful HE→EN→HE browser review and completed exact fixture cleanup; no accounts/grants or credentials. Supersedes the earlier cleanup-pending state. |

Screenshots were inspected during root's live browser review. These repository receipts retain that review attestation; they do not contain exported screenshot files or live authorization URLs.

Existing focused checks, reused without executing them again during evidence publication:

```text
node --check cloud/gateway/server.mjs
node --test --test-reporter=tap cloud/gateway/oauth-localization.test.mjs
git diff --check
```

The final focused execution ran at 2026-11-24 01:25:35–01:25:50 UTC, SentinelX job `job_0d518aeb088e`: 10 tests passed, zero failed/skipped, test duration 2994.9384 ms. Coverage includes negotiation, guidance, escaping, terminal errors, unchanged OAuth fields, strict Origin/locale/prototype guards, a real fixture PKCE exchange after a language switch, expiration during rejected login, and document policy headers. These are HTTP fixture results; the browser proof is the separate root review.

No extra GitHub Actions run or repetition of all 22 MCP tools was dispatched for this web-only change. Prior full backend acceptance remains in [CLOUD_ACCOUNT_ACCEPTANCE_20261123.md](CLOUD_ACCOUNT_ACCEPTANCE_20261123.md). The centralized Native lane owns simulator and release Actions.

## Deployed bytes and operational preservation

The approved Windows file uses CRLF; Git stores LF. Both hashes identify the equivalent source bytes:

| Source | Canonical Git LF SHA-256 | Tested/deployed CRLF SHA-256 |
| --- | --- | --- |
| b46 | `cf04a971541e4fac91c1039352db0862a2246b3132bdc8f171422c36813a6af2` | `6dbbf8d84dd1509b38f12a30eb0d5d2f2a9d6cc2d151ac4a4eedb9f5b3c8183f` |
| b2 | `dc12fce18f7730f50bc0049a5bde08bfa08038f7c25bd241e5e8e0e953cb9338` | `185af9c292b6f0651b7e757d68d1f911d7e5be690e4cc49de2bf8604496819a2` |

The backend owner deployed only `cloud/gateway/server.mjs` through the existing authorized Windows/SSH route, in a window coordinated with Native cloud tests. No permission policy or allowlist changed. The gateway encryption key and OAuth state bytes were preserved across deployment. PocketBase, the old bridge, and Lorvex service state remained unchanged. Root filesystem free space was checked before deployment; no unrelated files were removed.

At 01:34:07 UTC, after browser review, the backend owner performed a controlled gateway-only stop for an atomic edit removing exactly the disposable client and its one remaining pending request. The fixture had zero grants. Other state entries and the encryption key were preserved; readback and health 200 passed. The published receipt redacts the client identifier, retains cleanup counters and the pending-ID hash, and excludes the private cleanup plan.

## Remaining acceptance

Personal Plugin Connect still needs the account owner's normal login/consent and a tool invocation from ChatGPT with GSD closed. Continue with ChatGPT is a separate authorization and inference gate. Native Hebrew/English iPhone/iPad UI, physical iPad sync, VoiceOver, real Siri, Share, Watch, and WidgetKit timeline checks cannot be inferred from these web results.
