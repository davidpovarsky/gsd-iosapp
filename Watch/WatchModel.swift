import Foundation
import Observation
import WatchConnectivity
import WidgetKit
import GSDModel
import GSDSnapshot

/// The watch's thin client (spec 5). It holds the last snapshot from the iPhone and a queue of
/// commands for it. It never writes tasks: every change is a `WatchCommand` that `WatchOverlay`
/// shows on top of the snapshot until the iPhone reports it applied.
@MainActor @Observable
final class WatchModel: NSObject {
    /// Offered for 4 seconds after Complete (spec 6.4).
    struct UndoOffer: Equatable {
        let task: WatchTask
        let commandID: String
    }

    private(set) var snapshot: WatchSnapshot
    private(set) var outbox: WatchOutbox
    private(set) var undoOffer: UndoOffer?
    /// The task a tapped reminder asked to show (spec 4.4); the list scrolls to it.
    private(set) var openedTaskID: String?
    /// Set when a widget tap or the Capture control asked for Capture; the home screen shows it.
    var captureRequested = false

    /// One model for the app, its notification delegate, and the notification scene.
    static let shared = WatchModel()

    private let snapshotStore: WatchSnapshotStore
    /// Each unsent command is offered again at most once per activation (WATCH-REVIEW-FIX).
    private var resendLedger = WatchResendLedger()
    private var undoExpiry: _Concurrency.Task<Void, Never>?

    override init() {
        let directory = Self.storageDirectory()
        snapshotStore = WatchSnapshotStore(directoryURL: directory)
        outbox = WatchOutbox(directoryURL: directory)
        snapshot = snapshotStore.read() ?? .empty
        super.init()
    }

    /// The App Group container, else Application Support, created first because the outbox
    /// writes into it and the system doesn't make that directory.
    private static func storageDirectory() -> URL? {
        let files = FileManager.default
        if let group = files.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) { return group }
        guard let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// What to draw now: the snapshot with the unacknowledged commands on top.
    func lists(now: Date = .now) -> WatchLists {
        WatchOverlay.apply(snapshot, pending: outbox.commands, now: now,
                           calendar: .current, timeZone: .current)
    }

    /// Today's picks, or the first suggestions when there are none, with pending commands applied.
    func today(now: Date = .now) -> WatchToday {
        WatchOverlay.today(snapshot, pending: outbox.commands, now: now, timeZone: .current)
    }

    var hasSnapshot: Bool { snapshot.generatedAt != WatchSnapshot.empty.generatedAt }

    // MARK: Commands

