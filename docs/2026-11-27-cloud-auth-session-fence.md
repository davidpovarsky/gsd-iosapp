# Primary cloud authentication completion fence

## Scope and acceptance

The final product request requires account isolation, durable sign-out and safe renewal. The existing AuthService unconditionally writes a token after asynchronous password/OAuth/registration/refresh calls, clears the current token after a delayed delete or rejection, and allows validToken to fall back to its captured old token whenever any token is present. These paths can cross an explicit sign-out or a newer account.

This bounded change preserves the public TokenStore protocol, original PKCE values per attempt, original server endpoints, original test fixtures and all 1,333 original core test identities. It does not edit the server, original Hanlin SDK, shared visualization library, Keychain implementation, or task database. The app-owned pending-account switch must use the same AuthService session-adoption boundary as its other token mutations.

## Required behavior

- Each auth attempt captures its session revision and exact initial token before suspending.
- Explicit sign-out, a new sign-in attempt, and adoption of a user-approved pending account invalidate older completions, including sign-out followed by a byte-identical token.
- A copied AuthService value shares the same mutation fence.
- Refresh and deletion may save or clear only the session they actually started with. A refresh response for a different known account is rejected.
- validToken never returns a previous account after a newer account or sign-out has superseded it; ordinary offline fallback for an unchanged still-valid token is preserved.
- A cancelled sign-in or token refresh cannot publish a late result or disguise cancellation as a successful fallback.
- The existing original AuthService and cloud login tests remain unchanged.

## Verification and ownership

Root owns the AuthService producer and the new AuthServiceSessionFenceTests file. The client agent owns exactly the three SessionStore token-mutation call sites and its existing OAuth admission guard. The Watch agent owns its separate wire scope and mutation drain. Native execution is owned by native_acceptance on Scaleway Mac.

The new fixture has 17 deterministic asynchronous cases. Every HTTP request goes through an injected, in-memory RequestExecuting actor restricted to fixture.invalid. Continuations hold real AuthService network boundaries; there is no live network, browser, personal token or fake product success. The fixture compiles against the original API for its behavioral RED. GREEN will run the identical new fixture plus the unchanged existing auth tests; final acceptance must retain all original 1,333 identities and count these 17 additions separately.

Current state: test-first source only. No runtime RED or GREEN is claimed here. Original package source is unchanged in this checkpoint. Final input hashes, raw output and exact count/identity receipts will be supplied by the native owner.

## Verified behavioral RED and producer candidate

The corrected fixture at `0406aaeb192a2ba7f94625152641da3937e93da0` compiled on Xcode 27.0 and discovered exactly the original 1,333 identities plus all 17 additions. All 17 new runtime cases then failed the intended assertions, with no skip or timeout. Receipt SHA256: `fba788d81c1de6174defb28ca92233f2352418454b7df997d760fe0080221415`; XML SHA256: `aca8abfba1ec5f0b78eb6def0b6f88a54faf416928d5a57f03c10c25459a4686`. The earlier 70c fixture compile failure is preserved separately and is not behavioral evidence. Root directly verified the receipt, all 17 XML failures, unchanged source/dependencies and exact corrected fixture bytes before editing the producer.

The producer keeps TokenStore and Keychain code unchanged, shares an explicit mutex-backed revision across AuthService copies, captures the exact token/revision for each async operation, and conditionally commits token mutation. New sign-in entry and commit, sign-out and explicit pending-session adoption invalidate earlier completions. Refresh keeps its account identity, and validToken only permits unchanged-session offline fallback. SessionStore must use adoptSessionToken for both user-approved pending-account saves and auth.signOut for the pending clear. No await is held under a mutex. Current producer source is ready for independent review and the identical GREEN fixture plus unchanged existing auth tests; no GREEN outcome is claimed yet.
