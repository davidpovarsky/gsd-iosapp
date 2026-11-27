import Foundation
import GRDB
import Testing
import GSDModel
@testable import GSDStore

/// Real SQLite repositories exercise persisted authority and TaskStore mutation ordering.
/// Faults are injected only at the queue boundary; canonical rows/outbox are read from GRDB.
@MainActor
struct ShareGenerationQueueTests {
    private enum InjectedFailure: Error, Equatable { case enqueue, read, waitTimeout }

    private final class FaultQueue: SyncQueueRepository {
        let base: GRDBSyncQueueRepository
        let failEnqueue: Bool
        let failRead: Bool

        init(_ base: GRDBSyncQueueRepository, failEnqueue: Bool = false, failRead: Bool = false) {
            self.base = base
            self.failEnqueue = failEnqueue
            self.failRead = failRead
        }

        func enqueue(_ item: SyncQueueItem) async throws {
            if failEnqueue { throw InjectedFailure.enqueue }
            try await base.enqueue(item)
        }
        func enqueueClearingWrites(_ item: SyncQueueItem) async throws {
            if failEnqueue { throw InjectedFailure.enqueue }
            try await base.enqueueClearingWrites(item)
        }
        func enqueueIfLive(_ item: SyncQueueItem) async throws -> Bool {
            if failEnqueue { throw InjectedFailure.enqueue }
            return try await base.enqueueIfLive(item)
        }
        func pending() async throws -> [SyncQueueItem] { try await base.pending() }
        func update(_ item: SyncQueueItem) async throws { try await base.update(item) }
        func remove(id: String) async throws { try await base.remove(id: id) }
        func allTaskIds() async throws -> Set<String> { try await base.allTaskIds() }
        func all() async throws -> [SyncQueueItem] {
            if failRead { throw InjectedFailure.read }
            return try await base.all()
        }
    }

    private actor HeldUpsertRepository: TaskRepository {
        let base: GRDBTaskRepository
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ base: GRDBTaskRepository) { self.base = base }

