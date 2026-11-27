import Foundation
import Observation
import GSDModel
import GSDStore
import GSDSnapshot

// Real TaskStore, GRDB repositories, sync outbox and BackgroundDatabaseWindow.
// Only UIKit application state and WatchConnectivity transport are platform doubles.
protocol WCSessionDelegate: AnyObject {}
enum WCSessionActivationState { case notActivated, inactive, activated }
final class WCSessionUserInfoTransfer: @unchecked Sendable {
    let userInfo: [String: Any]
    init(_ userInfo: [String: Any]) { self.userInfo = userInfo }
}
final class WCSession: @unchecked Sendable {
    static let `default` = WCSession()
    static func isSupported() -> Bool { true }
    weak var delegate: (any WCSessionDelegate)?
    var activationState = WCSessionActivationState.activated
    var isPaired = true
    var isWatchAppInstalled = true
    var contexts: [[String: Any]] = []
    func activate() {}
    func updateApplicationContext(_ context: [String: Any]) throws { contexts.append(context) }
}
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}

actor ReadSuspension {
    private var reads = 0
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func beforeRead() async {
        reads += 1
        if reads == 2 {
            blocked = true
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func isBlocked() -> Bool { blocked }
    func release() {
        continuation?.resume()
        continuation = nil
        blocked = false
    }
}

/// Only the second read is delayed. Every read and mutation still executes against actual GRDB.
final class SuspendedRepository: TaskRepository, Sendable {
    let base: GRDBTaskRepository
    let suspension: ReadSuspension
    init(base: GRDBTaskRepository, suspension: ReadSuspension) {
        self.base = base; self.suspension = suspension
    }
    func upsert(_ task: GSDModel.Task) async throws { try await base.upsert(task) }
    func fetchAll() async throws -> [GSDModel.Task] { try await base.fetchAll() }
    func fetch(id: String) async throws -> GSDModel.Task? {
        await suspension.beforeRead()
        return try await base.fetch(id: id)
    }
    func setNotifyBeforeIfNull(id: String, value: Int) async throws {
        try await base.setNotifyBeforeIfNull(id: id, value: value)
    }
    func restampIfUnchanged(id: String, from: Date, to: Date) async throws -> Bool {
        try await base.restampIfUnchanged(id: id, from: from, to: to)
    }
    func delete(id: String) async throws { try await base.delete(id: id) }
    func replaceAll(_ tasks: [GSDModel.Task]) async throws { try await base.replaceAll(tasks) }
    func replaceAll(_ tasks: [GSDModel.Task], queueing items: [SyncQueueItem],
                    deletingLeftOut makeDelete: @Sendable (String) -> SyncQueueItem) async throws {
        try await base.replaceAll(tasks, queueing: items, deletingLeftOut: makeDelete)
    }
    func observeAll() -> AsyncThrowingStream<[GSDModel.Task], Error> { base.observeAll() }
}

@MainActor final class BodyHold {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class StoreRig {
    let database: AppDatabase
    let tasks: GRDBTaskRepository
    let queue: GRDBSyncQueueRepository
    let store: TaskStore
    let gate: WatchMutationGate
    let phone: WatchSessionCoordinator
    let defaults: UserDefaults
    let suite = "GSDWatchGate-" + UUID().uuidString

    init(directory: URL, suspension: ReadSuspension? = nil) throws {
        database = try AppDatabase.inMemory()
        tasks = GRDBTaskRepository(database)
        queue = GRDBSyncQueueRepository(database)
        defaults = UserDefaults(suiteName: suite)!
        let repository: any TaskRepository
        if let suspension {
            repository = SuspendedRepository(base: tasks, suspension: suspension)
        } else {
            repository = tasks
        }
        store = TaskStore(repository: repository,
                          smartViewRepository: GRDBSmartViewRepository(database),
                          archiveRepository: GRDBArchiveRepository(database),
                          trashRepository: GRDBTrashRepository(database),
                          defaults: defaults, feedbackDefaults: defaults, syncQueue: queue)
        gate = WatchMutationGate(directory: directory)
        #if WATCH_ACCOUNT_SCOPED
        let gate = gate
        phone = WatchSessionCoordinator(store: store, enabled: true, mutationGate: gate,
            scopeProvider: {
                guard let datasetID = gate.identity?.datasetID else { return nil }
                return .account(userID: "gate-fixture-owner", datasetID: datasetID)
            }, defaults: defaults, debounce: .zero)
        #else
        // RED: ace1576d gate/DTO exists, but the unchanged production coordinator
        // never admits its write into that gate.
        phone = WatchSessionCoordinator(store: store, enabled: true, defaults: defaults, debounce: .zero)
        #endif
        store.start()
        phone.start()
    }

    var scope: WatchAccountScope {
        .account(userID: "gate-fixture-owner", datasetID: gate.identity!.datasetID)
    }
    func deliver(_ command: WatchCommand) {
        phone.session(WCSession.default, didReceiveUserInfo: WatchWire.userInfo(for: command)!)
    }
    func close() { defaults.removePersistentDomain(forName: suite) }
}

@main struct WatchGateProbe {
    @MainActor static var failures = 0

    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("WATCH_GATE_CHECK " + String(decoding: data, as: UTF8.self))
    }

    @MainActor static func waitFor(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    static func task(_ id: String) -> GSDModel.Task {
        GSDModel.Task(id: id, title: id, urgent: true, important: true,
                      createdAt: .now, updatedAt: .now)
    }

    @MainActor static func drainChecks(root: URL) async throws {
        let gate = WatchMutationGate(directory: root.appendingPathComponent("drain"))
        let ticket = gate.admit()!
        let body = BodyHold()
        let pause = _Concurrency.Task { await gate.withPaused { await body.wait() } }
        let paused = await waitFor { gate.isPaused }
        let rejected = gate.admit()
        let waited = !body.entered
        if let rejected { gate.finish(rejected) }
        gate.finish(ticket)
        let entered = await waitFor { body.entered }
        let heldThroughBody = gate.isPaused && gate.admit() == nil
        body.release()
        await pause.value
        let reopened = gate.admit()
        check("pause_closes_admission_before_drain", paused && rejected == nil && waited
              && entered && heldThroughBody && reopened != nil)
        if let reopened { gate.finish(reopened) }

        let nestedGate = WatchMutationGate(directory: root.appendingPathComponent("nested"))
        let outerBody = BodyHold(), otherBody = BodyHold()
        var innerClosed = false
        let outer = _Concurrency.Task {
            await nestedGate.withPaused {
                await nestedGate.withPaused { innerClosed = nestedGate.isPaused }
                innerClosed = innerClosed && nestedGate.isPaused
                await outerBody.wait()
            }
        }
        _ = await waitFor { outerBody.entered }
        let other = _Concurrency.Task { await nestedGate.withPaused { await otherBody.wait() } }
        _ = await waitFor { otherBody.entered }
        outerBody.release()
        await outer.value
        let stillPaused = nestedGate.isPaused && nestedGate.admit() == nil
        otherBody.release()
        await other.value
        let finalTicket = nestedGate.admit()
        check("nested_and_overlapping_pauses_keep_admission_closed", innerClosed && stillPaused && finalTicket != nil)
        if let finalTicket { nestedGate.finish(finalTicket) }

        let cancelledGate = WatchMutationGate(directory: root.appendingPathComponent("cancelled"))
        let pending = cancelledGate.admit()!
        var cleanedWhileCancelled = false
        let cancelled = _Concurrency.Task {
            await cancelledGate.withPaused { cleanedWhileCancelled = _Concurrency.Task.isCancelled }
        }
        _ = await waitFor { cancelledGate.isPaused }
        cancelled.cancel()
        try await _Concurrency.Task.sleep(for: .milliseconds(25))
        let didNotReopen = cancelledGate.isPaused && !cleanedWhileCancelled
        cancelledGate.finish(pending)
        await cancelled.value
        check("cancelled_pause_waits_for_admitted_write", didNotReopen && cleanedWhileCancelled && !cancelledGate.isPaused)
    }

    @MainActor static func identityChecks(root: URL) async throws {
        let directory = root.appendingPathComponent("durable-identity")
        let gate = WatchMutationGate(directory: directory)
        let before = gate.identity!
        var durableBeforeBody = false
        try await gate.replacingDataset {
            let restored = WatchMutationGate(directory: directory)
            durableBeforeBody = gate.isPaused && gate.identity?.datasetID != before.datasetID
                && restored.identity == gate.identity && restored.identity?.installationID == before.installationID
        }
        let relaunched = WatchMutationGate(directory: directory)
        check("dataset_rotation_is_durable_before_body", durableBeforeBody
              && relaunched.identity == gate.identity && !gate.isPaused)

        let rigDirectory = root.appendingPathComponent("blocked-identity")
        let rig = try StoreRig(directory: rigDirectory)
        defer { rig.close() }
        let kept = task("kept-on-identity-failure")
        try await rig.tasks.upsert(kept)
        let persistedBeforeFailure = try await rig.tasks.fetchAll()
        let previousIdentity = rig.gate.identity
        let path = rigDirectory.appendingPathComponent("watch-dataset-identity.json")
        let preserved = rigDirectory.appendingPathComponent("preserved-identity.json")
        try FileManager.default.moveItem(at: path, to: preserved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        var destructiveBodyRan = false
        var refused = false
        do {
            try await rig.gate.replacingDataset {
                destructiveBodyRan = true
                try await rig.store.eraseAllData()
            }
        } catch { refused = true }
        let rows = try await rig.tasks.fetchAll()
        let queued = try await rig.queue.all()
        let failureDiagnostic: [String: Any] = [
            "refused": refused, "destructiveBodyRan": destructiveBodyRan,
            "rowsEqualOriginal": rows == [kept], "rowsEqualPersistedBefore": rows == persistedBeforeFailure,
            "queueEmpty": queued.isEmpty, "identityUnchanged": rig.gate.identity == previousIdentity,
            "paused": rig.gate.isPaused,
            "originalCreatedAt": kept.createdAt.timeIntervalSince1970,
            "persistedCreatedAt": rows.first?.createdAt.timeIntervalSince1970 ?? -1,
            "originalUpdatedAt": kept.updatedAt.timeIntervalSince1970,
            "persistedUpdatedAt": rows.first?.updatedAt.timeIntervalSince1970 ?? -1
        ]
        print("WATCH_GATE_DIAGNOSTIC " + String(decoding: try JSONSerialization.data(
            withJSONObject: failureDiagnostic, options: [.sortedKeys]), as: UTF8.self))
        check("identity_failure_prevents_destructive_body", refused && !destructiveBodyRan
              && rows == [kept] && queued.isEmpty && rig.gate.identity == previousIdentity && !rig.gate.isPaused)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: preserved, to: path)
    }

    @MainActor static func actualWriteChecks(root: URL) async throws {
        let suspension = ReadSuspension()
        let rig = try StoreRig(directory: root.appendingPathComponent("actual-internal-write"), suspension: suspension)
        defer { rig.close() }
        let original = task("actual-internal-fetch-task")
        try await rig.tasks.upsert(original)
        _ = await waitFor { rig.store.hasLoadedTasks }
        let command = WatchCommand(id: UUID().uuidString, issuedAt: .now,
                                   kind: .complete(taskID: original.id), accountScope: rig.scope)
        rig.deliver(command)
        let insideTaskStore = await waitFor { await suspension.isBlocked() }
        var eraseStarted = false
        let erase = _Concurrency.Task {
            try await rig.gate.replacingDataset {
                eraseStarted = true
                try await rig.store.eraseAllData()
            }
        }
        _ = await waitFor { rig.gate.isPaused || eraseStarted }
        try await _Concurrency.Task.sleep(for: .milliseconds(25))
        let waitedForWrite = rig.gate.isPaused && !eraseStarted
        check("reset_waits_for_internal_taskstore_write", insideTaskStore && waitedForWrite)
        await suspension.release()
        try await erase.value
        _ = await waitFor { WatchAppliedLedger(defaults: rig.defaults).contains(command.id) }
        let rows = try await rig.tasks.fetchAll()
        let queued = try await rig.queue.all()
        check("reset_leaves_no_late_task_or_outbox_write", eraseStarted
              && rows.isEmpty && queued.isEmpty && !rig.gate.isPaused)

        let pending = try StoreRig(directory: root.appendingPathComponent("actual-queued-before-reset"))
        defer { pending.close() }
        _ = await waitFor { pending.store.hasLoadedTasks }
        let old = WatchCommand(id: UUID().uuidString, issuedAt: .now,
                               kind: .capture(text: "Queued before reset", quadrant: .urgentImportant),
                               accountScope: pending.scope)
        try await pending.gate.replacingDataset { try await pending.store.eraseAllData() }
        pending.deliver(old)
        try await _Concurrency.Task.sleep(for: .milliseconds(75))
        let oldRows = try await pending.tasks.fetchAll()
        let oldQueue = try await pending.queue.all()
        let oldRejected = oldRows.isEmpty && oldQueue.isEmpty && !WatchAppliedLedger(defaults: pending.defaults).contains(old.id)
        let fresh = WatchCommand(id: UUID().uuidString, issuedAt: .now,
                                 kind: .capture(text: "Created after reset", quadrant: .urgentImportant),
                                 accountScope: pending.scope)
        pending.deliver(fresh)
        let accepted = await waitFor { WatchAppliedLedger(defaults: pending.defaults).contains(fresh.id) }
        let freshRows = try await pending.tasks.fetchAll()
        let freshQueue = try await pending.queue.all()
        check("queued_capture_before_reset_is_not_admitted_afterward", oldRejected && accepted
              && freshRows.map(\.id) == ["pending-" + fresh.id]
              && freshRows.map(\.title) == ["Created after reset"]
              && freshQueue.count == 1 && freshQueue.first?.taskId == freshRows.first?.id)
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDWatchGate-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await drainChecks(root: root)
            try await identityChecks(root: root)
            try await actualWriteChecks(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("WATCH_GATE_ERROR " + String(describing: error))
            exit(2)
        }
    }
}
