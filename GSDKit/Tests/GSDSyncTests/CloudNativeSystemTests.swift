import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Opt-in network acceptance against disposable accounts. Passwords and bearer tokens are never logged.
/// Uses the production TaskStore/GRDB/SyncEngine rather than a second task engine.
struct CloudNativeSystemTests {
    private func engine(_ db: AppDatabase, client: PocketBaseClient, auth: AuthService,
                        tokens: AuthServiceTests.InMemoryTokenStore) -> SyncEngine {
        SyncEngine(client: client, tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   tombstones: GRDBTombstoneRepository(db),
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "gsd.cloud-test.\(UUID().uuidString)")!),
                   deviceId: UUID().uuidString, tokenProvider: { try await auth.validToken() },
                   rawToken: { tokens.load() }, throttleMs: 0, library: GRDBCloudLibraryRepository(db))
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSD_CLOUD_SYSTEM_TEST"] == "1"))
    func closedNativePullOfflinePushNewDeviceAndAccountIsolation() async throws {
        let base = ProcessInfo.processInfo.environment["GSD_CLOUD_TEST_BASE"] ?? PocketBaseEndpoint.liveBaseURL
        let client = PocketBaseClient(baseURL: base)
        let tokensA = AuthServiceTests.InMemoryTokenStore(), tokensB = AuthServiceTests.InMemoryTokenStore()
        let presenter = AuthServiceTests.FakePresenter(.failure(AuthError.cancelled))
        let authA = AuthService(client: client, presenter: presenter, tokenStore: tokensA, config: .live)
        let authB = AuthService(client: client, presenter: presenter, tokenStore: tokensB, config: .live)
        let nonce = UUID().uuidString.lowercased()
        let password = UUID().uuidString + "A2!"
        _ = try await authA.createAccountWithEmail("gsd-native-a-\(nonce)@example.invalid", password: password)
        do {
            _ = try await authB.createAccountWithEmail("gsd-native-b-\(nonce)@example.invalid", password: password)
            let tokenA = try #require(tokensA.load()), ownerA = try #require(authA.currentUserId())
            let tokenB = try #require(tokensB.load())
            let db = try AppDatabase.inMemory()
            let tasks = GRDBTaskRepository(db), queue = GRDBSyncQueueRepository(db)
            let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                                  archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                                  defaults: UserDefaults(suiteName: "gsd.cloud-store.\(nonce)")!, syncQueue: queue)
            let sync = engine(db, client: client, auth: authA, tokens: tokensA)
            let now = Date()
            let remote = GSDModel.Task(id: UUID().uuidString, title: "Server created while native stopped",
                                      urgent: false, important: true, createdAt: now, updatedAt: now)
            // No native sync is running during this server-side write.
            _ = try await client.createTask(TaskWireMapper.toWire(remote, owner: ownerA, deviceId: "server-test", defaultReminder: 0),
                                            token: tokenA)
            let pull = await sync.sync(trigger: .launch)
            #expect(pull.error == nil && pull.failed == 0)
            #expect(try await tasks.fetch(id: remote.id)?.title == remote.title)

            let offline = GSDModel.Task(id: UUID().uuidString, title: "Offline native pending write",
                                       urgent: true, important: false, createdAt: now, updatedAt: now)
            try await store.create(offline)
            #expect(try await queue.pending().contains { $0.taskId == offline.id })
            let push = await sync.sync(trigger: .networkRegained)
            #expect(push.error == nil && push.failed == 0)
            let serverTasks = try await client.listEveryTask(token: tokenA)
            #expect(serverTasks.contains { $0.taskId == offline.id })
            #expect(try await client.listEveryTask(token: tokenB).isEmpty)

            // Repeating sync is idempotent, and another clean install receives the same account.
            _ = await sync.sync(trigger: .manual)
            #expect(try await client.listEveryTask(token: tokenA).count == 2)
            let newDevice = try AppDatabase.inMemory()
            let secondSync = engine(newDevice, client: client, auth: authA, tokens: tokensA)
            let secondResult = await secondSync.sync(trigger: .launch)
            #expect(secondResult.error == nil)
            #expect(try await GRDBTaskRepository(newDevice).fetchAll().count == 2)

            let live = try #require(try await tasks.fetch(id: offline.id))
            try await store.delete(live)
            let deletion = await sync.sync(trigger: .mutation)
            #expect(deletion.error == nil && deletion.failed == 0)
            let tombstones = try await client.listLibrary(token: tokenA)
            #expect(tombstones.contains { $0.kind == "trash" && $0.entityId == live.id && !$0.deleted })
            let deletionPull = await secondSync.sync(trigger: .foreground)
            #expect(deletionPull.error == nil)
            #expect(try await GRDBTaskRepository(newDevice).fetch(id: live.id) == nil)
            #expect(try await GRDBTrashRepository(newDevice).fetchAll().contains { $0.id == live.id })
            #expect(try await client.listLibrary(token: tokenB).isEmpty)
        } catch {
            try? await authB.deleteAccountViaRoute()
            try? await authA.deleteAccountViaRoute()
            throw error
        }
        try await authB.deleteAccountViaRoute()
        try await authA.deleteAccountViaRoute()
    }
}