        func upsert(_ task: GSDModel.Task) async throws {
            if !entered {
                entered = true
                if !released {
                    await withCheckedContinuation { continuation = $0 }
                }
            }
            try await base.upsert(task)
        }
        func hasEntered() -> Bool { entered }
        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
        func fetchAll() async throws -> [GSDModel.Task] { try await base.fetchAll() }
        func fetch(id: String) async throws -> GSDModel.Task? { try await base.fetch(id: id) }
        func setNotifyBeforeIfNull(id: String, value: Int) async throws {
            try await base.setNotifyBeforeIfNull(id: id, value: value)
        }
        func restampIfUnchanged(id: String, from: Date, to: Date) async throws -> Bool {
            try await base.restampIfUnchanged(id: id, from: from, to: to)
        }
        func delete(id: String) async throws { try await base.delete(id: id) }
        func replaceAll(_ tasks: [GSDModel.Task]) async throws { try await base.replaceAll(tasks) }
        func replaceAll(
            _ tasks: [GSDModel.Task], queueing items: [SyncQueueItem],
            deletingLeftOut makeDelete: @Sendable (String) -> SyncQueueItem
        ) async throws {
            try await base.replaceAll(tasks, queueing: items, deletingLeftOut: makeDelete)
        }
        nonisolated func observeAll() -> AsyncThrowingStream<[GSDModel.Task], Error> {
            base.observeAll()
        }
    }

    @MainActor private final class CompletionState { var finished = false }

    private struct Rig {
        let database: AppDatabase
        let repository: GRDBTaskRepository
        let queue: GRDBSyncQueueRepository
        let store: TaskStore
    }

    private func makeStore(
        _ database: AppDatabase,
        repository: any TaskRepository,
        queue: any SyncQueueRepository
    ) -> TaskStore {
        TaskStore(
            repository: repository,
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            trashRepository: GRDBTrashRepository(database),
            defaults: UserDefaults(suiteName: "dataset-queue-\(UUID().uuidString)")!,
            clock: { Date(timeIntervalSince1970: 2_000) },
            syncQueue: queue)
    }

    private func rig(failEnqueue: Bool = false, failRead: Bool = false) throws -> Rig {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTaskRepository(database)
        let queue = GRDBSyncQueueRepository(database)
        let store = makeStore(
            database, repository: repository,
            queue: FaultQueue(queue, failEnqueue: failEnqueue, failRead: failRead))
        return Rig(database: database, repository: repository, queue: queue, store: store)
    }

    private func task(_ id: String = "shared-task", title: String = "Original task") -> GSDModel.Task {
        GSDModel.Task(
            id: id, title: title, urgent: false, important: false,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000), notifyBefore: 15)
    }

    private func item(
        _ task: GSDModel.Task,
        id: String = "original-queue",
        generation: String? = "generation-A",
        status: SyncQueueItem.Status = .pending,
        operation: SyncQueueItem.Operation = .create,
        timestamp: Int = 1
    ) -> SyncQueueItem {
        SyncQueueItem(
            id: id, taskId: task.id, operation: operation, timestamp: timestamp,
            retryCount: status == .failed ? 3 : 0,
            payload: operation == .delete ? nil : task, status: status,
            lastError: status == .failed ? "fixture failed delivery" : nil,
            serverDatasetGeneration: generation)
    }

    private func seed(_ rig: Rig, status: SyncQueueItem.Status = .pending) async throws -> GSDModel.Task {
        let original = task()
        try await rig.repository.upsert(original)
        try await rig.queue.enqueue(item(original, status: status))
        return try #require(try await rig.repository.fetch(id: original.id))
    }

    @Test func generationPersistsAcrossSQLiteCloseAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gsd-queue-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.sqlite").path
        let expected = [
            item(task("pending"), id: "pending", generation: "0"),
            item(task("failed"), id: "failed", generation: "generation-original", status: .failed, timestamp: 2),
            item(task("legacy"), id: "legacy", generation: nil, timestamp: 3)
        ]
        do {
            let writer = try DatabaseQueue(path: path)
            let database = try AppDatabase(writer)
            let queue = GRDBSyncQueueRepository(database)
            for item in expected { try await queue.enqueue(item) }
            try writer.close()
        }
        do {
            let writer = try DatabaseQueue(path: path)
            let database = try AppDatabase(writer)
            let queue = GRDBSyncQueueRepository(database)
            #expect(try await queue.all() == expected)
            #expect(try await queue.pending().map(\.id) == ["pending", "legacy"])
            try writer.close()
        }
    }

    @Test func createInheritsAnExistingPendingGeneration() async throws {
        let rig = try rig()
        let original = task()
        let queued = item(original)
        try await rig.queue.enqueue(queued)
        try await rig.store.create(original)
        let rows = try await rig.queue.all()
        let created = try #require(rows.first { $0.id != queued.id })
        #expect(created.operation == .create)
        #expect(created.serverDatasetGeneration == "generation-A")
        #expect(rows.first { $0.id == queued.id } == queued)
        #expect(try await rig.repository.fetch(id: original.id)?.title == original.title)
    }

    @Test func saveInheritsAnExistingFailedGeneration() async throws {
        let rig = try rig()
        let original = try await seed(rig, status: .failed)
        let before = try await rig.queue.all()
        var edited = original
        edited.title = "Saved edit"
        try await rig.store.save(edited)
        let rows = try await rig.queue.all()
        let update = try #require(rows.first { $0.id != "original-queue" })
        #expect(update.operation == .update)
        #expect(update.serverDatasetGeneration == "generation-A")
        #expect(rows.first { $0.id == "original-queue" } == before.first)
        #expect(try await rig.repository.fetch(id: original.id)?.title == "Saved edit")
    }

    @Test func ordinaryMoveInheritsThePendingGeneration() async throws {
        let rig = try rig()
        let original = try await seed(rig)
        try await rig.store.move(original, to: .urgentImportant)
        let rows = try await rig.queue.all()
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.serverDatasetGeneration == "generation-A" })
        #expect(try await rig.repository.fetch(id: original.id)?.quadrant == .urgentImportant)
    }

    @Test func boundQueueWriteFailureKeepsTheTaskAndOriginalOutbox() async throws {
        let rig = try rig(failEnqueue: true)
        let original = try await seed(rig, status: .failed)
        let before = try await rig.queue.all()
        var edited = original
        edited.title = "Must not land"
        await #expect(throws: InjectedFailure.enqueue) { try await rig.store.save(edited) }
        #expect(try await rig.repository.fetch(id: original.id) == original)
        #expect(try await rig.queue.all() == before)
    }

    @Test func bindingReadFailureKeepsTheTaskAndOriginalOutbox() async throws {
        let rig = try rig(failRead: true)
        let original = try await seed(rig)
        let before = try await rig.queue.all()
        var edited = original
        edited.title = "Must not land"
        await #expect(throws: InjectedFailure.read) { try await rig.store.save(edited) }
        #expect(try await rig.repository.fetch(id: original.id) == original)
        #expect(try await rig.queue.all() == before)
    }

    @Test func conflictingBindingsCannotOverwriteTaskOrQueue() async throws {
        for (first, second) in [("generation-A", "generation-B"), ("e\u{0301}", "\u{00e9}")] {
            let rig = try rig()
            let original = task()
            try await rig.repository.upsert(original)
            try await rig.queue.enqueue(item(original, id: "pending", generation: first))
            try await rig.queue.enqueue(item(
                original, id: "failed-delete", generation: second, status: .failed,
                operation: .delete, timestamp: 2))
            let stored = try #require(try await rig.repository.fetch(id: original.id))
            let before = try await rig.queue.all()
            var edited = stored
            edited.title = "Must not land"
            await #expect(throws: SyncQueueGenerationError.conflictingGenerations) {
                try await rig.store.save(edited)
            }
            #expect(try await rig.repository.fetch(id: original.id) == stored)
            #expect(try await rig.queue.all() == before)
        }
    }

    @Test func invalidStoredBindingFailsClosed() async throws {
        for generation in ["", String(repeating: "é", count: 65), "invalid\nvalue"] {
            let rig = try rig()
            let original = task()
            try await rig.repository.upsert(original)
            try await rig.queue.enqueue(item(original, generation: generation))
            let stored = try #require(try await rig.repository.fetch(id: original.id))
            let before = try await rig.queue.all()
            var edited = stored
            edited.title = "Must not land"
            await #expect(throws: SyncQueueGenerationError.invalidGeneration) {
                try await rig.store.save(edited)
            }
            #expect(try await rig.repository.fetch(id: original.id) == stored)
            #expect(try await rig.queue.all() == before)
        }
    }

    @Test func unboundQueueFailureKeepsTheExistingLocalWriteContract() async throws {
        let rig = try rig(failEnqueue: true)
        let original = task()
        try await rig.repository.upsert(original)
        var edited = original
        edited.title = "Local edit remains available"
        try await rig.store.save(edited)
        #expect(try await rig.repository.fetch(id: original.id)?.title == edited.title)
        #expect(try await rig.queue.all().isEmpty)
    }

    @Test func trashAndRestoreCarryTheOriginalGeneration() async throws {
        let rig = try rig()
        let original = try await seed(rig, status: .failed)
        try await rig.store.delete(original)
        let deleted = try await rig.queue.all()
        #expect(deleted.count == 1)
        #expect(deleted.first?.operation == .delete)
        #expect(deleted.first?.serverDatasetGeneration == "generation-A")
        #expect(try await rig.repository.fetch(id: original.id) == nil)
        try await rig.store.restoreFromTrash(id: original.id)
        let restored = try await rig.queue.all()
        #expect(restored.count == 1)
        #expect(restored.first?.operation == .create)
        #expect(restored.first?.serverDatasetGeneration == "generation-A")
        #expect(try await rig.repository.fetch(id: original.id)?.title == original.title)
    }

    @Test func archiveAndRestoreCarryTheOriginalGeneration() async throws {
        let rig = try rig()
        let original = try await seed(rig)
        try await rig.store.archive(original)
        let archived = try await rig.queue.all()
        #expect(archived.count == 1)
        #expect(archived.first?.operation == .delete)
        #expect(archived.first?.serverDatasetGeneration == "generation-A")
        try await rig.store.restore(original)
        let restored = try await rig.queue.all()
        #expect(restored.contains { $0.operation == .update })
        #expect(restored.allSatisfy { $0.serverDatasetGeneration == "generation-A" })
        #expect(try await rig.repository.fetch(id: original.id)?.title == original.title)
    }

    @Test func replaceRetainsBindingsForKeptAndRemovedTasks() async throws {
        let rig = try rig()
        let removed = task("removed")
        let kept = task("kept")
        try await rig.repository.upsert(removed)
        try await rig.repository.upsert(kept)
        try await rig.queue.enqueue(item(removed, id: "removed-old", generation: "generation-A", status: .failed))
        try await rig.queue.enqueue(item(kept, id: "kept-old", generation: "generation-B", timestamp: 2))
        let data = try TaskExport.encode(TaskExport(tasks: [kept], exportedAt: Date(timeIntervalSince1970: 3_000)))
        _ = try await rig.store.importTasks(data, mode: .replace)
        let rows = try await rig.queue.all()
        let deletion = try #require(rows.first { $0.taskId == removed.id && $0.operation == .delete })
        let update = try #require(rows.first { $0.taskId == kept.id && $0.id != "kept-old" })
        #expect(deletion.serverDatasetGeneration == "generation-A")
        #expect(update.serverDatasetGeneration == "generation-B")
        #expect(!rows.contains { $0.taskId == removed.id && $0.operation != .delete })
        #expect(try await rig.repository.fetch(id: removed.id) == nil)
        #expect(try await rig.repository.fetch(id: kept.id)?.title == kept.title)
    }

    @Test func concurrentCreateAndReplaceCannotLoseBindingOrRecreateTheTask() async throws {
        let rig = try rig()
        let held = HeldUpsertRepository(rig.repository)
        let store = makeStore(rig.database, repository: held, queue: rig.queue)
        let original = task()
        try await rig.queue.enqueue(item(original))
        let empty = try TaskExport.encode(TaskExport(tasks: [], exportedAt: Date(timeIntervalSince1970: 3_000)))
        let created = _Concurrency.Task { try await store.create(original) }
        var replaced: _Concurrency.Task<ImportResult, Error>?
        let completion = CompletionState()
        do {
            var entered = false
            for _ in 0..<500 {
                if await held.hasEntered() { entered = true; break }
                try await _Concurrency.Task.sleep(for: .milliseconds(10))
            }
            guard entered else { throw InjectedFailure.waitTimeout }
            replaced = _Concurrency.Task { @MainActor in
                defer { completion.finished = true }
                return try await store.importTasks(empty, mode: .replace)
            }
            try await _Concurrency.Task.sleep(for: .milliseconds(100))
            #expect(!completion.finished)
            await held.release()
            try await created.value
            _ = try await replaced?.value
        } catch {
            await held.release()
            _ = try? await created.value
            _ = try? await replaced?.value
            throw error
        }
        #expect(try await rig.repository.fetch(id: original.id) == nil)
        let rows = try await rig.queue.all()
        #expect(rows.count == 1)
        #expect(rows.first?.operation == .delete)
        #expect(rows.first?.serverDatasetGeneration == "generation-A")
    }
}
