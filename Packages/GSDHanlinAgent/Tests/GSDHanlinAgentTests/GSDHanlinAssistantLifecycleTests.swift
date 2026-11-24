import Foundation
import XCTest
import GSDStore
import HanlinAgentCore
import HanlinChatCore
import HanlinHostContracts
@testable import GSDHanlinAgent

@MainActor
final class GSDHanlinAssistantLifecycleTests: XCTestCase {
    func testCancelledLoadCannotFinishOrFailTheNextRequest() async throws {
        let database = try AppDatabase.inMemory()
        let tasks = TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            trashRepository: GRDBTrashRepository(database))
        let conversations = SuspendedConversationStore()
        let conversationID = UUID()
        let state = GSDHanlinAssistantState(store: tasks, conversationID: conversationID) {
            configuration, authorizer in
            let namespace = try HanlinConversationNamespace(
                app: "gsd", account: "fixture", workspace: "local", space: "tasks")
            let context = HanlinHostContext(
                namespace: namespace, sceneID: UUID(), generation: UUID())
            let identity = HanlinHostSession(conversationID: conversationID, context: context)
            let host = GSDHanlinHost(store: tasks, context: context, writeAuthorizer: authorizer)
            let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { _ in
                XCTFail("Cancelled storage preflight must never reach the provider")
                throw URLError(.cancelled)
            })
            return GSDHanlinAgentBundle(host: host, agent: HanlinAgentSession(
                identity: identity, host: host, engine: engine, store: conversations), identity: identity)
        }
        let first = _Concurrency.Task { @MainActor in
            await state.send("First", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                             credential: "fixture-key", provider: "OpenAI")
        }
        await conversations.waitForLoad(1)
        let cancellation = state.cancelCurrentRequest()
        let second = _Concurrency.Task { @MainActor in
            await state.send("Second", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                             credential: "fixture-key", provider: "OpenAI")
        }
        await conversations.waitForLoad(2)
        await cancellation.value
        await conversations.resumeLoad(1)
        await first.value

        XCTAssertTrue(state.isRunning, "Late completion must not clear the second run")
        XCTAssertNil(state.errorMessage, "A cancelled request must not publish a failure")
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.messages.filter { $0.role == .user }.map(\.text), ["First", "Second"])
        XCTAssertFalse(state.messages.contains { $0.text == "The AI request failed." })

        await state.cancel()
        await conversations.resumeLoad(2)
        await second.value
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.errorMessage)
    }

    func testStaleApprovalActionsCannotResolveTheNextRequest() async throws {
        let database = try AppDatabase.inMemory()
        let tasks = TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            trashRepository: GRDBTrashRepository(database))
        let conversations = SuspendedConversationStore()
        let conversationID = UUID()
        var authorizers: [GSDHanlinHost.WriteAuthorizer] = []
        let state = GSDHanlinAssistantState(store: tasks, conversationID: conversationID) {
            configuration, authorizer in
            authorizers.append(authorizer)
            let namespace = try HanlinConversationNamespace(
                app: "gsd", account: "fixture", workspace: "local", space: "tasks")
            let context = HanlinHostContext(
                namespace: namespace, sceneID: UUID(), generation: UUID())
            let identity = HanlinHostSession(conversationID: conversationID, context: context)
            let host = GSDHanlinHost(store: tasks, context: context, writeAuthorizer: authorizer)
            let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { _ in
                XCTFail("Approval ownership checks must not reach the provider")
                throw URLError(.cancelled)
            })
            return GSDHanlinAgentBundle(host: host, agent: HanlinAgentSession(
                identity: identity, host: host, engine: engine, store: conversations), identity: identity)
        }
        defer {
            let cleanup = state.cancelCurrentRequest()
            _Concurrency.Task { @MainActor in
                await cleanup.value
                await conversations.resumeAllLoads()
            }
        }

        let first = _Concurrency.Task { @MainActor in
            await state.send("First", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                             credential: "fixture-key", provider: "OpenAI")
        }
        await conversations.waitForLoad(1)
        let firstAuthorizer = try XCTUnwrap(authorizers.first)
        let firstAuthorization = _Concurrency.Task { @MainActor in
            await firstAuthorizer(.init(tool: "create_task", taskIDs: [], description: "First change"))
        }
        let firstApprovalID = try await waitForApproval(in: state)
        let staleAllow = { @MainActor in
            state.resolveApproval(true, approvalID: firstApprovalID)
        }
        let staleDismiss = { @MainActor in
            state.resolveApproval(false, approvalID: firstApprovalID)
        }

        // Cancellation must also revoke an Allow result before the waiting host resumes.
        staleAllow()
        let cancellation = state.cancelCurrentRequest()
        let firstAllowed = await firstAuthorization.value
        XCTAssertFalse(firstAllowed)
        await cancellation.value

        let second = _Concurrency.Task { @MainActor in
            await state.send("Second", modelID: "fixture", endpoint: "https://fixture.invalid/v1",
                             credential: "fixture-key", provider: "OpenAI")
        }
        await conversations.waitForLoad(2)
        let secondAuthorizer = try XCTUnwrap(authorizers.last)
        let secondAuthorization = _Concurrency.Task { @MainActor in
            await secondAuthorizer(.init(tool: "delete_task", taskIDs: ["fixture"], description: "Second change"))
        }
        let secondApprovalID = try await waitForApproval(in: state)
        XCTAssertNotEqual(firstApprovalID, secondApprovalID)

        staleAllow()
        XCTAssertEqual(state.pendingApprovalID, secondApprovalID)
        staleDismiss()
        XCTAssertEqual(state.pendingApprovalID, secondApprovalID)
        XCTAssertEqual(state.pendingApproval?.description, "Second change")
        let staleAuthorizerAllowed = await firstAuthorizer(
            .init(tool: "create_task", taskIDs: [], description: "Late first change"))
        XCTAssertFalse(staleAuthorizerAllowed)
        XCTAssertEqual(state.pendingApprovalID, secondApprovalID)

        state.resolveApproval(true, approvalID: secondApprovalID)
        let secondAllowed = await secondAuthorization.value
        XCTAssertTrue(secondAllowed)
        XCTAssertNil(state.pendingApproval)
        XCTAssertNil(state.pendingApprovalID)

        await state.cancel()
        await conversations.resumeAllLoads()
        await first.value
        await second.value
    }

    private func waitForApproval(in state: GSDHanlinAssistantState) async throws -> UUID {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while state.pendingApprovalID == nil, ContinuousClock.now < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(1))
        }
        return try XCTUnwrap(state.pendingApprovalID, "The live request did not present its approval")
    }
}

private actor SuspendedConversationStore: HanlinConversationStore {
    private var count = 0
    private var loads: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(_ id: UUID, namespace: HanlinConversationNamespace) async throws -> HanlinConversationRecord? {
        count += 1
        let current = count
        let ready = observers.filter { $0.0 <= count }
        observers.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { loads[current] = $0 }
        return nil
    }

    func waitForLoad(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { observers.append((expected, $0)) }
    }

    func resumeLoad(_ number: Int) {
        loads.removeValue(forKey: number)?.resume()
    }

    func resumeAllLoads() {
        let pending = loads.values
        loads.removeAll()
        pending.forEach { $0.resume() }
    }

    func save(_ record: HanlinConversationRecord, replacing revision: UInt64?) throws {
        throw HanlinHostError.storeConflict
    }

    func delete(_ id: UUID, namespace: HanlinConversationNamespace, replacing revision: UInt64) throws {
        throw HanlinHostError.storeConflict
    }
}
