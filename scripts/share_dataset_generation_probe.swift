import Foundation
import GSDModel
import GSDWire
import GSDSnapshot

actor DatasetExecutor: RequestExecuting {
    private var requests: [URLRequest] = []
    private var generation = "server-generation-A"
    private var discoveryStatus = 200
    private var createStatus = 200
    private var failCreate = false
    private var holdDiscovery = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var afterDiscovery: (@Sendable () throws -> Void)?
    private let outbox: ShareOutboxStore?
    private var journalAtPost: [SharedCapture] = []

    init(directory: URL? = nil) {
        outbox = directory.map { ShareOutboxStore(directoryURL: $0) }
    }

    func configure(generation: String = "server-generation-A", discoveryStatus: Int = 200,
                   createStatus: Int = 200, failCreate: Bool = false,
                   holdDiscovery: Bool = false,
                   afterDiscovery: (@Sendable () throws -> Void)? = nil) {
        self.generation = generation
        self.discoveryStatus = discoveryStatus
        self.createStatus = createStatus
        self.failCreate = failCreate
        self.holdDiscovery = holdDiscovery
        self.afterDiscovery = afterDiscovery
    }

    func recorded() -> [URLRequest] { requests }
    func journalsObservedAtPost() -> [SharedCapture] { journalAtPost }

    func releaseDiscovery() {
        holdDiscovery = false
        continuation?.resume()
        continuation = nil
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else { throw ProbeFailure.invalidRequest }
        let status: Int
        let object: [String: Any]
        if request.httpMethod == "GET", url.path.hasSuffix("/api/gsd/dataset") {
            if holdDiscovery {
                // Deliberately ignores task cancellation until released: the production
                // caller must reject a late successful response before it can POST.
                await withCheckedContinuation { continuation = $0 }
            }
            try afterDiscovery?()
            status = discoveryStatus
            object = status == 200 ? ["generation": generation]
                : ["status": status, "message": "discovery_unavailable", "data": [:]]
        } else if request.httpMethod == "POST",
                  url.path.hasSuffix("/api/collections/tasks/records") {
            journalAtPost = outbox?.inFlightCaptures().map(\.capture) ?? []
            if failCreate { throw PocketBaseError.network("fixture ambiguous response") }
            status = createStatus
            guard let data = request.httpBody,
                  let sent = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let taskID = sent["task_id"] as? String else { throw ProbeFailure.invalidRequest }
            object = status == 200 ? ["id": "record-fixture", "task_id": taskID]
                : ["status": status, "message": "dataset_generation_mismatch", "data": [:]]
        } else {
            throw ProbeFailure.invalidRequest
        }
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: object), response)
    }
}

enum ProbeFailure: Error { case invalidRequest, missingCapture }

@MainActor final class ShareSubject {
    let directory: URL
    let outbox: ShareOutboxStore
    let executor: DatasetExecutor
    let scope: WatchAccountScope
    let publication: ShareScopePublicationStore
    let token: String
    let session: ShareCaptureSession

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = try SharedDatasetIdentityStore(directory: directory).loadOrCreate()
        scope = .account(userID: "generation-fixture-owner", datasetID: identity.datasetID)
        publication = ShareScopePublicationStore(directory: directory)
        try publication.publish(ShareScopePublication(scope: scope))
        outbox = ShareOutboxStore(directoryURL: directory)
        executor = DatasetExecutor(directory: directory)
        token = try ShareDatasetGenerationProbe.token()
        let frozenToken = token
        let transport = executor
        #if SHARE_DATASET_GENERATION
        session = ShareCaptureSession(outbox: outbox, directory: directory,
            credential: { .account(token: frozenToken, ownerID: "generation-fixture-owner") },
            push: { task, token, authorization in
                let push = ShareDatasetGenerationProbe.direct(transport, token: token)
                let outcome = await push.attempt(task, datasetGeneration: authorization.datasetGeneration) {
                    try await authorization.prepare($0)
                }
                if case .pushed(let id) = outcome { return id }
                return nil
            })
        #else
        session = ShareCaptureSession(outbox: outbox, directory: directory,
            credential: { .account(token: frozenToken, ownerID: "generation-fixture-owner") },
            push: { task, token in
                let outcome = await ShareDatasetGenerationProbe.direct(transport, token: token).attempt(task)
                if case .pushed(let id) = outcome { return id }
                return nil
            })
        #endif
    }

    func save(_ title: String) async throws -> ShareCaptureSession.SaveResult {
        try await session.save(SharedCapture(title: title, urls: [], urgent: false, important: true,
                                             tags: ["dataset"], capturedAt: Date(timeIntervalSince1970: 100)))
    }

    func blockOutbox() throws {
        try Data("owned failure fixture".utf8)
            .write(to: directory.appendingPathComponent(ShareOutboxStore.directoryName))
    }

    func unblockOutbox() throws {
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(ShareOutboxStore.directoryName))
    }
}

