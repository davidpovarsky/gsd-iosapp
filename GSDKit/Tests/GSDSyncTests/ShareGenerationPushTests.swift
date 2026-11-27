import Foundation
import GRDB
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

struct ShareGenerationPushTests {
    private let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private actor Executor: RequestExecuting {
        let status: Int
        private(set) var creates: [URLRequest] = []
        init(status: Int = 409) { self.status = status }

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path
            if path.hasSuffix("/auth-refresh") {
                return response(request, body: #"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#)
            }
            if request.httpMethod == "GET", path == "/api/collections/tasks/records" {
                return response(request, body: #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#)
            }
            if request.httpMethod == "POST", path == "/api/collections/tasks/records" {
                creates.append(request)
                return response(request, status: status, body: status == 200
                    ? #"{"id":"created-record","task_id":"shared","title":"Shared task"}"#
                    : #"{"status":409,"message":"dataset_generation_mismatch","data":{}}"#)
            }
            return response(request, status: 404, body: #"{"status":404,"message":"unexpected route","data":{}}"#)
        }

        private func response(_ request: URLRequest, status: Int = 200, body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func task(_ id: String = "shared") -> Task {
        Task(id: id, title: "Shared task", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }

    private func engine(_ database: AppDatabase, executor: Executor) -> SyncEngine {
        let credential = token
        return SyncEngine(
            client: PocketBaseClient(baseURL: "https://example.invalid", executor: executor),
            tasks: GRDBTaskRepository(database), queue: GRDBSyncQueueRepository(database),
            tombstones: GRDBTombstoneRepository(database),
            cursor: SyncCursor(defaults: UserDefaults(suiteName: "share-generation-push.\(UUID().uuidString)")!),
            deviceId: "device-A", tokenProvider: { credential }, rawToken: { credential },
            now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }

    private func item(_ id: String, generation: String?, status: SyncQueueItem.Status = .pending,
                      operation: SyncQueueItem.Operation = .create, timestamp: Int = 1,
                      taskID: String = "shared") -> SyncQueueItem {
        SyncQueueItem(id: id, taskId: taskID, operation: operation, timestamp: timestamp,
                      payload: operation == .delete ? nil : task(taskID), status: status,
                      serverDatasetGeneration: generation)
    }

    @Test func failedShareBindingPropagatesToSeededRetryAndSurvivesServerConflict() async throws {
        let database = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(database)
        try await GRDBTaskRepository(database).upsert(task())
        try await queue.enqueue(item("failed-share", generation: "generation-original", status: .failed))
        let executor = Executor()
        let current = engine(database, executor: executor)
        try await current.seedExistingTasks(owner: "u1")
        let result = try await current.push(token: token, owner: "u1")
        #expect(result.pushed == 0 && result.failed == 1)
        let requests = await executor.creates
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == "generation-original")
        let rows = try await queue.all()
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.serverDatasetGeneration == "generation-original" })
        #expect(rows.first { $0.id != "failed-share" }?.retryCount == 1)
    }

    @Test func failedBindingPersistenceStopsBeforeAnyCreate() async throws {
        let database = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(database)
        try await queue.enqueue(item("failed-share", generation: "generation-original", status: .failed))
        try await queue.enqueue(item("pending-retry", generation: nil, timestamp: 2))
        let before = try await queue.all()
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseGenerationBinding BEFORE UPDATE ON syncQueue BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let executor = Executor(status: 200)
        let current = engine(database, executor: executor)
        await #expect(throws: DatabaseError.self) {
            try await current.push(token: token, owner: "u1")
        }
        #expect(await executor.creates.isEmpty)
        #expect(try await queue.all() == before)
    }

    @Test func conflictingBindingsStopBeforeAnyCreate() async throws {
        let database = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(database)
        try await queue.enqueue(item("failed-original", generation: "generation-original", status: .failed))
        try await queue.enqueue(item("failed-other", generation: "generation-other", status: .failed, timestamp: 2))
        try await queue.enqueue(item("pending-retry", generation: nil, timestamp: 3))
        let before = try await queue.all()
        let executor = Executor(status: 200)
        let current = engine(database, executor: executor)
        await #expect(throws: SyncQueueGenerationError.conflictingGenerations) {
            try await current.push(token: token, owner: "u1")
        }
        #expect(await executor.creates.isEmpty)
        #expect(try await queue.all() == before)
    }

    @Test func sameDrainKeepsBindingAfterEarlierBoundDeleteIsRemoved() async throws {
        let database = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(database)
        try await queue.enqueue(item("old-delete", generation: "generation-original", operation: .delete))
        try await queue.enqueue(item("restored-create", generation: nil, timestamp: 2))
        let executor = Executor()
        let result = try await engine(database, executor: executor).push(token: token, owner: "u1")
        #expect(result.pushed == 1 && result.failed == 1)
        #expect(await executor.creates.count == 1)
        #expect(await executor.creates.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == "generation-original")
        let rows = try await queue.all()
        #expect(rows.count == 1 && rows.first?.id == "restored-create")
        #expect(rows.first?.serverDatasetGeneration == "generation-original")
    }

    @Test func successfulBoundCreateRetiresOnlyItsOwnItem() async throws {
        let database = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(database)
        try await queue.enqueue(item("bound-create", generation: "generation-original"))
        let unrelated = item("other-failed", generation: "other-generation", status: .failed, timestamp: 2, taskID: "other")
        try await queue.enqueue(unrelated)
        let executor = Executor(status: 200)
        let result = try await engine(database, executor: executor).push(token: token, owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await executor.creates.count == 1)
        #expect(await executor.creates.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == "generation-original")
        #expect(try await queue.all() == [unrelated])
    }

    @Test func ordinaryUnboundCreateRetainsItsExistingWireContract() async throws {
        let database = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(database)
        try await queue.enqueue(item("ordinary-create", generation: nil))
        let executor = Executor(status: 200)
        let result = try await engine(database, executor: executor).push(token: token, owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        let requests = await executor.creates
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == nil)
        let body = try JSONSerialization.jsonObject(with: requests.first?.httpBody ?? Data()) as? [String: Any]
        #expect(body?["task_id"] as? String == "shared")
        #expect(body?["owner"] as? String == "u1")
        #expect(body?["title"] as? String == "Shared task")
        #expect(try await queue.all().isEmpty)
    }
}
