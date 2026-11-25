import Foundation
import XCTest
import GRDB
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

    func testWorkspaceWritesSurviveDatabaseReopenAndRetainSyncPayloads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GSDWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite").path
        let due = Date(timeIntervalSince1970: 1_800_086_400)
        try await writePersistentWorkspace(at: path, due: due)

        let reopened = try AppDatabase(try DatabaseQueue(path: path))
        let repository = GRDBTaskRepository(reopened)
        let stored = try await repository.fetch(id: "launch")
        let task = try XCTUnwrap(stored)
        XCTAssertTrue(task.completed)
        XCTAssertEqual(task.quadrant, .urgentNotImportant)
        XCTAssertEqual(task.dueDate, due)
        XCTAssertEqual(task.dependencies, ["prerequisite"])
        XCTAssertEqual(task.title, "תכנון השקה")
        XCTAssertEqual(task.description, "Context from another surface")

        let queue = try await GRDBSyncQueueRepository(reopened).pending()
        let writes = queue.filter { $0.taskId == "launch" && $0.operation == .update }
        XCTAssertTrue(writes.contains { $0.payload?.completed == true
            && $0.payload?.dueDate == due
            && $0.payload?.quadrant == .urgentNotImportant
            && $0.payload?.dependencies == ["prerequisite"] })
        let all = try await repository.fetchAll()
        XCTAssertEqual(all.count, 2)
        try reopened.writer.close()
    }

    private func writePersistentWorkspace(at path: String, due: Date) async throws {
        let database = try AppDatabase(try DatabaseQueue(path: path))
        try await exercisePersistentWorkspace(database: database, due: due)
        try database.writer.close()
    }

    private func exercisePersistentWorkspace(database: AppDatabase, due: Date) async throws {
        let repository = GRDBTaskRepository(database)
        let store = TaskStore(
            repository: repository,
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            trashRepository: GRDBTrashRepository(database),
            syncQueue: GRDBSyncQueueRepository(database))
        try await store.create(task("prerequisite"))
        var launch = task("launch")
        launch.title = "תכנון השקה"
        try await store.create(launch)
        store.start()

        let commands = GSDTaskWorkspaceMutations(store: store)
        try await commands.addDependency(prerequisiteID: "prerequisite", dependentID: "launch")
        try await commands.moveTask(id: "launch", quadrant: .urgentNotImportant)
        var external = try await storedTask("launch", in: store)
        external.description = "Context from another surface"
        try await repository.upsert(external)
        try await commands.setDueDate(id: "launch", date: due)
        try await commands.setCompleted(id: "launch", completed: true)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if store.tasks.first(where: { $0.id == "launch" })?.completed == true { break }
            try await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        let observed = try XCTUnwrap(store.tasks.first { $0.id == "launch" })
        XCTAssertTrue(observed.completed)
        XCTAssertEqual(observed.description, external.description)
        for mode in GSDTaskWorkspacePresentation.allCases {
            let snapshot = GSDTaskWorkspaceRequest(presentation: mode).visibleTasks(in: store.tasks)
            XCTAssertEqual(snapshot.first { $0.id == "launch" }, observed)
        }
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
