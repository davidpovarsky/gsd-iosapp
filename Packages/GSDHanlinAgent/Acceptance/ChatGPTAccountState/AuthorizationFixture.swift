import Foundation
import HanlinChatCore

enum GSDChatGPTAuthorizationError: Error { case cancelled, unavailable, timedOut }

/// The UI presenter alone is replaced. The original SDK creates the attempt and verifies
/// the fixture's signed identity, nonce, registration and scopes through intercepted HTTP.
@MainActor final class GSDChatGPTAuthorization {
    static var callback: (@MainActor (HanlinChatGPTAuthorizationAttempt) async throws -> URL)?

    func authenticate(
        attempt: @escaping @MainActor (UInt16) throws -> HanlinChatGPTAuthorizationAttempt
    ) async throws -> (URL, HanlinChatGPTAuthorizationAttempt) {
        guard let callback = Self.callback else { throw GSDChatGPTAuthorizationError.cancelled }
        let value = try attempt(49152)
        return (try await callback(value), value)
    }

    func cancel() {}
}
