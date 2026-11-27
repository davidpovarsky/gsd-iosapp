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

    init(store: TaskStore, fetch: @escaping (URL) async -> String?,
         mutationGate: WatchMutationGate,
         scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?) {
        self.store = store
        self.fetch = fetch
        self.context = ShareScopeContext(mutationGate: mutationGate, scopeProvider: scopeProvider)
    }

    @discardableResult
    func schedule(for task: GSDModel.Task, origin: WatchAccountScope) -> _Concurrency.Task<Void, Never>? {
        guard !_Concurrency.Task.isCancelled,
              context.currentScope == origin,
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
                    guard var current = try await store.fetchTask(id: task.id) else { return }
                    try context.require(scope, generation: leaseGeneration)
                    guard current.title == derivedTitle(for: url), sharedURL(in: current) == url else { return }
                    current.title = String(fetched.prefix(FieldLimits.titleRange.upperBound))
                    try await store.save(current)
                }
            } catch {
                // Enrichment is optional. Keep the captured task and user edits unchanged;
                // scope loss, cancellation or a failed read must never recreate a row.
            }
        }
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
