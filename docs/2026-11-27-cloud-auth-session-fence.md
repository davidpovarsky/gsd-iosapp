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
