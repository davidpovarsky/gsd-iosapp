import Foundation
import Observation
import UIKit
import WatchConnectivity
import GSDModel
import GSDStore
import GSDSnapshot

/// The iPhone end of the watch link (spec 6.2 and 6.3). It sends the latest `WatchSnapshot` with
/// `updateApplicationContext` and applies the commands the watch queues with `transferUserInfo`,
/// through the same `TaskStore` paths the iPhone UI uses. The decisions are the tested
/// `WatchCommandPlan`; this type is the glue. It does nothing where `WCSession` is unsupported
/// (Mac Catalyst, iPad without a pairing) or when `enabled` is false (the isolated harness).
@MainActor
final class WatchSessionCoordinator: NSObject {
    /// The key both ends use in the application context dictionary.
    nonisolated static let snapshotKey = WatchWire.snapshotKey

    private let store: TaskStore
    private let mutationGate: WatchMutationGate
    private let scopeProvider: @MainActor () -> WatchAccountScope?
    private let scopeDidChange: @MainActor () -> Void
    private var observedScope: WatchAccountScope?
    private var scopeGeneration: UInt64 = 0
    private var scopeIsStable = false
    /// A command can land while the phone app is backgrounded and its database suspended. Mac
    /// Catalyst never suspends, and a Mac app is routinely `.inactive` with its window live.
    private let databaseWindow = BackgroundDatabaseWindow(isBackgrounded: {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIApplication.shared.applicationState != .active
        #endif
    })
    private let defaults: UserDefaults
    private let enabled: Bool
    private let now: () -> Date
    private let debounce: Duration
    private var ledger: WatchAppliedLedger
    private var debounceTask: _Concurrency.Task<Void, Never>?
    private var commandLoop: _Concurrency.Task<Void, Never>?
    private var lastSent: WatchSnapshot?

    /// Commands arrive on a WatchConnectivity queue. One stream, one consumer, so they apply in
    /// the order the watch sent them even though each apply awaits the database.
    private nonisolated let commands: AsyncStream<WatchCommand>
    private nonisolated let commandSink: AsyncStream<WatchCommand>.Continuation

    init(store: TaskStore, enabled: Bool, mutationGate: WatchMutationGate,
         scopeProvider: @escaping @MainActor () -> WatchAccountScope?,
         scopeDidChange: @escaping @MainActor () -> Void = {},
         defaults: UserDefaults = AppGroupDefaults.shared,
         now: @escaping () -> Date = { Date() },
         debounce: Duration = .seconds(1)) {
        self.store = store
        self.mutationGate = mutationGate
        self.scopeProvider = scopeProvider
        self.scopeDidChange = scopeDidChange
        self.enabled = enabled
        self.defaults = defaults
        self.now = now
        self.debounce = debounce
        self.ledger = WatchAppliedLedger(defaults: defaults)
        (self.commands, self.commandSink) = AsyncStream.makeStream(of: WatchCommand.self)
        super.init()
        observeAccountScope()
    }

    private func readScope() -> WatchAccountScope? {
        guard !mutationGate.isPaused, let dataset = mutationGate.identity?.datasetID,
              let scope = scopeProvider(), scope.isValid, scope.datasetID == dataset else { return nil }
        return scope
    }

    private var currentScope: WatchAccountScope? {
        guard scopeIsStable, let scope = readScope(), scope == observedScope else { return nil }
        return scope
    }

    /// Observation fires in willSet. Invalidate synchronously, before the deferred reread, so
    /// A → unresolved → A cannot revive a command already waiting on an old database read.
    private func observeAccountScope() {
        observedScope = withObservationTracking {
            readScope()
        } onChange: { [weak self] in
            // Every observed input belongs to a MainActor app/session object.
            MainActor.assumeIsolated { self?.invalidateAccountScope() }
        }
        scopeIsStable = true
    }

