@main struct WatchCaptureReplayProbe {
    @MainActor static var failures = 0
    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("WATCH_REPLAY_CHECK " + String(decoding: data, as: UTF8.self))
    }
    @MainActor static func waitFor(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    @MainActor static func replayCheck(root: URL, archive: Bool) async throws {
        let rig = try StoreRig(directory: root.appendingPathComponent(archive ? "archive" : "trash"))
        defer { rig.close() }
        _ = await waitFor { rig.store.hasLoadedTasks }
        let capture = WatchCommand(id: UUID().uuidString, issuedAt: .now,
            kind: .capture(text: "Capture later removed", quadrant: .urgentImportant), accountScope: rig.scope)
        rig.deliver(capture)
        let created = await waitFor { WatchAppliedLedger(defaults: rig.defaults).contains(capture.id) }
        guard created, let task = try await rig.store.fetchTask(id: "pending-" + capture.id) else {
            throw TaskStoreError.deleteNotRecorded
        }
        if archive { try await rig.store.archive(task) }
        else { try await rig.store.delete(task) }
        let terminalBefore: [ArchivedTask]
        if archive { terminalBefore = try await rig.store.archivedTasksStamped() }
        else { terminalBefore = try await rig.store.trashedTasks() }
        let queueBefore = try await rig.queue.all()

        // Exercise the actual bounded ledger, then reconstruct the coordinator as after relaunch.
        // The Watch retained the original capture because its acknowledgement was lost.
        var ledger = WatchAppliedLedger(defaults: rig.defaults)
        for _ in 0..<WatchAppliedLedger.capacity { ledger.record(UUID().uuidString) }
        let evicted = !ledger.contains(capture.id)
        #if WATCH_ACCOUNT_SCOPED
        let gate = rig.gate
        let relaunched = WatchSessionCoordinator(store: rig.store, enabled: true, mutationGate: gate,
            scopeProvider: {
                guard let dataset = gate.identity?.datasetID else { return nil }
                return .account(userID: "gate-fixture-owner", datasetID: dataset)
            }, defaults: rig.defaults, debounce: .zero)
        #else
        let relaunched = WatchSessionCoordinator(store: rig.store, enabled: true,
                                                  defaults: rig.defaults, debounce: .zero)
        #endif
        relaunched.start()
        relaunched.session(WCSession.default, didReceiveUserInfo: WatchWire.userInfo(for: capture)!)
        let acknowledged = await waitFor { WatchAppliedLedger(defaults: rig.defaults).contains(capture.id) }
        let live = try await rig.tasks.fetchAll()
        let queueAfter = try await rig.queue.all()
        let terminalAfter: [ArchivedTask]
        if archive { terminalAfter = try await rig.store.archivedTasksStamped() }
        else { terminalAfter = try await rig.store.trashedTasks() }
        check(archive ? "capture_replay_preserves_retained_archive_after_ledger_eviction"
                      : "capture_replay_preserves_retained_trash_after_ledger_eviction",
              evicted && acknowledged && live.isEmpty && queueAfter == queueBefore
              && terminalBefore.count == 1 && terminalBefore.first?.task.id == task.id
              && terminalAfter == terminalBefore)
    }
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDWatchCaptureReplay-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await replayCheck(root: root, archive: false)
            try await replayCheck(root: root, archive: true)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("WATCH_REPLAY_ERROR " + String(describing: error)); exit(2)
        }
    }
}
