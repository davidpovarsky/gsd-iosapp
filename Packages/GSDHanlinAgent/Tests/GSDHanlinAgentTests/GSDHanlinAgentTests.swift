import Foundation
import XCTest
import GSDModel
import GSDStore
import HanlinAgentCore
import HanlinHostContracts
import HanlinPlatformContracts
@testable import GSDHanlinAgent

@MainActor
final class GSDHanlinAgentTests: XCTestCase {
    private func fixture() throws -> (TaskStore, HanlinHostContext, HanlinHostSession) {
        let db = try AppDatabase.inMemory()
        let store = TaskStore(
            repository: GRDBTaskRepository(db),
            smartViewRepository: GRDBSmartViewRepository(db),
            archiveRepository: GRDBArchiveRepository(db),
            trashRepository: GRDBTrashRepository(db))
        let namespace = try HanlinConversationNamespace(
            app: "gsd", account: "testing", workspace: "local", space: "tasks")
        let context = HanlinHostContext(
            namespace: namespace, sceneID: UUID(), generation: UUID())
        return (store, context, HanlinHostSession(conversationID: UUID(), context: context))
    }

    func testCatalogHasUniqueValidatedToolsAndRequiresApprovals() throws {
        let (store, context, _) = try fixture()
        _ = store
        let catalog = try GSDHanlinToolCatalog.catalog(for: context)
        try catalog.validate()
        XCTAssertEqual(catalog.tools.count, 22)
        XCTAssertEqual(Set(catalog.tools.map(\.route.alias)).count, 22)
        XCTAssertEqual(catalog.tools.filter { $0.writeGuarantee != .readOnly }.count, 14)
        for spec in GSDHanlinToolCatalog.specs {
            XCTAssertNoThrow(try HanlinHostSchemaValidation(schemaJSON: spec.schemaJSON()))
        }
    }

    func testReadWorksAndWriteDeniedWithoutHostConsent() async throws {
        let (store, context, session) = try fixture()
        let host = GSDHanlinHost(store: store, context: context)
        let dispatcher = HanlinHostDispatcher(host: host)
        let catalog = try await host.catalog(for: context)
        let read = try await dispatcher.dispatch(
            alias: "list_tasks", argumentsJSON: #"{"limit":10}"#,
            providerCallID: "read1", runID: UUID(), step: 0,
            session: session, catalog: catalog, limits: .init())
        XCTAssertEqual(read.effectState, .confirmedNoEffect)
        let write = try await dispatcher.dispatch(
            alias: "create_task", argumentsJSON: #"{"title":"No permission"}"#,
            providerCallID: "write1", runID: UUID(), step: 0,
            session: session, catalog: catalog, limits: .init())
        XCTAssertEqual(write.effectState, .notDispatched)
        let after = try await store.fetchAllTasks()
        XCTAssertTrue(after.isEmpty)
    }

    func testApprovedCreatePersistsOnce() async throws {
        let (store, context, session) = try fixture()
        let host = GSDHanlinHost(store: store, context: context) { _ in true }
        let dispatcher = HanlinHostDispatcher(host: host)
        let catalog = try await host.catalog(for: context)
        let run = UUID()
        let one = try await dispatcher.dispatch(
            alias: "create_task", argumentsJSON: #"{"title":"Approved task","urgent":true}"#,
            providerCallID: "provider-1", runID: run, step: 0,
            session: session, catalog: catalog, limits: .init())
        XCTAssertEqual(one.effectState, .confirmedCommitted)
        let replay = try await dispatcher.dispatch(
            alias: "create_task", argumentsJSON: #"{"title":"Approved task","urgent":true}"#,
            providerCallID: "provider-1", runID: run, step: 0,
            session: session, catalog: catalog, limits: .init())
        XCTAssertEqual(replay.result, one.result)
        let rows = try await store.fetchAllTasks()
        XCTAssertEqual(rows.count, 1)
    }

    func testContextRevocationBlocksWrites() async throws {
        let (store, context, session) = try fixture()
        let host = GSDHanlinHost(store: store, context: context) { _ in true }
        let catalog = try await host.catalog(for: context)
        await host.setContext(.init(namespace: context.namespace,
                                    sceneID: context.sceneID, generation: UUID()))
        let dispatcher = HanlinHostDispatcher(host: host)
        do {
            _ = try await dispatcher.dispatch(
                alias: "create_task", argumentsJSON: #"{"title":"Wrong scene"}"#,
                providerCallID: "stale", runID: UUID(), step: 0,
                session: session, catalog: catalog, limits: .init())
            XCTFail("Expected a stale context error")
        } catch {
            // The rejected invocation must leave the database unchanged.
        }
        let rows = try await store.fetchAllTasks()
        XCTAssertTrue(rows.isEmpty)
    }
}
