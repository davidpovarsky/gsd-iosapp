import Observation

struct ProbeScope: Codable, Equatable, Sendable {
    let kind: String
    let identifier: String
    let datasetID: String?
}
@MainActor @Observable final class ProbeIdentity {
    var value: String?
    init(_ value: String?) { self.value = value }
}
@MainActor final class ProbeReadHold {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class ProbePhone {
    let store: TaskStore
    let identity: ProbeIdentity
    let defaults: UserDefaults
    let suite = "GSDWatchScopePhone-" + UUID().uuidString
    let phone: WatchSessionCoordinator
    #if WATCH_ACCOUNT_SCOPED
    let gate: WatchMutationGate
    #else
    var datasetID: String
    #endif

    init(owner: String?, dataset: String, directory: URL) throws {
        store = TaskStore()
        store.allowsMutations = true
        identity = ProbeIdentity(owner)
        defaults = UserDefaults(suiteName: suite)!
        #if WATCH_ACCOUNT_SCOPED
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityData = try JSONSerialization.data(withJSONObject: [
            "installationID": WatchScopeProbe.installation, "datasetID": dataset])
        try identityData.write(to: directory.appendingPathComponent("watch-dataset-identity.json"))
        let gate = WatchMutationGate(directory: directory)
        self.gate = gate
        let identity = identity
        phone = WatchSessionCoordinator(store: store, enabled: true, mutationGate: gate,
            scopeProvider: {
                guard let owner = identity.value, let dataset = gate.identity?.datasetID else { return nil }
                return .account(userID: owner, datasetID: dataset)
            }, defaults: defaults, debounce: .zero)
        #else
        datasetID = dataset
        phone = WatchSessionCoordinator(store: store, enabled: true, defaults: defaults, debounce: .zero)
        #endif
        phone.start()
    }

    var scope: ProbeScope? {
        guard let owner = identity.value else { return nil }
        #if WATCH_ACCOUNT_SCOPED
        guard let datasetID = gate.identity?.datasetID else { return nil }
        #endif
        return ProbeScope(kind: "account", identifier: owner, datasetID: datasetID)
    }

    func replaceDataset() async throws {
        #if WATCH_ACCOUNT_SCOPED
        try await gate.replacingDataset {}
        #else
        // Baseline has no reset generation guard. This is the expected new dataset identity,
        // while the unchanged coordinator still applies the old command.
        datasetID = UUID().uuidString
        #endif
    }

    func close() { defaults.removePersistentDomain(forName: suite) }
}

#if WATCH_ACCOUNT_SCOPED
typealias ProbeOrigin = WatchModel.ActionLease
#else
struct ProbeOrigin { let scope: ProbeScope? }
#endif

@main struct WatchScopeProbe {
    static let installation = "11111111-1111-4111-8111-111111111111"
    static let dataset = "22222222-2222-4222-8222-222222222222"
    static let accountA = ProbeScope(kind: "account", identifier: "scope-fixture-account-a", datasetID: dataset)
    static let accountB = ProbeScope(kind: "account", identifier: "scope-fixture-account-b", datasetID: dataset)
    @MainActor static var failures = 0
    @MainActor static var stamp = Date(timeIntervalSince1970: 2_000_000_000)

    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("WATCH_SCOPE_CHECK " + String(decoding: data, as: UTF8.self))
    }

    static func encodeScope(_ scope: ProbeScope?) throws -> Any? {
        try scope.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
    }

    static func wireScope<T: Encodable>(_ value: T) -> ProbeScope? {
        guard let bytes = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let raw = object["accountScope"],
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(ProbeScope.self, from: data)
    }

