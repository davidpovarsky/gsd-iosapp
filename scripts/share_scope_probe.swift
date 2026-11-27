import Foundation
import Observation
import GSDModel
import GSDStore
import GSDSnapshot

// UIKit lifecycle is doubled; all TaskStore/GRDB/outbox work remains actual.
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
actor ShareSuspension {
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
final class ShareRepository: TaskRepository, Sendable {
    let base: GRDBTaskRepository
    let suspension: ShareSuspension
    init(base: GRDBTaskRepository, suspension: ShareSuspension) { self.base = base; self.suspension = suspension }
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

@MainActor @Observable final class ShareIdentity { var owner: String? = "share-fixture-account-a" }
actor ShareFetch {
    private var waiting = false
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm() { waiting = true; entered = false }
    func fetch(_ url: URL) async -> String? {
        entered = true
        if waiting { await withCheckedContinuation { continuation = $0 } }
        return "Fetched page title"
    }
    func didEnter() -> Bool { entered }
    func release() { waiting = false; continuation?.resume(); continuation = nil }
}
@MainActor final class ShareRig {
    let database: AppDatabase
    let rows: GRDBTaskRepository
    let queue: GRDBSyncQueueRepository
    let store: TaskStore
    let gate: WatchMutationGate
    let outbox: ShareOutboxStore
    let inbox: ShareInbox
    let suspension = ShareSuspension()
    let identity = ShareIdentity()
    let fetcher = ShareFetch()
    let enricher: ShareTitleEnricher
    let drainer: ShareInboxDrainer
    let defaults: UserDefaults
    let suite = "GSDShareScope-" + UUID().uuidString
    init(directory: URL) throws {
        database = try AppDatabase.inMemory()
        rows = GRDBTaskRepository(database)
        queue = GRDBSyncQueueRepository(database)
        defaults = UserDefaults(suiteName: suite)!
        store = TaskStore(repository: ShareRepository(base: rows, suspension: suspension),
                          smartViewRepository: GRDBSmartViewRepository(database),
                          archiveRepository: GRDBArchiveRepository(database),
                          trashRepository: GRDBTrashRepository(database),
                          defaults: defaults, feedbackDefaults: defaults, syncQueue: queue)
        gate = WatchMutationGate(directory: directory)
        outbox = ShareOutboxStore(directoryURL: directory)
        inbox = ShareInbox(store: outbox)
        let fetcher = fetcher
        #if SHARE_ACCOUNT_SCOPED
        let identity = identity, gate = gate
        let provider: @MainActor @Sendable () -> WatchAccountScope? = {
            guard !gate.isPaused, let owner = identity.owner, let dataset = gate.identity?.datasetID else { return nil }
            return .account(userID: owner, datasetID: dataset)
        }
        enricher = ShareTitleEnricher(store: store, fetch: { await fetcher.fetch($0) },
                                     mutationGate: gate, scopeProvider: provider)
        drainer = ShareInboxDrainer(inbox: inbox, store: store, titleEnricher: enricher,
                                   mutationGate: gate, scopeProvider: provider)
        #else
        enricher = ShareTitleEnricher(store: store, fetch: { await fetcher.fetch($0) })
        drainer = ShareInboxDrainer(inbox: inbox, store: store, titleEnricher: enricher)
        #endif
    }
    var origin: WatchAccountScope {
        .account(userID: identity.owner!, datasetID: gate.identity!.datasetID)
    }
    func close() { defaults.removePersistentDomain(forName: suite) }
    func schedule(_ task: GSDModel.Task, origin: WatchAccountScope) -> _Concurrency.Task<Void, Never>? {
        #if SHARE_ACCOUNT_SCOPED
        return enricher.schedule(for: task, origin: origin)
        #else
        return enricher.schedule(for: task)
        #endif
    }
}
@main struct ShareScopeProbe {
    static let stamp = Date(timeIntervalSince1970: 2_000_000_000)
    @MainActor static var failures = 0
    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("SHARE_SCOPE_CHECK " + String(decoding: data, as: UTF8.self))
    }
    @MainActor static func waitFor(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    static func row(_ title: String) -> GSDModel.Task {
        GSDModel.Task(id: "shared-stable-task-id", title: title, description: "https://example.com/article",
                     urgent: true, important: true, createdAt: stamp, updatedAt: stamp)
    }
    static func capture(_ title: String, origin: WatchAccountScope?, pushed: Bool = false,
                        editedRetry: Bool = false) throws -> SharedCapture {
        let value = SharedCapture(title: title, urls: [], urgent: true, important: true,
                                  tags: ["scope"], capturedAt: stamp,
                                  taskID: "shared-stable-task-id", remoteRecordID: pushed ? "remote-fixture-id" : nil)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        if let origin { object["origin"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(origin)) }
        if editedRetry { object["isEditedRetry"] = true }
        return try JSONDecoder().decode(SharedCapture.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor static func heldChecks(root: URL) async throws {
        for (name, mode) in [
            ("legacy_share_stays_durable_for_review", "legacy"),
            ("account_a_share_cannot_overwrite_account_b", "account"),
            ("old_dataset_share_stays_held_after_reset", "dataset"),
            ("unresolved_identity_does_not_ingest_share", "unresolved")
        ] {
            let rig = try ShareRig(directory: root.appendingPathComponent(mode))
            defer { rig.close() }
            let original = row("Keep the current task")
            let origin = rig.origin
            try rig.outbox.write(capture("Captured in the prior context", origin: mode == "legacy" ? nil : origin))
            if mode == "account" { rig.identity.owner = "share-fixture-account-b" }
            if mode == "dataset" { try await rig.gate.replacingDataset { try await rig.store.eraseAllData() } }
            if mode == "unresolved" { rig.identity.owner = nil }
            try await rig.rows.upsert(original)
            let persisted = try await rig.rows.fetchAll()
            await rig.drainer.drain(enrichTitles: false)
            let current = try await rig.rows.fetchAll(), queued = try await rig.queue.all()
            check(name, current == persisted && queued.isEmpty && rig.outbox.pending().count == 1)
        }
    }
    @MainActor static func currentControl(root: URL) async throws {
        let local = try ShareRig(directory: root.appendingPathComponent("current-local"))
        let pushed = try ShareRig(directory: root.appendingPathComponent("current-pushed"))
        defer { local.close(); pushed.close() }
        try local.outbox.write(capture("Local share", origin: local.origin))
        try pushed.outbox.write(capture("Pushed share", origin: pushed.origin, pushed: true))
        await local.drainer.drain(enrichTitles: false)
        await pushed.drainer.drain(enrichTitles: false)
        let localRows = try await local.rows.fetchAll(), localQueue = try await local.queue.all()
        let pushedRows = try await pushed.rows.fetchAll(), pushedQueue = try await pushed.queue.all()
        check("current_scope_preserves_local_and_pushed_landings",
              localRows.count == 1 && localRows.first?.title == "Local share" && !localQueue.isEmpty
              && pushedRows.count == 1 && pushedRows.first?.title == "Pushed share"
              && pushedRows.first?.createdAt == stamp && pushedQueue.isEmpty
              && local.outbox.pending().isEmpty && pushed.outbox.pending().isEmpty)
    }
    @MainActor static func writeChecks(root: URL) async throws {
        for pushed in [false, true] {
            let rig = try ShareRig(directory: root.appendingPathComponent(pushed ? "pushed-write" : "local-write"))
            defer { rig.close() }
            try rig.outbox.write(capture("Admitted before reset", origin: rig.origin, pushed: pushed))
            await rig.suspension.arm(.upsert)
            let operation = _Concurrency.Task { await rig.drainer.drain(enrichTitles: false) }
            let entered = await waitFor { await rig.suspension.isBlocked() }
            var erased = false
            let reset = _Concurrency.Task {
                try await rig.gate.replacingDataset {
                    erased = true
                    try await rig.store.eraseAllData()
                }
            }
            _ = await waitFor { rig.gate.isPaused || erased }
            let waited = rig.gate.isPaused && !erased
            await rig.suspension.release()
            await operation.value
            try await reset.value
            let current = try await rig.rows.fetchAll(), queued = try await rig.queue.all()
            check(pushed ? "pushed_ingest_drains_before_reset" : "local_share_create_drains_before_reset",
                  entered && waited && erased && current.isEmpty && queued.isEmpty
                  && rig.outbox.pending().isEmpty && !rig.gate.isPaused)
        }
    }
    @MainActor static func titleChecks(root: URL) async throws {
        let foreign = try ShareRig(directory: root.appendingPathComponent("title-account"))
        defer { foreign.close() }
        let derived = String(URLTitle.derive(from: "https://example.com/article").prefix(FieldLimits.titleRange.upperBound))
        let a = row(derived)
        try await foreign.rows.upsert(a)
        foreign.store.start()
        guard await waitFor({ foreign.store.tasks.count == 1 }) else { throw ProbeError.observationSetup }
        let origin = foreign.origin
        await foreign.fetcher.arm()
        let operation = foreign.schedule(a, origin: origin)
        let entered = await waitFor { await foreign.fetcher.didEnter() }
        foreign.identity.owner = "share-fixture-account-b"
        var b = a; b.description += "\nAccount B data"
        try await foreign.rows.upsert(b)
        guard await waitFor({ foreign.store.tasks.first?.description == b.description }) else { throw ProbeError.observationSetup }
        let before = try await foreign.rows.fetchAll()
        await foreign.fetcher.release()
        await operation?.value
        let after = try await foreign.rows.fetchAll(), queued = try await foreign.queue.all()
        check("late_title_fetch_cannot_edit_another_account", entered && after == before && queued.isEmpty)

        let cold = try ShareRig(directory: root.appendingPathComponent("title-cold"))
        defer { cold.close() }
        try await cold.rows.upsert(a)
        let coldOperation = cold.schedule(a, origin: cold.origin)
        await coldOperation?.value
        let coldRows = try await cold.rows.fetchAll()
        check("title_enrichment_reads_canonical_row_without_ui_snapshot",
              cold.store.tasks.isEmpty && coldRows.count == 1 && coldRows.first?.title == "Fetched page title")

        let held = try ShareRig(directory: root.appendingPathComponent("title-write"))
        defer { held.close() }
        try await held.rows.upsert(a)
        held.store.start()
        guard await waitFor({ held.store.tasks.count == 1 }) else { throw ProbeError.observationSetup }
        await held.suspension.arm(.upsert)
        let heldOperation = held.schedule(a, origin: held.origin)
        let writeEntered = await waitFor { await held.suspension.isBlocked() }
        var cleared = false
        let reset = _Concurrency.Task {
            try await held.gate.replacingDataset {
                cleared = true
                try await held.store.eraseAllData()
            }
        }
        _ = await waitFor { held.gate.isPaused || cleared }
        let waited = held.gate.isPaused && !cleared
        await held.suspension.release()
        await heldOperation?.value
        try await reset.value
        let remaining = try await held.rows.fetchAll(), queue = try await held.queue.all()
        check("title_internal_write_drains_before_reset",
              writeEntered && waited && cleared && remaining.isEmpty && queue.isEmpty)
    }
    @MainActor static func terminalChecks(root: URL) async throws {
        for archived in [false, true] {
            let rig = try ShareRig(directory: root.appendingPathComponent(archived ? "archived" : "trashed"))
            defer { rig.close() }
            let original = row("Do not recreate")
            try await rig.rows.upsert(original)
            if archived { try await rig.store.archive(original) }
            else { try await rig.store.delete(original) }
            let queueBefore = try await rig.queue.all()
            try rig.outbox.write(capture("Late original share", origin: rig.origin))
            await rig.drainer.drain(enrichTitles: false)
            let current = try await rig.rows.fetchAll(), queueAfter = try await rig.queue.all()
            let terminal = archived
                ? try await rig.store.archivedTasksStamped().map(\.task.id)
                : try await rig.store.trashedTasks().map(\.task.id)
            check(archived ? "retained_archive_blocks_share_replay" : "retained_trash_blocks_share_replay",
                  current.isEmpty && queueAfter == queueBefore && terminal == [original.id]
                  && rig.outbox.pending().isEmpty)
        }
    }
    @MainActor static func liveReplayChecks(root: URL) async throws {
        for pushed in [false, true] {
            let rig = try ShareRig(directory: root.appendingPathComponent(pushed ? "live-pushed-replay" : "live-queued-replay"))
            defer { rig.close() }
            var edited = row("Canonical title after the first creation")
            edited.description = "A later canonical note"
            edited.completed = true
            edited.tags = ["manual"]
            edited.updatedAt = stamp.addingTimeInterval(50)
            try await rig.rows.upsert(edited)
            let before = try await rig.rows.fetchAll(), queueBefore = try await rig.queue.all()
            try rig.outbox.write(capture("Original stale creation", origin: rig.origin, pushed: pushed))
            await rig.drainer.drain(enrichTitles: false)
            let after = try await rig.rows.fetchAll(), queueAfter = try await rig.queue.all()
            check(pushed ? "canonical_edit_survives_pushed_creation_replay" : "canonical_edit_survives_queued_creation_replay",
                  after == before && queueAfter == queueBefore && rig.outbox.pending().isEmpty)
        }
        let retry = try ShareRig(directory: root.appendingPathComponent("edited-retry-held"))
        defer { retry.close() }
        let canonical = row("Keep the canonical edit")
        try await retry.rows.upsert(canonical)
        let before = try await retry.rows.fetchAll(), queueBefore = try await retry.queue.all()
        // The original retry fixture deliberately uses the same timestamp for both submits.
        try retry.outbox.write(capture("User changed the failed sheet", origin: retry.origin, editedRetry: true))
        await retry.drainer.drain(enrichTitles: false)
        let after = try await retry.rows.fetchAll(), queueAfter = try await retry.queue.all()
        let retained = retry.outbox.pending()
        check("distinct_edited_retry_is_retained_without_overwriting_canonical",
              after == before && queueAfter == queueBefore && retained.count == 1
              && retained.first?.capture.title == "User changed the failed sheet"
              && retained.first?.capture.taskID == canonical.id)
    }

    @MainActor static func reviewLeaseCheck(root: URL) async throws {
        let rig = try ShareRig(directory: root.appendingPathComponent("open-review"))
        defer { rig.close() }
        try rig.outbox.write(capture("Review A content", origin: rig.origin))
        guard let item = rig.drainer.reviewItems().first, item.canReview else { throw ProbeError.observationSetup }
        #if SHARE_REVIEW_LEASED
        guard let lease = item.reviewLease else { throw ProbeError.observationSetup }
        let allowed: @MainActor () -> Bool = { rig.drainer.isReviewCurrent(lease) }
        #else
        // This is the original view's one-time presentation decision. It then retains
        // and renders the captured value without consulting current identity again.
        let allowed: @MainActor () -> Bool = { item.canReview }
        #endif
        let initiallyAllowed = allowed()
        rig.identity.owner = nil
        let hiddenDuringTransition = !allowed()
        rig.identity.owner = "share-fixture-account-a"
        let oldLeaseStillInvalid = !allowed()
        rig.identity.owner = "share-fixture-account-b"
        let hiddenUnderB = !allowed()
        rig.identity.owner = "share-fixture-account-a"
        let canReselect = await waitFor { rig.drainer.reviewItems().first?.canReview == true }
        check("open_share_review_does_not_follow_account_transitions", initiallyAllowed
              && hiddenDuringTransition && oldLeaseStillInvalid && hiddenUnderB && canReselect && !allowed())
    }

    enum ProbeError: Error { case observationSetup, isolationRequired }
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDShareScope-" + UUID().uuidString)
        do {
            guard HarnessLaunch.isIsolated else { throw ProbeError.isolationRequired }
            AppGroupDefaults.shared.set(true, forKey: AppGroupDefaults.Key.fetchShareTitles)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await heldChecks(root: root)
            try await currentControl(root: root)
            try await writeChecks(root: root)
            try await titleChecks(root: root)
            try await terminalChecks(root: root)
            try await liveReplayChecks(root: root)
            try await reviewLeaseCheck(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("SHARE_SCOPE_ERROR " + String(describing: error)); exit(2)
        }
    }
}