    func complete(_ task: WatchTask) {
        // No Undo for a command that never queued: there is nothing to take back.
        guard let command = queue(.complete(taskID: task.id), sendImmediately: false) else { return }
        // WatchConnectivity can deliver a transfer after its local entry is removed.
        // Keep this completion local while Undo is visible; release the previous offer.
        releasePendingCompletion()
        undoOffer = UndoOffer(task: task, commandID: command.id)
        undoExpiry = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(4))
            if !_Concurrency.Task.isCancelled { self?.releasePendingCompletion() }
        }
    }

    func open(taskID: String) { openedTaskID = taskID }

    /// Called once the list has scrolled, so a second tap on the same task scrolls again.
    func consumeOpenedTask() { openedTaskID = nil }

    /// The Capture control's intent leaves a flag in the App Group; take it when the app is up.
    func consumeCaptureRequest() {
        guard let defaults = UserDefaults(suiteName: AppGroup.id) else { return }
        if WatchCaptureRequest.consume(from: defaults) { captureRequested = true }
    }

    /// A tapped widget opens the app with a `gsd://` URL.
    func open(url: URL) {
        if DeepLinkParser.route(from: url) == .capture { captureRequested = true }
    }

    func addToToday(_ task: WatchTask) { queue(.addToToday(taskID: task.id)) }

    func removeFromToday(_ task: WatchTask) { queue(.removeFromToday(taskID: task.id)) }

    func markUrgent(_ task: WatchTask) { queue(.markUrgent(taskID: task.id)) }

    @discardableResult
    func capture(text: String, quadrant: Quadrant) -> Bool {
        queue(.capture(text: text, quadrant: quadrant)) != nil
    }

    /// End the four-second Undo window before suspension, on expiry, or when another
    /// completion replaces it. The durable command keeps its original id across relaunch.
    func releasePendingCompletion() {
        let commandID = undoOffer?.commandID
        undoOffer = nil
        undoExpiry?.cancel()
        undoExpiry = nil
        guard let command = outbox.commands.first(where: { $0.id == commandID }) else { return }
        send(command)
    }

    /// Removes the queued `complete` if it never left, otherwise queues a `reopen`.
    func undo() {
        guard let offer = undoOffer else { return }
        switch WatchOverlay.undoComplete(commandID: offer.commandID, of: offer.task, outbox: outbox.commands) {
        case .removeFromOutbox(let id):
            var pending = outbox
            do { try pending.remove(id: id) } catch { return }
            outbox = pending
        case .queueReopen(let taskID):
            guard queue(.reopen(taskID: taskID)) != nil else { return }
        case .unavailable:
            return
        }
        // A failed write keeps both the durable command and the Undo offer available.
        undoOffer = nil
        undoExpiry?.cancel()
        undoExpiry = nil
    }

    /// Whether the offer can still be undone: a repeating task whose `complete` left has no Undo.
    var canUndo: Bool {
        guard let offer = undoOffer else { return false }
        return WatchOverlay.undoComplete(commandID: offer.commandID, of: offer.task,
                                         outbox: outbox.commands) != .unavailable
    }

    @discardableResult
    func queue(_ kind: WatchCommand.Kind, sendImmediately: Bool = true) -> WatchCommand? {
        let command = WatchCommand(id: UUID().uuidString, issuedAt: .now, kind: kind)
        // WatchOutbox mutates before it writes. Publish only a durable queue so a failed
        // save cannot appear as a pending task or be sent later during reactivation.
        var pending = outbox
        do { try pending.add(command) } catch { return nil }
        outbox = pending
        if sendImmediately {
            // A later action may depend on the completed task (for example, a freed Today slot).
            // Hand off the earlier completion first, ending its Undo offer.
            releasePendingCompletion()
            send(command)
        }
        return command
    }

    /// Only a capture still awaiting acknowledgement blocks its dependent actions.
    /// Canonical tasks retain this opaque id, so a prefix by itself is not a pending-state flag.
    private var awaitingCaptureTaskIDs: Set<String> {
        let acknowledged = Set(snapshot.appliedCommandIDs)
        return Set(outbox.commands.compactMap { command in
            guard case .capture = command.kind, !acknowledged.contains(command.id) else { return nil }
            return "pending-\(command.id)"
        })
    }

    private func send(_ command: WatchCommand) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        if let taskID = command.taskID, awaitingCaptureTaskIDs.contains(taskID) { return }
        if let payload = WatchWire.userInfo(for: command) { WCSession.default.transferUserInfo(payload) }
    }

    /// Hands the session every unacknowledged command it isn't already carrying. The phone
    /// leaves an id unrecorded when its store errors, so the watch has to offer it again; a
    /// repeat is safe because the phone skips ids it has applied.
    private func resendUnsent() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let inFlight = Set(WCSession.default.outstandingUserInfoTransfers
            .compactMap { WatchWire.command(from: $0.userInfo)?.id })
        // Activation must not hand off a completion whose Undo window is still open.
        let held = Set(undoOffer.map { [$0.commandID] } ?? [])
        // Do not consume the once-per-activation resend slot while a capture prerequisite is
        // unresolved; its acknowledgement will release the same durable dependent command.
        let awaiting = awaitingCaptureTaskIDs
        let blocked = Set(outbox.commands.filter { command in
            command.taskID.map { awaiting.contains($0) } ?? false
        }.map(\.id))
        resendLedger.take(from: outbox, excluding: inFlight.union(held).union(blocked)).forEach(send)
    }

    // MARK: Snapshot from the iPhone

    fileprivate func receive(_ snapshot: WatchSnapshot, resendPending: Bool = true) {
        guard snapshot.generatedAt >= self.snapshot.generatedAt else { return }   // a late, older context
        self.snapshot = snapshot
        try? snapshotStore.write(snapshot)
        try? outbox.drop(acknowledged: Set(snapshot.appliedCommandIDs))
        WidgetCenter.shared.reloadAllTimelines()
        if resendPending { resendUnsent() }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // A context that arrived while the app wasn't running is waiting here.
        let snapshot = Self.decode(session.receivedApplicationContext)
        _Concurrency.Task { @MainActor in
            if let snapshot { self.receive(snapshot, resendPending: false) }
            self.resendLedger.startActivation()
            self.resendUnsent()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                             error: Error?) {
        guard error != nil else { return }
        _Concurrency.Task { @MainActor in self.resendUnsent() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = Self.decode(applicationContext) else { return }
        _Concurrency.Task { @MainActor in self.receive(snapshot) }
    }

    private nonisolated static func decode(_ context: [String: Any]) -> WatchSnapshot? {
        guard let data = context[WatchWire.snapshotKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}
