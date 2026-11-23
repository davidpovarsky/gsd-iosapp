import AISDKProviderUtils
import CryptoKit
import Foundation
import HanlinChatCore
import Synchronization
import Testing
@testable import GSDHanlinAgent

/// Public-contract tests against the pinned ORIGINAL Hanlin SDK, without a real account.
@Suite(.serialized)
struct ChatGPTPlanContractTests: Sendable {
    private let hostID = "urn:uuid:eb92c371-d82f-4a97-9964-093a34c72122"
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstRegistrationAndSavedRegistrationUseDistinctOAuthContracts() throws {
        let first = try HanlinChatGPTPlanClient.makeAttempt(
            hostID: hostID, loopbackPort: 49152, appName: "GSD Tasks")
        let initial = try query(first.url)
        #expect(initial["client_id"] == "dynamic_agent_client")
        #expect(initial["agent_name_hint"] == "GSD Tasks")
        #expect(initial["redirect_uri"] == "http://127.0.0.1:49152/auth/callback")
        #expect(initial["resource"] == "https://api.openai.com/v1")
        #expect(initial["code_challenge_method"] == "S256")
        #expect(initial["code_challenge"] == base64URL(Data(SHA256.hash(data: Data(first.verifier.utf8)))))
        #expect(initial["prompt"] == nil)
        #expect(!first.state.isEmpty && !first.nonce.isEmpty)

        // A signed-out account retains its issued client mapping, without retaining tokens.
        let returning = try HanlinChatGPTPlanClient.makeAttempt(
            hostID: hostID, loopbackPort: 49153, appName: "GSD Tasks",
            clientID: "issued-gsd-client", emailHint: "fixture@example.invalid",
            requestPlanConsent: true)
        let saved = try query(returning.url)
        #expect(saved["client_id"] == "issued-gsd-client")
        #expect(saved["agent_name_hint"] == nil && saved["id_token_hint"] == nil)
        #expect(saved["login_hint"] == "fixture@example.invalid")
        #expect(saved["prompt"] == "consent")
        #expect(returning.state != first.state && returning.nonce != first.nonce)
    }

    @Test func callbackRejectsWrongStateDuplicateKeysAndDifferentRegistration() async throws {
        let attempt = try HanlinChatGPTPlanClient.makeAttempt(
            hostID: hostID, loopbackPort: 49152, clientID: "issued-gsd-client")
        let client = HanlinChatGPTPlanClient(session: stubSession { _ in
            Issue.record("Invalid callback reached the network")
            throw URLError(.badURL)
        })
        let queries = [
            "code=fixture&state=wrong",
            "code=fixture&state=\(attempt.state)&state=\(attempt.state)",
            "code=fixture&state=\(attempt.state)&client_id=another-client"
        ]
        for raw in queries {
            do {
                _ = try await client.exchange(
                    callback: URL(string: attempt.redirectURI.absoluteString + "?" + raw)!,
                    attempt: attempt)
                Issue.record("An invalid OAuth callback was accepted")
            } catch let error as HanlinChatGPTPlanError {
                switch error {
                case .invalidAuthorization, .invalidIdentity: break
                default: Issue.record("Unexpected callback error: \(error)")
                }
            }
        }
    }

