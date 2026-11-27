import Foundation
import Observation
import UIKit
import GSDStore
import GSDSnapshot

/// Shared admission for app-side Share ingest and delayed title writes.
@MainActor @Observable
final class ShareScopeContext {
    let mutationGate: WatchMutationGate
    private let scopeProvider: @MainActor @Sendable () -> WatchAccountScope?
    private var observedScope: WatchAccountScope?
    private var stable = false
    private(set) var generation: UInt64 = 0
    private let window = BackgroundDatabaseWindow(isBackgrounded: {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIApplication.shared.applicationState != .active
        #endif
    })

    init(mutationGate: WatchMutationGate,
         scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?) {
        self.mutationGate = mutationGate
        self.scopeProvider = scopeProvider
        observe()
    }

    private func readScope() -> WatchAccountScope? {
        guard !mutationGate.isPaused, let identity = mutationGate.identity,
              let scope = scopeProvider(), scope.isValid, scope.datasetID == identity.datasetID else { return nil }
        return scope
    }

    var currentScope: WatchAccountScope? {
        guard stable, let scope = readScope(), scope == observedScope else { return nil }
        return scope
    }

    private func observe() {
        observedScope = withObservationTracking { readScope() } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.generation &+= 1
                self.stable = false
                _Concurrency.Task { @MainActor [weak self] in self?.observe() }
            }
        }
        stable = true
    }

    func require(_ origin: WatchAccountScope, generation: UInt64) throws {
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard generation == self.generation, currentScope == origin else { throw ShareScopeError.held }
    }

    func withOrigin<T>(_ origin: WatchAccountScope?,
                       _ body: @MainActor (WatchAccountScope, UInt64) async throws -> T) async throws -> T {
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard let origin, origin.isValid, currentScope == origin, let ticket = mutationGate.admit() else {
            throw ShareScopeError.held
        }
        let generation = generation
        defer { mutationGate.finish(ticket) }
        return try await window.run {
            try require(origin, generation: generation)
            return try await body(origin, generation)
        }
    }
}

enum ShareScopeError: Error { case held }
