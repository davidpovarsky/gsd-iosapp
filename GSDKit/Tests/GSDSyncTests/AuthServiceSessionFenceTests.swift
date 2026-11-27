import Testing
import Foundation
import Synchronization
@testable import GSDSync
@testable import GSDWire

@Suite(.timeLimit(.minutes(1)))
struct AuthServiceSessionFenceTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000_000)
    private static let authBase = "https://fixture.invalid"
    private static let password = "fixture-password-only"

    @Test func refreshAfterSignOutCannotRestoreSession() async throws {
        try await refreshRace(signOut: true)
    }

    @Test func refreshAfterAccountReplacementCannotOverwriteNewSession() async throws {
        try await refreshRace()
    }

    @Test func staleRefreshRejectionCannotClearNewSession() async throws {
        try await refreshRace(status: 401)
    }

    @Test func validTokenCannotReturnOldAccountAfterTransientFailure() async throws {
        try await refreshRace(status: 500, viaValidToken: true)
    }

    @Test func validTokenCannotReturnLateRefreshedAccount() async throws {
        try await refreshRace(viaValidToken: true)
    }

    @Test func passwordSignInAfterSignOutCannotRestoreSession() async throws {
        try await signInAfterSignOut(.password)
    }

    @Test func registrationAfterSignOutCannotRestoreSession() async throws {
        try await signInAfterSignOut(.registration)
    }

    @Test func oauthSignInAfterSignOutCannotRestoreSession() async throws {
        try await signInAfterSignOut(.oauth)
    }

    @Test func latestPasswordAttemptOwnsTheSession() async throws {
        let store = MemoryTokenStore()
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let first = login(service, .password)
        _ = await executor.waitForPending(0)
        let second = login(service, .password)
        _ = await executor.waitForPending(1)
        let replacement = token("account-b")
        try await executor.respond(1, body: response("account-b", token: replacement))
        #expect(await second.value)
        try await executor.respond(0, body: response("account-a", token: token("account-a")))
        #expect(await first.value == false)
        #expect(store.load() == replacement)
    }

    @Test func confirmedDeleteCannotClearNewSession() async throws {
        try await deletionRace(status: 204)
    }

    @Test func rejectedDeleteCannotClearNewSession() async throws {
        try await deletionRace(status: 403)
    }

    @Test func deleteCannotContinueAfterRefreshCrossesAccount() async throws {
        let original = token("account-a", secondsLeft: 30)
        let replacement = token("account-b")
        let store = MemoryTokenStore(original)
        let executor = PausedExecutor(automaticDeletes: true)
        let service = makeService(store, executor)
        let operation = _Concurrency.Task {
            do { try await service.deleteAccount(); return true } catch { return false }
        }
        let request = await executor.waitForPending(0)
        #expect(request.url?.path.hasSuffix("auth-refresh") == true)
        store.save(replacement)
        try await executor.respond(0, body: response("account-a", token: token("account-a")))
        #expect(await operation.value == false)
        #expect(await executor.deleteCount() == 0)
        #expect(store.load() == replacement)
    }

    @Test func sameTokenReauthenticationInvalidatesOldRefresh() async throws {
        let original = token("account-a", secondsLeft: 30)
        let store = MemoryTokenStore(original)
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let oldRefresh = _Concurrency.Task {
            do { _ = try await service.refresh(); return true } catch { return false }
        }
        _ = await executor.waitForPending(0)
        service.signOut()
        let newLogin = login(service, .password)
        _ = await executor.waitForPending(1)
        try await executor.respond(1, body: response("account-a", token: original))
        #expect(await newLogin.value)
        try await executor.respond(0, body: response("account-a", token: token("account-a")))
        #expect(await oldRefresh.value == false)
        #expect(store.load() == original)
    }

    @Test func serviceCopiesShareSignOutFence() async throws {
        let store = MemoryTokenStore()
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let copy = service
        let operation = login(service, .password)
        _ = await executor.waitForPending(0)
        copy.signOut()
        try await executor.respond(0, body: response("account-a", token: token("account-a")))
        #expect(await operation.value == false)
        #expect(store.load() == nil)
    }

    @Test func cancelledPasswordSignInCannotSave() async throws {
        let store = MemoryTokenStore()
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let operation = login(service, .password)
        _ = await executor.waitForPending(0)
        operation.cancel()
        try await executor.respond(0, body: response("account-a", token: token("account-a")))
        #expect(await operation.value == false)
        #expect(store.load() == nil)
    }

    @Test func cancelledValidTokenCannotFallBackAfterRefresh() async throws {
        let original = token("account-a", secondsLeft: 30)
        let store = MemoryTokenStore(original)
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let operation = _Concurrency.Task {
            do { _ = try await service.validToken(); return true } catch { return false }
        }
        _ = await executor.waitForPending(0)
        operation.cancel()
        try await executor.respond(0, body: Data(), status: 500)
        #expect(await operation.value == false)
        #expect(store.load() == original)
    }

    @Test func refreshRejectsMismatchedAccountResponse() async throws {
        let original = token("account-a", secondsLeft: 30)
        let store = MemoryTokenStore(original)
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let operation = _Concurrency.Task {
            do { _ = try await service.refresh(); return true } catch { return false }
        }
        _ = await executor.waitForPending(0)
        try await executor.respond(0, body: response("account-b", token: token("account-b")))
        #expect(await operation.value == false)
        #expect(store.load() == original)
    }

    private func refreshRace(status: Int = 200, signOut: Bool = false,
                             viaValidToken: Bool = false) async throws {
        let original = token("account-a", secondsLeft: 30)
        let replacement = token("account-b")
        let store = MemoryTokenStore(original)
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let operation = _Concurrency.Task {
            do {
                if viaValidToken { _ = try await service.validToken() }
                else { _ = try await service.refresh() }
                return true
            } catch { return false }
        }
        let request = await executor.waitForPending(0)
        #expect(request.value(forHTTPHeaderField: "Authorization") == original)
        if signOut { service.signOut() } else { store.save(replacement) }
        try await executor.respond(0, body: response("account-a", token: token("account-a")), status: status)
        #expect(await operation.value == false)
        #expect(store.load() == (signOut ? nil : replacement))
    }

    private enum LoginKind: Sendable { case password, registration, oauth }

    private func signInAfterSignOut(_ kind: LoginKind) async throws {
        let store = MemoryTokenStore()
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let operation = login(service, kind)
        _ = await executor.waitForPending(0)
        service.signOut()
        try await executor.respond(0, body: response("account-a", token: token("account-a")))
        #expect(await operation.value == false)
        #expect(store.load() == nil)
    }

    private func deletionRace(status: Int) async throws {
        let original = token("account-a")
        let replacement = token("account-b")
        let store = MemoryTokenStore(original)
        let executor = PausedExecutor()
        let service = makeService(store, executor)
        let operation = _Concurrency.Task {
            do { try await service.deleteAccountViaRoute(); return true } catch { return false }
        }
        let request = await executor.waitForPending(0)
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "Authorization") == original)
        store.save(replacement)
        try await executor.respond(0, body: Data(), status: status)
        #expect(await operation.value == false)
        #expect(store.load() == replacement)
    }

    private func login(_ service: AuthService, _ kind: LoginKind) -> _Concurrency.Task<Bool, Never> {
        _Concurrency.Task {
            do {
                switch kind {
                case .password:
                    _ = try await service.signInWithEmail("fixture@example.invalid", password: Self.password)
                case .registration:
                    _ = try await service.createAccountWithEmail("fixture@example.invalid", password: Self.password)
                case .oauth:
                    _ = try await service.signIn(provider: "fixture")
                }
                return true
            } catch { return false }
        }
    }

    private func makeService(_ store: TokenStore, _ executor: RequestExecuting) -> AuthService {
        AuthService(client: PocketBaseClient(baseURL: Self.authBase, executor: executor),
                    presenter: LocalPresenter(), tokenStore: store,
                    config: AuthConfig(baseURL: Self.authBase, redirectURI: "gsd://callback", callbackScheme: "gsd"),
                    now: { Self.now })
    }

    private func token(_ id: String, secondsLeft: Int = 2_000_000_000) -> String {
        let expiry = Int(Self.now.timeIntervalSince1970) + secondsLeft
        let payload = Data("{\"id\":\"\(id)\",\"exp\":\(expiry)}".utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).fixture"
    }

    private func response(_ id: String, token: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "token": token, "record": ["id": id, "email": "\(id)@example.invalid"]
        ])
    }

    private struct LocalPresenter: WebAuthPresenting {
        func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
            #expect(authURL.host == "fixture.invalid")
            return try #require(URL(string: "gsd://callback?code=fixture-code&state=fixture-state"))
        }
    }

    private final class MemoryTokenStore: TokenStore {
        private let value: Mutex<String?>
        init(_ token: String? = nil) { value = Mutex(token) }
        func load() -> String? { value.withLock { $0 } }
        func save(_ token: String) { value.withLock { $0 = token } }
        func clear() { value.withLock { $0 = nil } }
    }

    private actor PausedExecutor: RequestExecuting {
        private let automaticDeletes: Bool
        private var requests: [URLRequest] = []
        private var pending: [URLRequest] = []
        private var replies: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
        private var waiters: [Int: [CheckedContinuation<URLRequest, Never>]] = [:]

        init(automaticDeletes: Bool = false) { self.automaticDeletes = automaticDeletes }

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            #expect(request.url?.host == "fixture.invalid")
            requests.append(request)
            if request.url?.path.hasSuffix("auth-methods") == true {
                let provider: [String: String] = [
                    "name": "fixture", "displayName": "Fixture", "state": "fixture-state",
                    "authURL": "https://fixture.invalid/authorize?redirect_uri=",
                    "codeVerifier": "fixture-verifier", "codeChallenge": "fixture-challenge",
                    "codeChallengeMethod": "S256"
                ]
                let data = try JSONSerialization.data(withJSONObject: ["oauth2": ["providers": [provider]]])
                return (data, try http(request, 200))
            }
            if request.httpMethod == "POST" && request.url?.path.hasSuffix("/users/records") == true {
                return (Data(#"{"id":"created-fixture-account"}"#.utf8), try http(request, 200))
            }
            if automaticDeletes && request.httpMethod == "DELETE" {
                return (Data(), try http(request, 204))
            }
            let index = pending.count
            pending.append(request)
            return try await withCheckedThrowingContinuation { continuation in
                replies[index] = continuation
                for waiter in waiters.removeValue(forKey: index) ?? [] { waiter.resume(returning: request) }
            }
        }

        func waitForPending(_ index: Int) async -> URLRequest {
            if pending.indices.contains(index) { return pending[index] }
            return await withCheckedContinuation { waiters[index, default: []].append($0) }
        }

        func respond(_ index: Int, body: Data, status: Int = 200) throws {
            let pendingReply = replies.removeValue(forKey: index)
            let reply = try #require(pendingReply)
            reply.resume(returning: (body, try http(pending[index], status)))
        }

        func deleteCount() -> Int { requests.filter { $0.httpMethod == "DELETE" }.count }

        private func http(_ request: URLRequest, _ status: Int) throws -> HTTPURLResponse {
            let url = try #require(request.url)
            return try #require(HTTPURLResponse(url: url, statusCode: status,
                                        httpVersion: nil, headerFields: nil))
        }
    }
}
