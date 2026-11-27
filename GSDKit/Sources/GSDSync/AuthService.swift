import Foundation
import Synchronization
import GSDWire

/// Stateful-PKCE auth orchestration over the injected seams. PKCE values remain local
/// to each attempt; copies share a session fence so late completions cannot undo a newer intent.
public struct AuthService: Sendable {
    private let client: PocketBaseClient
    private let presenter: WebAuthPresenting
    private let tokenStore: TokenStore
    private let config: AuthConfig
    private let refreshSkew: TimeInterval
    private let now: @Sendable () -> Date
    private let sessionState: SessionState

    private final class SessionState: Sendable {
        let revision = Mutex<UInt64>(0)
    }

    private struct SessionLease: Sendable {
        let revision: UInt64
        let token: String?
    }

    /// Refresh proactively while a PocketBase token still has days of validity left.
    public init(client: PocketBaseClient, presenter: WebAuthPresenting, tokenStore: TokenStore,
                config: AuthConfig, refreshSkew: TimeInterval = 7 * 24 * 60 * 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.presenter = presenter; self.tokenStore = tokenStore
        self.config = config; self.refreshSkew = refreshSkew; self.now = now
        sessionState = SessionState()
    }

    public func signIn(provider: String) async throws -> AuthResult {
        try _Concurrency.Task.checkCancellation()
        let lease = captureSession(startingSignIn: true)
        let methods = try await client.authMethods()
        try requireCurrent(lease)
        guard let p = methods.providers.first(where: { $0.name == provider }) else {
            throw AuthError.providerNotFound(provider)
        }
        let authURL = try buildAuthURL(p.authURL, redirectURI: config.redirectURI)
        let callback = try await presenter.present(authURL: authURL, callbackURLScheme: config.callbackScheme)
        try requireCurrent(lease)
        let (code, state) = parseCallback(callback)
        guard state == p.state else { throw AuthError.stateMismatch }
        guard let code else { throw AuthError.missingCode }
        let result = try await client.authWithOAuth2(
            provider: provider, code: code, codeVerifier: p.codeVerifier, redirectURL: config.redirectURI)
        try replaceToken(result.token, expecting: lease, advanceRevision: true)
        return result
    }

    /// Display only providers actually configured by our account server.
    public func enabledOAuthProviders() async -> [String] {
        (try? await client.authMethods().providers.map(\.name)) ?? []
    }

