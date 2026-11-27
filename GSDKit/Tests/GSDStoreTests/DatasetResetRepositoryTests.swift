import Foundation
import GRDB
import Testing
@testable import GSDStore

struct DatasetResetRepositoryTests {
    private let endpoint = "https://example.invalid/gsd-cloud"

    private func request(owner: String = "owner-A", id: String = "request-A",
                         baseURL: String? = nil) throws -> DatasetResetRequest {
        try DatasetResetRequest(baseURL: baseURL ?? endpoint, owner: owner,
                                expectedGeneration: "0", requestID: id)
    }

    private func receipt(_ generation: String = "generation-1") throws -> DatasetResetAcknowledgement {
        try DatasetResetAcknowledgement(generation: generation, deletedTasks: 2, tombstonedLibrary: 3)
    }

    @Test func requestAndAcknowledgementSurviveSQLiteCloseAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gsd-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reset.sqlite").path
        let original = try request()
        let acknowledgement = try receipt()
        do {
            let writer = try DatabaseQueue(path: path)
            let repository = GRDBDatasetResetRepository(try AppDatabase(writer))
            #expect(try await repository.claim(original) == original)
            try writer.close()
        }
        do {
            let writer = try DatabaseQueue(path: path)
            let repository = GRDBDatasetResetRepository(try AppDatabase(writer))
            #expect(try await repository.load(baseURL: endpoint, owner: original.owner) == original)
            _ = try await repository.acknowledge(original, receipt: acknowledgement)
            try writer.close()
        }
        do {
            let writer = try DatabaseQueue(path: path)
            let repository = GRDBDatasetResetRepository(try AppDatabase(writer))
            let replay = try await repository.claim(request(id: "must-not-replace"))
            #expect(replay.requestID == original.requestID)
            #expect(replay.expectedGeneration == original.expectedGeneration)
            #expect(replay.acknowledgement == acknowledgement)
            try writer.close()
        }
    }

    @Test func claimsAreIsolatedByOwnerAndEndpoint() async throws {
        let repository = GRDBDatasetResetRepository(try AppDatabase.inMemory())
        let first = try request()
        let second = try request(owner: "owner-B", id: "request-B")
        let otherServer = try request(id: "request-C", baseURL: "https://another.invalid/gsd-cloud")
        for value in [first, second, otherServer] { _ = try await repository.claim(value) }
        for value in [first, second, otherServer] {
            #expect(try await repository.load(baseURL: value.baseURL, owner: value.owner) == value)
        }
        let acknowledged = try await repository.acknowledge(first, receipt: receipt())
        try await repository.complete(acknowledged)
        #expect(try await repository.load(baseURL: endpoint, owner: second.owner) == second)
        #expect(try await repository.load(baseURL: otherServer.baseURL, owner: otherServer.owner) == otherServer)
    }

    @Test func twoRepositoriesChooseOneImmutableRequest() async throws {
        let database = try AppDatabase.inMemory()
        let first = GRDBDatasetResetRepository(database)
        let second = GRDBDatasetResetRepository(database)
        let a = try request(id: "request-A")
        let b = try request(id: "request-B")
        async let claimA = first.claim(a)
        async let claimB = second.claim(b)
        let values = try await [claimA, claimB]
        #expect(values[0] == values[1])
        #expect([a, b].contains(values[0]))
        #expect(try await first.load(baseURL: endpoint, owner: a.owner) == values[0])
    }

    @Test func acknowledgingAnotherRequestCannotReplacePendingIdentity() async throws {
        let repository = GRDBDatasetResetRepository(try AppDatabase.inMemory())
        let original = try request()
        _ = try await repository.claim(original)
        await #expect(throws: DatasetResetJournalError.conflictingRequest) {
            try await repository.acknowledge(request(id: "different-request"), receipt: receipt())
        }
        #expect(try await repository.load(baseURL: endpoint, owner: original.owner) == original)
    }

    @Test func conflictingAcknowledgementCannotReplaceFirstReceipt() async throws {
        let repository = GRDBDatasetResetRepository(try AppDatabase.inMemory())
        let original = try request()
        _ = try await repository.claim(original)
        let first = try await repository.acknowledge(original, receipt: receipt())
        #expect(try await repository.acknowledge(original, receipt: receipt()) == first)
        await #expect(throws: DatasetResetJournalError.conflictingAcknowledgement) {
            try await repository.acknowledge(original, receipt: receipt("generation-2"))
        }
        #expect(try await repository.load(baseURL: endpoint, owner: original.owner) == first)
    }

    @Test func onlyAcknowledgedExactRequestCanBeCompleted() async throws {
        let repository = GRDBDatasetResetRepository(try AppDatabase.inMemory())
        let original = try request()
        _ = try await repository.claim(original)
        await #expect(throws: DatasetResetJournalError.acknowledgementRequired) {
            try await repository.complete(original)
        }
        let acknowledged = try await repository.acknowledge(original, receipt: receipt())
        try await repository.complete(acknowledged)
        #expect(try await repository.load(baseURL: endpoint, owner: original.owner) == nil)
        let newer = try request(id: "new-intent")
        _ = try await repository.claim(newer)
        await #expect(throws: DatasetResetJournalError.conflictingRequest) {
            try await repository.complete(acknowledged)
        }
        #expect(try await repository.load(baseURL: endpoint, owner: original.owner) == newer)
    }

    @Test func corruptJournalFailsClosedWithoutRemovingBytes() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBDatasetResetRepository(database)
        let original = try request()
        _ = try await repository.claim(original)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE datasetResetRequests SET payload = ?", arguments: ["not-json"])
        }
        await #expect(throws: DatasetResetJournalError.corruptRecord) {
            try await repository.load(baseURL: endpoint, owner: original.owner)
        }
        await #expect(throws: DatasetResetJournalError.corruptRecord) {
            try await repository.claim(request(id: "must-not-overwrite"))
        }
        let payload = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM datasetResetRequests")
        }
        #expect(payload == "not-json")
    }

    @Test func failedAcknowledgementPersistenceLeavesTheOriginalPendingRequest() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBDatasetResetRepository(database)
        let original = try request()
        _ = try await repository.claim(original)
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseResetReceipt BEFORE UPDATE ON datasetResetRequests BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        await #expect(throws: DatabaseError.self) {
            try await repository.acknowledge(original, receipt: receipt())
        }
        #expect(try await repository.load(baseURL: endpoint, owner: original.owner) == original)
    }
}
