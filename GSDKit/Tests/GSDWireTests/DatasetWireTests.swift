import Foundation
import Testing
@testable import GSDWire

/// Exact native wire contract. All requests use an injected executor; no account or live server.
struct DatasetWireTests {
    private actor RecordingExecutor: RequestExecuting {
        let body: Data
        let status: Int
        private var requests: [URLRequest] = []

        init(_ body: String, status: Int = 200) {
            self.body = Data(body.utf8)
            self.status = status
        }

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        func recordedRequests() -> [URLRequest] { requests }
    }

    private func client(_ executor: RecordingExecutor) -> PocketBaseClient {
        PocketBaseClient(baseURL: "https://fixture.invalid/gsd-cloud", executor: executor)
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func response(
        generation: Any = "generation-2",
        requestID: Any = "request-1",
        deletedTasks: Any = 3,
        tombstonedLibrary: Any = 4
    ) -> [String: Any] {
        [
            "generation": generation, "request_id": requestID,
            "deleted_tasks": deletedTasks, "tombstoned_library": tombstonedLibrary
        ]
    }

    private func record() throws -> PocketBaseTaskRecord {
        try JSONDecoder().decode(
            PocketBaseTaskRecord.self,
            from: Data(#"{"task_id":"task-1","owner":"owner-1","title":"Preserved task","urgent":true,"important":false}"#.utf8))
    }

    private func expectDecodingFailure(
        _ operation: @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("A malformed dataset response must be rejected.")
        } catch let error as PocketBaseError {
            guard case .decoding = error else {
                Issue.record("Malformed dataset response used the wrong error category: \(error)")
                return
            }
        } catch {
            Issue.record("Malformed dataset response escaped the wire error category: \(error)")
        }
    }

    @Test func fetchUsesConfiguredPrefixAndRawAuthorization() async throws {
        let executor = RecordingExecutor(#"{"generation":"0"}"#)
        let generation = try await client(executor).fetchDatasetGeneration(token: "fixture.raw.token")
        #expect(generation == "0")
        let requests = await executor.recordedRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.absoluteString == "https://fixture.invalid/gsd-cloud/api/gsd/dataset")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "fixture.raw.token")
        #expect(request.httpBody == nil)
    }

    @Test func fetchPreservesInitialOpaqueAndBoundaryGenerations() async throws {
        let values = ["0", "opaque-._:v2", " opaque value ", String(repeating: "é", count: 64)]
        for value in values {
            let executor = RecordingExecutor(try json(["generation": value]))
            let actual = try await client(executor).fetchDatasetGeneration(token: "fixture-token")
            #expect(Array(actual.utf8) == Array(value.utf8))
        }
    }

    @Test func fetchRejectsMalformedGenerationResponses() async throws {
        let invalid: [[String: Any]] = [
            [:], ["generation": NSNull()], ["generation": 0], ["generation": ""],
            ["generation": String(repeating: "x", count: 129)],
            ["generation": String(repeating: "é", count: 65)],
            ["generation": "a\r\nb"], ["generation": "a\u{0000}b"],
            ["generation": "a\u{007f}b"]
        ]
        for body in invalid {
            let executor = RecordingExecutor(try json(body))
            let api = client(executor)
            await expectDecodingFailure { _ = try await api.fetchDatasetGeneration(token: "fixture-token") }
            let requests = await executor.recordedRequests()
            #expect(requests.count == 1)
        }
    }

    @Test func resetUsesExactBodyAndDecodesTheReceipt() async throws {
        let executor = RecordingExecutor(try json(response()))
        let receipt = try await client(executor).resetDataset(
            expectedGeneration: "generation-1", requestID: "request-1", token: "fixture.raw.token")
        #expect(receipt.generation == "generation-2")
        #expect(receipt.requestID == "request-1")
        #expect(receipt.deletedTasks == 3)
        #expect(receipt.tombstonedLibrary == 4)
        let requests = await executor.recordedRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.absoluteString == "https://fixture.invalid/gsd-cloud/api/gsd/dataset/reset")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "fixture.raw.token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
        #expect(body == ["expected_generation": "generation-1", "request_id": "request-1"])
    }

