import Foundation
import XCTest
import GSDStore
@testable import GSDHanlinAgent

@MainActor
final class GSDRemoteBridgeApprovalTests: XCTestCase {
    func testOldDialogCannotResolveNewApprovalAndStopRevokesAResumedGrant() async throws {
        let database = try AppDatabase.inMemory()
        let tasks = TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            trashRepository: GRDBTrashRepository(database))
        let bridge = GSDRemoteBridgeState(store: tasks)
        let first = _Concurrency.Task { @MainActor in
            await bridge.awaitApproval(.init(tool: "create_task", taskIDs: [], description: "First"))
        }
        let oldID = try await approvalID(bridge)
        bridge.stopPolling()
        let firstAllowed = await first.value
        XCTAssertFalse(firstAllowed)

        let second = _Concurrency.Task { @MainActor in
            await bridge.awaitApproval(.init(tool: "delete_task", taskIDs: ["fixture"], description: "Second"))
        }
        let currentID = try await approvalID(bridge)
        XCTAssertNotEqual(oldID, currentID)
        bridge.resolveApproval(true, approvalID: oldID)
        bridge.resolveApproval(false, approvalID: oldID)
        XCTAssertEqual(bridge.pendingApprovalID, currentID)
        XCTAssertEqual(bridge.pendingApproval?.description, "Second")

        bridge.resolveApproval(true, approvalID: currentID)
        bridge.stopPolling()
        let secondAllowed = await second.value
        XCTAssertFalse(secondAllowed, "Stopping the bridge must revoke a grant before its suspended caller resumes")
        XCTAssertNil(bridge.pendingApprovalID)
    }

    private func approvalID(_ bridge: GSDRemoteBridgeState) async throws -> UUID {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while bridge.pendingApprovalID == nil, ContinuousClock.now < deadline {
            await _Concurrency.Task<Never, Never>.yield()
        }
        return try XCTUnwrap(bridge.pendingApprovalID)
    }
}