    @Test func returningExchangeVerifiesSignatureNonceAndUsesGrantedScopes() async throws {
        let attempt = try HanlinChatGPTPlanClient.makeAttempt(
            hostID: hostID, loopbackPort: 49152, clientID: "issued-gsd-client")
        let signed = try signedIdentity(subject: "account-1", nonce: attempt.nonce)
        let body = try json([
            "access_token": "fixture-access", "refresh_token": "fixture-refresh",
            "id_token": signed.token, "expires_in": 3600, "scope": "openid profile email offline_access"
        ])
        let session = stubSession { request in
            if request.url?.path == "/.well-known/jwks.json" { return .init(data: signed.jwks) }
            #expect(try form(request)["client_id"] == "issued-gsd-client")
            #expect(try form(request)["code_verifier"] == attempt.verifier)
            return .init(data: body)
        }
        let client = HanlinChatGPTPlanClient(session: session, now: { [instant] in instant })
        // The issued client ID may be omitted on a returning callback.
        let callback = URL(string: attempt.redirectURI.absoluteString + "?code=fixture&state=" + attempt.state)!
        let account = try await client.exchange(callback: callback, attempt: attempt)
        #expect(account.clientID == "issued-gsd-client" && account.subject == "account-1")
        #expect(account.hostID == hostID && account.email == "fixture@example.invalid")
        #expect(!account.canUsePlan)
        #expect(account.expiresAt == instant.addingTimeInterval(3600))
    }

    @Test func refreshRotatesCredentialAndValidatesNewIdentity() async throws {
        let signed = try signedIdentity(subject: "account-1")
        let body = try json([
            "access_token": "rotated-access", "refresh_token": "rotated-refresh+suffix",
            "id_token": signed.token, "expires_in": 600,
            "earliest_refresh_at": instant.timeIntervalSince1970 + 450,
            "scope": "openid resource.invoke chatgpt.tokens.use.direct"
        ])
        let session = stubSession { request in
            if request.url?.path == "/.well-known/jwks.json" { return .init(data: signed.jwks) }
            let sent = try form(request)
            #expect(sent["grant_type"] == "refresh_token")
            #expect(sent["refresh_token"] == "fixture-refresh+suffix")
            #expect(sent["scope"] == nil)
            return .init(data: body)
        }
        let client = HanlinChatGPTPlanClient(session: session, now: { [instant] in instant })
        let updated = try await client.refresh(credentials())
        #expect(updated.accessToken == "rotated-access")
        #expect(updated.refreshToken == "rotated-refresh+suffix")
        #expect(updated.idToken == signed.token && updated.canUsePlan)
        #expect(updated.earliestRefreshAt == instant.addingTimeInterval(450))
        #expect(updated.expiresAt == instant.addingTimeInterval(600))
    }

    @Test func refreshRejectsSignedIdentityForDifferentSubject() async throws {
        let signed = try signedIdentity(subject: "different-account")
        let body = try json([
            "access_token": "rotated-access", "refresh_token": "rotated-refresh",
            "id_token": signed.token, "expires_in": 600
        ])
        let client = HanlinChatGPTPlanClient(session: stubSession { request in
            .init(data: request.url?.path == "/.well-known/jwks.json" ? signed.jwks : body)
        }, now: { [instant] in instant })
        do {
            _ = try await client.refresh(credentials())
            Issue.record("A refresh switched the account identity")
        } catch HanlinChatGPTPlanError.invalidIdentity {
            // Expected: the previously selected account must remain selected.
        }
    }

