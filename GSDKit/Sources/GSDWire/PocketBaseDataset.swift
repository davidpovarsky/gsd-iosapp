import Foundation

/// Invalid caller-owned dataset identifiers never reach the network.
/// Error values identify the field only; they do not contain account tokens or submitted values.
public enum DatasetProtocolError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case negativeResetCount(field: String)
}

/// The server's durable acknowledgement of one caller-identified dataset reset.
/// Codable permits a host journal to retain the exact receipt before local queue retirement.
public struct DatasetResetReceipt: Codable, Equatable, Sendable {
    public let generation: String
    public let requestID: String
    public let deletedTasks: Int
    public let tombstonedLibrary: Int

    public init(
        generation: String,
        requestID: String,
        deletedTasks: Int,
        tombstonedLibrary: Int
    ) throws {
        try DatasetIdentifier.validate(generation, field: "generation")
        try DatasetIdentifier.validate(requestID, field: "request_id")
        guard deletedTasks >= 0 else {
            throw DatasetProtocolError.negativeResetCount(field: "deleted_tasks")
        }
        guard tombstonedLibrary >= 0 else {
            throw DatasetProtocolError.negativeResetCount(field: "tombstoned_library")
        }
        self.generation = generation
        self.requestID = requestID
        self.deletedTasks = deletedTasks
        self.tombstonedLibrary = tombstonedLibrary
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case requestID = "request_id"
        case deletedTasks = "deleted_tasks"
        case tombstonedLibrary = "tombstoned_library"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(String.self, forKey: .generation)
        let requestID = try container.decode(String.self, forKey: .requestID)
        let deletedTasks = try container.decode(Int.self, forKey: .deletedTasks)
        let tombstonedLibrary = try container.decode(Int.self, forKey: .tombstonedLibrary)
        do {
            try self.init(
                generation: generation, requestID: requestID,
                deletedTasks: deletedTasks, tombstonedLibrary: tombstonedLibrary)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid dataset reset receipt."))
        }
    }
}

/// The same bounded, header-safe representation is used in JSON and HTTP headers.
/// Opaque identifiers are kept verbatim; whitespace or Unicode normalization would change authority.
enum DatasetIdentifier {
    static func validate(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            throw DatasetProtocolError.invalidIdentifier(field: field)
        }
    }
}

private struct DatasetGenerationResponse: Decodable {
    let generation: String

    private enum CodingKeys: String, CodingKey { case generation }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(String.self, forKey: .generation)
        do {
            try DatasetIdentifier.validate(generation, field: "generation")
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .generation, in: container, debugDescription: "Invalid dataset generation.")
        }
        self.generation = generation
    }
}

private struct DatasetResetRequest: Encodable {
    let expectedGeneration: String
    let requestID: String

    private enum CodingKeys: String, CodingKey {
        case expectedGeneration = "expected_generation"
        case requestID = "request_id"
    }
}

extension PocketBaseClient {
    /// Uses this client's configured PocketBase base and native raw-token Authorization.
    /// A missing route or invalid response is an error, never a legacy-generation fallback.
    public func fetchDatasetGeneration(token: String) async throws -> String {
        let request = authedRequest(path: "/api/gsd/dataset", method: "GET", token: token)
        return try await send(request, as: DatasetGenerationResponse.self).generation
    }

    /// The caller persists expectedGeneration and requestID before sending this operation.
    /// Retrying these exact values preserves server idempotency; this method creates neither.
    public func resetDataset(
        expectedGeneration: String,
        requestID: String,
        token: String
    ) async throws -> DatasetResetReceipt {
        try DatasetIdentifier.validate(expectedGeneration, field: "expected_generation")
        try DatasetIdentifier.validate(requestID, field: "request_id")
        let body = try JSONEncoder().encode(DatasetResetRequest(
            expectedGeneration: expectedGeneration, requestID: requestID))
        let request = authedRequest(
            path: "/api/gsd/dataset/reset", method: "POST", token: token, body: body)
        let receipt = try await send(request, as: DatasetResetReceipt.self)
        guard receipt.requestID.utf8.elementsEqual(requestID.utf8) else {
            throw PocketBaseError.decoding("Dataset reset response has a different request identifier.")
        }
        guard !receipt.generation.utf8.elementsEqual(expectedGeneration.utf8) else {
            throw PocketBaseError.decoding("Dataset reset response did not rotate the generation.")
        }
        return receipt
    }
}
