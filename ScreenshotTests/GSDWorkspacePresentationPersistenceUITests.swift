#if GSD_WORKSPACE_PRESENTATION_FIXTURE
import Darwin
import Foundation
import GSDSync
import GSDWire
import Observation
import SwiftUI
import Synchronization
import TaskVisualizationKit

/// Compile the exact host store, SessionStore and KeychainTokenStore sources with this branch.
/// The real GSDSync and TaskVisualizationKit packages remain dependencies, never copied DTOs.
@main
@MainActor
private enum WorkspacePresentationFixture {
    private typealias State = TaskWorkspacePresentationState
    private typealias Scope = GSDTaskWorkspacePresentationScope
    fileprivate typealias Account = GSDTaskWorkspacePresentationAccount
    private enum Failure: Error { case assertion(String) }

    @MainActor
    private struct Context {
        let suite: String
        let defaults: UserDefaults
        let store: GSDTaskWorkspacePresentationStore
        init() {
            let name = "com.itorah.gsd.workspace-presentation-fixture." + UUID().uuidString
            let preferences = UserDefaults(suiteName: name)!
            preferences.removePersistentDomain(forName: name)
            suite = name
            defaults = preferences
            store = GSDTaskWorkspacePresentationStore(defaults: preferences)
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor
    @Observable
    fileprivate final class Identity {
        var signedIn = true
        var userID: String? = "fixture-owner-a"
        var inProgress = false
        var pending = false
        var account: Account? {
            Account.validated(isSignedIn: signedIn, userID: userID,
                              inProgress: inProgress, hasPendingAccountSwitch: pending)
        }
    }

    static func main() async {
        guard ProcessInfo.processInfo.environment["GSD_WORKSPACE_PRESENTATION_FIXTURE_ALLOWED"] == "1" else {
            print("An explicitly owned fixture process is required.")
            exit(2)
        }
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("fresh_store_restores_hidden_lanes_and_timeline", restores),
            ("canonical_root_scopes_remain_distinct", roots),
            ("guest_and_accounts_remain_isolated", accounts),
            ("unresolved_same_account_rejects_old_binding", sameAccount),
            ("cross_account_and_root_retarget_reject_old_binding", retarget),
            ("same_scope_views_share_latest_state", sharedViews),
            ("invalid_identity_and_viewport_fail_closed", validation),
            ("session_resolution_holds_identity_until_apply", accountResolution),
            ("oauth_retry_cannot_interrupt_an_inflight_signin", oauthAdmission),
            ("delete_cannot_interrupt_an_inflight_signin", deleteAdmission)
        ]
        let selection = ProcessInfo.processInfo.environment["GSD_WORKSPACE_PRESENTATION_FIXTURE_CASE"]
        let selected = cases.filter { selection == nil || $0.0 == selection }
        guard !selected.isEmpty else { print("Unknown fixture selection."); exit(2) }
        var outcomes: [[String: String]] = []
        var passed = true
        for (name, body) in selected {
            do {
                try await body()
                outcomes.append(["case": name, "result": "PASS"])
            } catch {
                passed = false
                outcomes.append(["case": name, "result": "FAIL", "failure": String(describing: error)])
            }
        }
        let report: [String: Any] = [
            "schemaVersion": 1, "scope": "actual_host_preferences_and_session_resolution",
            "expectedCount": selected.count, "executedCount": outcomes.count,
            "passed": passed, "cases": outcomes, "personalAccount": false,
            "realNetwork": false, "keychainAccess": false,
            "freshStoreOnly": true, "nativeColdRelaunchClaim": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(passed ? 0 : 1)
    }

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            await _Concurrency.Task.yield()
        }
        try require(condition(), "The scheduled MainActor identity update did not settle.")
    }