    static func scopedCommand(_ kind: WatchCommand.Kind, scope: ProbeScope?) throws -> WatchCommand {
        let command = WatchCommand(id: UUID().uuidString, issuedAt: .now, kind: kind)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
        object["accountScope"] = try encodeScope(scope)
        return try JSONDecoder().decode(WatchCommand.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor static func snapshot(scope: ProbeScope?, tasks: [WatchTask] = [], acks: [String] = []) throws -> WatchSnapshot {
        stamp = stamp.addingTimeInterval(1)
        let snapshot = WatchSnapshot(generatedAt: stamp, escalationWindowDays: nil,
                                     tasks: tasks, doFirstTotal: tasks.count, appliedCommandIDs: acks)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        object["accountScope"] = try encodeScope(scope)
        return try JSONDecoder().decode(WatchSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor static func task(_ id: String = "shared-imported-task-id", title: String = "Account A task") -> WatchTask {
        WatchTask(id: id, title: title, urgent: true, important: true,
                  createdAt: .now, updatedAt: .now, isRecurring: false)
    }

    @MainActor static func watch(at directory: URL, snapshot: WatchSnapshot) throws -> WatchModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try WatchSnapshotStore(directoryURL: directory).write(snapshot)
        watchProbeDirectory = directory
        WCSession.default.outstandingUserInfoTransfers = []
        WCSession.default.receivedApplicationContext = [:]
        WCSession.default.activationState = .activated
        return WatchModel()
    }

    @MainActor static func origin(_ watch: WatchModel) -> ProbeOrigin? {
        #if WATCH_ACCOUNT_SCOPED
        watch.actionLease
        #else
        ProbeOrigin(scope: wireScope(watch.snapshot))
        #endif
    }

    @MainActor static func capture(_ watch: WatchModel, _ text: String, origin: ProbeOrigin?) -> Bool {
        #if WATCH_ACCOUNT_SCOPED
        watch.capture(text: text, quadrant: .urgentImportant, origin: origin)
        #else
        watch.capture(text: text, quadrant: .urgentImportant)
        #endif
    }

    @MainActor static func complete(_ watch: WatchModel, _ task: WatchTask, origin: ProbeOrigin?) {
        #if WATCH_ACCOUNT_SCOPED
        watch.complete(task, origin: origin)
        #else
        watch.complete(task)
        #endif
    }

    @MainActor static func heldCount(_ watch: WatchModel) -> Int {
        #if WATCH_ACCOUNT_SCOPED
        watch.quarantinedCount
        #else
        0
        #endif
    }

    @MainActor static func transferred() -> [WatchCommand] {
        WCSession.default.outstandingUserInfoTransfers.compactMap { WatchWire.command(from: $0.userInfo) }
    }

    @MainActor static func waitFor(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor static func receive(_ snapshot: WatchSnapshot, on watch: WatchModel) async throws {
        let context = [WatchWire.snapshotKey: try JSONEncoder().encode(snapshot)]
        watch.session(WCSession.default, didReceiveApplicationContext: context)
        _ = await waitFor { watch.snapshot.generatedAt == snapshot.generatedAt }
    }

    @MainActor static func deliver(_ command: WatchCommand, to phone: ProbePhone) {
        phone.phone.session(WCSession.default, didReceiveUserInfo: WatchWire.userInfo(for: command)!)
    }

    @MainActor static func latestSnapshot() -> WatchSnapshot? {
        WCSession.default.contexts.last.flatMap { $0[WatchWire.snapshotKey] as? Data }
            .flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
    }

    @MainActor static func watchChecks(root: URL) async throws {
        let verifiedDirectory = root.appendingPathComponent("verified")
        let verified = try watch(at: verifiedDirectory, snapshot: snapshot(scope: accountA))
        let accepted = capture(verified, "A durable draft", origin: origin(verified))
        check("scoped_capture_preserves_verified_origin", accepted
              && verified.outbox.commands.count == 1
              && wireScope(verified.outbox.commands[0]) == accountA
              && WatchOutbox(directoryURL: verifiedDirectory).commands == verified.outbox.commands)

        let unknown = try watch(at: root.appendingPathComponent("unknown"),
                                snapshot: snapshot(scope: nil, tasks: [task()]))
        let unknownAccepted = capture(unknown, "Must stay a draft", origin: origin(unknown))
        check("unresolved_snapshot_disables_capture", !unknownAccepted && unknown.outbox.commands.isEmpty && transferred().isEmpty)
        check("legacy_snapshot_hides_unverified_rows", !unknown.hasSnapshot
              && unknown.lists().doFirst.isEmpty && unknown.today().picks.isEmpty
              && unknown.today().suggestions.isEmpty)

        let switchDirectory = root.appendingPathComponent("switch")
        let switched = try watch(at: switchDirectory, snapshot: snapshot(scope: accountA))
        WCSession.default.activationState = .inactive
        _ = capture(switched, "A pending row", origin: origin(switched))
        let pending = switched.outbox.commands
        try await receive(snapshot(scope: accountB), on: switched)
        check("account_change_hides_previous_pending_rows", switched.lists().doFirst.isEmpty
              && switched.lists().pendingCount == 0 && switched.today().picks.isEmpty
              && heldCount(switched) == 1 && switched.outbox.commands == pending)

        let undo = try watch(at: root.appendingPathComponent("undo"),
                             snapshot: snapshot(scope: accountA, tasks: [task()]))
        complete(undo, task(), origin: origin(undo))
        undo.open(taskID: task().id)
        let undoID = undo.undoOffer?.commandID
        try await receive(snapshot(scope: accountB), on: undo)
        check("account_change_clears_undo_and_navigation", undoID != nil && undo.undoOffer == nil
              && !undo.canUndo && undo.openedTaskID == nil && transferred().isEmpty
              && undo.outbox.commands.map(\.id) == [undoID!])

        let staleRow = try watch(at: root.appendingPathComponent("stale-row"),
                                 snapshot: snapshot(scope: accountA, tasks: [task()]))
        let oldRowOrigin = origin(staleRow)
        let bTask = task(title: "Account B task sharing an imported id")
        try await receive(snapshot(scope: accountB, tasks: [bTask]), on: staleRow)
        complete(staleRow, task(), origin: oldRowOrigin)
        let oldRowRejected = staleRow.outbox.commands.isEmpty
        complete(staleRow, bTask, origin: origin(staleRow))
        check("stale_row_callback_cannot_queue_for_new_account", oldRowRejected
              && staleRow.outbox.commands.count == 1 && wireScope(staleRow.outbox.commands[0]) == accountB)

        let draft = try watch(at: root.appendingPathComponent("stale-draft"), snapshot: snapshot(scope: accountA))
        let oldDraftOrigin = origin(draft)
        try await receive(snapshot(scope: accountB), on: draft)
        let staleDraft = capture(draft, "A draft must not move to B", origin: oldDraftOrigin)
        let newDraft = capture(draft, "New B draft", origin: origin(draft))
        check("stale_capture_draft_cannot_move_to_new_account", !staleDraft && newDraft
              && draft.outbox.commands.count == 1 && wireScope(draft.outbox.commands[0]) == accountB)

        let cycle = try watch(at: root.appendingPathComponent("same-account-cycle"), snapshot: snapshot(scope: accountA))
        let beforeCycle = origin(cycle)
        try await receive(snapshot(scope: nil), on: cycle)
        try await receive(snapshot(scope: accountA), on: cycle)
        let oldCycleAccepted = capture(cycle, "Stale callback", origin: beforeCycle)
        let currentAccepted = capture(cycle, "Current callback", origin: origin(cycle))
        check("same_account_transition_invalidates_old_ui_lease", !oldCycleAccepted && currentAccepted
              && cycle.outbox.commands.count == 1)

        let legacyDirectory = root.appendingPathComponent("legacy")
        let legacy = try watch(at: legacyDirectory, snapshot: snapshot(scope: accountA))
        var legacyOutbox = WatchOutbox(directoryURL: legacyDirectory)
        let oldCommand = try scopedCommand(.capture(text: "Unscoped preserved capture", quadrant: .urgentImportant), scope: nil)
        try legacyOutbox.add(oldCommand)
        let legacyReloaded = try watch(at: legacyDirectory, snapshot: legacy.snapshot)
        legacyReloaded.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        check("legacy_unscoped_command_is_kept_and_not_transferred", transferred().isEmpty
              && heldCount(legacyReloaded) == 1 && legacyReloaded.outbox.commands == [oldCommand]
              && WatchOutbox(directoryURL: legacyDirectory).commands == [oldCommand])

        let ackDirectory = root.appendingPathComponent("foreign-ack")
        let foreignAck = try watch(at: ackDirectory, snapshot: snapshot(scope: accountA))
        WCSession.default.activationState = .inactive
        _ = capture(foreignAck, "Keep A command", origin: origin(foreignAck))
        let aCommand = foreignAck.outbox.commands.first!
        try await receive(snapshot(scope: accountB, acks: [aCommand.id]), on: foreignAck)
        let keptDuringB = foreignAck.outbox.commands == [aCommand]
        try await receive(snapshot(scope: accountA, acks: [aCommand.id]), on: foreignAck)
        check("other_account_ack_does_not_discard_held_command", keptDuringB && foreignAck.outbox.commands.isEmpty)

        let restartDirectory = root.appendingPathComponent("scope-relaunch")
        var prior: WatchModel? = try watch(at: restartDirectory, snapshot: snapshot(scope: accountA))
        WCSession.default.activationState = .inactive
        _ = capture(prior!, "Held A after restart", origin: origin(prior!))
        let beforeRestart = prior!.outbox.commands
        try await receive(snapshot(scope: accountB), on: prior!)
        prior = nil
        watchProbeDirectory = restartDirectory
        WCSession.default.outstandingUserInfoTransfers = []
        WCSession.default.activationState = .activated
        let restored = WatchModel()
        restored.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        check("relaunch_preserves_scope_quarantine", restored.lists().doFirst.isEmpty && transferred().isEmpty
              && heldCount(restored) == 1 && restored.outbox.commands == beforeRestart)
        try await receive(snapshot(scope: accountA), on: restored)
        let returned = await waitFor { transferred().count == 1 }
        check("matching_account_returns_held_command_without_rebinding", returned
              && transferred().map(\.id) == beforeRestart.map(\.id)
              && transferred().first.flatMap(wireScope) == accountA)

        let same = try watch(at: root.appendingPathComponent("same-scope-update"), snapshot: snapshot(scope: accountA))
        let stillCurrent = origin(same)
        try await receive(snapshot(scope: accountA, tasks: [task("another-row")]), on: same)
        let keptLease = capture(same, "Current account update", origin: stillCurrent)
        check("snapshot_refresh_keeps_current_ui_lease", keptLease && same.outbox.commands.count == 1)
    }

    @MainActor static func phoneChecks(root: URL) async throws {
        WCSession.default.contexts = []
        let wrong = try ProbePhone(owner: accountA.identifier, dataset: dataset, directory: root.appendingPathComponent("phone-wrong"))
        defer { wrong.close() }
        wrong.identity.value = accountB.identifier
        let aCapture = try scopedCommand(.capture(text: "A must not enter B", quadrant: .urgentImportant), scope: accountA)
        deliver(aCapture, to: wrong)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let rejectedA = wrong.store.tasks.isEmpty && !WatchAppliedLedger(defaults: wrong.defaults).contains(aCapture.id)
        let bCapture = try scopedCommand(.capture(text: "B valid control", quadrant: .urgentImportant), scope: wrong.scope)
        deliver(bCapture, to: wrong)
        let acceptedB = await waitFor { WatchAppliedLedger(defaults: wrong.defaults).contains(bCapture.id) }
        check("phone_rejects_other_account_capture", rejectedA && acceptedB
              && wrong.store.tasks.map(\.title) == ["B valid control"])

        let legacy = try ProbePhone(owner: accountA.identifier, dataset: dataset, directory: root.appendingPathComponent("phone-legacy"))
        defer { legacy.close() }
        let legacyCapture = try scopedCommand(.capture(text: "Unknown old owner", quadrant: .urgentImportant), scope: nil)
        deliver(legacyCapture, to: legacy)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        check("phone_rejects_unscoped_legacy_capture", legacy.store.tasks.isEmpty
              && !WatchAppliedLedger(defaults: legacy.defaults).contains(legacyCapture.id))

        let held = try ProbePhone(owner: accountA.identifier, dataset: dataset, directory: root.appendingPathComponent("phone-fetch"))
        defer { held.close() }
        let original = task().asTask
        held.store.tasks = [original]
        let read = ProbeReadHold()
        held.store.beforeFetch = { await read.wait() }
        let completeA = try scopedCommand(.complete(taskID: original.id), scope: accountA)
        deliver(completeA, to: held)
        let entered = await waitFor { read.entered }
        held.identity.value = accountB.identifier
        held.store.beforeFetch = nil
        read.release()
        try await _Concurrency.Task.sleep(for: .milliseconds(75))
        check("phone_revalidates_scope_after_suspended_fetch", entered
              && held.store.tasks == [original] && !WatchAppliedLedger(defaults: held.defaults).contains(completeA.id))

        WCSession.default.contexts = []
        let unresolved = try ProbePhone(owner: accountA.identifier, dataset: dataset, directory: root.appendingPathComponent("phone-unresolved"))
        defer { unresolved.close() }
        unresolved.store.tasks = [task().asTask]
        unresolved.phone.schedule()
        _ = await waitFor { latestSnapshot() != nil }
        let firstWasScoped = latestSnapshot().flatMap(wireScope) == accountA
        unresolved.identity.value = nil
        let blanked = await waitFor {
            guard let current = latestSnapshot() else { return false }
            return current.tasks.isEmpty && wireScope(current) == nil
        }
        check("phone_emits_empty_snapshot_during_unresolved_identity", firstWasScoped && blanked)

        let reset = try ProbePhone(owner: accountA.identifier, dataset: dataset, directory: root.appendingPathComponent("phone-reset"))
        defer { reset.close() }
        let beforeReset = try scopedCommand(.capture(text: "Queued before reset", quadrant: .urgentImportant), scope: reset.scope)
        try await reset.replaceDataset()
        deliver(beforeReset, to: reset)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let staleResetRejected = reset.store.tasks.isEmpty && !WatchAppliedLedger(defaults: reset.defaults).contains(beforeReset.id)
        let afterReset = try scopedCommand(.capture(text: "Created after reset", quadrant: .urgentImportant), scope: reset.scope)
        deliver(afterReset, to: reset)
        let afterAccepted = await waitFor { WatchAppliedLedger(defaults: reset.defaults).contains(afterReset.id) }
        check("phone_rejects_previous_dataset_capture", staleResetRejected && afterAccepted
              && reset.store.tasks.map(\.title) == ["Created after reset"])
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDWatchScope-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await watchChecks(root: root)
            try await phoneChecks(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("WATCH_SCOPE_ERROR " + String(describing: error))
            exit(2)
        }
    }
}
