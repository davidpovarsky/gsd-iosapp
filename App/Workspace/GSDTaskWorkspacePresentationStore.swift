import CryptoKit
import Foundation
import Observation
import SwiftUI
import TaskVisualizationKit

/// Only the live SessionStore identity may select an account's UI preferences.
enum GSDTaskWorkspacePresentationAccount: Hashable {
    case guest
    case account(String)

    static func validated(isSignedIn: Bool, userID: String?, inProgress: Bool,
                          hasPendingAccountSwitch: Bool) -> Self? {
        guard !inProgress, !hasPendingAccountSwitch else { return nil }
        if isSignedIn {
            guard let userID, !userID.isEmpty else { return nil }
            return .account(userID)
        }
        return userID == nil ? .guest : nil
    }
}

struct GSDTaskWorkspacePresentationScope: Hashable {
    let account: GSDTaskWorkspacePresentationAccount
    let rootTaskIDs: [String]?

    init(account: GSDTaskWorkspacePresentationAccount, rootTaskIDs: [String]?) {
        self.account = account
        self.rootTaskIDs = Self.canonicalRoots(rootTaskIDs)
    }

    static func canonicalRoots(_ taskIDs: [String]?) -> [String]? {
        taskIDs.map { Array(Set($0)).sorted() }
    }

    var storageKey: String {
        var parts = ["workspace-presentation-v1"]
        switch account {
        case .guest: parts.append("guest")
        case .account(let id): parts.append(contentsOf: ["account", id])
        }
        // nil follows all current matrix tasks; [] is an intentionally empty selection.
        parts.append(rootTaskIDs == nil ? "all-matrix-tasks" : "explicit-root-task-ids")
        parts.append(contentsOf: rootTaskIDs ?? [])
        let input = parts.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return "gsd.workspace.presentation.v1." + digest
    }
}

/// Device-local UI state only. No TaskStore, database, sync queue, or account credential is written.
@MainActor
@Observable
final class GSDTaskWorkspacePresentationStore {
    private struct Record: Codable {
        let version: Int
        let state: TaskWorkspacePresentationState
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var states: [GSDTaskWorkspacePresentationScope: TaskWorkspacePresentationState] = [:]

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load(_ scope: GSDTaskWorkspacePresentationScope) {
        guard states[scope] == nil else { return }
        let decoded = defaults.data(forKey: scope.storageKey).flatMap {
            try? JSONDecoder().decode(Record.self, from: $0)
        }
        states[scope] = decoded.flatMap { $0.version == 1 ? Self.validated($0.state) : nil } ?? .init()
    }

    func state(for scope: GSDTaskWorkspacePresentationScope) -> TaskWorkspacePresentationState {
        states[scope] ?? .init()
    }

    @discardableResult
    func save(_ state: TaskWorkspacePresentationState, for scope: GSDTaskWorkspacePresentationScope) -> Bool {
        let safe = Self.validated(state)
        guard let data = try? JSONEncoder().encode(Record(version: 1, state: safe)) else { return false }
        defaults.set(data, forKey: scope.storageKey)
        states[scope] = safe
        return true
    }

    private static func validated(_ state: TaskWorkspacePresentationState) -> TaskWorkspacePresentationState {
        let viewport = state.timelineViewport
        let zoom = viewport.zoom.isFinite ? min(16, max(1, viewport.zoom)) : 1
        let center = viewport.centerDate.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
        // Do not filter collapsed IDs against visible lanes or currently loaded tasks.
        return .init(collapsedLaneIDs: state.collapsedLaneIDs,
                     timelineViewport: .init(zoom: zoom, centerDate: center))
    }
}

/// One live view's binding lease. The repository is shared so inline/expanded/root views agree.
@MainActor
@Observable
final class GSDTaskWorkspacePresentationSession {
    @ObservationIgnored private let store: GSDTaskWorkspacePresentationStore
    @ObservationIgnored private var readAccount: (@MainActor () -> GSDTaskWorkspacePresentationAccount?)?
    @ObservationIgnored private var identityOwner: ObjectIdentifier?
    @ObservationIgnored private var rootTaskIDs: [String]?
    @ObservationIgnored private var observationID: UUID?
    private var generation = UUID()
    private var activeScope: GSDTaskWorkspacePresentationScope?

    init(store: GSDTaskWorkspacePresentationStore) { self.store = store }

    func connect(identityOwner: ObjectIdentifier, rootTaskIDs: [String]?,
                 readAccount: @escaping @MainActor () -> GSDTaskWorkspacePresentationAccount?) {
        let roots = GSDTaskWorkspacePresentationScope.canonicalRoots(rootTaskIDs)
        guard self.identityOwner != identityOwner || self.rootTaskIDs != roots || self.readAccount == nil else { return }
        disconnect()
        self.identityOwner = identityOwner
        self.rootTaskIDs = roots
        self.readAccount = readAccount
        reload()
        observeAccount()
    }

    func disconnect() {
        observationID = nil
        readAccount = nil
        identityOwner = nil
        activeScope = nil
        generation = UUID()
    }

    var binding: Binding<TaskWorkspacePresentationState> {
        let expectedGeneration = generation
        let expectedScope = activeScope
        return Binding(
            get: { [weak self] in
                guard let self, let scope = expectedScope,
                      self.isCurrent(scope, generation: expectedGeneration) else { return .init() }
                return self.store.state(for: scope)
            },
            set: { [weak self] value in
                guard let self, let scope = expectedScope,
                      self.isCurrent(scope, generation: expectedGeneration) else { return }
                self.store.save(value, for: scope)
            }
        )
    }

    private func isCurrent(_ scope: GSDTaskWorkspacePresentationScope, generation: UUID) -> Bool {
        self.generation == generation && activeScope == scope && rootTaskIDs == scope.rootTaskIDs
            && readAccount?() == scope.account
    }

    private func reload() {
        guard let account = readAccount?() else { activeScope = nil; return }
        let scope = GSDTaskWorkspacePresentationScope(account: account, rootTaskIDs: rootTaskIDs)
        store.load(scope)
        activeScope = scope
    }

    private func observeAccount() {
        guard let readAccount else { return }
        let token = UUID()
        observationID = token
        withObservationTracking {
            _ = readAccount()
        } onChange: { [weak self] in
            // The observed canonical identity fields and this context are MainActor-owned.
            // Invalidate synchronously on willSet: A -> unresolved -> A cannot revive an old binding.
            MainActor.assumeIsolated { self?.accountWillChange(observation: token) }
        }
    }

    private func accountWillChange(observation: UUID) {
        guard observationID == observation else { return }
        let rearm = UUID()
        observationID = rearm
        activeScope = nil
        generation = UUID()
        // Observation calls onChange before the field is assigned. Read the settled identity
        // in the next actor turn; the old generation is already unusable during that interval.
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, self.observationID == rearm, self.readAccount != nil else { return }
            self.reload()
            self.observeAccount()
        }
    }
}
