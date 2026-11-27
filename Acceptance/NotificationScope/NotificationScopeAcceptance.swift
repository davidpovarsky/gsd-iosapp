#if GSD_NOTIFICATION_UIKIT_STUB
/// Compile-only foreground UIApplication surface for the isolated macOS acceptance executable.
/// No TaskStore, reminder handler, repository, outbox, scope or gate behavior is replaced.
@MainActor
public final class UIApplication {
    public enum State { case active, inactive, background }
    public static let shared = UIApplication()
    public var applicationState: State { .active }
}
#else
import Foundation
import Darwin
import GSDModel
import GSDStore
import GSDSnapshot

@main @MainActor
enum NotificationScopeAcceptance {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor private final class Identity {
        var scope: WatchAccountScope?
    }

    @MainActor private final class Completion {
        var count = 0
        func finish() { count += 1 }
    }

    /// A controlled suspension around the real GRDB repository, never a replacement store.
    private actor FetchControl {
        private var holdID: String?
        private var holdAt = 0
        private var fetches = 0
        private var suspended: CheckedContinuation<Void, Never>?
        private var failingID: String?
        private(set) var isHeld = false

        func hold(_ id: String, at fetch: Int) {
            holdID = id
            holdAt = fetch
            fetches = 0
            isHeld = false
        }

        func failNext(_ id: String) { failingID = id }

        func beforeFetch(_ id: String) async throws {
            if failingID == id {
                failingID = nil
                throw Failure("Intentional repository read failure.")
            }
            guard holdID == id else { return }
            fetches += 1
            guard fetches == holdAt else { return }
            holdID = nil
            isHeld = true
            await withCheckedContinuation { suspended = $0 }
        }

        func release() {
            let continuation = suspended
            suspended = nil
            isHeld = false
            continuation?.resume()
        }
    }

    private final class ControlledRepository: TaskRepository {
        let base: GRDBTaskRepository
        let control = FetchControl()

