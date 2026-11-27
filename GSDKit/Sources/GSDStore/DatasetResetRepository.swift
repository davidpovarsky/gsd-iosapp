import Foundation
import GRDB

public enum DatasetResetJournalError: Error, Equatable {
    case invalidRequest
    case invalidAcknowledgement
    case conflictingRequest
    case conflictingAcknowledgement
    case acknowledgementRequired
    case corruptRecord
}

/// No credential or task content is stored here. The immutable request survives a lost reply.
public struct DatasetResetRequest: Codable, Equatable, Sendable {
    public let baseURL: String
    public let owner: String
    public let expectedGeneration: String
    public let requestID: String
    public private(set) var acknowledgement: DatasetResetAcknowledgement?

    public init(baseURL: String, owner: String, expectedGeneration: String, requestID: String) throws {
        guard !baseURL.isEmpty, validDatasetIdentifier(owner),
              validDatasetIdentifier(expectedGeneration), validDatasetIdentifier(requestID) else {
            throw DatasetResetJournalError.invalidRequest
        }
        self.baseURL = baseURL
        self.owner = owner
        self.expectedGeneration = expectedGeneration
        self.requestID = requestID
        acknowledgement = nil
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, owner, expectedGeneration, requestID, acknowledgement
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(baseURL: values.decode(String.self, forKey: .baseURL),
                      owner: values.decode(String.self, forKey: .owner),
                      expectedGeneration: values.decode(String.self, forKey: .expectedGeneration),
                      requestID: values.decode(String.self, forKey: .requestID))
        if let receipt = try values.decodeIfPresent(DatasetResetAcknowledgement.self, forKey: .acknowledgement) {
            self = try accepting(receipt)
        }
    }

    func validated() throws -> Self {
        _ = try Self(baseURL: baseURL, owner: owner, expectedGeneration: expectedGeneration, requestID: requestID)
        if let acknowledgement { _ = try accepting(acknowledgement) }
        return self
    }

    func matchesIdentity(_ other: Self) -> Bool {
        baseURL.utf8.elementsEqual(other.baseURL.utf8) && owner.utf8.elementsEqual(other.owner.utf8)
            && expectedGeneration.utf8.elementsEqual(other.expectedGeneration.utf8)
            && requestID.utf8.elementsEqual(other.requestID.utf8)
    }

    func accepting(_ receipt: DatasetResetAcknowledgement) throws -> Self {
        _ = try receipt.validated()
        guard !receipt.generation.utf8.elementsEqual(expectedGeneration.utf8) else {
            throw DatasetResetJournalError.invalidAcknowledgement
        }
        if let acknowledgement {
            guard acknowledgement.exactlyMatches(receipt) else {
                throw DatasetResetJournalError.conflictingAcknowledgement
            }
        }
        var copy = self
        copy.acknowledgement = receipt
        return copy
    }
}

public struct DatasetResetAcknowledgement: Codable, Equatable, Sendable {
    public let generation: String
    public let deletedTasks: Int
    public let tombstonedLibrary: Int

    public init(generation: String, deletedTasks: Int, tombstonedLibrary: Int) throws {
        guard validDatasetIdentifier(generation), deletedTasks >= 0, tombstonedLibrary >= 0,
              !deletedTasks.addingReportingOverflow(tombstonedLibrary).overflow else {
            throw DatasetResetJournalError.invalidAcknowledgement
        }
        self.generation = generation
        self.deletedTasks = deletedTasks
        self.tombstonedLibrary = tombstonedLibrary
    }

    private enum CodingKeys: String, CodingKey { case generation, deletedTasks, tombstonedLibrary }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(generation: values.decode(String.self, forKey: .generation),
                      deletedTasks: values.decode(Int.self, forKey: .deletedTasks),
                      tombstonedLibrary: values.decode(Int.self, forKey: .tombstonedLibrary))
    }

    public var removedCount: Int { deletedTasks + tombstonedLibrary }

    func validated() throws -> Self {
        try Self(generation: generation, deletedTasks: deletedTasks, tombstonedLibrary: tombstonedLibrary)
    }

    func exactlyMatches(_ other: Self) -> Bool {
        generation.utf8.elementsEqual(other.generation.utf8)
            && deletedTasks == other.deletedTasks && tombstonedLibrary == other.tombstonedLibrary
    }
}

private func validDatasetIdentifier(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
}

public protocol DatasetResetRepository: Sendable {
    func load(baseURL: String, owner: String) async throws -> DatasetResetRequest?
    /// Return the existing request when another coordinator already claimed this account.
    func claim(_ request: DatasetResetRequest) async throws -> DatasetResetRequest
    func acknowledge(_ request: DatasetResetRequest, receipt: DatasetResetAcknowledgement) async throws -> DatasetResetRequest
    /// Local completion retires only this exact, acknowledged request.
    func complete(_ request: DatasetResetRequest) async throws
}

public final class GRDBDatasetResetRepository: DatasetResetRepository {
    private let dbWriter: any DatabaseWriter