    private func invalidateAccountScope() {
        scopeGeneration &+= 1
        scopeIsStable = false
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            self.observeAccountScope()
            self.scopeDidChange()
            self.lastSent = nil
            self.schedule()
        }
    }

    private func isCurrent(_ scope: WatchAccountScope, generation: UInt64) -> Bool {
        !_Concurrency.Task.isCancelled && generation == scopeGeneration && currentScope == scope
    }

    private var session: WCSession? {
        enabled && WCSession.isSupported() ? WCSession.default : nil
    }

    func start() {
        guard let session, commandLoop == nil else { return }
        session.delegate = self
        session.activate()
        commandLoop = _Concurrency.Task { [weak self, commands] in
            for await command in commands { await self?.apply(command) }
        }
    }

    /// Coalesce a burst of task changes into one send.
    func schedule() {
        guard session != nil else { return }
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: self.debounce)
            if _Concurrency.Task.isCancelled { return }
            await self.sendSnapshot()
        }
    }

    // MARK: Phone to watch

    private func sendSnapshot() async {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        guard let scope = currentScope else {
            // Clear the previous account immediately; no database access is needed while
            // identity is unresolved or a destructive transition is draining old work.
            publish(WatchSnapshot(generatedAt: now(), escalationWindowDays: nil, tasks: [],
                                  doFirstTotal: 0, appliedCommandIDs: []), through: session)
            return
        }
        guard store.hasLoadedTasks, let ticket = mutationGate.admit() else { return }
        let generation = scopeGeneration
        defer { mutationGate.finish(ticket) }
        await databaseWindow.run {
            guard isCurrent(scope, generation: generation) else { return }
            let rows: [Task]
            do { rows = try await store.fetchAllTasks() }
            catch { return } // keep the last valid snapshot until the canonical read succeeds
            guard isCurrent(scope, generation: generation) else { return }
            let window = EscalationWindow.load(from: defaults)
            var snapshot = WatchSnapshotBuilder.build(
                from: rows, now: now(), escalationWindowDays: window.days,
                appliedCommandIDs: ledger.snapshotIDs)
            snapshot.accountScope = scope
            publish(snapshot, through: session)
        }
    }

    private func publish(_ snapshot: WatchSnapshot, through session: WCSession) {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        // generatedAt changes every build, so compare the payload with it held fixed.
        var stable = snapshot; stable.generatedAt = .distantPast
        // Codable key order is not a content fingerprint. Compare the value itself.
        guard stable != lastSent else { return }
        do {
            try session.updateApplicationContext([Self.snapshotKey: data])
            lastSent = stable
        } catch {
            // Not paired or not reachable right now; the next task change sends again.
        }
    }

    // MARK: Watch to phone

    private func apply(_ command: WatchCommand) async {
        guard let scope = currentScope, command.accountScope == scope,
              let ticket = mutationGate.admit() else {
            schedule()   // return the current identity; keep an unaccepted command unacknowledged
            return
        }
        let generation = scopeGeneration
        defer { mutationGate.finish(ticket) }
        await databaseWindow.run {
            guard isCurrent(scope, generation: generation) else { return }
            await applyWithDatabase(command, scope: scope, generation: generation)
        }
    }

    private func applyWithDatabase(_ command: WatchCommand, scope: WatchAccountScope,
                                   generation: UInt64) async {
        let task: Task?
        do { task = try await store.fetchTask(id: command.taskID ?? "pending-\(command.id)") }
        catch { return }   // database unavailable: leave the id unrecorded so a retry can apply it
        guard isCurrent(scope, generation: generation) else { return }
        // A lost capture acknowledgement may outlive the bounded command ledger. Retained
        // Trash/archive records prove that this exact stable ID already existed and the user
        // subsequently removed it. Never recreate it or guess from a title/prefix alone.
        if case .capture = command.kind, task == nil {
            let stableID = "pending-\(command.id)"
            do {
                let trash = try await store.trashedTasks()
                guard isCurrent(scope, generation: generation) else { return }
                if trash.contains(where: { $0.task.id == stableID }) {
                    ledger.record(command.id)
                    schedule()
                    return
                }
                let archive = try await store.archivedTasksStamped()
                guard isCurrent(scope, generation: generation) else { return }
                if archive.contains(where: { $0.task.id == stableID }) {
                    ledger.record(command.id)
                    schedule()
                    return
                }
            } catch { return } // unavailable terminal history cannot prove the command applied
        }
        let now = Date(), zone = TimeZone.current
        // Read the rows fresh: `store.tasks` can lag behind a database that was just resumed.
        var nextRank: Int?
        if case .addToToday = command.kind {
            do { nextRank = TopThree.nextRank(try await store.fetchAllTasks(), now: now, timeZone: zone) }
            catch { return }
            guard isCurrent(scope, generation: generation) else { return }
        }
        guard isCurrent(scope, generation: generation) else { return }
        let decision = WatchCommandPlan.decide(
            command, task: task, alreadyApplied: ledger.contains(command.id),
            today: TopThree.localDate(now, timeZone: zone), nextRank: nextRank)
        // An older phone may have acknowledged a capture under an unrelated random task id.
        // Keep a later action recoverable instead of claiming an unresolved synthetic id applied.
        // Never guess by title: two real tasks can have identical text.
        if case .skip(.missingTask) = decision, let id = command.taskID,
           id.hasPrefix("pending-"), UUID(uuidString: String(id.dropFirst("pending-".count))) != nil {
            return
        }
        if case .apply(let action) = decision {
            do { try await perform(action, on: task, commandID: command.id) }
            catch where Self.isPermanentRefusal(error) {
                // The store will always refuse this command. Recording it lets the watch drop it.
            } catch { return }   // a store or database failure may clear; leave the id unrecorded
        }
        ledger.record(command.id)
        schedule()
    }

    private static func isPermanentRefusal(_ error: Error) -> Bool {
        error is TaskStoreError || error is ValidationError
    }

    private func perform(_ action: WatchCommandPlan.Action, on task: Task?, commandID: String) async throws {
        switch action {
        case .toggleComplete:
            if let task { try await store.toggleComplete(task) }
        case .move(let quadrant):
            if let task { try await store.move(task, to: quadrant) }
        case .snoozeOneHour:
            if let task { try await store.snooze(task, by: .oneHour) }
        case .capture(let text, let quadrant):
            // Match the optimistic row exactly, so later offline actions target the same task.
            // A replay after a lost acknowledgement must not overwrite subsequent edits.
            guard task == nil else { return }
            let parsed = WatchCommandPlan.parseCapture(text)
            let stamp = Date()
            try await store.create(Task(
                id: "pending-\(commandID)", title: parsed.title,
                description: parsed.descriptionAdditions.joined(separator: "\n"),
                urgent: quadrant.isUrgent, important: quadrant.isImportant,
                createdAt: stamp, updatedAt: stamp, tags: parsed.tags))
        case .pickForToday(let date, let rank):
            if let task { try await store.setFocus(id: task.id, date: date, rank: rank) }
        case .clearPick:
            if let task { try await store.setFocus(id: task.id, date: nil, rank: nil) }
        }
    }
}

extension WatchSessionCoordinator: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        _Concurrency.Task { @MainActor in
            // A newly active or installed watch needs the current payload even if tasks did not change.
            self.lastSent = nil
            self.schedule()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// A different watch was paired; activate again to follow it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        _Concurrency.Task { @MainActor in
            // A newly active or installed watch needs the current payload even if tasks did not change.
            self.lastSent = nil
            self.schedule()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = WatchWire.command(from: userInfo) else { return }
        commandSink.yield(command)
    }
}
