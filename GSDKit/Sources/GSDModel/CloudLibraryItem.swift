import Foundation

/// The existing archive, trash and custom-view stores use the same account sync lifecycle.
public struct CloudLibraryItem: Codable, Equatable, Sendable {
    public var kind: String
    public var entityId: String
    public var payload: String
    public var clientUpdatedAt: String
    public var deleted: Bool
    public var owner: String?

    public init(kind: String, entityId: String, payload: String, clientUpdatedAt: String,
                deleted: Bool, owner: String? = nil) {
        self.kind = kind; self.entityId = entityId; self.payload = payload
        self.clientUpdatedAt = clientUpdatedAt; self.deleted = deleted; self.owner = owner
    }
    public var key: String { kind + ":" + entityId }
    enum CodingKeys: String, CodingKey {
        case kind, payload, deleted, owner
        case entityId = "entity_id"
        case clientUpdatedAt = "client_updated_at"
    }
}

public struct CloudLibraryChange: Sendable {
    public var item: CloudLibraryItem
    public var pending: Bool
    public init(item: CloudLibraryItem, pending: Bool) { self.item = item; self.pending = pending }
}
