import Foundation
import Observation
import GSDSnapshot

/// Admission for Watch writes and dataset replacement. A pause closes admission synchronously,
/// then waits for complete TaskStore operations, including their internal repository awaits.
/// Nested/overlapping pauses share the hold count; cancellation cannot release another hold.
@MainActor @Observable
final class WatchMutationGate {
    typealias Identity = SharedDatasetIdentity

    private(set) var identity: Identity?
    private(set) var isPaused = false
    @ObservationIgnored private let identityStore: SharedDatasetIdentityStore
    @ObservationIgnored private let sharedDirectory: URL?
    @ObservationIgnored private var pauses = 0
    @ObservationIgnored private var admitted: Set<UUID> = []
    @ObservationIgnored private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// No identity means no Watch admission. The app can still run, while a later dataset
    /// replacement retries the durable identity write before erasing any local data.
    init(directory: URL?) {
        sharedDirectory = directory
        identityStore = SharedDatasetIdentityStore(directory: directory)
        // The app and first-ever Share agree on the atomic winner. Unreadable existing
        // identity data still fails closed and is never replaced during initialization.
        identity = try? identityStore.loadOrCreate()
    }

    func admit() -> UUID? {
        guard !isPaused, identity != nil else { return nil }
        let ticket = UUID()
        admitted.insert(ticket)
        return ticket
    }

    func finish(_ ticket: UUID) {
        guard admitted.remove(ticket) != nil, admitted.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Only transition/erase callers use this method, never an admitted Watch operation.
    /// Awaiting one's own ticket would deadlock; the coordinator only admits and finishes.
    func withPaused<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        pauses += 1
        if !isPaused { isPaused = true }
        defer {
            pauses -= 1
            if pauses == 0 { isPaused = false }
        }
        if !admitted.isEmpty {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        return try await operation()
    }

    /// Remote account deletion uses this boundary without rotating a retained local dataset.
    /// Callers must release it before invoking replacingDataset; leases are never upgraded
    /// or acquired recursively, and admitted operations never wait on this file lock.
    func withExternalWritesPaused<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        try await withPaused {
            let lease: SharedMutationLease
            do { lease = try await SharedMutationLease.acquire(directory: sharedDirectory, mode: .exclusive) }
            catch is CancellationError { throw CancellationError() }
            catch { throw IdentityError.unavailable }
            defer { lease.release() }
            try _Concurrency.Task<Never, Never>.checkCancellation()
            return try await operation()
        }
    }

    /// Rotation occurs only after admitted local operations and cooperating extension POSTs
    /// settle. A durable identity failure prevents the first remote/local destructive action.
    func replacingDataset<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        try await withExternalWritesPaused {
            let fresh = Identity(installationID: identity?.installationID ?? UUID().uuidString,
                                 datasetID: UUID().uuidString)
            do { try identityStore.replace(fresh) }
            catch { throw IdentityError.unavailable }
            identity = fresh
            return try await operation()
        }
    }

    private enum IdentityError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            String(localized: "Couldn't prepare the task collection. Please try again.")
        }
    }
}
