import Foundation
import Synchronization
import XCTest
import GSDModel
import HanlinAgentCore
import HanlinChatCore
import GSDStore
import HanlinHostContracts
import HanlinPersistenceAdapters
@testable import GSDHanlinAgent

@MainActor
final class GSDHanlinConversationPersistenceTests: XCTestCase {
    func testReopeningRestoresUserAndAssistantRolesWithoutExecutingTools() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = GSDHanlinConversationScope(
            gsdAccountID: "gsd-account-a", provider: "ChatGPT", providerAccountID: "registration-a")
        let privateStore = try HanlinPrivateConversationStore(directory: directory)
        let history = GSDHanlinConversationHistory(scope: scope, store: privateStore, directory: directory)
        let owner = UUID()
        _ = try await history.activate(owner: owner)
        let expected: [GSDHanlinMessage] = [
            .init(role: .user, text: "Remember this plan"),
            .init(role: .assistant, text: "Here is the saved plan"),
            .init(role: .status, text: "Tool completed: create_task")
        ]
        try await history.save(.init(messages: expected), owner: owner).value

        let database = try AppDatabase.inMemory()
        let tasks = TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            trashRepository: GRDBTrashRepository(database))
        let reopened = try GSDHanlinAssistantState(
            store: tasks, scope: scope, conversationDirectory: directory)
        await reopened.restoreConversation()

        XCTAssertEqual(reopened.messages, expected)
        XCTAssertFalse(reopened.isRunning)
        XCTAssertNil(reopened.pendingApproval)
        XCTAssertNil(reopened.pendingApprovalID)
        let allTasks = try await tasks.fetchAllTasks()
        XCTAssertTrue(allTasks.isEmpty, "Restoring display history must never execute a saved tool")
    }

    func testCloudAndProviderAccountsRemainIsolatedAndLegacyRecordsArePreserved() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = scope(gsd: "cloud-a", provider: "ChatGPT", account: "registration-a")
        XCTAssertEqual(scope, self.scope(gsd: "cloud-a", provider: "ChatGPT", account: "registration-a"))
        let alternatives = [
            self.scope(gsd: "cloud-b", provider: "ChatGPT", account: "registration-a"),
            self.scope(gsd: "cloud-a", provider: "ChatGPT", account: "registration-b"),
            self.scope(gsd: "cloud-a", provider: "OpenAI", account: "registration-a"),
            self.scope(gsd: nil, provider: "ChatGPT", account: "registration-a"),
            self.scope(gsd: "cloud-a", provider: "ChatGPT", account: nil)
        ]
        XCTAssertEqual(Set(alternatives + [scope]).count, 6)
        XCTAssertFalse(scope.accountID.contains("cloud-a"))
        let expected = GSDHanlinConversationSnapshot(messages: [.init(role: .user, text: "Account A only")])
        try await seed(expected, scope: scope, directory: directory)
        let store = try HanlinPrivateConversationStore(directory: directory)
        let legacyNamespace = try HanlinConversationNamespace(
            app: "gsd", account: "device-local", workspace: "local", space: "tasks")
        let legacyID = UUID()
        try await store.save(.init(namespace: legacyNamespace, conversationID: legacyID, revision: 0,
            entries: [.init(runID: UUID(), step: 0, sequence: 0, payload: .text("Unknown legacy owner"))]),
            replacing: nil)
        let legacyBefore = try await store.load(legacyID, namespace: legacyNamespace)

        for other in alternatives {
            let reopened = try GSDHanlinAssistantState(
                store: fixture(), scope: other, conversationDirectory: directory)
            await reopened.restoreConversation()
            XCTAssertTrue(reopened.messages.isEmpty)
            XCTAssertTrue(reopened.isConversationReady)
        }
        let same = try GSDHanlinAssistantState(store: fixture(), scope: scope, conversationDirectory: directory)
        await same.restoreConversation()
        XCTAssertEqual(same.messages, expected.messages)
        let legacyAfter = try await store.load(legacyID, namespace: legacyNamespace)
        XCTAssertEqual(legacyAfter, legacyBefore, "An unknown legacy owner must never be assigned to a personal account")
    }

    func testNewOwnerRejectsLateWritesFromDismissedConversation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try GSDHanlinConversationHistoryRegistry.history(
            scope: scope(), directory: directory)
        let oldOwner = UUID()
        _ = try await history.activate(owner: oldOwner)
        let first = GSDHanlinConversationSnapshot(messages: [.init(role: .user, text: "Before reopening")])
        let queued = history.save(first, owner: oldOwner)
        let currentOwner = UUID()
        let restored = try await history.activate(owner: currentOwner)
        try await queued.value
        XCTAssertEqual(restored, first)

        let current = GSDHanlinConversationSnapshot(messages: [.init(role: .user, text: "Current conversation")])
        try await history.save(current, owner: currentOwner).value
        do {
            try await history.save(.init(messages: [.init(role: .user, text: "Stale completion")]),
                                   owner: oldOwner).value
            XCTFail("The dismissed owner must not overwrite the reopened conversation")
        } catch is CancellationError { }
        let reopened = try await history.activate(owner: UUID())
        XCTAssertEqual(reopened, current)
    }

    func testRestoredWorkspaceRequiresCurrentTaskIDsWithoutChangingTasks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = try fixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = GSDModel.Task(id: "current-task", title: "Current", urgent: false, important: true,
                                 createdAt: now, updatedAt: now)
        try await tasks.create(task)
        let scope = scope()
        let request = GSDTaskWorkspaceRequest(presentation: .network, title: "Saved view", taskIDs: [task.id])
        let messages: [GSDHanlinMessage] = [.init(role: .assistant, text: "Your task workspace")]
        try await seed(.init(messages: messages, workspace: request), scope: scope, directory: directory)
        let restored = try GSDHanlinAssistantState(store: tasks, scope: scope, conversationDirectory: directory)
        await restored.restoreConversation()
        XCTAssertEqual(restored.workspace, request)
        let afterRestore = try await tasks.fetchAllTasks()
        XCTAssertEqual(afterRestore, [task])

        // A local reset or a synced deletion can remove the IDs while the same account's history remains.
        let emptyTasks = try fixture()
        let reopened = try GSDHanlinAssistantState(store: emptyTasks, scope: scope, conversationDirectory: directory)
        await reopened.restoreConversation()
        XCTAssertEqual(reopened.messages, messages)
        XCTAssertNil(reopened.workspace)
        let afterMissingRestore = try await emptyTasks.fetchAllTasks()
        XCTAssertTrue(afterMissingRestore.isEmpty)
        XCTAssertNil(reopened.pendingApproval)
    }

    func testUnrecognizedDisplayRecordIsPreservedAndCannotStartAProviderRequest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = scope()
        let store = try HanlinPrivateConversationStore(directory: directory)
        let namespace = try scope.displayNamespace
        try await store.save(.init(namespace: namespace, conversationID: scope.conversationID, revision: 0,
            entries: [.init(runID: UUID(), step: 0, sequence: 0, payload: .text("future format"))]),
            replacing: nil)
        let before = try await store.load(scope.conversationID, namespace: namespace)
        let state = try GSDHanlinAssistantState(store: fixture(), scope: scope, conversationDirectory: directory) {
            _, _ in
            XCTFail("An unreadable conversation must not be overwritten or sent to a provider")
            throw URLError(.cancelled)
        }
        await state.restoreConversation()
        XCTAssertFalse(state.isConversationReady)
        XCTAssertNotNil(state.errorMessage)
        await state.send("Do not overwrite", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                         credential: "fixture-key", provider: "OpenAI")
        XCTAssertTrue(state.messages.isEmpty)
        let after = try await store.load(scope.conversationID, namespace: namespace)
        XCTAssertEqual(after, before)
    }

    func testStreamingDeltasAdvanceScrollRevisionAndCancellationPersistsPartialReply() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = try fixture()
        let scope = scope()
        let firstChunk = sse(text: "First")
        let secondChunk = sse(text: " second")
        let pipe = Mutex<AsyncThrowingStream<Data, Error>.Continuation?>(nil)
        let state = try GSDHanlinAssistantState(store: tasks, scope: scope, conversationDirectory: directory) {
            configuration, authorizer in
            let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
                .init(body: .stream(AsyncThrowingStream { continuation in
                    pipe.withLock { $0 = continuation }
                    continuation.yield(firstChunk)
                }), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
            })
            return try self.bundle(tasks: tasks, scope: scope, directory: directory,
                                   engine: engine, authorizer: authorizer)
        }
        await state.restoreConversation()
        let sending = _Concurrency.Task { @MainActor in
            await state.send("A streamed answer", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                             credential: "fixture-key", provider: "OpenAI")
        }
        try await eventually { state.messages.last?.text == "First" }
        let count = state.messages.count
        let revision = state.transcriptRevision
        pipe.withLock { $0?.yield(secondChunk) }
        try await eventually { state.messages.last?.text == "First second" }
        XCTAssertEqual(state.messages.count, count, "A delta modifies the existing bubble")
        XCTAssertGreaterThan(state.transcriptRevision, revision, "The UI must observe deltas, not only message count")
        let cancellation = state.cancelCurrentRequest()
        let followupResponse = sse(text: "After cancellation") + sseFinish()
        let reopened = try GSDHanlinAssistantState(store: tasks, scope: scope, conversationDirectory: directory) {
            configuration, authorizer in
            let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
                .init(body: .data(followupResponse), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
            })
            return try self.bundle(tasks: tasks, scope: scope, directory: directory,
                                   engine: engine, authorizer: authorizer)
        }
        // Reopen and send immediately, before joining the cancelled consumer or its cleanup.
        await reopened.restoreConversation()
        XCTAssertEqual(reopened.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(reopened.messages.map(\.text), ["A streamed answer", "First second"])
        XCTAssertFalse(reopened.isRunning)
        XCTAssertNil(reopened.pendingApproval)
        XCTAssertNil(reopened.pendingApprovalID)
        await reopened.send("Continue immediately", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                            credential: "fixture-key", provider: "OpenAI")
        XCTAssertNil(reopened.errorMessage, "The stable SDK journal must not conflict after cancellation")
        XCTAssertNil(reopened.failure)
        XCTAssertEqual(reopened.messages.last?.text, "After cancellation")
        await cancellation.value
        pipe.withLock { $0?.finish() }
        await sending.value
    }

    func testNextProviderTurnReceivesRestoredRolesAndExcludesDisplayStatus() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = scope()
        let prior: [GSDHanlinMessage] = [
            .init(role: .user, text: "Prior question"),
            .init(role: .assistant, text: "Prior answer"),
            .init(role: .status, text: "Tool completed: create_task")
        ]
        try await seed(.init(messages: prior), scope: scope, directory: directory)
        let tasks = try fixture()
        let capturedBody = Mutex<Data?>(nil)
        let response = sse(text: "Continued") + sseFinish()
        let state = try GSDHanlinAssistantState(store: tasks, scope: scope, conversationDirectory: directory) {
            configuration, authorizer in
            let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
                capturedBody.withLock { $0 = request.httpBody }
                return .init(body: .data(response), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
            })
            return try self.bundle(tasks: tasks, scope: scope, directory: directory,
                                   engine: engine, authorizer: authorizer)
        }
        await state.send("Follow up", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                         credential: "fixture-key", provider: "OpenAI")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.messages.last?.text, "Continued")
        let bytes = try XCTUnwrap(capturedBody.withLock { $0 })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            .filter { ["user", "assistant"].contains($0["role"] as? String ?? "") }
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
        let encoded = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(encoded.contains("Prior question"))
        XCTAssertTrue(encoded.contains("Prior answer"))
        XCTAssertTrue(encoded.contains("Follow up"))
        XCTAssertFalse(encoded.contains("Tool completed: create_task"))
        let reopened = try GSDHanlinAssistantState(store: tasks, scope: scope, conversationDirectory: directory)
        await reopened.restoreConversation()
        XCTAssertEqual(reopened.messages, state.messages)
    }

    func testReopenedConversationCannotApproveAnOlderOwnersWrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = try fixture()
        let scope = scope()
        let chunk = sse(text: "Waiting")
        let pipe = Mutex<AsyncThrowingStream<Data, Error>.Continuation?>(nil)
        var capturedAuthorizer: GSDHanlinHost.WriteAuthorizer?
        let state = try GSDHanlinAssistantState(store: tasks, scope: scope, conversationDirectory: directory) {
            configuration, authorizer in
            capturedAuthorizer = authorizer
            let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
                .init(body: .stream(AsyncThrowingStream { continuation in
                    pipe.withLock { $0 = continuation }
                    continuation.yield(chunk)
                }), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
            })
            return try self.bundle(tasks: tasks, scope: scope, directory: directory,
                                   engine: engine, authorizer: authorizer)
        }
        let sending = _Concurrency.Task { @MainActor in
            await state.send("First sheet", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                             credential: "fixture-key", provider: "OpenAI")
        }
        try await eventually { capturedAuthorizer != nil && state.messages.last?.text == "Waiting" }
        let authorize = try XCTUnwrap(capturedAuthorizer)
        let pending = _Concurrency.Task { @MainActor in
            await authorize(.init(tool: "create_task", taskIDs: [], description: "Older sheet change"))
        }
        try await eventually { state.pendingApprovalID != nil }
        let oldApproval = try XCTUnwrap(state.pendingApprovalID)
        let reopened = try GSDHanlinAssistantState(store: tasks, scope: scope, conversationDirectory: directory)
        await reopened.restoreConversation()
        state.resolveApproval(true, approvalID: oldApproval)
        let allowed = await pending.value
        XCTAssertFalse(allowed, "A live write grant cannot move to a new conversation owner")
        XCTAssertNil(reopened.pendingApproval)
        await state.cancel()
        pipe.withLock { $0?.finish() }
        await sending.value
        let allTasks = try await tasks.fetchAllTasks()
        XCTAssertTrue(allTasks.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    private func scope(gsd: String? = "cloud", provider: String = "OpenAI",
                       account: String? = "https://fixture.invalid/v1") -> GSDHanlinConversationScope {
        .init(gsdAccountID: gsd, provider: provider, providerAccountID: account)
    }

    private func fixture() throws -> TaskStore {
        let database = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(database),
                         smartViewRepository: GRDBSmartViewRepository(database),
                         archiveRepository: GRDBArchiveRepository(database),
                         trashRepository: GRDBTrashRepository(database))
    }

    private func seed(_ snapshot: GSDHanlinConversationSnapshot, scope: GSDHanlinConversationScope,
                      directory: URL) async throws {
        let history = try GSDHanlinConversationHistoryRegistry.history(scope: scope, directory: directory)
        let owner = UUID()
        _ = try await history.activate(owner: owner)
        try await history.save(snapshot, owner: owner).value
    }

    private func bundle(tasks: TaskStore, scope: GSDHanlinConversationScope, directory: URL,
                        engine: HanlinAISDKAgentEngine,
                        authorizer: @escaping GSDHanlinHost.WriteAuthorizer) throws -> GSDHanlinAgentBundle {
        let namespace = try HanlinConversationNamespace(
            app: "gsd", account: scope.accountID, workspace: "local", space: "tasks")
        let context = HanlinHostContext(namespace: namespace, sceneID: UUID(), generation: UUID())
        let identity = HanlinHostSession(conversationID: scope.conversationID, context: context)
        let host = GSDHanlinHost(store: tasks, context: context, writeAuthorizer: authorizer)
        let history = try GSDHanlinConversationHistoryRegistry.history(scope: scope, directory: directory)
        return GSDHanlinAgentBundle(host: host, agent: HanlinAgentSession(
            identity: identity, host: host, engine: engine, store: history.store), identity: identity)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), "The controlled stream did not reach its expected state")
    }

    private func sse(text: String) -> Data {
        // These are provider response bytes only; the original SDK parses and emits each delta.
        let event: [String: Any] = [
            "id": "history-fixture", "object": "chat.completion.chunk", "created": 0, "model": "fixture",
            "choices": [["index": 0, "delta": ["role": "assistant", "content": text], "finish_reason": NSNull()]]
        ]
        let bytes = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        return Data(("data: " + String(decoding: bytes, as: UTF8.self) + "\n\n").utf8)
    }

    private func sseFinish() -> Data {
        Data(#"data: {"id":"history-fixture","object":"chat.completion.chunk","created":0,"model":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#.utf8)
            + Data("\n\ndata: [DONE]\n\n".utf8)
    }
}