    public init(_ database: AppDatabase) { dbWriter = database.writer }

    public func load(baseURL: String, owner: String) async throws -> DatasetResetRequest? {
        try await dbWriter.read { db in try Self.read(db, baseURL: baseURL, owner: owner) }
    }

    public func claim(_ request: DatasetResetRequest) async throws -> DatasetResetRequest {
        _ = try request.validated()
        guard request.acknowledgement == nil else { throw DatasetResetJournalError.invalidRequest }
        return try await dbWriter.write { db in
            if let existing = try Self.read(db, baseURL: request.baseURL, owner: request.owner) { return existing }
            try Self.write(db, request)
            return request
        }
    }

    public func acknowledge(_ request: DatasetResetRequest, receipt: DatasetResetAcknowledgement) async throws -> DatasetResetRequest {
        try await dbWriter.write { db in
            guard let current = try Self.read(db, baseURL: request.baseURL, owner: request.owner),
                  current.matchesIdentity(request) else { throw DatasetResetJournalError.conflictingRequest }
            let acknowledged = try current.accepting(receipt)
            try Self.write(db, acknowledged)
            return acknowledged
        }
    }

    public func complete(_ request: DatasetResetRequest) async throws {
        guard request.acknowledgement != nil else { throw DatasetResetJournalError.acknowledgementRequired }
        try await dbWriter.write { db in
            guard let current = try Self.read(db, baseURL: request.baseURL, owner: request.owner) else { return }
            guard current.matchesIdentity(request) else { throw DatasetResetJournalError.conflictingRequest }
            guard let acknowledgement = current.acknowledgement,
                  let expected = request.acknowledgement, acknowledgement.exactlyMatches(expected) else {
                throw DatasetResetJournalError.acknowledgementRequired
            }
            try db.execute(sql: "DELETE FROM datasetResetRequests WHERE baseURL = ? AND owner = ?",
                           arguments: [request.baseURL, request.owner])
        }
    }

    private static func read(_ db: Database, baseURL: String, owner: String) throws -> DatasetResetRequest? {
        guard let payload = try String.fetchOne(db,
            sql: "SELECT payload FROM datasetResetRequests WHERE baseURL = ? AND owner = ?",
            arguments: [baseURL, owner]) else { return nil }
        do {
            let request = try JSONDecoder().decode(DatasetResetRequest.self, from: Data(payload.utf8)).validated()
            guard request.baseURL.utf8.elementsEqual(baseURL.utf8), request.owner.utf8.elementsEqual(owner.utf8) else {
                throw DatasetResetJournalError.corruptRecord
            }
            return request
        } catch { throw DatasetResetJournalError.corruptRecord }
    }

    private static func write(_ db: Database, _ request: DatasetResetRequest) throws {
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO datasetResetRequests (baseURL, owner, payload) VALUES (?, ?, ?)
            ON CONFLICT(baseURL, owner) DO UPDATE SET payload = excluded.payload
            """, arguments: [request.baseURL, request.owner, payload])
    }
}

/// An explicitly in-memory repository for ephemeral package clients. The app injects GRDB.
public actor MemoryDatasetResetRepository: DatasetResetRepository {
    private var requests: [Data: [Data: DatasetResetRequest]] = [:]

    public init() {}

    public func load(baseURL: String, owner: String) throws -> DatasetResetRequest? {
        try requests[Data(baseURL.utf8)]?[Data(owner.utf8)]?.validated()
    }

    public func claim(_ request: DatasetResetRequest) throws -> DatasetResetRequest {
        _ = try request.validated()
        guard request.acknowledgement == nil else { throw DatasetResetJournalError.invalidRequest }
        if let current = requests[Data(request.baseURL.utf8)]?[Data(request.owner.utf8)] { return try current.validated() }
        requests[Data(request.baseURL.utf8), default: [:]][Data(request.owner.utf8)] = request
        return request
    }

    public func acknowledge(_ request: DatasetResetRequest, receipt: DatasetResetAcknowledgement) throws -> DatasetResetRequest {
        guard let current = requests[Data(request.baseURL.utf8)]?[Data(request.owner.utf8)], current.matchesIdentity(request) else {
            throw DatasetResetJournalError.conflictingRequest
        }
        let acknowledged = try current.accepting(receipt)
        requests[Data(request.baseURL.utf8), default: [:]][Data(request.owner.utf8)] = acknowledged
        return acknowledged
    }

    public func complete(_ request: DatasetResetRequest) throws {
        guard let expected = request.acknowledgement else { throw DatasetResetJournalError.acknowledgementRequired }
        guard let current = requests[Data(request.baseURL.utf8)]?[Data(request.owner.utf8)] else { return }
        guard current.matchesIdentity(request) else { throw DatasetResetJournalError.conflictingRequest }
        guard let acknowledgement = current.acknowledgement, acknowledgement.exactlyMatches(expected) else {
            throw DatasetResetJournalError.acknowledgementRequired
        }
        requests[Data(request.baseURL.utf8)]?[Data(request.owner.utf8)] = nil
    }
}
