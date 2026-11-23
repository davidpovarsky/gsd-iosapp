import Foundation
import Testing
@testable import GSDSync
@testable import GSDWire

struct CloudAccountAuthTests {
    final class Executor: RequestExecuting, @unchecked Sendable {
        var requests: [URLRequest] = []
        var rejectLogin = false
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let registration = request.url!.path.hasSuffix("/records")
            let status = rejectLogin && !registration ? 400 : 200
            let body = registration
                ? #"{"id":"account12345678","email":"test@example.invalid"}"#
                : (status == 200
                   ? #"{"token":"h.eyJpZCI6ImFjY291bnQxMjM0NTY3OCIsImV4cCI6OTk5OTk5OTk5OX0.s","record":{"id":"account12345678","email":"test@example.invalid"}}"#
                   : #"{"message":"Invalid credentials"}"#)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func service(_ executor: Executor, _ store: TokenStore) -> AuthService {
        AuthService(client: PocketBaseClient(baseURL: "https://cloud.example/gsd-cloud", executor: executor),
                    presenter: AuthServiceTests.FakePresenter(.failure(AuthError.cancelled)),
                    tokenStore: store, config: .live)
    }

    @Test func emailRegistrationAndLoginReuseTheOriginalSession() async throws {
        let executor = Executor(), tokens = AuthServiceTests.InMemoryTokenStore()
        let auth = service(executor, tokens)
        let result = try await auth.createAccountWithEmail("  Test@EXAMPLE.invalid  ", password: "long-test-password")
        #expect(executor.requests.count == 2)
        #expect(executor.requests[0].url?.path == "/gsd-cloud/api/collections/users/records")
        #expect(executor.requests[1].url?.path == "/gsd-cloud/api/collections/users/auth-with-password")
        let registration = try JSONDecoder().decode([String: String].self, from: #require(executor.requests[0].httpBody))
        #expect(registration["email"] == "test@example.invalid")
        #expect(registration["password"] == registration["passwordConfirm"])
        #expect(tokens.load() == result.token)
        #expect(auth.currentUserId() == "account12345678")
        auth.signOut()
        #expect(tokens.load() == nil)
    }

    @Test func rejectedCredentialsDoNotReplaceASavedSession() async throws {
        let executor = Executor(), tokens = AuthServiceTests.InMemoryTokenStore("existing")
        executor.rejectLogin = true
        await #expect(throws: PocketBaseError.self) {
            _ = try await service(executor, tokens).signInWithEmail("test@example.invalid", password: "wrong")
        }
        #expect(tokens.load() == "existing")
    }

    @Test func invalidRegistrationNeverSendsCredentials() async throws {
        let executor = Executor(), tokens = AuthServiceTests.InMemoryTokenStore()
        await #expect(throws: AuthError.invalidCredentials) {
            _ = try await service(executor, tokens).createAccountWithEmail("test@example.invalid", password: "short")
        }
        #expect(executor.requests.isEmpty)
        #expect(tokens.load() == nil)
    }
}
