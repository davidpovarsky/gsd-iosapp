import Foundation
import GSDModel
import GSDStore
import GSDSnapshot

/// Fetching does not hold an account transition open. Its eventual write must re-enter the
/// originating scope and read the canonical row before changing the URL-derived title.
@MainActor
final class ShareTitleEnricher {
    private let store: TaskStore
    private let fetch: (URL) async -> String?
    private let context: ShareScopeContext
    private let serverGeneration: @MainActor @Sendable (WatchAccountScope) async throws -> String

    init(store: TaskStore, fetch: @escaping (URL) async -> String?,
         mutationGate: WatchMutationGate,
         scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?,
         serverGeneration: @escaping @MainActor @Sendable (WatchAccountScope) async throws -> String) {
        self.store = store
        self.fetch = fetch
        self.serverGeneration = serverGeneration
        self.context = ShareScopeContext(mutationGate: mutationGate, scopeProvider: scopeProvider)
    }

    @discardableResult
    func schedule(for task: GSDModel.Task, origin: WatchAccountScope,
                  serverDatasetGeneration: String?) -> _Concurrency.Task<Void, Never>? {
        guard !_Concurrency.Task.isCancelled,
              context.currentScope == origin,
              origin.kind != "account" || isValidGeneration(serverDatasetGeneration),
              AppGroupDefaults.shared.object(forKey: AppGroupDefaults.Key.fetchShareTitles) as? Bool ?? false,
              let url = sharedURL(in: task), task.title == derivedTitle(for: url) else { return nil }
        let generation = context.generation
        return _Concurrency.Task { [weak self] in
            guard let self,
                  let fetched = await fetch(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fetched.isEmpty else { return }
            do {
                try context.require(origin, generation: generation)
                try await context.withOrigin(origin) { scope, leaseGeneration in
                    let binding: String?
                    if scope.kind == "account" {
                        guard let bound = serverDatasetGeneration else { throw ShareScopeError.held }
                        let currentGeneration = try await serverGeneration(scope)
                        try context.require(scope, generation: leaseGeneration)
                        guard bound.utf8.elementsEqual(currentGeneration.utf8) else { throw ShareScopeError.held }
                        binding = bound
                    } else {
                        binding = nil
                    }
                    // Read after the awaited generation check, so intervening manual edits
                    // cannot be overwritten by the older URL-title response.
                    guard var current = try await store.fetchTask(id: task.id) else { return }
                    try context.require(scope, generation: leaseGeneration)
                    guard current.title == derivedTitle(for: url), sharedURL(in: current) == url else { return }
                    current.title = String(fetched.prefix(FieldLimits.titleRange.upperBound))
                    try await store.save(current, serverDatasetGeneration: binding)
                }
            } catch {
                // Enrichment is optional. Keep the captured task and user edits unchanged;
                // scope loss, cancellation or a failed read must never recreate a row.
            }
        }
    }

    private func isValidGeneration(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.utf8.count <= 128
            && !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F })
    }

    private func sharedURL(in task: GSDModel.Task) -> URL? {
        let firstLine = task.description.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? task.description
        guard let safe = URLSanitizer.sanitize(firstLine), let url = URL(string: safe) else { return nil }
        return url
    }

    private func derivedTitle(for url: URL) -> String {
        String(URLTitle.derive(from: url.absoluteString).prefix(FieldLimits.titleRange.upperBound))
    }
}
