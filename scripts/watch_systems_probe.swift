import Foundation
import GSDModel
import GSDSnapshot

// Only the platform seams are doubled. Production queue, capture, snapshot,
// debounce and delegate implementations are compiled from their original files.
@MainActor var watchProbeDirectory: URL?

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
    var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] = []
    var receivedApplicationContext: [String: Any] = [:]
    var contexts: [[String: Any]] = []
    func activate() {}
    func transferUserInfo(_ payload: [String: Any]) {
        outstandingUserInfoTransfers.append(WCSessionUserInfoTransfer(payload))
    }
    func updateApplicationContext(_ context: [String: Any]) throws { contexts.append(context) }
}
struct WidgetCenter {
    static let shared = WidgetCenter()
    func reloadAllTimelines() {}
}
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
@MainActor struct BackgroundDatabaseWindow {
    init(isBackgrounded: @escaping () -> Bool) {}
    func run<T>(_ body: () async throws -> T) async rethrows -> T { try await body() }
}
enum TaskStoreError: Error { case unexpectedMutation }
enum HarnessLaunch {
    static let isIsolated = true
    static func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "GSDWatchProbe-" + UUID().uuidString)!
    }
}
enum StoreLocation { static let appGroupID = AppGroup.id }
@MainActor final class TaskStore {
    var tasks: [GSDModel.Task] = []
    var hasLoadedTasks = true
    func fetchTask(id: String) async throws -> GSDModel.Task? { nil }
    func fetchAllTasks() async throws -> [GSDModel.Task] { tasks }
    func toggleComplete(_ task: GSDModel.Task) async throws { throw TaskStoreError.unexpectedMutation }
    func move(_ task: GSDModel.Task, to: Quadrant) async throws { throw TaskStoreError.unexpectedMutation }
    enum Snooze { case oneHour }
    func snooze(_ task: GSDModel.Task, by: Snooze) async throws { throw TaskStoreError.unexpectedMutation }
    func add(_ capture: ParsedCapture, override quadrant: Quadrant) async throws { throw TaskStoreError.unexpectedMutation }
    func setFocus(id: String, date: String?, rank: Int?) async throws { throw TaskStoreError.unexpectedMutation }
}

