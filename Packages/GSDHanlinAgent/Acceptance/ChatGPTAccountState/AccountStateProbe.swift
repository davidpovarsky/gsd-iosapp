import CryptoKit
import Foundation
import HanlinChatCore

private struct FixtureReply: Sendable { let status: Int; let data: Data }

private actor FixtureNetwork {
    let fence: GSDChatGPTLocalSignOutStore
    private let signingKey = P256.Signing.PrivateKey()
    private var attempt: HanlinChatGPTAuthorizationAttempt?
    private var refreshGate: CheckedContinuation<FixtureReply, Never>?
    var holdRefresh = false
    private(set) var requestCount = 0
    private(set) var revokeCount = 0
    private(set) var refreshCount = 0
    private(set) var firstRequestWasFenced: Bool?
    private(set) var revokedRotatedToken = false

    init(fence: GSDChatGPTLocalSignOutStore) { self.fence = fence }

    func setHoldRefresh() { holdRefresh = true }

    func authorize(_ value: HanlinChatGPTAuthorizationAttempt) -> URL {
        attempt = value
        var callback = URLComponents(url: value.redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            .init(name: "state", value: value.state), .init(name: "code", value: "fixture-code"),
            .init(name: "client_id", value: value.clientID == "dynamic_agent_client" ? "fixture-client-a" : value.clientID)
        ]
        return callback.url!
    }

    private func json(_ value: [String: Any], status: Int = 200) -> FixtureReply {
        FixtureReply(status: status, data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }

    private func fields(_ request: URLRequest) -> [String: String] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && body.count < 65_536 {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        guard let text = String(data: body, encoding: .utf8) else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary((components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func token(rotated: Bool) -> FixtureReply {
        var value: [String: Any] = [
            "access_token": rotated ? "fixture-rotated-access" : "fixture-auth-access",
            "refresh_token": rotated ? "fixture-rotated-refresh" : "fixture-auth-refresh",
            "token_type": "Bearer", "expires_in": 3600,
            "scope": "openid resource.invoke chatgpt.tokens.use.direct"
        ]
        if !rotated, let attempt {
            let clientID = attempt.clientID == "dynamic_agent_client" ? "fixture-client-a" : attempt.clientID
            let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "fixture-key"])
            let payload = try! JSONSerialization.data(withJSONObject: [
                "iss": "https://auth.openai.com", "sub": "fixture-subject-a", "aud": clientID,
                "nonce": attempt.nonce, "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
                "email_verified": true, "email": "fixture-a@example.invalid"
            ])
            let signed = header.fixtureBase64URL + "." + payload.fixtureBase64URL
            let signature = try! signingKey.signature(for: Data(signed.utf8)).rawRepresentation
            value["id_token"] = signed + "." + signature.fixtureBase64URL
        }
        return json(value)
    }

    func releaseRefresh() {
        refreshGate?.resume(returning: token(rotated: true))
        refreshGate = nil
    }

    func response(_ request: URLRequest) async -> FixtureReply {
        requestCount += 1
        if firstRequestWasFenced == nil {
            firstRequestWasFenced = (try? fence.deniedRegistrationHashes()
                .contains(GSDChatGPTLocalSignOutStore.registrationHash("fixture-client-a"))) == true
        }
        guard let url = request.url, let host = url.host,
              ["auth.openai.com", "api.openai.com"].contains(host) else {
            return json(["error": "fixture_unexpected_host"], status: 400)
        }
        switch url.path {
        case "/.well-known/openid-configuration":
            return json(["issuer": "https://auth.openai.com", "revocation_endpoint": "https://auth.openai.com/fixture/revoke"])
        case "/fixture/revoke":
            revokeCount += 1
            revokedRotatedToken = revokedRotatedToken || fields(request)["token"] == "fixture-rotated-refresh"
            return json(["error": "fixture_revoke_failure"], status: 400)
        case "/v1/models":
            return json(["models": [["slug": "fixture-model", "display_name": "Fixture", "visibility": "list"]]])
        case "/api/accounts/oauth/token":
            if fields(request)["grant_type"] == "refresh_token" {
                refreshCount += 1
                if holdRefresh {
                    return await withCheckedContinuation { refreshGate = $0 }
                }
                return token(rotated: true)
            }
            return token(rotated: false)
        case "/.well-known/jwks.json":
            let key = signingKey.publicKey.x963Representation
            return json(["keys": [["kty": "EC", "crv": "P-256", "alg": "ES256", "kid": "fixture-key",
                                    "x": key.subdata(in: 1..<33).fixtureBase64URL,
                                    "y": key.subdata(in: 33..<65).fixtureBase64URL]]])
        default:
            return json(["error": "fixture_unexpected_route"], status: 400)
        }
    }
}

private final class ProtocolRouting: @unchecked Sendable {
    private let lock = NSLock()
    private var backend: FixtureNetwork?
    func install(_ value: FixtureNetwork) { lock.lock(); defer { lock.unlock() }; backend = value }
    func current() -> FixtureNetwork? { lock.lock(); defer { lock.unlock() }; return backend }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let routing = ProtocolRouting()
    private var operation: _Concurrency.Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let backend = Self.routing.current() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let request = request
        operation = _Concurrency.Task { [weak self] in
            let reply = await backend.response(request)
            guard let self, !_Concurrency.Task.isCancelled,
                  let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                                 httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { operation?.cancel() }
}

private extension Data {
    var fixtureBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor private final class FixtureKeychain {
    enum Failure: Error { case locked, writeFailed }
    var snapshot: GSDChatGPTSnapshot?
    var failLoad = false
    var failSave = false
    private(set) var reads = 0
    init(_ snapshot: GSDChatGPTSnapshot) { self.snapshot = snapshot }
    func load() throws -> GSDChatGPTSnapshot? {
        reads += 1
        if failLoad { throw Failure.locked }
        return snapshot
    }
    func save(_ value: GSDChatGPTSnapshot) throws {
        if failSave { throw Failure.writeFailed }
        snapshot = value
    }
}

@main private struct AccountStateProbe {
    @MainActor static var failures = 0
    static let host = "urn:uuid:22222222-2222-4222-8222-222222222222"

    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("CHATGPT_ACCOUNT_CHECK " + String(decoding: data, as: UTF8.self))
    }

    static func credential(_ suffix: String = "a", expired: Bool = false) -> HanlinChatGPTPlanCredentials {
        .init(clientID: "fixture-client-" + suffix, hostID: host, subject: "fixture-subject-" + suffix,
              email: "fixture-" + suffix + "@example.invalid", idToken: "fixture-id-token-" + suffix,
              accessToken: "fixture-access-" + suffix, refreshToken: "fixture-refresh-" + suffix,
              scopes: ["openid", "resource.invoke", "chatgpt.tokens.use.direct"],
              expiresAt: Date().addingTimeInterval(expired ? -1 : 3600))
    }

    static func snapshot(twoAccounts: Bool = false, expired: Bool = false) -> GSDChatGPTSnapshot {
        let values = twoAccounts ? [credential("a", expired: expired), credential("b")] : [credential(expired: expired)]
        return .init(hostID: host, accounts: values.map(GSDChatGPTRegistration.init), activeID: "fixture-client-a")
    }

    @MainActor static func state(_ keychain: FixtureKeychain, fence: GSDChatGPTLocalSignOutStore,
                                network: FixtureNetwork) -> GSDChatGPTAccountState {
        FixtureURLProtocol.routing.install(network)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let client = HanlinChatGPTPlanClient(session: URLSession(configuration: configuration))
        return GSDChatGPTAccountState(client: client, loadSnapshot: keychain.load,
                                     saveSnapshot: keychain.save, localSignOutStore: fence)
    }

    @MainActor static func run(root: URL) async throws {
        func fence(_ name: String) -> GSDChatGPTLocalSignOutStore {
            .init(directory: root.appendingPathComponent(name))
        }

        let failedStore = fence("failed-keychain-clear")
        let failedKeychain = FixtureKeychain(snapshot())
        failedKeychain.failSave = true
        let failedNetwork = FixtureNetwork(fence: failedStore)
        let failed = state(failedKeychain, fence: failedStore, network: failedNetwork)
        await failed.signOut()
        let reloaded = state(failedKeychain, fence: failedStore, network: failedNetwork)
        check("logout_survives_revoke_and_keychain_failure", !failed.canUsePlan && !reloaded.canUsePlan
              && reloaded.accounts.first?.signedIn == false && failedKeychain.snapshot?.accounts.first?.credentials != nil)
        let revokeCount = await failedNetwork.revokeCount
        let fencedBeforeNetwork = await failedNetwork.firstRequestWasFenced
        check("signout_fence_precedes_remote_requests", revokeCount == 2 && fencedBeforeNetwork == true)
        let bytes = try? Data(contentsOf: failedStore.directory.appendingPathComponent(GSDChatGPTLocalSignOutStore.fileName))
        let text = bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let expectedHash = GSDChatGPTLocalSignOutStore.registrationHash("fixture-client-a")
        check("fence_contains_only_hashed_registration", text.contains(expectedHash)
              && !text.contains("fixture-client") && !text.contains("fixture-subject")
              && !text.contains("fixture-refresh") && !text.contains("fixture-access") && !text.contains("@example.invalid"))

        let recoveryStore = fence("unlock-recovery")
        let recoveryKeychain = FixtureKeychain(snapshot())
        recoveryKeychain.failLoad = true
        let recoveryNetwork = FixtureNetwork(fence: recoveryStore)
        let recovery = state(recoveryKeychain, fence: recoveryStore, network: recoveryNetwork)
        let initiallyUnavailable = !recovery.canUsePlan
        recoveryKeychain.failLoad = false
        await recovery.loadModels()
        check("reopening_recovers_initial_keychain_failure", initiallyUnavailable && recovery.canUsePlan
              && recovery.activeID == "fixture-client-a" && recovery.models.count == 1 && recoveryKeychain.reads == 2)

        let deniedStore = fence("unlock-with-fence")
        try deniedStore.markSignedOut("fixture-client-a")
        let deniedKeychain = FixtureKeychain(snapshot())
        deniedKeychain.failLoad = true
        let deniedNetwork = FixtureNetwork(fence: deniedStore)
        let denied = state(deniedKeychain, fence: deniedStore, network: deniedNetwork)
        deniedKeychain.failLoad = false
        await denied.loadModels()
        let deniedRequests = await deniedNetwork.requestCount
        check("storage_retry_preserves_signout_fence", !denied.canUsePlan && denied.activeID == "fixture-client-a"
              && denied.accounts.first?.signedIn == false && deniedRequests == 0 && deniedKeychain.reads == 2)

        let separatedStore = fence("registration-separation")
        let separatedKeychain = FixtureKeychain(snapshot(twoAccounts: true))
        separatedKeychain.failSave = true
        let separatedNetwork = FixtureNetwork(fence: separatedStore)
        let separated = state(separatedKeychain, fence: separatedStore, network: separatedNetwork)
        await separated.signOut()
        separatedKeychain.failSave = false
        separated.selectAccount("fixture-client-b")
        let separatedReload = state(separatedKeychain, fence: separatedStore, network: separatedNetwork)
        check("signout_isolated_to_registration", separatedReload.activeID == "fixture-client-b"
              && separatedReload.canUsePlan
              && separatedReload.accounts.first(where: { $0.id == "fixture-client-a" })?.signedIn == false
              && separatedReload.accounts.first(where: { $0.id == "fixture-client-b" })?.signedIn == true)

        let blockedURL = root.appendingPathComponent("blocked-fence-directory")
        let blockedStore = GSDChatGPTLocalSignOutStore(directory: blockedURL)
        let blockedKeychain = FixtureKeychain(snapshot())
        blockedKeychain.failSave = true
        let blockedNetwork = FixtureNetwork(fence: blockedStore)
        let blocked = state(blockedKeychain, fence: blockedStore, network: blockedNetwork)
        // Fault the write after successful initialization, independently of read-error handling.
        try Data("not a directory".utf8).write(to: blockedURL)
        await blocked.signOut()
        let blockedRequests = await blockedNetwork.requestCount
        check("both_storage_failures_report_failure_without_remote_work", !blocked.canUsePlan && !blocked.isBusy
              && blockedRequests == 0 && blockedKeychain.snapshot?.accounts.first?.credentials != nil
              && blocked.status == "The device could not save the ChatGPT sign-out. Please try again.")

        let corruptStore = fence("corrupt-fence")
        try FileManager.default.createDirectory(at: corruptStore.directory, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: corruptStore.directory.appendingPathComponent(GSDChatGPTLocalSignOutStore.fileName))
        let corruptKeychain = FixtureKeychain(snapshot())
        let corruptNetwork = FixtureNetwork(fence: corruptStore)
        let corrupt = state(corruptKeychain, fence: corruptStore, network: corruptNetwork)
        await corrupt.loadModels()
        let corruptRequests = await corruptNetwork.requestCount
        check("corrupt_fence_fails_closed", !corrupt.canUsePlan && corruptRequests == 0)

        failedKeychain.failSave = false
        let cleanup = state(failedKeychain, fence: failedStore, network: failedNetwork)
        await cleanup.signOut()
        let cleanupReload = state(failedKeychain, fence: failedStore, network: failedNetwork)
        check("repeated_logout_can_finish_keychain_cleanup", !cleanupReload.canUsePlan
              && failedKeychain.snapshot?.accounts.first?.credentials == nil && !cleanup.isBusy)

        let signInStore = fence("verified-signin")
        try signInStore.markSignedOut("fixture-client-a")
        try signInStore.markSignedOut("fixture-client-b")
        let signInKeychain = FixtureKeychain(snapshot(twoAccounts: true))
        let signInNetwork = FixtureNetwork(fence: signInStore)
        let signingIn = state(signInKeychain, fence: signInStore, network: signInNetwork)
        let deniedBeforeSignIn = !signingIn.canUsePlan
        GSDChatGPTAuthorization.callback = { await signInNetwork.authorize($0) }
        await signingIn.signIn(accountID: "fixture-client-a")
        GSDChatGPTAuthorization.callback = nil
        let signInHashes = try signInStore.deniedRegistrationHashes()
        let signedInReload = state(signInKeychain, fence: signInStore, network: signInNetwork)
        check("verified_signin_clears_only_current_fence", deniedBeforeSignIn && signingIn.canUsePlan
              && signedInReload.canUsePlan && !signInHashes.contains(expectedHash)
              && signInHashes.contains(GSDChatGPTLocalSignOutStore.registrationHash("fixture-client-b"))
              && signedInReload.accounts.first(where: { $0.id == "fixture-client-b" })?.signedIn == false)

        let rejectedStore = fence("failed-signin-save")
        try rejectedStore.markSignedOut("fixture-client-a")
        let rejectedKeychain = FixtureKeychain(snapshot())
        rejectedKeychain.failSave = true
        let rejectedNetwork = FixtureNetwork(fence: rejectedStore)
        let rejected = state(rejectedKeychain, fence: rejectedStore, network: rejectedNetwork)
        GSDChatGPTAuthorization.callback = { await rejectedNetwork.authorize($0) }
        await rejected.signIn(accountID: "fixture-client-a")
        GSDChatGPTAuthorization.callback = nil
        let rejectedHashes = try rejectedStore.deniedRegistrationHashes()
        check("failed_signin_save_preserves_fence", !rejected.canUsePlan
              && rejectedHashes.contains(expectedHash)
              && rejectedKeychain.snapshot?.accounts.first?.credentials?.refreshToken == "fixture-refresh-a")

        let rotatingStore = fence("refresh-race")
        let rotatingKeychain = FixtureKeychain(snapshot(expired: true))
        rotatingKeychain.failSave = true
        let rotatingNetwork = FixtureNetwork(fence: rotatingStore)
        await rotatingNetwork.setHoldRefresh()
        let rotating = state(rotatingKeychain, fence: rotatingStore, network: rotatingNetwork)
        let inference = _Concurrency.Task { @MainActor in try await rotating.accessForInference() }
        for _ in 0..<200 {
            if await rotatingNetwork.refreshCount > 0 { break }
            try await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        let refreshStarted = await rotatingNetwork.refreshCount == 1
        let signingOut = _Concurrency.Task { @MainActor in await rotating.signOut() }
        for _ in 0..<200 {
            if rotating.isBusy { break }
            try await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        let deniedBeforeRefreshCompletes = rotating.isBusy && !rotating.canUsePlan
        await rotatingNetwork.releaseRefresh()
        await signingOut.value
        let staleInferenceFailed: Bool
        switch await inference.result {
        case .success: staleInferenceFailed = false
        case .failure: staleInferenceFailed = true
        }
        let rotatingReload = state(rotatingKeychain, fence: rotatingStore, network: rotatingNetwork)
        let revokedRotated = await rotatingNetwork.revokedRotatedToken
        check("refresh_after_signout_cannot_restore_credentials", refreshStarted && deniedBeforeRefreshCompletes
              && staleInferenceFailed && !rotatingReload.canUsePlan && revokedRotated)
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDAccountProbe-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await run(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            // Fixture errors contain no credentials or request bodies.
            print("CHATGPT_ACCOUNT_ERROR " + String(describing: type(of: error)))
            exit(2)
        }
    }
}
