import Foundation
import Observation
import Synchronization
import GSDModel
import GSDStore
import GSDSnapshot

// UserNotifications is a recording platform double; TaskStore, GRDB, reminder math,
// scope codec, gate, and BackgroundDatabaseWindow remain the actual production code.
struct UNNotificationSound: Sendable { static let defaultSound = Self() }
extension UNNotificationSound { static var `default`: Self { defaultSound } }
final class UNMutableNotificationContent: @unchecked Sendable {
    var title = ""
    var body = ""
    var sound: UNNotificationSound?
    var userInfo: [AnyHashable: Any] = [:]
    var categoryIdentifier = ""
}
final class UNCalendarNotificationTrigger: Sendable {
    let dateComponents: DateComponents
    let repeats: Bool
    init(dateMatching: DateComponents, repeats: Bool) {
        dateComponents = dateMatching; self.repeats = repeats
    }
}
final class UNNotificationRequest: Sendable {
    let identifier: String
    let content: UNMutableNotificationContent
    let trigger: UNCalendarNotificationTrigger?
    init(identifier: String, content: UNMutableNotificationContent, trigger: UNCalendarNotificationTrigger?) {
        self.identifier = identifier; self.content = content; self.trigger = trigger
    }
}
enum UNAuthorizationStatus: Sendable { case notDetermined, authorized, provisional, ephemeral, denied }
struct UNNotificationSettings: Sendable { let authorizationStatus: UNAuthorizationStatus }
struct UNAuthorizationOptions: OptionSet, Sendable {
    let rawValue: Int
    static let alert = Self(rawValue: 1), sound = Self(rawValue: 2), badge = Self(rawValue: 4)
}
final class UNUserNotificationCenter: Sendable {
    struct State: Sendable {
        var requests: [String: UNNotificationRequest] = [:]
        var adds = 0
        var removals = 0
        var beforeAdd: (@Sendable () async -> Void)?
    }
    private let state = Mutex(State())
    private static let instance = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { instance }
    func add(_ request: UNNotificationRequest) async throws {
        let before = state.withLock { $0.beforeAdd }
        if let before { await before() }
        state.withLock { $0.adds += 1; $0.requests[request.identifier] = request }
    }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        state.withLock { value in
            value.removals += 1
            for id in ids { value.requests.removeValue(forKey: id) }
        }
    }
    func removeAllPendingNotificationRequests() {
        state.withLock { $0.removals += 1; $0.requests.removeAll() }
    }
    func notificationSettings() async -> UNNotificationSettings { .init(authorizationStatus: .authorized) }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func setBadgeCount(_ count: Int) async throws {}
    func reset() { state.withLock { $0 = State() } }
    func recording() -> State { state.withLock { $0 } }
    func holdAdd(_ hook: (@Sendable () async -> Void)?) { state.withLock { $0.beforeAdd = hook } }
}
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
actor ReminderReadControl {
    enum Failure: Error { case unavailable }
    private var holdNext = false
    private var failNext = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(hold: Bool = false, fail: Bool = false) { holdNext = hold; failNext = fail }
    func afterRead() async throws {
        if failNext { failNext = false; throw Failure.unavailable }
        if holdNext {
            holdNext = false
            blocked = true
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func isBlocked() -> Bool { blocked }
    func release() { continuation?.resume(); continuation = nil; blocked = false }
}
final class ReminderRepository: TaskRepository, Sendable {
    let base: GRDBTaskRepository
    let control: ReminderReadControl
    init(base: GRDBTaskRepository, control: ReminderReadControl) { self.base = base; self.control = control }
    func upsert(_ task: GSDModel.Task) async throws { try await base.upsert(task) }
    func fetchAll() async throws -> [GSDModel.Task] { try await base.fetchAll() }
    func fetch(id: String) async throws -> GSDModel.Task? {
        let captured = try await base.fetch(id: id)
        try await control.afterRead()
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
@MainActor @Observable final class ReminderIdentity {
    var owner: String? = "reminder-fixture-account-a"
}
@MainActor final class ReminderHold {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class ReminderRig {
    let database: AppDatabase
    let rows: GRDBTaskRepository
    let control = ReminderReadControl()
    let store: TaskStore
    let scheduler: LiveReminderScheduler
    let gate: WatchMutationGate
    let identity = ReminderIdentity()
    let defaults: UserDefaults
    let suite = "GSDReminderScope-" + UUID().uuidString
    init(directory: URL, configured: Bool = true) throws {
        database = try AppDatabase.inMemory()
        rows = GRDBTaskRepository(database)
        defaults = UserDefaults(suiteName: suite)!
        scheduler = LiveReminderScheduler(settingsProvider: { NotificationSettings() },
                                          calendar: ReminderScopeProbe.calendar,
                                          now: { ReminderScopeProbe.now })
        store = TaskStore(repository: ReminderRepository(base: rows, control: control),
                          smartViewRepository: GRDBSmartViewRepository(database),
                          archiveRepository: GRDBArchiveRepository(database),
                          trashRepository: GRDBTrashRepository(database),
                          defaults: defaults, feedbackDefaults: defaults)
        gate = WatchMutationGate(directory: directory)
        if configured { configure() }
    }
    func configure() {
        let identity = identity, gate = gate
        let scope: @MainActor @Sendable () -> WatchAccountScope? = {
            guard !gate.isPaused, let owner = identity.owner, let dataset = gate.identity?.datasetID else { return nil }
            return .account(userID: owner, datasetID: dataset)
        }
        #if REMINDER_CANONICAL_CONTEXT
        scheduler.configureScope(store: store, mutationGate: gate, scopeProvider: scope)
        #else
        scheduler.setScopeProvider(scope)
        #endif
    }
    var scope: WatchAccountScope? {
        guard let owner = identity.owner, let dataset = gate.identity?.datasetID else { return nil }
        return .account(userID: owner, datasetID: dataset)
    }
    func close() { defaults.removePersistentDomain(forName: suite) }
}

@main struct ReminderScopeProbe {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let calendar: Calendar = {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(secondsFromGMT: 0)!; return result
    }()
    @MainActor static var failures = 0
    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("REMINDER_SCOPE_CHECK " + String(decoding: data, as: UTF8.self))
    }
    @MainActor static func waitFor(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    static func task(_ title: String) -> GSDModel.Task {
        GSDModel.Task(id: "same-imported-id", title: title, description: title + " body",
                      urgent: true, important: true, createdAt: now, updatedAt: now,
                      dueDate: now.addingTimeInterval(title.hasPrefix("B") ? 7200 : 3600))
    }
    @MainActor static func seedRequest(_ title: String) async throws {
        let content = UNMutableNotificationContent(); content.title = title
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "task-same-imported-id", content: content, trigger: nil))
    }
    @MainActor static func checks(root: URL) async throws {
        let center = UNUserNotificationCenter.current()
        center.reset()
        let canonical = try ReminderRig(directory: root.appendingPathComponent("canonical"))
        defer { canonical.close() }
        canonical.identity.owner = "reminder-fixture-account-b"
        let old = task("A old title"), actual = task("B canonical title")
        try await canonical.rows.upsert(actual)
        await canonical.scheduler.schedule(old)
        let request = center.recording().requests["task-" + actual.id]
        let expectedFire = actual.dueDate!.addingTimeInterval(-15 * 60)
        check("reminder_uses_canonical_row_for_scoped_payload", request?.content.title == actual.title
              && request?.content.body == actual.description
              && request?.content.userInfo["taskID"] as? String == actual.id
              && request.flatMap { WatchAccountScope.fromNotification($0.content.userInfo) } == canonical.scope
              && request?.trigger?.dateComponents == calendar.dateComponents([.year, .month, .day, .hour, .minute], from: expectedFire))

        center.reset()
        let missing = try ReminderRig(directory: root.appendingPathComponent("missing"))
        defer { missing.close() }
        try await seedRequest("Old pending reminder")
        await missing.scheduler.schedule(old)
        check("reminder_missing_canonical_task_cancels_stale_copy", center.recording().requests.isEmpty
              && center.recording().adds == 1 && center.recording().removals == 1)

        center.reset()
        let unconfigured = try ReminderRig(directory: root.appendingPathComponent("unconfigured"), configured: false)
        defer { unconfigured.close() }
        try await unconfigured.rows.upsert(old)
        await unconfigured.scheduler.schedule(old)
        check("reminder_requires_configured_verified_scope", center.recording().adds == 0
              && center.recording().removals == 0)

        center.reset()
        let cancelled = try ReminderRig(directory: root.appendingPathComponent("cancelled"))
        defer { cancelled.close() }
        try await cancelled.rows.upsert(old)
        let hold = ReminderHold()
        let operation = _Concurrency.Task {
            await hold.wait()
            await cancelled.scheduler.schedule(old)
        }
        _ = await waitFor { hold.entered }
        operation.cancel()
        hold.release()
        await operation.value
        check("cancelled_resync_cannot_start_new_reminder", center.recording().adds == 0
              && center.recording().removals == 0)

        center.reset()
        let suspended = try ReminderRig(directory: root.appendingPathComponent("suspended"))
        defer { suspended.close() }
        try await suspended.rows.upsert(old)
        await suspended.control.configure(hold: true)
        let scheduling = _Concurrency.Task { await suspended.scheduler.schedule(old) }
        let entered = await waitFor { await suspended.control.isBlocked() }
        suspended.identity.owner = "reminder-fixture-account-b"
        try await suspended.rows.upsert(actual)
        await suspended.control.release()
        await scheduling.value
        let noWrongPayload = center.recording().adds == 0
        await suspended.scheduler.schedule(old)
        let current = center.recording().requests["task-" + old.id]
        check("reminder_revalidates_scope_after_suspended_read", entered && noWrongPayload
              && current?.content.title == actual.title
              && current.flatMap { WatchAccountScope.fromNotification($0.content.userInfo) } == suspended.scope)

        center.reset()
        let failed = try ReminderRig(directory: root.appendingPathComponent("read-failure"))
        defer { failed.close() }
        try await failed.rows.upsert(actual)
        try await seedRequest("Preserve existing request on read error")
        await failed.control.configure(fail: true)
        await failed.scheduler.schedule(old)
        check("reminder_read_failure_preserves_existing_request",
              center.recording().requests["task-" + old.id]?.content.title == "Preserve existing request on read error"
              && center.recording().adds == 1 && center.recording().removals == 0)

        center.reset()
        let paused = try ReminderRig(directory: root.appendingPathComponent("paused"))
        defer { paused.close() }
        try await paused.rows.upsert(old)
        await paused.gate.withPaused { await paused.scheduler.schedule(old) }
        check("paused_dataset_blocks_reminder_admission", center.recording().adds == 0
              && center.recording().removals == 0 && !paused.gate.isPaused)

        center.reset()
        let draining = try ReminderRig(directory: root.appendingPathComponent("drain"))
        defer { draining.close() }
        try await draining.rows.upsert(old)
        let addHold = ReminderHold()
        center.holdAdd { await addHold.wait() }
        let addition = _Concurrency.Task { await draining.scheduler.schedule(old) }
        let reachedAdd = await waitFor { addHold.entered }
        var erased = false
        let reset = _Concurrency.Task {
            try await draining.gate.replacingDataset {
                erased = true
                try await draining.rows.replaceAll([])
                await draining.scheduler.cancelAll()
            }
        }
        _ = await waitFor { draining.gate.isPaused || erased }
        let heldUntilAdd = draining.gate.isPaused && !erased
        addHold.release()
        await addition.value
        try await reset.value
        center.holdAdd(nil)
        check("dataset_reset_drains_admitted_notification_add", reachedAdd && heldUntilAdd && erased
              && center.recording().requests.isEmpty && !draining.gate.isPaused)
    }
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDReminderScope-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await checks(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("REMINDER_SCOPE_ERROR " + String(describing: error)); exit(2)
        }
    }
}
