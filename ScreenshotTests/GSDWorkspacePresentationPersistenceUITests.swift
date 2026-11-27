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
    private typealias Account = GSDTaskWorkspacePresentationAccount
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
    private final class Identity {
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
            ("session_resolution_holds_identity_until_apply", accountResolution)
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
}
#endif