@main struct ShareDatasetGenerationProbe {
    static let base = "https://fixture.invalid/nested"
    static let expectedGeneration = "server-generation-A"
    @MainActor static var failures = 0

    static func token() throws -> String {
        // Requests and the independent exact-byte assertion must use one deterministic fixture.
        // Dictionary serialization order is not part of the JWT identity contract.
        let claims = try JSONSerialization.data(
            withJSONObject: ["id": "generation-fixture-owner", "exp": 4_000_000_000],
            options: [.sortedKeys])
        return "fixture." + claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            + ".signature"
    }

    static func direct(_ executor: DatasetExecutor, token: String) -> DirectTaskPush {
        DirectTaskPush(client: PocketBaseClient(baseURL: base, executor: executor),
                       token: { token }, deviceID: { "generation-fixture-device" },
                       defaultReminder: { 15 },
                       now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    static var task: GSDModel.Task {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return GSDModel.Task(id: "generation-direct-task", title: "Keep this capture",
                             description: "https://example.com", urgent: false, important: true,
                             createdAt: stamp, updatedAt: stamp, tags: ["dataset"])
    }

    static func attempt(_ executor: DatasetExecutor, bound: String? = nil) async throws -> DirectTaskPush.Outcome {
        let client = direct(executor, token: try token())
        #if SHARE_DATASET_GENERATION
        return await client.attempt(task, datasetGeneration: bound) { _ in }
        #else
        return await client.attempt(task)
        #endif
    }

    static func isFailure(_ outcome: DirectTaskPush.Outcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    static func serverGeneration(_ capture: SharedCapture?) -> String? {
        guard let capture,
              let data = try? JSONEncoder().encode(capture),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["serverDatasetGeneration"] as? String
    }

    static func methods(_ requests: [URLRequest], _ method: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method }
    }

    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed],
                                               options: [.sortedKeys])
        print("SHARE_DATASET_CHECK " + String(decoding: data, as: UTF8.self))
    }

    @MainActor static func waitForGET(_ executor: DatasetExecutor) async -> Bool {
        for _ in 0..<300 {
            if methods(await executor.recorded(), "GET").count == 1 { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor static func guardedCreate() async throws {
        let executor = DatasetExecutor()
        let outcome = try await attempt(executor)
        let requests = await executor.recorded()
        let gets = methods(requests, "GET"), posts = methods(requests, "POST")
        let body = posts.first?.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let bearer = try token()
        let independentFixtureTokensHaveStableBytes = try (0..<16).allSatisfy { _ in try token() == bearer }
        let components: [String: Bool] = [
            "independentFixtureTokensHaveStableBytes": independentFixtureTokensHaveStableBytes,
            "pushed": outcome == .pushed(recordID: "record-fixture"),
            "oneGET": gets.count == 1, "onePOST": posts.count == 1,
            "twoRequests": requests.count == 2, "GETFirst": requests.first?.httpMethod == "GET",
            "GETBase": gets.first?.url?.absoluteString == base + "/api/gsd/dataset",
            "POSTBase": posts.first?.url?.absoluteString == base + "/api/collections/tasks/records",
            "authorizationMatchesIndependentFixtureToken": requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == bearer
            },
            "generationHeader": posts.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == expectedGeneration,
            "taskID": body?["task_id"] as? String == task.id,
            "owner": body?["owner"] as? String == "generation-fixture-owner",
            "device": body?["device_id"] as? String == "generation-fixture-device",
            "title": body?["title"] as? String == task.title,
            "defaultReminder": body?["notify_before"] as? Int == 15,
            "requestsUseSameCredentialBytes": gets.first?.value(forHTTPHeaderField: "Authorization")
                == posts.first?.value(forHTTPHeaderField: "Authorization"),
            "recordedCredentialHasFixtureOwner": gets.first?.value(forHTTPHeaderField: "Authorization")
                .flatMap { JWT.userId($0) } == "generation-fixture-owner"
        ]
        let details = try JSONSerialization.data(withJSONObject: components, options: [.sortedKeys])
        print("SHARE_DATASET_DIAGNOSTIC " + String(decoding: details, as: UTF8.self))
        check("generation_get_and_create_use_same_base_bearer_and_payload",
              outcome == .pushed(recordID: "record-fixture") && gets.count == 1 && posts.count == 1
              && requests.count == 2 && requests.first?.httpMethod == "GET"
              && gets.first?.url?.absoluteString == base + "/api/gsd/dataset"
              && posts.first?.url?.absoluteString == base + "/api/collections/tasks/records"
              && requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == bearer }
              && posts.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == expectedGeneration
              && body?["task_id"] as? String == task.id
              && body?["owner"] as? String == "generation-fixture-owner"
              && body?["device_id"] as? String == "generation-fixture-device"
              && body?["title"] as? String == task.title && body?["notify_before"] as? Int == 15)
    }

    @MainActor static func failedDiscovery(root: URL) async throws {
        let subject = try ShareSubject(directory: root.appendingPathComponent("failed-discovery"))
        await subject.executor.configure(discoveryStatus: 503)
        let result = try await subject.save("Retain while offline")
        let requests = await subject.executor.recorded()
        let queued = subject.outbox.pending()
        check("failed_generation_discovery_holds_capture_without_post",
              result == .held && methods(requests, "GET").count == 1 && methods(requests, "POST").isEmpty
              && queued.count == 1 && queued.first?.capture.title == "Retain while offline"
              && queued.first?.capture.origin == subject.scope
              && serverGeneration(queued.first?.capture) == nil)
    }

    @MainActor static func mismatch() async throws {
        let executor = DatasetExecutor()
        await executor.configure(createStatus: 409)
        let outcome = try await attempt(executor)
        let requests = await executor.recorded()
        let posts = methods(requests, "POST")
        check("generation_conflict_never_retries_headerless",
              isFailure(outcome) && requests.count == 2 && methods(requests, "GET").count == 1
              && posts.count == 1
              && posts.first?.value(forHTTPHeaderField: "X-GSD-Dataset-Generation") == expectedGeneration)
    }

    @MainActor static func invalidatedDiscovery(root: URL) async throws {
        let subject = try ShareSubject(directory: root.appendingPathComponent("invalidated-discovery"))
        await subject.executor.configure(holdDiscovery: true)
        let operation = _Concurrency.Task { try await subject.save("Before reset admission") }
        let entered = await waitForGET(subject.executor)
        // Production account/reset admission invalidates publication synchronously,
        // before waiting for this extension's shared lease.
        try subject.publication.publish(ShareScopePublication(scope: nil))
        await subject.executor.releaseDiscovery()
        let result = try await operation.value
        let requests = await subject.executor.recorded()
        let queued = subject.outbox.pending()
        check("late_generation_after_scope_invalidation_cannot_post",
              entered && result == .held && methods(requests, "POST").isEmpty
              && queued.count == 1 && queued.first?.capture.origin == subject.scope
              && serverGeneration(queued.first?.capture) == nil)
    }

    @MainActor static func cancelledDiscovery(root: URL) async throws {
        let subject = try ShareSubject(directory: root.appendingPathComponent("cancelled-discovery"))
        await subject.executor.configure(holdDiscovery: true)
        let operation = _Concurrency.Task { try await subject.save("Cancelled discovery") }
        let entered = await waitForGET(subject.executor)
        operation.cancel()
        await subject.executor.releaseDiscovery()
        _ = try? await operation.value
        let requests = await subject.executor.recorded()
        let retained = subject.outbox.pending().map(\.capture)
            + subject.outbox.inFlightCaptures().map(\.capture)
        check("late_generation_after_cancellation_cannot_post",
              entered && methods(requests, "POST").isEmpty && retained.count == 1
              && retained.first?.title == "Cancelled discovery"
              && retained.first?.origin == subject.scope && serverGeneration(retained.first) == nil)
    }

    @MainActor static func durableBeforePost(root: URL) async throws {
        let subject = try ShareSubject(directory: root.appendingPathComponent("before-post"))
        let result = try await subject.save("Journal before POST")
        let seen = await subject.executor.journalsObservedAtPost()
        let queued = subject.outbox.pending()
        check("bound_generation_is_durable_before_first_post",
              result == .queued && seen.count == 1 && queued.count == 1
              && serverGeneration(seen.first) == expectedGeneration
              && serverGeneration(queued.first?.capture) == expectedGeneration
              && seen.first?.origin == subject.scope && seen.first?.taskID == queued.first?.capture.taskID
              && queued.first?.capture.remoteRecordID == "record-fixture"
              && subject.outbox.inFlightCaptures().isEmpty)
    }

    @MainActor static func editedRetry(root: URL) async throws {
        let subject = try ShareSubject(directory: root.appendingPathComponent("edited-retry"))
        try subject.blockOutbox()
        var firstFailed = false
        do { _ = try await subject.save("Original") } catch { firstFailed = true }
        let journal = subject.outbox.inFlightCaptures().first?.capture
        await subject.executor.configure(generation: "server-generation-B")
        try subject.unblockOutbox()
        let result = try await subject.save("Edited after failure")
        let requests = await subject.executor.recorded()
        let pending = subject.outbox.pending()
        check("edited_retry_retains_bound_generation_without_refetch_or_repost",
              firstFailed && result == .queued && methods(requests, "GET").count == 1
              && methods(requests, "POST").count == 1 && pending.count == 1
              && serverGeneration(journal) == expectedGeneration
              && serverGeneration(pending.first?.capture) == expectedGeneration
              && journal?.taskID == pending.first?.capture.taskID
              && pending.first?.capture.title == "Edited after failure"
              && pending.first?.capture.isEditedRetry == true
              && pending.first?.capture.remoteRecordID == nil)
    }

    @MainActor static func ambiguousRecovery(root: URL) async throws {
        let subject = try ShareSubject(directory: root.appendingPathComponent("ambiguous-recovery"))
        await subject.executor.configure(failCreate: true)
        try subject.blockOutbox()
        do { _ = try await subject.save("Retain ambiguous POST") } catch { }
        let original = subject.outbox.inFlightCaptures().first?.capture
        try subject.unblockOutbox()
        let lease = try await SharedMutationLease.acquire(directory: subject.directory, mode: .exclusive)
        try subject.outbox.recoverInFlight()
        lease.release()
        let recovered = subject.outbox.pending()
        let requests = await subject.executor.recorded()
        check("crash_journal_recovery_preserves_original_generation_and_identity",
              methods(requests, "GET").count == 1 && methods(requests, "POST").count == 1
              && recovered.count == 1 && serverGeneration(original) == expectedGeneration
              && serverGeneration(recovered.first?.capture) == expectedGeneration
              && original?.taskID == recovered.first?.capture.taskID
              && recovered.first?.capture.origin == subject.scope
              && recovered.first?.capture.remoteRecordID == nil
              && subject.outbox.inFlightCaptures().isEmpty)
    }

    @MainActor static func failedBinding(root: URL) async throws {
        let subject = try ShareSubject(directory: root.appendingPathComponent("failed-binding"))
        let inFlight = subject.directory.appendingPathComponent(ShareOutboxStore.inFlightDirectoryName)
        let retained = subject.directory.appendingPathComponent("retained-original-journal")
        await subject.executor.configure(afterDiscovery: {
            try FileManager.default.moveItem(at: inFlight, to: retained)
            try Data("owned binding fault".utf8).write(to: inFlight)
        })
        _ = try await subject.save("No unjournaled POST")
        let requests = await subject.executor.recorded()
        check("failed_generation_journal_write_prevents_post",
              methods(requests, "GET").count == 1 && methods(requests, "POST").isEmpty
              && FileManager.default.fileExists(atPath: retained.path)
              && subject.outbox.pending().count == 1)
    }

    @MainActor static func fixedGeneration() async throws {
        let executor = DatasetExecutor()
        await executor.configure(generation: "server-generation-B", createStatus: 409)
        let outcome = try await attempt(executor, bound: expectedGeneration)
        let requests = await executor.recorded()
        check("bound_attempt_never_refreshes_generation_after_server_reset",
              isFailure(outcome) && requests.count == 1 && methods(requests, "GET").isEmpty
              && methods(requests, "POST").first?.value(
                    forHTTPHeaderField: "X-GSD-Dataset-Generation") == expectedGeneration)
    }

    @MainActor static func invalidGeneration() async throws {
        var allRefused = true
        for value in ["", String(repeating: "x", count: 129), "generation\r\nother"] {
            let executor = DatasetExecutor()
            await executor.configure(generation: value)
            let outcome = try await attempt(executor)
            let requests = await executor.recorded()
            allRefused = allRefused && isFailure(outcome)
                && methods(requests, "GET").count == 1 && methods(requests, "POST").isEmpty
        }
        check("invalid_server_generations_never_reach_create", allRefused)
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GSDShareDataset-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await guardedCreate()
            try await failedDiscovery(root: root)
            try await mismatch()
            try await invalidatedDiscovery(root: root)
            try await cancelledDiscovery(root: root)
            try await durableBeforePost(root: root)
            try await editedRetry(root: root)
            try await ambiguousRecovery(root: root)
            try await failedBinding(root: root)
            try await fixedGeneration()
            try await invalidGeneration()
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("SHARE_DATASET_ERROR " + String(describing: error))
            exit(2)
        }
    }
}