    @Test func refreshPreservesExactErrorDiagnosticsAndRequiresRotatedRefreshToken() async throws {
        let denied = Data(#"{"error":"invalid_grant","error_description":"not retained"}"#.utf8)
        let client = HanlinChatGPTPlanClient(session: stubSession { _ in
            .init(status: 400, headers: ["x-request-id": "request-refresh-fixture"], data: denied)
        })
        do {
            _ = try await client.refresh(credentials())
            Issue.record("A failed refresh was accepted")
        } catch HanlinChatGPTPlanError.oauth(let status, let code, let requestID) {
            #expect(status == 400 && code == "invalid_grant")
            #expect(requestID == "request-refresh-fixture")
        }
        let missing = try json(["access_token": "fixture-access", "expires_in": 600])
        let incomplete = HanlinChatGPTPlanClient(session: stubSession { _ in .init(data: missing) })
        do {
            _ = try await incomplete.refresh(credentials())
            Issue.record("A rotating session was accepted without its replacement refresh token")
        } catch HanlinChatGPTPlanError.invalidToken {}
    }

    @Test func revokeUsesDiscoveredEndpointAndAcceptsEmptySuccess() async throws {
        let discovery = try json([
            "issuer": "https://auth.openai.com",
            "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"
        ])
        let requests = Mutex<[String]>([])
        let session = stubSession { request in
            let path = request.url!.path
            requests.withLock { $0.append(path) }
            if path == "/.well-known/openid-configuration" { return .init(data: discovery) }
            #expect(path == "/api/accounts/oauth/revoke" && request.httpMethod == "POST")
            let values = try form(request)
            #expect(values["token"] == "fixture-refresh+suffix")
            #expect(values["token_type_hint"] == "refresh_token")
            #expect(values["client_id"] == "issued-gsd-client")
            return .init(data: Data())
        }
        try await HanlinChatGPTPlanClient(session: session).revoke(credentials())
        #expect(requests.withLock { $0.count } == 2)
    }

    @Test func revokeRejectsForeignDiscoveredEndpointBeforeSendingToken() async throws {
        let discovery = try json([
            "issuer": "https://auth.openai.com",
            "revocation_endpoint": "https://untrusted.example.invalid/revoke"
        ])
        let requests = Mutex(0)
        let client = HanlinChatGPTPlanClient(session: stubSession { _ in
            requests.withLock { $0 += 1 }
            return .init(data: discovery)
        })
        do {
            try await client.revoke(credentials())
            Issue.record("Revocation forwarded credentials to a foreign origin")
        } catch HanlinChatGPTPlanError.invalidAuthorization {}
        #expect(requests.withLock { $0 } == 1)
    }

    @Test func responsesRequestRetainsAll22ToolsUnderOfficialAdditionalToolsContract() throws {
        let tools: [[String: Any]] = try GSDHanlinToolCatalog.specs.map {
            ["type": "function", "name": $0.alias,
             "parameters": try JSONSerialization.jsonObject(with: $0.schemaJSON())]
        }
        let original = try request([
            "model": "fixture-model", "input": [["role": "system", "content": "Use the GSD tools."]],
            "tools": tools, "store": true, "stream": false, "max_output_tokens": 2048,
            "temperature": 0.7, "top_p": 0.8, "background": true, "metadata": ["fixture": "test"],
            "previous_response_id": "fixture-response", "service_tier": "auto"
        ])
        let prepared = try HanlinChatGPTPlanTransport.prepareRequest(original)
        let body = try #require(try JSONSerialization.jsonObject(with: prepared.httpBody!) as? [String: Any])
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        for key in ["max_output_tokens", "temperature", "top_p", "background", "metadata",
                    "previous_response_id", "service_tier", "tools"] {
            #expect(body[key] == nil)
        }
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.first?["type"] as? String == "additional_tools")
        #expect(input.first?["role"] as? String == "developer")
        #expect(input.last?["role"] as? String == "developer")
        let transferred = try #require(input.first?["tools"] as? [[String: Any]])
        #expect(transferred.count == 22)
        #expect(Set(transferred.compactMap { $0["name"] as? String }) ==
                Set(GSDHanlinToolCatalog.specs.map(\.alias)))
        #expect(prepared.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func responsesRouteAndUnsupportedToolsFailBeforeNetwork() async throws {
        let called = Mutex(0)
        let fetch = HanlinChatGPTPlanTransport.makeFetch { request in
            called.withLock { $0 += 1 }
            return .init(body: .none, urlResponse: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        for url in [
            "https://api.openai.com/v1/chat/completions",
            "https://example.invalid/v1/responses",
            "https://api.openai.com/v1/responses?relay=1"
        ] {
            var invalid = try request()
            invalid.url = URL(string: url)!
            do {
                _ = try await fetch(invalid)
                Issue.record("A plan credential reached an unsupported route")
            } catch HanlinChatGPTPlanTransportError.invalidRoute {}
        }
        let unsupported = try request(["input": "test", "tools": [["type": "mcp", "server_label": "fixture"]]])
        #expect(throws: HanlinChatGPTPlanTransportError.self) {
            try HanlinChatGPTPlanTransport.prepareRequest(unsupported)
        }
        #expect(called.withLock { $0 } == 0)
    }

