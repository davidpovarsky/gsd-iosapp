import Testing
import Foundation
@testable import GSDSync
@testable import GSDWire
import GSDStore
import GSDModel

struct SyncEngineEraseTests {
    // Returns a one-task remote index for GET; records writes (DELETE/POST/PATCH) otherwise.
    final class DeleteExecutor: RequestExecuting, @unchecked Sendable {
        var indexJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec1","task_id":"t1","client_updated_at":"2001-01-01T00:00:00.000Z"}]}"#
        private(set) var writes: [(method: String, path: String)] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let m = request.httpMethod ?? "GET"
            if m == "GET" {
                return (Data(indexJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            writes.append((m, request.url!.path))
            return (Data(#"{"id":"rec1","task_id":"t1"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: m == "DELETE" ? 204 : 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func make(_ db: AppDatabase, _ exec: RequestExecuting)
        -> (SyncEngine, GRDBTaskRepository, GRDBSyncQueueRepository) {
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        return (eng, tasks, queue)
    }

    @Test func eraseAllRemoteEnqueuesAndDeletesEveryLocalTask() async throws {
        // Keep the original catalog identity while requiring the stronger atomic reset protocol.
        let db = try AppDatabase.inMemory()
        let exec = AtomicEraseFixtureExecutor(remoteTaskIDs: ["t1"], expectedToken: token)
        let (eng, tasks, queue) = make(db, exec)
        try await tasks.upsert(Task(id: "t1", title: "x", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        try await queue.enqueue(SyncQueueItem(id: "pending", taskId: "t1", operation: .update, timestamp: 1))
        try await queue.enqueue(SyncQueueItem(
            id: "failed", taskId: "t1", operation: .create, timestamp: 2, status: .failed))
        #expect(await exec.snapshot().remoteTaskIDs == ["t1"])

        let result = await eng.eraseAllRemote()
        let observed = await exec.snapshot()
        #expect(result.pushed == 1)
        #expect(result.error == nil && !result.notSignedIn && !result.skipped)
        #expect(observed.remoteTaskIDs.isEmpty)
        #expect(observed.deletedTaskCounts == [1])
        #expect(observed.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /api/gsd/dataset", "POST /api/gsd/dataset/reset"
        ])
        #expect(observed.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == token })
        #expect(!observed.requests.contains {
            $0.httpMethod == "DELETE" || $0.url?.path.contains("/collections/tasks/") == true
        })
        let reset = try #require(observed.resetBodies.first)
        #expect(observed.resetBodies.count == 1)
        #expect(reset["expected_generation"] == "generation-before-reset")
        let requestID = try #require(reset["request_id"])
        #expect(!requestID.isEmpty && requestID.utf8.count <= 128)
        #expect(try await queue.pending().isEmpty)
        #expect(try await queue.all().isEmpty)            // failed mutations are retired as well
    }

    @Test func eraseAllRemoteNoOpsWhenSignedOut() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(Task(id: "t1", title: "x", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: DeleteExecutor()),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { nil },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        let result = await eng.eraseAllRemote()
        #expect(result.notSignedIn)
        #expect(try await queue.pending().isEmpty)        // signed out → no deletes enqueued
    }

    @Test func eraseAllRemoteTokenFailureIsAnErrorNotSignedOut() async throws {
        // A session EXISTS but can't be validated (expired + refresh unavailable). Reporting
        // notSignedIn here would let the caller wipe local while every task survives remotely.
        let db = try AppDatabase.inMemory()
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: DeleteExecutor()),
                             tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A",
                             tokenProvider: { throw PocketBaseError.network("offline during refresh") },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        let result = await eng.eraseAllRemote()
        #expect(!result.notSignedIn)
        #expect(result.error != nil)
    }

    @Test func flushDeletesDrainsPendingDeletes() async throws {
        let db = try AppDatabase.inMemory(); let exec = DeleteExecutor()
        let (eng, _, queue) = make(db, exec)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "t1", operation: .delete, timestamp: 2_000_000_000_000))
        let result = await eng.flushDeletes()
        #expect(result.pushed == 1)
        #expect(exec.writes.contains { $0.method == "DELETE" })
    }

    @Test func pullSuppressedWhileErasing() async throws {
        let db = try AppDatabase.inMemory(); let exec = DeleteExecutor()  // index has "t1"
        let (eng, tasks, _) = make(db, exec)
        await eng.setErasing(true)
        let (applied, conflicts, maxApplied) = try await eng.pull(token: token, since: "1970-01-01T00:00:00.000Z")
        #expect(applied == 0 && conflicts == 0 && maxApplied == nil)
        #expect(try await tasks.fetch(id: "t1") == nil)   // gate prevented the upsert
    }
}


/// Stateful server fixture for the atomic erase route. Unexpected enumeration or per-record
/// deletion fails; only a valid reset removes the actual retained remote task set.
actor AtomicEraseFixtureExecutor: RequestExecuting {
    struct Snapshot: Sendable {
        let requests: [URLRequest]
        let remoteTaskIDs: Set<String>
        let resetBodies: [[String: String]]
        let deletedTaskCounts: [Int]
    }

    private var generation = "generation-before-reset"
    private var remoteTaskIDs: Set<String>
    private let expectedToken: String
    private var requests: [URLRequest] = []
    private var resetBodies: [[String: String]] = []
    private var deletedTaskCounts: [Int] = []

    init(remoteTaskIDs: Set<String>, expectedToken: String) {
        self.remoteTaskIDs = remoteTaskIDs
        self.expectedToken = expectedToken
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requests: requests, remoteTaskIDs: remoteTaskIDs,
            resetBodies: resetBodies, deletedTaskCounts: deletedTaskCounts)
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard request.value(forHTTPHeaderField: "Authorization") == expectedToken else {
            return try response(["code": 401, "message": "fixture_authorization_mismatch"], status: 401, request: request)
        }
        switch (request.httpMethod ?? "", request.url?.path ?? "") {
        case ("GET", "/api/gsd/dataset"):
            return try response(["generation": generation], status: 200, request: request)
        case ("POST", "/api/gsd/dataset/reset"):
            guard request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  let data = request.httpBody,
                  let body = try? JSONDecoder().decode([String: String].self, from: data),
                  Set(body.keys) == ["expected_generation", "request_id"],
                  let expected = body["expected_generation"],
                  let requestID = body["request_id"], !requestID.isEmpty, requestID.utf8.count <= 128 else {
                return try response(["code": 400, "message": "fixture_invalid_reset"], status: 400, request: request)
            }
            guard expected == generation else {
                return try response(
                    ["code": 409, "message": "dataset_generation_mismatch"], status: 409, request: request)
            }
            resetBodies.append(body)
            let removed = remoteTaskIDs.count
            remoteTaskIDs.removeAll()
            generation = "generation-after-reset"
            deletedTaskCounts.append(removed)
            return try response([
                "generation": generation, "request_id": requestID,
                "deleted_tasks": removed, "tombstoned_library": 0
            ], status: 200, request: request)
        default:
            return try response(["code": 404, "message": "fixture_unexpected_route"], status: 404, request: request)
        }
    }

    private func response(
        _ body: [String: Any], status: Int, request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        (
            try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}
