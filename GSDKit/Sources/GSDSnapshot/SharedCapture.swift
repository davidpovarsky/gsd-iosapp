import Foundation
import GSDModel

/// The cross-process payload the Share Extension writes and the app ingests (spec §3, §4.1).
/// Raw user input — `urls`/`title`/`tags` are sanitized, clamped, and normalized on ingest by
/// `SharedCaptureBuilder`, never here.
public struct SharedCapture: Codable, Sendable, Equatable {
    public var title: String          // user-edited; clamped on ingest
    public var urls: [String]         // raw shared URLs; sanitized on ingest
    public var urgent: Bool
    public var important: Bool
    public var tags: [String]         // split from the comma field; normalized on ingest
    public var capturedAt: Date
    /// The `Task.id` the extension chose before trying to push (nil on files from older builds).
    /// The app materializes under this id, so a push that timed out but still landed resolves
    /// to an update of the server copy on the next sync, never a duplicate.
    public var taskID: String?
    /// Set when the extension's direct push succeeded: the PocketBase record id. The app then
    /// lands the task locally WITHOUT enqueueing a sync item (`ShareInbox` → `ingestPushed`).
    public var remoteRecordID: String?
    /// Immutable account/dataset origin chosen by the extension sheet. Older captures decode nil.
    /// Nil, mismatched and unresolved origins stay in the outbox for explicit review.
    public var origin: WatchAccountScope?
    /// Set only when a retry changes the sheet's original authored payload after a failed save.
    /// If that identity already exists, a distinct retry stays available for explicit review.
    public var isEditedRetry: Bool?
    /// The server authority discovered for this capture before direct POST. It never advances
    /// during retry/recovery. Missing bindings on account captures require explicit review.
    public var serverDatasetGeneration: String?

    public init(title: String, urls: [String], urgent: Bool, important: Bool,
                tags: [String], capturedAt: Date,
                taskID: String? = nil, remoteRecordID: String? = nil,
                origin: WatchAccountScope? = nil, isEditedRetry: Bool? = nil,
                serverDatasetGeneration: String? = nil) {
        self.title = title
        self.urls = urls
        self.urgent = urgent
        self.important = important
        self.tags = tags
        self.capturedAt = capturedAt
        self.taskID = taskID
        self.remoteRecordID = remoteRecordID
        self.origin = origin
        self.isEditedRetry = isEditedRetry
        self.serverDatasetGeneration = serverDatasetGeneration
    }

    /// The task under `taskID` with `capturedAt` as both timestamps — what the extension pushes,
    /// and (when `remoteRecordID` is set) what the app must land. Deterministic on purpose: the
    /// local copy must match the server copy so last-write-wins treats them as the same write.
    public func pushedTask() -> Task? {
        guard let taskID else { return nil }
        return SharedCaptureBuilder.task(from: self, id: taskID, now: capturedAt)
    }
}
