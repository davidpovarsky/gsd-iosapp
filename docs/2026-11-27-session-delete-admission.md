# Session deletion admission and extension-write boundary

This additive fixture accompanies the narrowly scoped SessionStore deletion correction. It preserves the existing nine host checks and the complete default native presentation UI branch. It does not alter any Core or Agent test identity.

## Reproduction

The tenth conditional fixture case is `delete_cannot_interrupt_an_inflight_signin`. It initializes the real SessionStore and AuthService with a synthetic account A token, starts a real password sign-in to account B, and holds the response through an isolated URLProtocol that intercepts every URL. While that first request is active, the case calls the actual deleteAccount(eraseLocalData: false) method.

Required behavior: the deletion entry is rejected synchronously, the first in-progress phase stays closed, the retained token remains unchanged, no second transport request or authorization presenter starts, and releasing the original response installs only account B and its exact synthetic response token. Cleanup always releases and joins the first operation, including the negative baseline. Admission failures remain visible if cleanup also fails.

The expected behavioral RED is exactly:

> A delete attempt must not end the active sign-in phase.

Compile errors, setup timeouts, or cleanup-only failures cannot qualify this RED. The baseline is the unchanged SessionStore from canonical 937bf3aae7332f6b69b9fa84f49624de31424fd4. The fixture uses the qualified AuthService implementation in that source, never live credentials or an external authorization browser.

The newly added delayed transport has independent state; the original OAuth case, its request counter, its locked holder and all original assertions remain byte-identical. The full GREEN run executes the original nine cases followed by this tenth case.

## Native execution contract

The native owner compiles the exact GSDTaskWorkspacePresentationStore.swift, SessionStore.swift, KeychainTokenStore.swift and this complete conditional fixture file in the existing standalone host package, with real local GSDKit and TaskVisualizationKit dependencies, macOS 26 and the existing pinned dependency closure. Only GSD_WORKSPACE_PRESENTATION_FIXTURE selects the fixture branch. GSD_WORKSPACE_PRESENTATION_FIXTURE_ALLOWED=1 is required at runtime. Select the tenth case with GSD_WORKSPACE_PRESENTATION_FIXTURE_CASE=delete_cannot_interrupt_an_inflight_signin for RED; unset selection for all ten GREEN cases.

The optional SyncCoordinator fixture dependency still traps on every method. Its added withExternalWritesPaused signature is a compile-only adapter; these tests pass coordinator:nil and do not claim to exercise the production cross-process lease. That lease is qualified separately by the Share owner and source-reviewed at the SessionStore call site.

## Production scope

The correction adds the same synchronous !inProgress entry guard already used by email and OAuth sign-in. The remote AccountDeleter.delete operation is wholly wrapped by the required production coordinator's withExternalWritesPaused boundary, including the primary route and fallback. Lease acquisition failure must return without starting deletion and without clearing local data or credentials. The wrapper releases before the later eraseLocal callback, which may acquire the dataset replacement lease itself. The inProgress phase stays active through both steps. Existing AuthService fences, user confirmation and local retention behavior remain unchanged.

No physical device, system-delivered notification, personal authorization, or successful remote account deletion is claimed by this fixture.
