import Foundation
import GSDModel
import GSDSnapshot

// Explicit synthetic verified-account prerequisite for the unchanged original27 checks.
// These adapters exist only in the isolated probe target. Shipping UI must retain its origin.
let watchFixtureInstallation = "11111111-1111-4111-8111-111111111111"
let watchFixtureDataset = "22222222-2222-4222-8222-222222222222"
let watchFixtureScope = WatchAccountScope.guest(
    installationID: watchFixtureInstallation, datasetID: watchFixtureDataset)
let watchFixtureInitialSnapshot = WatchSnapshot(
    generatedAt: .distantPast, escalationWindowDays: nil, tasks: [], doFirstTotal: 0,
    appliedCommandIDs: [], accountScope: watchFixtureScope)

extension WatchCommand {
    init(id: String, issuedAt: Date, kind: Kind) {
        self.init(id: id, issuedAt: issuedAt, kind: kind, accountScope: watchFixtureScope)
    }
}
extension WatchSnapshot {
    init(version: Int = WatchSnapshot.currentVersion, generatedAt: Date,
         escalationWindowDays: Int?, tasks: [WatchTask], doFirstTotal: Int,
         appliedCommandIDs: [String]) {
        self.init(version: version, generatedAt: generatedAt, escalationWindowDays: escalationWindowDays,
                  tasks: tasks, doFirstTotal: doFirstTotal, appliedCommandIDs: appliedCommandIDs,
                  accountScope: watchFixtureScope)
    }
}
@MainActor extension WatchModel {
    func queue(_ kind: WatchCommand.Kind, sendImmediately: Bool = true) -> WatchCommand? {
        queue(kind, origin: actionLease, sendImmediately: sendImmediately)
    }
    func capture(text: String, quadrant: Quadrant) -> Bool {
        capture(text: text, quadrant: quadrant, origin: actionLease)
    }
    func complete(_ task: WatchTask) { complete(task, origin: actionLease) }
    func addToToday(_ task: WatchTask) { addToToday(task, origin: actionLease) }
    func removeFromToday(_ task: WatchTask) { removeFromToday(task, origin: actionLease) }
    func markUrgent(_ task: WatchTask) { markUrgent(task, origin: actionLease) }
    func undo() { undo(origin: actionLease) }
}
@MainActor extension WatchSessionCoordinator {
    convenience init(store: TaskStore, enabled: Bool,
                     defaults: UserDefaults = AppGroupDefaults.shared,
                     now: @escaping () -> Date = { Date() },
                     debounce: Duration = .seconds(1)) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GSDWatchFixtureGate-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = WatchMutationGate.Identity(
            installationID: watchFixtureInstallation, datasetID: watchFixtureDataset)
        try! JSONEncoder().encode(identity).write(to: directory.appendingPathComponent("watch-dataset-identity.json"))
        let gate = WatchMutationGate(directory: directory)
        self.init(store: store, enabled: enabled, mutationGate: gate,
                  scopeProvider: { watchFixtureScope }, defaults: defaults, now: now, debounce: debounce)
    }
}
