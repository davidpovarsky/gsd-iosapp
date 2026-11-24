import Foundation
import XCTest
import GSDModel
import GSDStore
import HanlinHostContracts
import HanlinPlatformContracts
@testable import GSDHanlinAgent

@MainActor
final class GSDTaskWorkspaceTests: XCTestCase {
    private func task(_ id: String, dependencies: [String] = [], saved: Bool = false) -> GSDModel.Task {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return .init(id: id, title: id, urgent: false, important: true,
                     createdAt: now, updatedAt: now, dependencies: dependencies,
                     savedAt: saved ? now : nil)
    }

    private func fixture() throws -> TaskStore {
        let database = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(database),
                         smartViewRepository: GRDBSmartViewRepository(database),
                         archiveRepository: GRDBArchiveRepository(database),
                         trashRepository: GRDBTrashRepository(database),
                         syncQueue: GRDBSyncQueueRepository(database))
    }

    private func storedTask(_ id: String, in store: TaskStore) async throws -> GSDModel.Task {
        let stored = try await store.fetchTask(id: id)
        return try XCTUnwrap(stored)
    }

    func testSelectionIncludesSavedAndTransitivePrerequisitesWithoutRecurrenceParent() throws {
        let first = task("first", saved: true)
        let second = task("second", dependencies: ["first"])
        var final = task("final", dependencies: ["second"])
        final.parentTaskId = "recurrence-parent"
        let all = [first, second, final, task("recurrence-parent"), task("unrelated")]
        let request = try GSDTaskWorkspaceRequest.validated(
            presentation: "graph", title: "Launch", taskIDs: ["final", "final"], tasks: all)
        XCTAssertEqual(request.taskIDs, ["final"])
        XCTAssertEqual(request.visibleTasks(in: all).map(\.id), ["first", "second", "final"])
        XCTAssertTrue(DependencyGraph(tasks: all).isBlocked("final"))
    }

    func testAllTasksSelectionRemainsLiveAndOnlyIncludesReferencedSavedTasks() throws {
        let saved = task("saved", saved: true)
        let original = [saved, task("unused-saved", saved: true), task("active", dependencies: ["saved"])]
        let request = try GSDTaskWorkspaceRequest.validated(
            presentation: "board", title: nil, taskIDs: nil, tasks: original)
        XCTAssertNil(request.taskIDs)
        XCTAssertEqual(request.visibleTasks(in: original + [task("new-task")]).map(\.id),
                       ["saved", "active", "new-task"])
    }

    func testInvalidModeAndMissingSelectionAreRejected() throws {
        XCTAssertThrowsError(try GSDTaskWorkspaceRequest.validated(
            presentation: "invented", title: nil, taskIDs: nil, tasks: []))
        XCTAssertThrowsError(try GSDTaskWorkspaceRequest.validated(
            presentation: "graph", title: nil, taskIDs: ["missing"], tasks: []))
        XCTAssertThrowsError(try JSONDecoder().decode(
            GSDTaskWorkspaceRequest.self,
            from: Data(#"{"presentation":"invented","taskIDs":[]}"#.utf8)))
    }

    func testWorkspaceMutationsPersistAndPreserveUnchangedFields() async throws {
        let store = try fixture()
        var original = task("editable")
        original.description = "Keep this context"
        original.tags = ["work"]
        try await store.create(original)
        let commands = GSDTaskWorkspaceMutations(store: store)
        try await commands.moveTask(id: original.id, quadrant: .urgentNotImportant)
        let due = Date(timeIntervalSince1970: 1_800_086_400)
        try await commands.setDueDate(id: original.id, date: due)
        try await commands.setCompleted(id: original.id, completed: true)
        try await commands.setCompleted(id: original.id, completed: true)
        let persisted = try await storedTask(original.id, in: store)
        XCTAssertEqual(persisted.quadrant, .urgentNotImportant)
        XCTAssertEqual(persisted.description, original.description)
        XCTAssertEqual(persisted.tags, original.tags)
        XCTAssertEqual(persisted.dueDate, due)
        XCTAssertTrue(persisted.completed)
        let rows = try await store.fetchAllTasks()
        XCTAssertEqual(rows.count, 1)
    }

    func testDependencyMutationsUsePersistedTasksAndRejectCycles() async throws {
        let store = try fixture()
        try await store.create(task("first"))
        try await store.create(task("second"))
        let commands = GSDTaskWorkspaceMutations(store: store)
        try await commands.addDependency(prerequisiteID: "first", dependentID: "second")
        var edited = try await storedTask("second", in: store)
        edited.title = "Changed elsewhere"
        try await store.save(edited)
        do {
            try await commands.addDependency(prerequisiteID: "second", dependentID: "first")
            XCTFail("A dependency cycle must fail")
        } catch {
            XCTAssertEqual(error as? DependencyError, .cycle)
        }
        try await commands.removeDependency(prerequisiteID: "first", dependentID: "second")
        let second = try await storedTask("second", in: store)
        XCTAssertEqual(second.title, "Changed elsewhere")
        XCTAssertTrue(second.dependencies.isEmpty)
    }

    func testSavedAndMissingTasksCannotBeMutatedThroughWorkspace() async throws {
        let store = try fixture()
        try await store.create(task("saved", saved: true))
        let commands = GSDTaskWorkspaceMutations(store: store)
        do {
            try await commands.setCompleted(id: "saved", completed: true)
            XCTFail("Saved tasks require return to the matrix")
        } catch {
            XCTAssertEqual(error as? GSDTaskWorkspaceError, .savedRequiresReturn)
        }
        do {
            try await commands.setCompleted(id: "gone", completed: true)
            XCTFail("Missing task must not be recreated")
        } catch {
            XCTAssertEqual(error as? GSDTaskWorkspaceError, .missingTask)
        }
        let rows = try await store.fetchAllTasks()
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(try XCTUnwrap(rows.first).completed)
    }

    func testPresentationToolIsReadOnlyAndResolvesLiveTaskSelection() async throws {
        let store = try fixture()
        let original = task("launch")
        try await store.create(original)
        let before = try await store.fetchAllTasks()
        let namespace = try HanlinConversationNamespace(
            app: "gsd", account: "testing", workspace: "local", space: "tasks")
        let context = HanlinHostContext(namespace: namespace, sceneID: UUID(), generation: UUID())
        let host = GSDHanlinHost(store: store, context: context)
        let result = await host.invokeRemoteTool(
            name: "show_task_workspace",
            argumentsJSON: Data(#"{"presentation":"timeline","ids":["launch"],"title":"Launch plan"}"#.utf8),
            remoteRequestID: "workspace-read-only-12345")
        XCTAssertFalse(result.isError, result.text)
        let request = try JSONDecoder().decode(GSDTaskWorkspaceRequest.self, from: Data(result.text.utf8))
        XCTAssertEqual(request.presentation, .timeline)
        XCTAssertEqual(request.taskIDs, ["launch"])
        let after = try await store.fetchAllTasks()
        XCTAssertEqual(after, before)
    }
}