    @Test func resetRejectsInvalidIdentifiersBeforeSending() async throws {
        let invalid = [
            "", String(repeating: "x", count: 129), String(repeating: "é", count: 65),
            "a\r\nb", "a\tb", "a\u{0000}b", "a\u{007f}b"
        ]
        for value in invalid {
            let executor = RecordingExecutor(try json(response()))
            let api = client(executor)
            await #expect(throws: DatasetProtocolError.invalidIdentifier(field: "expected_generation")) {
                _ = try await api.resetDataset(
                    expectedGeneration: value, requestID: "request-1", token: "fixture-token")
            }
            await #expect(throws: DatasetProtocolError.invalidIdentifier(field: "request_id")) {
                _ = try await api.resetDataset(
                    expectedGeneration: "0", requestID: value, token: "fixture-token")
            }
            let requests = await executor.recordedRequests()
            #expect(requests.isEmpty)
        }
    }

    @Test func resetPreservesBoundaryAndOpaqueRequestIdentifiers() async throws {
        let generation = String(repeating: "é", count: 64)
        let requestID = " " + String(repeating: "r", count: 126) + " "
        let executor = RecordingExecutor(try json(response(requestID: requestID, deletedTasks: 0, tombstonedLibrary: 0)))
        let receipt = try await client(executor).resetDataset(
            expectedGeneration: generation, requestID: requestID, token: "fixture-token")
        #expect(Array(receipt.requestID.utf8) == Array(requestID.utf8))
        #expect(receipt.deletedTasks == 0)
        #expect(receipt.tombstonedLibrary == 0)
        let requests = await executor.recordedRequests()
        let body = try JSONDecoder().decode([String: String].self, from: #require(requests.first?.httpBody))
        #expect(Array(try #require(body["expected_generation"]).utf8) == Array(generation.utf8))
        #expect(Array(try #require(body["request_id"]).utf8) == Array(requestID.utf8))
    }

    @Test func resetRejectsMalformedReceipts() async throws {
        var missingCount = response()
        missingCount.removeValue(forKey: "deleted_tasks")
        let invalid: [[String: Any]] = [
            [:], missingCount, response(generation: "generation-1"),
            response(generation: ""), response(generation: NSNull()),
            response(generation: String(repeating: "x", count: 129)),
            response(generation: "bad\nvalue"), response(requestID: ""),
            response(requestID: String(repeating: "r", count: 129)),
            response(requestID: "bad\u{007f}value"),
            response(deletedTasks: -1), response(tombstonedLibrary: -1),
            response(deletedTasks: 1.5), response(tombstonedLibrary: "2"),
            response(deletedTasks: NSNull())
        ]
        for body in invalid {
            let executor = RecordingExecutor(try json(body))
            let api = client(executor)
            await expectDecodingFailure {
                _ = try await api.resetDataset(
                    expectedGeneration: "generation-1", requestID: "request-1", token: "fixture-token")
            }
            let requests = await executor.recordedRequests()
            #expect(requests.count == 1)
        }
    }

    @Test func resetRequiresTheExactReturnedRequestIdentifierBytes() async throws {
        let pairs = [("request-1", "request-2"), ("e\u{0301}", "\u{00e9}")]
        for (sent, returned) in pairs {
            let executor = RecordingExecutor(try json(response(requestID: returned)))
            let api = client(executor)
            await expectDecodingFailure {
                _ = try await api.resetDataset(
                    expectedGeneration: "generation-1", requestID: sent, token: "fixture-token")
            }
        }
    }

    @Test func repeatedResetKeepsCallerIdentityAndReceiptUnchanged() async throws {
        let executor = RecordingExecutor(try json(response()))
        let api = client(executor)
        let first = try await api.resetDataset(
            expectedGeneration: "generation-1", requestID: "request-1", token: "fixture-token")
        let retry = try await api.resetDataset(
            expectedGeneration: "generation-1", requestID: "request-1", token: "fixture-token")
        #expect(first == retry)
        let requests = await executor.recordedRequests()
        #expect(requests.count == 2)
        for request in requests {
            let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
            #expect(body == ["expected_generation": "generation-1", "request_id": "request-1"])
        }
    }

    @Test func resetPreservesConflictEnvelopesWithoutRetry() async throws {
        for message in ["request_id_conflict", "dataset_generation_mismatch"] {
            let executor = RecordingExecutor(
                try json(["code": 409, "message": message, "data": [String: String]()]), status: 409)
            let api = client(executor)
            await #expect(throws: PocketBaseError.pocketBase(status: 409, message: message)) {
                _ = try await api.resetDataset(
                    expectedGeneration: "generation-1", requestID: "request-1", token: "fixture-token")
            }
            let requests = await executor.recordedRequests()
            #expect(requests.count == 1)
            #expect(requests.first?.url?.path == "/gsd-cloud/api/gsd/dataset/reset")
        }
    }

    @Test func missingDatasetRoutesFailWithoutLegacyFallback() async throws {
        let fetchExecutor = RecordingExecutor("missing", status: 404)
        let fetchAPI = client(fetchExecutor)
        await #expect(throws: PocketBaseError.http(status: 404, body: "missing")) {
            _ = try await fetchAPI.fetchDatasetGeneration(token: "fixture-token")
        }
        let resetExecutor = RecordingExecutor(
            #"{"code":404,"message":"route_not_found","data":{}}"#, status: 404)
        let resetAPI = client(resetExecutor)
        await #expect(throws: PocketBaseError.pocketBase(status: 404, message: "route_not_found")) {
            _ = try await resetAPI.resetDataset(
                expectedGeneration: "0", requestID: "request-1", token: "fixture-token")
        }
        let fetchRequests = await fetchExecutor.recordedRequests()
        let resetRequests = await resetExecutor.recordedRequests()
        #expect(fetchRequests.count == 1)
        #expect(resetRequests.count == 1)
    }

    @Test func createCarriesExactGenerationWithoutChangingTheTaskBody() async throws {
        let executor = RecordingExecutor(#"{"id":"record-1","task_id":"task-1"}"#)
        let value = try record()
        let recordID = try await client(executor).createTask(
            value, datasetGeneration: "generation-1", token: "fixture.raw.token")
        #expect(recordID == "record-1")
        let requests = await executor.recordedRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.path == "/gsd-cloud/api/collections/tasks/records")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "fixture.raw.token")
        #expect(request.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == "generation-1")
        let sent = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: #require(request.httpBody))
        #expect(sent == value)
    }

    @Test func existingCreateCallRemainsHeaderlessWhenNoGenerationIsSupplied() async throws {
        let executor = RecordingExecutor(#"{"id":"record-1","task_id":"task-1"}"#)
        _ = try await client(executor).createTask(try record(), token: "fixture-token")
        let requests = await executor.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == nil)
    }

    @Test func createRejectsInvalidGenerationBeforeSending() async throws {
        let invalid = [
            "", String(repeating: "x", count: 129), String(repeating: "é", count: 65),
            "a\r\nb", "a\tb", "a\u{0000}b", "a\u{007f}b"
        ]
        for generation in invalid {
            let executor = RecordingExecutor(#"{"id":"record-1","task_id":"task-1"}"#)
            let api = client(executor)
            let value = try record()
            await #expect(throws: DatasetProtocolError.invalidIdentifier(field: "generation")) {
                _ = try await api.createTask(
                    value, datasetGeneration: generation, token: "fixture-token")
            }
            let requests = await executor.recordedRequests()
            #expect(requests.isEmpty)
        }
    }

    @Test func createDoesNotRetryAStaleGenerationWithoutItsHeader() async throws {
        let executor = RecordingExecutor(
            #"{"code":409,"message":"dataset_generation_mismatch","data":{}}"#, status: 409)
        let api = client(executor)
        let value = try record()
        await #expect(throws: PocketBaseError.pocketBase(status: 409, message: "dataset_generation_mismatch")) {
            _ = try await api.createTask(
                value, datasetGeneration: "generation-old", token: "fixture-token")
        }
        let requests = await executor.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == "generation-old")
    }

    @Test func persistedReceiptRetainsValidatedFields() throws {
        let receipt = try DatasetResetReceipt(
            generation: "generation-2", requestID: "request-1", deletedTasks: 3, tombstonedLibrary: 4)
        let data = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(DatasetResetReceipt.self, from: data) == receipt)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["generation", "request_id", "deleted_tasks", "tombstoned_library"])
        #expect(throws: DatasetProtocolError.invalidIdentifier(field: "generation")) {
            try DatasetResetReceipt(generation: "", requestID: "request-1", deletedTasks: 0, tombstonedLibrary: 0)
        }
        #expect(throws: DatasetProtocolError.negativeResetCount(field: "deleted_tasks")) {
            try DatasetResetReceipt(generation: "generation-2", requestID: "request-1", deletedTasks: -1, tombstonedLibrary: 0)
        }
        #expect(throws: DatasetProtocolError.negativeResetCount(field: "tombstoned_library")) {
            try DatasetResetReceipt(generation: "generation-2", requestID: "request-1", deletedTasks: 0, tombstonedLibrary: -1)
        }
    }
}