    @Test func responsesHTTPFailuresPreserveCodeParameterAndRequestID() async throws {
        let body = Data(#"{"error":{"code":"insufficient_scope","param":"resource","message":"not retained"}}"#.utf8)
        let fetch = HanlinChatGPTPlanTransport.makeFetch { request in
            .init(body: .data(body), urlResponse: HTTPURLResponse(
                url: request.url!, statusCode: 403, httpVersion: nil,
                headerFields: ["x-request-id": "request-response-fixture"])!)
        }
        do {
            _ = try await fetch(request())
            Issue.record("A plan admission error was accepted")
        } catch HanlinChatGPTPlanTransportError.response(let diagnostic) {
            #expect(diagnostic.status == 403 && diagnostic.code == "insufficient_scope")
            #expect(diagnostic.parameter == "resource" && diagnostic.requestID == "request-response-fixture")
            #expect(diagnostic.bodyShape == "error")
        }
    }

    @Test func streamRequiresCompletedAndRejectsLateFailureOrInterruptedText() async throws {
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        // Fragment at arbitrary byte boundaries; validation must not change provider bytes.
        let successBytes = Data((delta + completed).utf8)
        let success = streamFetch(chunks: [
            Data(successBytes.prefix(9)), Data(successBytes.dropFirst(9).prefix(24)),
            Data(successBytes.dropFirst(33))
        ])
        let successResponse = try await success(request())
        #expect(try await successResponse.body.collectData() == successBytes)
        let interrupted = streamFetch(chunks: [Data(delta.utf8)])
        do {
            let response = try await interrupted(request())
            _ = try await response.body.collectData()
            Issue.record("Partial text without response.completed was treated as success")
        } catch HanlinChatGPTPlanTransportError.incompleteStream {}
        for terminal in ["response.failed", "response.incomplete", "error"] {
            let event = "data: {\"type\":\"\(terminal)\",\"error\":{\"code\":\"rate_limit_exceeded\"}}\n\n"
            let failed = streamFetch(chunks: [Data(delta.utf8), Data(event.utf8)])
            do {
                let response = try await failed(request())
                _ = try await response.body.collectData()
                Issue.record("A late \(terminal) event was treated as success")
            } catch HanlinChatGPTPlanTransportError.response(let diagnostic) {
                #expect(diagnostic.code == "rate_limit_exceeded")
                #expect(diagnostic.requestID == "stream-fixture")
            }
        }
    }


    @Test @MainActor
    func originalEngineAdvertises22ToolsWithoutBypassingHostExecution() async throws {
        let seen = Mutex<Set<String>>([])
        let executionCount = Mutex(0)
        let fetchCount = Mutex(0)
        let definitions = try GSDHanlinToolCatalog.specs.map { spec in
            HanlinAISDKToolDefinition(
                name: spec.alias, description: spec.summary, inputSchemaData: try spec.schemaJSON(),
                execute: { _, _ in
                    executionCount.withLock { $0 += 1 }
                    return .init(modelText: "Fixture should never execute", isError: true)
                }, requiresApproval: spec.writes)
        }
        let configuration = HanlinChatModelConfiguration(
            modelID: "fixture-model", company: "OpenAI", apiType: "openai-responses",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            apiKey: "fixture-plan-access", supportsToolUse: true)
        // Inject only the physical transport. The original engine must select the
        // canonical plan adapter itself, including for per-turn fetch overrides.
        let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
            fetchCount.withLock { $0 += 1 }
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
            #expect(body["max_output_tokens"] == nil && body["tools"] == nil)
            let input = try #require(body["input"] as? [[String: Any]])
            let tools = input.filter { $0["type"] as? String == "additional_tools" }
                .flatMap { $0["tools"] as? [[String: Any]] ?? [] }
            seen.withLock { $0 = Set(tools.compactMap { $0["name"] as? String }) }
            // Stop after inspecting the real provider request; no credentials leave the test.
            throw URLError(.cancelled)
        })
        do {
            let stream = try await engine.stream(
                messages: [.init(role: .user, text: "List my tasks")],
                baseSystemPrompt: "Use the advertised GSD tools.", tools: definitions,
                maxSteps: 1, prepareStep: {
                    .init(activeToolAliases: GSDHanlinToolCatalog.specs.map(\.alias))
                })
            for try await _ in stream {}
        } catch {
            // Cancellation is deliberate. Assertions below verify real request construction.
        }
        #expect(fetchCount.withLock { $0 } == 1)
        #expect(seen.withLock { $0 } == Set(GSDHanlinToolCatalog.specs.map(\.alias)))
        #expect(executionCount.withLock { $0 } == 0)
    }

    private func credentials() -> HanlinChatGPTPlanCredentials {
        .init(clientID: "issued-gsd-client", hostID: hostID, subject: "account-1",
              email: "fixture@example.invalid", idToken: "previous-fixture-id",
              accessToken: "fixture-access", refreshToken: "fixture-refresh+suffix",
              scopes: ["openid"], expiresAt: instant.addingTimeInterval(60))
    }

    private func signedIdentity(subject: String, nonce: String? = nil) throws -> (token: String, jwks: Data) {
        let key = P256.Signing.PrivateKey()
        var claims: [String: Any] = [
            "iss": "https://auth.openai.com", "sub": subject, "aud": "issued-gsd-client",
            "exp": instant.timeIntervalSince1970 + 3600, "email_verified": true,
            "email": "fixture@example.invalid"
        ]
        if let nonce { claims["nonce"] = nonce }
        let header = base64URL(try json(["alg": "ES256", "kid": "fixture-signing-key"]))
        let payload = base64URL(try json(claims))
        let signingInput = header + "." + payload
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        let publicBytes = key.publicKey.x963Representation
        let jwks = try json(["keys": [[
            "kid": "fixture-signing-key", "kty": "EC", "alg": "ES256", "crv": "P-256",
            "x": base64URL(Data(publicBytes[1..<33])), "y": base64URL(Data(publicBytes[33..<65]))
        ]]])
        return (signingInput + "." + base64URL(signature), jwks)
    }
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func base64URL(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func query(_ url: URL) throws -> [String: String] {
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private func form(_ request: URLRequest) throws -> [String: String] {
    var bytes = request.httpBody ?? Data()
    if bytes.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    // Application/x-www-form-urlencoded treats raw + as space; the SDK must escape token +.
    let encoded = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
    return try query(#require(URL(string: "https://fixture.invalid/?" + encoded)))
}

private func request(_ body: [String: Any] = ["model": "fixture-model", "input": "test"]) throws -> URLRequest {
    var value = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    value.httpMethod = "POST"
    value.httpBody = try json(body)
    return value
}

private func streamFetch(chunks: [Data]) -> FetchFunction {
    HanlinChatGPTPlanTransport.makeFetch { request in
        .init(body: .stream(AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: [
                "Content-Type": "text/event-stream; charset=utf-8", "x-request-id": "stream-fixture"
            ])!)
    }
}

private struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    let data: Data
}

/// URLSession injection exercises the real shared client's request/verification paths.
private final class PlanURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> StubResponse
    static let handler = Mutex<Handler?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handle = try PlanURLProtocol.handler.withLock { try #require($0) }
            let result = try handle(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status,
                                           httpVersion: nil, headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubSession(_ handler: @escaping PlanURLProtocol.Handler) -> URLSession {
    PlanURLProtocol.handler.withLock { $0 = handler }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PlanURLProtocol.self]
    return URLSession(configuration: configuration)
}
