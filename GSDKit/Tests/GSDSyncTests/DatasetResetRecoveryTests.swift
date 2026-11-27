import Foundation
import GRDB
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

@Suite(.timeLimit(.minutes(1)))
struct DatasetResetRecoveryTests {
    private let endpoint = "https://example.invalid/gsd-cloud"
    private let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String?) { self.value = value }
        func read() -> String? { lock.withLock { value } }
        func write(_ value: String?) { lock.withLock { self.value = value } }
    }

    private actor Gate {
        private var entered = false
        private var released = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Never>?

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enterWaiters.append($0) }
        }

        func block() async {
            entered = true
            for waiter in enterWaiters { waiter.resume() }
            enterWaiters.removeAll()
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Models a committed server transaction and its immutable receipt, including a lost reply.
    /// It is deterministic HTTP transport evidence; these tests do not claim live server acceptance.
    private actor Executor: RequestExecuting {
        private(set) var requests: [URLRequest] = []
        private(set) var resetBodies: [[String: String]] = []
        private(set) var remoteIDs: Set<String> = ["old"]
        private var generation = "0"
        private var receipts: [String: (expected: String, data: Data)] = [:]
        private var lostReply = false
        private let loseFirstReply: Bool
        private let heldPath: String?
        private let gate: Gate?

        init(loseFirstReply: Bool = false, heldPath: String? = nil, gate: Gate? = nil) {
            self.loseFirstReply = loseFirstReply
            self.heldPath = heldPath
            self.gate = gate
        }

        func addRemote(_ id: String) { remoteIDs.insert(id) }

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let path = request.url!.path
            if path == "/gsd-cloud/api/gsd/dataset" {
                let body = try JSONSerialization.data(withJSONObject: ["generation": generation])
                if heldPath == path { await gate?.block() }
                return response(request, data: body)
            }
            if path == "/gsd-cloud/api/gsd/dataset/reset" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: String]
                resetBodies.append(body)
                let expected = body["expected_generation"] ?? ""
                let id = body["request_id"] ?? ""
                if let previous = receipts[id] {
                    guard previous.expected == expected else {
                        return response(request, status: 409, message: "request_id_conflict")
                    }
                    return response(request, data: previous.data)
                }
                guard !id.isEmpty, expected == generation else {
                    return response(request, status: 409, message: "dataset_generation_mismatch")
                }
                let removed = remoteIDs.count
                remoteIDs.removeAll()
                generation = "generation-\(receipts.count + 1)"
                let receipt = try JSONSerialization.data(withJSONObject: [
                    "generation": generation, "request_id": id,
                    "deleted_tasks": removed, "tombstoned_library": 0
                ])
                receipts[id] = (expected, receipt)
                if heldPath == path { await gate?.block() }
                if loseFirstReply && !lostReply {
                    lostReply = true
                    throw PocketBaseError.network("reply lost after commit")
                }
                return response(request, data: receipt)
            }
            return response(request, status: 404, message: "unexpected automatic request")
        }

        private func response(_ request: URLRequest, status: Int = 200, data: Data)
            -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        private func response(_ request: URLRequest, status: Int, message: String)
            -> (Data, HTTPURLResponse) {
            let data = try! JSONSerialization.data(withJSONObject: ["status": status, "message": message, "data": [:]])
            return response(request, status: status, data: data)
        }
    }

    private func engine(_ database: AppDatabase, executor: Executor, token: TokenBox) -> SyncEngine {
        SyncEngine(
            client: PocketBaseClient(baseURL: endpoint, executor: executor),
            tasks: GRDBTaskRepository(database), queue: GRDBSyncQueueRepository(database),
            tombstones: GRDBTombstoneRepository(database),
            cursor: SyncCursor(defaults: UserDefaults(suiteName: "reset-recovery.\(UUID().uuidString)")!),
            deviceId: "device-A", tokenProvider: { token.read() }, rawToken: { token.read() },
            throttleMs: 0, resetRequests: GRDBDatasetResetRepository(database))
    }

    private func seed(_ database: AppDatabase) async throws -> [SyncQueueItem] {
        let task = Task(id: "old", title: "Keep local until acknowledgement", urgent: false, important: false,
                        createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        try await GRDBTaskRepository(database).upsert(task)
        let item = SyncQueueItem(id: "pending-old", taskId: task.id, operation: .create, timestamp: 1000, payload: task)
        try await GRDBSyncQueueRepository(database).enqueue(item)
        return [item]
    }

    @Test func ambiguousReceiptReplaysAcrossDatabaseReopenWithoutErasingNewRemoteTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gsd-reset-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        let executor = Executor(loseFirstReply: true)
        let credential = TokenBox(token)
        do {
            let writer = try DatabaseQueue(path: path)
            let database = try AppDatabase(writer)
            let before = try await seed(database)
            let first = await engine(database, executor: executor, token: credential).eraseAllRemote()
            #expect(first.error != nil && !first.notSignedIn)
            #expect(try await GRDBSyncQueueRepository(database).all() == before)
            try writer.close()
        }
        await executor.addRemote("created-after-reset")
        do {
            let writer = try DatabaseQueue(path: path)
            let database = try AppDatabase(writer)
            let result = await engine(database, executor: executor, token: credential).eraseAllRemote()
            #expect(result.error == nil && result.pushed == 1)
            #expect(try await GRDBSyncQueueRepository(database).all().isEmpty)
            #expect(result.datasetReset?.acknowledgement != nil)
            try writer.close()
        }
        let bodies = await executor.resetBodies
        #expect(bodies.count == 2 && bodies.first == bodies.last)
        #expect(bodies.first?["expected_generation"] == "0")
        #expect(await executor.requests.filter { $0.url!.path.hasSuffix("/dataset") }.count == 1)
        #expect(await executor.remoteIDs == ["created-after-reset"])
    }

    @Test func persistedAcknowledgementBlocksAutomaticSyncAndRealtimeAfterEngineRestart() async throws {
        let database = try AppDatabase.inMemory()
        _ = try await seed(database)
        let executor = Executor()
        let credential = TokenBox(token)
        let first = await engine(database, executor: executor, token: credential).eraseAllRemote()
        #expect(first.error == nil)
        let before = await executor.requests.count
        let restarted = engine(database, executor: executor, token: credential)
        let sync = await restarted.sync(trigger: .launch)
        let push = await restarted.pushNow()
        #expect(sync.error != nil && push.error != nil)
        await restarted.applyRealtime(rawData: #"{"action":"create","record":{"id":"remote-new","task_id":"incoming","title":"Must remain remote","owner":"u1","client_updated_at":"2026-11-27 00:00:00.000Z","updated":"2026-11-27 00:00:00.000Z"}}"#)
        #expect(try await GRDBTaskRepository(database).fetch(id: "incoming") == nil)
        #expect(try await GRDBTaskRepository(database).fetch(id: "old") != nil)
        #expect(try await GRDBSyncQueueRepository(database).all().isEmpty)
        #expect(await executor.requests.count == before)
        #expect(await restarted.health(online: true).level == .warning)
    }

    @Test func acknowledgedReceiptWaitsForExplicitLocalCompletionWithoutAnotherRemoteReset() async throws {
        let database = try AppDatabase.inMemory()
        _ = try await seed(database)
        let executor = Executor()
        let credential = TokenBox(token)
        let first = await engine(database, executor: executor, token: credential).eraseAllRemote()
        #expect(first.error == nil && first.datasetReset != nil)
        let before = await executor.requests.count
        let restarted = engine(database, executor: executor, token: credential)
        let retry = await restarted.eraseAllRemote()
        #expect(retry.error == nil && retry.datasetReset == first.datasetReset)
        #expect(await executor.requests.count == before)
        try await GRDBTaskRepository(database).replaceAll([])
        try await restarted.completeDatasetReset(retry)
        #expect(try await GRDBDatasetResetRepository(database).load(baseURL: endpoint, owner: "u1") == nil)
        #expect(try await GRDBTaskRepository(database).fetchAll().isEmpty)
        #expect(await restarted.health(online: true).level != .warning)
    }

    @Test func changedCredentialAfterDiscoveryCannotStartResetOrRetireQueue() async throws {
        let database = try AppDatabase.inMemory()
        let before = try await seed(database)
        let gate = Gate()
        let executor = Executor(heldPath: "/gsd-cloud/api/gsd/dataset", gate: gate)
        let credential = TokenBox(token)
        let current = engine(database, executor: executor, token: credential)
        let operation = _Concurrency.Task { await current.eraseAllRemote() }
        await gate.waitUntilEntered()
        credential.write(String(token.dropLast()) + "y") // Same owner, different exact credential.
        await gate.release()
        let result = await operation.value
        #expect(result.error != nil && !result.notSignedIn)
        #expect(await executor.resetBodies.isEmpty)
        #expect(try await GRDBSyncQueueRepository(database).all() == before)
        #expect(try await GRDBDatasetResetRepository(database).load(baseURL: endpoint, owner: "u1") == nil)
    }

    @Test func cancelledDiscoveryCannotStartResetOrRetireQueue() async throws {
        let database = try AppDatabase.inMemory()
        let before = try await seed(database)
        let gate = Gate()
        let executor = Executor(heldPath: "/gsd-cloud/api/gsd/dataset", gate: gate)
        let credential = TokenBox(token)
        let current = engine(database, executor: executor, token: credential)
        let operation = _Concurrency.Task { await current.eraseAllRemote() }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        let result = await operation.value
        #expect(result.error != nil && !result.notSignedIn)
        #expect(await executor.resetBodies.isEmpty)
        #expect(try await GRDBSyncQueueRepository(database).all() == before)
        #expect(try await GRDBDatasetResetRepository(database).load(baseURL: endpoint, owner: "u1") == nil)
    }

    @Test func changedCredentialAfterServerCommitKeepsUnacknowledgedIntentAndQueue() async throws {
        let database = try AppDatabase.inMemory()
        let before = try await seed(database)
        let gate = Gate()
        let executor = Executor(heldPath: "/gsd-cloud/api/gsd/dataset/reset", gate: gate)
        let credential = TokenBox(token)
        let current = engine(database, executor: executor, token: credential)
        let operation = _Concurrency.Task { await current.eraseAllRemote() }
        await gate.waitUntilEntered()
        credential.write(String(token.dropLast()) + "y")
        await gate.release()
        let result = await operation.value
        #expect(result.error != nil && !result.notSignedIn)
        let pending = try await GRDBDatasetResetRepository(database).load(baseURL: endpoint, owner: "u1")
        #expect(pending != nil && pending?.acknowledgement == nil)
        #expect(try await GRDBSyncQueueRepository(database).all() == before)
        await executor.addRemote("created-after-reset")
        credential.write(token)
        let retry = await engine(database, executor: executor, token: credential).eraseAllRemote()
        #expect(retry.error == nil)
        let bodies = await executor.resetBodies
        #expect(bodies.count == 2 && bodies.first == bodies.last)
        #expect(await executor.remoteIDs == ["created-after-reset"])
    }

    @Test func failedAcknowledgementPersistenceKeepsQueueAndOriginalIdentityForRetry() async throws {
        let database = try AppDatabase.inMemory()
        let before = try await seed(database)
        let executor = Executor()
        let credential = TokenBox(token)
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseResetReceipt BEFORE UPDATE ON datasetResetRequests BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let first = await engine(database, executor: executor, token: credential).eraseAllRemote()
        #expect(first.error != nil)
        #expect(try await GRDBSyncQueueRepository(database).all() == before)
        let pending = try await GRDBDatasetResetRepository(database).load(baseURL: endpoint, owner: "u1")
        #expect(pending != nil && pending?.acknowledgement == nil)
        try await database.writer.write { db in try db.execute(sql: "DROP TRIGGER refuseResetReceipt") }
        let retry = await engine(database, executor: executor, token: credential).eraseAllRemote()
        #expect(retry.error == nil && retry.datasetReset?.requestID == pending?.requestID)
        let bodies = await executor.resetBodies
        #expect(bodies.count == 2 && bodies.first == bodies.last)
        #expect(await executor.requests.filter { $0.url!.path.hasSuffix("/dataset") }.count == 1)
        #expect(try await GRDBSyncQueueRepository(database).all().isEmpty)
    }

    @Test func queueRetirementFailureKeepsDurableReceiptWithoutRepeatingRemoteReset() async throws {
        let database = try AppDatabase.inMemory()
        let before = try await seed(database)
        let executor = Executor()
        let credential = TokenBox(token)
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseQueueRetirement BEFORE DELETE ON syncQueue BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let first = await engine(database, executor: executor, token: credential).eraseAllRemote()
        #expect(first.error != nil && first.datasetReset?.acknowledgement != nil)
        #expect(try await GRDBSyncQueueRepository(database).all() == before)
        let requestsBefore = await executor.requests.count
        try await database.writer.write { db in try db.execute(sql: "DROP TRIGGER refuseQueueRetirement") }
        let retry = await engine(database, executor: executor, token: credential).eraseAllRemote()
        #expect(retry.error == nil && retry.datasetReset == first.datasetReset)
        #expect(try await GRDBSyncQueueRepository(database).all().isEmpty)
        #expect(await executor.requests.count == requestsBefore)
    }
}
