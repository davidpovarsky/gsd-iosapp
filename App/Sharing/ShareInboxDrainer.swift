import Foundation
import Observation
import GSDModel
import GSDStore
import GSDSnapshot

/// Every foreground/background Share landing uses the same immutable origin admission.
@MainActor @Observable
final class ShareInboxDrainer {
    private let inbox: ShareInbox
    private let store: TaskStore
    private let titleEnricher: ShareTitleEnricher
    private let context: ShareScopeContext
    private let sharedDirectory: URL?
    private let recoverJournals: Bool
    private(set) var pendingCount = 0

    init(inbox: ShareInbox, store: TaskStore, titleEnricher: ShareTitleEnricher,
         mutationGate: WatchMutationGate,
         scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?,
         sharedDirectory: URL? = nil, recoverJournals: Bool = false) {
        self.inbox = inbox
        self.store = store
        self.titleEnricher = titleEnricher
        self.context = ShareScopeContext(mutationGate: mutationGate, scopeProvider: scopeProvider)
        self.sharedDirectory = sharedDirectory
        self.recoverJournals = recoverJournals
        refreshPending()
    }

    /// Recovery takes its file lease BEFORE any local gate ticket, then releases it.
    /// An active extension POST cannot be ingested early from its crash journal.
    func drain(enrichTitles: Bool = true) async {
        if recoverJournals {
            do {
                let lease = try await SharedMutationLease.acquire(directory: sharedDirectory, mode: .exclusive)
                defer { lease.release() }
                try inbox.recoverInFlight()
            } catch {
                refreshPending()
                return
            }
        }
        await inbox.drain { capture, task, pushed in
            try await context.withOrigin(capture.origin) { scope, generation in
                if try await isRetainedTerminal(task.id, scope: scope, generation: generation) { return }
                try context.require(scope, generation: generation)
                if pushed { try await store.ingestSynced(task) }
                else { try await store.create(task) }
                if enrichTitles && !_Concurrency.Task.isCancelled {
                    titleEnricher.schedule(for: task, origin: scope)
                }
            }
        }
        refreshPending()
    }

    private func isRetainedTerminal(_ id: String, scope: WatchAccountScope,
                                    generation: UInt64) async throws -> Bool {
        let live = try await store.fetchTask(id: id)
        try context.require(scope, generation: generation)
        if live != nil { return false }
        let trash = try await store.trashedTasks()
        try context.require(scope, generation: generation)
        if trash.contains(where: { $0.task.id == id }) { return true }
        let archive = try await store.archivedTasksStamped()
        try context.require(scope, generation: generation)
        return archive.contains { $0.task.id == id }
    }

    func refreshPending() { pendingCount = inbox.pendingCaptures().count + inbox.pendingRecoveryCount() }

    struct ReviewItem: Identifiable {
        let id: String
        let capture: SharedCapture
        let canReview: Bool
        let needsOriginalAccount: Bool
    }

    /// No title/content from another account appears under the currently signed-in account.
    func reviewItems() -> [ReviewItem] {
        let current = context.currentScope
        return inbox.pendingCaptures().map { item in
            let origin = item.capture.origin
            let sameOwner = current != nil && origin?.kind == current?.kind
                && origin?.identifier == current?.identifier
            return ReviewItem(id: item.id, capture: item.capture,
                              canReview: current != nil && (origin == nil || sameOwner),
                              needsOriginalAccount: origin != nil && !sameOwner)
        }
    }
}
