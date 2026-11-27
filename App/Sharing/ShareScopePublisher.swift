import Foundation
import Observation
import GSDSnapshot

/// Installed during GSDApp.init before any asynchronous account or Share operation.
@MainActor
final class ShareScopePublisher {
    private let store: ShareScopePublicationStore
    private let scopeProvider: @MainActor @Sendable () -> WatchAccountScope?
    private var nonce = UUID().uuidString
    private(set) var publicationAvailable = false

    init(directory: URL?, scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?) {
        store = ShareScopePublicationStore(directory: directory)
        self.scopeProvider = scopeProvider
        // A cold launch of the same verified scope can keep an already-open sheet's lease.
        if let previous = try? store.read(), previous.scope == scopeProvider(), !previous.guestBootstrap {
            nonce = previous.nonce
        }
        observe()
    }

    private func observe() {
        let scope = withObservationTracking { scopeProvider() } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.invalidate() }
        }
        publish(scope)
    }

    private func invalidate() {
        nonce = UUID().uuidString
        // Observation is willSet: publish unresolved synchronously before the account/dataset
        // field changes or any transition await. Re-reading occurs after the mutation.
        publish(nil)
        _Concurrency.Task { @MainActor [weak self] in self?.observe() }
    }

    private func publish(_ scope: WatchAccountScope?) {
        do {
            try store.publish(ShareScopePublication(scope: scope, nonce: nonce))
            publicationAvailable = true
        } catch {
            publicationAvailable = false
            // Do not replace identity or reassign captures after a metadata write failure.
            // Dataset/token validation remains mandatory at extension and app admission.
        }
    }
}
