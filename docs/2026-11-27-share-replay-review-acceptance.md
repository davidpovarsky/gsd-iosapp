# Share replay, review and extension-origin acceptance

This additive fixture freeze uses product checkpoint bbbed0d7dc263ae77f9686e1864e8afac9fecd04 as its behavioral baseline. No production behavior changes are included.

## App-side Share16

The original twelve Share scope, canonical-store, gate and title-enrichment assertions remain unchanged. Four additional checks exercise:

- A stale queued creation replay must preserve the actual persisted canonical row and sync outbox.
- A stale pushed creation replay must preserve the actual persisted canonical row and sync outbox.
- A distinct, explicitly edited retry must remain in the Share outbox for review without overwriting a canonical row. Identical timestamps deliberately prevent timestamp-based classification.
- A detail review lease must become invalid synchronously on unresolved/account transitions, including A → unresolved → A. The baseline uses the original view's cached canReview decision; the corrected path calls the actual drainer lease method.

The first three use actual TaskStore and GRDB readback, comparing persisted-before values rather than unpersisted Date values. Review coverage establishes the model admission used by the view; it does not claim native SwiftUI rendering acceptance.

Expected baseline: the original twelve pass, the four additions fail. Final acceptance requires all sixteen unique checks to pass on the final consumed source.

## Extension9

The standalone extension probe executes the actual ShareCaptureSession, ShareScopePublisher, SharedTokenKeychain status interpretation, JWT decoder and filesystem outbox/identity/publication/lease code. Only HTTP and the SecItemCopyMatching result are doubled. No personal credentials or real network requests are used.

The nine checks cover tri-state Keychain access; missing metadata; first-ever unpushed guest bootstrap; unavailable credentials; another-account replacement; same-owner credential replacement; A → unresolved → A publication invalidation; origin journaling before an admitted POST; and exactly-once recovery of an abandoned journal.

Expected bbbed baseline: eight pass and same_owner_token_replacement_invalidates_open_sheet fails. Final acceptance requires all nine unique checks to pass. Earlier original Share4 and native Share2/all-eight assertions remain independent required gates.

## Execution boundary

Only the native acceptance owner executes Swift on the Apple runner. Python prepare-only work on Oracle is packaging, not acceptance. Each run binds original product inputs, exact fixture/driver hashes and the full dependency closure before and after execution. Failed fixture compilation must remain a setup failure, never a behavioral RED.

A local file lease orders live cooperating processes. It does not establish that a timed-out or crashed HTTP request can never commit later on the server. That unresolved remote ordering condition remains separately owned by the server lane.