    private static func state(_ lane: String, zoom: Double = 3) -> State {
        State(collapsedLaneIDs: [lane, "temporarily-hidden-lane"],
              timelineViewport: .init(zoom: zoom, centerDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private static func lease(_ context: Context, _ identity: Identity,
                              roots: [String]? = nil) -> GSDTaskWorkspacePresentationSession {
        let session = GSDTaskWorkspacePresentationSession(store: context.store)
        session.connect(identityOwner: ObjectIdentifier(identity), rootTaskIDs: roots) { identity.account }
        return session
    }

    private static func restores() async throws {
        let context = Context(); defer { context.clean() }
        let scope = Scope(account: .account("fixture-owner-a"), rootTaskIDs: ["missing-root", "visible-root"])
        let expected = state("urgent-important")
        try require(context.store.save(expected, for: scope), "The scoped record must encode.")
        let reopened = GSDTaskWorkspacePresentationStore(defaults: UserDefaults(suiteName: context.suite)!)
        reopened.load(scope)
        try require(reopened.state(for: scope) == expected,
                    "A new owner must restore the full viewport and absent or hidden lane IDs.")
        try require(!scope.storageKey.contains("fixture-owner-a") && !scope.storageKey.contains("missing-root"),
                    "Preference keys must not expose raw owner or task identifiers.")
    }

    private static func roots() async throws {
        let account = Account.account("fixture-owner-a")
        let all = Scope(account: account, rootTaskIDs: nil)
        let empty = Scope(account: account, rootTaskIDs: [])
        let a = Scope(account: account, rootTaskIDs: ["b", "absent-root", "b", "a"])
        let b = Scope(account: account, rootTaskIDs: ["a", "b", "absent-root"])
        try require(all.storageKey != empty.storageKey, "All tasks and an explicitly empty request are distinct.")
        try require(a == b && a.storageKey == b.storageKey, "Root order and duplicates must not fork a scope.")
        try require(a.rootTaskIDs == ["a", "absent-root", "b"], "Absent explicit roots must be preserved.")
        try require(a.storageKey != Scope(account: account, rootTaskIDs: ["a", "b"]).storageKey,
                    "Removing an explicit root must select a different scope.")
    }

    private static func accounts() async throws {
        let context = Context(); defer { context.clean() }
        let scopes = [Scope(account: .guest, rootTaskIDs: nil),
                      Scope(account: .account("fixture-owner-a"), rootTaskIDs: nil),
                      Scope(account: .account("fixture-owner-b"), rootTaskIDs: nil)]
        for (index, scope) in scopes.enumerated() {
            try require(context.store.save(state("lane-\(index)"), for: scope), "Every account record must save.")
        }
        let reopened = GSDTaskWorkspacePresentationStore(defaults: UserDefaults(suiteName: context.suite)!)
        for (index, scope) in scopes.enumerated() {
            reopened.load(scope)
            try require(reopened.state(for: scope) == state("lane-\(index)"), "Account records must remain isolated.")
        }
        try require(Set(scopes.map(\.storageKey)).count == 3, "Guest and two accounts require distinct keys.")
    }

    private static func sameAccount() async throws {
        let context = Context(); defer { context.clean() }
        let identity = Identity()
        let session = lease(context, identity); defer { session.disconnect() }
        let expected = state("owner-a")
        session.binding.wrappedValue = expected
        let old = session.binding
        identity.inProgress = true
        identity.inProgress = false // Deliberately no suspension between A -> unresolved -> A.
        old.wrappedValue = state("stale-immediate")
        let scope = Scope(account: .account("fixture-owner-a"), rootTaskIDs: nil)
        try require(context.store.state(for: scope) == expected, "A stale callback must fail synchronously.")
        try await waitUntil { session.binding.wrappedValue == expected }
        old.wrappedValue = state("stale-after-rearm")
        try require(session.binding.wrappedValue == expected, "Re-arming the same account must not revive the old lease.")
        session.binding.wrappedValue = state("fresh")
        try require(context.store.state(for: scope) == state("fresh"), "A fresh same-account lease must remain writable.")
        let disconnected = session.binding
        session.disconnect()
        disconnected.wrappedValue = state("after-disconnect")
        try require(context.store.state(for: scope) == state("fresh"), "A disappeared view must reject late writes.")
    }

    private static func retarget() async throws {
        let context = Context(); defer { context.clean() }
        let identity = Identity()
        let a = Scope(account: .account("fixture-owner-a"), rootTaskIDs: ["root-x"])
        let b = Scope(account: .account("fixture-owner-b"), rootTaskIDs: ["root-x"])
        let y = Scope(account: .account("fixture-owner-b"), rootTaskIDs: ["root-y"])
        context.store.save(state("a"), for: a)
        context.store.save(state("b"), for: b)
        context.store.save(state("y"), for: y)
        let session = lease(context, identity, roots: ["root-x"]); defer { session.disconnect() }
        let oldA = session.binding
        identity.userID = "fixture-owner-b"
        oldA.wrappedValue = state("wrong-account")
        try await waitUntil { session.binding.wrappedValue == state("b") }
        oldA.wrappedValue = state("wrong-after-rearm")
        try require(context.store.state(for: a) == state("a") && context.store.state(for: b) == state("b"),
                    "Account switching must not write through the old binding into either account.")
        let oldRoot = session.binding
        session.connect(identityOwner: ObjectIdentifier(identity), rootTaskIDs: ["root-y"]) { identity.account }
        oldRoot.wrappedValue = state("wrong-root")
        try require(session.binding.wrappedValue == state("y") && context.store.state(for: b) == state("b"),
                    "Retargeting explicit roots must reject callbacks captured for the previous request.")
    }

    private static func sharedViews() async throws {
        let context = Context(); defer { context.clean() }
        let identity = Identity()
        let inline = lease(context, identity, roots: ["a", "b"])
        let expanded = lease(context, identity, roots: ["b", "a", "b"])
        defer { inline.disconnect(); expanded.disconnect() }
        inline.binding.wrappedValue = state("collapsed-in-card")
        try require(expanded.binding.wrappedValue == state("collapsed-in-card"), "The expanded view must see inline changes.")
        var updated = expanded.binding.wrappedValue
        updated.timelineViewport.zoom = 5
        expanded.binding.wrappedValue = updated
        try require(inline.binding.wrappedValue == updated, "Inline and expanded views must share the latest viewport.")
        try require(updated.collapsedLaneIDs.contains("temporarily-hidden-lane"), "Editing the viewport must retain hidden lanes.")
    }

    private static func validation() async throws {
        try require(Account.validated(isSignedIn: true, userID: nil, inProgress: false,
                                     hasPendingAccountSwitch: false) == nil, "A missing signed-in owner must fail closed.")
        try require(Account.validated(isSignedIn: false, userID: "a", inProgress: false,
                                     hasPendingAccountSwitch: false) == nil, "Inconsistent identity must fail closed.")
        try require(Account.validated(isSignedIn: false, userID: nil, inProgress: true,
                                     hasPendingAccountSwitch: false) == nil, "An active resolution must not become guest.")
        try require(Account.validated(isSignedIn: false, userID: nil, inProgress: false,
                                     hasPendingAccountSwitch: true) == nil, "A pending switch must not become guest.")
        let context = Context(); defer { context.clean() }
        let scope = Scope(account: .guest, rootTaskIDs: nil)
        var invalid = state("retained")
        invalid.timelineViewport.zoom = .infinity
        invalid.timelineViewport.centerDate = Date(timeIntervalSinceReferenceDate: .nan)
        try require(context.store.save(invalid, for: scope), "Malformed viewport numbers must normalize safely.")
        let restored = context.store.state(for: scope)
        try require(restored.timelineViewport.zoom == 1 && restored.timelineViewport.centerDate == nil,
                    "Non-finite viewport values must not reach storage.")
        try require(restored.collapsedLaneIDs == invalid.collapsedLaneIDs, "Validation must preserve collapsed identities.")
        invalid.timelineViewport.zoom = 20
        context.store.save(invalid, for: scope)
        try require(context.store.state(for: scope).timelineViewport.zoom == 16, "Zoom must clamp to the public maximum.")
        invalid.timelineViewport.zoom = 0
        context.store.save(invalid, for: scope)
        try require(context.store.state(for: scope).timelineViewport.zoom == 1, "Zoom must clamp to the public minimum.")
    }

    private static func accountResolution() async throws {
        let keys = ["gsd.lastOwnerId", "gsd.accountEmail", "gsd.accountProvider"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for failErase in [false, true] {
            let context = Context(); defer { context.clean() }
            UserDefaults.standard.set("fixture-owner-a", forKey: "gsd.lastOwnerId")
            let tokens = FixtureTokens(token: fixtureToken(owner: "fixture-owner-a"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureAuthProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let client = PocketBaseClient(baseURL: "https://fixture.invalid", session: transport)
            let auth = AuthService(client: client, presenter: FixturePresenter(), tokenStore: tokens,
                                   config: AuthConfig(baseURL: "https://fixture.invalid",
                                                      redirectURI: "fixture://callback", callbackScheme: "fixture"))
            let gate = EraseGate(fails: failErase)
            defer { gate.release() }
            let session = SessionStore(auth: auth, tokenStore: tokens, coordinator: nil,
                                       hasLocalActiveTasks: { true }, eraseLocal: { try await gate.run() })
            let scopeA = Scope(account: .account("fixture-owner-a"), rootTaskIDs: nil)
            let scopeB = Scope(account: .account("fixture-owner-b"), rootTaskIDs: nil)
            let guest = Scope(account: .guest, rootTaskIDs: nil)
            context.store.save(state("account-a"), for: scopeA)
            context.store.save(state("account-b"), for: scopeB)
            context.store.save(state("guest"), for: guest)
            let owner = GSDTaskWorkspacePresentationSession(store: context.store)
            defer { owner.disconnect() }
            owner.connect(identityOwner: ObjectIdentifier(session), rootTaskIDs: nil) {
                Account.validated(isSignedIn: session.isSignedIn, userID: session.currentUserID,
                                  inProgress: session.inProgress,
                                  hasPendingAccountSwitch: session.pendingAccountSwitch != nil)
            }
            let old = owner.binding
            await session.signInWithEmail("fixture-b@example.invalid", password: "fixture-only", createAccount: false)
            try require(session.pendingAccountSwitch?.newOwnerId == "fixture-owner-b" && !session.isSignedIn,
                        "The actual sign-in route must create a pending different-account confirmation.")
            session.resolveAccountSwitch(.fresh)
            try require(session.inProgress && session.pendingAccountSwitch == nil,
                        "Resolving must mark identity unresolved synchronously before releasing the dialog.")
            try await waitUntil { gate.entered }
            try require(session.inProgress && !session.isSignedIn && session.currentUserID == nil,
                        "Identity must stay unresolved during the actual suspended eraseLocal operation.")
            old.wrappedValue = state("stale-owner")
            owner.binding.wrappedValue = state("transient-guest")
            try require(context.store.state(for: scopeA) == state("account-a") &&
                        context.store.state(for: guest) == state("guest"),
                        "Neither old-owner nor guest preferences may change during resolution.")
            gate.release()
            try await waitUntil { !session.inProgress }
            if failErase {
                try require(!session.isSignedIn && session.currentUserID == nil && session.lastError != nil,
                            "The existing error path must settle signed out and clear the progress phase.")
                try await waitUntil { owner.binding.wrappedValue == state("guest") }
            } else {
                try require(session.isSignedIn && session.currentUserID == "fixture-owner-b",
                            "The successful existing apply path must resolve to the new account.")
                try await waitUntil { owner.binding.wrappedValue == state("account-b") }
            }
            old.wrappedValue = state("late-old-owner")
            try require(context.store.state(for: scopeA) == state("account-a") &&
                        context.store.state(for: scopeB) == state("account-b"),
                        "The previous account binding must remain invalid after success or failure.")
        }
        try require(FixtureAuthProtocol.observations.withLock { $0.requests } == 2 &&
                    !FixtureAuthProtocol.observations.withLock { $0.unexpected },
                    "Exactly two intercepted password requests and no unexpected transport are required.")
    }


    private static func oauthAdmission() async throws {
        let keys = ["gsd.lastOwnerId", "gsd.accountEmail", "gsd.accountProvider"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set("fixture-owner-a", forKey: "gsd.lastOwnerId")
        let originalToken = fixtureToken(owner: "fixture-owner-a")
        let tokens = FixtureTokens(token: originalToken)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureHeldLoginProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { FixtureHeldLoginProtocol.release(); transport.invalidateAndCancel() }
        let client = PocketBaseClient(baseURL: "https://fixture.invalid", session: transport)
        let auth = AuthService(client: client, presenter: FixtureAdmissionPresenter(), tokenStore: tokens,
                               config: AuthConfig(baseURL: "https://fixture.invalid",
                                                  redirectURI: "fixture://callback", callbackScheme: "fixture"))
        let session = SessionStore(auth: auth, tokenStore: tokens, coordinator: nil,
                                   hasLocalActiveTasks: { false })
        let first = _Concurrency.Task {
            await session.signInWithEmail("fixture-b@example.invalid", password: "fixture-only", createAccount: false)
        }
        var admissionFailure: Error?
        do {
            let deadline = Date().addingTimeInterval(10)
            while !FixtureHeldLoginProtocol.isHolding && Date() < deadline {
                try await _Concurrency.Task.sleep(for: .milliseconds(20))
            }
            try require(FixtureHeldLoginProtocol.isHolding && session.inProgress,
                        "The first real AuthService password response must be held while sign-in is active.")
            await session.signIn(provider: "google")
            try require(session.inProgress,
                        "A second OAuth attempt must not end the first sign-in phase.")
            try require(Account.validated(isSignedIn: session.isSignedIn, userID: session.currentUserID,
                                          inProgress: session.inProgress,
                                          hasPendingAccountSwitch: session.pendingAccountSwitch != nil) == nil,
                        "The concurrent attempt must not reopen validated account admission.")
            try require(tokens.load() == originalToken,
                        "No second attempt may replace the original token while the first response is held.")
            try require(FixtureHeldLoginProtocol.observations.withLock { $0.requests } == 1 &&
                        !FixtureHeldLoginProtocol.observations.withLock { $0.unexpected } &&
                        FixtureAdmissionPresenter.calls.withLock { $0 } == 0,
                        "The rejected OAuth entry must not start transport or an authorization presenter.")
        } catch { admissionFailure = error }
        // Even a meaningful RED releases and joins the first actual login before restoring defaults.
        let hadHeldResponse = FixtureHeldLoginProtocol.isHolding
        FixtureHeldLoginProtocol.release()
        if !hadHeldResponse { first.cancel(); transport.invalidateAndCancel() }
        await first.value
        try require(!session.inProgress && session.isSignedIn && session.currentUserID == "fixture-owner-b" &&
                    tokens.load() == FixtureHeldLoginProtocol.responseToken,
                    "Only the original held login may install its account and exact response token.")
        try require(FixtureAdmissionPresenter.calls.withLock { $0 } == 0,
                    "No real or fixture OAuth presenter may be entered, including the negative baseline.")
        if let admissionFailure { throw admissionFailure }
    }

    private static func deleteAdmission() async throws {
        let keys = ["gsd.lastOwnerId", "gsd.accountEmail", "gsd.accountProvider"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set("fixture-owner-a", forKey: "gsd.lastOwnerId")
        let originalToken = fixtureToken(owner: "fixture-owner-a")
        let tokens = FixtureTokens(token: originalToken)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureHeldDeleteAdmissionProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { FixtureHeldDeleteAdmissionProtocol.release(); transport.invalidateAndCancel() }
        let client = PocketBaseClient(baseURL: "https://fixture.invalid", session: transport)
        let auth = AuthService(client: client, presenter: FixtureAdmissionPresenter(), tokenStore: tokens,
                               config: AuthConfig(baseURL: "https://fixture.invalid",
                                                  redirectURI: "fixture://callback", callbackScheme: "fixture"))
        let session = SessionStore(auth: auth, tokenStore: tokens, coordinator: nil,
                                   hasLocalActiveTasks: { false })
        let first = _Concurrency.Task {
            await session.signInWithEmail("fixture-b@example.invalid", password: "fixture-only", createAccount: false)
        }
        var admissionFailure: Error?
        do {
            let deadline = Date().addingTimeInterval(10)
            while !FixtureHeldDeleteAdmissionProtocol.isHolding && Date() < deadline {
                try await _Concurrency.Task.sleep(for: .milliseconds(20))
            }
            try require(FixtureHeldDeleteAdmissionProtocol.isHolding && session.inProgress,
                        "The first real AuthService password response must be held before attempting deletion.")
            await session.deleteAccount(eraseLocalData: false)
            try require(session.inProgress,
                        "A delete attempt must not end the active sign-in phase.")
            try require(Account.validated(isSignedIn: session.isSignedIn, userID: session.currentUserID,
                                          inProgress: session.inProgress,
                                          hasPendingAccountSwitch: session.pendingAccountSwitch != nil) == nil,
                        "An overlapping delete must not reopen validated account admission.")
            try require(tokens.load() == originalToken,
                        "An overlapping delete must not clear or replace the retained account token.")
            try require(FixtureHeldDeleteAdmissionProtocol.observations.withLock { $0.requests } == 1 &&
                        !FixtureHeldDeleteAdmissionProtocol.observations.withLock { $0.unexpected } &&
                        FixtureAdmissionPresenter.calls.withLock { $0 } == 0,
                        "A rejected delete must not start another request or authorization presenter.")
        } catch { admissionFailure = error }
        // Release and join even the negative baseline; retain both admission and cleanup failures.
        let hadHeldResponse = FixtureHeldDeleteAdmissionProtocol.isHolding
        FixtureHeldDeleteAdmissionProtocol.release()
        if !hadHeldResponse { first.cancel(); transport.invalidateAndCancel() }
        await first.value
        var completionFailure: Error?
        do {
            try require(!session.inProgress && session.isSignedIn && session.currentUserID == "fixture-owner-b" &&
                        tokens.load() == FixtureHeldDeleteAdmissionProtocol.responseToken,
                        "Only the original held sign-in may install its final account and exact response token.")
            try require(FixtureAdmissionPresenter.calls.withLock { $0 } == 0,
                        "The delete admission fixture must never enter an authorization presenter.")
        } catch { completionFailure = error }
        if let admissionFailure {
            if let completionFailure {
                throw Failure.assertion("\(admissionFailure); cleanup: \(completionFailure)")
            }
            throw admissionFailure
        }
        if let completionFailure { throw completionFailure }
    }

    @MainActor
    private final class EraseGate {
        let fails: Bool
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        init(fails: Bool) { self.fails = fails }
        func run() async throws {
            entered = true
            await withCheckedContinuation { continuation = $0 }
            if fails { throw Failure.assertion("Synthetic local erase failure") }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
}

private func fixtureToken(owner: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["id": owner, "exp": 4_000_000_000] as [String: Any])
    let body = data.base64EncodedString().replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "eyJhbGciOiJub25lIn0." + body + ".fixture"
}

private final class FixtureTokens: TokenStore, Sendable {
    private let value: Mutex<String?>
    init(token: String) { value = Mutex(token) }
    func load() -> String? { value.withLock { $0 } }
    func save(_ token: String) { value.withLock { $0 = token } }
    func clear() { value.withLock { $0 = nil } }
}

private struct FixturePresenter: WebAuthPresenting {
    func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
        throw URLError(.unsupportedURL)
    }
}

private final class FixtureAuthProtocol: URLProtocol, @unchecked Sendable {
    static let observations = Mutex((requests: 0, unexpected: false))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let expected = request.url?.host == "fixture.invalid" &&
            request.url?.path == "/api/collections/users/auth-with-password" && request.httpMethod == "POST"
        Self.observations.withLock { $0.requests += 1; $0.unexpected = $0.unexpected || !expected }
        guard expected, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let body: [String: Any] = [
            "token": fixtureToken(owner: "fixture-owner-b"),
            "record": ["id": "fixture-owner-b", "email": "fixture-b@example.invalid",
                       "verified": true, "collectionName": "users"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


private struct FixtureAdmissionPresenter: WebAuthPresenting {
    static let calls = Mutex(0)
    func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
        Self.calls.withLock { $0 += 1 }
        throw URLError(.unsupportedURL)
    }
}

/// Fixture-only synchronized ownership of the delayed URLProtocol. Every read, replacement,
/// take and identity-based removal holds this lock; callbacks run only after take unlocks.
/// The optional reference is never exposed except by that atomic take operation.
private final class FixtureHeldLoginStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: FixtureHeldLoginProtocol?

    var isHolding: Bool { lock.withLock { retained != nil } }

    func store(_ instance: FixtureHeldLoginProtocol) {
        lock.withLock { retained = instance }
    }

    func take() -> FixtureHeldLoginProtocol? {
        lock.withLock {
            defer { retained = nil }
            return retained
        }
    }

    func remove(_ instance: FixtureHeldLoginProtocol) {
        lock.withLock { if retained === instance { retained = nil } }
    }
}

/// Every URL is intercepted. The first password response is released explicitly by the test;
/// an unexpected OAuth discovery request fails locally before any browser can be presented.
private final class FixtureHeldLoginProtocol: URLProtocol, @unchecked Sendable {
    static let observations = Mutex((requests: 0, unexpected: false))
    private static let held = FixtureHeldLoginStorage()
    static let responseToken = fixtureToken(owner: "fixture-owner-b")
    static var isHolding: Bool { held.isHolding }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let expected = request.url?.host == "fixture.invalid" &&
            request.url?.path == "/api/collections/users/auth-with-password" && request.httpMethod == "POST"
        let first = Self.observations.withLock {
            $0.requests += 1
            $0.unexpected = $0.unexpected || !expected || $0.requests != 1
            return $0.requests == 1
        }
        guard expected && first else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.held.store(self)
    }

    static func release() {
        held.take()?.finish()
    }

    private func finish() {
        guard let url = request.url else { return }
        let body: [String: Any] = [
            "token": Self.responseToken,
            "record": ["id": "fixture-owner-b", "email": "fixture-b@example.invalid"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.held.remove(self)
    }
}

/// The deletion admission case has its own delayed request owner so it can run after the
/// original OAuth case without resetting or weakening that case's single-request checks.
private final class FixtureHeldDeleteAdmissionStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: FixtureHeldDeleteAdmissionProtocol?
    var isHolding: Bool { lock.withLock { retained != nil } }
    func store(_ instance: FixtureHeldDeleteAdmissionProtocol) {
        lock.withLock { retained = instance }
    }
    func take() -> FixtureHeldDeleteAdmissionProtocol? {
        lock.withLock {
            defer { retained = nil }
            return retained
        }
    }
    func remove(_ instance: FixtureHeldDeleteAdmissionProtocol) {
        lock.withLock { if retained === instance { retained = nil } }
    }
}

/// Intercepts every URL locally. Only the first synthetic password response may succeed;
/// an unguarded DELETE fails locally while the original password response stays held.
private final class FixtureHeldDeleteAdmissionProtocol: URLProtocol, @unchecked Sendable {
    static let observations = Mutex((requests: 0, unexpected: false))
    private static let held = FixtureHeldDeleteAdmissionStorage()
    static let responseToken = fixtureToken(owner: "fixture-owner-b")
    static var isHolding: Bool { held.isHolding }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let expected = request.url?.host == "fixture.invalid" &&
            request.url?.path == "/api/collections/users/auth-with-password" && request.httpMethod == "POST"
        let first = Self.observations.withLock {
            $0.requests += 1
            $0.unexpected = $0.unexpected || !expected || $0.requests != 1
            return $0.requests == 1
        }
        guard expected && first else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.held.store(self)
    }
    static func release() { held.take()?.finish() }
    private func finish() {
        guard let url = request.url else { return }
        let data = try! JSONSerialization.data(withJSONObject: [
            "token": Self.responseToken,
            "record": ["id": "fixture-owner-b", "email": "fixture-b@example.invalid"]
        ] as [String: Any])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.held.remove(self) }
}

/// Compile-only optional dependency. The actual SessionStore is initialized with coordinator:nil.
/// Every method traps so this fixture cannot accidentally replace or claim sync behavior.
@MainActor
final class SyncCoordinator {
    func beginSignIn() async { fatalError("Unexpected coordinator") }
    func cancelSignIn() { fatalError("Unexpected coordinator") }
    func start(trigger: SyncTrigger) { fatalError("Unexpected coordinator") }
    func signedOut() { fatalError("Unexpected coordinator") }
    func holdForAccountDeletion() { fatalError("Unexpected coordinator") }
    func releaseAfterFailedAccountDeletion() { fatalError("Unexpected coordinator") }
    func eraseRemoteTasksPass() async -> AccountDeleter.ErasePass { fatalError("Unexpected coordinator") }
    func syncNow() async { fatalError("Unexpected coordinator") }
    func withExternalWritesPaused<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        fatalError("Unexpected coordinator")
    }
}

#else
import Foundation
import UIKit
import XCTest

/// Ordinary app data and real touch only. A read-only host watcher attests DB/outbox invariance.
@MainActor
final class GSDWorkspacePresentationPersistenceUITests: XCTestCase {
    private enum Failure: Error { case condition(String) }
    private struct TaskIdentity {
        let id: String
        let title: String
    }
    private struct TimelineObservation {
        let zoom: Double
        let lower: Date
        let upper: Date
        let label: String
        let chartFrame: CGRect
        var width: TimeInterval { upper.timeIntervalSince(lower) }
        var json: [String: Any] {
            ["zoomPercent": zoom, "lowerEpoch": lower.timeIntervalSince1970,
             "upperEpoch": upper.timeIntervalSince1970, "visibleRange": label,
             "chartFrame": NSCoder.string(for: chartFrame)]
        }
    }
    private var hebrew = false
    private var artifacts = URL(fileURLWithPath: "/")
    private var receipt: [String: Any] = [:]
    private var checks: [String] = []
    private let lane = "urgent-important"

    func testBoardCollapseAndTimelineZoomPersistAcrossNavigationAndRelaunch() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["GSD_SYSTEM_SURFACE_FRESH_SIMULATOR"] == "1",
              let source = environment["GSD_SYSTEM_SURFACE_APP_SOURCE"],
              source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let simulator = environment["GSD_SYSTEM_SURFACE_SIMULATOR_UDID"],
              UUID(uuidString: simulator) != nil,
              let root = environment["GSD_SYSTEM_SURFACE_ARTIFACTS"], root.hasPrefix("/"),
              let language = environment["GSD_TEST_LANGUAGE"], ["en", "he"].contains(language),
              let family = environment["GSD_WORKSPACE_PRESENTATION_DEVICE_FAMILY"],
              ["phone", "tablet"].contains(family) else {
            throw Failure.condition("Missing owned simulator, source, family, language, or artifacts.")
        }
        let actualFamily = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        try require(actualFamily == family, "The actual test device must match the declared family.")
        if let actual = environment["SIMULATOR_UDID"] {
            try require(actual.caseInsensitiveCompare(simulator) == .orderedSame,
                        "The test runner must use the declared owned simulator.")
        }
        hebrew = language == "he"
        artifacts = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("workspace-presentation-\(family)-\(language)", isDirectory: true)
        try require(!FileManager.default.fileExists(atPath: artifacts.path),
                    "Evidence must use a new append-only configuration directory.")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        receipt = [
            "schemaVersion": 1, "sourceSHA": source, "simulator": simulator,
            "language": language, "deviceFamily": family, "actualDeviceFamily": actualFamily,
            "scope": "ordinary_app_native_workspace_presentation_and_disk_relaunch",
            "demoSeed": false, "inMemoryStore": false, "personalAccount": false,
            "taskMutationRoute": "original_ui_actions", "timeZone": TimeZone.current.identifier,
            "passed": false
        ]
        try persist()
        XCUIDevice.shared.orientation = family == "tablet" ? .landscapeLeft : .portrait
        let app = XCUIApplication(bundleIdentifier: "com.itorah.gsd")
        app.launchArguments = [
            "-AppleLanguages", hebrew ? "(he)" : "(en)",
            "-AppleLocale", hebrew ? "he_IL" : "en_US"
        ]
        defer { app.terminate() }
        do {
            try exercise(app)
            receipt["passed"] = true
            try persist()
        } catch {
            try? capture(app, "failure-presentation-native-state")
            receipt["failure"] = String(describing: error)
            try persist()
            throw error
        }
    }

    private func exercise(_ app: XCUIApplication) throws {
        app.launch()
        try openWorkspace(app)
        try tapMode("table", in: app)
        let token = String(UUID().uuidString.prefix(8))
        var tasks: [TaskIdentity] = []
        for letter in ["A", "B", "C"] {
            let task = try createTask("GSD Presentation \(letter) \(token)", in: app)
            tasks.append(task)
            try setDatePresence(true, using: app.buttons["task-workspace.date.\(task.id)"], in: app)
        }
        try require(Set(tasks.map(\.id)).count == 3, "Three real independent task identities are required.")
        receipt["tasks"] = tasks.map { ["id": $0.id, "title": $0.title] }
        try checked("ordinaryTasksAndDatesCreated")
        try capture(app, "01-ordinary-tasks-and-dates")

        try tapMode("board", in: app)
        let expanded = element("task-workspace.board.column.\(lane)", in: app)
        try require(expanded.waitForExistence(timeout: 10), "The original Board lane must start expanded.")
        let before = try databaseCheckpoint("before-collapse", tasks: tasks, in: app)
        let collapse = try boardCollapseControl(in: app)
        collapse.tap()
        try requireCollapsedBoard(app)
        try tapMode("timeline", in: app)
        try tapMode("board", in: app)
        try requireCollapsedBoard(app)
        let search = app.textFields["task-workspace.search"]
        try require(search.isHittable, "The real workspace search field must be reachable.")
        search.tap()
        search.typeText("NoSuchGSDPresentation-" + token + "\n")
        try require(element("task-workspace.board", in: app).waitForNonExistence(timeout: 8),
                    "The filter must actually remove the visible Board before restoration.")
        try capture(app, "02-board-filtered-away")
        let clear = app.buttons[hebrew ? "ניקוי חיפוש" : "Clear search"]
        try require(clear.waitForExistence(timeout: 5) && clear.isHittable, "The normal clear-search action is missing.")
        clear.tap()
        try require(clear.waitForNonExistence(timeout: 5), "The filter must really clear.")
        try requireCollapsedBoard(app)
        try checked("boardCollapseSurvivesTabAndFilter")
        let after = try databaseCheckpoint("after-collapse", tasks: tasks, in: app)
        for key in ["schemaSHA256", "taskRowsSHA256", "outboxRowsSHA256", "otherTaskRowsSHA256"] {
            try require(before[key] as? String == after[key] as? String,
                        "Collapse, tab navigation and filtering must not alter canonical \(key).")
        }
        receipt["collapseDatabaseSnapshots"] = ["before": before, "after": after]
        try checked("collapseLeavesDatabaseAndOutboxUnchanged")
        try capture(app, "03-board-collapse-retained")

        try coldRelaunch(app)
        try openWorkspace(app)
        try tapMode("board", in: app)
        try requireCollapsedBoard(app)
        try checked("boardCollapseSurvivesColdRelaunch")
        try capture(app, "04-board-after-cold-relaunch")

        try tapMode("timeline", in: app)
        try tapButton("task-workspace.timeline.fit", in: app)
        let full = try timelineObservation(in: app)
        try require(full.zoom == 100 && full.width >= 23 * 60 * 60,
                    "The original Fit view must expose a full, parseable date range at 100%.")
        let chart = element("task-workspace.timeline.chart", in: app)
        let viewport = visibleViewport(in: app)
        try require(viewport.contains(chart.frame) && chart.frame.width >= 180 && chart.frame.height >= 140,
                    "A fully visible chart with measured space for a real pinch is required.")
        try require(chart.isHittable, "The native Timeline chart must accept the actual pinch.")
        receipt["fullTimeline"] = full.json
        try capture(app, "05-timeline-before-pinch")
        chart.pinch(withScale: 1.5, velocity: 1.0)
        try waitForValueChange(element("task-workspace.timeline.zoom-scale", in: app), from: "100%")
        let zoomed = try timelineObservation(in: app)
        try require(zoomed.zoom >= 140 && zoomed.zoom <= 160, "The observed zoom must match the native 1.5 pinch.")
        try require(zoomed.width < full.width - 3600,
                    "A changed percentage alone is insufficient; the rendered date interval must narrow.")
        try require(abs(full.width / zoomed.width - zoomed.zoom / 100) < 0.04,
                    "The measured date range must agree with the reported zoom, allowing minute formatting.")
        try contained(zoomed, in: full)
        receipt["afterNativePinch"] = zoomed.json
        try checked("nativePinchChangesZoomAndVisibleRange")
        try capture(app, "06-timeline-after-native-pinch")

        let earlier = app.buttons["task-workspace.timeline.earlier"]
        // A pinch may anchor near either end. Exercise both real controls in an enabled order.
        let firstEarlier = earlier.isEnabled
        let first = try shiftTimeline(earlier: firstEarlier, previous: zoomed, full: full, in: app)
        let shifted = try shiftTimeline(earlier: !firstEarlier, previous: first, full: full, in: app)
        receipt["earlierLaterTimeline"] = [first.json, shifted.json]
        try checked("earlierAndLaterShiftDatesWithoutChangingZoom")
        try capture(app, "07-timeline-after-date-navigation")

        // B was dated between A and C. Clearing its middle date preserves the full outer domain.
        let target = tasks[1]
        let row = app.buttons["task-workspace.timeline.inspect.\(target.id)"]
        try require(row.waitForExistence(timeout: 10) && row.isHittable,
                    "The original task row must remain touchable after zoom and date navigation.")
        try require(row.label == target.title, "The zoomed row must still identify the exact canonical task.")
        row.tap()
        let due = app.buttons["task-workspace.timeline.due.\(target.id)"]
        try require(due.waitForExistence(timeout: 10) && due.isHittable,
                    "The selected task's original date action must remain in the visible footer.")
        try capture(app, "08-zoomed-row-selected")
        try setDatePresence(false, using: due, in: app)
        let close = app.buttons["task-workspace.timeline.close-actions"]
        try require(close.waitForExistence(timeout: 10) && close.isHittable, "Selected task actions did not return.")
        close.tap()
        try tapMode("table", in: app)
        try verifyCanonicalNoDate(target, in: app, name: "09-canonical-date-cleared")
        try checked("postZoomDateActionUpdatesCanonicalTask")
        try tapMode("board", in: app)
        try requireCollapsedBoard(app)
        try tapMode("timeline", in: app)
        let beforeRelaunch = try timelineObservation(in: app)
        try sameViewport(beforeRelaunch, shifted)
        receipt["beforeColdTimeline"] = beforeRelaunch.json
        try capture(app, "10-presentation-before-cold-relaunch")

        try coldRelaunch(app)
        try openWorkspace(app)
        try tapMode("board", in: app)
        try requireCollapsedBoard(app)
        try tapMode("timeline", in: app)
        let restored = try timelineObservation(in: app)
        try sameViewport(restored, beforeRelaunch)
        receipt["afterColdTimeline"] = restored.json
        try capture(app, "11-timeline-restored-from-disk")
        try tapMode("table", in: app)
        try verifyCanonicalNoDate(target, in: app, name: "12-canonical-date-after-cold-relaunch")
        for task in tasks {
            let open = app.buttons["task-workspace.open.\(task.id)"]
            try require(open.waitForExistence(timeout: 10) && open.label == task.title,
                        "Ordinary relaunch must preserve each original task ID and title.")
        }
        try checked("dateMutationAndPresentationSurviveColdRelaunch")
        try tapMode("timeline", in: app)
        try tapButton("task-workspace.timeline.fit", in: app)
        let fitted = try timelineObservation(in: app)
        try require(fitted.zoom == 100, "Fit must restore exactly 100%.")
        try require(abs(fitted.lower.timeIntervalSince(full.lower)) <= 60 &&
                    abs(fitted.upper.timeIntervalSince(full.upper)) <= 60,
                    "Fit must restore the original full date domain, not just its percentage.")
        receipt["afterFit"] = fitted.json
        try checked("fitRestoresFullRange")
        try capture(app, "13-timeline-fit-restored")
    }

    private func openWorkspace(_ app: XCUIApplication) throws {
        let skip = app.buttons[hebrew ? "דילוג" : "Skip"]
        if skip.waitForExistence(timeout: 3) {
            try require(skip.isHittable, "The normal onboarding action is obscured.")
            skip.tap()
            try require(skip.waitForNonExistence(timeout: 10), "Onboarding did not finish.")
        }
        let tab = app.tabBars.buttons[hebrew ? "מרחב משימות" : "Workspace"]
        let sidebar = element("gsd.sidebar.workspace", in: app)
        let entry = tab.exists ? tab : sidebar
        try require(entry.waitForExistence(timeout: 25) && entry.isHittable, "The actual Workspace entry is unavailable.")
        entry.tap()
        try require(element("task-workspace", in: app).waitForExistence(timeout: 15), "The shared workspace did not open.")
        let frame = app.frame
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        try require(tablet ? frame.width > frame.height : frame.height > frame.width,
                    "The observed app must match the requested tablet-landscape or phone-portrait configuration.")
        receipt["appFrame"] = NSCoder.string(for: frame)
    }

    private func createTask(_ title: String, in app: XCUIApplication) throws -> TaskIdentity {
        try tapButton("task-workspace.create", in: app)
        let field = app.textFields["editor-title"]
        try require(field.waitForExistence(timeout: 10) && field.isHittable, "The canonical create editor did not open.")
        let form = element("task-editor", in: app)
        let quadrant = form.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", hebrew ? "לביצוע מיידי" : "Do First")).firstMatch
        try require(quadrant.waitForExistence(timeout: 5) && quadrant.isHittable, "The real Do First control is missing.")
        quadrant.tap()
        try require(quadrant.isSelected, "The created task must use the intended actual Board lane.")
        field.tap()
        field.typeText(title)
        try tapButton("editor-save", in: app)
        try require(field.waitForNonExistence(timeout: 10), "The real task create must finish.")
        let matches = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'task-workspace.open.' AND label == %@", title))
        try require(matches.firstMatch.waitForExistence(timeout: 15), "The new canonical task row is missing.")
        let ids = Set(matches.allElementsBoundByIndex.map(\.identifier))
        try require(ids.count == 1, "A title must resolve to one exact task, without duplicates.")
        guard let identifier = ids.first else { throw Failure.condition("Missing task identity.") }
        let id = String(identifier.dropFirst("task-workspace.open.".count))
        try require(!id.isEmpty, "The canonical task ID must not be empty.")
        return TaskIdentity(id: id, title: title)
    }

    private func setDatePresence(_ wanted: Bool, using action: XCUIElement, in app: XCUIApplication) throws {
        try require(action.waitForExistence(timeout: 10) && action.isHittable, "The original date action must be touchable.")
        action.tap()
        let row = app.switches["task-workspace.date.toggle"].firstMatch
        try require(row.waitForExistence(timeout: 10), "The shared date editor did not open.")
        let native = row.switches.firstMatch
        try require(native.waitForExistence(timeout: 5) && native.isHittable,
                    "The real nested UISwitch must be available for the date change.")
        try require(row.frame.contains(native.frame) && app.frame.contains(native.frame), "The date switch must be visible.")
        let before = wanted ? "0" : "1"
        let after = wanted ? "1" : "0"
        try require(native.value as? String == before, "The native date switch must begin in the opposite state.")
        native.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", after), object: native)
        try require(XCTWaiter.wait(for: [settled], timeout: 5) == .completed,
                    "The native switch must actually change before saving.")
        try tapButton("task-workspace.date.save", in: app)
        try require(row.waitForNonExistence(timeout: 10), "The original date mutation did not finish.")
    }

    private func requireCollapsedBoard(_ app: XCUIApplication) throws {
        let column = element("task-workspace.board.column.\(lane)", in: app)
        try require(column.waitForNonExistence(timeout: 8), "The stored Board lane must remain collapsed.")
        let expand = try boardCollapseControl(in: app)
        try require(expand.label == (hebrew ? "הרחבת העמודה" : "Expand column"),
                    "The same real control must advertise Expand after collapse.")
        try require(expand.frame.width >= 44 && expand.frame.height >= 44, "The collapsed lane must retain a usable touch target.")
    }

    private func boardCollapseControl(in app: XCUIApplication) throws -> XCUIElement {
        let control = app.buttons["task-workspace.board.collapse.\(lane)"]
        try require(control.waitForExistence(timeout: 10), "The real Board collapse control is missing.")
        let board = app.scrollViews["task-workspace.board"].firstMatch
        try require(board.waitForExistence(timeout: 10) && !board.frame.isEmpty, "The native Board scroll container is missing.")
        for _ in 0..<6 {
            let viewport = board.frame.intersection(app.frame)
            if viewport.contains(control.frame) && !control.frame.isEmpty { break }
            if control.frame.midX > viewport.midX { board.swipeLeft() } else { board.swipeRight() }
        }
        try require(board.frame.intersection(app.frame).contains(control.frame) && control.isHittable,
                    "The Board control must be physically visible before touch.")
        return control
    }

    private func timelineObservation(in app: XCUIApplication) throws -> TimelineObservation {
        let zoom = element("task-workspace.timeline.zoom-scale", in: app)
        let range = element("task-workspace.timeline.visible-range", in: app)
        let chart = element("task-workspace.timeline.chart", in: app)
        try require(zoom.waitForExistence(timeout: 10) && range.waitForExistence(timeout: 10) &&
                    chart.waitForExistence(timeout: 10), "Timeline zoom, range and chart must all be present.")
        guard let rawZoom = zoom.value as? String,
              let percentage = Double(rawZoom.replacingOccurrences(of: "%", with: "")) else {
            throw Failure.condition("Timeline must expose its original numeric zoom percentage.")
        }
        let parts = range.label.components(separatedBy: " – ")
        try require(parts.count == 2, "The original visible range must expose two actual formatted dates.")
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened,
                                      locale: Locale(identifier: hebrew ? "he_IL" : "en_US"),
                                      calendar: Calendar(identifier: .gregorian), timeZone: TimeZone.current)
        let lower = try format.parseStrategy.parse(parts[0])
        let upper = try format.parseStrategy.parse(parts[1])
        try require(upper > lower && percentage >= 100 && percentage <= 1600, "The observed Timeline range must be valid.")
        return TimelineObservation(zoom: percentage, lower: lower, upper: upper,
                                   label: range.label, chartFrame: chart.frame)
    }

    private func shiftTimeline(earlier: Bool, previous: TimelineObservation,
                               full: TimelineObservation, in app: XCUIApplication) throws -> TimelineObservation {
        let button = app.buttons["task-workspace.timeline." + (earlier ? "earlier" : "later")]
        try require(button.waitForExistence(timeout: 5) && button.isEnabled && button.isHittable,
                    "Both real date navigation controls must have an enabled touch opportunity.")
        button.tap()
        let range = element("task-workspace.timeline.visible-range", in: app)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous.label), object: range)
        try require(XCTWaiter.wait(for: [changed], timeout: 8) == .completed, "Date navigation must change the visible dates.")
        let result = try timelineObservation(in: app)
        try require(result.zoom == previous.zoom && abs(result.width - previous.width) <= 120,
                    "Date navigation must preserve zoom and visible interval width.")
        try require(earlier ? result.lower < previous.lower : result.lower > previous.lower,
                    "The date range must move in the action's actual chronological direction, including RTL.")
        try contained(result, in: full)
        return result
    }

    private func contained(_ observation: TimelineObservation, in full: TimelineObservation) throws {
        try require(observation.lower.timeIntervalSince(full.lower) >= -60 &&
                    observation.upper.timeIntervalSince(full.upper) <= 60, "The visible dates must stay inside the task domain.")
    }

    private func sameViewport(_ actual: TimelineObservation, _ expected: TimelineObservation) throws {
        try require(actual.zoom == expected.zoom &&
                    abs(actual.lower.timeIntervalSince(expected.lower)) <= 60 &&
                    abs(actual.upper.timeIntervalSince(expected.upper)) <= 60,
                    "Navigation and cold reopen must restore the actual zoom and center date.")
    }

    private func verifyCanonicalNoDate(_ task: TaskIdentity, in app: XCUIApplication, name: String) throws {
        let date = app.buttons["task-workspace.date.\(task.id)"]
        try require(date.waitForExistence(timeout: 10) && date.label == (hebrew ? "קביעת תאריך" : "Set date"),
                    "The canonical table must show that this exact task has no due date.")
        try tapButton("task-workspace.open.\(task.id)", in: app)
        let title = app.textFields["editor-title"]
        try require(title.waitForExistence(timeout: 10) && title.value as? String == task.title,
                    "The date mutation must still open the exact original canonical task.")
        let toggle = app.switches[hebrew ? "יש תאריך יעד" : "Has due date"].firstMatch
        let form = element("task-editor", in: app)
        for _ in 0..<5 {
            if toggle.exists && toggle.isHittable { break }
            form.swipeUp()
        }
        try require(toggle.exists && toggle.value as? String == "0", "The actual editor must reload a nil due date.")
        try capture(app, name)
        try tapButton("editor-cancel", in: app)
        try require(title.waitForNonExistence(timeout: 10), "Read-only canonical inspection must close through Cancel.")
    }

    private func databaseCheckpoint(_ phase: String, tasks: [TaskIdentity],
                                    in app: XCUIApplication) throws -> [String: Any] {
        let nonce = UUID().uuidString
        let request = artifacts.appendingPathComponent("database-\(phase).request.json")
        let acknowledgment = artifacts.appendingPathComponent("database-\(phase).ack.json")
        try require(!FileManager.default.fileExists(atPath: request.path) &&
                    !FileManager.default.fileExists(atPath: acknowledgment.path), "Checkpoint evidence must be fresh.")
        let payload: [String: Any] = [
            "schemaVersion": 1, "phase": phase, "nonce": nonce,
            "sourceSHA": receipt["sourceSHA"]!, "simulator": receipt["simulator"]!,
            "taskIDs": tasks.map(\.id).sorted(),
            "tables": ["tasks", "syncQueue", "deletedTasks", "archivedTasks"],
            "readOnlyRequired": true
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: request, options: .atomic)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: acknowledgment.path) { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try require(FileManager.default.fileExists(atPath: acknowledgment.path),
                    "The owned read-only database watcher must acknowledge each snapshot within 60 seconds.")
        guard let ack = try JSONSerialization.jsonObject(with: Data(contentsOf: acknowledgment)) as? [String: Any] else {
            throw Failure.condition("Invalid database checkpoint acknowledgment.")
        }
        try require(ack["schemaVersion"] as? Int == 1 && ack["nonce"] as? String == nonce &&
                    ack["phase"] as? String == phase && ack["sourceSHA"] as? String == receipt["sourceSHA"] as? String &&
                    ack["simulator"] as? String == receipt["simulator"] as? String &&
                    ack["captureComplete"] as? Bool == true && ack["readOnly"] as? Bool == true,
                    "The snapshot must bind this exact source, owned simulator, phase, and fresh nonce.")
        try require(ack["taskIDs"] as? [String] == tasks.map(\.id).sorted(),
                    "The read-only database must contain the same three actual canonical tasks.")
        for key in ["schemaSHA256", "taskRowsSHA256", "outboxRowsSHA256", "otherTaskRowsSHA256"] {
            guard let digest = ack[key] as? String else { throw Failure.condition("Missing actual snapshot digest: \(key)") }
            try require(digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "Invalid database snapshot digest.")
        }
        return ack
    }

    private func coldRelaunch(_ app: XCUIApplication) throws {
        app.terminate()
        try require(app.wait(for: .notRunning, timeout: 10), "Cold persistence requires an actual process termination.")
        app.launch()
    }

    private func tapMode(_ mode: String, in app: XCUIApplication) throws {
        let identifier = "task-workspace.tab.\(mode)"
        let button = app.buttons[identifier].firstMatch
        try require(button.waitForExistence(timeout: 10), "The original presentation mode is missing.")
        let strips = app.scrollViews.containing(.button, identifier: identifier)
            .allElementsBoundByIndex.filter { !$0.frame.isEmpty }
        guard let strip = strips.min(by: { $0.frame.height < $1.frame.height }) else {
            throw Failure.condition("The actual presentation strip is unavailable.")
        }
        for _ in 0..<4 {
            let viewport = strip.frame.intersection(app.frame)
            if !button.frame.isEmpty && viewport.contains(button.frame) { break }
            if button.frame.midX > viewport.midX { strip.swipeLeft() } else { strip.swipeRight() }
        }
        try require(strip.frame.intersection(app.frame).contains(button.frame) && button.isHittable,
                    "The actual presentation tab must be inside its visible strip before tapping.")
        button.tap()
    }

    private func tapButton(_ id: String, in app: XCUIApplication) throws {
        let button = app.buttons[id].firstMatch
        try require(button.waitForExistence(timeout: 10) && button.isEnabled && button.isHittable,
                    "The real action must be visible and enabled: \(id)")
        button.tap()
    }

    private func waitForValueChange(_ element: XCUIElement, from oldValue: String) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", oldValue), object: element)
        try require(XCTWaiter.wait(for: [changed], timeout: 8) == .completed, "The native gesture must change the actual zoom value.")
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func visibleViewport(in app: XCUIApplication) -> CGRect {
        var viewport = app.frame
        for cover in app.tabBars.allElementsBoundByIndex + app.keyboards.allElementsBoundByIndex {
            if cover.frame.intersects(viewport) && cover.frame.minY > viewport.minY {
                viewport.size.height = min(viewport.maxY, cover.frame.minY) - viewport.minY
            }
        }
        return viewport
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { XCTFail(message); throw Failure.condition(message) }
    }

    private func checked(_ name: String) throws {
        checks.append(name)
        try persist()
    }

    private func persist() throws {
        receipt["checks"] = checks
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifacts.appendingPathComponent("workspace-presentation-persistence.json"), options: .atomic)
    }

    private func capture(_ app: XCUIApplication, _ name: String) throws {
        let destination = artifacts.appendingPathComponent(name + ".png")
        try require(!FileManager.default.fileExists(atPath: destination.path), "Raw screenshots must never be replaced.")
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(to: destination, options: .atomic)
        let observed = app.debugDescription
        let hierarchy = XCTAttachment(string: observed)
        hierarchy.name = name + "-observed-elements"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        try observed.write(to: artifacts.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }
}
#endif
