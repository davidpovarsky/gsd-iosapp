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

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func overlappingReadsWaitForTheLastOwnerBeforeSuspending() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        fixture.queue.suspend()
        let firstWindow = backgroundWindow(fixture)
        let secondWindow = firstWindow // Two callers retain one database's access scope.
        let firstEntered = Gate(), secondEntered = Gate()
        let releaseFirst = Gate(), releaseSecond = Gate()
        defer { releaseFirst.open(); releaseSecond.open() }

        let first = _Concurrency.Task { @MainActor in
            try await firstWindow.run {
                firstEntered.open()
                await releaseFirst.wait()
                return try await fixture.store.fetchTask(id: "intent-fixture")
            }
        }
        await firstEntered.wait()
        let second = _Concurrency.Task { @MainActor in
            try await secondWindow.run {
                secondEntered.open()
                await releaseSecond.wait()
                return try await fixture.store.fetchAllTasks()
            }
        }
        await secondEntered.wait()
        releaseFirst.open()
        let firstResult = await first.result
        // The first call has exited while the second is still awaiting its release.
        // This read failed with the former per-call defer/suspend implementation.
        await #expect(throws: Never.self) {
            let task = try await fixture.store.fetchTask(id: "intent-fixture")
            #expect(task != nil)
        }
        releaseSecond.open()
        let secondResult = await second.result
        #expect(try firstResult.get()?.id == "intent-fixture")
        #expect(try secondResult.get().map(\.id) == ["intent-fixture"])
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchAllTasks()
        }
    }

    @Test func aForegroundReturnDuringARealReadWindowLeavesDatabaseLive() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        fixture.queue.suspend()
        var backgrounded = true
        let window = BackgroundDatabaseWindow(
            isBackgrounded: { backgrounded },
            resume: { fixture.queue.resume() },
            suspend: { fixture.queue.suspend() })
        let value = try await window.run {
            window.suspendWhenIdle() // A scene background callback cannot undercut this owner.
            let task = try await fixture.store.fetchTask(id: "intent-fixture")
            backgrounded = false // The app became active while an operation was in flight.
            window.resumeForForeground()
            return task
        }
        #expect(value?.id == "intent-fixture")
        #expect(try await fixture.store.fetchAllTasks().map(\.id) == ["intent-fixture"])
    }

    @Test func aThrowingNestedWindowDoesNotSuspendItsOuterOwner() async throws {
        enum ProbeFailure: Error { case afterRead }
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        fixture.queue.suspend()
        let window = backgroundWindow(fixture)
        try await window.run {
            await #expect(throws: ProbeFailure.self) {
                try await window.run {
                    #expect(try await fixture.store.fetchTask(id: "intent-fixture") != nil)
                    throw ProbeFailure.afterRead
                }
            }
            let tasks = try await fixture.store.fetchAllTasks()
            #expect(tasks.map(\.id) == ["intent-fixture"])
        }
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchTask(id: "intent-fixture")
        }
    }

    @Test func sceneBackgroundingWaitsForAnOwnerThatStartedInForeground() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        var backgrounded = false
        let window = BackgroundDatabaseWindow(
            isBackgrounded: { backgrounded },
            resume: { fixture.queue.resume() },
            suspend: { fixture.queue.suspend() })
        let lease = window.begin()
        defer { lease.finish() }
        backgrounded = true
        window.suspendWhenIdle()
        #expect(try await fixture.store.fetchTask(id: "intent-fixture") != nil)
        #expect(lease.finish())
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchAllTasks()
        }
        // With no owned operation, backgrounding still suspends immediately.
        window.resumeForForeground()
        window.suspendWhenIdle()
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchAllTasks()
        }
    }

    @Test func expirationCompletesOnceWithoutClosingAnotherOwnersDatabase() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        fixture.queue.suspend()
        let window = backgroundWindow(fixture)
        let otherOwner = window.begin()
        defer { otherOwner.finish() }
        var completions: [Bool] = []
        let expiringOwner = window.begin { completions.append($0) }
        defer { expiringOwner.finish(success: false) }
        window.suspendWhenIdle()

        #expect(expiringOwner.finish(success: false))
        #expect(completions == [false]) // Completion is independent of the other owner's lifetime.
        #expect(!expiringOwner.finish(success: true))
        #expect(!expiringOwner.finish(success: false))
        #expect(throws: CancellationError.self) { try expiringOwner.checkCancellation() }
        #expect(try await fixture.store.fetchAllTasks().map(\.id) == ["intent-fixture"])
        #expect(otherOwner.finish())
        #expect(completions == [false])
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchTask(id: "intent-fixture")
        }
    }

    @Test func expiredWorkCannotStartAnotherPhaseAfterAnAwaitIgnoresCancellation() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        fixture.queue.suspend()
        let window = backgroundWindow(fixture)
        var completions: [Bool] = []
        let lease = window.begin { completions.append($0) }
        defer { lease.finish(success: false) }
        let entered = Gate(), release = Gate()
        defer { release.open() }
        var phases: [String] = []
        let work = _Concurrency.Task { @MainActor in
            do {
                try lease.checkCancellation()
                phases.append("drain")
                entered.open()
                await release.wait() // Deliberately ignores cancellation like some system APIs.
                try lease.checkCancellation()
                phases.append("sync")
                _ = try await fixture.store.fetchAllTasks()
                lease.finish(success: true)
            } catch {
                lease.finish(success: false)
            }
        }
        await entered.wait()
        work.cancel()
        lease.finish(success: false)
        #expect(completions == [false])
        await #expect(throws: DatabaseError.self) {
            _ = try await fixture.store.fetchTask(id: "intent-fixture")
        }
        release.open()
        await work.value
        #expect(phases == ["drain"])
        #expect(completions == [false])
        #expect(lease.isFinished)
    }
}