        init(_ database: AppDatabase) { base = GRDBTaskRepository(database) }
        func upsert(_ task: GSDModel.Task) async throws { try await base.upsert(task) }
        func fetchAll() async throws -> [GSDModel.Task] { try await base.fetchAll() }
        func fetch(id: String) async throws -> GSDModel.Task? {
            try await control.beforeFetch(id)
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

    @MainActor private final class Fixture {
        let suite = "gsd.notification.scope.fixture.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsd-notification-scope-\(UUID().uuidString)", isDirectory: true)
        let defaults: UserDefaults
        let repository: ControlledRepository
        let queue: GRDBSyncQueueRepository
        let store: TaskStore
        let gate: WatchMutationGate
        let identity = Identity()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        init() throws {
            let defaults = UserDefaults(suiteName: suite)!
            self.defaults = defaults
            let database = try AppDatabase.inMemory()
            let repository = ControlledRepository(database)
            self.repository = repository
            let queue = GRDBSyncQueueRepository(database)
            self.queue = queue
            let fixedNow = now
            store = TaskStore(repository: repository,
                              smartViewRepository: GRDBSmartViewRepository(database),
                              archiveRepository: GRDBArchiveRepository(database),
                              trashRepository: GRDBTrashRepository(database),
                              defaults: defaults, feedbackDefaults: defaults,
                              clock: { fixedNow }, syncQueue: queue)
            gate = WatchMutationGate(directory: directory)
            guard gate.identity != nil else { throw Failure("Fresh isolated gate identity is unavailable.") }
        }

        func account(_ id: String) throws -> WatchAccountScope {
            guard let dataset = gate.identity?.datasetID else { throw Failure("Missing dataset identity.") }
            return .account(userID: id, datasetID: dataset)
        }

        func attach() {
            #if GSD_NOTIFICATION_SCOPE_BASELINE
            // Only the old call signature differs in the RED source; the assertion is unchanged.
            ReminderActionInbox.attach(store: store)
            #else
            ReminderActionInbox.attach(store: store, mutationGate: gate,
                                       scopeProvider: { [identity] in identity.scope })
            #endif
        }

        func seed(_ id: String = "imported-same-id", title: String = "Current account task") async throws {
            try await store.ingestSynced(GSDModel.Task(
                id: id, title: title, urgent: false, important: true,
                createdAt: now, updatedAt: now, dueDate: now.addingTimeInterval(3600)))
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private static func wait(_ description: String,
                             until condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        throw Failure("Timed out waiting for \(description).")
    }

    private static func deliver(_ action: String = ReminderAction.completeID,
                                taskID: String = "imported-same-id",
                                scope: WatchAccountScope?, completion: Completion) {
        #if GSD_NOTIFICATION_SCOPE_BASELINE
        ReminderActionInbox.deliver(action: action, taskID: taskID, done: completion.finish)
        #else
        ReminderActionInbox.deliver(action: action, taskID: taskID,
                                    scope: scope, done: completion.finish)
        #endif
    }

    private static func finish(_ completion: Completion) async throws {
        try await wait("exactly one notification completion") { completion.count > 0 }
        try require(completion.count == 1, "Notification completion must be called exactly once.")
    }

    private static func coldAction() async throws {
        // This is first in a fresh process, before the production singleton has any attachment.
        let f = try Fixture()
        defer { f.clean() }
        let origin = try f.account("account-A")
        f.identity.scope = try f.account("account-B")
        try await f.seed(title: "B imported the same ID")
        let before = try await f.store.fetchTask(id: "imported-same-id")
        let completion = Completion()
        deliver(scope: origin, completion: completion)
        try require(completion.count == 0, "A valid cold action should wait for its store attachment.")
        f.attach()
        try await finish(completion)
        let after = try await f.store.fetchTask(id: "imported-same-id")
        try require(after == before, "A cold A action must not inherit account B when the store attaches.")
        let queued = try await f.queue.all()
        try require(queued.isEmpty, "Refused cold action must not create an outbox write.")
    }

    private static func crossAccountAction() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let origin = try f.account("account-A")
        f.identity.scope = try f.account("account-B")
        try await f.seed(title: "B imported the same ID")
        f.attach()
        let before = try await f.store.fetchTask(id: "imported-same-id")
        let completion = Completion()
        deliver(scope: origin, completion: completion)
        try await finish(completion)
        let after = try await f.store.fetchTask(id: "imported-same-id")
        try require(after == before,
                    "An account A notification must not mutate account B's task with the same imported ID.")
        let queued = try await f.queue.all()
        try require(queued.isEmpty, "Cross-account refusal must leave the real outbox unchanged.")
    }

    private static func matchingActions() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let scope = try f.account("account-A")
        f.identity.scope = scope
        try await f.seed("complete")
        try await f.seed("snooze")
        f.attach()
        let complete = Completion()
        deliver(taskID: "complete", scope: scope, completion: complete)
        try await finish(complete)
        let snooze = Completion()
        deliver(ReminderAction.snoozeID, taskID: "snooze", scope: scope, completion: snooze)
        try await finish(snooze)
        let completedTask = try await f.store.fetchTask(id: "complete")
        let snoozedTask = try await f.store.fetchTask(id: "snooze")
        try require(completedTask?.completed == true, "Matching Complete must reach the canonical repository.")
        try require(snoozedTask?.completed == false
                    && snoozedTask?.snoozedUntil == f.now.addingTimeInterval(3600),
                    "Matching Snooze must retain the task and persist the original one-hour behavior.")
        let queued = try await f.queue.all()
        try require(queued.count == 2 && Set(queued.map(\.taskId)) == ["complete", "snooze"]
                    && queued.allSatisfy { $0.operation == .update },
                    "Both matching actions must create their real update outbox entries.")
    }

