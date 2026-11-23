import Foundation
import Testing
import GSDModel
@testable import GSDStore

struct CloudLibrarySyncTests {
    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    private func task(_ id: String = "library-task-01") -> GSDModel.Task {
        GSDModel.Task(id: id, title: "Archive payload", urgent: false, important: true,
                      createdAt: stamp, updatedAt: stamp, timeEntries: [
                        TimeEntry(id: "timer001", startedAt: stamp, endedAt: stamp.addingTimeInterval(91), notes: "Preserve")
                      ])
    }

    @Test func archiveAndCustomViewApplyToTheOriginalRepositories() async throws {
        let origin = try AppDatabase.inMemory(), destination = try AppDatabase.inMemory()
        let source = GRDBCloudLibraryRepository(origin), target = GRDBCloudLibraryRepository(destination)
        try await GRDBArchiveRepository(origin).archive(task(), at: stamp.addingTimeInterval(5))
        let view = SmartView(id: "custom-view-01", name: "Cloud view", icon: "cloud",
                             criteria: FilterCriteria(tags: ["cloud"]), isBuiltIn: false)
        try await GRDBSmartViewRepository(origin).upsert(view, createdAt: stamp, updatedAt: stamp)
        let changes = try await source.capture(owner: "account-a", now: stamp)
        #expect(changes.count == 2)
        for change in changes {
            try await target.apply(change.item, owner: "account-a", stampedAt: stamp.addingTimeInterval(5))
            try await source.acknowledge(change.item, owner: "account-a")
        }
        #expect(try await GRDBArchiveRepository(destination).fetchAll() == [task()])
        #expect(try await GRDBSmartViewRepository(destination).fetchAll() == [view])
        #expect(try await source.capture(owner: "account-a", now: stamp).allSatisfy { !$0.pending })
        #expect(try await target.capture(owner: "account-a", now: stamp).allSatisfy { !$0.pending })
    }

    @Test func localDeletionProducesDurableOwnerScopedTombstone() async throws {
        let db = try AppDatabase.inMemory(), destination = try AppDatabase.inMemory()
        let library = GRDBCloudLibraryRepository(db), target = GRDBCloudLibraryRepository(destination)
        let archive = GRDBArchiveRepository(db)
        try await archive.archive(task(), at: stamp)
        let original = try #require(try await library.capture(owner: "account-a", now: stamp).first)
        try await target.apply(original.item, owner: "account-a", stampedAt: stamp)
        try await library.acknowledge(original.item, owner: "account-a")
        try await archive.deletePermanently(id: task().id)
        let removed = try #require(try await library.capture(owner: "account-a", now: stamp.addingTimeInterval(1)).first)
        #expect(removed.pending && removed.item.deleted)
        try await target.apply(removed.item, owner: "account-a", stampedAt: stamp.addingTimeInterval(1))
        #expect(try await GRDBArchiveRepository(destination).fetchAll().isEmpty)
        #expect(try await library.capture(owner: "account-b", now: stamp).isEmpty)
    }

    @Test func remoteTrashCannotDestroyANewerPendingLocalEdit() async throws {
        let sourceDB = try AppDatabase.inMemory(), destination = try AppDatabase.inMemory()
        try await GRDBTrashRepository(sourceDB).trash(task(), at: stamp)
        let remote = try #require(try await GRDBCloudLibraryRepository(sourceDB).capture(owner: "a", now: stamp).first)
        var newer = task()
        newer.title = "Newer offline edit"; newer.updatedAt = stamp.addingTimeInterval(10)
        try await GRDBTaskRepository(destination).upsert(newer)
        let target = GRDBCloudLibraryRepository(destination)
        try await target.apply(remote.item, owner: "a", stampedAt: stamp)
        #expect(try await GRDBTaskRepository(destination).fetch(id: newer.id) == newer)
        #expect(try await GRDBTrashRepository(destination).fetchAll().isEmpty)
        let healing = try #require(try await target.capture(owner: "a", now: stamp.addingTimeInterval(11)).first)
        #expect(healing.item.deleted && healing.pending)
    }

    @Test func freshAccountResetCannotUploadOldDeletionMetadata() async throws {
        let db = try AppDatabase.inMemory()
        let library = GRDBCloudLibraryRepository(db), archive = GRDBArchiveRepository(db)
        try await archive.archive(task(), at: stamp)
        _ = try await library.capture(owner: "account-a", now: stamp)
        try await archive.deletePermanently(id: task().id)
        try await library.resetMetadata()
        #expect(try await library.capture(owner: "account-a", now: stamp).isEmpty)
    }
}
