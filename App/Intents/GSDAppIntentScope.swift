import Foundation
import Observation
import UIKit
import GSDModel
import GSDStore
import GSDSnapshot

enum GSDAppIntentScopeError: LocalizedError {
    case selectionExpired
    case identityUnavailable

    var errorDescription: String? {
        switch self {
        case .selectionExpired:
            String(localized: "This task selection is no longer valid. Select the task again.")
        case .identityUnavailable:
            String(localized: "GSD cannot verify the current account or task collection. Open GSD and try again.")
        }
    }
}

/// A persisted Shortcut refers to one task in one account/dataset, even after relaunch.
/// A legacy raw task ID has no provable origin and must be selected again.
private struct GSDIntentTaskReference: Codable {
    static let prefix = "gsd-task-v1:"
    let version: Int
    let taskID: String
    let scope: WatchAccountScope

    init(taskID: String, scope: WatchAccountScope) {
        version = 1
        self.taskID = taskID
        self.scope = scope
    }

    func identifier() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.prefix + (try encoder.encode(self)).base64EncodedString()
    }

    static func decode(_ identifier: String) throws -> Self {
        guard identifier.hasPrefix(prefix),
              let data = Data(base64Encoded: String(identifier.dropFirst(prefix.count))),
              let reference = try? JSONDecoder().decode(Self.self, from: data),
              reference.version == 1, !reference.taskID.isEmpty, reference.scope.isValid else {
            throw GSDAppIntentScopeError.selectionExpired
        }
        return reference
    }
}

/// One app-wired context for Siri/Shortcuts queries and mutations. The shared admission gate
/// keeps an accepted write on its original dataset until the existing TaskStore operation
/// finishes; confirmed sign-in/reset/import transitions drain that ticket before replacing data.
@MainActor
final class GSDAppIntentScope {
    struct Selection: Sendable {
        let identifier: String
        let task: GSDModel.Task
    }

    private let store: TaskStore
    private let mutationGate: WatchMutationGate
    private let scopeProvider: @MainActor @Sendable () -> WatchAccountScope?
    private var observedScope: WatchAccountScope?
    private var scopeIsStable = false
    private var generation: UInt64 = 0
    private let databaseWindow = BackgroundDatabaseWindow(isBackgrounded: {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIApplication.shared.applicationState != .active
        #endif
    })

    init(store: TaskStore, mutationGate: WatchMutationGate,
         scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?) {
        self.store = store
        self.mutationGate = mutationGate
        self.scopeProvider = scopeProvider
        observeScope()
    }

    private func readScope() -> WatchAccountScope? {
        guard !mutationGate.isPaused, let dataset = mutationGate.identity?.datasetID,
              let scope = scopeProvider(), scope.isValid, scope.datasetID == dataset else { return nil }
        return scope
    }

    private var currentScope: WatchAccountScope? {
        guard scopeIsStable, let scope = readScope(), scope == observedScope else { return nil }
        return scope
    }

    private func observeScope() {
        observedScope = withObservationTracking {
            readScope()
        } onChange: { [weak self] in
            // SessionStore and the gate are MainActor objects. Invalidate at willSet,
            // including A -> unresolved -> A while a canonical query is suspended.
            MainActor.assumeIsolated { self?.invalidateScope() }
        }
        scopeIsStable = true
    }

    private func invalidateScope() {
        generation &+= 1
        scopeIsStable = false
        _Concurrency.Task { @MainActor [weak self] in self?.observeScope() }
    }

    private func requireCurrent(_ scope: WatchAccountScope, generation: UInt64) throws {
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard generation == self.generation, currentScope == scope else {
            throw GSDAppIntentScopeError.identityUnavailable
        }
    }

    private func withCurrentScope<T>(
        _ body: @MainActor (WatchAccountScope, UInt64) async throws -> T
    ) async throws -> T {
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard let scope = currentScope, let ticket = mutationGate.admit() else {
            throw GSDAppIntentScopeError.identityUnavailable
        }
        let generation = self.generation
        defer { mutationGate.finish(ticket) }
        return try await databaseWindow.run {
            try requireCurrent(scope, generation: generation)
            return try await body(scope, generation)
        }
    }

    private func selection(_ task: GSDModel.Task, scope: WatchAccountScope) throws -> Selection {
        Selection(identifier: try GSDIntentTaskReference(taskID: task.id, scope: scope).identifier(), task: task)
    }

    func entities(for identifiers: [String]) async throws -> [Selection] {
        let references = try identifiers.map(GSDIntentTaskReference.decode)
        return try await withCurrentScope { scope, generation in
            guard references.allSatisfy({ $0.scope == scope }) else {
                throw GSDAppIntentScopeError.selectionExpired
            }
            var found: [Selection] = []
            for reference in references {
                let task = try await store.fetchTask(id: reference.taskID)
                try requireCurrent(scope, generation: generation)
                if let task { found.append(try selection(task, scope: scope)) }
            }
            return found
        }
    }

    func suggestedEntities() async throws -> [Selection] {
        try await withCurrentScope { scope, generation in
            let rows = try await store.fetchAllTasks()
            try requireCurrent(scope, generation: generation)
            return try rows.filter { !$0.completed && !$0.isSaved }.prefix(20)
                .map { try selection($0, scope: scope) }
        }
    }

    func entities(matching string: String) async throws -> [Selection] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await withCurrentScope { scope, generation in
            let rows = try await store.fetchAllTasks()
            try requireCurrent(scope, generation: generation)
            return try rows.filter { task in
                !task.isSaved && (query.isEmpty
                || task.title.lowercased().contains(query)
                || task.tags.contains { $0.lowercased().contains(query) })
            }.prefix(20).map { try selection($0, scope: scope) }
        }
    }

    func create(_ parsed: ParsedCapture, quadrant: Quadrant?, dueDate: Date?) async throws {
        try await withCurrentScope { _, _ in
            try await store.add(parsed, override: quadrant, dueDate: dueDate)
        }
    }

    func complete(identifier: String) async throws -> String? {
        let reference = try GSDIntentTaskReference.decode(identifier)
        return try await withCurrentScope { scope, generation in
            guard reference.scope == scope else { throw GSDAppIntentScopeError.selectionExpired }
            let task = try await store.fetchTask(id: reference.taskID)
            try requireCurrent(scope, generation: generation)
            guard let task else { return nil }
            if !task.completed { try await store.toggleComplete(task) }
            return task.title
        }
    }
}
