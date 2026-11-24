import Foundation
import GSDModel
import GSDStore

/// Resolves action IDs again so a visual card cannot write an obsolete task snapshot.
@MainActor
public struct GSDTaskWorkspaceMutations {
    private let store: TaskStore

    public init(store: TaskStore) {
        self.store = store
    }

    public func setCompleted(id: String, completed: Bool) async throws {
        let task = try await editableTask(id)
        if task.completed != completed { try await store.toggleComplete(task) }
    }

    public func moveTask(id: String, quadrant: Quadrant) async throws {
        let task = try await editableTask(id)
        try await store.move(task, to: quadrant)
    }

    public func setDueDate(id: String, date: Date?) async throws {
        let original = try await editableTask(id)
        var edited = original
        edited.dueDate = date
        if date == nil { edited.notificationEnabled = false }
        guard try await store.saveEdits(edited, openedAs: original) else {
            throw GSDTaskWorkspaceError.missingTask
        }
    }

    public func addDependency(prerequisiteID: String, dependentID: String) async throws {
        let dependent = try await editableTask(dependentID)
        try await store.addDependency(prerequisiteID, to: dependent)
    }

    public func removeDependency(prerequisiteID: String, dependentID: String) async throws {
        let dependent = try await editableTask(dependentID)
        try await store.removeDependency(prerequisiteID, from: dependent)
    }

    private func editableTask(_ id: String) async throws -> GSDModel.Task {
        guard let task = try await store.fetchTask(id: id) else {
            throw GSDTaskWorkspaceError.missingTask
        }
        guard !task.isSaved else { throw GSDTaskWorkspaceError.savedRequiresReturn }
        return task
    }
}