    private static func refusedActions() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let scope = try f.account("account-A")
        f.identity.scope = scope
        try await f.seed()
        f.attach()
        let before = try await f.store.fetchTask(id: "imported-same-id")
        let invalidData = try JSONSerialization.data(withJSONObject: [
            "kind": "future-unknown", "identifier": "account-A",
            "datasetID": scope.datasetID!
        ])
        let invalid = try JSONDecoder().decode(WatchAccountScope.self, from: invalidData)
        for origin in [nil, invalid] as [WatchAccountScope?] {
            let completion = Completion()
            deliver(scope: origin, completion: completion)
            try await finish(completion)
        }
        try await f.gate.withPaused {
            let completion = Completion()
            deliver(scope: scope, completion: completion)
            try await finish(completion)
        }
        let after = try await f.store.fetchTask(id: "imported-same-id")
        let queued = try await f.queue.all()
        try require(after == before && queued.isEmpty,
                    "Legacy, invalid and paused actions must finish without task or outbox writes.")
    }

    private static func queuedAcrossReplacement() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let origin = try f.account("account-A")
        f.identity.scope = origin
        try await f.seed("first", title: "A admitted action")
        try await f.seed(title: "A original")
        f.attach()
        // Fetch one is ReminderActionHandler; fetch two is inside the real toggleComplete.
        await f.repository.control.hold("first", at: 2)
        let first = Completion()
        deliver(taskID: "first", scope: origin, completion: first)
        try await wait("the real TaskStore internal fetch") { await f.repository.control.isHeld }
        let queued = Completion()
        deliver(scope: origin, completion: queued)
        f.identity.scope = nil
        var replacementStarted = false
        let replacement = _Concurrency.Task { @MainActor in
            try await f.gate.replacingDataset {
                replacementStarted = true
                try await f.store.eraseAllData()
                try await f.seed(title: "B imported the same ID")
                f.identity.scope = try f.account("account-B")
            }
        }
        var admissionFailure: Error?
        do {
            try await wait("closed replacement admission") { f.gate.isPaused }
            try require(!replacementStarted && first.count == 0 && queued.count == 0,
                        "Replacement must wait for the entire admitted TaskStore mutation.")
            try require(f.gate.admit() == nil, "No new mutation ticket may enter during the drain.")
        } catch { admissionFailure = error }
        await f.repository.control.release()
        try await finish(first)
        try await finish(queued)
        try await replacement.value
        if let admissionFailure { throw admissionFailure }
        let after = try await f.store.fetchAllTasks()
        let outbox = try await f.queue.all()
        try require(after.count == 1 && after[0].id == "imported-same-id"
                    && after[0].title == "B imported the same ID" && !after[0].completed,
                    "The queued A action must not complete B or recreate the erased A task.")
        try require(outbox.isEmpty, "No old notification write may survive the replacement outbox reset.")
        try require(f.gate.identity?.datasetID != origin.datasetID, "Reset must rotate the durable dataset.")
        let replay = Completion()
        deliver(scope: origin, completion: replay)
        try await finish(replay)
        let replayed = try await f.store.fetchAllTasks()
        let replayOutbox = try await f.queue.all()
        try require(replayed == after && replayOutbox.isEmpty,
                    "An old notification replay must remain refused after replacement finishes.")
    }

    private static func missingAndError() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let scope = try f.account("account-A")
        f.identity.scope = scope
        try await f.seed()
        f.attach()
        let before = try await f.store.fetchTask(id: "imported-same-id")
        let missing = Completion()
        deliver(taskID: "absent", scope: scope, completion: missing)
        try await finish(missing)
        await f.repository.control.failNext("imported-same-id")
        let failed = Completion()
        deliver(scope: scope, completion: failed)
        try await finish(failed)
        let after = try await f.store.fetchTask(id: "imported-same-id")
        let queued = try await f.queue.all()
        try require(after == before && queued.isEmpty,
                    "Missing tasks and repository errors must complete once without a mutation.")
    }

    #if !GSD_NOTIFICATION_SCOPE_BASELINE
    private static func persistedOpen() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let origin = try f.account("account-A")
        f.identity.scope = try f.account("account-B")
        try await f.seed(title: "B imported the same ID")
        f.attach()
        let original = ReminderActionInbox.requestOpen(taskID: "imported-same-id", scope: origin,
                                                       defaults: f.defaults)
        let reloadedDefaults = UserDefaults(suiteName: f.suite)!
        guard let request = ReminderActionInbox.consumePendingOpen(defaults: reloadedDefaults) else {
            throw Failure("The persisted typed notification request did not reload.")
        }
        try require(request == original && request.scope == origin,
                    "Reload must preserve the exact scheduled scope and request identity.")
        var presented = 0
        let opened = await ReminderActionInbox.resolveOpen(request) { _ in presented += 1 }
        try require(!opened && presented == 0,
                    "A persisted A tap must never present B's same-ID task.")
        try require(ReminderActionInbox.consumePendingOpen(defaults: f.defaults) == nil,
                    "A consumed request must not replay on another launch.")
        try require(ReminderActionInbox.requestOpen(taskID: "imported-same-id", scope: nil,
                                                    defaults: f.defaults) == nil,
                    "A legacy unscoped tap must not acquire the current account.")
        let old = ReminderActionInbox.requestOpen(taskID: "imported-same-id", scope: origin,
                                                  defaults: f.defaults)!
        let newer = ReminderActionInbox.requestOpen(taskID: "another-id", scope: origin,
                                                    defaults: f.defaults)!
        try require(ReminderActionInbox.consumePendingOpen(matching: old.id, defaults: f.defaults) == nil,
                    "A stale live delivery must not consume a newer request.")
        try require(ReminderActionInbox.consumePendingOpen(defaults: f.defaults) == newer,
                    "The newer scoped request must remain available.")
        f.identity.scope = origin
        try await f.gate.replacingDataset {
            try await f.store.eraseAllData()
            try await f.seed(title: "A recreated the same ID after reset")
            f.identity.scope = try f.account("account-A")
        }
        let resetOpen = await ReminderActionInbox.resolveOpen(request) { _ in presented += 1 }
        try require(f.identity.scope?.identifier == origin.identifier
                    && f.identity.scope?.datasetID != origin.datasetID && !resetOpen && presented == 0,
                    "An old tap must remain refused after the same account resets and recreates its task ID.")
        let queued = try await f.queue.all()
        try require(queued.isEmpty, "Refused notification presentation must not enqueue any write.")
    }

    private static func suspendedOpen() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let origin = try f.account("account-A")
        f.identity.scope = origin
        try await f.seed(title: "A original")
        f.attach()
        let request = ReminderActionInbox.requestOpen(taskID: "imported-same-id", scope: origin,
                                                       defaults: f.defaults)!
        _ = ReminderActionInbox.consumePendingOpen(defaults: f.defaults)
        await f.repository.control.hold("imported-same-id", at: 1)
        var presented = 0
        let opening = _Concurrency.Task { @MainActor in
            await ReminderActionInbox.resolveOpen(request) { _ in presented += 1 }
        }
        try await wait("the notification's canonical fetch") { await f.repository.control.isHeld }
        f.identity.scope = nil
        var replacementStarted = false
        let replacement = _Concurrency.Task { @MainActor in
            try await f.gate.replacingDataset {
                replacementStarted = true
                try await f.store.eraseAllData()
                try await f.seed(title: "B imported the same ID")
                f.identity.scope = try f.account("account-B")
            }
        }
        var admissionFailure: Error?
        do {
            try await wait("closed admission during notification fetch") { f.gate.isPaused }
            try require(!replacementStarted && presented == 0,
                        "Dataset replacement must wait through the notification fetch.")
        } catch { admissionFailure = error }
        await f.repository.control.release()
        let opened = await opening.value
        try await replacement.value
        if let admissionFailure { throw admissionFailure }
        try require(!opened && presented == 0,
                    "Post-await identity validation must reject presentation during the account transition.")
        let reopened = await ReminderActionInbox.resolveOpen(request) { _ in presented += 1 }
        let after = try await f.store.fetchTask(id: "imported-same-id")
        try require(!reopened && presented == 0 && after?.title == "B imported the same ID",
                    "The old request must not open B after the transition finishes.")
        let queued = try await f.queue.all()
        try require(queued.isEmpty, "Reading/refusing a notification must leave the real outbox empty.")
    }

    private static func validOpen() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let scope = try f.account("account-A")
        f.identity.scope = scope
        try await f.seed(title: "The exact canonical task")
        f.attach()
        let before = try await f.store.fetchAllTasks()
        let beforeOutbox = try await f.queue.all()
        let original = ReminderActionInbox.requestOpen(taskID: "imported-same-id", scope: scope,
                                                       defaults: f.defaults)!
        guard let request = ReminderActionInbox.consumePendingOpen(matching: original.id, defaults: f.defaults) else {
            throw Failure("A matching live notification request was not consumed.")
        }
        var presented: [GSDModel.Task] = []
        var callbackScopeMatched = false
        let opened = await ReminderActionInbox.resolveOpen(request) { task in
            callbackScopeMatched = f.identity.scope == scope && f.gate.identity?.datasetID == scope.datasetID
            presented.append(task)
        }
        let after = try await f.store.fetchAllTasks()
        let afterOutbox = try await f.queue.all()
        try require(opened && callbackScopeMatched && presented == before,
                    "The synchronous callback must receive exactly the canonical task in its validated scope.")
        try require(after == before && afterOutbox == beforeOutbox,
                    "Opening a valid scoped notification must not mutate tasks or the outbox.")
    }
    #endif

    private static func emit(_ prefix: String, _ payload: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(prefix + " " + String(decoding: data, as: UTF8.self))
    }

    static func main() async {
        guard ProcessInfo.processInfo.environment["GSD_NOTIFICATION_SCOPE_FIXTURE_ALLOWED"] == "1" else {
            FileHandle.standardError.write(Data("Explicit isolated-fixture admission is required.\n".utf8))
            exit(64)
        }
        var checks: [(String, @MainActor () async throws -> Void)] = [
            ("cold_action_retains_original_scope_until_attach", coldAction),
            ("cross_account_action_cannot_mutate_same_id_task", crossAccountAction),
            ("matching_scope_actions_reach_canonical_store", matchingActions),
            ("legacy_invalid_and_paused_actions_complete_without_writes", refusedActions),
            ("queued_action_cannot_cross_account_dataset_replacement", queuedAcrossReplacement),
            ("missing_task_and_read_error_complete_once", missingAndError)
        ]
        #if !GSD_NOTIFICATION_SCOPE_BASELINE
        checks += [
            ("persisted_open_refuses_cross_account_and_legacy_payloads", persistedOpen),
            ("scoped_open_revalidates_after_suspended_fetch", suspendedOpen),
            ("valid_open_reads_canonical_task_without_mutation", validOpen)
        ]
        #endif
        if let selected = ProcessInfo.processInfo.environment["GSD_NOTIFICATION_SCOPE_FIXTURE_CASE"] {
            checks = checks.filter { $0.0 == selected }
            guard checks.count == 1 else {
                FileHandle.standardError.write(Data("Unknown exact fixture case.\n".utf8))
                exit(64)
            }
        }
        var failures = 0
        for (name, check) in checks {
            do {
                try await check()
                emit("NOTIFICATION_SCOPE_CHECK", ["id": name, "passed": true])
            } catch {
                failures += 1
                emit("NOTIFICATION_SCOPE_CHECK", ["id": name, "passed": false,
                                                   "error": String(describing: error)])
            }
        }
        emit("NOTIFICATION_SCOPE_RESULT", ["checks": checks.map { $0.0 },
                                           "passed": checks.count - failures, "failed": failures,
                                           "realTaskStore": true, "realGRDB": true,
                                           "realReminderHandler": true, "realOutbox": true,
                                           "uiApplicationForegroundStub": true,
                                           "personalAccounts": false, "externalNetwork": false])
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
