import Foundation
import Observation
import AppIntents
import GSDModel
import GSDStore
import GSDSnapshot

// UIKit lifecycle is the only platform double. AppIntents, all actual intent/query
// methods, TaskStore, GRDB repositories/outbox and BackgroundDatabaseWindow execute.
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
actor IntentSuspension {
    enum Operation: Sendable, Equatable { case fetchAll, fetch, upsert }
    private var operation: Operation?
    private var remaining = 0
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm(_ operation: Operation, hit: Int = 1) { self.operation = operation; remaining = hit }
    func reach(_ operation: Operation) async {
        guard self.operation == operation else { return }
        remaining -= 1
        if remaining == 0 {
            self.operation = nil
            blocked = true
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func isBlocked() -> Bool { blocked }
    func release() { continuation?.resume(); continuation = nil; blocked = false }
}
final class IntentRepository: TaskRepository, Sendable {
    let base: GRDBTaskRepository
    let suspension: IntentSuspension
    init(base: GRDBTaskRepository, suspension: IntentSuspension) { self.base = base; self.suspension = suspension }
    func upsert(_ task: GSDModel.Task) async throws {
        await suspension.reach(.upsert)
        try await base.upsert(task)
    }
    func fetchAll() async throws -> [GSDModel.Task] {
        let captured = try await base.fetchAll()
        await suspension.reach(.fetchAll)
        return captured
    }
    func fetch(id: String) async throws -> GSDModel.Task? {
        let captured = try await base.fetch(id: id)
        await suspension.reach(.fetch)
        return captured
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
@MainActor @Observable final class IntentIdentity {
    var owner: String? = "intent-fixture-account-a"
}
@MainActor final class IntentRig {
    let database: AppDatabase
    let rows: GRDBTaskRepository
    let queue: GRDBSyncQueueRepository
    let store: TaskStore
    let gate: WatchMutationGate
    let suspension = IntentSuspension()
    let identity = IntentIdentity()
    let defaults: UserDefaults
    let suite = "GSDIntentScope-" + UUID().uuidString
    #if INTENT_ACCOUNT_SCOPED
    let scopeContext: GSDAppIntentScope
    #endif
    init(directory: URL) throws {
        database = try AppDatabase.inMemory()
        rows = GRDBTaskRepository(database)
        queue = GRDBSyncQueueRepository(database)
        defaults = UserDefaults(suiteName: suite)!
        store = TaskStore(repository: IntentRepository(base: rows, suspension: suspension),
                          smartViewRepository: GRDBSmartViewRepository(database),
                          archiveRepository: GRDBArchiveRepository(database),
                          trashRepository: GRDBTrashRepository(database),
                          defaults: defaults, feedbackDefaults: defaults, syncQueue: queue)
        gate = WatchMutationGate(directory: directory)
        #if INTENT_ACCOUNT_SCOPED
        let identity = identity, gate = gate
        scopeContext = GSDAppIntentScope(store: store, mutationGate: gate, scopeProvider: {
            guard !gate.isPaused, let owner = identity.owner, let dataset = gate.identity?.datasetID else { return nil }
            return .account(userID: owner, datasetID: dataset)
        })
        AppDependencyManager.shared.add(dependency: scopeContext)
        #endif
        AppDependencyManager.shared.add(dependency: store)
    }
    func close() { defaults.removePersistentDomain(forName: suite) }
}
@main struct AppIntentScopeProbe {
    static let stamp = Date(timeIntervalSince1970: 2_000_000_000)
    @MainActor static var failures = 0
    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("APP_INTENT_SCOPE_CHECK " + String(decoding: data, as: UTF8.self))
    }
    @MainActor static func waitFor(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    static func row(_ title: String) -> GSDModel.Task {
        GSDModel.Task(id: "same-imported-task-id", title: title, urgent: true, important: true,
                      createdAt: stamp, updatedAt: stamp)
    }
    @MainActor static func select(_ title: String) async throws -> GSDTaskEntity {
        let result = try await GSDTaskQuery().entities(matching: title)
        guard let first = result.first else { throw ProbeError.missingSelection }
        return first
    }
    enum ProbeError: Error { case missingSelection }
    @MainActor static func complete(_ entity: GSDTaskEntity) async throws {
        var intent = CompleteTaskIntent()
        intent.task = entity
        _ = try await intent.perform()
    }
    @MainActor static func create(_ title: String) async throws {
        var intent = CreateTaskIntent()
        intent.taskTitle = title
        _ = try await intent.perform()
    }
    @MainActor static func rejected(_ body: @MainActor () async throws -> Void) async -> Bool {
        do { try await body(); return false } catch { return true }
    }

    @MainActor static func referenceChecks(root: URL) async throws {
        let legacy = try IntentRig(directory: root.appendingPathComponent("legacy"))
        defer { legacy.close() }
        let original = row("Legacy task")
        try await legacy.rows.upsert(original)
        let raw = GSDTaskEntity(id: original.id, title: original.title, completed: false)
        let resolutionRejected = await rejected { _ = try await GSDTaskQuery().entities(for: [original.id]) }
        let mutationRejected = await rejected { try await complete(raw) }
        let legacyRows = try await legacy.rows.fetchAll(), legacyQueue = try await legacy.queue.all()
        check("legacy_raw_shortcut_requires_reselection", resolutionRejected && mutationRejected
              && legacyRows == [original] && legacyQueue.isEmpty)

        let switching = try IntentRig(directory: root.appendingPathComponent("account"))
        defer { switching.close() }
        let a = row("Account A selected task"), b = row("Account B same ID")
        try await switching.rows.upsert(a)
        let selectedA = try await select(a.title)
        switching.identity.owner = "intent-fixture-account-b"
        try await switching.rows.upsert(b)
        let wrongRejected = await rejected { try await complete(selectedA) }
        let rowsBeforeValid = try await switching.rows.fetchAll()
        let selectedB = try await select(b.title)
        try await complete(selectedB)
        let rowsAfterValid = try await switching.rows.fetchAll()
        check("account_a_selection_cannot_complete_account_b", wrongRejected && rowsBeforeValid == [b]
              && selectedA.id != selectedB.id && rowsAfterValid.count == 1
              && rowsAfterValid.first?.title == b.title && rowsAfterValid.first?.completed == true)

        let dataset = try IntentRig(directory: root.appendingPathComponent("dataset"))
        defer { dataset.close() }
        try await dataset.rows.upsert(a)
        let oldSelection = try await select(a.title)
        try await dataset.gate.replacingDataset {
            try await dataset.store.eraseAllData()
            try await dataset.rows.upsert(b)
        }
        let priorRejected = await rejected { try await complete(oldSelection) }
        let unchanged = try await dataset.rows.fetchAll() == [b]
        let currentSelection = try await select(b.title)
        try await complete(currentSelection)
        let done = try await dataset.rows.fetchAll().first?.completed == true
        check("previous_dataset_selection_requires_reselection", priorRejected && unchanged && done
              && oldSelection.id != currentSelection.id)
    }

    @MainActor static func readChecks(root: URL) async throws {
        let query = try IntentRig(directory: root.appendingPathComponent("query-read"))
        defer { query.close() }
        let a = row("Query A content"), b = row("Query B content")
        try await query.rows.upsert(a)
        await query.suspension.arm(.fetchAll)
        let oldQuery = _Concurrency.Task { try await GSDTaskQuery().suggestedEntities() }
        let entered = await waitFor { await query.suspension.isBlocked() }
        query.identity.owner = "intent-fixture-account-b"
        try await query.rows.upsert(b)
        await query.suspension.release()
        let oldRefused: Bool
        do { _ = try await oldQuery.value; oldRefused = false } catch { oldRefused = true }
        let current = try await GSDTaskQuery().suggestedEntities()
        check("canonical_query_revalidates_scope_after_suspended_read", entered && oldRefused
              && current.map(\.title) == [b.title])

        let completion = try IntentRig(directory: root.appendingPathComponent("completion-read"))
        defer { completion.close() }
        try await completion.rows.upsert(a)
        let selectedA = try await select(a.title)
        await completion.suspension.arm(.fetch)
        let staleCompletion = _Concurrency.Task { try await complete(selectedA) }
        let readEntered = await waitFor { await completion.suspension.isBlocked() }
        completion.identity.owner = "intent-fixture-account-b"
        try await completion.rows.upsert(b)
        await completion.suspension.release()
        let completionRefused: Bool
        do { try await staleCompletion.value; completionRefused = false } catch { completionRefused = true }
        let stillB = try await completion.rows.fetchAll(), queue = try await completion.queue.all()
        check("completion_revalidates_scope_after_suspended_read", readEntered && completionRefused
              && stillB == [b] && queue.isEmpty)
    }

    @MainActor static func writeChecks(root: URL) async throws {
        let completion = try IntentRig(directory: root.appendingPathComponent("completion-internal"))
        defer { completion.close() }
        let original = row("Completion before reset")
        try await completion.rows.upsert(original)
        let selected = try await select(original.title)
        await completion.suspension.arm(.fetch, hit: 2)
        let operation = _Concurrency.Task { try await complete(selected) }
        let internalRead = await waitFor { await completion.suspension.isBlocked() }
        var erased = false
        let reset = _Concurrency.Task {
            try await completion.gate.replacingDataset {
                erased = true
                try await completion.store.eraseAllData()
            }
        }
        _ = await waitFor { completion.gate.isPaused || erased }
        let waited = completion.gate.isPaused && !erased
        await completion.suspension.release()
        _ = try? await operation.value
        try await reset.value
        let completionRows = try await completion.rows.fetchAll(), completionQueue = try await completion.queue.all()
        check("completion_internal_write_drains_before_reset", internalRead && waited && erased
              && completionRows.isEmpty && completionQueue.isEmpty && !completion.gate.isPaused)

        let capture = try IntentRig(directory: root.appendingPathComponent("create-internal"))
        defer { capture.close() }
        await capture.suspension.arm(.upsert)
        let creation = _Concurrency.Task { try await create("Created before reset #scope") }
        let internalWrite = await waitFor { await capture.suspension.isBlocked() }
        var cleared = false
        let replacement = _Concurrency.Task {
            try await capture.gate.replacingDataset {
                cleared = true
                try await capture.store.eraseAllData()
            }
        }
        _ = await waitFor { capture.gate.isPaused || cleared }
        let waitedForCreate = capture.gate.isPaused && !cleared
        await capture.suspension.release()
        _ = try? await creation.value
        try await replacement.value
        let captureRows = try await capture.rows.fetchAll(), captureQueue = try await capture.queue.all()
        // This valid current-scope control also checks the original capture shorthand path.
        try await create("Current capture !! #scope")
        let valid = try await capture.rows.fetchAll()
        check("create_internal_write_drains_before_reset", internalWrite && waitedForCreate && cleared
              && captureRows.isEmpty && captureQueue.isEmpty && valid.count == 1
              && valid.first?.title == "Current capture" && valid.first?.quadrant == .urgentImportant
              && valid.first?.tags == ["scope"])
    }

    @MainActor static func unresolvedCheck(root: URL) async throws {
        let rig = try IntentRig(directory: root.appendingPathComponent("unresolved"))
        defer { rig.close() }
        let original = row("Keep during account transition")
        try await rig.rows.upsert(original)
        let selected = try await select(original.title)
        rig.identity.owner = nil
        let queryRefused = await rejected { _ = try await GSDTaskQuery().suggestedEntities() }
        let createRefused = await rejected { try await create("Do not create while unresolved") }
        let completeRefused = await rejected { try await complete(selected) }
        let rows = try await rig.rows.fetchAll(), queue = try await rig.queue.all()
        check("unresolved_identity_refuses_queries_and_mutations", queryRefused && createRefused
              && completeRefused && rows == [original] && queue.isEmpty)
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDAppIntentScope-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await referenceChecks(root: root)
            try await readChecks(root: root)
            try await writeChecks(root: root)
            try await unresolvedCheck(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("APP_INTENT_SCOPE_ERROR " + String(describing: error)); exit(2)
        }
    }
}
