import Foundation
import GSDSnapshot

/// Owned native acceptance producer. Uses the real pending-file codec and file lease.
/// It never reads Keychain credentials, writes SQLite or calls a cloud endpoint.
@main
struct ShareAccountGenerationSeed {
    struct Request: Decodable {
        let schemaVersion: Int
        let phase: String
        let owner: String
        let generation: String
        let taskID: String
        let title: String
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalidArguments }
        let group = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let request = try JSONDecoder().decode(Request.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        guard request.schemaVersion == 1, ["seed-current", "seed-stale"].contains(request.phase),
              UUID(uuidString: request.taskID) != nil, !request.title.isEmpty,
              !request.generation.isEmpty, request.generation.utf8.count <= 128,
              !request.generation.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            throw Failure.invalidRequest
        }
        let lease = try await SharedMutationLease.acquire(directory: group, mode: .exclusive)
        defer { lease.release() }
        let identity = try SharedDatasetIdentityStore(directory: group).read()
        let publication = ShareScopePublicationStore(directory: group)
        guard let record = try publication.read(), let origin = record.scope,
              origin.kind == "account", origin.identifier == request.owner,
              origin.datasetID == identity.datasetID, publication.matches(origin, nonce: record.nonce) else {
            throw Failure.originMismatch
        }
        let outbox = ShareOutboxStore(directoryURL: group)
        guard !outbox.pending().contains(where: { $0.capture.taskID == request.taskID }),
              !outbox.inFlightCaptures().contains(where: { $0.capture.taskID == request.taskID }) else {
            throw Failure.existingCapture
        }
        let capture = SharedCapture(title: request.title, urls: [], urgent: true, important: true,
            tags: [], capturedAt: .now, taskID: request.taskID, origin: origin,
            serverDatasetGeneration: request.generation)
        try outbox.write(capture)
        let stored = outbox.pending().filter { $0.capture.taskID == request.taskID }
        guard stored.count == 1, stored[0].capture == capture,
              publication.matches(origin, nonce: record.nonce) else { throw Failure.writeMismatch }
        let receipt: [String: Any] = [
            "schemaVersion": 1, "realShareOutboxStore": true, "sqlWrites": 0, "cloudRequests": 0,
            "owner": request.owner, "taskID": request.taskID, "generation": request.generation,
            "pendingFileID": stored[0].id,
            "scope": ["kind": origin.kind, "identifier": origin.identifier, "datasetID": origin.datasetID]
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    enum Failure: Error {
        case invalidArguments, invalidRequest, originMismatch, existingCapture, writeMismatch
    }
}
