import Foundation
import GSDModel
import GSDSnapshot

/// Deliberately permits duplicate remote creates: safety must come from the controller,
/// without depending on a server uniqueness constraint or a successful first response.
@MainActor final class DirectTaskPush {
    enum Outcome { case pushed(String), failed(String) }
    private(set) var attempts: [GSDModel.Task] = []
    private(set) var remoteRecords: [GSDModel.Task] = []
    func attempt(_ task: GSDModel.Task) async -> Outcome {
        attempts.append(task)
        remoteRecords.append(task)
        return .pushed("record-\(remoteRecords.count)")
    }
}

@main struct ShareRetryProbe {
    @MainActor static var failures = 0
    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("SHARE_RETRY_CHECK " + String(decoding: data, as: UTF8.self))
    }

    @MainActor static func capture(_ title: String) -> SharedCapture {
        SharedCapture(title: title, urls: [], urgent: false, important: true,
                      tags: [], capturedAt: Date(timeIntervalSince1970: 100))
    }

    @MainActor static func checks(root: URL) async throws {
        let outbox = ShareOutboxStore(directoryURL: root)
        let push = DirectTaskPush()
        let controller = ShareViewController(outbox: outbox, push: push)
        let blocker = root.appendingPathComponent(ShareOutboxStore.directoryName)
        try Data("forced directory creation failure".utf8).write(to: blocker)
        var didThrow = false
        do { try await controller.saveAndPush(capture("Original")) }
        catch { didThrow = true }
        check("write_failure_is_reported_after_push", didThrow && push.remoteRecords.count == 1
              && outbox.pending().isEmpty)
        let originalID = push.remoteRecords.first?.id

        try FileManager.default.removeItem(at: blocker)
        try await controller.saveAndPush(capture("Edited after failure"))
        check("retry_does_not_repeat_remote_create", push.attempts.count == 1
              && push.remoteRecords.count == 1 && outbox.pending().count == 1)

        var created: [GSDModel.Task] = []
        var ingested: [GSDModel.Task] = []
        let inbox = ShareInbox(store: outbox, now: { Date(timeIntervalSince1970: 200) }, newID: { "unexpected-new-id" })
        await inbox.drain(create: { created.append($0) }, ingestPushed: { ingested.append($0) })
        check("retry_preserves_identity_and_edits_on_drain", created.count == 1 && ingested.isEmpty
              && created.first?.id == originalID && created.first?.title == "Edited after failure"
              && outbox.pending().isEmpty)

        let firstPush = DirectTaskPush()
        let freshController = ShareViewController(outbox: outbox, push: firstPush)
        try await freshController.saveAndPush(capture("First success"))
        created = []; ingested = []
        await inbox.drain(create: { created.append($0) }, ingestPushed: { ingested.append($0) })
        check("first_success_uses_pushed_ingest", created.isEmpty && ingested.count == 1
              && ingested.first?.id == firstPush.remoteRecords.first?.id
              && ingested.first?.createdAt == Date(timeIntervalSince1970: 100)
              && ingested.first?.id != originalID && outbox.pending().isEmpty)
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDShareRetry-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await checks(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("SHARE_RETRY_ERROR " + String(describing: error))
            exit(2)
        }
    }
}