@main struct WatchSystemsProbe {
    @MainActor static var failures = 0

    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("WATCH_SYSTEMS_CHECK " + String(decoding: data, as: UTF8.self))
    }

    @MainActor static func model(at directory: URL?) -> WatchModel {
        watchProbeDirectory = directory
        WCSession.default.outstandingUserInfoTransfers = []
        WCSession.default.activationState = .activated
        WCSession.default.receivedApplicationContext = [:]
        return WatchModel()
    }

    @MainActor static func watchTask(_ id: String, recurring: Bool = false) -> WatchTask {
        WatchTask(id: id, title: id, urgent: true, important: true,
                  createdAt: .now, updatedAt: .now, isRecurring: recurring)
    }

    @MainActor static func transferred() -> [WatchCommand] {
        WCSession.default.outstandingUserInfoTransfers.compactMap { WatchWire.command(from: $0.userInfo) }
    }

    @MainActor static func waitForTransfers(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if transferred().count >= count { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor static func undoChecks(root: URL) async throws {
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let session = WCSession.default
        let inactiveDirectory = try directory("inactive-capture")
        let inactive = model(at: inactiveDirectory)
        session.activationState = .inactive
        let captureAccepted = inactive.capture(text: "Wait for activation", quadrant: .urgentImportant)
        let remainedLocal = transferred().isEmpty && WatchOutbox(directoryURL: inactiveDirectory).commands.count == 1
        session.activationState = .activated
        inactive.session(session, activationDidCompleteWith: .activated, error: nil)
        let resumed = await waitForTransfers(1)
        check("inactive_capture_waits_for_activation", captureAccepted && remainedLocal && resumed
              && transferred().map(\.id) == inactive.outbox.commands.map(\.id))

        for recurring in [false, true] {
            let localDirectory = try directory(recurring ? "undo-recurring" : "undo-regular")
            let local = model(at: localDirectory)
            local.complete(watchTask("Undo locally", recurring: recurring))
            let held = transferred().isEmpty && local.canUndo
            local.undo()
            check(recurring ? "undo_recurring_stays_local" : "undo_nonrecurring_stays_local",
                  held && local.undoOffer == nil && local.outbox.commands.isEmpty
                  && WatchOutbox(directoryURL: localDirectory).commands.isEmpty && transferred().isEmpty)
        }

        let blockedDirectory = try directory("blocked-undo")
        let blocked = model(at: blockedDirectory)
        blocked.complete(watchTask("Preserve on failure"))
        let commandID = blocked.undoOffer?.commandID
        let path = blockedDirectory.appendingPathComponent(WatchOutbox.fileName)
        let saved = blockedDirectory.appendingPathComponent("preserved.json")
        try FileManager.default.moveItem(at: path, to: saved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        blocked.undo()
        let durable = try JSONDecoder().decode([WatchCommand].self, from: Data(contentsOf: saved))
        let retained = blocked.undoOffer?.commandID == commandID && commandID != nil
            && blocked.outbox.commands.map(\.id) == durable.map(\.id) && transferred().isEmpty
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: saved, to: path)
        blocked.undo()
        check("failed_undo_preserves_durable_queue", retained && blocked.outbox.commands.isEmpty
              && WatchOutbox(directoryURL: blockedDirectory).commands.isEmpty && transferred().isEmpty)

        let activated = model(at: try directory("activation-hold"))
        session.activationState = .inactive
        activated.complete(watchTask("Keep Undo during activation"))
        session.activationState = .activated
        activated.session(session, activationDidCompleteWith: .activated, error: nil)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let activationHeld = transferred().isEmpty && activated.canUndo
        activated.undo()
        check("activation_keeps_undo_command_local", activationHeld && transferred().isEmpty
              && activated.outbox.commands.isEmpty)

        let replaced = model(at: try directory("replace-offer"))
        replaced.complete(watchTask("first"))
        let firstID = replaced.undoOffer?.commandID
        replaced.complete(watchTask("second"))
        let secondID = replaced.undoOffer?.commandID
        let releasedFirst = firstID != nil && transferred().map(\.id) == [firstID!]
        replaced.undo()
        check("replacing_offer_releases_previous_completion", releasedFirst && secondID != firstID
              && replaced.outbox.commands.map(\.id) == [firstID!] && transferred().map(\.id) == [firstID!])

        let ordered = model(at: try directory("command-order"))
        ordered.complete(watchTask("Complete before next action"))
        let heldBeforeNextAction = transferred().isEmpty
        let acceptedNextAction = ordered.capture(text: "Next action", quadrant: .urgentImportant)
        check("following_action_releases_completion_first", heldBeforeNextAction && acceptedNextAction
              && ordered.undoOffer == nil && transferred().count == 2
              && transferred().map(\.id) == ordered.outbox.commands.map(\.id))

        let backgrounded = model(at: try directory("background-flush"))
        backgrounded.complete(watchTask("Leaving app"))
        let backgroundID = backgrounded.undoOffer?.commandID
        let heldBeforeBackground = transferred().isEmpty
        changeScenePhase(.inactive, model: backgrounded)
        changeScenePhase(.background, model: backgrounded)
        check("background_releases_pending_completion", heldBeforeBackground && backgroundID != nil
              && backgrounded.undoOffer == nil && transferred().map(\.id) == [backgroundID!]
              && backgrounded.outbox.commands.map(\.id) == [backgroundID!])

        let restartDirectory = try directory("restart")
        var terminated: WatchModel? = model(at: restartDirectory)
        terminated!.complete(watchTask("Survive termination"))
        let originalID = terminated!.undoOffer?.commandID
        let heldBeforeTermination = transferred().isEmpty
        terminated = nil
        let relaunched = model(at: restartDirectory)
        relaunched.session(session, activationDidCompleteWith: .activated, error: nil)
        let sentAfterRestart = await waitForTransfers(1)
        check("relaunch_resends_original_command_id", heldBeforeTermination && sentAfterRestart
              && originalID != nil && transferred().map(\.id) == [originalID!]
              && relaunched.outbox.commands.map(\.id) == [originalID!])

        let expired = model(at: try directory("expiry"))
        expired.complete(watchTask("Commit after Undo"))
        let expiredID = expired.undoOffer?.commandID
        let heldBeforeExpiry = transferred().isEmpty
        try await _Concurrency.Task.sleep(for: .milliseconds(4100))
        let sentAfterExpiry = await waitForTransfers(1)
        check("completion_released_after_undo_window", heldBeforeExpiry && sentAfterExpiry
              && expiredID != nil && expired.undoOffer == nil && transferred().map(\.id) == [expiredID!]
              && expired.outbox.commands.map(\.id) == [expiredID!])
    }

    @MainActor static func queueChecks(root: URL) throws {
        let absent = model(at: nil)
        let absentResult = absent.queue(.capture(text: "No container", quadrant: .urgentImportant))
        check("no_container_keeps_outbox_empty", absentResult == nil && absent.outbox.commands.isEmpty
              && WCSession.default.outstandingUserInfoTransfers.isEmpty)

        let retainedDirectory = root.appendingPathComponent("retained")
        try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
        let retained = model(at: retainedDirectory)
        let first = retained.queue(.capture(text: "Retained", quadrant: .urgentImportant))
        let file = retainedDirectory.appendingPathComponent(WatchOutbox.fileName)
        let preserved = retainedDirectory.appendingPathComponent("previous-outbox.json")
        try FileManager.default.moveItem(at: file, to: preserved)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let rejected = retained.queue(.capture(text: "Must not appear", quadrant: .urgentImportant))
        let original = try JSONDecoder().decode([WatchCommand].self, from: Data(contentsOf: preserved))
        check("failed_write_preserves_existing_queue", first != nil && rejected == nil
              && retained.outbox.commands.map(\.id) == original.map(\.id)
              && WCSession.default.outstandingUserInfoTransfers.count == 1)

        let successfulDirectory = root.appendingPathComponent("successful")
        try FileManager.default.createDirectory(at: successfulDirectory, withIntermediateDirectories: true)
        let successful = model(at: successfulDirectory)
        let success: Any = successful.capture(text: "Durable capture", quadrant: .notUrgentImportant)
        let reloaded = WatchOutbox(directoryURL: successfulDirectory)
        check("capture_success_is_durable", (success as? Bool) == true && reloaded.commands.count == 1
              && reloaded.commands.map(\.id) == successful.outbox.commands.map(\.id)
              && WCSession.default.outstandingUserInfoTransfers.count == 1)

        let failed = model(at: nil)
        let failure: Any = failed.capture(text: "Keep this draft", quadrant: .urgentImportant)
        check("capture_failure_is_reported", (failure as? Bool) == false && failed.outbox.commands.isEmpty
              && WCSession.default.outstandingUserInfoTransfers.isEmpty)
    }

    @MainActor static func waitForContexts(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if WCSession.default.contexts.count >= count { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor static func sessionChecks() async throws {
        let suite = "GSDWatchProbe-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = WCSession.default
        session.contexts = []
        let coordinator = WatchSessionCoordinator(store: TaskStore(), enabled: true,
            defaults: defaults, now: { Date(timeIntervalSince1970: 100) }, debounce: .zero)
        coordinator.start()
        coordinator.schedule()
        let initial = await waitForContexts(1)
        coordinator.schedule()
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let firstData = session.contexts.first?[WatchWire.snapshotKey] as? Data
        let snapshot = firstData.flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
        print("WATCH_SYSTEMS_DIAGNOSTIC initial=\(initial) contexts=\(session.contexts.count) generatedAt=\(snapshot?.generatedAt.timeIntervalSince1970 ?? -1)")
        check("unchanged_snapshot_is_coalesced", initial && session.contexts.count == 1
              && snapshot?.generatedAt == Date(timeIntervalSince1970: 100))

        let priorActivation = session.contexts.count
        coordinator.session(session, activationDidCompleteWith: .activated, error: nil)
        let activated = await waitForContexts(priorActivation + 1)
        print("WATCH_SYSTEMS_DIAGNOSTIC activationBefore=\(priorActivation) activationAfter=\(session.contexts.count)")
        check("activation_resends_current_snapshot", activated && session.contexts.count == priorActivation + 1)

        let priorReinstall = session.contexts.count
        session.isWatchAppInstalled = false
        coordinator.sessionWatchStateDidChange(session)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let uninstalledDidNotSend = session.contexts.count == priorReinstall
        session.isWatchAppInstalled = true
        coordinator.sessionWatchStateDidChange(session)
        let reinstalled = await waitForContexts(priorReinstall + 1)
        print("WATCH_SYSTEMS_DIAGNOSTIC reinstallBefore=\(priorReinstall) reinstallAfter=\(session.contexts.count) uninstalledDidNotSend=\(uninstalledDidNotSend)")
        check("watch_reinstall_resends_current_snapshot", uninstalledDidNotSend && reinstalled
              && session.contexts.count == priorReinstall + 1)
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDWatchProbe-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try queueChecks(root: root)
            try await sessionChecks()
            try await undoChecks(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("WATCH_SYSTEMS_ERROR " + String(describing: error))
            exit(2)
        }
    }
}