    public func signInWithEmail(_ email: String, password: String) async throws -> AuthResult {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), address.utf8.count <= 254,
              !password.isEmpty, password.count <= 128 else { throw AuthError.invalidCredentials }
        try _Concurrency.Task.checkCancellation()
        let lease = captureSession(startingSignIn: true)
        let result = try await client.authWithPassword(email: address, password: password)
        try replaceToken(result.token, expecting: lease, advanceRevision: true)
        return result
    }

    public func createAccountWithEmail(_ email: String, password: String) async throws -> AuthResult {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), address.utf8.count <= 254,
              password.count >= 10, password.count <= 128 else { throw AuthError.invalidCredentials }
        try _Concurrency.Task.checkCancellation()
        let lease = captureSession(startingSignIn: true)
        let result = try await client.registerPasswordAccount(email: address, password: password)
        try replaceToken(result.token, expecting: lease, advanceRevision: true)
        return result
    }

    public func signOut() {
        sessionState.revision.withLock { revision in
            revision &+= 1
            tokenStore.clear()
        }
    }

    /// Install an already validated token after the user resolves the pending-account dialog.
    /// Keeping this boundary shared with sign-out also fences a byte-identical reauthentication.
    public func adoptSessionToken(_ token: String) {
        sessionState.revision.withLock { revision in
            revision &+= 1
            tokenStore.save(token)
        }
    }

    public func currentUserId() -> String? {
        tokenStore.load().flatMap { JWT.userId($0) }
    }

    /// Transient renewal failure may use the old token only while its exact session is still current.
    public func validToken() async throws -> String? {
        try await validToken(for: captureSession())
    }

    private func validToken(for lease: SessionLease) async throws -> String? {
        try _Concurrency.Task.checkCancellation()
        guard let token = lease.token else { return nil }
        try requireCurrent(lease)
        guard JWT.expiresWithin(refreshSkew, of: token, now: now()) else { return token }
        do {
            return try await refresh(for: lease).token
        } catch {
            try _Concurrency.Task.checkCancellation()
            if error is CancellationError || error is AuthError { throw error }
            let canFallBack = sessionState.revision.withLock { revision in
                revision == lease.revision && tokenStore.load() == token &&
                    !JWT.expiresWithin(0, of: token, now: now())
            }
            if canFallBack { return token }
            throw error
        }
    }

    public func deleteAccountViaRoute() async throws {
        try await deleteAuthed(path: "/api/gsd/account", starting: captureSession())
    }

    /// Fallback after the caller has erased this account's remote tasks.
    public func deleteAccount() async throws {
        let lease = captureSession()
        guard let token = lease.token, let id = JWT.userId(token) else { throw AuthError.notSignedIn }
        try await deleteAuthed(path: "/api/collections/users/records/\(id)", starting: lease)
    }

    private func deleteAuthed(path: String, starting lease: SessionLease) async throws {
        guard lease.token.flatMap({ JWT.userId($0) }) != nil,
              let token = try await validToken(for: lease) else { throw AuthError.notSignedIn }
        let deletion = captureSession()
        guard deletion.revision == lease.revision, deletion.token == token else { throw AuthError.cancelled }
        try requireCurrent(deletion)
        do {
            try await client.sendNoContent(client.authedRequest(path: path, method: "DELETE", token: token))
            try replaceToken(nil, expecting: deletion)
        } catch {
            try requireCurrent(deletion)
            if Self.isAuthRejection(error) { try replaceToken(nil, expecting: deletion) }
            throw error
        }
    }

    /// A renewal belongs to the session used for its request, including its rejection path.
    @discardableResult
    public func refresh() async throws -> AuthResult {
        try await refresh(for: captureSession())
    }

    private func refresh(for lease: SessionLease) async throws -> AuthResult {
        guard let token = lease.token else { throw AuthError.notSignedIn }
        try requireCurrent(lease)
        do {
            let result = try await client.authRefresh(token: token)
            if let owner = JWT.userId(token) {
                guard result.record.id == owner, JWT.userId(result.token) == owner else {
                    throw AuthError.stateMismatch
                }
            }
            try replaceToken(result.token, expecting: lease)
            return result
        } catch {
            try requireCurrent(lease)
            if Self.isAuthRejection(error) { try replaceToken(nil, expecting: lease) }
            throw error
        }
    }

    private func captureSession(startingSignIn: Bool = false) -> SessionLease {
        sessionState.revision.withLock { revision in
            if startingSignIn { revision &+= 1 }
            return SessionLease(revision: revision, token: tokenStore.load())
        }
    }

    private func requireCurrent(_ lease: SessionLease) throws {
        try _Concurrency.Task.checkCancellation()
        try sessionState.revision.withLock { revision in
            guard revision == lease.revision, tokenStore.load() == lease.token else { throw AuthError.cancelled }
        }
    }

    private func replaceToken(_ token: String?, expecting lease: SessionLease,
                              advanceRevision: Bool = false) throws {
        try _Concurrency.Task.checkCancellation()
        try sessionState.revision.withLock { revision in
            guard revision == lease.revision, tokenStore.load() == lease.token else { throw AuthError.cancelled }
            if advanceRevision || token == nil { revision &+= 1 }
            if let token { tokenStore.save(token) } else { tokenStore.clear() }
        }
    }

    private static func isAuthRejection(_ error: Error) -> Bool {
        switch error {
        case PocketBaseError.http(let status, _), PocketBaseError.pocketBase(let status, _):
            status == 401 || status == 403
        default:
            false
        }
    }

    // MARK: helpers (internal — exercised via signIn; PROBE-VERIFIED)
    func buildAuthURL(_ base: String, redirectURI: String) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let enc = redirectURI.addingPercentEncoding(withAllowedCharacters: allowed) ?? redirectURI
        guard let url = URL(string: base + enc) else { throw AuthError.presentationFailed }
        return url
    }
    func parseCallback(_ url: URL) -> (code: String?, state: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (items.first { $0.name == "code" }?.value, items.first { $0.name == "state" }?.value)
    }
}
