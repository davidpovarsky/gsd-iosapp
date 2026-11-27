import Foundation
import GSDModel

/// A queued local mutation awaiting push to PocketBase (§7.5). Persisted in the `syncQueue` table;
/// the 5c push engine drains the `.pending` items. `payload` is the full task for create/update,
/// and on a delete the task as archived, or nil for trash and import replace. Built in 5a; enqueue-on-mutation wiring lands in 5c.
public struct SyncQueueItem: Sendable, Identifiable, Equatable {
    public enum Operation: String, Codable, Sendable { case create, update, delete }
    public enum Status: String, Codable, Sendable { case pending, failed }

    public var id: String
    public var taskId: String
    public var operation: Operation
    public var timestamp: Int          // ms when queued
    public var retryCount: Int
    public var payload: Task?          // full task for create/update; on delete, the task as archived or nil
    public var status: Status
    public var lastError: String?
    public var lastAttemptAt: Int?     // ms
    public var failedAt: Int?          // ms
    /// A Share mutation's original server data set. Once bound, retries and later mutations
    /// for the same queued task must inherit it rather than selecting a newer generation.
    public var serverDatasetGeneration: String?

    public init(id: String, taskId: String, operation: Operation, timestamp: Int,
                retryCount: Int = 0, payload: Task? = nil, status: Status = .pending,
                lastError: String? = nil, lastAttemptAt: Int? = nil, failedAt: Int? = nil,
                serverDatasetGeneration: String? = nil) {
        self.id = id; self.taskId = taskId; self.operation = operation; self.timestamp = timestamp
        self.retryCount = retryCount; self.payload = payload; self.status = status
        self.lastError = lastError; self.lastAttemptAt = lastAttemptAt; self.failedAt = failedAt
        self.serverDatasetGeneration = serverDatasetGeneration
    }
}

public enum SyncQueueGenerationError: Error, LocalizedError, Equatable, Sendable {
    case invalidGeneration
    case conflictingGenerations

    public var errorDescription: String? {
        switch self {
        case .invalidGeneration:
            String(localized: "This task's cloud data could not be verified. Please try again.")
        case .conflictingGenerations:
            String(localized: "This task belongs to a different cloud data set. Keep it for review before retrying.")
        }
    }
}

extension SyncQueueItem {
    /// Pending and failed rows, including deletes, retain the first admitted generation.
    /// Compare opaque UTF-8 bytes: Unicode canonical equivalence is not authority equivalence.
    package static func resolvedServerDatasetGeneration(
        for taskID: String,
        in items: [SyncQueueItem],
        proposed: String? = nil
    ) throws -> String? {
        var resolved = proposed
        if let proposed { try validateServerDatasetGeneration(proposed) }
        for item in items where item.taskId == taskID {
            guard let generation = item.serverDatasetGeneration else { continue }
            try validateServerDatasetGeneration(generation)
            if let resolved, !resolved.utf8.elementsEqual(generation.utf8) {
                throw SyncQueueGenerationError.conflictingGenerations
            }
            resolved = generation
        }
        return resolved
    }

    private static func validateServerDatasetGeneration(_ generation: String) throws {
        guard !generation.isEmpty, generation.utf8.count <= 128,
              !generation.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            throw SyncQueueGenerationError.invalidGeneration
        }
    }
}
