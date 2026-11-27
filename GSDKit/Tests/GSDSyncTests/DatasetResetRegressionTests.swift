import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

struct DatasetResetRegressionTests {
    private enum Mode: Equatable, Sendable { case normal, discoveryFails, resetFails, loseFirstAcknowledgement }

    private struct ResetCall: Equatable, Sendable {
        let expectedGeneration: String
        let requestID: String
    }

    private actor Executor: RequestExecuting {
        let mode: Mode
        private(set) var requests: [URLRequest] = []
        private(set) var resetCalls: [ResetCall] = []
        private var generation = "0"
        private var receipts: [String: (ResetCall, Data)] = [:]
        private var lostAcknowledgement = false

        init(_ mode: Mode) { self.mode = mode }

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let path = request.url!.path
            if path == "/api/gsd/dataset" {
                if mode == .discoveryFails { return response(request, status: 503, message: "offline") }
                return response(request, body: try JSONSerialization.data(withJSONObject: ["generation": generation]))
            }
            if path == "/api/gsd/dataset/reset" {
                let data = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
                let call = ResetCall(expectedGeneration: data?["expected_generation"] ?? "",
                                     requestID: data?["request_id"] ?? "")
                resetCalls.append(call)
                if mode == .resetFails { return response(request, status: 503, message: "reset unavailable") }
                if let previous = receipts[call.requestID] {
                    guard previous.0 == call else { return response(request, status: 409, message: "request_id_conflict") }
                    return response(request, body: previous.1)
                }
                guard !call.requestID.isEmpty, call.expectedGeneration == generation else {
                    return response(request, status: 409, message: "dataset_generation_mismatch")
                }
                generation = "generation-after-reset"
                let receipt = try JSONSerialization.data(withJSONObject: [
                    "generation": generation, "request_id": call.requestID,
                    "deleted_tasks": 1, "tombstoned_library": 0
                ])
                receipts[call.requestID] = (call, receipt)
                if mode == .loseFirstAcknowledgement && !lostAcknowledgement {
                    lostAcknowledgement = true
                    throw PocketBaseError.network("response lost after commit")
                }
                return response(request, body: receipt)
            }
            // The original implementation receives a genuine index and successful deletes.
            // Its failure is the obsolete operation, not an artificial network/decoder error.
            if request.httpMethod == "GET" && path == "/api/collections/tasks/records" {
                return response(request, body: Data(#"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec1","task_id":"t1","client_updated_at":"2001-01-01T00:00:00.000Z"}]}"#.utf8))
            }
            if request.httpMethod == "DELETE" { return response(request, status: 204, body: Data()) }
            return response(request, status: 404, message: "unexpected route")
        }

        private func response(_ request: URLRequest, status: Int = 200, body: Data)
            -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        private func response(_ request: URLRequest, status: Int, message: String)
            -> (Data, HTTPURLResponse) {
            let body = try! JSONSerialization.data(withJSONObject: ["status": status, "message": message, "data": [:]])
            return response(request, status: status, body: body)
        }
    }

    private let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func make(_ mode: Mode) async throws
        -> (SyncEngine, GRDBSyncQueueRepository, Executor) {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let task = Task(id: "t1", title: "Keep until acknowledgement", urgent: false, important: false,
                        createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        try await tasks.upsert(task)
        try await queue.enqueue(SyncQueueItem(id: "pending1", taskId: task.id, operation: .create,
                                             timestamp: 1000, payload: task))
        let executor = Executor(mode)
        let currentToken = token
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: executor),
                                tasks: tasks, queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "dataset-reset.\(UUID().uuidString)")!),
                                deviceId: "device-A", tokenProvider: { currentToken }, throttleMs: 0)
        return (engine, queue, executor)
    }

    @Test func eraseUsesOneAtomicResetWithoutEnumerationOrIndividualDeletes() async throws {
        let (engine, queue, executor) = try await make(.normal)
        let result = await engine.eraseAllRemote()
        let requests = await executor.requests
        let calls = await executor.resetCalls
        #expect(result.error == nil && !result.skipped && !result.notSignedIn)
        #expect(result.pushed == 1)
        #expect(calls.count == 1)
        #expect(calls.first?.expectedGeneration == "0")
        #expect(requests.map { $0.url!.path } == ["/api/gsd/dataset", "/api/gsd/dataset/reset"])
        #expect(requests.map { $0.httpMethod ?? "" } == ["GET", "POST"])
        #expect(try await queue.all().isEmpty)
    }

    @Test func failedGenerationDiscoveryPreservesEveryPendingMutation() async throws {
        let (engine, queue, executor) = try await make(.discoveryFails)
        let before = try await queue.all()
        let result = await engine.eraseAllRemote()
        let requests = await executor.requests
        #expect(result.error != nil)
        #expect(result.pushed == 0)
        #expect(try await queue.all() == before)
        #expect(requests.map { $0.url!.path } == ["/api/gsd/dataset"])
    }

    @Test func failedAtomicResetDoesNotRetireTheQueue() async throws {
        let (engine, queue, executor) = try await make(.resetFails)
        let before = try await queue.all()
        let result = await engine.eraseAllRemote()
        let requests = await executor.requests
        #expect(result.error != nil)
        #expect(result.pushed == 0)
        #expect(try await queue.all() == before)
        #expect(requests.filter { $0.url!.path == "/api/gsd/dataset/reset" }.count == 1)
        #expect(requests.allSatisfy { $0.httpMethod != "DELETE" })
    }

    @Test func ambiguousResetReplaysItsOriginalIdentityWithoutRediscovery() async throws {
        let (engine, queue, executor) = try await make(.loseFirstAcknowledgement)
        let before = try await queue.all()
        let first = await engine.eraseAllRemote()
        #expect(first.error != nil)
        #expect(try await queue.all() == before)
        let second = await engine.eraseAllRemote()
        let calls = await executor.resetCalls
        let requests = await executor.requests
        #expect(second.error == nil && second.pushed == 1)
        #expect(calls.count == 2)
        #expect(calls.first == calls.last)
        #expect(calls.first?.expectedGeneration == "0")
        #expect(requests.filter { $0.url!.path == "/api/gsd/dataset" }.count == 1)
        #expect(requests.allSatisfy { $0.httpMethod != "DELETE" })
        #expect(try await queue.all().isEmpty)
    }
}
