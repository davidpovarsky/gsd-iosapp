import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Models the production library route: publishing a live Trash item removes the
/// active server task. This makes an ordering regression observable as data loss.
private actor LibraryOrderingServer: RequestExecuting {
    let account: AccountServer
    private let failResurrectionListing: Bool
    private var taskListings = 0
    private(set) var destructiveLibraryWrites: [String] = []
    private(set) var libraryWrites = 0

    init(account: AccountServer, failResurrectionListing: Bool) {
        self.account = account
        self.failResurrectionListing = failResurrectionListing
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let method = request.httpMethod ?? "GET"
        if url.path == "/api/collections/gsd_library/records" {
            return (Data(#"{"items":[],"totalPages":1,"totalItems":0}"#.utf8), response(url, 200))
        }
        if method == "PUT", url.path.hasPrefix("/api/gsd/library/") {
            libraryWrites += 1
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            if body["deleted"] as? Bool == false {
                destructiveLibraryWrites.append(url.lastPathComponent)
                var deletion = URLRequest(url: URL(string: "https://ordering.test/api/gsd/tasks/rec_\(url.lastPathComponent)")!)
                deletion.httpMethod = "DELETE"
                _ = try await account.execute(deletion)
            }
            return (Data(), response(url, 204))
        }
        if method == "GET", url.path.hasSuffix("/records") {
            taskListings += 1
            if failResurrectionListing, taskListings == 2 {
                return (Data(#"{"message":"temporarily unavailable"}"#.utf8), response(url, 503))
            }
        }
        return try await account.execute(request)
    }

    private func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

@MainActor
struct CloudLibraryOrderingTests {
    nonisolated private static let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    nonisolated private static let now = WireDate.parse("2026-11-07T12:00:00.000Z")!

    private struct Stack {
        let account: AccountServer
        let executor: LibraryOrderingServer
        let repo: GRDBTaskRepository
        let trash: GRDBTrashRepository
        let cursor: SyncCursor
        let engine: SyncEngine
    }

    private func makeStack(failResurrectionListing: Bool = false) async throws -> Stack {
        let db = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "cloud-library-ordering-\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: WireDate.parse("2026-11-02T00:00:00.000Z"))
        cursor.clear() // An explicit sign-out keeps the sync contract version.
        let repo = GRDBTaskRepository(db), queue = GRDBSyncQueueRepository(db)
        let trash = GRDBTrashRepository(db), archive = GRDBArchiveRepository(db)
        let account = AccountServer()
        let executor = LibraryOrderingServer(account: account, failResurrectionListing: failResurrectionListing)
        let engine = SyncEngine(
            client: PocketBaseClient(baseURL: "https://ordering.test", executor: executor),
            tasks: repo, queue: queue, tombstones: GRDBTombstoneRepository(db),
            cursor: cursor, deviceId: "ios", tokenProvider: { Self.token }, rawToken: { Self.token },
            now: { Self.now }, throttleMs: 0, library: GRDBCloudLibraryRepository(db))
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: archive, trashRepository: trash, defaults: defaults,
                              clock: { Self.now }, syncQueue: queue)
        let task = GSDModel.Task(id: "t1", title: "Call the venue", urgent: true, important: true,
                                createdAt: WireDate.parse("2026-10-01T10:00:00.000Z")!,
                                updatedAt: WireDate.parse("2026-11-01T10:00:00.000Z")!)
        await account.add(task.id)
        try await repo.upsert(task)
        try await store.delete(task)
        await engine.beginSignIn()
        return Stack(account: account, executor: executor, repo: repo, trash: trash, cursor: cursor, engine: engine)
    }

    @Test("signed-out Trash is restored before the cloud library can publish it")
    func restoresBeforePublishingTrash() async throws {
        let stack = try await makeStack()
        let result = await stack.engine.sync(trigger: .signIn)
        #expect(result.error == nil)
        #expect(await stack.account.has("t1"))
        #expect(try await stack.repo.fetch(id: "t1") != nil)
        #expect(try await stack.trash.fetchAll().isEmpty)
        #expect(stack.cursor.rememberedDeletes().isEmpty)
        #expect(await stack.executor.libraryWrites == 0)
    }

    @Test("a transient resurrection failure cannot publish the remembered Trash")
    func failedResurrectionDefersDestructiveLibraryWrite() async throws {
        let stack = try await makeStack(failResurrectionListing: true)
        let first = await stack.engine.sync(trigger: .signIn)
        #expect(first.error == nil)
        #expect(await stack.account.has("t1"))
        #expect(try await stack.repo.fetch(id: "t1") == nil)
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
        #expect(await stack.executor.libraryWrites == 0)

        let retry = await stack.engine.sync(trigger: .foreground)
        #expect(retry.error == nil)
        #expect(await stack.account.has("t1"))
        #expect(try await stack.repo.fetch(id: "t1") != nil)
        #expect(try await stack.trash.fetchAll().isEmpty)
        #expect(stack.cursor.rememberedDeletes().isEmpty)
        #expect(await stack.executor.destructiveLibraryWrites.isEmpty)
    }
}
