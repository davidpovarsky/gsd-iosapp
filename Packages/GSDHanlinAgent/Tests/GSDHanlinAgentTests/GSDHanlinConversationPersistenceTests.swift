import Foundation
import XCTest
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
}
