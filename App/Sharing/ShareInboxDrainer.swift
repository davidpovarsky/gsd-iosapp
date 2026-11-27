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
    private let serverGeneration: @MainActor @Sendable (WatchAccountScope) async throws -> String
    private(set) var pendingCount = 0
    @ObservationIgnored private var drainInProgress = false
    @ObservationIgnored private var pendingDrainEnrichment: Bool?

    init(inbox: ShareInbox, store: TaskStore, titleEnricher: ShareTitleEnricher,
         mutationGate: WatchMutationGate,
         scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?,
         sharedDirectory: URL? = nil, recoverJournals: Bool = false,
         serverGeneration: @escaping @MainActor @Sendable (WatchAccountScope) async throws -> String) {
        self.inbox = inbox
        self.store = store
        self.titleEnricher = titleEnricher
        self.context = ShareScopeContext(mutationGate: mutationGate, scopeProvider: scopeProvider)
        self.sharedDirectory = sharedDirectory
        self.recoverJournals = recoverJournals
        self.serverGeneration = serverGeneration
        refreshPending()
    }

    /// Preserve requests received during a suspended credential/generation read.
    /// Each owner performs at most its initial pass and one coalesced trailing pass.
    /// Further real requests move to a new owner; a failure alone never schedules a retry.
    func drain(enrichTitles: Bool = true) async {
        guard !_Concurrency.Task.isCancelled else { return }
        pendingDrainEnrichment = (pendingDrainEnrichment ?? false) || enrichTitles
        guard !drainInProgress else { return }
        drainInProgress = true
        defer {
            drainInProgress = false
            // A foreground request may outlive a cancelled background owner. Hand off
            // only that recorded request, with fresh scope/credential checks in drainOnce.
            if let requested = pendingDrainEnrichment {
                pendingDrainEnrichment = nil
                _Concurrency.Task { @MainActor in await self.drain(enrichTitles: requested) }
            }
        }
        for _ in 0..<2 {
            guard !_Concurrency.Task.isCancelled, let requested = pendingDrainEnrichment else { break }
            pendingDrainEnrichment = nil
            await drainOnce(enrichTitles: requested)
        }
    }

    /// Recovery takes its file lease BEFORE any local gate ticket, then releases it.
    /// An active extension POST cannot be ingested early from its crash journal.
    private func drainOnce(enrichTitles: Bool) async {
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
                if try await isAlreadyApplied(capture, task: task, scope: scope, generation: generation) { return }
                let binding = try await validatedServerGeneration(
                    capture, scope: scope, generation: generation)
                // Discovery suspends. Sync or another local action may have landed this
                // identity meanwhile; a creation replay must still preserve canonical edits.
                if scope.kind == "account",
                   try await isAlreadyApplied(capture, task: task, scope: scope, generation: generation) { return }
                try context.require(scope, generation: generation)
                if pushed { try await store.ingestSynced(task) }
                else { try await store.create(task, serverDatasetGeneration: binding) }
                if enrichTitles && !_Concurrency.Task.isCancelled {
                    titleEnricher.schedule(for: task, origin: scope, serverDatasetGeneration: binding)
                }
            }
        }
        refreshPending()
    }

    /// A personal-account capture may never acquire a newer server authority on app launch.
    /// The origin lease and exact credential check in the injected provider span this read.
    private func validatedServerGeneration(
        _ capture: SharedCapture, scope: WatchAccountScope, generation: UInt64
    ) async throws -> String? {
        guard scope.kind == "account" else { return nil }
        guard let bound = capture.serverDatasetGeneration, !bound.isEmpty, bound.utf8.count <= 128,
              !bound.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            throw ShareScopeError.held
        }
        let current = try await serverGeneration(scope)
        try context.require(scope, generation: generation)
        guard bound.utf8.elementsEqual(current.utf8) else { throw ShareScopeError.held }
        return bound
    }

    private func isAlreadyApplied(_ capture: SharedCapture, task: GSDModel.Task,
                                  scope: WatchAccountScope, generation: UInt64) async throws -> Bool {
        let live = try await store.fetchTask(id: task.id)
        try context.require(scope, generation: generation)
        if let live {
            try requireRetryAlreadyRepresented(capture, incoming: task, existing: live)
            return true
        }
        let trash = try await store.trashedTasks()
        try context.require(scope, generation: generation)
        if let retained = trash.first(where: { $0.task.id == task.id }) {
            try requireRetryAlreadyRepresented(capture, incoming: task, existing: retained.task)
            return true
        }
        let archive = try await store.archivedTasksStamped()
        try context.require(scope, generation: generation)
        if let retained = archive.first(where: { $0.task.id == task.id }) {
            try requireRetryAlreadyRepresented(capture, incoming: task, existing: retained.task)
            return true
        }
        return false
    }

    /// A creation replay never overwrites canonical data or emits another sync write.
    /// Distinct edits from a failed sheet retry remain durable for explicit review instead.
    private func requireRetryAlreadyRepresented(_ capture: SharedCapture,
                                                 incoming: GSDModel.Task,
                                                 existing: GSDModel.Task) throws {
        guard capture.isEditedRetry == true else { return }
        guard incoming.title == existing.title, incoming.description == existing.description,
              incoming.urgent == existing.urgent, incoming.important == existing.important,
              incoming.tags == existing.tags else { throw ShareScopeError.held }
    }

    func refreshPending() { pendingCount = inbox.pendingCaptures().count + inbox.pendingRecoveryCount() }

    struct ReviewLease {
        let scope: WatchAccountScope
        let generation: UInt64
    }

    struct ReviewItem: Identifiable {
        let id: String
        let capture: SharedCapture
        let reviewLease: ReviewLease?
        let needsOriginalAccount: Bool
        var canReview: Bool { reviewLease != nil }
    }

    func isReviewCurrent(_ lease: ReviewLease) -> Bool {
        context.currentScope == lease.scope && context.generation == lease.generation
    }

    /// No title/content from another account appears under the currently signed-in account.
    func reviewItems() -> [ReviewItem] {
        let current = context.currentScope
        return inbox.pendingCaptures().map { item in
            let origin = item.capture.origin
            let sameOwner = current != nil && origin?.kind == current?.kind
                && origin?.identifier == current?.identifier
            let lease = current.flatMap { scope in
                origin == nil || sameOwner ? ReviewLease(scope: scope, generation: context.generation) : nil
            }
            return ReviewItem(id: item.id, capture: item.capture, reviewLease: lease,
                              needsOriginalAccount: origin != nil && !sameOwner)
        }
    }
}
