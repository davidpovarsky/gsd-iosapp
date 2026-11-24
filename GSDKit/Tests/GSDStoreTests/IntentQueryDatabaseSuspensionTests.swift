import Foundation
import Testing
import GSDModel
@testable import GRDB
@testable import GSDStore

/// The app's EntityQuery reads through TaskStore before an intent's perform().
/// Exercise that real on-disk DatabaseQueue path, including the suspended state.
/// Suspend only this test's queue; global notifications would interrupt parallel tests.
/// These are database lifecycle checks, not proof of a Siri or Shortcuts UI invocation.
@MainActor
struct IntentQueryDatabaseSuspensionTests {
    private struct Fixture {
        let directory: URL
        let queue: DatabaseQueue
        let store: TaskStore
        let defaults: UserDefaults
        let defaultsSuite: String

        func cleanup() {
            queue.resume()
            try? queue.close()
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsd-intent-query-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(
            path: directory.appendingPathComponent("gsd.sqlite").path,
            configuration: AppDatabase.makeConfiguration())
        let database = try AppDatabase(queue)
        let defaultsSuite = "gsd-intent-query-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let store = TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            trashRepository: GRDBTrashRepository(database),
            defaults: defaults,
            newID: { "intent-fixture" })
        try await store.add(CaptureParser.parse("Intent fixture #work"))
        return Fixture(directory: directory, queue: queue, store: store,
                       defaults: defaults, defaultsSuite: defaultsSuite)
    }

    private func backgroundWindow(_ fixture: Fixture) -> BackgroundDatabaseWindow {
        BackgroundDatabaseWindow(
            isBackgrounded: { true },
            resume: { fixture.queue.resume() },
            suspend: { fixture.queue.suspend() })
    }

    @Test func entityReadsRequireResumeAndRestoreSuspension() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        fixture.queue.suspend()

        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchTask(id: "intent-fixture")
        }
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchAllTasks()
        }

        let values = try await backgroundWindow(fixture).run {
            let byID = try await fixture.store.fetchTask(id: "intent-fixture")
            let all = try await fixture.store.fetchAllTasks()
            return (byID, all)
        }
        #expect(values.0?.title == "Intent fixture")
        #expect(values.1.map(\.id) == ["intent-fixture"])
        #expect(fixture.store.tasks.isEmpty) // No foreground observation was required.

        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchAllTasks()
        }
        fixture.queue.resume()
        #expect(try await fixture.store.fetchTask(id: "intent-fixture")?.title == "Intent fixture")
    }

    @Test func failedEntityReadWindowRestoresSuspension() async throws {
        enum ProbeFailure: Error { case afterRead }
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        fixture.queue.suspend()

        await #expect(throws: ProbeFailure.self) {
            try await backgroundWindow(fixture).run {
                #expect(try await fixture.store.fetchTask(id: "intent-fixture") != nil)
                throw ProbeFailure.afterRead
            }
        }
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchTask(id: "intent-fixture")
        }
        fixture.queue.resume()
        #expect(try await fixture.store.fetchAllTasks().map(\.id) == ["intent-fixture"])
    }
}
