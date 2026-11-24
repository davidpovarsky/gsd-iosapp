# Session identity observation — 2026-11-24

## Scope and defect

Base: `b86d1dbdbf8fb70f170814e966c41ab31fab88e5`.
Work branch: `fix/gsd-session-observation-20261124`.

`SessionStore.isSignedIn` and `currentUserID` previously read the token store in
computed properties without an Observation dependency. A token cleared by a
rejected background refresh, or a different owner with the same cached email,
could therefore fail to invalidate a SwiftUI view observing only those fields.

Production edits are limited to App/Auth/SessionStore.swift,
App/Auth/KeychainTokenStore.swift, and one call in the existing .active
path of App/GSDApp.swift. The existing Keychain and `AuthService`
remain the session authority. `SessionStore` maintains observable UI snapshots
of token presence and owner, refreshed from that authority on MainActor.

The Keychain adapter sends one invalidation notification after each save or
clear. Its object and userInfo are nil; it carries no token or account identity.
The weak MainActor observer rereads current state, so queued notices cannot
replay an earlier owner. Its observer token is removed in an isolated deinit.
Initialization and explicit sign-in, sign-out, deletion and account-decision
paths also refresh synchronously. Same-owner token renewal does not publish a
false identity change. No login protocol, persistence format, task engine,
localization string, UI target or server behavior changes.

## Verification boundary

`scripts/check_session_observation.py` is a portable, strict Swift 6 host probe.
It compiles the actual SessionStore source and the actual Keychain adapter's
load/save/clear methods. Only imports and the host platform dependencies are
substituted: in-memory Security storage, fake auth/coordinator seams, and a
non-Apple localized-string initializer. It uses real Swift Observation and
NotificationCenter. It is not an OS Keychain or network integration test.

The probe contains thirteen checks:

1. Restore identity from the existing token store.
2. Verify one payload-free notification for save and for clear.
3. Observe an external owner change with unchanged email.
4. Observe a token clear representing rejected refresh, without a UI action.
5. Preserve identity during same-owner token renewal.
6. Publish explicit sign-out synchronously.
7. Reread current state after queued save/clear notifications.
8. Keep an unresolved account decision signed out.
9. Publish the accepted account decision's owner.
10. Publish the confirmed-deletion signed-out state.
11. Release SessionStore despite the notification subscription.
12. Reread an externally replaced token on foreground activation without a local notice.
13. Reread an externally cleared token on foreground activation without a local notice.

**Behavioral verification is pending the mandatory Xcode 27 native gate.**
The Windows toolchain attempts did not execute these assertions successfully;
no local regression pass or expected behavioral baseline failure is claimed.
The first attempt reported a test-only weak-variable warning. After correcting
that warning, Swift 6.3.3 hit an ownership assertion while capturing a local
noncopyable Mutex. The probe now uses an immutable Sendable recorder owning the
Mutex. The following attempt stalled and hit the enclosing 220-second timeout.
Only its exact verified compiler process was terminated; unrelated processes
were left running. The portable probe now bounds and cleans up its own process
tree on timeout. Strict concurrency and warnings-as-errors remain enabled.

Raw compiler and timeout receipts are preserved in
`evidence/session-observation-20261124/windows-toolchain-attempts.json`.
Syntax validation of both production files is recorded separately in
`evidence/session-observation-20261124/swift-parse.json`.
The direct Swift 6.3.3 frontend parse completed successfully at
2026-11-24 02:02:18 UTC. `git diff --check` and Python syntax compilation of
the portable probe also passed. These are syntax checks, not behavior results.

The native owner will run `python3 scripts/check_session_observation.py`
unconditionally on the final integrated source, followed by the actual app
build and the live account UI acceptance already assigned to that lane. The
unchanged package trees may reuse their existing approved package evidence.
Release acceptance remains blocked until the real native gate succeeds.


## Activation follow-up

Root review identified that process-local notifications do not cover another
process changing the shared Keychain while GSD is inactive. Current source has
only a shared-token read in ShareViewController; no extension save/clear call
was found. The snapshot still needs a resume boundary for shared-store changes.
The existing GSDApp .active path now calls session.enteredForeground()
immediately before coordinator.enteredForeground(). That narrow method rereads
the existing authority. There is no polling or UIKit/AppKit observer.

Two additional probe assertions directly replace/clear the shared storage
without sending the app adapter's notification, then invoke the activation
method and require observable identity updates. Their runtime result remains
pending the mandatory Mac gate; no Windows compilation retry was performed.
