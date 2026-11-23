import Foundation
import GRDB
import GSDModel

public protocol CloudLibraryRepository: Sendable {
    func capture(owner: String, now: Date) async throws -> [CloudLibraryChange]
    func apply(_ item: CloudLibraryItem, owner: String, stampedAt: Date) async throws
    func acknowledge(_ item: CloudLibraryItem, owner: String) async throws
}

private struct LibraryState: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cloudLibrarySync"
    var owner: String
    var kind: String
    var entityId: String
    var payload: String
    var version: String
    var deleted: Bool
    var pending: Bool
    var item: CloudLibraryItem {
        CloudLibraryItem(kind: kind, entityId: entityId, payload: payload,
                         clientUpdatedAt: version, deleted: deleted)
    }
}

/// Sync metadata only. User data continues to live in the original GRDB repositories.
public final class GRDBCloudLibraryRepository: CloudLibraryRepository {
    private let writer: any DatabaseWriter
    public init(_ database: AppDatabase) { writer = database.writer }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func capture(owner: String, now: Date) async throws -> [CloudLibraryChange] {
        try await writer.write { db in
            let previous = try LibraryState.filter(Column("owner") == owner).fetchAll(db)
            var current: [String: (String, String, String, Date)] = [:]
            for row in try ArchivedTaskRecord.fetchAll(db) {
                current["archive:" + row.id] = ("archive", row.id, try Self.encode(row.toDomain()), row.archivedAt)
            }
            for row in try DeletedTaskRecord.fetchAll(db) {
                current["trash:" + row.id] = ("trash", row.id, try Self.encode(row.toDomain()), row.deletedAt)
            }
            for row in try SmartViewRecord.fetchAll(db) {
                let view = try row.toDomain()
                let wire = SmartViewWire(id: view.id, name: view.name, icon: view.icon,
                                         criteria: view.criteria, createdAt: row.createdAt, updatedAt: row.updatedAt)
                current["view:" + row.id] = ("view", row.id, try Self.encode(wire), row.updatedAt)
            }
            let existing = Dictionary(uniqueKeysWithValues: previous.map { ($0.item.key, $0) })
            for (key, value) in current {
                let (kind, id, payload, modified) = value
                if let old = existing[key], !old.deleted, old.payload == payload { continue }
                let stamp = existing[key] == nil ? modified : max(now, modified)
                try LibraryState(owner: owner, kind: kind, entityId: id, payload: payload,
                                 version: Self.stamp(stamp), deleted: false, pending: true).save(db)
            }
            for var old in previous where !old.deleted && current[old.item.key] == nil {
                old.deleted = true; old.payload = ""; old.version = Self.stamp(now); old.pending = true
                try old.save(db)
            }
            return try LibraryState.filter(Column("owner") == owner).fetchAll(db).map {
                CloudLibraryChange(item: $0.item, pending: $0.pending)
            }
        }
    }

    /// Used after an explicit fresh-account local wipe. It prevents old local deletion
    /// metadata from being mistaken for edits to the account being opened.
    public func resetMetadata() async throws {
        _ = try await writer.write { db in try LibraryState.deleteAll(db) }
    }

    public func acknowledge(_ item: CloudLibraryItem, owner: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE cloudLibrarySync SET pending = 0
                WHERE owner = ? AND kind = ? AND entityId = ? AND version = ? AND payload = ? AND deleted = ?
                """, arguments: [owner, item.kind, item.entityId, item.clientUpdatedAt, item.payload, item.deleted])
        }
    }

    public func apply(_ item: CloudLibraryItem, owner: String, stampedAt: Date) async throws {
        try await writer.write { db in
            var normalized = item.payload
            if item.deleted {
                switch item.kind {
                case "archive": _ = try ArchivedTaskRecord.deleteOne(db, key: item.entityId)
                case "trash": _ = try DeletedTaskRecord.deleteOne(db, key: item.entityId)
                case "view": _ = try SmartViewRecord.deleteOne(db, key: item.entityId)
                default: return
                }
                normalized = ""
            } else if item.kind == "view" {
                let wire = try Self.decode(SmartViewWire.self, item.payload)
                guard wire.id == item.entityId else { throw LibraryError.identityMismatch }
                let view = SmartView(id: wire.id, name: wire.name, icon: wire.icon ?? "line.3.horizontal.decrease",
                                     criteria: wire.criteria, isBuiltIn: false)
                try SmartViewRecord(view, createdAt: wire.createdAt, updatedAt: wire.updatedAt).save(db)
                normalized = try Self.encode(wire)
            } else {
                let task = try Self.decode(GSDModel.Task.self, item.payload)
                guard task.id == item.entityId else { throw LibraryError.identityMismatch }
                if let live = try TaskRecord.fetchOne(db, key: item.entityId), live.updatedAt > stampedAt {
                    // A newer local edit will clear the older cloud tombstone on the next pass.
                    try LibraryState(owner: owner, kind: item.kind, entityId: item.entityId, payload: "",
                                     version: Self.stamp(live.updatedAt), deleted: true, pending: true).save(db)
                    return
                }
                if item.kind == "archive" {
                    try ArchivedTaskRecord(task, archivedAt: stampedAt).save(db)
                    _ = try DeletedTaskRecord.deleteOne(db, key: item.entityId)
                } else if item.kind == "trash" {
                    try DeletedTaskRecord(task, deletedAt: stampedAt).save(db)
                    _ = try ArchivedTaskRecord.deleteOne(db, key: item.entityId)
                } else { return }
                _ = try TaskRecord.deleteOne(db, key: item.entityId)
                _ = try SyncQueueRecord.writes(of: [item.entityId]).deleteAll(db)
                normalized = try Self.encode(task)
            }
            try LibraryState(owner: owner, kind: item.kind, entityId: item.entityId, payload: normalized,
                             version: item.clientUpdatedAt, deleted: item.deleted, pending: false).save(db)
        }
    }
    private enum LibraryError: Error { case identityMismatch }
}
